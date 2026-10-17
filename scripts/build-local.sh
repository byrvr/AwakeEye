#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${AWAKEEYE_BUILD_DIR:-${COFFEEBULL_BUILD_DIR:-$repo_root/build}}"
output_dir="${AWAKEEYE_OUTPUT_DIR:-${COFFEEBULL_OUTPUT_DIR:-$repo_root/dist}}"
mkdir -p "$build_dir" "$output_dir"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
compiler="$(/usr/bin/xcrun --find clang)"
sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$build_dir/helper"
"$compiler" -fobjc-arc -isysroot "$sdk_path" -mmacosx-version-min=12.0 \
  -framework Foundation -framework Security -lbsm \
  "$repo_root/Helper/CoffeeBullHelper.m" -o "$build_dir/helper/CoffeeBullHelper"
/usr/bin/codesign --force --options runtime --sign - "$build_dir/helper/CoffeeBullHelper"
helper_digest="$(/usr/bin/shasum -a 256 "$build_dir/helper/CoffeeBullHelper" | /usr/bin/awk '{print $1}')"
printf '#define COFFEEBULL_HELPER_SHA256 @"%s"\n' "$helper_digest" \
  > "$repo_root/KeepingYouAwake/KYAHelperBuildIdentity.h"

# A personal build: no upstream signing identity, notarization, or updater.
/usr/bin/xcodebuild clean build \
  -workspace "$repo_root/KeepingYouAwake.xcworkspace" \
  -scheme 'KeepingYouAwake (Direct)' \
  -configuration Release \
  -derivedDataPath "$build_dir" \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=YES \
  ONLY_ACTIVE_ARCH=YES

if [[ -d "$output_dir/AwakeEye.app" ]]; then
  previous_export="$(/usr/bin/mktemp -d "$build_dir/previous-export.XXXXXXXX")"
  /bin/mv "$output_dir/AwakeEye.app" "$previous_export/AwakeEye.app"
fi
/usr/bin/ditto "$build_dir/Build/Products/Release/AwakeEye.app" "$output_dir/AwakeEye.app"
/usr/bin/install -m 755 "$build_dir/helper/CoffeeBullHelper" "$output_dir/AwakeEye.app/Contents/Resources/CoffeeBullHelper"
/usr/bin/codesign --force --options runtime --sign - "$output_dir/AwakeEye.app/Contents/Library/LoginItems/KeepingYouAwake Launcher.app"
/usr/bin/codesign --force --options runtime --sign - "$output_dir/AwakeEye.app"
embedded_digest="$(/usr/bin/shasum -a 256 "$output_dir/AwakeEye.app/Contents/Resources/CoffeeBullHelper" | /usr/bin/awk '{print $1}')"
[[ "$embedded_digest" == "$helper_digest" ]] || { printf 'Embedded helper changed during signing.\n' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$output_dir/AwakeEye.app"
printf 'Built %s\n' "$output_dir/AwakeEye.app"
