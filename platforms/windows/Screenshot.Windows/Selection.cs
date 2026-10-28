namespace Screenshot.Windows;

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
        if (region.Width < (scrolling ? 32 : 2) || region.Height < (scrolling ? 80 : 2)) { Invalidate(); return; }
        var screen = new Rectangle(region.X + desktop.X, region.Y + desktop.Y, region.Width, region.Height);
        if (scrolling && !System.Windows.Forms.Screen.AllScreens.Any(s => s.Bounds.Contains(screen))) { MessageBox.Show(this, "长截图选区需位于同一块屏幕内。", "请重新框选"); return; }
        var result = scrolling ? null : Screenshot.Windows.Capture.Crop(frozen, region);
        Hide(); Selected?.Invoke(screen, result); Close();
    }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Close(); base.OnKeyDown(e); }
    protected override void Dispose(bool disposing) { if (disposing) frozen.Dispose(); base.Dispose(disposing); }
}
