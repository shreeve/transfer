#!/usr/bin/env bash
#
# install.sh — install Transfer.app with one command (macOS 27, Apple Silicon):
#
#   curl -fsSL https://raw.githubusercontent.com/shreeve/transfer/main/Scripts/install.sh | bash
#
# Installs the newest GitHub release, signed with a Developer ID and notarized, so it opens on first
# launch; Sparkle updates it in place from then on. Nothing is installed unless the app is signed
# by Transfer's Developer ID (team SD6N7Z8P9P) and Gatekeeper accepts it as notarized.
#
# The app lands in /Applications, or ~/Applications where that is not writable; TRANSFER_DEST
# names another directory (... | TRANSFER_DEST=dir bash). An installed copy is replaced by
# rename, so a failed install leaves it be. TRANSFER_ZIP_URL installs another archive, for tests;
# it must pass the same checks.
#
# Uninstall the same way — the app goes; your servers, Live files, and settings
# (~/Library/Application Support/Transfer) stay:
#
#   curl -fsSL .../install.sh | bash -s -- --uninstall

set -euo pipefail

# Color only when stdout is a terminal, and never against NO_COLOR.
Color_Off='' Red='' Green='' Dim='' Bold_Green=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    Color_Off='\033[0m'
    Red='\033[0;31m' Green='\033[0;32m' Dim='\033[0;2m'
    Bold_Green='\033[1;32m'
fi

info() { printf "${Dim}%s${Color_Off}\n" "$*"; }
fail() { printf "${Red}error${Color_Off}: %s\n" "$*" >&2; exit 1; }
tildify() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

# Remove only what install put down — the app bundle, wherever it landed. The library and
# settings belong to the user.
uninstall() {
    removed=false
    if [ -n "${TRANSFER_DEST:-}" ]; then
        set -- "$TRANSFER_DEST/Transfer.app"
    else
        set -- "/Applications/Transfer.app" "$HOME/Applications/Transfer.app"
    fi
    for app in "$@"; do
        [ -d "$app" ] || continue
        rm -rf "$app" || fail "cannot remove $(tildify "$app")"
        printf "${Green}Transfer was removed from ${Bold_Green}%s${Color_Off}\n" "$(tildify "$(dirname "$app")")"
        removed=true
    done
    $removed || fail "Transfer is not installed ($(tildify "$(dirname "$1")")${2:+ or $(tildify "$(dirname "$2")")})"
    info "your servers, Live files, and settings ($(tildify "$HOME/Library/Application Support/Transfer")) are untouched"
}

main() {
    case "${1:-}" in
        --uninstall) uninstall; return ;;
    esac

    [ "$(uname -s)" = "Darwin" ] || fail "Transfer is a macOS app."
    [ "$(uname -m)" = "arm64" ] || fail "Transfer is Apple Silicon only (this Mac is $(uname -m))."
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 27 ] || fail "Transfer needs macOS 27 or later (this Mac runs $(sw_vers -productVersion))."

    # A Developer ID Application certificate (the two Apple extensions that mark one) of team SD6N7Z8P9P.
    requirement='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "SD6N7Z8P9P"'
    # The repo's latest release is Transfer's newest; its archive keeps one name.
    url="${TRANSFER_ZIP_URL:-https://github.com/shreeve/transfer/releases/latest/download/Transfer.zip}"
    # TRANSFER_DEST, when given, is honored or refused, never quietly
    # swapped for another; only the default falls back, for Macs where
    # /Applications belongs to someone else.
    if [ -n "${TRANSFER_DEST:-}" ]; then
        dest="$TRANSFER_DEST"
    else
        dest="/Applications"
        [ -w "$dest" ] || dest="$HOME/Applications"
    fi
    mkdir -p "$dest"
    [ -w "$dest" ] || fail "$(tildify "$dest") is not writable"
    installed="$dest/Transfer.app"
    staged="$dest/.Transfer.app.incoming"
    aside="$dest/.Transfer.app.outgoing"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp" "$staged"' EXIT
    info "Transfer (latest release, Apple Silicon)"
    # A redirect may not leave HTTPS.
    curl -fSL --proto-redir =https --retry 3 --retry-delay 1 --progress-bar "$url" -o "$tmp/Transfer.zip"
    # ditto, not unzip: it preserves the bundle exactly as it was archived.
    ditto -x -k "$tmp/Transfer.zip" "$tmp/unpacked"
    [ -d "$tmp/unpacked/Transfer.app" ] || fail "the download holds no Transfer.app; nothing was changed"

    # Stage beside the destination, so the swap below is two renames within
    # one directory. Everything that touches the bundle happens to the staged
    # copy: nothing is written into an app once it is in place.
    rm -rf "$staged"
    mv "$tmp/unpacked/Transfer.app" "$staged"
    # A damaged or substituted download stops here, with the installed app
    # still standing. A valid signature is not enough, since anyone can sign
    # a bundle: it must come from a Developer ID Application certificate of
    # Transfer's team, and Gatekeeper must accept the app as notarized.
    codesign --verify --deep --strict -R="$requirement" "$staged" 2>/dev/null \
        || fail "the downloaded Transfer.app is not signed with Transfer's Developer ID; nothing was changed"
    assessment=$(spctl --assess --type execute -vv "$staged" 2>&1) \
        && grep -qx 'source=Notarized Developer ID' <<<"$assessment" \
        || fail "Gatekeeper does not accept the downloaded Transfer.app as notarized; nothing was changed"

    # A swap that died between its two renames left the only copy set
    # aside; it goes back before anything else.
    if [ -e "$aside" ]; then
        [ -e "$installed" ] || mv "$aside" "$installed"
        rm -rf "$aside"
    fi

    # Replace, never merge, and never by deleting first: the installed app
    # steps aside, the staged one takes its name, and only then is the old
    # one removed. A rename that fails puts back the app that was there.
    if [ -e "$installed" ]; then
        mv "$installed" "$aside" || fail "cannot replace $(tildify "$installed")"
        if ! mv "$staged" "$installed"; then
            mv "$aside" "$installed"
            fail "cannot move Transfer into $(tildify "$dest"); the installed copy is untouched"
        fi
        rm -rf "$aside"
    else
        mv "$staged" "$installed"
    fi

    # Launch Services learns of the bundle at this path at once, so Finder,
    # Spotlight and System Settings show its name and icon without waiting
    # for a rescan. Best effort: the app runs the same without it.
    lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [ -x "$lsregister" ]; then
        "$lsregister" -f "$installed" >/dev/null 2>&1 || true
    fi

    printf "${Green}Transfer was installed to ${Bold_Green}%s${Color_Off}\n" "$(tildify "$installed")"
    info "Run 'open -a Transfer' to get started"
}

main "$@"
