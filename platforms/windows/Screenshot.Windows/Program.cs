using System.Diagnostics;
namespace Screenshot.Windows;

internal static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2); Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        if (args is ["--prepare-update-test", var task, var candidate]) return UpdateProcessFixture.Prepare(task, candidate);
        if (args is ["--apply-update", var folder]) return Updates.Apply(folder);
        if (args is ["--self-test"]) return WindowsSelfTest.Run();
        if (args is ["--desktop-self-test"]) return DesktopSelfTest.Run();
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) { MessageBox.Show("此版本需要 Windows 11 或更新系统。", "Screenshot"); return 1; }
        using var instance = new Mutex(true, @"Local\kirktools." + Profile.Name.Replace(" ", ""), out bool first);
        if (!first) { MessageBox.Show("Screenshot 已在系统托盘运行。", "Screenshot"); return 0; }
        try { using var app = new ScreenshotContext(); if (args is ["--update-started", var directory]) Updates.MarkStarted(directory); Application.Run(app); return 0; }
        catch (Exception) { MessageBox.Show("启动失败。请把完整安装包解压到可写目录后运行；不要直接在 ZIP 中启动。", "Screenshot"); return 1; }
    }
}
internal sealed class ScreenshotContext : ApplicationContext
{
    readonly NotifyIcon tray; readonly Hotkeys keys = new(); Preferences preferences = Preferences.Load();
    Selection? selection; Editor? editor; ScrollSession? scroll; Form? settings; bool updating, disposed, startingScroll; CancellationTokenSource? updateCancellation;
    bool Busy => selection != null || editor != null || scroll != null || updating || startingScroll;
    public ScreenshotContext()
    {
        tray = new() { Icon = Profile.Development ? SystemIcons.Information : SystemIcons.Application, Text = Profile.Name, Visible = true }; tray.DoubleClick += (_, _) => Settings(); keys.Triggered += Trigger; Menu();
        if (!Bind(preferences)) { tray.ShowBalloonTip(5000, "快捷键注册失败", "组合键已被其他应用占用，可从托盘截图并打开设置修改。", ToolTipIcon.Warning); }
        else tray.ShowBalloonTip(3000, "Screenshot 已启动", $"截图：{preferences.Region}；长图：{preferences.Scroll}。双击托盘打开设置。", ToolTipIcon.Info);
        SystemEventsBridge.Subscribe(this); _ = CleanupUpdates();
    }
    static async Task CleanupUpdates() { await Task.Delay(3000); Updates.Cleanup(); }
    bool Bind(Preferences value)
    {
        keys.Remove(1); keys.Remove(2);
        if (value.Region.Modifiers == 0 || value.Scroll.Modifiers == 0 || value.Region == value.Scroll || !keys.Register(1, value.Region) || !keys.Register(2, value.Scroll)) { keys.Remove(1); keys.Remove(2); return false; }
        return true;
    }
    void Menu()
    {
        var old = tray.ContextMenuStrip; var menu = new ContextMenuStrip();
        menu.Items.Add($"区域截图  {preferences.Region}", null, (_, _) => Start(false)); menu.Items.Add($"滚动长截图  {preferences.Scroll}", null, (_, _) => Start(true));
        menu.Items.Add("设置快捷键", null, (_, _) => Settings()); if (!Profile.Development) menu.Items.Add("检查更新…", null, async (_, _) => await Update());
        menu.Items.Add("退出", null, (_, _) => ExitThread());
        menu.Opening += (_, _) => { for (int i = 0; i < menu.Items.Count - 1; i++) menu.Items[i].Enabled = !Busy; }; tray.ContextMenuStrip = menu; old?.Dispose();
    }
    void Trigger(int id)
    {
        if (id == 1) Start(false); else if (id == 2) Start(true); else if (id == 3 && scroll != null) _ = scroll.Finish(FinishMode.Copy); else if (id == 4) scroll?.Dispose();
    }
    void Start(bool scrolling)
    {
        if (Busy || disposed) return; IntPtr target = Native.GetForegroundWindow();
        try
        {
            var overlay = new Selection(scrolling); selection = overlay; bool accepted = false;
            overlay.Selected += (region, image) =>
            {
                accepted = true; selection = null;
                if (!scrolling && image != null) { OpenEditor(image); return; }
                startingScroll = true; Native.SetForegroundWindow(target);
                // 等冻结遮罩退出后再启动采集，避免首帧混入遮罩内容。
                var delay = new System.Windows.Forms.Timer { Interval = 100 };
                delay.Tick += (_, _) =>
                {
                    delay.Stop(); delay.Dispose();
                    if (disposed) return;
                    try
                    {
                        scroll = new ScrollSession(region, (result, mode) =>
                        {
                            try
                            {
                                if (mode == FinishMode.Edit) OpenEditor((Bitmap)result.Clone());
                                else { Editor.CopyImage(result); if (mode == FinishMode.Save) Editor.SaveImage(null, result); }
                                return true;
                            }
                            catch (Exception) { MessageBox.Show("复制或保存失败，请关闭占用剪贴板的程序后重试。", "Screenshot"); return false; }
                        });
                        scroll.Closed += () => { scroll = null; keys.Remove(3); keys.Remove(4); };
                        bool enter = keys.Register(3, new(0, Keys.Enter)), escape = keys.Register(4, new(0, Keys.Escape));
                        if (!enter || !escape) tray.ShowBalloonTip(4000, "临时快捷键不可用", "请使用长图预览下方按钮完成或取消。", ToolTipIcon.Info);
                    }
                    catch (Exception error) { scroll?.Dispose(); scroll = null; MessageBox.Show(error.Message, "无法开始长截图"); }
                    finally { startingScroll = false; }
                }; delay.Start();
            };
            overlay.FormClosed += (_, _) => { if (!accepted) selection = null; overlay.Dispose(); }; overlay.Show();
        }
        catch (Exception error) { selection?.Dispose(); selection = null; MessageBox.Show(error.Message, "截图失败"); }
    }
    void OpenEditor(Bitmap image)
    {
        editor = new Editor(image); editor.FormClosed += (_, _) => { editor?.Dispose(); editor = null; }; editor.Show(); editor.Activate();
    }
    void Settings()
    {
        if (Busy || disposed) return;
        if (settings != null) { settings.Activate(); return; }
        var form = new Form { Text = "Screenshot · 设置", Size = new(480, 255), StartPosition = FormStartPosition.CenterScreen, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false }; settings = form;
        Shortcut region = preferences.Region, scrolling = preferences.Scroll;
        TextBox Field(string label, int top, Shortcut initial, Action<Shortcut> change)
        {
            form.Controls.Add(new Label { Text = label, Bounds = new(20, top + 4, 100, 25) });
            var field = new TextBox { ReadOnly = true, Text = initial.ToString(), Bounds = new(130, top, 300, 28) };
            field.KeyDown += (_, e) => { e.SuppressKeyPress = true; var value = Shortcut.From(e.KeyData); if (value.Modifiers != 0 && value.Key is not (Keys.ControlKey or Keys.ShiftKey or Keys.Menu or Keys.LWin or Keys.RWin)) { change(value); field.Text = value.ToString(); } }; form.Controls.Add(field); return field;
        }
        Field("区域截图", 25, region, v => region = v); Field("滚动长图", 70, scrolling, v => scrolling = v);
        form.Controls.Add(new Label { Text = "点击输入框后按组合键。支持 Ctrl / Alt / Shift。", Bounds = new(20, 112, 420, 30) });
        var save = new Button { Text = "保存", Bounds = new(325, 155, 105, 32) }; form.Controls.Add(save);
        save.Click += (_, _) =>
        {
            var candidate = new Preferences(region, scrolling);
            if (!Bind(candidate)) { Bind(preferences); MessageBox.Show(form, "组合键相同、没有修饰键或已被系统/其他应用占用。请换一个组合键。", "未修改设置"); return; }
            try { candidate.Save(); preferences = candidate; Menu(); form.Close(); } catch (Exception) { Bind(preferences); MessageBox.Show(form, "设置文件无法写入，已恢复原快捷键。", "保存失败"); }
        };
        form.FormClosed += (_, _) => { settings = null; form.Dispose(); }; form.Show();
    }
    async Task Update()
    {
        if (Busy) { MessageBox.Show("请先完成或取消当前截图/更新。", "Screenshot"); return; }
        updating = true; var cancellation = new CancellationTokenSource(); updateCancellation = cancellation;
        using var progress = new Form { Text = "Screenshot · 检查更新", Size = new(420, 150), StartPosition = FormStartPosition.CenterScreen, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false };
        progress.Controls.Add(new Label { Text = "正在检查或下载 GitHub 正式版，请稍候…", Dock = DockStyle.Top, Height = 40, Padding = new(12) });
        progress.Controls.Add(new ProgressBar { Style = ProgressBarStyle.Marquee, Dock = DockStyle.Top, Height = 20 });
        var cancel = new Button { Text = "取消", Dock = DockStyle.Bottom }; cancel.Click += (_, _) => cancellation.Cancel(); progress.Controls.Add(cancel); progress.FormClosing += (_, _) => cancellation.Cancel(); progress.Show();
        try { if (await Updates.Check(progress, cancellation.Token)) ExitThread(); }
        catch (OperationCanceledException) { }
        catch (Exception error) { MessageBox.Show(progress, "检查或安装更新失败：" + error.Message + "\n当前版本仍可继续使用。", "更新失败"); }
        finally { updating = false; progress.Close(); cancellation.Dispose(); updateCancellation = null; }
    }
    public void CancelForDisplayChange() { selection?.Close(); }
    protected override void ExitThreadCore()
    {
        if (disposed) return; disposed = true; updateCancellation?.Cancel(); SystemEventsBridge.Unsubscribe(this); scroll?.Dispose(); selection?.Dispose(); editor?.Close(); settings?.Close(); tray.Visible = false; tray.Dispose(); keys.Dispose(); base.ExitThreadCore();
    }
}
internal static class SystemEventsBridge
{
    static ScreenshotContext? context;
    public static void Subscribe(ScreenshotContext value) { context = value; Microsoft.Win32.SystemEvents.DisplaySettingsChanged += Changed; }
    static void Changed(object? sender, EventArgs e) { var current = context; var form = Application.OpenForms.Cast<Form>().FirstOrDefault(); if (current != null && form != null && !form.IsDisposed) form.BeginInvoke(new Action(current.CancelForDisplayChange)); }
    public static void Unsubscribe(ScreenshotContext value) { Microsoft.Win32.SystemEvents.DisplaySettingsChanged -= Changed; context = null; }
}
