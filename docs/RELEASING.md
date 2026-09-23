# Releasing and updates

Transfer ships the way DuckTable does (`duckdb-harbor/ducktable/docs/UPDATES.md`): an ad-hoc signed app, a one-command installer, and in-app updates through [Sparkle](https://sparkle-project.org), with GitHub Releases as the only host. There is no Developer ID, no notarization, no server, and no CI step.

## How it fits together

| Piece | Where | Does |
| --- | --- | --- |
| Installer | `Scripts/install.sh` | Fetches the latest release's `Transfer.zip` with `curl`, checks the signature, swaps the app into `/Applications` by rename, registers it with Launch Services. `--uninstall` removes only the app. |
| Build | `Scripts/package-app.sh` | Builds the app (`CONFIG=release` for releases), embeds Sparkle, ad-hoc signs everything, and fails unless the bundle signs as `com.github.shreeve.transfer`. |
| Release | `Scripts/release.sh` | Stamps the version, builds, zips, writes and signs the feed, commits, tags, pushes, publishes. |
| Feed | `appcast.xml` on each release | Sparkle's list of the newest version, its download URL, and its EdDSA signature. |
| App | `Support/Info.plist` | `SUFeedURL` points at the latest release's `appcast.xml`; `SUPublicEDKey` is the key updates must be signed with. |

Why no Developer ID works:

- **First install.** macOS only asks Gatekeeper about files marked as downloaded from the internet. `curl` never sets that mark, so the installed app opens on first launch. A browser download does set it, which is why the README tells those users about **Open Anyway**.
- **Updates.** Sparkle accepts an update when its code signature is valid and its EdDSA signature matches `SUPublicEDKey`. Both hold for an ad-hoc signed app. This was proven on macOS 27.0: an installed 0.1.0 found a 0.1.2 served from this Mac, installed it, and relaunched as 0.1.2.

## One-time setup: the signing key

Updates are signed with an ed25519 key. The private half lives in the login keychain, where Sparkle's `generate_keys` created it; the public half is `SUPublicEDKey` in `Support/Info.plist`. Sparkle's tools are in `.build/artifacts/sparkle/Sparkle/bin` after any `swift build`.

```bash
bin=.build/artifacts/sparkle/Sparkle/bin
$bin/generate_keys -p                   # prints the public key; it must equal SUPublicEDKey
$bin/generate_keys -x /tmp/transfer-key  # exports the private key for a backup
$bin/generate_keys -f /tmp/transfer-key  # imports it on another Mac
```

Keep a backup of the private key in a password manager, and delete any exported file afterwards. Never commit it or leave it on disk. Losing it strands every installed copy on its version, because an app only trusts the key it shipped with. Anyone who has it can sign an update every installed copy will accept.

## Cutting a release

From `main`, clean and in step with `origin/main`:

```bash
Scripts/release.sh 0.1.1 --dry-run
Scripts/release.sh 0.1.1
```

Versions are `major.minor.patch` and must go up: Sparkle orders updates by `CFBundleVersion`, which the script sets to the version, as it does `CFBundleShortVersionString`.

The script:

1. Refuses to run unless it is on a clean `main` that matches `origin/main`, and the tag does not exist yet.
2. Writes the version into `Support/Info.plist`.
3. Builds with `CONFIG=release Scripts/package-app.sh`, and checks the bundle's version and that it has an `SUPublicEDKey`.
4. Zips the app with `ditto` into `.build/release-<version>/Transfer.zip`, and copies it as `Transfer-<version>.zip`.
5. Writes `appcast.xml` with Sparkle's `generate_appcast`, signing with the keychain key, and stops if the feed came out unsigned. That happens silently when the keychain key does not match `SUPublicEDKey`, and would ship a feed no copy can use.
6. Commits `Transfer <version>`, tags `v<version>`, pushes both, and publishes the GitHub release as the latest, with `Transfer.zip` (for the installer), `Transfer-<version>.zip` (the feed's download), and `appcast.xml`.

`--dry-run` does steps 2 to 5 and puts `Info.plist` back, publishing nothing. Look in `.build/release-<version>/`.

It runs locally, not in CI: Transfer needs the macOS 27 SDK and the Xcode 27 toolchain.

## Verifying a release

```bash
gh release view v0.1.1
curl -fsSL https://github.com/shreeve/transfer/releases/latest/download/appcast.xml | grep sparkle:version
T=$(mktemp -d); curl -fsSL https://raw.githubusercontent.com/shreeve/transfer/main/Scripts/install.sh | TRANSFER_DEST=$T bash
plutil -extract CFBundleShortVersionString raw $T/Transfer.app/Contents/Info.plist
codesign --verify --deep --strict $T/Transfer.app && rm -rf $T
```

The feed must list the new version, and the throwaway install must report it with a valid signature.

## Testing an update before shipping it

To watch Sparkle update an older build without publishing anything:

1. `Scripts/release.sh 0.1.1 --dry-run`, then install the old version into a folder: `TRANSFER_DEST=/tmp/t TRANSFER_ZIP_URL=file://$PWD/.build/release-0.1.1/Transfer.zip bash Scripts/install.sh`.
2. Dry-run the newer version, put its zip in a folder as `Transfer-<new>.zip`, and write a feed for it: `.build/artifacts/sparkle/Sparkle/bin/generate_appcast --download-url-prefix http://127.0.0.1:8765/ <folder>`.
3. Serve that folder: `python3 -m http.server 8765 --bind 127.0.0.1`.
4. Point Transfer at it: `defaults write com.github.shreeve.transfer SUFeedURL http://127.0.0.1:8765/appcast.xml`. A user default overrides `SUFeedURL` in `Info.plist`.
5. Quit any running Transfer (only one copy runs at a time), open the old copy, and choose **Check for Updates…**, then **Install Update**. It relaunches as the new version.
6. Clean up: `defaults delete com.github.shreeve.transfer SUFeedURL`, stop the server, delete the folders.

## If something goes wrong

- **The script says the feed is unsigned.** The keychain key does not match `SUPublicEDKey`. Compare `generate_keys -p` with the plist; import the right key with `generate_keys -f`.
- **A user sees "cannot verify" or "damaged".** They downloaded in a browser. Point them to the installer, or to Open Anyway, or to `xattr -dr com.apple.quarantine /Applications/Transfer.app`.
- **Installed copies do not see the new version.** The release must be the repo's latest (`gh api repos/shreeve/transfer/releases/latest --jq .tag_name`), since `SUFeedURL` reads the latest release's feed, and its `CFBundleVersion` must be higher than theirs.
- **A bad release is out.** Publish a fixed, higher version. Sparkle only moves forward; deleting a release does not roll anyone back.

## If Transfer ever gets a Developer ID

`SIGN="Developer ID Application: …" Scripts/package-app.sh` already signs every piece with a real identity and the hardened runtime. Notarization (`xcrun notarytool submit … --wait`, then `xcrun stapler staple`) would go between the build and the zip in `release.sh`. Browser downloads would then open without Open Anyway; nothing else changes.
