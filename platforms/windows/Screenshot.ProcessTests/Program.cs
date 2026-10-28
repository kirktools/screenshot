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
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || args.Length is < 2 or > 3 || (args.Length == 3 && args[2] != "--confirm-test-source")) return 1;
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
            Process? started = null; bool confirmedSource = false;
            while (started == null)
            {
                // 验证生产启动确认与实际进程，不依赖 Shell 是否继承 CI 环境变量。
                if (File.Exists(Path.Combine(task, "started"))) started = FindOwnedProcess(executable);
                if (started != null) break;
                if (args.Length == 3 && !confirmedSource)
                {
                    int helper = int.Parse(File.ReadAllText(Path.Combine(root, "helper.pid")));
                    confirmedSource = ConfirmOwnSource(helper, executable, expected, Path.Combine(task, "Screenshot.Update.exe"), original);
                }
                if (DateTime.UtcNow > deadline)
                {
                    int pid = int.Parse(File.ReadAllText(Path.Combine(root, "helper.pid")));
                    Console.Error.WriteLine("OWN HELPER WINDOWS: " + HelperWindows(pid));
                    throw new Exception("新版启动确认超时: " + Diagnostic(root, task));
                }
                Thread.Sleep(100);
            }
            using (started)
            {
                File.WriteAllText(Path.Combine(root, "started.pid"), started.Id.ToString());
                var actual = started.MainModule?.FileVersionInfo;
                if (actual == null || actual.FileMajorPart != 999 || actual.FileMinorPart != 0 || actual.FileBuildPart != 0) throw new Exception("实际启动版本不符");
            }
            int helperPid = int.Parse(File.ReadAllText(Path.Combine(root, "helper.pid")));
            WaitFor(helperPid, 20000);
            if (Hash(executable) != expected) throw new Exception("新版文件不符");
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
            StopOwned(Path.Combine(root, "helper.pid"), task, "Screenshot.Update.exe");
            try { if (Directory.Exists(task)) Directory.Delete(task, true); } catch (IOException) { }
            try { if (Directory.Exists(root)) Directory.Delete(root, true); } catch (IOException) { }
        }
    }
    // 维护者已授权的隔离 CI 验收：只正常确认当前已校验临时程序，不改变安全策略或复选框。
    static bool ConfirmOwnSource(int pid, string executable, string expectedHash, string helperPath, string helperHash)
    {
        using var helper = Process.GetProcessById(pid);
        bool confirmed = false;
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out uint owner);
            if (owner != pid || !IsWindowVisible(window) || WindowText(window) != "Open File - Security Warning" || WindowClass(window) != "#32770") return true;
            // 先等待实际的来源对话框，再验证文件；复制阶段目标文件仍可能是旧版。
            bool identity = SameFile(helper.MainModule?.FileName, helperPath), helperValid = Hash(helperPath) == helperHash, candidateValid = Hash(executable) == expectedHash;
            if (!identity || !helperValid || !candidateValid)
                throw new Exception($"来源确认的测试进程或文件已变化: identity={identity},helperHash={helperValid},candidateHash={candidateValid}");
            var controls = new List<IntPtr>();
            EnumChildWindows(window, (control, _) => { controls.Add(control); return true; }, IntPtr.Zero);
            if (!controls.Any(c => WindowText(c).Contains("Screenshot.exe", StringComparison.OrdinalIgnoreCase))) return true;
            var buttons = controls.Where(c => WindowClass(c) == "Button" && WindowText(c).Replace("&", "") == "Run").ToArray();
            if (buttons.Length != 1) return true;
            if (Hash(executable) != expectedHash) throw new Exception("来源确认前测试文件发生变化");
            if (SendMessageTimeout(buttons[0], 0xF5, IntPtr.Zero, IntPtr.Zero, 2, 2000, out _) == IntPtr.Zero)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            Console.WriteLine("PASS: normal source confirmation for this verified temporary CI executable only; security settings and checkbox unchanged");
            confirmed = true; return false;
        }, IntPtr.Zero);
        return confirmed;
    }
    // Windows 可能返回 8.3 短路径；文件身份比较比路径字符串更严格且不受别名影响。
    static bool SameFile(string? observed, string expected)
    {
        if (observed == null) return false;
        using var a = File.OpenHandle(observed, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var b = File.OpenHandle(expected, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (!GetFileInformationByHandle(a, out var first) || !GetFileInformationByHandle(b, out var second)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return first.Volume == second.Volume && first.IndexHigh == second.IndexHigh && first.IndexLow == second.IndexLow;
    }
    [StructLayout(LayoutKind.Sequential)] struct FileInformation
    {
        public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle file, out FileInformation information);
    static string WindowText(IntPtr window) { var text = new StringBuilder(2048); GetWindowText(window, text, text.Capacity); return text.ToString(); }
    static string WindowClass(IntPtr window) { var text = new StringBuilder(100); GetClassName(window, text, text.Capacity); return text.ToString(); }
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr window, EnumWindow callback, IntPtr parameter);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    static string HelperWindows(int pid)
    {
        var titles = new List<string>();
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out uint owner);
            if (owner != pid || !IsWindowVisible(window)) return true;
            var title = new StringBuilder(256); GetWindowText(window, title, title.Capacity);
            var type = new StringBuilder(100); GetClassName(window, type, type.Capacity);
            titles.Add(type + ":" + title); return true;
        }, IntPtr.Zero);
        return string.Join(" | ", titles);
    }
    delegate bool EnumWindow(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder text, int count);
    static Process? FindOwnedProcess(string executable)
    {
        Process? found = null;
        foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(executable)))
        {
            try
            {
                if (!process.HasExited && SameFile(process.MainModule?.FileName, executable)) { found = process; continue; }
            }
            catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { }
            process.Dispose();
        }
        return found;
    }
    static string Diagnostic(string root, string task) => string.Join(" | ", new[] { Path.Combine(root, "error.txt"), Path.Combine(task, "failure.txt"), Path.Combine(task, "phase.txt") }.Where(File.Exists).Select(File.ReadAllText).DefaultIfEmpty("无助手错误")) + " | markers=" + string.Join(",", new[] { "ready", "started", "complete" }.Select(n => n + ":" + File.Exists(Path.Combine(task, n))));
    static string Hash(string path) { using var stream = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(stream)); }
    static void WaitFor(int pid, int timeout)
    { try { using var process = Process.GetProcessById(pid); if (!process.WaitForExit(timeout)) throw new Exception("助手未正常退出"); } catch (ArgumentException) { } }
    static void StopOwned(string marker, string directory, string file = "Screenshot.exe")
    {
        try
        {
            if (!File.Exists(marker)) return;
            using var process = Process.GetProcessById(int.Parse(File.ReadAllText(marker)));
            if (SameFile(process.MainModule?.FileName, Path.Combine(directory, file)))
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
