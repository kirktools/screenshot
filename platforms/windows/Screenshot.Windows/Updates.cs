using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Security;
using System.Security.Principal;
using Screenshot.Core;
namespace Screenshot.Windows;

internal sealed record UpdatePlan(string InstallDirectory, int ProcessId, string OldHash, string NewHash, string Version);
internal static class Updates
{
    static readonly string Root = Path.Combine(Preferences.Folder, "updates");
    static string Hash(string path) { using var file = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(file)); }
    internal static bool IsElevated
    {
        get { using var identity = WindowsIdentity.GetCurrent(); return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator); }
    }
    internal static void EnsureUnelevated()
    {
        if (IsElevated) throw new SecurityException("自动更新不在管理员权限下运行。请退出后以普通用户身份重新打开，再检查更新；无需关闭系统安全保护。");
    }
    public static void MarkStarted(string directory)
    {
        EnsureUnelevated();
        directory = Path.GetFullPath(directory);
        if (Path.GetDirectoryName(directory) != Path.GetFullPath(Root) || !Guid.TryParseExact(Path.GetFileName(directory), "N", out _) || !File.Exists(Path.Combine(directory, "plan.json"))) throw new InvalidDataException("更新确认目录无效");
        File.WriteAllText(Path.Combine(directory, "started"), "started");
        UpdateProcessFixture.Started();
    }
    public static void Cleanup()
    {
        try
        {
            if (IsElevated) return;
            if (!Directory.Exists(Root)) return;
            foreach (string folder in Directory.GetDirectories(Root))
            {
                if (!Guid.TryParseExact(Path.GetFileName(folder), "N", out _) || (File.GetAttributes(folder) & FileAttributes.ReparsePoint) != 0) continue;
                if (File.Exists(Path.Combine(folder, "complete")))
                { try { Directory.Delete(folder, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
    public static async Task<bool> Check(Form owner, CancellationToken cancellation)
    {
        EnsureUnelevated();
        using var client = new ReleaseClient();
        var bytes = await client.Download(new("https://api.github.com/repos/kirktools/screenshot/releases/latest"), 2 * 1024 * 1024, cancellation);
        var current = typeof(Updates).Assembly.GetName().Version!;
        string architecture = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";
        var offer = ReleaseUpdates.Parse(bytes, current, architecture);
        if (offer is null) { MessageBox.Show(owner, "当前没有更新的正式版。", "检查更新"); return false; }
        if (MessageBox.Show(owner, $"发现 {offer.Version}，当前 {current.Major}.{current.Minor}.{current.Build}。\n\n将从 kirktools/screenshot 的 GitHub 正式版下载、校验并替换应用；无需管理员权限。当前 Windows 安装包未做 Authenticode 签名，系统可能要求确认来源。\n\n确认下载并安装？", "软件更新", MessageBoxButtons.OKCancel, MessageBoxIcon.Information) != DialogResult.OK) return false;
        string install = Path.GetFullPath(AppContext.BaseDirectory);
        if (!File.Exists(Path.Combine(install, "Screenshot.exe"))) throw new IOException("请先把完整安装包解压到可写目录，再运行 Screenshot.exe。");
        string test = Path.Combine(install, ".update-write-test-" + Guid.NewGuid().ToString("N"));
        try { using (File.Create(test)) { } } catch (IOException) { throw new IOException("安装目录不可写。请把完整应用移到自己的可写目录后更新，不需要以管理员身份运行。"); } finally { if (File.Exists(test)) File.Delete(test); }
        Directory.CreateDirectory(Root); string directory = Path.Combine(Root, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        bool launched = false;
        try
        {
            var archive = await client.Download(offer.Archive, ReleaseUpdates.MaximumArchiveBytes, cancellation);
            var checksums = await client.Download(offer.Checksums, 65536, cancellation);
            ReleaseUpdates.VerifyChecksum(archive, Encoding.UTF8.GetString(checksums), offer.ArchiveName);
            string candidate = Path.Combine(directory, "candidate");
            await Task.Run(() => ReleaseUpdates.Extract(archive, candidate), cancellation);
            string candidateExe = Path.Combine(candidate, "Screenshot.exe");
            var version = FileVersionInfo.GetVersionInfo(candidateExe);
            if (version.FileMajorPart != offer.Version.Major || version.FileMinorPart != offer.Version.Minor || version.FileBuildPart != offer.Version.Build) throw new InvalidDataException("安装包版本与 Release 不一致");
            using (var pe = File.OpenRead(candidateExe)) using (var reader = new BinaryReader(pe))
            {
                if (reader.ReadUInt16() != 0x5A4D) throw new InvalidDataException("候选程序不是 Windows 可执行文件");
                pe.Position = 0x3C; int offset = reader.ReadInt32(); if (offset < 0 || offset > pe.Length - 6) throw new InvalidDataException("PE 头无效");
                pe.Position = offset; if (reader.ReadUInt32() != 0x4550) throw new InvalidDataException("PE 签名无效");
                ushort expected = architecture == "arm64" ? (ushort)0xAA64 : (ushort)0x8664;
                if (reader.ReadUInt16() != expected) throw new InvalidDataException("安装包架构与当前程序不一致");
            }
            string currentExe = Path.Combine(install, "Screenshot.exe"), helper = Path.Combine(directory, "Screenshot.Update.exe");
            File.Copy(currentExe, helper);
            var plan = new UpdatePlan(install, Environment.ProcessId, Hash(currentExe), Hash(candidateExe), offer.Version.ToString());
            File.WriteAllText(Path.Combine(directory, "plan.json"), JsonSerializer.Serialize(plan));
            var start = new ProcessStartInfo(helper) { UseShellExecute = false }; start.ArgumentList.Add("--apply-update"); start.ArgumentList.Add(directory);
            Process.Start(start)?.Dispose();
            // 等待助手校验任务并准备完成，失败时不退出正在使用的旧版。
            for (int i = 0; i < 100; i++) { if (File.Exists(Path.Combine(directory, "ready"))) { launched = true; return true; } await Task.Delay(100, cancellation); }
            throw new IOException("更新助手未准备就绪，当前应用继续运行。请稍后重试。");
        }
        finally { if (!launched) { try { File.WriteAllText(Path.Combine(directory, "cancelled"), "cancelled"); Directory.Delete(directory, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } } }
    }
    public static int Apply(string directory)
    {
        UpdatePlan? plan = null; string phase = "validate";
        try
        {
            EnsureUnelevated();
            directory = Path.GetFullPath(directory);
            if (Path.GetDirectoryName(directory) != Path.GetFullPath(Root) || !Guid.TryParseExact(Path.GetFileName(directory), "N", out _)) throw new InvalidDataException("更新任务目录无效");
            plan = JsonSerializer.Deserialize<UpdatePlan>(File.ReadAllText(Path.Combine(directory, "plan.json"))) ?? throw new InvalidDataException("更新任务无效");
            string install = Path.GetFullPath(plan.InstallDirectory), candidate = Path.Combine(directory, "candidate");
            string oldExe = Path.Combine(install, "Screenshot.exe"), newExe = Path.Combine(candidate, "Screenshot.exe");
            if (Hash(oldExe) != plan.OldHash || Hash(newExe) != plan.NewHash || Hash(Environment.ProcessPath!) != plan.OldHash) throw new InvalidDataException("更新文件已变化，已取消");
            File.WriteAllText(Path.Combine(directory, "ready"), "ready");
            try
            {
                using var process = Process.GetProcessById(plan.ProcessId); var deadline = DateTime.UtcNow.AddSeconds(60);
                while (!process.HasExited)
                {
                    if (File.Exists(Path.Combine(directory, "cancelled"))) return 0;
                    if (DateTime.UtcNow > deadline) throw new IOException("旧应用没有退出，未替换安装文件");
                    Thread.Sleep(100);
                }
            }
            catch (ArgumentException) { }
            if (File.Exists(Path.Combine(directory, "cancelled"))) return 0;
            if (Hash(oldExe) != plan.OldHash || Hash(newExe) != plan.NewHash) throw new InvalidDataException("更新文件在等待期间已变化，未覆盖");
            phase = "replace";
            PortableInstall.Replace(install, candidate, () =>
            {
                string executable = Path.Combine(install, "Screenshot.exe");
                File.WriteAllText(executable + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n");
                var start = new ProcessStartInfo(executable) { UseShellExecute = true, WorkingDirectory = install };
                start.ArgumentList.Add("--update-started"); start.ArgumentList.Add(directory);
                phase = "launch";
                using var child = Process.Start(start) ?? throw new IOException("新版没有启动");
                var deadline = DateTime.UtcNow.AddSeconds(15);
                while (!File.Exists(Path.Combine(directory, "started")))
                {
                    if (child.HasExited) throw new IOException("新版启动后提前退出");
                    if (DateTime.UtcNow > deadline) { if (!child.HasExited) { child.Kill(); child.WaitForExit(5000); } throw new IOException("新版启动确认超时"); }
                    Thread.Sleep(100);
                }
            });
            File.WriteAllText(Path.Combine(directory, "complete"), "updated");
            return 0;
        }
        catch (Exception error)
        {
            if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true" && plan != null)
            {
                try { File.WriteAllText(Path.Combine(directory, "failure.txt"), phase + ": " + error.GetType().Name + ": " + error.Message); } catch (IOException) { }
            }
            if (plan != null)
            {
                try { Process.Start(new ProcessStartInfo(Path.Combine(plan.InstallDirectory, "Screenshot.exe")) { UseShellExecute = true })?.Dispose(); }
                catch (Exception) { /* 原文件和备份保留，供用户恢复。 */ }
            }
            MessageBox.Show("更新没有完成；原版已尽可能保留或恢复。请确认目录可写，并检查 Windows 的来源确认提示。没有自动提权或关闭安全保护。", "更新失败"); return 1;
        }
    }
}
