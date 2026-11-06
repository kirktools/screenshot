# 文档素材

`editor-features.png` 展示文字实际缩放、旋转后的原生编辑界面。`features-demo.gif`、同名 MP4 与封面是 **24 秒、16:9** 的新功能演示：

1. 文字角点缩放与手柄旋转，直接调用真实画布的手势处理逻辑。
2. 带固定顶部导航、局部悬浮底栏的合成页面，经真实长图会话拼接和预览。
3. 合成连续帧驱动真实 GIF 会话，展示实际编码的 GIF、录制控件和预览。
4. 真实置顶贴图窗口的移动与等比缩放。

不读取桌面，不包含私人聊天。画面节奏经过编排，不是鼠标实录，也不代表所有真实应用均通过兼容性验收。视频无声、不自动播放。

## 重新生成

需要 Swift/Command Line Tools 和安装了 Pillow 的 Python 环境。推荐本地虚拟环境，避免改变系统 Python：

```sh
python3 -m venv .local/media-env
.local/media-env/bin/python -m pip install Pillow
make demo-media PYTHON=.local/media-env/bin/python
```

该命令只构建开发包、运行离线演示和更新上述公开素材，不安装应用、不请求录屏权限，不发布。原始分镜、示例 GIF 和接触表留在忽略的 `.build/`，只复制指定文件到 `docs/images/`。

`scrolling.gif`、`scroll-preview.png`、`scroll-result.png` 仍保留为基础拼接流程示例，可通过 `--documentation-scroll-demo` 重新导出；这组素材与主页的新功能演示分开。

## 开发构建边界

演示 Swift 源码独立放在 `Sources/Screenshot/Development/`。普通开发包与正式包默认从源码列表中排除该目录，导出入口、合成录制适配器也受编译条件保护。`make demo-media` 才启用 `SCREENSHOT_BUILD_DEMO=1`，并且只能用于 development 变体；正式构建传入该开关会直接拒绝。

演示使用独立的 `.build/feature-demo.*/compilation` 和 `.build/feature-demo.*/app`，不会覆盖 `dist/` 中的普通应用。构建脚本检查普通包不含演示入口及 GIF/MP4 素材，避免后续误打包。
