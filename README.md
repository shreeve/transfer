# Transfer

Transfer is a native Mac app for browsing an SFTP server. Open an editable file and later saves upload. Open a PDF or an image and it is only viewed. Press Space to preview. Drag a file to the Finder and you get a real copy. Command-C and Command-V copy files and folders to another folder, another server, or the Finder, and back; Option-Command-V moves them. A bar at the bottom shows what is copied, and Escape clears it.

It targets macOS 27 on Apple silicon. The bundle id is `com.github.shreeve.transfer`.

## Requirements

A Mac with Apple silicon running macOS 27 or later.

## Install

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/shreeve/transfer/main/Scripts/install.sh | bash
```

It downloads the newest release from GitHub, checks the app's signature, and puts `Transfer.app` in `/Applications` (or `~/Applications` if `/Applications` is not writable). Then open it from Launchpad, Spotlight, or with `open -a Transfer`.

To install somewhere else, name the folder:

```bash
curl -fsSL https://raw.githubusercontent.com/shreeve/transfer/main/Scripts/install.sh | TRANSFER_DEST=~/Apps bash
```

Or with [Homebrew](https://brew.sh):

```bash
brew install --cask shreeve/tap/transfer-sftp
```

The cask is `transfer-sftp` because Homebrew's own `transfer` is a different app. Transfer updates itself, so `brew upgrade` leaves it alone.

Transfer is signed with an Apple Developer ID and notarized by Apple, so it also opens normally when you download `Transfer.zip` from the [releases page](https://github.com/shreeve/transfer/releases) in a browser and drag the app to Applications.

## Update

Transfer updates itself. Choose **Transfer → Check for Updates…** at any time; a new version downloads, installs, and relaunches when you click **Install Update**. Settings → Updates turns automatic checks on or off and shows when it last checked.

Running the install command again also updates to the newest release, replacing the app in place.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/shreeve/transfer/main/Scripts/install.sh | bash -s -- --uninstall
```

This removes only the app. Your saved servers, Live files, and settings stay, so a later install picks up where you left off.

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
| Saved servers, recents, stars, Live file records | `~/Library/Application Support/Transfer/transfer.sqlite` |
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
