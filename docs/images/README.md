# 文档素材

- `editor.png`：AppKit 原位编辑画面与工具栏，使用内置示例内容。
- `scrolling.gif` / `scroll-preview.png`：合成滚动帧驱动的实际预览控件。
- `scroll-result.png`：同一离线演示拼接的 PNG，与生成参考逐像素比较通过后才导出。

素材不包含私人聊天或桌面背景，也不读取屏幕。重新生成（先构建应用）：

```bash
SCREENSHOT_DOCUMENTATION_DIR="$PWD/docs/images" \
  'dist/Screenshot.app/Contents/MacOS/Screenshot' --overlay-demo
SCREENSHOT_DOCUMENTATION_DIR="$PWD/docs/images" \
  'dist/Screenshot.app/Contents/MacOS/Screenshot' --documentation-scroll-demo
```

这些素材展示界面和拼接流程，不代表真实应用滚动兼容性验证。真实桌面采集仍需按验收文档测试。修改相关界面后请同步更新素材。

`screenshot-intro.gif` / `screenshot-intro.mp4` / `screenshot-intro-poster.png`：用上述当前原生控件快照与合成滚动内容组合的 16 秒、16:9 基础流程演示，无声、不自动播放，不是鼠标操作实录，也不是 GIF 录制功能的实拍视频。更新于本轮界面调整后，展示包含 GIF 与贴图入口的工具栏。
