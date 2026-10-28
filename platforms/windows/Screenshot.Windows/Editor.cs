using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
namespace Screenshot.Windows;

internal enum Tool { Crop, Arrow, Rectangle, Ellipse, Text, Redact }
internal sealed record Mark(Tool Tool, Point Start, Point End, Color Color, int Width, string Text = "");
internal sealed record EditState(Rectangle Crop, Mark[] Marks);
internal sealed class EditDocument(Bitmap image) : IDisposable
{
    public Bitmap Image { get; } = image;
    readonly List<EditState> history = [new(new(Point.Empty, image.Size), [])]; int index;
    public EditState State => history[index];
    public void Apply(EditState state) { history.RemoveRange(index + 1, history.Count - index - 1); history.Add(state); if (history.Count > 31) history.RemoveAt(0); index = history.Count - 1; }
    public void Undo() { if (index > 0) index--; }
    public void Redo() { if (index + 1 < history.Count) index++; }
    public Bitmap Render()
    {
        var output = new Bitmap(State.Crop.Width, State.Crop.Height, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(output); g.TranslateTransform(-State.Crop.X, -State.Crop.Y); Paint(g, State); return output;
    }
    public void Paint(Graphics g, EditState state)
    {
        g.DrawImageUnscaled(Image, Point.Empty); g.SmoothingMode = SmoothingMode.AntiAlias;
        foreach (var mark in state.Marks) Draw(g, mark);
    }
    public static Rectangle Area(Point a, Point b) => Rectangle.FromLTRB(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));
    public static void Draw(Graphics g, Mark mark)
    {
        var rect = Area(mark.Start, mark.End);
        if (mark.Tool is Tool.Rectangle or Tool.Ellipse or Tool.Redact && (rect.Width < 1 || rect.Height < 1)) return;
        using var pen = new Pen(mark.Color, mark.Width);
        switch (mark.Tool)
        {
            case Tool.Arrow:
                using (var cap = new AdjustableArrowCap(4, 5, true)) { pen.CustomEndCap = cap; g.DrawLine(pen, mark.Start, mark.End); }
                break;
            case Tool.Rectangle: g.DrawRectangle(pen, rect); break;
            case Tool.Ellipse: g.DrawEllipse(pen, rect); break;
            case Tool.Redact:
                // 打码直接进入最终像素，不导出原图、历史或可撤销图层。
                g.SmoothingMode = SmoothingMode.None; g.FillRectangle(Brushes.Black, rect); g.SmoothingMode = SmoothingMode.AntiAlias; break;
            case Tool.Text:
                using (var brush = new SolidBrush(mark.Color)) using (var font = new Font("Microsoft YaHei UI", Math.Max(14, mark.Width * 7), GraphicsUnit.Pixel)) g.DrawString(mark.Text, font, brush, mark.Start); break;
        }
    }
    public void Dispose() => Image.Dispose();
}
internal sealed class EditCanvas : Control
{
    readonly EditDocument document; Point start, current; bool drawing; float scale = 1;
    public Tool Tool = Tool.Arrow; public Color Ink = Color.Red; public int LineWidth = 3;
    public event Action? Changed;
    public EditCanvas(EditDocument document)
    {
        this.document = document; DoubleBuffered = true; Cursor = Cursors.Cross; TabStop = true;
    }
    public void Fit(int width)
    { scale = Math.Min(1f, (float)Math.Max(100, width) / document.State.Crop.Width); Size = new(Math.Max(1, (int)(document.State.Crop.Width * scale)), Math.Max(1, (int)(document.State.Crop.Height * scale))); Invalidate(); }
    Point Pixel(Point location) => new(Math.Clamp((int)(location.X / scale) + document.State.Crop.X, document.State.Crop.Left, document.State.Crop.Right - 1), Math.Clamp((int)(location.Y / scale) + document.State.Crop.Y, document.State.Crop.Top, document.State.Crop.Bottom - 1));
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(Color.White); e.Graphics.ScaleTransform(scale, scale); e.Graphics.TranslateTransform(-document.State.Crop.X, -document.State.Crop.Y);
        document.Paint(e.Graphics, document.State);
        if (drawing)
        {
            var mark = new Mark(Tool, start, current, Ink, LineWidth);
            if (Tool == Tool.Crop) { using var pen = new Pen(Color.Turquoise, 2 / scale); e.Graphics.DrawRectangle(pen, EditDocument.Area(start, current)); }
            else EditDocument.Draw(e.Graphics, mark);
        }
    }
    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return; Focus(); start = current = Pixel(e.Location);
        if (Tool == Tool.Text)
        {
            using var prompt = new Form { Text = "输入文字", Size = new(390, 160), StartPosition = FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false, FormBorderStyle = FormBorderStyle.FixedDialog };
            var field = new TextBox { Dock = DockStyle.Top, Margin = new(12) }; var ok = new Button { Text = "确定", Dock = DockStyle.Bottom, DialogResult = DialogResult.OK }; prompt.Controls.Add(field); prompt.Controls.Add(ok); prompt.AcceptButton = ok;
            if (prompt.ShowDialog(FindForm()) == DialogResult.OK && !string.IsNullOrWhiteSpace(field.Text)) document.Apply(document.State with { Marks = [.. document.State.Marks, new(Tool, start, start, Ink, LineWidth, field.Text)] });
            Invalidate(); Changed?.Invoke(); return;
        }
        drawing = true; Capture = true;
    }
    protected override void OnMouseMove(MouseEventArgs e) { if (drawing) { current = Pixel(e.Location); Invalidate(); } }
    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (!drawing) return; current = Pixel(e.Location); drawing = false; Capture = false; var rect = EditDocument.Area(start, current);
        if (Tool == Tool.Crop)
        { if (rect.Width >= 8 && rect.Height >= 8) document.Apply(document.State with { Crop = Rectangle.Intersect(rect, document.State.Crop) }); }
        else if (rect.Width + rect.Height >= 3) document.Apply(document.State with { Marks = [.. document.State.Marks, new(Tool, start, current, Ink, LineWidth)] });
        Changed?.Invoke(); Invalidate();
    }
}
internal sealed class Editor : Form
{
    readonly EditDocument document; readonly EditCanvas canvas; readonly Panel viewport; readonly ToolTip tips = new();
    public Editor(Bitmap image)
    {
        document = new(image); Text = "Screenshot · 编辑"; StartPosition = FormStartPosition.CenterScreen; Size = new(1040, 760); MinimumSize = new(700, 400); KeyPreview = true;
        var tools = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 82, AutoSize = false, Padding = new(5), WrapContents = true }; Controls.Add(tools);
        viewport = new Panel { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Color.FromArgb(40, 40, 40) }; Controls.Add(viewport); viewport.BringToFront();
        canvas = new(document); viewport.Controls.Add(canvas);
        foreach (var pair in new[] { (Tool.Crop, "裁剪"), (Tool.Arrow, "箭头"), (Tool.Rectangle, "矩形"), (Tool.Ellipse, "圆形"), (Tool.Text, "文字"), (Tool.Redact, "打码") })
        {
            var button = new RadioButton { Text = pair.Item2, Appearance = Appearance.Button, AutoSize = true, Checked = pair.Item1 == Tool.Arrow }; button.CheckedChanged += (_, _) => { if (button.Checked) canvas.Tool = pair.Item1; }; tools.Controls.Add(button);
        }
        void Button(string title, Action action) { var b = new Button { Text = title, AutoSize = true }; b.Click += (_, _) => action(); tools.Controls.Add(b); }
        Button("颜色", () => { using var dialog = new ColorDialog { Color = canvas.Ink }; if (dialog.ShowDialog(this) == DialogResult.OK) canvas.Ink = dialog.Color; });
        var width = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 65 }; width.Items.AddRange(["细", "中", "粗"]); width.SelectedIndex = 1; width.SelectedIndexChanged += (_, _) => canvas.LineWidth = new[] { 2, 4, 8 }[width.SelectedIndex]; canvas.LineWidth = 4; tools.Controls.Add(width); tips.SetToolTip(width, "线宽（原图像素）");
        Button("撤销", () => { document.Undo(); Fit(); }); Button("重做", () => { document.Redo(); Fit(); }); Button("复制", () => Copy(false)); Button("保存 PNG", Save); Button("✓ 完成", () => Copy(true)); Button("× 取消", Close);
        canvas.Changed += Fit; viewport.Resize += (_, _) => Fit(); Shown += (_, _) => Fit();
    }
    void Fit() { canvas.Fit(viewport.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 2); }
    static void ClipboardImage(Bitmap image)
    {
        // 同时提供 PNG 和位图格式；两者均仅包含已渲染后的像素。
        using var stream = new MemoryStream(); image.Save(stream, ImageFormat.Png);
        var data = new DataObject(); data.SetData("PNG", false, new MemoryStream(stream.ToArray())); data.SetData(DataFormats.Bitmap, true, image);
        Clipboard.SetDataObject(data, true, 5, 80);
    }
    public static void CopyImage(Bitmap image) => ClipboardImage(image);
    void Copy(bool close)
    {
        try { using var result = document.Render(); ClipboardImage(result); if (close) Close(); }
        catch (Exception) { MessageBox.Show(this, "剪贴板暂时不可用，请关闭占用程序后重试。", "复制失败"); }
    }
    public static void SaveImage(IWin32Window? owner, Bitmap image)
    {
        using var dialog = new SaveFileDialog { Filter = "PNG 图片|*.png", DefaultExt = "png", AddExtension = true, FileName = $"Screenshot-{DateTime.Now:yyyyMMdd-HHmmss}.png" };
        if (dialog.ShowDialog(owner) == DialogResult.OK) image.Save(dialog.FileName, ImageFormat.Png);
    }
    void Save() { try { using var result = document.Render(); SaveImage(this, result); } catch (Exception) { MessageBox.Show(this, "无法保存 PNG，请检查目录写入权限。", "保存失败"); } }
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        switch (keyData)
        {
            case Keys.Enter: Copy(true); return true;
            case Keys.Escape: Close(); return true;
            case Keys.Control | Keys.C: Copy(false); return true;
            case Keys.Control | Keys.S: Save(); return true;
            case Keys.Control | Keys.Z: document.Undo(); Fit(); return true;
            case Keys.Control | Keys.Shift | Keys.Z: document.Redo(); Fit(); return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }
    protected override void Dispose(bool disposing) { if (disposing) { document.Dispose(); tips.Dispose(); } base.Dispose(disposing); }
}
