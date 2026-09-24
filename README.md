# Transfer

Transfer is a native Mac app for browsing an SFTP server. Open an editable file and later saves upload. Open a PDF or an image and it is only viewed. Press Space to preview. Drag a file to the Finder and you get a real copy. Command-C and Command-V copy files and folders to another folder, another server, or the Finder, and back; Option-Command-V moves them. A bar at the bottom shows what is copied, and Escape clears it.

It needs a Mac with Apple silicon running macOS 27 or later. The bundle id is `com.github.shreeve.transfer`.

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

It downloads the newest release from GitHub and installs it only if the app is signed with Transfer's Developer ID and Gatekeeper accepts it as notarized, so it stops, changing nothing, on a Mac where Gatekeeper's checks are turned off. It puts `Transfer.app` in `/Applications` (or `~/Applications` if `/Applications` is not writable). An existing copy is replaced only once the new one is ready, so a failed install leaves it in place. To install somewhere else, name the folder:

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

Transfer opens `sftp://` links. A link to a folder opens it in a window that shows no server yet, or else in a new tab; a link to a file selects it in its folder. The server is found among your saved servers by name, by the host name `~/.ssh/config` gives it, or by address; a server not yet saved opens the New Connection sheet, filled in.

`Tools/xfer` prints such a link from a shell on the server, for Command-click in Ghostty or any terminal that shows OSC 8 links. Install it on each server, with the name the Mac uses for that server:

```bash
ssh live 'mkdir -p ~/bin ~/.config/transfer && cat > ~/bin/xfer && chmod 755 ~/bin/xfer && echo live > ~/.config/transfer/host' < Tools/xfer
```

`~/bin` must be on the server's `PATH`. Many shells, zsh among them, leave it off: add `export PATH="$HOME/bin:$PATH"` to `~/.zshrc` or `~/.profile` there. Then run `xfer` (this folder) or `xfer some/path` on the server and Command-click what it prints. Inside tmux older than 3.4, `xfer` says when `allow-passthrough` must be on for the link to get through.

## Where your data lives

| What | Where |
| --- | --- |
| Saved servers, stars, Live file records | `~/Library/Application Support/Transfer/transfer.sqlite`, and the `-wal` and `-shm` files beside it (`transfer.lock` there keeps a second copy of Transfer out) |
| Working copies of Live files | `~/Library/Application Support/Transfer/Live/` |
| Editable file extensions | `~/Library/Application Support/Transfer/config.json` (Settings → Extensions) |
| Passwords you chose to save | Keychain, service "Transfer" |
| Preview cache | `~/Library/Caches/Transfer/` |
| Copy and paste staging | `~/Library/Caches/com.github.shreeve.transfer/` |
| Preferences | `defaults read com.github.shreeve.transfer` |

A library written by a newer Transfer is left alone: an older version says so and quits rather than guess. A library from 0.1.7 or earlier is upgraded in place on first launch, and 0.1.7 can still open it afterwards.

To remove everything after uninstalling, delete `~/Library/Application Support/Transfer`, `~/Library/Caches/Transfer`, and `~/Library/Caches/com.github.shreeve.transfer`, run `defaults delete com.github.shreeve.transfer`, and remove the "Transfer" items in Keychain Access. Check first that no Live file has unsynced edits.

## Build and run

The Xcode 27 toolchain has to be selected (`xcode-select` pointing at Xcode.app). There is no Xcode project.

```bash
swift test
open --env TRANSFER_LIBRARY=/tmp/transfer-dev "$(Scripts/package-app.sh)"
```

`Scripts/package-app.sh` builds `Transfer.app` (in `.build`, or in the folder `SCRATCH` names) and prints its path. `TRANSFER_LIBRARY` gives the build a library of its own, with its caches inside it, so it never touches your saved servers, Live files, or caches. Leave it out only on purpose: a build on the real library is a second copy of Transfer working on your Live files. Either way the build shares the installed app's preferences, and `sftp://` links open in whichever copy macOS registered last; open the installed copy once to send them back to it.

`swift test` needs no server. The tests that log in run against an unprivileged local `sshd`, never Remote Login or a real server:

```bash
eval "$(Scripts/local-sshd.sh 2222)" && TRANSFER_REQUIRE_SERVER=1 swift test; kill $TRANSFER_TEST_SSHD
```

The port is optional (2222 by default). Without the server those suites report skipped; `TRANSFER_REQUIRE_SERVER=1` makes them fail instead.

## How a connection works

Transfer uses the `ssh` already on the Mac, so your `~/.ssh/config`, agent, and `ProxyJump` apply. One login is shared by every window for that server. Listing, the file you are previewing, and copying run on separate SSH channels, so a download does not block the file list, and many files copy at once.

Which files open for editing is `editableExtensions` in `config.json`. The first launch copies `Support/config.json` to the library, and Settings → Extensions edits that copy.

## For people changing it

`docs/SPEC.md` is what the app does. `HANDOFF.md` is how the code works, including the window layout and the traps that already cost a day. `AGENTS.md` is the short rule list for an automated session. `docs/RELEASING.md` is how releases and updates work (`Scripts/release.sh X.Y.Z`), and `CHANGELOG.md` is what changed in each version.
