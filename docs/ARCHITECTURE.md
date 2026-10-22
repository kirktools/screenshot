# 架构与演进边界

## 当前实现

```text
AppDelegate（菜单、权限、一次只运行一个捕获会话）
 ├─ HotkeyRegistry（稳定工具 ID → Carbon 注册 → 动作闭包）
 ├─ RegionSelector（AppKit 多屏框选，屏幕点坐标）
 ├─ RegionCaptureProvider → MacCaptureProvider（ScreenCaptureKit）
 ├─ ScrollSession（采样、稳定性检查、暂停/重试/撤销、资源限制）
 │   └─ StitchCore（纯 Swift / Foundation 亮度匹配，无 AppKit）
 └─ EditorController / EditorCanvas → paint / render → PNG / 剪贴板
```

没有第三方依赖、服务器、网络调用或遥测。不是一个只有 UI 的原型；SwiftPM 编译可执行文件，脚本组装真实 .app。UI 使用 AppKit 便于精确控制非激活面板和鼠标坐标；未来可在不改变核心的情况下使用 SwiftUI 替换设置界面。

## 像素与坐标

框选使用 AppKit 全局坐标（点、左下原点），每块 NSScreen 独立覆盖层，鼠标位置统一转换为全局矩形。SCK sourceRect 转为对应屏幕左上原点的点坐标，输出按参与显示器的最高 backingScaleFactor 统一到像素。普通截图跨屏时逐屏合成，屏幕排列中的空隙透明，低 DPI 屏幕可能被放大。长截图禁止跨屏；捕获过程中显示器布局变化会中断并提示。

拼接与编辑统一使用图片像素和左上原点。亮度采样只压缩横向到最多 128 列，纵向保持实际像素；因此接缝没有纵向缩小再放大的累积误差。RGBA 合成使用 sRGB，导出 PNG。HDR 广色域不作原样保留承诺。

## 拼接策略

220ms 间隔串行抓取，无累积任务队列；连续两帧亮度差低于阈值才认为滚动停稳。搜索前后位移，要求至少约 22% 重叠，建议用户保留半屏以上。按原始纵向像素搜索位移（横向与行抽样控制开销），检查重叠误差、多个相近候选和分带误差。重复帧丢弃，反向或不确定匹配暂停，不修改已接入片段。重试仍与最后保留帧比较，不会把当前帧直接设为新的基准来跳过缺失内容。

这是保守的全局垂直平移匹配，**不是**页面理解、OCR 或复杂光流。相似模板可能仍有误判风险，因此预览和真实应用人工验收必不可少。不能保证检测出每一种微小动画或固定元素。选区应排除固定栏、阴影、滚动条、头像悬浮件；窗口不能被其他应用覆盖、移位或缩放。

上限：普通截图 4000 万像素；长图 30000 像素高、3200 万像素、保留帧 RGBA 总量 256 MB，先达到者暂停。临时合成还需额外内存；内存总量不等于该限制。缩略预览直接绘制片段，不为每次更新分配整张长图。会话取消/完成即取消任务、移除临时热键和窗口，释放片段。编辑历史最多 30 步；裁剪后旧图可能被历史引用，关闭预览释放。

当前匹配和图像渲染在主线程执行，便于状态串行和 AppKit 安全性；超大选区可能短暂影响 UI。若真实测量发现瓶颈，下一步把 GrayFrame 匹配放入独立 actor，并以会话 generation 校验返回结果，防止取消后的任务写回。

## Windows 与工具集

现在只交付 macOS，未实现 Windows 版本。StitchCore 无 macOS API，可在支持 Swift 的平台编译；不承诺 Windows Swift 工具链或 UI 已经验证。如果未来 Windows 采用 C#/Rust，可保持 GrayFrame/MatchResult 语义，通过 C ABI 封装或移植，并用同一批固定图像测试向量验证。不要为未实现的平台增加空壳运行时。

采集、快捷键、剪贴板、窗口、权限是平台适配层；Windows 可使用 Windows Graphics Capture、RegisterHotKey、原生剪贴板和自己的 UI。当前 RegionCaptureProvider 边界仍使用 macOS CGImage/CGRect，是 macOS 内部的替换点，跨语言公共协议应另定义 pixel buffer（格式、步长、尺寸、scale、时间戳）和平台中立矩形，不能把 CGImage 暴露为跨平台 ABI。

工具宿主已用 `screenshot.region`、`screenshot.scroll` 等稳定命名注册快捷键；未来可把菜单元数据、设置、生命周期包装为 ToolDescriptor/ToolModule，再增加取色、文本处理等模块。无需现在就引入插件加载器、脚本权限或共享网络服务。截图编辑和拼接状态不得变成所有工具共用的全局变量。

## 国际化

默认中文。菜单使用 Bundle.module 的 zh-Hans/en Localizable.strings；多数详细提示和编辑工具名仍为中文。目录与查找入口已预留，完整英文翻译尚未完成；新增语言时应把其余 UI 字符串逐步提取为稳定 key，而非直接翻译技术标识。
