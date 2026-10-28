using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Screenshot.Windows;

// 仅供隔离 CI：在临时 Win32 桌面显示合成窗口，避免 runner 的首次设置页面遮挡。
// 不关闭其他窗口、不修改系统设置；结束时恢复原桌面并关闭临时桌面。
internal static class TestDesktop
{
    public static int Run(Func<int> test)
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true") return 1;
        IntPtr original = OpenInputDesktop(0, false, 0x100);
        if (original == IntPtr.Zero) { Console.Error.WriteLine("Cannot open CI input desktop: " + Marshal.GetLastWin32Error()); return 77; }
        IntPtr desktop = CreateDesktop("ScreenshotTest-" + Guid.NewGuid().ToString("N"), IntPtr.Zero, IntPtr.Zero, 0, 0x1C7, IntPtr.Zero);
        if (desktop == IntPtr.Zero) { CloseDesktop(original); Console.Error.WriteLine("Cannot create isolated CI desktop: " + Marshal.GetLastWin32Error()); return 77; }
        int result = 1; bool switched = false;
        try
        {
            if (!SwitchDesktop(desktop)) throw new Win32Exception(Marshal.GetLastWin32Error());
            switched = true;
            var thread = new Thread(() =>
            {
                try
                {
                    if (!SetThreadDesktop(desktop)) throw new Win32Exception(Marshal.GetLastWin32Error());
                    result = test();
                }
                catch (Exception error) { Console.Error.WriteLine("ISOLATED DESKTOP FAILED: " + error.Message); }
            }) { IsBackground = true };
            thread.SetApartmentState(ApartmentState.STA); thread.Start();
            if (!thread.Join(TimeSpan.FromMinutes(4))) { Console.Error.WriteLine("Isolated desktop test timed out"); return 1; }
            return result;
        }
        catch (Win32Exception error) { Console.Error.WriteLine("ISOLATED DESKTOP FAILED: " + error.NativeErrorCode); return 77; }
        finally
        {
            if (switched && !SwitchDesktop(original)) Console.Error.WriteLine("Failed to restore CI desktop: " + Marshal.GetLastWin32Error());
            CloseDesktop(desktop); CloseDesktop(original);
        }
    }
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr mode, uint flags, uint access, IntPtr attributes);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetThreadDesktop(IntPtr desktop);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SwitchDesktop(IntPtr desktop);
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr desktop);
}
