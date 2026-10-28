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
# 编译产物使用固定的虚拟源码根目录，不嵌入本机用户名和工作区位置。
build_flags+=(-Xswiftc -file-prefix-map -Xswiftc "$PWD=/screenshot"
              -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/screenshot"
              -Xcc "-ffile-prefix-map=$PWD=/screenshot"
              -Xlinker -oso_prefix -Xlinker "$PWD/")
if [[ "${SCREENSHOT_NATIVE_BUILD:-0}" == 1 ]]; then build_flags+=(--build-system native); fi
if [[ "${SCREENSHOT_DISABLE_BUILD_SANDBOX:-0}" == 1 ]]; then build_flags+=(--disable-sandbox); fi
variant=${SCREENSHOT_VARIANT:-release}
case "$variant" in
  release) app_name=Screenshot; bundle_id=com.kirktools.screenshot ;;
  development) app_name='Screenshot Dev'; bundle_id=com.kirktools.screenshot.dev; export SCREENSHOT_SKIP_PACKAGING=1 ;;
  *) echo 'SCREENSHOT_VARIANT 只能是 release 或 development' >&2; exit 1 ;;
esac
app="$PWD/dist/$app_name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  package_inputs=$(mktemp -d "$PWD/.build/package-inputs.XXXXXX")
  trap 'rm -rf "$package_inputs"' EXIT
  swift build "${build_flags[@]}" -c "$configuration" --triple arm64-apple-macosx14.0
  arm_path=$(swift build "${build_flags[@]}" -c "$configuration" --triple arm64-apple-macosx14.0 --show-bin-path)
  # 新版 SwiftPM 的 Xcode 后端可能为不同架构返回同一个输出目录。
  cp "$arm_path/Screenshot" "$package_inputs/arm64"
  swift build "${build_flags[@]}" -c "$configuration" --triple x86_64-apple-macosx14.0
  intel_path=$(swift build "${build_flags[@]}" -c "$configuration" --triple x86_64-apple-macosx14.0 --show-bin-path)
  cp "$intel_path/Screenshot" "$package_inputs/x86_64"
  lipo -create "$package_inputs/arm64" "$package_inputs/x86_64" -output "$app/Contents/MacOS/Screenshot"
  bin_path=$intel_path
else
  swift build "${build_flags[@]}" -c "$configuration"
  bin_path=$(swift build "${build_flags[@]}" -c "$configuration" --show-bin-path)
  cp "$bin_path/Screenshot" "$app/Contents/MacOS/Screenshot"
fi
# AppLocalization 显式读取标准 Contents/Resources 内的语言资源包。
resource="$bin_path/Screenshot_Screenshot.bundle"
[[ -d "$resource" ]] || { echo '构建缺少语言资源包。' >&2; exit 1; }
python3 - "$app" <<'PYTHON'
from pathlib import Path
import shutil,sys
app=Path(sys.argv[1])
for path in [app/'Contents/MacOS/KirkScreenshot', app/'Contents/Resources/KirkScreenshot_KirkScreenshot.bundle']:
    if path.is_symlink() or path.is_file(): path.unlink()
    elif path.is_dir(): shutil.rmtree(path)
PYTHON
cp -R "$resource" "$app/Contents/Resources/"

cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$app/Contents/Info.plist"
if [[ "$variant" == development ]]; then
  cp Resources/DevAppIcon.icns "$app/Contents/Resources/AppIcon.icns"
else
  cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$app/Contents/Info.plist"
# 将源码身份写入设置窗口；本地验收可明确区分分支、提交和未提交修改。
python3 - "$app/Contents/Info.plist" <<'PYTHON'
import os, plistlib, subprocess, sys
from pathlib import Path
p = Path(sys.argv[1])
def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()
try:
    revision = git('rev-parse', '--short=8', 'HEAD')
    branch = os.environ.get('GITHUB_HEAD_REF') or git('branch', '--show-current') or 'detached'
    dirty = bool(git('status', '--porcelain'))
    label = f'{branch} @ {revision}' + (' · 有本地修改' if dirty else '')
except subprocess.CalledProcessError:
    label = '源码快照'
with p.open('rb') as f:
    data = plistlib.load(f)
data['BuildSource'] = label
with p.open('wb') as f:
    plistlib.dump(data, f)
PYTHON
# CI 测试可使用 ad-hoc；make dev 与正式 Release 必须使用稳定证书身份。
python3 scripts/sign-app.py "$app" --mode "${SCREENSHOT_SIGNING_MODE:-adhoc}"
"$app/Contents/MacOS/Screenshot" --packaged-resources-test
if [[ "${SCREENSHOT_SKIP_PACKAGING:-0}" != 1 ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$app" "$PWD/dist/Screenshot-$version-macOS.zip"
  scripts/package-dmg.sh
  python3 scripts/check-public-content.py --app "$app" --zip "$PWD/dist/Screenshot-$version-macOS.zip"
else
  python3 scripts/check-public-content.py --app "$app"
fi
echo "已构建：$app"
