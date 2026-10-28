using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Screenshot.Core;
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
        try { using var g = Graphics.FromImage(image); g.CopyFromScreen(region.Location, Point.Empty, region.Size, CopyPixelOperation.SourceCopy); return image; }
        catch { image.Dispose(); throw; }
    }
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
internal sealed class Selection : Form
{
    readonly Bitmap frozen; readonly Rectangle desktop; Point start; Rectangle region; bool dragging;
    readonly bool scrolling;
    public event Action<Rectangle, Bitmap?>? Selected;
    public Selection(bool scrolling)
    {
        this.scrolling = scrolling; desktop = SystemInformation.VirtualScreen;
        // 在创建遮罩、更改光标或激活窗口前冻结画面，保留原应用的悬停提示。
        frozen = Screenshot.Windows.Capture.ScreenImage(desktop);
        FormBorderStyle = FormBorderStyle.None; StartPosition = FormStartPosition.Manual; Bounds = desktop;
        AutoScaleMode = AutoScaleMode.None; TopMost = true; ShowInTaskbar = false; DoubleBuffered = true; Cursor = Cursors.Cross; KeyPreview = true;
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        Screenshot.Windows.Capture.DrawPixels(e.Graphics, frozen);
        using (var shade = new SolidBrush(Color.FromArgb(115, 0, 0, 0))) e.Graphics.FillRectangle(shade, ClientRectangle);
        if (region.Width > 0 && region.Height > 0)
        {
            e.Graphics.DrawImage(frozen, region, region, GraphicsUnit.Pixel);
            using var pen = new Pen(Color.Turquoise, 2); e.Graphics.DrawRectangle(pen, region);
        }
        TextRenderer.DrawText(e.Graphics, scrolling ? "框选单一滚动正文区域 · Esc 取消" : "拖动框选 · Esc 取消", Font, new Point(24, 24), Color.White, Color.FromArgb(40, 40, 40));
    }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button != MouseButtons.Left) return; start = e.Location; dragging = true; Capture = true; }
    protected override void OnMouseMove(MouseEventArgs e) { if (dragging) { region = Rectangle.FromLTRB(Math.Min(start.X, e.X), Math.Min(start.Y, e.Y), Math.Max(start.X, e.X), Math.Max(start.Y, e.Y)); region = Rectangle.Intersect(region, ClientRectangle); Invalidate(); } }
    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (!dragging) return; dragging = false; Capture = false;
        if (region.Width < 32 || region.Height < 80) { Invalidate(); return; }
        var screen = new Rectangle(region.X + desktop.X, region.Y + desktop.Y, region.Width, region.Height);
        if (scrolling && !System.Windows.Forms.Screen.AllScreens.Any(s => s.Bounds.Contains(screen))) { MessageBox.Show(this, "长截图选区需位于同一块屏幕内。", "请重新框选"); return; }
        var result = scrolling ? null : Screenshot.Windows.Capture.Crop(frozen, region);
        Hide(); Selected?.Invoke(screen, result); Close();
    }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Close(); base.OnKeyDown(e); }
    protected override void Dispose(bool disposing) { if (disposing) frozen.Dispose(); base.Dispose(disposing); }
}
