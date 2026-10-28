#!/bin/bash
# 构建独立开发版，不覆盖日常 Screenshot，也不触碰系统隐私权限。
set -euo pipefail
cd "$(dirname "$0")/.."
export SCREENSHOT_NATIVE_BUILD=${SCREENSHOT_NATIVE_BUILD:-1}
export SCREENSHOT_SKIP_PACKAGING=1
export SCREENSHOT_SIGNING_MODE=local
export SCREENSHOT_VARIANT=development
scripts/build-app.sh
python3 scripts/install-dev.py
