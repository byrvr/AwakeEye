#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${COFFEEBULL_BUILD_DIR:-$repo_root/build}"
output_dir="${COFFEEBULL_OUTPUT_DIR:-$repo_root/dist}"
mkdir -p "$build_dir" "$output_dir"

# A personal build: no upstream signing identity, notarization, or updater.
/usr/bin/xcodebuild build \
  -workspace "$repo_root/KeepingYouAwake.xcworkspace" \
  -scheme 'KeepingYouAwake (Direct)' \
  -configuration Release \
  -derivedDataPath "$build_dir" \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO

/usr/bin/ditto "$build_dir/Build/Products/Release/CoffeeBull.app" "$output_dir/CoffeeBull.app"
/usr/bin/codesign --force --deep --sign - "$output_dir/CoffeeBull.app"
/usr/bin/codesign --verify --deep --strict "$output_dir/CoffeeBull.app"
printf 'Built %s\n' "$output_dir/CoffeeBull.app"
