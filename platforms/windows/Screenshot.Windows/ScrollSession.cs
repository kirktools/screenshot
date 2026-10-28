using Screenshot.Core;
namespace Screenshot.Windows;

internal enum FinishMode { Copy, Edit, Save }
internal sealed class ScrollSession : IDisposable
{
    sealed record Segment(Bitmap Image, GrayFrame Anchor);
    readonly Rectangle region; readonly List<Segment> segments = []; readonly StitchTracker tracker = new();
    readonly System.Windows.Forms.Timer timer = new() { Interval = 33 };
    readonly PreviewPanel panel; readonly Boundary boundary; readonly Func<Bitmap, FinishMode, bool> output;
    readonly string layout = DisplayLayout(); bool processing, finishing, disposed, blocked; int height; long bytes;
    internal int CapturedHeight => height;
    internal bool HasUnmatchedFrame => tracker.HasUnmatchedFrame;
    internal Rectangle PreviewBounds => panel.Bounds;
    internal bool Released => disposed && panel.IsDisposed && boundary.IsDisposed && segments.Count == 0;
    internal bool InFlight => processing;
    internal void UndoLast() => Undo();
    public Action? Closed;
    static string DisplayLayout() => string.Join(";", Screen.AllScreens.Select(s => $"{s.DeviceName}:{s.Bounds}"));
    public ScrollSession(Rectangle region, Func<Bitmap, FinishMode, bool> output)
    {
        this.region = region; this.output = output;
        var space = FindPanelSpace(region) ?? throw new InvalidOperationException("选区外没有足够空间显示长图预览。请缩小选区或为预览留出侧边空间。");
        panel = new PreviewPanel(space, DrawPreview);
        panel.Finish += mode => _ = Finish(mode); panel.Cancel += Dispose; panel.Undo += Undo; panel.Retry += Retry;
        boundary = new Boundary(region);
        try
        {
            boundary.Show(); panel.Show();
            if (!Native.SetWindowDisplayAffinity(boundary.Handle, 0x11) || !Native.SetWindowDisplayAffinity(panel.Handle, 0x11)) throw new InvalidOperationException("系统无法排除截图控件，请关闭远程/受保护桌面后重试。");
            timer.Tick += async (_, _) => await Tick(); timer.Start();
        }
        catch { panel.Dispose(); boundary.Dispose(); timer.Dispose(); throw; }
    }
    static Rectangle? FindPanelSpace(Rectangle selection)
    {
        // 控件始终位于选区外；不依赖 GDI 对窗口排除标记的具体实现。
        foreach (var screen in Screen.AllScreens.OrderByDescending(s => s.Bounds.Contains(selection)))
        {
            var work = screen.WorkingArea; int width = Math.Min(340, work.Width), height = Math.Min(500, work.Height);
            Point[] starts = [new(selection.Right + 12, Math.Clamp(selection.Top, work.Top, work.Bottom - height)), new(selection.Left - width - 12, Math.Clamp(selection.Top, work.Top, work.Bottom - height)), new(work.Left, work.Top), new(work.Right - width, work.Bottom - height)];
            foreach (var point in starts) { var candidate = new Rectangle(point, new(width, height)); if (work.Contains(candidate) && !candidate.IntersectsWith(selection)) return candidate; }
        }
        return null;
    }
    async Task Tick()
    {
        if (processing || finishing || disposed || blocked) return;
        if (layout != DisplayLayout()) { blocked = true; panel.Error = "显示器布局已变化，请完成已有部分或取消后重新框选。"; return; }
        processing = true;
        try
        {
            var capture = await Task.Run(() =>
            {
                var bitmap = Capture.ScreenImage(region);
                try { return (Bitmap: bitmap, Gray: Capture.Gray(bitmap)); } catch { bitmap.Dispose(); throw; }
            });
            using var image = capture.Bitmap;
            if (disposed) return;
            if (layout != DisplayLayout()) { blocked = true; panel.Error = "显示器布局已变化，请重新框选。"; return; }
            var result = await Task.Run(() => tracker.Consume(capture.Gray, Environment.TickCount64 / 1000d));
            if (disposed) return;
            if (result.Kind is TrackingKind.Seed or TrackingKind.Append)
            {
                int rows = result.Kind == TrackingKind.Seed ? image.Height : result.Match.Rows;
                long addition = (long)image.Width * rows * 4 + capture.Gray.Pixels.Length;
                if (height + rows > 30000 || (long)(height + rows) * image.Width > Capture.MaximumPixels || bytes + addition > 128L * 1024 * 1024)
                { blocked = true; tracker.Reset(segments.LastOrDefault()?.Anchor); panel.Error = "已达到长图资源上限。请完成已有部分，或撤销上一段。"; return; }
                var strip = Capture.Crop(image, new(0, image.Height - rows, image.Width, rows));
                segments.Add(new(strip, capture.Gray)); height += rows; bytes += addition;
                panel.Error = null; panel.RefreshImage();
            }
            else if (result.Kind == TrackingKind.Duplicate) panel.Error = null;
            else if (result.Kind == TrackingKind.Paused) panel.Error = result.Match.Kind == MatchKind.Reverse ? "检测到向上滚动。请回到预览末尾附近，向下滚动接续。" : "暂时无法可靠接续，请回到预览末尾附近；也可重试或撤销。";
        }
        catch (Exception) { if (!disposed) { blocked = true; panel.Error = "屏幕读取失败。请检查桌面是否锁定、目标是否受保护；可完成已有部分或取消。"; } }
        finally { processing = false; }
    }
    void DrawPreview(Graphics g, Rectangle viewport, int scrollOffset)
    {
        if (segments.Count == 0) return;
        float scale = (float)viewport.Width / region.Width;
        float full = height * scale;
        float top = scrollOffset < 0 ? Math.Min(0, viewport.Height - full) : Math.Clamp(-scrollOffset, Math.Min(0, viewport.Height - full), 0);
        foreach (var segment in segments)
        {
            float h = segment.Image.Height * scale;
            if (top + h >= 0 && top < viewport.Height) g.DrawImage(segment.Image, 0, top, viewport.Width, h);
            top += h;
        }
    }
    public async Task Finish(FinishMode mode)
    {
        if (disposed || finishing) return; finishing = true; timer.Stop();
        while (processing) await Task.Delay(15);
        if (disposed) return;
        if (segments.Count == 0) { panel.Error = "尚无已捕获内容，请稍后再完成。"; finishing = false; timer.Start(); return; }
        if ((tracker.HasUnmatchedFrame || blocked) && MessageBox.Show(panel, "末尾尚未可靠接续。仅导出预览中已确认的内容？", "确认长图范围", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK)
        { finishing = false; timer.Start(); return; }
        try
        {
            using var result = new Bitmap(region.Width, height); using (var g = Graphics.FromImage(result)) { int y = 0; foreach (var s in segments) { Capture.DrawPixels(g, s.Image, 0, y); y += s.Image.Height; } }
            if (output(result, mode)) Dispose(); else { finishing = false; timer.Start(); }
        }
        catch { panel.Error = "导出失败，请关闭占用剪贴板的程序或释放内存后重试。"; finishing = false; timer.Start(); }
    }
    void Undo()
    {
        if (processing || finishing || segments.Count < 2) return;
        var last = segments[^1]; segments.RemoveAt(segments.Count - 1); height -= last.Image.Height; bytes -= (long)last.Image.Width * last.Image.Height * 4 + last.Anchor.Pixels.Length; last.Image.Dispose();
        tracker.Reset(segments[^1].Anchor); blocked = false; panel.Error = "已撤销。请回到预览末尾附近继续滚动。"; panel.RefreshImage();
    }
    void Retry() { if (processing || finishing) return; tracker.Reset(segments.LastOrDefault()?.Anchor); blocked = false; panel.Error = "请回到预览末尾附近，向下滚动接续。"; }
    public void Dispose()
    {
        if (disposed) return; disposed = true; timer.Stop(); timer.Dispose(); panel.Dispose(); boundary.Dispose();
        // 处理中结果不会再写入列表；Bitmap/GrayFrame 由该帧自己的 finally 释放。
        foreach (var segment in segments) segment.Image.Dispose(); segments.Clear(); Closed?.Invoke();
    }
}
internal sealed class Boundary : Form
{
    public Boundary(Rectangle region)
    {
        FormBorderStyle = FormBorderStyle.None; StartPosition = FormStartPosition.Manual; Bounds = Rectangle.Inflate(region, 2, 2);
        AutoScaleMode = AutoScaleMode.None; ShowInTaskbar = false; TopMost = true; BackColor = Color.Magenta; TransparencyKey = Color.Magenta;
    }
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x20 | 0x80; return p; } }
    protected override void OnPaint(PaintEventArgs e) { using var brush = new SolidBrush(Color.Turquoise); e.Graphics.FillRectangles(brush, [new(0, 0, Width, 2), new(0, Height - 2, Width, 2), new(0, 0, 2, Height), new(Width - 2, 0, 2, Height)]); }
}
internal sealed class PreviewPanel : Form
{
    readonly PreviewCanvas canvas; readonly Label error; readonly ToolTip tips = new();
    public event Action<FinishMode>? Finish; public event Action? Cancel, Undo, Retry;
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public string? Error { set { error.Text = value ?? ""; error.Visible = !string.IsNullOrEmpty(value); error.BringToFront(); } }
    public PreviewPanel(Rectangle bounds, Action<Graphics, Rectangle, int> draw)
    {
        SetStyle(ControlStyles.Selectable, false); TabStop = false;
        FormBorderStyle = FormBorderStyle.None; Text = "滚动长截图"; StartPosition = FormStartPosition.Manual; Bounds = bounds; AutoScaleMode = AutoScaleMode.None; ShowInTaskbar = false; TopMost = true; ControlBox = false;
        canvas = new PreviewCanvas(draw) { Dock = DockStyle.Fill }; Controls.Add(canvas);
        var tools = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 48, Padding = new(4), WrapContents = false }; Controls.Add(tools);
        void Button(string title, string hint, Action action) { var b = new NoFocusButton { Text = title, Width = 49, Height = 34 }; b.Click += (_, _) => action(); tips.SetToolTip(b, hint); tools.Controls.Add(b); }
        Button("✓", "完成并复制（回车）", () => Finish?.Invoke(FinishMode.Copy)); Button("✎", "编辑长图", () => Finish?.Invoke(FinishMode.Edit)); Button("↓", "复制并保存 PNG", () => Finish?.Invoke(FinishMode.Save));
        var menu = new ContextMenuStrip(); menu.Items.Add("重试", null, (_, _) => Retry?.Invoke()); menu.Items.Add("撤销上一段", null, (_, _) => Undo?.Invoke()); menu.Items.Add("跟随末尾", null, (_, _) => canvas.Follow());
        Button("…", "更多操作", () => menu.Show(tools, new Point(0, tools.Height))); Button("×", "取消（Esc）", () => Cancel?.Invoke());
        error = new Label { AutoSize = false, Bounds = new(8, 8, Math.Max(100, ClientSize.Width - 16), 78), BackColor = Color.FromArgb(255, 245, 215), ForeColor = Color.Black, Padding = new(8), Visible = false }; canvas.Controls.Add(error);
        FormClosed += (_, _) => menu.Dispose();
    }
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80; return p; } }
    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x21) { message.Result = (IntPtr)3; return; } // MA_NOACTIVATE：保留按钮点击，不激活窗口。
        base.WndProc(ref message);
    }
    public void RefreshImage() => canvas.Invalidate();
    protected override void Dispose(bool disposing) { if (disposing) tips.Dispose(); base.Dispose(disposing); }
}
internal sealed class NoFocusButton : Button
{
    public NoFocusButton() { SetStyle(ControlStyles.Selectable, false); TabStop = false; }
}
internal sealed class PreviewCanvas : Control
{
    readonly Action<Graphics, Rectangle, int> draw;
    public PreviewCanvas(Action<Graphics, Rectangle, int> draw) { this.draw = draw; DoubleBuffered = true; ResizeRedraw = true; SetStyle(ControlStyles.Selectable, false); TabStop = false; }
    int offset = -1;
    protected override void OnPaint(PaintEventArgs e) { e.Graphics.Clear(Color.FromArgb(35, 35, 35)); draw(e.Graphics, ClientRectangle, offset); }
    protected override void OnMouseWheel(MouseEventArgs e) { offset = Math.Max(0, (offset < 0 ? 0 : offset) - e.Delta); Invalidate(); }
    public void Follow() { offset = -1; Invalidate(); }
}
