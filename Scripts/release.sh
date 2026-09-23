#!/bin/bash
#
# release.sh — build Transfer <version>, sign its update feed, and publish it as a GitHub release.
#
#   Scripts/release.sh 0.2.0 --dry-run   # build everything under .build/release-0.2.0; publish nothing
#   Scripts/release.sh 0.2.0             # also commit the version, tag v0.2.0, push, and publish
#
# The release carries three files: Transfer.zip, which Scripts/install.sh fetches from the latest
# release; Transfer-<version>.zip, the archive the feed names; and appcast.xml, the Sparkle feed
# the app reads from the latest release (SUFeedURL). The bundle is signed with the Developer ID
# and notarized, with the ticket stapled, so Gatekeeper accepts it however it was downloaded. The
# feed is signed with the EdDSA key in the login keychain, the private half of SUPublicEDKey.
#
# SIGN names another signing identity and NOTARY_PROFILE another notarytool keychain profile.
#
# It runs locally rather than in CI: Transfer needs the macOS 27 SDK and the Xcode 27 toolchain.

set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fail() { echo "error: $*" >&2; exit 1; }

version="${1:?usage: Scripts/release.sh <version> [--dry-run]}"
dry=false
[ "${2:-}" = "--dry-run" ] && dry=true
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3, not $version"
repo="shreeve/transfer"
tag="v$version"
plist="Support/Info.plist"
identity="${SIGN:-Developer ID Application: Steve Shreeve (SD6N7Z8P9P)}"
profile="${NOTARY_PROFILE:-notary-tool}"

if ! $dry; then
    [ "$(git branch --show-current)" = "main" ] || fail "release from main"
    [ -z "$(git status --porcelain)" ] || fail "the working tree is not clean"
    git fetch -q origin main --tags
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not in step with origin/main"
    ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "$tag already exists"
fi
security find-identity -v -p codesigning | grep -qF "\"$identity\"" \
    || fail "the keychain has no signing identity \"$identity\""
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
    || fail "notarytool cannot sign in with keychain profile \"$profile\"; see docs/RELEASING.md"

# The version goes into the bundle both ways: Sparkle orders updates by CFBundleVersion.
# A dry run puts the plist back afterwards.
if $dry; then
    cp "$plist" "$root/.build/Info.plist.dry-run"
    trap 'mv "$root/.build/Info.plist.dry-run" "$root/'"$plist"'"' EXIT
fi
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$version" "$plist"

CONFIG=release SIGN="$identity" Scripts/package-app.sh >/dev/null
app="$root/.build/Transfer.app"
[ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" = "$version" ] || fail "the bundle does not say $version"
[ -n "$(plutil -extract SUPublicEDKey raw "$app/Contents/Info.plist" 2>/dev/null)" ] \
    || fail "the bundle has no SUPublicEDKey, so it could never update"

out="$root/.build/release-$version"
rm -rf "$out"
mkdir -p "$out/feed"

# Apple scans the app and issues a ticket; stapling puts the ticket in the bundle, so Gatekeeper
# can check it offline. The zip sent to Apple is only for the submission: the release zips are
# made from the stapled app below.
echo "Notarizing (usually a few minutes)…"
ditto -c -k --keepParent "$app" "$out/notarize.zip"
result=$(xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$profile" --wait --output-format json || true)
rm "$out/notarize.zip"
status=$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)
if [ "$status" != "Accepted" ]; then
    id=$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)
    [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    fail "notarization came back ${status:-without a status}"
fi
xcrun stapler staple -q "$app"
spctl --assess --type execute -vv "$app" 2>&1 | grep -q "source=Notarized Developer ID" \
    || fail "Gatekeeper does not accept the stapled app"

# ditto --keepParent preserves the bundle exactly; the installer unpacks it with ditto too.
ditto -c -k --keepParent "$app" "$out/Transfer.zip"
cp "$out/Transfer.zip" "$out/feed/Transfer-$version.zip"

generator="$(find "$root/.build/artifacts" -path '*Sparkle/bin/generate_appcast' -type f | head -1)"
[ -x "$generator" ] || fail "Sparkle's generate_appcast is missing; run swift build once"
"$generator" --download-url-prefix "https://github.com/$repo/releases/download/$tag/" \
    --link "https://github.com/$repo" "$out/feed" >/dev/null
# generate_appcast writes an unsigned feed when its key does not match SUPublicEDKey, and Sparkle
# rejects an unsigned enclosure, so a silent mismatch would ship a dead update feed.
unsigned=$(grep -o '<enclosure[^>]*>' "$out/feed/appcast.xml" | grep -v 'sparkle:edSignature=' || true)
[ -z "$unsigned" ] || fail "the feed is unsigned; the keychain key does not match SUPublicEDKey"
cp "$out/feed/appcast.xml" "$out/appcast.xml"

if $dry; then
    echo "Dry run: $out"
    ls -la "$out"
    exit 0
fi

git commit -q -m "Transfer $version" -- "$plist"
git tag "$tag"
git push -q origin main "$tag"
gh release create "$tag" "$out/Transfer.zip" "$out/feed/Transfer-$version.zip" "$out/appcast.xml" \
    --repo "$repo" --title "Transfer $version" --latest \
    --notes "Transfer for macOS 27 (Apple Silicon), ad-hoc signed.

Install or update with one command:

    curl -fsSL https://raw.githubusercontent.com/$repo/main/Scripts/install.sh | bash

A copy downloaded in a browser is quarantined: allow it under System Settings → Privacy & Security → Open Anyway, or run xattr -dr com.apple.quarantine Transfer.app. Installed copies update themselves through Transfer → Check for Updates…"
echo "Published $tag"
