# 架构与演进边界

## 当前实现

```text
AppDelegate（菜单、权限、一次只运行一个捕获会话）
 ├─ HotkeyRegistry（稳定工具 ID → Carbon 注册 → 动作闭包）
 ├─ RegionSelector（AppKit 多屏框选，屏幕点坐标）
 ├─ RegionCaptureProvider → MacCaptureProvider（ScreenCaptureKit）
 ├─ ScrollSession（流式采集、后台匹配、恢复/暂停/重试/撤销、资源限制）
 │   └─ StitchCore（匹配、ScrollCaptureTracker 双向规则、CaptureLifecycle 输出资格，无 AppKit）
 └─ EditorController / EditorCanvas → paint / render → PNG / 剪贴板
```

没有第三方依赖、自建服务器或遥测。截图采集和处理不联网；仅用户主动检查更新时访问 GitHub。不是一个只有 UI 的原型；SwiftPM 编译可执行文件，脚本组装真实 .app。UI 使用 AppKit 便于精确控制非激活面板和鼠标坐标；未来可在不改变核心的情况下使用 SwiftUI 替换设置界面。

## 像素与坐标

框选使用 AppKit 全局坐标（点、左下原点），每块 NSScreen 独立覆盖层，鼠标位置统一转换为全局矩形。SCK sourceRect 转为对应屏幕左上原点的点坐标，输出按参与显示器的最高 backingScaleFactor 统一到像素。普通截图跨屏时逐屏合成，屏幕排列中的空隙透明，低 DPI 屏幕可能被放大。长截图禁止跨屏；捕获过程中显示器布局变化会中断并提示。

拼接与编辑统一使用图片像素和左上原点。亮度采样只压缩横向到最多 128 列，纵向保持实际像素；因此接缝没有纵向缩小再放大的累积误差。RGBA 合成使用 sRGB，导出 PNG。HDR 广色域不作原样保留承诺。

## 拼接策略

普通截图继续使用 SCScreenshotManager。长截图使用 SCStream，minimumFrameInterval 配置为 1/30 秒、queueDepth 为 3，回调在独立串行队列进行；这只是目标频率，不保证每台设备实际达到。只消费 complete 帧，复制 BGRA 像素后立即释放系统帧；AsyncThrowingStream 仅保留最新两帧，慢消费者不会无限积压或长期占用 IOSurface。

创建 SCStream 时重新获取边框/状态面板出现后的应用列表，再排除本应用，避免 prepare 时尚无可见窗口而漏掉随后出现的控件。异步创建期间取消仍会清理采集源。

ScrollProcessor actor 完成亮度采样、StitchCore 匹配和新增条带复制。UI 主线程只更新会话状态和节流后的缩略图。取消、重试、撤销后通过 generation 丢弃旧处理结果；超时检查另校验 revision，避免过期的失败结果覆盖刚恢复的状态。

ScrollCaptureTracker 不要求停稳：每帧都可与最近确认视口匹配，并维护文档顶部、底部和当前视口的位置。向上移动到新范围时只复制顶部新增条带，向下时只复制底部新增条带；范围内回看不增加图像。扩展前还要与对应端点直接核对位移，避免往返累计误差。失配后可通过任一端点找回位置，存在两个不同位置候选时拒绝猜测。原有 ContinuousStitchTracker 及 MatchResult 保持单向接口语义；新位移接口另返回带符号的像素偏移。搜索前后位移，要求至少约 22% 重叠；按原始纵向像素搜索，以每个纵向小区间最有纹理的行粗定位（检查所有列），对最佳候选使用完整重叠像素评分。候选歧义以相对误差判断；六个分带检查绝对误差及扣除轻微渲染噪声后的误差与字形梯度比例，避免背景吞没文字变化。重复帧需通过全图均值及显著变化像素比例两项检查。短暂模糊、丢帧或惯性回弹进入最长约 0.8 秒的恢复窗口，锚点保持不变；恢复成功即可继续。持续失配停止追加并提示等待接续，保留原锚点继续识别；可靠重叠回来后自动恢复。尺寸变化立即停止处理，资源/权限错误也不能自动跳过。静止时没有新帧也由 watchdog 检查超时。重试保留整个已确认范围；撤销按捕获顺序恢复两端检查点，并删除相应顶部或底部条带，不会跳过缺失内容。

完成时先停止生产，等待采集回调队列中已获准的像素复制完成，再关闭帧队列、排空剩余帧，最后后台合成。CaptureLifecycle 在纯 Swift 核心中管理采集、收尾、提交和停止；后台结果必须校验同一 generation 并获得一次性提交资格，取得资格到写剪贴板之间不允许异步挂起。取消后迟到的合成结果不能写剪贴板或重复回调。ScrollOutputAction 区分复制、编辑、保存：默认成功写入 PNG 剪贴板后才关闭，失败保留会话以便重试；只有明确的编辑操作交给 EditorController。保存操作先复制，取消保存对话框也不丢失已完成图片。测试注入独立 NSPasteboard，避免自动回归污染用户剪贴板。健康状态只显示预览和图标工具栏，明确异常以独立悬浮提示出现，提示不参与预览面板布局，尺寸/段数默认隐藏在更多菜单设置。末尾仍有失配时明确要求再次回车，才仅导出已确认部分；重试后尚未验证新画面也不能静默完成。取消则丢弃处理中结果，停止流、移除输出与临时键。

这是保守的全局垂直平移匹配，**不是**页面理解、OCR 或复杂光流。相似模板可能仍有误判风险，因此预览和真实应用人工验收必不可少。不能保证检测出每一种微小动画或固定元素。选区应排除固定栏、阴影、滚动条、头像悬浮件；窗口不能被其他应用覆盖、移位或缩放。

上限：普通截图 4000 万像素；长图 30000 像素高、3200 万像素、保留条带 RGBA 与匹配亮度帧合计 256 MB，先达到者暂停。临时合成还需额外内存；内存总量不等于该限制。每段只深拷贝新增像素条带，保留亮度帧以支持撤销；CGImage.cropping 本身共享原图，不能直接作为内存优化。缩略预览最多约每 150ms 更新，直接绘制片段，不为每帧分配整张长图。会话取消/完成即取消任务、移除临时热键和窗口，释放片段。编辑历史最多 30 步；裁剪后旧图可能被历史引用，关闭预览释放。

匹配、条带复制、最终合成已离开主线程。AppKit 缩略图绘制仍在主线程且已节流；超多片段仍可能增加预览开销。采集与识别均有界，不承诺任意滚动速度或动态页面都能接续。

## Windows 与工具集

现在只交付 macOS，未实现 Windows 版本。StitchCore 无 macOS API，可在支持 Swift 的平台编译；不承诺 Windows Swift 工具链或 UI 已经验证。如果未来 Windows 采用 C#/Rust，可保持 GrayFrame/MatchResult 语义，通过 C ABI 封装或移植，并用同一批固定图像测试向量验证。不要为未实现的平台增加空壳运行时。

采集、快捷键、剪贴板、窗口、权限是平台适配层；Windows 可使用 Windows Graphics Capture、RegisterHotKey、原生剪贴板和自己的 UI。当前 RegionCaptureProvider 边界仍使用 macOS CGImage/CGRect，是 macOS 内部的替换点，跨语言公共协议应另定义 pixel buffer（格式、步长、尺寸、scale、时间戳）和平台中立矩形，不能把 CGImage 暴露为跨平台 ABI。

工具宿主已用 `screenshot.region`、`screenshot.scroll` 等稳定命名注册快捷键；未来可把菜单元数据、设置、生命周期包装为 ToolDescriptor/ToolModule，再增加取色、文本处理等模块。无需现在就引入插件加载器、脚本权限或共享网络服务。截图编辑和拼接状态不得变成所有工具共用的全局变量。

## 国际化

默认中文。菜单使用 Bundle.module 的 zh-Hans/en Localizable.strings；多数详细提示和编辑工具名仍为中文。目录与查找入口已预留，完整英文翻译尚未完成；新增语言时应把其余 UI 字符串逐步提取为稳定 key，而非直接翻译技术标识。

## 技术依据与边界

- Apple [Meet ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10156/) 与 [Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/)：持续帧、指定回调队列、帧状态、帧率与 IOSurface 生命周期。
- 未掌握微信内部采集或拼接实现，不把外部 AI 的通用算法清单当成微信技术证据。当前仅做垂直平移匹配，不引入透视变换；截图文字精确裁接，不用接缝融合掩盖错位。
- 跨平台复用新增 TrackingResult / ContinuousStitchTracker；SCStream、AppKit、CGImage 仍属于 macOS 适配层。

## 捕获与原位标注

CaptureBoundary 使用无激活能力、ignoresMouseEvents=true 的透明面板；边框绘制在采集矩形外，随 ScrollSession 完成/取消一起释放。捕获状态面板常驻显示固定横向比例、可滚动的已拼接内容，默认跟随新增的一端，可放大预览和关闭自动跟随；优先放在选区右/左侧，空间不足时在上下或屏幕边缘定位。两者均由采集过滤器排除整个本应用。

EditorController 使用原选区位置的无标题窗口、逐屏半透明遮罩和独立浮动工具栏。EditorCanvas 继续使用原始图片像素做标注，视图的 preferredWidth / maximumZoom 只改变显示比例；保存与复制继续调用同一个 render。文字通过内嵌 NSTextField 输入，提交后成为标注。Enter/✓ 复制并关闭所有编辑窗口，Esc/× 取消；Cmd+C 可仅复制，Cmd+S 打开置于遮罩上方的原生保存面板。长图只在可视区域内建立滚动视口，不为屏幕高度生成整张巨型窗口。

普通截图可从工具栏切换为同一选区的滚动采集；该转换重新采集目标应用，不把冻结画面或已有普通标注拼进长图。长图条带按文档顺序保存，操作检查点按捕获顺序保存，使双向补图与撤销互不混淆。

原位编辑滚动规则：CaptureScrollView 对普通截图直接忽略 scrollWheel，横纵弹性均为 none；只有图像显示高度超过选区的长图才开启滚动。Annotation 独立保存颜色和原图像素线宽；拖动、文字提交、撤销/重做均保留该样式，改变当前画笔不会修改已有标注。圆形以椭圆路径渲染；等宽高拖动得到圆。打码仍用实心黑色覆盖，不跟随画笔颜色。

ScrollPreviewCanvas 直接绘制已保存的新增条带，只画与当前视口相交的内容，不把整张长图压缩进固定高度的 NSImageView；预览不会改变合成或导出像素。放大时提高可见宽度；关闭跟随后可滚动回看，继续拼接不强制拉回末尾。


## 正式版更新

`ReleaseUpdate` 负责数字版本比较、正式 Release 和资源约束、校验值及 ZIP 校验；`UpdateDownload` 负责 HTTPS/已有 gh 连接和独立临时目录；`UpdateWindow` 管理确认、取消和安装占用状态；macOS 专用的 `UpdateBundle` / `UpdateInstaller` 负责签名、架构、同盘替换、备份和回滚。更新不依赖截图权限。

安装助手使用当前程序的副本，运行于用户缓存目录，和 `make dev` 共用互斥锁。助手先核对任务、当前包及候选包并报告就绪，旧进程才退出。固定安装位置且不提权；不会执行下载脚本、移除 quarantine 或重新签名下载包。有 Team ID 的现有安装只接受相同 Team ID。

将来 Windows 实现应复用版本和资源协议及测试向量，另实现平台下载、签名验证和安装后端，不能复用 macOS helper、AppKit 或 Security API。当前代码不宣称 Windows 已验证。

协议来源：[GitHub Releases API](https://docs.github.com/en/rest/releases/releases)、[Release assets API](https://docs.github.com/en/rest/releases/assets)；发行身份与系统验证参见 [Apple Developer ID](https://developer.apple.com/developer-id/)。SHA-256 用于完整性检查，不能替代 Developer ID 信任身份。

## 原生方案的取舍

保留 AppKit / ScreenCaptureKit 与共享 Swift 核心，不在截图路径引入 MyGo、Go 或 WebView。跨平台共用的是匹配和会话规则；采集、窗口、权限、剪贴板及图像存储通过平台适配接入。其他平台需通过适配层接入双向会话 API；既有单向接口保持兼容，不向旧 C ABI 偷加新的结果枚举。

首次明确截图时调用系统原生录屏申请；明确截图直接调用系统请求，不显示自建权限浮层，不自动重试；实际系统弹窗及授权方式由操作系统处理。启动不申请权限，不自动重建授权或更改系统隐私设置。系统接口通过 ScreenPermissionAccess 注入，测试不会申请真实权限。

回归除正常连续帧外，还覆盖双向补图/往返去重/向上撤销的完整 RGBA 对照、超过队列容量的突发帧收尾、合成中取消及独立剪贴板检查。合成测试不代表所有真实应用和系统权限状态已通过人工验收。
