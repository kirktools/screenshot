# Screenshot

独立的原生截图工具，支持 macOS 与 Windows 11。框选、滚动、复制，不必打开微信。

**原生体验 · 本机处理 · 无需账号**

Native macOS and Windows screenshots with manual scrolling, automatic stitching, and annotation.

[下载最新版本](https://github.com/kirktools/screenshot/releases/latest) · [English](README.en.md)

<img src="docs/images/editor.png" alt="Screenshot 原位标注与浮动工具栏" width="800">

## 能做什么

- **区域截图**：macOS 支持原位调整边框；两端都支持箭头、矩形、圆形、文字、裁剪和打码。
- **滚动长图**：手动向下滚动，自动拼接；常驻预览，回车直接复制。
- **随时唤起**：菜单栏 / 系统托盘常驻，全局快捷键可配置。
- **应用内更新**：菜单中检查 GitHub 正式版，确认后下载、校验并更新。
- **留在本机**：不注册、不上传，复制或保存为 PNG。

## 怎么用

1. macOS 按 **⌘⇧2 / 7** 截普通图 / 长图，可悬停预选窗口或拖动框选。Windows 按 **Ctrl+Shift+2 / 7** 拖动框选。
2. 普通截图直接标注；长截图在原应用中向下滚动，预览自动更新。
3. **回车 / ✓ 复制并结束**，**Esc / × 取消**。长图需要编辑时点铅笔，保存时点下载图标。

长图界面只保留预览和图标，出错才显示悬浮提示。撤销、重试、放大等操作在「…」里。

<img src="docs/images/screenshot-intro.gif" alt="16 秒功能演示：原位标注、滚动拼接与长图完成" width="800">

[观看 MP4 版](docs/images/screenshot-intro.mp4)

<sub>macOS 原生界面与合成内容，脚本驱动演示，非鼠标实录；不含私人聊天。</sub>

## 安装运行

**Windows 11**：下载 x64 / ARM64 ZIP，完整解压到可写目录后运行 `Screenshot.exe`，无需另装运行时。默认 `Ctrl+Shift+2 / 7`，托盘菜单可配置快捷键及检查更新。Windows 首版界面与 macOS 有差异，详见 [Windows 使用与验收](docs/WINDOWS.md)。

**macOS**：

支持 **macOS 14+**，Apple Silicon / Intel。新版本提供 DMG 安装包：打开后将应用拖入 Applications。也保留 ZIP；旧版没有 DMG 时可使用 ZIP。

本地验收 PR：切到对应代码后运行 `make dev`，自动更新并启动独立的 `/Applications/Screenshot Dev.app`，不覆盖日常版；设置中可核对分支和提交。详见[本地测试](docs/USAGE.md#本地验收-pr)。

从源码构建（Swift 6.0+）：

```bash
make dev
```

日常版安装到 `/Applications/Screenshot.app`；源码开发使用独立的 `Screenshot Dev`，默认快捷键为 `⌃⌥2 / ⌃⌥7`，配置和权限各自独立。启动只驻留菜单栏，设置按需打开。首次截图需授予**屏幕录制**权限，不需要辅助功能或麦克风权限。

当前应用尚未 Developer ID 签名及公证；下载包可能被 macOS 拦截，请按系统提示核验来源，勿关闭系统安全保护。详见[安装与权限](docs/USAGE.md#安装与权限)。

## 使用边界

长图适合静态、向下滚动的正文。框选时避开固定栏、输入框和悬浮按钮；动态消息、动画、快速跳页或重复内容可能无法接续。暂不支持向上扩展及跨屏长图，不保证适配所有应用。

## 文档与贡献

[使用与排障](docs/USAGE.md) · [隐私说明](docs/PRIVACY.md) · [安全报告](SECURITY.md) · [贡献指南](CONTRIBUTING.md) · [架构](docs/ARCHITECTURE.md) · [测试验收](docs/ACCEPTANCE.md) · [CI 与发布](docs/RELEASING.md)

欢迎 Issue 和 PR：请附系统版本、芯片与复现步骤，图片使用非敏感示例。修改算法请补测试，修改界面请附截图。

[MIT](LICENSE) · Copyright © 2026 kirktools
