#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/live-fixture/ScrollFixture.app/Contents/MacOS .build/cache/clang
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache/clang"
fixture="$PWD/.build/live-fixture/ScrollFixture.app"
swiftc -O scripts/ScrollFixture.swift -o "$fixture/Contents/MacOS/ScrollFixture"
cat > "$fixture/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.kirktools.screenshot.fixture</string><key>CFBundleExecutable</key><string>ScrollFixture</string><key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --sign - "$fixture"
SCREENSHOT_SCROLL_FIXTURE_EXEC="$fixture/Contents/MacOS/ScrollFixture" \
  'dist/Screenshot.app/Contents/MacOS/Screenshot' --live-scroll-self-test
