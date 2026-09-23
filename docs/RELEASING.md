# Releasing and updates

Transfer ships as an app signed with a Developer ID and notarized by Apple, a one-command installer, and in-app updates through [Sparkle](https://sparkle-project.org), with GitHub Releases as the only host. There is no server and no CI step. Releases up to 0.1.4 were ad-hoc signed; Sparkle moves those copies to signed ones like any other update.

## How it fits together

| Piece | Where | Does |
| --- | --- | --- |
| Installer | `Scripts/install.sh` | Fetches the latest release's `Transfer.zip` with `curl`, checks the signature, swaps the app into `/Applications` by rename, registers it with Launch Services. `--uninstall` removes only the app. |
| Build | `Scripts/package-app.sh` | Builds the app (`CONFIG=release` for releases), embeds Sparkle, and signs everything, inner pieces first: ad-hoc by default, or with `SIGN`'s identity, the hardened runtime, and a secure timestamp. Fails unless the bundle signs as `com.github.shreeve.transfer`. |
| Entitlements | `Support/Transfer.entitlements` | Lets the hardened app send Apple events: Open in Terminal drives Terminal and iTerm2 with AppleScript. |
| Release | `Scripts/release.sh` | Stamps the version, builds with the Developer ID, notarizes and staples, zips, writes and signs the feed, commits, tags, pushes, publishes. |
| Feed | `appcast.xml` on each release | Sparkle's list of the newest version, its download URL, and its EdDSA signature. |
| App | `Support/Info.plist` | `SUFeedURL` points at the latest release's `appcast.xml`; `SUPublicEDKey` is the key updates must be signed with. |

Two signatures, for two jobs:

- **Gatekeeper** judges a file marked as downloaded from the internet, as browsers and Homebrew mark it, on first launch. It accepts an app signed with a Developer ID and notarized: Apple has scanned it and issued a ticket, which the release staples into the bundle so the check works offline. `curl` sets no mark, so the installer would work either way; a browser or Homebrew install needs the notarization.
- **Sparkle** accepts an update when its code signature is valid and its EdDSA signature matches `SUPublicEDKey`. This was proven on macOS 27.0: an installed 0.1.4, ad-hoc signed, found a notarized 0.1.5 served from this Mac, installed it, and relaunched as 0.1.5.

## One-time setup: the Developer ID and notarization

Releases are signed with the Developer ID Application certificate of the individual team `SD6N7Z8P9P`. Only the account holder can create it: Xcode → Settings → Apple Accounts → the team → Manage Certificates… → + → Developer ID Application. Its private key lives in the login keychain; to release from another Mac, export the certificate with its key from Keychain Access and import it there. Check with:

```bash
security find-identity -v -p codesigning   # must list "Developer ID Application: Steve Shreeve (SD6N7Z8P9P)"
```

Notarization signs in through a notarytool keychain profile named `notary-tool`, stored once per Mac:

```bash
xcrun notarytool store-credentials notary-tool   # Apple ID, an app-specific password, team SD6N7Z8P9P
xcrun notarytool history --keychain-profile notary-tool
```

The app-specific password comes from account.apple.com → Sign-In and Security → App-Specific Passwords; it is needed only for this command, and a new one can replace it at any time. An App Store Connect API key works too, and suits a team better. `SIGN` and `NOTARY_PROFILE` name another identity or profile.

## One-time setup: the update signing key

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

1. Refuses to run unless the keychain holds the Developer ID and the notary profile signs in, and, for a real release, unless it is on a clean `main` that matches `origin/main` and the tag does not exist yet.
2. Writes the version into `Support/Info.plist`.
3. Builds with `CONFIG=release Scripts/package-app.sh` and the Developer ID, and checks the bundle's version and that it has an `SUPublicEDKey`.
4. Sends the app to Apple's notary service and waits (under a minute for 0.1.5), prints Apple's log and stops if it is not accepted, staples the ticket, and checks that Gatekeeper accepts the app as Notarized Developer ID.
5. Zips the stapled app with `ditto` into `.build/release-<version>/Transfer.zip`, and copies it as `Transfer-<version>.zip`.
6. Writes `appcast.xml` with Sparkle's `generate_appcast`, signing with the keychain key, and stops if the feed came out unsigned. That happens silently when the keychain key does not match `SUPublicEDKey`, and would ship a feed no copy can use.
7. Commits `Transfer <version>`, tags `v<version>`, pushes both, and publishes the GitHub release as the latest, with `Transfer.zip` (for the installer), `Transfer-<version>.zip` (the feed's download), and `appcast.xml`.

`--dry-run` does steps 1 to 6, without the git checks, and puts `Info.plist` back, publishing nothing; it still submits the app to Apple, which makes nothing public. Look in `.build/release-<version>/`.

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
- **Notarization is refused.** The script prints Apple's log, which names each file and the problem: usually a piece signed without the hardened runtime or a secure timestamp, or a new executable that `package-app.sh` does not sign.
- **The script finds no signing identity or notary profile.** See the one-time setup above.
- **A user sees "cannot verify" or "damaged".** They have a release older than 0.1.5 from a browser. Point them to the installer or to the current release.
- **Installed copies do not see the new version.** The release must be the repo's latest (`gh api repos/shreeve/transfer/releases/latest --jq .tag_name`), since `SUFeedURL` reads the latest release's feed, and its `CFBundleVersion` must be higher than theirs.
- **A bad release is out.** Publish a fixed, higher version. Sparkle only moves forward; deleting a release does not roll anyone back.
