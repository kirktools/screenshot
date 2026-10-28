using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Screenshot.Adapters;
namespace Screenshot.Windows;

// 仅在隔离 CI 桌面运行：只读取自身生成的无敏感内容窗口，不导出真实桌面帧。
internal static class DesktopSelfTest
{
    public static int Run()
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true")
        { Console.Error.WriteLine("桌面回归仅在隔离 CI 上执行；本机请按 Windows 验收文档操作。"); return 1; }
        var work = Screen.PrimaryScreen?.WorkingArea ?? Rectangle.Empty;
        if (!Environment.UserInteractive || work.Width < 640 || work.Height < 480)
        { Console.WriteLine("DESKTOP TEST NOT RUN: runner 没有可用的交互桌面，不能宣称已验证真实采集。"); return 77; }
        int exit = 1;
        using var document = Document();
        using var fixture = new Fixture(document) { Bounds = new(work.Left + 12, work.Top + 32, 256, 240) };
        fixture.Shown += async (_, _) =>
        {
            try { await RunSession(fixture, document); exit = 0; }
            catch (Exception error) { Console.Error.WriteLine("DESKTOP SELF TEST FAILED: " + error.Message); }
            finally { fixture.Close(); }
        };
        Application.Run(fixture);
        return exit;
    }
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    static Bitmap Document()
    {
        var image = new Bitmap(256, 720, PixelFormat.Format32bppRgb);
        var data = image.LockBits(new(Point.Empty, image.Size), ImageLockMode.WriteOnly, image.PixelFormat);
        try
        {
            uint state = 271828; var row = new byte[data.Stride];
            for (int y = 0; y < image.Height; y++)
            {
                for (int x = 0; x < image.Width; x++)
                { state = unchecked(state * 1664525 + 1013904223); byte value = (byte)(state >> 24); int i = x * 4; row[i] = row[i + 1] = row[i + 2] = value; row[i + 3] = 255; }
                Marshal.Copy(row, 0, data.Scan0 + y * data.Stride, row.Length);
            }
        }
        finally { image.UnlockBits(data); }
        return image;
    }
    static async Task Wait(Func<bool> condition, string name, Func<string>? detail = null)
    {
        var deadline = DateTime.UtcNow.AddSeconds(12);
        while (!condition())
        { if (DateTime.UtcNow > deadline) throw new InvalidOperationException(name + "超时 " + detail?.Invoke()); await Task.Delay(20); }
    }
    static async Task RunSession(Fixture fixture, Bitmap document)
    {
        fixture.Activate(); fixture.Refresh(); await Task.Delay(300);
        var region = new Rectangle(fixture.PointToScreen(Point.Empty), fixture.ClientSize);
        using (var capture = Capture.ScreenImage(region))
        using (var expected = Capture.Crop(document, new(Point.Empty, region.Size)))
        {
            double difference = new StitchMatcher().Difference(Capture.Gray(capture), Capture.Gray(expected));
            GetWindowThreadProcessId(Native.GetForegroundWindow(), out uint foregroundPid);
            string foreground = "none"; try { using var process = System.Diagnostics.Process.GetProcessById((int)foregroundPid); foreground = process.ProcessName; } catch (ArgumentException) { }
            Console.WriteLine($"FOREGROUND: {foreground}");
            Console.WriteLine($"CAPTURE: dpi={fixture.DeviceDpi}, imageDpi={document.HorizontalResolution}, region={region.Size}, difference={difference:F3}, paints={fixture.Paints}, foregroundSelf={Native.GetForegroundWindow() == fixture.Handle}, mean={Capture.Gray(capture).Pixels.Average(v => (double)v):F2}");
            if (difference > .1)
                throw new InvalidOperationException("自身测试窗口与 GDI 实际采集不一致，可能存在遮挡、缩放或无交互桌面");
        }
        Console.WriteLine("PASS: actual GDI region capture includes layered fixture pixels");
        await TestFrozenSelection(fixture, document, region);
        using (var first = new Hotkeys()) using (var second = new Hotkeys())
        {
            var shortcut = new Shortcut(1 | 2 | 4, Keys.F10);
            if (!first.Register(1, shortcut) || second.Register(1, shortcut)) throw new InvalidOperationException("全局快捷键注册/冲突检测错误");
            first.Remove(1);
            if (!second.Register(1, shortcut)) throw new InvalidOperationException("快捷键未释放");
        }
        Console.WriteLine("PASS: native hotkey registration, conflict and release");
        fixture.BringToFront(); Native.SetForegroundWindow(fixture.Handle);
        await Wait(() => Native.GetForegroundWindow() == fixture.Handle, "目标窗口恢复前台");
        Bitmap? result = null;
        using var session = new ScrollSession(region, (image, _) => { result = (Bitmap)image.Clone(); return true; });
        if (Native.GetForegroundWindow() != fixture.Handle) throw new InvalidOperationException("长图控件抢走了目标窗口焦点");
        if (session.PreviewBounds.IntersectsWith(region)) throw new InvalidOperationException("预览进入了采集区域");
        await Wait(() => session.CapturedHeight == region.Height, "采集首帧", () => session.Diagnostic);
        using (var capture = Capture.ScreenImage(region))
        using (var expected = Capture.Crop(document, new(Point.Empty, region.Size)))
            if (new StitchMatcher().Difference(Capture.Gray(capture), Capture.Gray(expected)) > .1)
                throw new InvalidOperationException("控件出现后真实选区像素发生变化，边框排除策略不兼容");
        Console.WriteLine("PASS: capture controls do not change captured region pixels");
        for (int offset = 30; offset <= 360; offset += 30)
        {
            fixture.ScrollTo(offset);
            await Wait(() => session.CapturedHeight == region.Height + offset, "连续滚动接续");
            if (offset == 120)
            {
                fixture.ScrollTo(90);
                await Wait(() => session.HasUnmatchedFrame, "反向滚动检测");
                fixture.ScrollTo(120);
                await Wait(() => !session.HasUnmatchedFrame, "回到保留锚点恢复");
            }
        }
        await Wait(() => !session.InFlight, "处理队列排空");
        session.UndoLast();
        if (session.CapturedHeight != region.Height + 330) throw new InvalidOperationException("撤销未移除上一段");
        fixture.ScrollTo(330);
        await Wait(() => !session.HasUnmatchedFrame && !session.InFlight, "撤销后的锚点恢复");
        fixture.ScrollTo(360);
        await Wait(() => session.CapturedHeight == region.Height + 360 && !session.HasUnmatchedFrame, "撤销后重新接续");
        await session.Finish(FinishMode.Copy);
        if (!session.Released || result == null || result.Height != region.Height + 360) throw new InvalidOperationException("完成未导出完整长图或未释放窗口/片段");
        using (result)
        {
            for (int y = 0; y < result.Height; y++) for (int x = 0; x < result.Width; x++)
            {
                var a = result.GetPixel(x, y); var b = document.GetPixel(x, y);
                if (a.R != b.R || a.G != b.G || a.B != b.B) throw new InvalidOperationException("真实长图像素不一致或边框进入导出");
            }
        }
        Console.WriteLine("PASS: real desktop scroll session, reverse recovery, undo, full-pixel stitching and resource release");
    }
    static async Task TestFrozenSelection(Fixture fixture, Bitmap document, Rectangle region)
    {
        Bitmap? result = null;
        using (var overlay = new Selection(false))
        {
            overlay.Selected += (_, image) => result = image;
            fixture.ScrollTo(30); // 冻结后改变原窗口，框选结果仍必须是原画面。
            overlay.Show(); overlay.Refresh(); await Task.Delay(100);
            var a = overlay.PointToClient(new Point(region.Left + 20, region.Top + 20));
            var b = overlay.PointToClient(new Point(region.Left + 148, region.Top + 120));
            IntPtr Position(Point p) => (IntPtr)((p.Y << 16) | (p.X & 0xFFFF));
            SendMessage(overlay.Handle, 0x201, (IntPtr)1, Position(a));
            SendMessage(overlay.Handle, 0x200, (IntPtr)1, Position(b));
            SendMessage(overlay.Handle, 0x202, IntPtr.Zero, Position(b));
        }
        using (result)
        using (var expected = Capture.Crop(document, new(20, 20, 128, 100)))
        {
            if (result == null || result.Size != expected.Size) throw new InvalidOperationException("冻结框选未生成正确区域");
            for (int y = 0; y < result.Height; y++) for (int x = 0; x < result.Width; x++)
                if (result.GetPixel(x, y).ToArgb() != expected.GetPixel(x, y).ToArgb()) throw new InvalidOperationException("框选结果不是冻结时的原始像素");
        }
        fixture.ScrollTo(0); fixture.Activate(); fixture.Refresh(); await Task.Delay(100);
        Console.WriteLine("PASS: native selection uses frozen layered pixels, despite subsequent source changes");
    }
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    sealed class Fixture : Form
    {
        readonly Bitmap document; int offset; public int Paints;
        public Fixture(Bitmap document)
        {
            this.document = document;
            AutoScaleMode = AutoScaleMode.None; FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false; TopMost = true; DoubleBuffered = true; TransparencyKey = Color.Magenta; StartPosition = FormStartPosition.Manual;
        }
        public void ScrollTo(int value) { offset = value; Refresh(); }
        protected override void OnPaint(PaintEventArgs e) { Paints++; e.Graphics.DrawImageUnscaled(document, 0, -offset); }
    }
}
