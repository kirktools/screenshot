using System.Runtime.InteropServices;
namespace Screenshot.Windows;

internal static class Native
{
    public const int WmHotkey = 0x0312;
    [DllImport("user32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] public static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr window, int id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowDisplayAffinity(IntPtr window, uint affinity);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
}
internal sealed class Hotkeys : NativeWindow, IDisposable
{
    public event Action<int>? Triggered;
    public Hotkeys() { CreateHandle(new CreateParams()); }
    public bool Register(int id, Shortcut value) => Native.RegisterHotKey(Handle, id, value.Modifiers | 0x4000, (uint)value.Key);
    public void Remove(int id) => Native.UnregisterHotKey(Handle, id);
    protected override void WndProc(ref Message m) { if (m.Msg == Native.WmHotkey) Triggered?.Invoke(m.WParam.ToInt32()); base.WndProc(ref m); }
    public void Dispose() { foreach (int id in new[] { 1, 2, 3, 4 }) Remove(id); DestroyHandle(); }
}
internal sealed record Shortcut(uint Modifiers, Keys Key)
{
    public override string ToString() => string.Join(" + ", new[] { (Modifiers & 2) != 0 ? "Ctrl" : null, (Modifiers & 1) != 0 ? "Alt" : null, (Modifiers & 4) != 0 ? "Shift" : null, (Modifiers & 8) != 0 ? "Win" : null, Key.ToString() }.Where(x => x != null));
    public static Shortcut From(Keys data) => new(((data & Keys.Control) != 0 ? 2u : 0) | ((data & Keys.Alt) != 0 ? 1u : 0) | ((data & Keys.Shift) != 0 ? 4u : 0), data & Keys.KeyCode);
}
internal sealed record Preferences(Shortcut Region, Shortcut Scroll)
{
    public static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Profile.Name.Replace(" ", ""));
    static string FileName => Path.Combine(Folder, "settings.json");
    public static Preferences Default => new(new(Profile.Development ? 2u | 1u : 2u | 4u, Keys.D2), new(Profile.Development ? 2u | 1u : 2u | 4u, Keys.D7));
    public static Preferences Load() { try { return System.Text.Json.JsonSerializer.Deserialize<Preferences>(File.ReadAllText(FileName)) ?? Default; } catch { return Default; } }
    public void Save() { Directory.CreateDirectory(Folder); string temp = FileName + ".tmp"; File.WriteAllText(temp, System.Text.Json.JsonSerializer.Serialize(this)); File.Move(temp, FileName, true); }
}

internal static class Profile
{
#if DEVELOPMENT
    public static bool Development=>true;
    public static string Name=>"Screenshot Dev";
#else
    public static bool Development => false;
    public static string Name => "Screenshot";
#endif
}
