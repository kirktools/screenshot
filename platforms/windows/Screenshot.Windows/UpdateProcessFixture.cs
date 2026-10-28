using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using Screenshot.Adapters;
namespace Screenshot.Windows;

// 仅供隔离 CI 的真实进程回归。路径限定到专用临时副本，不改动正式安装。
internal static class UpdateProcessFixture
{
    internal static string? Root
    {
        get
        {
            if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true") return null;
            string install = Path.TrimEndingDirectorySeparator(Path.GetFullPath(AppContext.BaseDirectory));
            string? root = Path.GetDirectoryName(install);
            return root != null && Path.GetFileName(install) == "current" && Path.GetFileName(root).StartsWith("ScreenshotUpdateProcess-", StringComparison.Ordinal) && Path.TrimEndingDirectorySeparator(Path.GetDirectoryName(root)!) == Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath())) ? root : null;
        }
    }
    internal static int Prepare(string directory, string candidate)
    {
        string? root = Root;
        try
        {
            if (root == null) throw new InvalidOperationException("更新进程回归只接受隔离 CI 的临时副本");
            Updates.EnsureUnelevated();
            SharedStitchCore.Validate();
            File.WriteAllText(Path.Combine(root, "standard-user"), "true");
            string updateRoot = Path.GetFullPath(Path.Combine(Preferences.Folder, "updates"));
            directory = Path.GetFullPath(directory); candidate = Path.GetFullPath(candidate);
            if (Path.GetDirectoryName(directory) != updateRoot || !Guid.TryParseExact(Path.GetFileName(directory), "N", out _) || candidate != Path.Combine(root, "candidate")) throw new InvalidOperationException("测试路径越界");
            Directory.CreateDirectory(directory);
            // 使用真实 ZIP 解压和完整性检查；不访问网络，也不发布测试版本。
            using var stream = new MemoryStream();
            using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, true))
                foreach (string file in PortableInstall.CandidateFiles(candidate)) zip.CreateEntryFromFile(Path.Combine(candidate, file), file, CompressionLevel.Fastest);
            var bytes = stream.ToArray(); string checksum = Convert.ToHexString(SHA256.HashData(bytes));
            ReleaseUpdates.VerifyChecksum(bytes, checksum + "  fixture.zip", "fixture.zip");
            string extracted = Path.Combine(directory, "candidate"); ReleaseUpdates.Extract(bytes, extracted);
            string current = Path.Combine(AppContext.BaseDirectory, "Screenshot.exe");
            static string Hash(string path) { using var input = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(input)); }
            var plan = new UpdatePlan(AppContext.BaseDirectory, Environment.ProcessId, Hash(current), Hash(Path.Combine(extracted, "Screenshot.exe")), "999.0.0", PortableInstall.Digest(extracted));
            string helper = Path.Combine(directory, "Screenshot.Update.exe"); File.Copy(current, helper);
            File.WriteAllText(Path.Combine(directory, "plan.json"), JsonSerializer.Serialize(plan));
            var start = new ProcessStartInfo(helper) { UseShellExecute = false }; start.ArgumentList.Add("--apply-update"); start.ArgumentList.Add(directory);
            using var child = Process.Start(start) ?? throw new IOException("助手未启动");
            File.WriteAllText(Path.Combine(root, "helper.pid"), child.Id.ToString());
            for (int i = 0; i < 200; i++)
            {
                if (File.Exists(Path.Combine(directory, "ready"))) return 0;
                if (child.HasExited) throw new IOException("助手未就绪即退出");
                Thread.Sleep(100);
            }
            throw new IOException("助手准备超时");
        }
        catch (Exception error)
        {
            if (root != null) File.WriteAllText(Path.Combine(root, "error.txt"), error.GetType().Name + ": " + error.Message);
            return 1;
        }
    }
}
