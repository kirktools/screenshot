using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Screenshot.Adapters;
namespace Screenshot.Windows;

internal static class Capture
{
    // 显式指定源/目标像素，避免 GDI+ 按显示器 DPI 缩放冻结画面与导出图像。
    public static void DrawPixels(Graphics graphics, Bitmap image, int x = 0, int y = 0) =>
        graphics.DrawImage(image, new Rectangle(x, y, image.Width, image.Height), new Rectangle(Point.Empty, image.Size), GraphicsUnit.Pixel);
    public const long MaximumPixels = 24_000_000;
    public static Bitmap ScreenImage(Rectangle region)
    {
        if (region.Width < 1 || region.Height < 1 || (long)region.Width * region.Height > MaximumPixels) throw new InvalidOperationException("选区超过 2400 万像素，请缩小区域");
        var image = new Bitmap(region.Width, region.Height, PixelFormat.Format32bppRgb);
        try
        {
            using var g = Graphics.FromImage(image);
            IntPtr screen = GetDC(IntPtr.Zero), target = IntPtr.Zero;
            if (screen == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                target = g.GetHdc();
                // CAPTUREBLT 包含 tooltip 等分层窗口；CopyFromScreen 不接受组合操作码。
                if (!BitBlt(target, 0, 0, region.Width, region.Height, screen, region.X, region.Y, 0x40CC0020))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { if (target != IntPtr.Zero) g.ReleaseHdc(target); ReleaseDC(IntPtr.Zero, screen); }
            return image;
        }
        catch { image.Dispose(); throw; }
    }
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("gdi32.dll", SetLastError = true)] static extern bool BitBlt(IntPtr target, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, uint operation);
    public static GrayFrame Gray(Bitmap image)
    {
        int width = Math.Min(128, image.Width); var pixels = new byte[width * image.Height];
        var data = image.LockBits(new(Point.Empty, image.Size), ImageLockMode.ReadOnly, image.PixelFormat);
        try
        {
            var row = new byte[Math.Abs(data.Stride)];
            for (int y = 0; y < image.Height; y++)
            {
                Marshal.Copy(data.Scan0 + y * data.Stride, row, 0, row.Length);
                for (int x = 0; x < width; x++) { int offset = (int)((long)x * image.Width / width) * 4; pixels[y * width + x] = (byte)((row[offset + 2] * 77 + row[offset + 1] * 150 + row[offset] * 29) >> 8); }
            }
        }
        finally { image.UnlockBits(data); }
        return new(width, image.Height, pixels, image.Width);
    }
    public static Bitmap Crop(Bitmap source, Rectangle area) => source.Clone(area, PixelFormat.Format32bppArgb);
}
