#!/bin/bash
#
# release.sh — build Transfer <version>, sign its update feed, and publish it as a GitHub release.
#
#   Scripts/release.sh 0.2.0 --notes     # print the release notes it would publish; nothing else
#   Scripts/release.sh 0.2.0 --dry-run   # build everything under .build/release-0.2.0; publish nothing
#   Scripts/release.sh 0.2.0             # also commit the version, tag v0.2.0, push, and publish
#
# The release carries three files: Transfer.zip, which Scripts/install.sh fetches from the latest
# release; Transfer-<version>.zip, the archive the feed names; and appcast.xml, the Sparkle feed
# the app reads from the latest release (SUFeedURL). The bundle is signed with the Developer ID
# and notarized, with the ticket stapled, so Gatekeeper accepts it however it was downloaded. The
# feed is signed with the EdDSA key in the login keychain, the private half of SUPublicEDKey.
#
# The notes are the version's section of CHANGELOG.md, which a release must have: the GitHub
# release shows them, and the feed embeds them for Sparkle's update dialog.
#
# A failed run leaves the repo as it found it: Info.plist is put back, and until the push, the
# local commit, the tag, and the draft release are undone. Only publishing the pushed draft can
# fail beyond that, and the script prints the command that finishes it. A real release refuses
# to start when a tag or release for the version already exists.
#
# SIGN names another signing identity, NOTARY_PROFILE another notarytool keychain profile, and
# SCRATCH another build folder.
#
# It runs locally rather than in CI: Transfer needs the macOS 27 SDK and the Xcode 27 toolchain.

set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fail() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }

version="${1:?usage: Scripts/release.sh <version> [--dry-run | --notes]}"
mode="${2:-publish}"
case "$mode" in publish | --dry-run | --notes) ;; *) fail "unknown option $mode" ;; esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3, not $version"
repo="shreeve/transfer"
tag="v$version"
plist="Support/Info.plist"
identity="${SIGN:-Developer ID Application: Steve Shreeve (SD6N7Z8P9P)}"
profile="${NOTARY_PROFILE:-notary-tool}"
scratch="${SCRATCH:-$root/.build}"

# The version's section of CHANGELOG.md, from under its "## <version>" heading to the next one.
section=$(awk -v v="$version" '
    /^## / { if (on) exit; on = ($2 == v); next }
    on { line[++n] = $0 }
    END {
        first = 1
        while (first <= n && line[first] == "") first++
        while (n >= first && line[n] == "") n--
        for (i = first; i <= n; i++) print line[i]
    }' CHANGELOG.md)
notes="$section

Install or update with one command:

    curl -fsSL https://raw.githubusercontent.com/$repo/main/Scripts/install.sh | bash

Installed copies update themselves through Transfer → Check for Updates…"

if [ "$mode" = --notes ]; then
    [ -n "$section" ] || fail "CHANGELOG.md has no section for $version"
    printf '%s\n' "$notes"
    exit 0
fi

# Whether version $1 is higher than version $2.
higher() {
    local IFS=. i
    local -a a=($1) b=($2)
    for i in 0 1 2; do
        ((10#${a[i]} > 10#${b[i]})) && return 0
        ((10#${a[i]} < 10#${b[i]})) && return 1
    done
    return 1
}

if [ "$mode" = publish ]; then
    [ "$(git branch --show-current)" = "main" ] || fail "release from main"
    [ -z "$(git status --porcelain)" ] || fail "the working tree is not clean"
    git fetch -q origin main --tags
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not in step with origin/main"
    ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "$tag already exists"
    ! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || fail "$tag already exists on origin"
    gh auth status >/dev/null 2>&1 || fail "gh is not signed in to GitHub"
    ! gh release view "$tag" --repo "$repo" >/dev/null 2>&1 \
        || fail "a release for $tag already exists; if a failed run left a draft, delete it: gh release delete $tag --repo $repo"
fi
# Sparkle offers an update only when its CFBundleVersion is higher than the installed one's.
latest=""
for existing in $(git tag -l 'v[0-9]*'); do
    existing="${existing#v}"
    [[ "$existing" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [ -z "$latest" ] || higher "$existing" "$latest"; then latest="$existing"; fi
done
problems=()
[ -z "$latest" ] || higher "$version" "$latest" || problems+=("$version is not higher than the latest release, $latest")
[ -n "$section" ] || problems+=("CHANGELOG.md has no \"## $version\" section for the release notes")
for problem in ${problems[@]+"${problems[@]}"}; do
    if [ "$mode" = publish ]; then fail "$problem"; else warn "$problem"; fi
done

security find-identity -v -p codesigning | grep -qF "\"$identity\"" \
    || fail "the keychain has no signing identity \"$identity\""
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
    || fail "notarytool cannot sign in with keychain profile \"$profile\"; see docs/RELEASING.md"

# From here a failure undoes what the run did, as far as `stage` says it got.
start=$(git rev-parse HEAD)
backup=$(mktemp)
cp "$plist" "$backup"
stage=stamped
undo() {
    local status=$?
    case "$stage" in
        stamped | drafted | committed)
            if [ "$stage" != stamped ]; then
                gh release delete "$tag" --repo "$repo" --yes >/dev/null 2>&1 \
                    || echo "error: if a draft release $tag exists, delete it: gh release delete $tag --repo $repo" >&2
            fi
            if [ "$stage" = committed ]; then
                git tag -d "$tag" >/dev/null 2>&1 || true
                git reset -q --keep "$start" || echo "error: could not undo the commit \"Transfer $version\"" >&2
            fi
            cp "$backup" "$plist"
            ;;
        pushed)
            echo "error: $tag is pushed, but its release is still a draft; publish it with:" >&2
            echo "  gh release edit $tag --repo $repo --draft=false --latest --verify-tag" >&2
            ;;
    esac
    rm -f "$backup"
    exit "$status"
}
trap undo EXIT
trap 'exit 130' INT TERM HUP

# The version goes into the bundle both ways: Sparkle orders updates by CFBundleVersion.
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$version" "$plist"

app=$(CONFIG=release SIGN="$identity" SCRATCH="$scratch" Scripts/package-app.sh)
[ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" = "$version" ] || fail "the bundle does not say $version"
[ -n "$(plutil -extract SUPublicEDKey raw "$app/Contents/Info.plist" 2>/dev/null)" ] \
    || fail "the bundle has no SUPublicEDKey, so it could never update"

out="$scratch/release-$version"
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
assessment=$(spctl --assess --type execute -vv "$app" 2>&1) && grep -qx "source=Notarized Developer ID" <<<"$assessment" \
    || fail "Gatekeeper does not accept the stapled app"

# ditto --keepParent preserves the bundle exactly; the installer unpacks it with ditto too.
ditto -c -k --keepParent "$app" "$out/Transfer.zip"
cp "$out/Transfer.zip" "$out/feed/Transfer-$version.zip"
# Notes named like the archive are the update's notes; embedded, the feed carries them itself.
[ -z "$section" ] || printf '%s\n' "$section" > "$out/feed/Transfer-$version.md"
printf '%s\n' "$notes" > "$out/notes.md"

generator="$(find "$scratch/artifacts" -path '*Sparkle/bin/generate_appcast' -type f | head -1)"
[ -x "$generator" ] || fail "Sparkle's generate_appcast is missing; run swift build once"
"$generator" --download-url-prefix "https://github.com/$repo/releases/download/$tag/" \
    --embed-release-notes --link "https://github.com/$repo" "$out/feed" >/dev/null
# generate_appcast writes an unsigned feed when its key does not match SUPublicEDKey, and Sparkle
# rejects an unsigned enclosure, so a silent mismatch would ship a dead update feed.
unsigned=$(grep -o '<enclosure[^>]*>' "$out/feed/appcast.xml" | grep -v 'sparkle:edSignature=' || true)
[ -z "$unsigned" ] || fail "the feed is unsigned; the keychain key does not match SUPublicEDKey"
[ -z "$section" ] || grep -q '<description' "$out/feed/appcast.xml" || fail "the feed carries no release notes"
cp "$out/feed/appcast.xml" "$out/appcast.xml"

if [ "$mode" = --dry-run ]; then
    echo "Dry run: $out"
    ls -la "$out"
    exit 0
fi

# A draft is invisible until published, so it can be deleted if anything below fails. The tag
# does not exist on GitHub yet; it arrives with the push, and publishing uses it.
stage=drafted
gh release create "$tag" "$out/Transfer.zip" "$out/feed/Transfer-$version.zip" "$out/appcast.xml" \
    --repo "$repo" --title "Transfer $version" --notes-file "$out/notes.md" --draft >/dev/null
stage=committed
git commit -q -m "Transfer $version" -- "$plist"
git tag "$tag"
git push -q --atomic origin main "$tag"
stage=pushed
gh release edit "$tag" --repo "$repo" --draft=false --latest --verify-tag >/dev/null
stage=published
echo "Published $tag"
