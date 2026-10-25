#!/bin/bash
# 构建当前分支，更新唯一的本地应用；不触碰系统隐私权限。
set -euo pipefail
cd "$(dirname "$0")/.."
export KIRK_NATIVE_BUILD=${KIRK_NATIVE_BUILD:-1}
export KIRK_SKIP_PACKAGING=1
scripts/build-app.sh
python3 scripts/install-dev.py
