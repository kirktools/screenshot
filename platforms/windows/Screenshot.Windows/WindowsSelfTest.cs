using System.Drawing.Imaging;
namespace Screenshot.Windows;

internal static class WindowsSelfTest
{
    public static int Run()
    {
        try
        {
            foreach (string json in new[] { "null", "{}", "{\"Region\":null,\"Scroll\":null}", "{\"Region\":{\"Modifiers\":0,\"Key\":0},\"Scroll\":null}" })
                if (Preferences.Parse(json) != Preferences.Default) throw new Exception("损坏设置未回退默认值");
            if (Updates.IsElevated)
            {
                try { Updates.EnsureUnelevated(); throw new Exception("高权限更新未被拒绝"); }
                catch (System.Security.SecurityException) { }
            }
            using var source = new Bitmap(120, 100); using (var g = Graphics.FromImage(source)) { g.Clear(Color.White); g.FillRectangle(Brushes.Blue, 10, 10, 30, 25); }
            using var document = new EditDocument((Bitmap)source.Clone());
            document.Apply(document.State with { Marks = [new(Tool.Redact, new(8, 8), new(45, 40), Color.Red, 4)] });
            using (var image = document.Render())
            {
                if (image.GetPixel(20, 20).ToArgb() != Color.Black.ToArgb()) throw new Exception("打码未进入导出像素");
                using var png = new MemoryStream(); image.Save(png, ImageFormat.Png); png.Position = 0; using var decoded = new Bitmap(png);
                if (decoded.GetPixel(20, 20).ToArgb() != Color.Black.ToArgb()) throw new Exception("PNG 打码丢失");
                // Windows 没有独立命名剪贴板；只在隔离 CI 中验证系统剪贴板，避免本机自测覆盖用户内容。
                if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true")
                {
                    Editor.CopyImage(image); using var clipboard = Clipboard.GetImage();
                    if (clipboard == null || clipboard.Width != 120) throw new Exception("剪贴板写入失败");
                    using var clipboardBitmap = new Bitmap(clipboard);
                    if (clipboardBitmap.GetPixel(20, 20).ToArgb() != Color.Black.ToArgb()) throw new Exception("剪贴板打码丢失");
                    Clipboard.Clear();
                }
            }
            document.Apply(document.State with { Crop = new(5, 5, 60, 50) }); using (var cropped = document.Render()) { if (cropped.Size != new Size(60, 50)) throw new Exception("裁剪尺寸错误"); }
            document.Undo(); if (document.State.Crop.Width != 120) throw new Exception("撤销失败"); document.Redo(); if (document.State.Crop.Width != 60) throw new Exception("重做失败");
            using var editor = new Editor((Bitmap)source.Clone()); editor.CreateControl();
            Console.WriteLine("WINDOWS SELF TEST PASSED: redaction, PNG, crop, undo/redo, native editor; system clipboard checked only in isolated CI"); return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
    }
}
