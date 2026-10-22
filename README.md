# Kirk Screenshot

独立、轻巧的原生 macOS 菜单栏截图工具。GitHub：[`kirktools/screenshot`](https://github.com/kirktools/screenshot)。默认中文，所有图片处理在本机完成，无需微信、注册或上传。

当前版本 **0.1.0，早期可运行版本**。核心算法和原生导出有自动验证；真实桌面上的权限、焦点和各应用长截图仍需完成[人工验收](docs/ACCEPTANCE.md)，请勿将“已构建”理解为所有应用都已适配。

## 功能

- 菜单栏常驻，区域截图 `⌘⇧2`、滚动长截图 `⌘⇧7`，设置中可录入新快捷键；占用时显示错误。
- 拖动框选，普通截图可跨屏，按最高 Retina 缩放合成；长截图限定单屏固定区域。
- 手动向下滚动，画面停稳后自动识别重叠、去重拼接。显示状态、段数、尺寸和缩略图。
- 捕获面板不激活目标应用；ScreenCaptureKit 显式排除本应用窗口。回车完成，Esc 取消；不可靠匹配会暂停，可回滚重试或撤销上一段。
- 编辑预览：裁剪、箭头、矩形、文字、实心打码，30 步撤销/重做；复制 PNG 和保存 PNG 共用渲染结果。
- 只保留最近一次预览；新截图替换旧预览前请先保存。没有后台自动保存或上传。

## 系统与开发要求

运行：macOS **14 Sonoma 或更新版本**，Apple Silicon 或 Intel。选择 14 是因为采用 SCScreenshotManager 的单帧 API，避免旧截图 API 和额外流管理。参见 [Apple ScreenCaptureKit 文档](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)。

构建：Swift **6.0+**、对应 macOS SDK、Xcode Command Line Tools 即可，无第三方包。`swift test` 的 XCTest 运行需要完整 Xcode；仅装 Command Line Tools 时用 `scripts/test-core.sh` 运行同一批算法用例。Swift 语言模式为 5，兼容当前 Swift 6 工具链。最低系统版本是编译目标，不代表已在所有支持系统实测。

```bash
xcode-select --install # 尚未安装开发工具时
scripts/test-core.sh  # 不依赖 XCTest，可用于只有 Command Line Tools 的环境
scripts/build-app.sh
open 'dist/Kirk Screenshot.app'
```

产物：`dist/Kirk Screenshot.app` 和 `dist/Kirk-Screenshot-0.1.0-macOS.zip`。默认本机构建架构；`UNIVERSAL=1 scripts/build-app.sh` 构建 arm64/x86_64 双架构，`CONFIGURATION=debug` 可改为调试构建。用 Xcode 打开 `Package.swift` 也可浏览调试，但日常运行建议使用固定位置的 `.app`，以稳定权限身份。

受限执行环境若无法写默认 Swift/Clang 缓存，可把 `CLANG_MODULE_CACHE_PATH` 与 `SWIFTPM_MODULECACHE_OVERRIDE` 指向工作区 `.build/cache/clang`，并为 SwiftPM 指定 `--cache-path`。不应为应用运行关闭系统保护。

## 安装与权限

建议把应用复制到 `~/Applications` 或 `/Applications` 后首次启动。当前构建仅 **ad-hoc 签名**，不是 Developer ID 签名，也没有 Apple 公证。网络下载的包可能被 Gatekeeper 拦截；确认来源后可按 macOS 提示在“系统设置 → 隐私与安全性”中使用“仍要打开”（若系统允许）。不要关闭 Gatekeeper、SIP 或全局放宽安全策略；本地从源码构建是另一条路径。

第一次启动显示设置；截图前申请“屏幕与系统音频录制 / 屏幕录制”（不同系统名称稍异）。只读屏幕像素，不申请麦克风、辅助功能或输入监控权限。全局快捷键采用 Carbon 热键注册，滚动由你在原应用内完成。

首次拒绝后，使用设置里的权限按钮打开系统设置并勾选 Kirk Screenshot。授权、撤销或重新授权后可能需要退出再启动。若仍失败，确认设置中的应用与正在运行的包路径相同；重建、更换签名或路径可能让系统重新识别应用。不要把每次权限弹窗都当作拼接错误。

## 使用

1. 菜单栏选择“区域截图”或按快捷键，拖动框选；Esc 放弃。
2. 普通截图直接打开编辑预览。拖动使用箭头/矩形/裁剪/打码；文字工具点击位置输入内容。
3. 长截图只框选一个滚动容器的正文；避开顶部栏、底部输入框、滚动条、悬浮按钮。原应用恢复焦点后，鼠标留在内容区，每次向下滚动约 1/3–1/2 屏，停顿至少半秒。
4. 状态暂停时不要继续往下滚；向上回到上一段附近，再按“重试”。“撤销上一段”会删除最后接入的片段，也需要回滚到保留内容附近后重试。
5. 回车完成已接入片段，Esc 丢弃本次会话。编辑后按复制 / `⌘C`，或保存 / `⌘S`。裁剪和打码都实际改变导出像素；仍可在关闭编辑前撤销。

## 支持范围与限制

适合静态、垂直滚动、无固定覆盖的正文区域。重点人工验收对象为浏览器网页、微信聊天记录、Codex 对话；**尚未宣称这些应用全部通过实测**。

不支持水平/双向连续拼接、自动驱动滚动、窗口缩放/移动中的捕获、混合多个滚动容器或跨屏长截图。固定标题、悬浮元素、视频、闪烁光标、动画、动态消息、懒加载重排和高度重复内容可能导致暂停；某些细小变化仍可能漏检。请缩小区域、停止动态内容、避开固定栏；必要时使用普通截图。内容被其他应用遮挡时会截到遮挡物。

每次至少保留约 22% 重叠，建议半屏以上。上限为长图高 30000 像素、3200 万像素、保留帧 256 MB；普通截图最多 4000 万像素。长图和编辑历史会额外占内存。没有 OCR、自动去固定栏、智能窗口识别、登录启动或内置更新器。输出为 sRGB PNG；多数细节提示尚未翻译成英文。

## 测试与贡献

```bash
scripts/test-core.sh
swift test  # 完整 Xcode 环境 / CI
swift run KirkScreenshot --self-test
# 可选：验证真实剪贴板，随后恢复已有数据
KIRK_TEST_CLIPBOARD=1 swift run KirkScreenshot --self-test
```

算法测试覆盖精确重叠、重复帧、重复纹理、重叠不足、噪声、Retina 高度、像素尺寸变化、同视口缩放、反向滚动、固定栏及动态内容拒绝。`--self-test` 不读取桌面，验证真实 CGImage 拼接方向、编辑渲染、裁剪撤销/重做、PNG 编解码、打码像素与文件写入；默认测试 PNG 写入系统临时目录。真实交互见[验收清单](docs/ACCEPTANCE.md)。

欢迎 Issue 和 PR。提交时说明 macOS、芯片、屏幕缩放、复现步骤与期望结果；测试图片请用合成内容，勿上传私人聊天截图。新增算法行为应附可复现测试；UI 修改附截图和交互验证结果。架构演进见 [ARCHITECTURE.md](docs/ARCHITECTURE.md)，自动测试与发布见 [RELEASING.md](docs/RELEASING.md)。

MIT License，Copyright © 2026 **kirktools**。
