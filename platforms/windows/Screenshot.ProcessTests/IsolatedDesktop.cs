using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace Screenshot.ProcessTests;

// 仅供隔离 CI：在临时 Win32 桌面显示合成窗口，避免 runner 的首次设置页面遮挡。
// 整个测试进程（含采集线程）绑定临时桌面，不关闭其他窗口、不修改系统设置。
internal static class IsolatedDesktop
{
    public static int Run(string executable, string[] arguments)
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true") return 1;
        IntPtr original = OpenInputDesktop(0, false, 0x100);
        if (original == IntPtr.Zero) { Console.Error.WriteLine("Cannot open CI input desktop: " + Marshal.GetLastWin32Error()); return 77; }
        string name = "ScreenshotTest-" + Guid.NewGuid().ToString("N");
        IntPtr desktop = CreateDesktop(name, IntPtr.Zero, IntPtr.Zero, 0, 0x1C7, IntPtr.Zero);
        if (desktop == IntPtr.Zero) { CloseDesktop(original); Console.Error.WriteLine("Cannot create isolated CI desktop: " + Marshal.GetLastWin32Error()); return 77; }
        IntPtr child = IntPtr.Zero; bool switched = false;
        try
        {
            if (!SwitchDesktop(desktop)) throw new Win32Exception(Marshal.GetLastWin32Error());
            switched = true;
            var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>(), Desktop = @"winsta0\" + name, Flags = 0x100, Input = GetStdHandle(-10), Output = GetStdHandle(-11), Error = GetStdHandle(-12) };
            if (!CreateProcess(executable, new StringBuilder(string.Join(" ", new[] { executable }.Concat(arguments).Select(Quote))), IntPtr.Zero, IntPtr.Zero, true, 0, IntPtr.Zero, null, ref startup, out var process))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            child = process.Process; CloseHandle(process.Thread);
            uint wait = WaitForSingleObject(child, 240000);
            if (wait != 0) { TerminateProcess(child, 1); WaitForSingleObject(child, 5000); Console.Error.WriteLine("Isolated desktop test did not finish: " + wait); return 1; }
            if (!GetExitCodeProcess(child, out uint code)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return (int)code;
        }
        catch (Win32Exception error) { Console.Error.WriteLine("ISOLATED DESKTOP FAILED: " + error.NativeErrorCode); return 77; }
        finally
        {
            if (child != IntPtr.Zero) CloseHandle(child);
            if (switched && !SwitchDesktop(original)) Console.Error.WriteLine("Failed to restore CI desktop: " + Marshal.GetLastWin32Error());
            CloseDesktop(desktop); CloseDesktop(original);
        }
    }
    static string Quote(string value)
    {
        var result = new StringBuilder("\""); int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { result.Append('\\', slashes * 2 + 1).Append(c); slashes = 0; continue; }
            result.Append('\\', slashes).Append(c); slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }
    public static string CurrentPath
    {
        get
        {
            var name = new StringBuilder(256);
            if (!GetUserObjectInformation(GetThreadDesktop(GetCurrentThreadId()), 2, name, name.Capacity * 2, out _)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return @"winsta0\" + name;
        }
    }
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder value, int bytes, out int needed);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct StartupInfo
    {
        public int Size; public string? Reserved, Desktop, Title;
        public int X, Y, XSize, YSize, XChars, YChars, Fill, Flags; public short Show, ReservedSize;
        public IntPtr ReservedPointer, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr mode, uint flags, uint access, IntPtr attributes);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SwitchDesktop(IntPtr desktop);
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string? directory, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int kind);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint code);
}
