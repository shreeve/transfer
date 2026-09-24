#!/bin/bash
# Builds Transfer.app and prints its path, the only thing on stdout; the build's output goes to
# stderr. CONFIG=release for a release build; the default is a debug build for local work.
# SCRATCH is the build folder (`.build` by default), for builds that must not share one.
set -euo pipefail

scratch="${SCRATCH:-}"
[ -z "$scratch" ] || scratch="$(mkdir -p "$scratch" && cd "$scratch" && pwd)"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
scratch="${scratch:-$root/.build}"

config="${CONFIG:-debug}"
swift build -c "$config" --scratch-path "$scratch" >&2
bin_dir="$(swift build -c "$config" --scratch-path "$scratch" --show-bin-path)"
app="$scratch/Transfer.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin_dir/Transfer" "$app/Contents/MacOS/Transfer"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
cp "$root/Support/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$root/Support/config.json" "$app/Contents/Resources/config.json"

# Sparkle is a binary framework. SwiftPM links it from the build directory, so the app needs
# its own copy and an rpath that finds it.
sparkle="$(find "$scratch/artifacts" -type d -name Sparkle.framework -path '*macos-arm64*' 2>/dev/null | head -1)"
[ -n "$sparkle" ] || { echo "error: no Sparkle.framework for macos-arm64 under $scratch/artifacts" >&2; exit 1; }
cp -R "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Transfer"

# Local builds are ad-hoc signed. Releases pass SIGN="Developer ID Application: …" (release.sh
# does), which signs every piece with that identity, inner components first, with the hardened
# runtime and a secure timestamp, as notarization requires. The hardened runtime is only for
# real identities: with ad-hoc signatures its library validation refuses the framework because
# neither side has a team.
sign="${SIGN:--}"
options=()
if [ "$sign" != "-" ]; then options=(--options=runtime --timestamp); fi
framework="$app/Contents/Frameworks/Sparkle.framework"
resign() { codesign --force --sign "$sign" ${options[@]+"${options[@]}"} "$@"; }
resign "$framework/Versions/B/XPCServices/Installer.xpc"
resign --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
resign "$framework/Versions/B/Autoupdate"
resign "$framework/Versions/B/Updater.app"
resign "$framework"
resign --entitlements "$root/Support/Transfer.entitlements" "$app"
# macOS files permissions under the signing identifier, so every build signs as the bundle id.
codesign --verify --deep --strict "$app"
identifier=$( (codesign -dv "$app" 2>&1 || true) | sed -n 's/^Identifier=//p')
expected=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
[ "$identifier" = "$expected" ] || { echo "error: signed as '$identifier', not $expected" >&2; exit 1; }
echo "$app"
