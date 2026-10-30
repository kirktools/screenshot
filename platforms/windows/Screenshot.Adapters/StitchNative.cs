using System.Runtime.InteropServices;
namespace Screenshot.Adapters;

internal sealed class StitchHandle : SafeHandle
{
    public StitchHandle() : base(IntPtr.Zero, true) { SetHandle(StitchNative.Create()); if (IsInvalid) throw new InvalidOperationException("无法创建共享拼接会话"); }
    public override bool IsInvalid => handle == IntPtr.Zero;
    protected override bool ReleaseHandle() { StitchNative.Destroy(handle); return true; }
}
internal static class StitchNative
{
    const string Library = "StitchCoreABI";
    static readonly IntPtr loaded;
    static StitchNative()
    {
        string name = OperatingSystem.IsWindows() ? Library + ".dll" : OperatingSystem.IsMacOS() ? "lib" + Library + ".dylib" : "lib" + Library + ".so";
        loaded = NativeLibrary.Load(Path.Combine(AppContext.BaseDirectory, name), typeof(StitchNative).Assembly, DllImportSearchPath.SafeDirectories | DllImportSearchPath.UseDllDirectoryForDependencies);
        NativeLibrary.SetDllImportResolver(typeof(StitchNative).Assembly, (name, _, _) => name == Library ? loaded : IntPtr.Zero);
        if (Version() != 1) throw new InvalidDataException("共享拼接核心 ABI 版本不兼容");
    }
    [DllImport(Library, EntryPoint = "screenshot_stitch_abi_version", CallingConvention = CallingConvention.Cdecl)] internal static extern int Version();
    [DllImport(Library, EntryPoint = "screenshot_stitch_match", CallingConvention = CallingConvention.Cdecl)] internal static extern int Match(byte[] a, int an, int aw, int ah, int asw, byte[] b, int bn, int bw, int bh, int bsw, out int rows);
    [DllImport(Library, EntryPoint = "screenshot_stitch_difference", CallingConvention = CallingConvention.Cdecl)] internal static extern double Difference(byte[] a, int an, int aw, int ah, int asw, byte[] b, int bn, int bw, int bh, int bsw);
    [DllImport(Library, EntryPoint = "screenshot_stitch_tracker_create", CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr Create();
    [DllImport(Library, EntryPoint = "screenshot_stitch_tracker_destroy", CallingConvention = CallingConvention.Cdecl)] internal static extern void Destroy(IntPtr handle);
    [DllImport(Library, EntryPoint = "screenshot_stitch_tracker_unmatched", CallingConvention = CallingConvention.Cdecl)] internal static extern int Unmatched(StitchHandle handle);
    [DllImport(Library, EntryPoint = "screenshot_stitch_tracker_reset", CallingConvention = CallingConvention.Cdecl)] internal static extern int Reset(StitchHandle handle, byte[]? bytes, int count, int width, int height, int sourceWidth);
    [DllImport(Library, EntryPoint = "screenshot_stitch_tracker_consume", CallingConvention = CallingConvention.Cdecl)] internal static extern int Consume(StitchHandle handle, byte[] bytes, int count, int width, int height, int sourceWidth, double time, out int match, out int rows);
}
