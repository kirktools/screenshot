using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text;

// 隔离 CI 专用测试工具：只降低子进程权限，不改用户、UAC、系统策略或真实安装。
internal static class Program
{
    static int Main(string[] args)
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || args.Length != 2) return 1;
        string root = Path.Combine(Path.GetTempPath(), "ScreenshotUpdateProcess-" + Guid.NewGuid().ToString("N"));
        string install = Path.Combine(root, "current"), candidate = Path.Combine(root, "candidate");
        string task = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Screenshot", "updates", Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(install); Directory.CreateDirectory(candidate);
            foreach (string file in new[] { "Screenshot.exe", "LICENSE.txt", "ThirdPartyNotices.txt" })
            {
                File.Copy(Path.Combine(args[0], file), Path.Combine(install, file));
                File.Copy(file == "Screenshot.exe" ? args[1] : Path.Combine(args[0], file), Path.Combine(candidate, file));
            }
            string original = Hash(Path.Combine(install, "Screenshot.exe")), expected = Hash(Path.Combine(candidate, "Screenshot.exe"));
            if (original == expected) throw new Exception("必须使用不同版本的程序验证真实替换");
            string executable = Path.Combine(install, "Screenshot.exe");
            using (var worker = StandardUserProcess(executable, ["--prepare-update-test", task, candidate]))
            {
                // GetProcessById 返回的对象必须先保留句柄，退出后仍需读取退出码。
                using var handle = worker.SafeHandle;
                if (!worker.WaitForExit(60000)) { worker.Kill(); worker.WaitForExit(5000); throw new Exception("更新准备进程超时"); }
                if (worker.ExitCode != 0)
                    throw new Exception(File.Exists(Path.Combine(root, "error.txt")) ? File.ReadAllText(Path.Combine(root, "error.txt")) : "更新准备失败");
            }
            if (!File.Exists(Path.Combine(root, "standard-user"))) throw new Exception("未验证普通用户权限，不能绕过高权限更新保护");
            var deadline = DateTime.UtcNow.AddSeconds(40);
            while (!File.Exists(Path.Combine(root, "started.pid")))
            { if (DateTime.UtcNow > deadline) throw new Exception("新版启动确认超时，可能需要系统来源确认"); Thread.Sleep(100); }
            int helperPid = int.Parse(File.ReadAllText(Path.Combine(root, "helper.pid")));
            WaitFor(helperPid, 20000);
            if (Hash(executable) != expected || !File.ReadAllText(Path.Combine(root, "started.version")).StartsWith("999.0.0", StringComparison.Ordinal)) throw new Exception("新版文件或实际启动版本不符");
            var backups = Directory.GetDirectories(install, ".backup-*");
            if (backups.Length != 1 || Hash(Path.Combine(backups[0], "Screenshot.exe")) != original) throw new Exception("旧版备份不完整");
            if (!File.ReadAllText(executable + ":Zone.Identifier").Contains("ZoneId=3", StringComparison.Ordinal)) throw new Exception("来源标记未保留");
            Console.WriteLine("PASS: standard-user real update helper, different-version replacement, backup, internet zone and new-process startup acknowledgement");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine("UPDATE PROCESS TEST FAILED: " + (error is System.ComponentModel.Win32Exception native ? $"win32={native.NativeErrorCode}: {native.Message}" : error.Message)); return 1; }
        finally
        {
            // 只结束本测试临时副本的进程，不触碰其他 Screenshot 实例。
            StopOwned(Path.Combine(root, "started.pid"), install);
            StopOwned(Path.Combine(root, "helper.pid"), task);
            try { if (Directory.Exists(task)) Directory.Delete(task, true); } catch (IOException) { }
            try { if (Directory.Exists(root)) Directory.Delete(root, true); } catch (IOException) { }
        }
    }
    static string Hash(string path) { using var stream = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(stream)); }
    static void WaitFor(int pid, int timeout)
    { try { using var process = Process.GetProcessById(pid); if (!process.WaitForExit(timeout)) throw new Exception("助手未正常退出"); } catch (ArgumentException) { } }
    static void StopOwned(string marker, string directory)
    {
        try
        {
            if (!File.Exists(marker)) return;
            using var process = Process.GetProcessById(int.Parse(File.ReadAllText(marker)));
            if (Path.GetDirectoryName(process.MainModule?.FileName)?.Equals(directory, StringComparison.OrdinalIgnoreCase) == true)
            { process.Kill(); process.WaitForExit(5000); }
        }
        catch (ArgumentException) { } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { }
    }
    static Process StandardUserProcess(string executable, string[] args)
    {
        using var identity = WindowsIdentity.GetCurrent();
        if (!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
        {
            var start = new ProcessStartInfo(executable) { UseShellExecute = false }; foreach (string arg in args) start.ArgumentList.Add(arg);
            return Process.Start(start) ?? throw new Exception("无法启动普通用户测试进程");
        }
        IntPtr source = IntPtr.Zero, token = IntPtr.Zero; List<IntPtr> sids = [];
        try
        {
            if (!OpenProcessToken(GetCurrentProcess(), 0x8B, out source)) Error("读取自身令牌");
            SidAndAttributes Sid(WellKnownSidType type)
            {
                var sid = new SecurityIdentifier(type, null); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
                IntPtr memory = Marshal.AllocHGlobal(bytes.Length); Marshal.Copy(bytes, 0, memory, bytes.Length); sids.Add(memory); return new() { Sid = memory };
            }
            var disabled = new[] { Sid(WellKnownSidType.BuiltinAdministratorsSid), Sid(WellKnownSidType.BuiltinPowerUsersSid) };
            if (!CreateRestrictedToken(source, 1, (uint)disabled.Length, disabled, 0, IntPtr.Zero, 0, IntPtr.Zero, out token)) Error("降低子进程权限");
            var medium = new SecurityIdentifier("S-1-16-8192"); var bytes = new byte[medium.BinaryLength]; medium.GetBinaryForm(bytes, 0);
            IntPtr memory = Marshal.AllocHGlobal(bytes.Length); Marshal.Copy(bytes, 0, memory, bytes.Length); sids.Add(memory);
            var label = new SidAndAttributes { Sid = memory, Attributes = 0x20 };
            if (!SetTokenInformation(token, 25, ref label, (uint)(Marshal.SizeOf<SidAndAttributes>() + bytes.Length))) Error("设置中等完整性");
            var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>(), Desktop = @"winsta0\default" };
            string Quote(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";
            var command = new StringBuilder(string.Join(" ", new[] { executable }.Concat(args).Select(Quote)));
            if (!CreateProcessAsUser(token, executable, command, IntPtr.Zero, IntPtr.Zero, false, 0x400, IntPtr.Zero, Path.GetDirectoryName(executable), ref startup, out var info)) Error("启动受限子进程");
            try { return Process.GetProcessById(info.ProcessId); }
            finally { CloseHandle(info.Thread); CloseHandle(info.Process); }
        }
        finally { if (token != IntPtr.Zero) CloseHandle(token); if (source != IntPtr.Zero) CloseHandle(source); foreach (var sid in sids) Marshal.FreeHGlobal(sid); }
    }
    static void Error(string operation) => throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), operation);
    [StructLayout(LayoutKind.Sequential)] struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct StartupInfo
    {
        public int Size; public string? Reserved; public string? Desktop; public string? Title;
        public int X, Y, XSize, YSize, XChars, YChars, Fill, Flags; public short Show, ReservedSize;
        public IntPtr ReservedPointer, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool CreateRestrictedToken(IntPtr existing, uint flags, uint sidCount, [In] SidAndAttributes[] disabled, uint privilegeCount, IntPtr privileges, uint restrictingCount, IntPtr restricting, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr token, int information, ref SidAndAttributes value, uint length);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessAsUser(IntPtr token, string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string? directory, ref StartupInfo startup, out ProcessInfo process);
}
