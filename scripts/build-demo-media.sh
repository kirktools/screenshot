#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
media_python="${PYTHON:-python3}"
"$media_python" -c 'import PIL' || { echo '请先在本地虚拟环境安装 Pillow，再传入 PYTHON=解释器路径。' >&2; exit 1; }
mkdir -p .build
media_root="$(mktemp -d "$PWD/.build/feature-demo.XXXXXX")"
mkdir -p "$media_root/native"
SCREENSHOT_BUILD_DEMO=1 SCREENSHOT_VARIANT=development SCREENSHOT_NATIVE_BUILD=1 SCREENSHOT_SKIP_PACKAGING=1 SCREENSHOT_BUILD_SCRATCH="$media_root/compilation" SCREENSHOT_APP_OUTPUT_DIR="$media_root/app" scripts/build-app.sh
SCREENSHOT_DOCUMENTATION_DIR="$media_root/native" "$media_root/app/Screenshot Dev.app/Contents/MacOS/Screenshot" --documentation-features-demo
"$media_python" scripts/build-feature-demo.py "$media_root"
swiftc scripts/EncodeFeatureDemo.swift -o "$media_root/encode"
"$media_root/encode" "$media_root"
cp "$media_root/native/editor.png" docs/images/editor-features.png
for name in features-demo.gif features-demo.mp4 features-demo-poster.png; do
    cp "$media_root/$name" "docs/images/$name"
done
python3 scripts/check-public-content.py
echo '已更新公开演示素材；原始分镜留在忽略的 .build/，未读取桌面或安装应用。'
