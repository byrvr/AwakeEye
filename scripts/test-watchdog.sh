#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_build_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/coffeebull-watchdog-tests.XXXXXXXX")"
trap '/bin/rm -rf -- "$test_build_dir"' EXIT

# Prefer installed Xcode when CLT and Xcode SDK versions differ. The explicit
# SDK path also prevents clang from selecting a different default SDK.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
compiler="$(/usr/bin/xcrun --find clang)"
sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
"$compiler" -fobjc-arc -isysroot "$sdk_path" -mmacosx-version-min=12.0 \
  -framework Foundation -framework Security -lbsm \
  "$repo_root/Helper/CoffeeBullHelper.m" -o "$test_build_dir/sleep-helper"

"$test_build_dir/sleep-helper" --self-test
