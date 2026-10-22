#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(tr -d '\n' < VERSION)
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo 'VERSION 必须是 x.y.z' >&2; exit 1; fi
configuration=${CONFIGURATION:-release}
mkdir -p "$PWD/.build/cache/clang" "$PWD/.build/cache/swiftpm"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/cache/clang"
build_flags=(--cache-path "$PWD/.build/cache/swiftpm")
if [[ "${KIRK_NATIVE_BUILD:-0}" == 1 ]]; then build_flags+=(--build-system native); fi
if [[ "${KIRK_DISABLE_BUILD_SANDBOX:-0}" == 1 ]]; then build_flags+=(--disable-sandbox); fi
app="$PWD/dist/Kirk Screenshot.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  package_inputs=$(mktemp -d "$PWD/.build/package-inputs.XXXXXX")
  trap 'rm -rf "$package_inputs"' EXIT
  swift build "${build_flags[@]}" -c "$configuration" --triple arm64-apple-macosx14.0
  arm_path=$(swift build "${build_flags[@]}" -c "$configuration" --triple arm64-apple-macosx14.0 --show-bin-path)
  # 新版 SwiftPM 的 Xcode 后端可能为不同架构返回同一个输出目录。
  cp "$arm_path/KirkScreenshot" "$package_inputs/arm64"
  swift build "${build_flags[@]}" -c "$configuration" --triple x86_64-apple-macosx14.0
  intel_path=$(swift build "${build_flags[@]}" -c "$configuration" --triple x86_64-apple-macosx14.0 --show-bin-path)
  cp "$intel_path/KirkScreenshot" "$package_inputs/x86_64"
  lipo -create "$package_inputs/arm64" "$package_inputs/x86_64" -output "$app/Contents/MacOS/KirkScreenshot"
  bin_path=$intel_path
else
  swift build "${build_flags[@]}" -c "$configuration"
  bin_path=$(swift build "${build_flags[@]}" -c "$configuration" --show-bin-path)
  cp "$bin_path/KirkScreenshot" "$app/Contents/MacOS/KirkScreenshot"
fi
# SwiftPM Bundle.module 也在主 Bundle 内查找该资源包。
for resource in "$bin_path"/*.bundle; do
  [[ -d "$resource" ]] || continue
  cp -R "$resource" "$app/Contents/Resources/"
done
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$app/Contents/Info.plist"
# 默认 ad-hoc 签名仅保证包完整性，不是 Developer ID 签名或公证。
identity=${SIGN_IDENTITY:--}
if [[ "$identity" == '-' ]]; then
  codesign --force --deep --sign - "$app"
else
  codesign --force --deep --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$PWD/dist/Kirk-Screenshot-$version-macOS.zip"
echo "已构建：$app"
