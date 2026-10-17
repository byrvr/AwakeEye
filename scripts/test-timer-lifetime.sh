#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_build_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/coffeebull-timer-tests.XXXXXXXX")"
trap '/bin/rm -rf -- "$test_build_dir"' EXIT
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
compiler="$(/usr/bin/xcrun --find clang)"
sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
"$compiler" -fobjc-arc -isysroot "$sdk_path" \
  -I "$repo_root/Packages/KYASleepWakeTimer/Sources/KYASleepWakeTimer/include" \
  -I "$repo_root/Packages/KYAApplicationSupport/Sources/KYAApplicationSupport/include" \
  -I "$repo_root/Packages/KYACommon/Sources/KYACommon/include" \
  -framework Foundation -framework AppKit \
  "$repo_root/tests/test_timer_lifetime.m" -o "$test_build_dir/test-timer-lifetime"
"$test_build_dir/test-timer-lifetime"
