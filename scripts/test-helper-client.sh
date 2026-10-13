#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_build_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/coffeebull-helper-client-tests.XXXXXXXX")"
trap '/bin/rm -rf -- "$test_build_dir"' EXIT
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
compiler="$(/usr/bin/xcrun --find clang)"
sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
"$compiler" -fobjc-arc -isysroot "$sdk_path" -mmacosx-version-min=12.0 \
  -framework Foundation -framework AppKit -framework Security \
  "$repo_root/tests/test_helper_client.m" -o "$test_build_dir/test-helper-client"
"$test_build_dir/test-helper-client"
