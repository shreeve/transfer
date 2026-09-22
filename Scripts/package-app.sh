#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build
bin_dir="$(swift build --show-bin-path)"
app="$root/.build/Transfer.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/Transfer" "$app/Contents/MacOS/Transfer"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "$app"
