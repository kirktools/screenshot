# Screenshot

A lightweight, native macOS capture tool. **One selection for screenshots, scrolling captures, and GIFs.**

[Website](https://kirktools.github.io/screenshot/) · [Download](https://github.com/kirktools/screenshot/releases/latest) · [简体中文](README.md)

![Native in-place editing and icon toolbar](docs/images/editor-features.png)

- **Region capture:** hover to select a window, drag a region, adjust its edges, and annotate in place.
- **Scrolling screenshots:** scroll up or down manually; automatic overlap matching and deduplication. Stable top/bottom bars appear once. Preview, undo, and recovery are available.
- **GIF recording:** reuse the selected region, start/stop manually, preview, and save.
- **Editable text:** move and re-edit text, drag corners to scale, use the rotation handle, or enter precise size, angle, and opacity. Arrows, shapes, solid redaction, crop, and undo/redo remain available.
- **Pinned references:** keep the rendered image above other windows, move or resize it. The capture toolbar can be moved too.
- **Text extraction and translation:** recognize and copy text on your Mac. Translate on device (macOS 15+) or with AI, and hover to highlight matching passages in the original and translation.
- **AI Image Analysis:** ask about a chart, a formula, or a question in your screenshot. Preview the selection before sending it.

## Use

1. Press **⌘⇧2** and select a region or window.
2. Annotate directly, or choose scrolling capture, GIF recording, or pinning from the toolbar.
3. **Return / ✓** copies and finishes a screenshot; **Esc / ×** cancels. Stop a GIF to preview and save it.

Pixel dimensions appear above the selection. Open **AI Tools** on the left of the capture toolbar and choose **Extract Text** to copy or translate text, or **AI Image Analysis** to ask about the image. See the [usage guide](docs/USAGE.md#截图文字与翻译).

Disable the separate scrolling shortcut in Settings to use only one global shortcut, or keep **⌘⇧7** for direct scrolling capture. Shortcuts are configurable.

![18-second demo: text transforms, fixed bars, GIF recording and pinned images](docs/images/features-demo.gif)

[MP4](docs/images/features-demo.mp4) · 18 seconds with original electronic music, covering text transforms, fixed-bar scrolling, actual GIF encoding, and pinned images. Native UI and synthetic content; script-driven, with edited pacing rather than mouse interactions.

## Install

Requires **macOS 14+**, Apple Silicon or Intel. Download the DMG and drag Screenshot into Applications. Screen Recording permission is required; Accessibility and microphone permissions are not.

Current releases are not Apple Developer ID signed or notarized. Verify the download source and follow macOS prompts; do not disable Gatekeeper or SIP. See the [installation guide](docs/USAGE.md#安装与权限).

For development or PR testing (Swift 6+, Command Line Tools, Python 3):

```sh
make dev
```

This updates a separate **Screenshot Dev**, with independent permissions and settings and default shortcuts **⌃⌥2 / ⌃⌥7**. It does not replace the daily app. This README describes current source capabilities; available downloads follow their [release notes](https://github.com/kirktools/screenshot/releases/latest).

## Limits and privacy

Scrolling capture works best with static, vertically scrolling content. Stable bars near the top/bottom can be separated; central overlays, animations, dynamic messages, reflow, repeated patterns, and fast jumps may prevent a reliable match. Horizontal and cross-display scrolling captures are unsupported. There is no fixed height limit, but memory and pixel budgets still apply.

GIF recording is limited to 60 seconds, up to 10 fps and 1280 pixels on the longest edge; no audio or cursor capture.

Capture, editing, and text recognition run on your Mac and require no account. When you choose AI translation, the selected service receives the recognized text. When you confirm AI image analysis, it receives the previewed selection and your question. Timing diagnostics are local and optional. See [Privacy](docs/PRIVACY.md) and [Usage](docs/USAGE.md).

## Contribute

Issues and PRs are welcome. Include your system version, reproduction steps, and non-sensitive examples. See [Contributing](CONTRIBUTING.md), [Architecture](docs/ARCHITECTURE.md), and [Security](SECURITY.md).

[MIT](LICENSE) · Copyright © 2026 kirktools
