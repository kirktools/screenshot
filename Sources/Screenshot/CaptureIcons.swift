import AppKit

enum CaptureIcons {
    /// 四角与纵向双箭头表示延长捕获，与保存图标区分；和编辑工具栏复用同一套度量。
    static var scrollCapture: NSImage { toolbar("arrow.up.and.down")! }
}
