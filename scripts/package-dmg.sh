#!/bin/bash
# 使用系统自带工具生成只读压缩安装镜像，不依赖 Finder 自动化。
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(tr -d '\r\n' < VERSION)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION 必须是 x.y.z' >&2; exit 1; }
app="$PWD/dist/Kirk Screenshot.app"
[[ -d "$app" ]] || { echo '请先构建 dist/Kirk Screenshot.app。' >&2; exit 1; }
codesign --verify --deep --strict "$app"
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$app_version" == "$version" ]] || { echo '应用版本与 VERSION 不一致，请重新构建。' >&2; exit 1; }
mkdir -p .build
staging=$(mktemp -d "$PWD/.build/dmg-stage.XXXXXX")
trap 'rm -rf "$staging"' EXIT
# 使用独立副本，避免为创建镜像改动已签名的应用或混入 dist 中的旧产物。
ditto "$app" "$staging/Kirk Screenshot.app"
ln -s /Applications "$staging/Applications"
image="$PWD/dist/Kirk-Screenshot-$version-macOS.dmg"
hdiutil create -ov -format UDZO -fs HFS+ -volname 'Kirk Screenshot' -srcfolder "$staging" "$image"
hdiutil verify "$image"
echo "已生成安装镜像：$image"
