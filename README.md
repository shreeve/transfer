# Transfer

Transfer is a native Mac app for browsing an SFTP server. Open an editable file and later saves upload. Open a PDF or an image and it is only viewed. Press Space to preview. Drag a file to the Finder and you get a real copy. Command-C and Command-V copy files and folders to another folder, another server, or the Finder, and back; Option-Command-V moves them. A bar at the bottom shows what is copied, and Escape clears it.

It targets macOS 27 on Apple silicon. The bundle id is `com.github.shreeve.transfer`.

## Requirements

A Mac with Apple silicon running macOS 27 or later.

## Install

Transfer is signed with an Apple Developer ID and notarized by Apple, so it opens normally however you get it. Pick one of these; they all put the same `Transfer.app` in your Applications folder.

### Homebrew

```bash
brew install --cask shreeve/tap/transfer-sftp
```

This adds the `shreeve/tap` tap the first time. The cask is `transfer-sftp` because Homebrew's own `transfer` is a different app, which also installs a `Transfer.app`; the two cannot be installed together.

### One-command installer

```bash
curl -fsSL https://raw.githubusercontent.com/shreeve/transfer/main/Scripts/install.sh | bash
```

It downloads the newest release from GitHub, checks the app's signature, and puts `Transfer.app` in `/Applications` (or `~/Applications` if `/Applications` is not writable). An existing copy is replaced only once the new one is ready, so a failed install leaves it in place. To install somewhere else, name the folder:

```bash
curl -fsSL https://raw.githubusercontent.com/shreeve/transfer/main/Scripts/install.sh | TRANSFER_DEST=~/Apps bash
```

### Download

Download `Transfer.zip` from the [latest release](https://github.com/shreeve/transfer/releases/latest), open it, and drag `Transfer.app` to Applications.

The first time you open Transfer after a Homebrew install or a download, macOS asks you to confirm opening an app from the internet; that is normal. Then open it from Launchpad, Spotlight, or with `open -a Transfer`.

## Update

Transfer updates itself, however it was installed. Choose **Transfer → Check for Updates…** at any time; a new version downloads, installs, and relaunches when you click **Install Update**. Settings → Updates turns automatic checks on or off and shows when it last checked.

- **Homebrew:** `brew upgrade` skips Transfer, since the app keeps itself current, and `brew list --versions` may show the version first installed. `brew upgrade --greedy transfer-sftp` updates it through Homebrew instead.
- **Installer:** running the install command again also updates to the newest release, replacing the app in place.

## Uninstall

Remove it the way you installed it. Each of these removes only the app: your saved servers, Live files, and settings stay, so a later install picks up where you left off.

| Installed with | Uninstall |
| --- | --- |
| Homebrew | `brew uninstall --cask transfer-sftp` |
| Installer | `curl -fsSL https://raw.githubusercontent.com/shreeve/transfer/main/Scripts/install.sh \| bash -s -- --uninstall` |
| Download | Drag `Transfer.app` from Applications to the Trash |

`brew uninstall --zap --cask transfer-sftp` also deletes your data: saved servers, Live file working copies, caches, and preferences, but not passwords in the Keychain. Check first that no Live file has unsynced edits. [Where your data lives](#where-your-data-lives) lists everything, for removing it by hand.

### Switching between Homebrew and the installer

Homebrew will not install over a `Transfer.app` it did not put there. To move to Homebrew, uninstall with the installer's `--uninstall` first, then `brew install`. To move from Homebrew to the installer, `brew uninstall --cask transfer-sftp` first, so Homebrew does not keep a record of an app it no longer manages. Your data carries over either way.

## Open a server folder from its terminal

Transfer opens `sftp://` links. A link to a folder opens it in a new tab; a link to a file selects it in its folder. The server is found among your saved servers by name, by the host name `~/.ssh/config` gives it, or by address; a server not yet saved opens the New Connection sheet, filled in.

`Tools/xfer` prints such a link from a shell on the server, for Command-click in Ghostty or any terminal that shows OSC 8 links. Install it on each server, with the name the Mac uses for that server:

```bash
ssh live 'mkdir -p ~/bin ~/.config/transfer && cat > ~/bin/xfer && chmod 755 ~/bin/xfer && echo live > ~/.config/transfer/host' < Tools/xfer
```

Then run `xfer` (this folder) or `xfer some/path` on the server and Command-click what it prints.

## Where your data lives

| What | Where |
| --- | --- |
| Saved servers, stars, Live file records | `~/Library/Application Support/Transfer/transfer.sqlite` |
| Working copies of Live files | `~/Library/Application Support/Transfer/Live/` |
| Editable file extensions | `~/Library/Application Support/Transfer/config.json` (Settings → Extensions) |
| Passwords you chose to save | Keychain, service "Transfer" |
| Preview cache | `~/Library/Caches/Transfer/` |
| Copy and paste staging | `~/Library/Caches/com.github.shreeve.transfer/` |
| Preferences | `defaults read com.github.shreeve.transfer` |

To remove everything after uninstalling, delete `~/Library/Application Support/Transfer`, `~/Library/Caches/Transfer`, and `~/Library/Caches/com.github.shreeve.transfer`, run `defaults delete com.github.shreeve.transfer`, and remove the "Transfer" items in Keychain Access. Check first that no Live file has unsynced edits.

## Build and run

The Xcode 27 toolchain has to be selected (`xcode-select` pointing at Xcode.app). There is no Xcode project.

```bash
swift test
Scripts/package-app.sh
open .build/Transfer.app
```

`swift test` does not need a server. To run the tests that log in to a local `sshd`:

```bash
eval "$(Scripts/local-sshd.sh)" && swift test; kill $TRANSFER_TEST_SSHD
```

That starts an unprivileged server on 127.0.0.1:2222 and does not turn on Remote Login.

A build from `Scripts/package-app.sh` runs from `.build/Transfer.app` and leaves an installed copy alone, so you can keep a release in Applications for daily use and open builds beside it. Both use the same saved servers, Live files, and settings, and only one runs at a time: quit one before opening the other. `sftp://` links open in whichever copy macOS registered last; open the installed copy once to send them back to it.

## How a connection works

Transfer uses the `ssh` already on the Mac. One login is shared by every window for that server. Listing, the file you are previewing, and copying run on separate SSH channels, so a download does not block the file list. Several files can copy at once.

Which files open for editing is `editableExtensions` in `Support/config.json`. The first launch copies that file to `~/Library/Application Support/Transfer/config.json`, and Settings > Extensions edits the copy.

## Releasing

Maintainers publish a version with one command from a clean, pushed `main`:

```bash
Scripts/release.sh 0.1.1 --dry-run
Scripts/release.sh 0.1.1
```

`docs/RELEASING.md` explains the one-time setup, what the script checks and publishes, how to verify a release, and how to test an update before shipping it.

## For people changing it

`PLAN.md` is the product spec. `HANDOFF.md` is how the current code actually works, including the window layout and the mistakes that already cost a day. `AGENTS.md` is the short rule list for an automated session. `docs/RELEASING.md` is how releases and updates work.
