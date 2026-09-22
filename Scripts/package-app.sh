#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build
bin_dir="$(swift build --show-bin-path)"
app="$root/.build/Transfer.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin_dir/Transfer" "$app/Contents/MacOS/Transfer"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
cp "$root/Support/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$root/Support/config.json" "$app/Contents/Resources/config.json"

# Sparkle is a binary framework. SwiftPM links it from the build directory, so the app needs
# its own copy and an rpath that finds it.
sparkle="$(find "$root/.build/artifacts" -type d -name Sparkle.framework -path '*macos-arm64*' | head -1)"
cp -R "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Transfer"

# Ad-hoc signing for local builds. A release needs Developer ID on every step, inner components
# first: SIGN="Developer ID Application: …" Scripts/package-app.sh
# The hardened runtime is only for real identities: with ad-hoc signatures its library validation
# refuses the framework because neither side has a team.
sign="${SIGN:--}"
runtime=""
if [ "$sign" != "-" ]; then runtime="--options=runtime"; fi
framework="$app/Contents/Frameworks/Sparkle.framework"
resign() { codesign --force --sign "$sign" $runtime "$@"; }
resign "$framework/Versions/B/XPCServices/Installer.xpc"
resign --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
resign "$framework/Versions/B/Autoupdate"
resign "$framework/Versions/B/Updater.app"
resign "$framework"
resign "$app"
echo "$app"
