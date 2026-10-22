# 文档素材

- `editor.png`：实际 AppKit 原位编辑画面与工具栏，内容由内置示例生成。
- `scrolling.gif` / `scroll-preview.png`：真实滚动采集测试中记录的预览控件。
- `scroll-result.png`：同一测试实际采集、拼接的 PNG，与生成参考逐行逐列比较通过后才导出。

不包含私人聊天或桌面背景。重新生成（先构建应用；第二项需要已有录屏权限，会短暂显示测试窗口）：

```bash
KIRK_DOCUMENTATION_DIR="$PWD/docs/images" \
  'dist/Kirk Screenshot.app/Contents/MacOS/KirkScreenshot' --overlay-demo
KIRK_DOCUMENTATION_DIR="$PWD/docs/images" KIRK_SCROLL_FIXTURE_STYLE=showcase \
  scripts/test-live-scroll.sh
```

视频暂未提供。请在修改相关界面后更新素材。
