#!/bin/bash
# 检查实际挂载的安装包，不启动应用、不读取桌面、不改动录屏授权。
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(tr -d '\r\n' < VERSION)
image="$PWD/dist/Kirk-Screenshot-$version-macOS.dmg"
mkdir -p .build
mountpoint=$(mktemp -d "$PWD/.build/dmg-mount.XXXXXX")
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then hdiutil detach "$mountpoint"; fi
  rmdir "$mountpoint"
}
trap cleanup EXIT
hdiutil verify "$image"
hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" "$image"
mounted=1
[[ -d "$mountpoint/Screenshot.app" ]] || { echo "DMG 缺少应用。" >&2; exit 1; }
[[ -L "$mountpoint/Applications" && "$(readlink "$mountpoint/Applications")" == /Applications ]] || { echo "DMG 缺少正确的 Applications 安装入口。" >&2; exit 1; }
[[ "$(find "$mountpoint" -mindepth 1 -maxdepth 1 ! -name '.*' | wc -l | tr -d ' ')" == 2 ]] || { echo "DMG 包含额外文件。" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mountpoint/Screenshot.app/Contents/Info.plist")" == "$version" ]] || { echo "DMG 应用版本不一致。" >&2; exit 1; }
codesign --verify --deep --strict "$mountpoint/Screenshot.app"
cmp "$mountpoint/Screenshot.app/Contents/MacOS/KirkScreenshot" 'dist/Screenshot.app/Contents/MacOS/KirkScreenshot'
echo 'DMG 验证通过：应用、Applications 安装入口、版本、签名与二进制一致。'
