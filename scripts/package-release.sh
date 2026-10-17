#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${AWAKEEYE_OUTPUT_DIR:-${COFFEEBULL_OUTPUT_DIR:-$repo_root/dist}}"
if [[ $# -gt 2 ]]; then
  printf 'Usage: %s [AwakeEye.app] [release-directory]\n' "$0" >&2
  exit 1
fi
app_path="${1:-$output_dir/AwakeEye.app}"
release_dir="${2:-$output_dir/releases}"
if [[ ! -d "$app_path" || "$(basename "$app_path")" != AwakeEye.app ]]; then
  printf 'Expected an exported AwakeEye.app: %s\n' "$app_path" >&2
  exit 1
fi
app_path="$(cd "$(dirname "$app_path")" && pwd)/AwakeEye.app"
info_plist="$app_path/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  printf 'Invalid release version: %s\n' "$version" >&2
  exit 1
fi
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
if [[ -z "$executable" || "$executable" == */* || "$executable" == . || "$executable" == .. ]]; then
  printf 'Invalid app executable name.\n' >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app_path"
architectures="$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/$executable")"
case "$architectures" in
  arm64 | x86_64) archive_arch="$architectures" ;;
  'x86_64 arm64' | 'arm64 x86_64') archive_arch=universal ;;
  *) printf 'Unsupported app architectures: %s\n' "$architectures" >&2; exit 1 ;;
esac

mkdir -p "$release_dir"
release_dir="$(cd "$release_dir" && pwd)"
staging_dir="$(/usr/bin/mktemp -d "$release_dir/.AwakeEye-package.XXXXXXXX")"
trap '/bin/rm -rf "$staging_dir"' EXIT
archive_name="AwakeEye-$version-macos-$archive_arch.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$staging_dir/$archive_name"
(
  cd "$staging_dir"
  /usr/bin/shasum -a 256 "$archive_name" > SHA256SUMS
)
/bin/mv -f "$staging_dir/$archive_name" "$release_dir/$archive_name"
/bin/mv -f "$staging_dir/SHA256SUMS" "$release_dir/SHA256SUMS"
printf 'Packaged %s\nChecksums %s\n' "$release_dir/$archive_name" "$release_dir/SHA256SUMS"
