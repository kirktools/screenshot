# 本地验证记录

验证日期：2026-10-22（Asia/Shanghai）。本记录仅描述本次实际执行结果，不代表所有支持系统与应用均已验收。

## 环境

- macOS 27.0.1，Apple Silicon arm64。
- Swift 6.4 / Command Line Tools，未安装完整 Xcode。
- 空仓库，origin 已指向 `https://github.com/kirktools/screenshot.git`；本次没有 git commit、push 或远端发布。
- 从 Codex 命令行启动的测试进程，其 `CGPreflightScreenCaptureAccess()` 返回 true，真实采集测试通过；未修改系统权限。通过 LaunchServices 正常打开最终 .app 后，设置窗口显示“尚未授予屏幕录制权限”，说明两个执行上下文的权限归属不同。日常使用仍需用户为 Kirk Screenshot 单独授权。

## 已通过

| 检查 | 证据 / 范围 |
| --- | --- |
| 平台无关算法 | `scripts/test-core.sh`，13 组共享用例通过；包括 1/2 像素微滚动、正文留白、Retina 精确接缝、噪声、反向、重复与失败场景 |
| 原生图像拼接 | 合成 CGImage 裁成两个重叠片段，经真实采样、匹配、合成后，与原始图片对应区域亮度像素一致 |
| 编辑与导出 | 图像方向、PNG 编码/解码、实心打码区域真实黑色像素、PNG 文件写入通过 |
| 编辑历史 | 裁剪尺寸、裁剪撤销/重做、标注撤销、新操作清空重做历史通过 |
| 系统剪贴板 | 向 NSPasteboard.general 写入 PNG 并读取比较一致；测试后恢复先前的数据 |
| ScreenCaptureKit | 最终应用包 `--capture-smoke-test` 真实捕获屏幕小区域；160 × 120 点在 2× 屏幕产生 320 × 240 像素 PNG；结果只在 `.build/validation/desktop-smoke.png`，不提交不展示 |
| 会话键注册 | 最终包 `--hotkey-smoke-test` 通过 Return/Esc 注册、相同绑定更新、重复注册冲突检查；退出后移除热键 |
| 原生 UI 启动 | .app 以合成图片打开编辑器，观察到中文工具栏、滚动预览、尺寸状态；最终默认构建的 .app 正常启动设置窗口，显示 0.1.0、⌘⇧2 / ⌘⇧7 及待授权提示 |
| Release 构建 | `UNIVERSAL=1` 构建通过，`lipo -archs` 返回 x86_64 和 arm64，两架构分别 verify_arch 通过 |
| 包完整性 | `codesign --verify --deep --strict` 通过，ad-hoc 签名；zip 与 SHA256SUMS 已生成 |
| 发布辅助逻辑 | 临时副本验证 patch/minor/major 自动增量为 0.1.1 / 0.2.0 / 1.0.0；未修改本仓库 0.1.0 |
| 静态配置 | bash 语法、Python AST、Info.plist 与 Actions/Dependabot YAML 解析通过 |

算法用例由同一份 `Tests/StitchCoreTests/StitchMatcherTests.swift` 提供：完整 Xcode/CI 用 XCTest，当前只有 Command Line Tools，使用独立 Swift 编译的兼容入口运行，断言失败会以非零状态退出。本机未成功执行 XCTest runner，不能写成 `swift test` 已通过。

## 尚未验证

- 鼠标框选 → 自动恢复原应用 → 完成预览的完整真实交互；UI 自动化读取到了窗口，但后续操作被工具的窗口状态冲突检查阻止，没有绕过该保护。
- 全局快捷键按下后的实际事件分发、快捷键录入与重启持久化。已验证的是注册机制，不是键盘操作链路。
- 浏览器、微信、Codex 的实际长截图、焦点保持、面板排除、暂停重试和撤销操作。
- 首次拒绝、重新授权、权限撤销后的完整系统交互；没有为了测试主动撤销现有权限。
- 多屏负坐标、混合 DPI、跨屏框选、拔插屏幕、全屏 Space、Intel 上运行、macOS 14 上运行。
- 用户在保存对话框中取消/选择路径、复制后粘贴到其他应用、反复捕获的长期内存表现。
- GitHub Actions 的真实云端执行；workflow 尚未推送。YAML 解析通过不代表 runner 上已跑过。
- Developer ID 签名、公证和网络下载后的 Gatekeeper 安装体验。

人工操作步骤见 [ACCEPTANCE.md](ACCEPTANCE.md)。目前应将此版本视为本地可运行、核心链路已有自动验证的早期版本；完成真实桌面验收后再考虑公开发布。

## 复现本机验证

在终端正常权限下：

```bash
scripts/test-core.sh
UNIVERSAL=1 scripts/build-app.sh
'dist/Kirk Screenshot.app/Contents/MacOS/KirkScreenshot' --self-test
KIRK_TEST_CLIPBOARD=1 'dist/Kirk Screenshot.app/Contents/MacOS/KirkScreenshot' --self-test
'dist/Kirk Screenshot.app/Contents/MacOS/KirkScreenshot' --hotkey-smoke-test
# 需要已有屏幕录制授权，会把一张真实小区域截图保存在系统临时目录。
'dist/Kirk Screenshot.app/Contents/MacOS/KirkScreenshot' --capture-smoke-test
```

README 的默认 `UNIVERSAL=1 scripts/build-app.sh` 已在普通执行权限下实际构建通过。Swift 6.4 默认后端共用不同架构的输出目录，脚本现在会逐架构复制二进制后合并，避免被覆盖。链接器对 Command Line Tools 缺少两个搜索目录产生警告，但构建成功。

在 Codex 文件隔离环境中也使用过 `KIRK_NATIVE_BUILD=1 KIRK_DISABLE_BUILD_SANDBOX=1 UNIVERSAL=1 scripts/build-app.sh`，把 Swift/Clang 缓存放在 `.build/cache`，绕过嵌套构建沙箱限制；不是关闭 macOS 的 Gatekeeper 或 SIP。native build system 在 Swift 6.4 中有弃用提示，普通开发机优先运行默认构建命令。
