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

## 2026-10-22：重启与系统快捷键冲突回归

现象：用户重启后普通截图无响应，按自定义系统占用的 `⌘⇧7` 得到 Touch Bar 图片。调查时最初没有 KirkScreenshot 进程；再次打开后进程存在，但旧版只在首次启动显示设置，未实现 reopen 回调，因此看起来仍没有启动。

系统 API `CopySymbolicHotKeys` 返回 keyCode 26 / modifiers 768（⌘⇧7）已启用；同机 ⌘⇧6 也被系统使用。最小复现证实旧方式 `RegisterEventHotKey` 对已被系统占用的 ⌘⇧6 仍返回 0（成功），因此仅检查注册返回值不足以排除冲突。没有改动任何系统快捷键或权限设置。

修复：注册前查询已启用的系统绑定；启动时遇到冲突尝试备用组合键，保存并明确展示；提供无需热键的两种截图按钮；每次手动启动和 reopen 均显示状态，窗口重新激活时刷新权限。

本地新增验证：

- `--hotkey-smoke-test`：已启用的系统组合键被拒绝，错误明确标注 macOS；⌃⌥7 备用键注册通过；原 Return/Esc 和重复绑定检查继续通过。
- `--startup-smoke-test`：可见设置窗口及两种截图按钮存在，关闭窗口后调用 reopen 处理器可恢复同一窗口，多次 reopen 不生成重复窗口。
- 原 13 组算法测试与原生 PNG、拼接、打码、裁剪撤销/重做自测再次通过。

以上启动回归是直接执行应用生命周期处理器的原生自测；真实键盘按下和用户权限授权仍需在桌面验证，不能把这些测试等同于用户已完成验收。

最终包实际启动观察：设置窗口可见，显示区域截图 ⌘⇧2、长截图 ⌃⌥7，并明确提示“⌘⇧7 已被 macOS 系统快捷键占用，已改用 ⌃⌥7”；备用绑定已保存在应用偏好中。通过 UI 点击“区域截图”后，正常出现应用的屏幕录制权限引导，没有修改系统授权。窗口仍显示未获权限，因此尚不能宣称用户实际截图链路已恢复完成。UI 自动化发送 ⌘⇧2 未观察到动作，不能代替授权后的真实键盘验收。

后续按用户明确要求，在系统设置的“键盘快捷键 → 截屏”中，仅取消“将触控栏的图片保存为文件（⇧⌘7）”的勾选。CopySymbolicHotKeys 再查询确认 keyCode 26 / modifiers 768 已禁用；触控栏拷贝到剪贴板的另一组合键和其他系统快捷键保持原样。将本机 Kirk 的 `screenshot.scroll` 偏好恢复为 ⌘⇧7，重开应用后从实际窗口确认普通截图 ⌘⇧2 / 长截图 ⌘⇧7，冲突提示消失。未重新构建应用，也未改动录屏权限。统一工具快捷键前缀仅讨论候选，尚未启用。

后续权限排障：用户指出开关已打开但应用仍提示申请。实际读取系统设置确认 Kirk Screenshot 的录屏开关为 on，应用自身状态仍未授权，符合临时签名重建后旧授权条目未匹配的情形，但未读取 TCC 数据库，不能认定签名不匹配已得到直接证明。应用此前只位于仓库 dist，没有安装到用户 Applications；已原样复制到 `~/Applications/Kirk Screenshot.app`，SHA-256 与 designated requirement 均保持不变，并确认从安装路径打开状态窗口。未重新构建，未更改系统安全保护；是否重建这一条录屏授权记录等待用户当次确认。
