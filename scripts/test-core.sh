#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$PWD/.build/core-check"
mkdir -p "$output" "$PWD/.build/cache/clang"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache/clang"
swiftc -O -enable-testing -emit-library -emit-module -module-name StitchCore \
  Sources/StitchCore/*.swift -emit-module-path "$output/StitchCore.swiftmodule" -o "$output/libStitchCore.dylib"
swiftc -O -D STANDALONE_TESTS -I "$output" -L "$output" -lStitchCore \
  -Xlinker -rpath -Xlinker "$output" \
  Tests/StitchCoreTests/StitchMatcherTests.swift scripts/CoreTestMain.swift -o "$output/core-tests"
"$output/core-tests"
