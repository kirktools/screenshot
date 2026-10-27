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
