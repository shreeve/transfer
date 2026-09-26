<div align="center">

<img src="Support/AppIcon.svg" width="160" height="160" alt="Transfer's icon: a page with a yellow badge on a blue tile">

# Transfer

**A native Mac app for browsing SFTP servers, built to feel like Finder.**

[![Latest release](https://img.shields.io/github/v/release/shreeve/transfer?label=release&color=0346A6)](https://github.com/shreeve/transfer/releases/latest)
![macOS 27 or later](https://img.shields.io/badge/macOS-27%2B-00AADD)
![Apple silicon](https://img.shields.io/badge/Apple%20silicon-arm64-004499)
![Signed and notarized](https://img.shields.io/badge/Developer%20ID-notarized-2E8B57)
[![MIT license](https://img.shields.io/github/license/shreeve/transfer?color=555)](LICENSE)

[Install](#install) · [Features](#features) · [Keys](#keys) · [Links from a terminal](#open-a-server-folder-from-its-terminal) · [Changelog](CHANGELOG.md)

</div>

Transfer browses a server the way Finder browses your disk. Press Space to preview a file. Open an editable file and every save uploads. Open a PDF or an image and it is only viewed. Drag a file to the Finder and you get a real copy. Command-C and Command-V copy files and folders to another folder, another server, or the Finder, and back; Option-Command-V moves them. A bar at the bottom shows what is copied, and Escape clears it.

It uses the `ssh` already on your Mac, so your `~/.ssh/config`, agent, and `ProxyJump` just work.

## Features

- **Finder's views.** Icons, list, and columns share one location and one selection. Tabs, a sidebar of servers and starred places, an inspector with a preview, and Finder's keys throughout. In column view, Shift with the mouse wheel, or a sideways swipe, reaches the columns off the left edge.
- **Live editing.** An editable file opens in its usual editor, and every completed save uploads. A save never overwrites a change someone made on the server: that becomes a conflict you settle with Compare, Keep Local, Keep Remote, or Keep Both. Edits made while offline upload after the next login.
- **Copy, paste, drag, and move** between folders, between servers, and to and from the Finder. A move removes an original only once it has checked that the copy is complete.
- **Quick Look** with Space, syntax-colored previews of text and source files, and View for everything else.
- **One login per server.** Every window and tab showing a server shares one ssh login. Listing, previewing, and copying run on separate channels, so a download never stalls the file list.
- **Fast.** Thousands of small files copy at over a thousand a second at 20 ms round trip, and a large file uses several channels at once.
- **`sftp://` links.** Command-click a link that `xfer` prints on a server, and the folder opens in Transfer.
- **Safe to install.** Signed with a Developer ID, notarized by Apple, and it updates itself.

It is a browser, not a mounted disk: there is no background helper, sync folder, or File Provider. [`docs/SPEC.md`](docs/SPEC.md) describes everything it does.

## Install

Transfer needs a Mac with Apple silicon running macOS 27 or later. Pick one way; each puts the same `Transfer.app` in your Applications folder.

**Homebrew**

```bash
brew install --cask shreeve/tap/transfer-sftp
```

**One-command installer**

```bash
curl -fsSL https://raw.githubusercontent.com/shreeve/transfer/main/Scripts/install.sh | bash
```

**Download.** Get `Transfer.zip` from the [latest release](https://github.com/shreeve/transfer/releases/latest), open it, and drag `Transfer.app` to Applications.

The first time you open Transfer after a Homebrew install or a download, macOS asks you to confirm opening an app from the internet; that is normal. Then open it from Launchpad, Spotlight, or with `open -a Transfer`.

<details>
<summary>More about each way to install</summary>

**Homebrew** adds the `shreeve/tap` tap the first time. The cask is `transfer-sftp` because Homebrew's own `transfer` is a different app, which also installs a `Transfer.app`; the two cannot be installed together.

**The installer** downloads the newest release from GitHub and installs it only if the app is signed with Transfer's Developer ID and Gatekeeper accepts it as notarized, so it stops, changing nothing, on a Mac where Gatekeeper's checks are turned off. It puts `Transfer.app` in `/Applications` (or `~/Applications` if `/Applications` is not writable). An existing copy is replaced only once the new one is ready, so a failed install leaves it in place. To install somewhere else, name the folder:

```bash
curl -fsSL https://raw.githubusercontent.com/shreeve/transfer/main/Scripts/install.sh | TRANSFER_DEST=~/Apps bash
```

The bundle id is `com.github.shreeve.transfer`.

</details>

## Update

Transfer updates itself, however it was installed. Choose **Transfer → Check for Updates…** at any time; a new version downloads, installs, and relaunches when you click **Install Update**. Settings → Updates turns automatic checks on or off and shows when it last checked.

- **Homebrew:** `brew upgrade` skips Transfer, since the app keeps itself current, and `brew list --versions` may show the version first installed. `brew upgrade --greedy transfer-sftp` updates it through Homebrew instead.
- **Installer:** running the install command again also updates to the newest release, replacing the app in place.

## Uninstall

Remove it the way you installed it. Each of these removes only the app: your saved servers, Live files, and settings stay, so a later install picks up where you left off.

**Homebrew**

```bash
brew uninstall --cask transfer-sftp
```

**Installer**

```bash
curl -fsSL https://raw.githubusercontent.com/shreeve/transfer/main/Scripts/install.sh | bash -s -- --uninstall
```

**Download.** Drag `Transfer.app` from Applications to the Trash.

`brew uninstall --zap --cask transfer-sftp` also deletes your data: saved servers, Live file working copies, caches, and preferences, but not passwords in the Keychain. Check first that no Live file has unsynced edits. [Where your data lives](#where-your-data-lives) lists everything, for removing it by hand.

**Switching between Homebrew and the installer.** Homebrew will not install over a `Transfer.app` it did not put there. To move to Homebrew, uninstall with the installer's `--uninstall` first, then `brew install`. To move from Homebrew to the installer, `brew uninstall --cask transfer-sftp` first, so Homebrew does not keep a record of an app it no longer manages. Your data carries over either way.

## Keys

The ones you will reach for most; [`docs/SPEC.md`](docs/SPEC.md#menus-and-keys) has them all.

| Do | Press |
| --- | --- |
| Open (Live for an editable file, View for any other) | Command-O or Command-Down |
| Quick Look | Space |
| Copy, Paste | Command-C, Command-V |
| Move Item Here | Option-Command-V |
| Clear the clipboard | Escape |
| Rename | Return |
| Delete… | Command-Delete |
| Go to Remote Folder… | Command-L |
| Parent folder, Back, Forward | Command-Up, Command-[, Command-] |
| Icons, List, Columns | Command-1, Command-2, Command-3 |
| New Connection…, New Window, New Tab | Command-K, Command-N, Command-T |
| Sidebar, Inspector | Command-B, Command-I |

## Open a server folder from its terminal

Transfer opens `sftp://` links. A link to a folder opens it in a window that shows no server yet, or else in a new tab; a link to a file selects it in its folder. The server is found among your saved servers by name, by the host name `~/.ssh/config` gives it, or by address; a server not yet saved opens the New Connection sheet, filled in.

`Tools/xfer` prints such a link from a shell on the server, for Command-click in Ghostty or any terminal that shows OSC 8 links. Install it on each server, with the name the Mac uses for that server:

```bash
ssh live 'mkdir -p ~/bin ~/.config/transfer && cat > ~/bin/xfer && chmod 755 ~/bin/xfer && echo live > ~/.config/transfer/host' < Tools/xfer
```

`~/bin` must be on the server's `PATH`. Many shells, zsh among them, leave it off: add `export PATH="$HOME/bin:$PATH"` to `~/.zshrc` or `~/.profile` there. Then run `xfer` (this folder) or `xfer some/path` on the server and Command-click what it prints. Inside tmux older than 3.4, `xfer` says when `allow-passthrough` must be on for the link to get through.

## How a connection works

Transfer uses the `ssh` already on the Mac, so your `~/.ssh/config`, agent, and `ProxyJump` apply. One login is shared by every window for that server. Listing, the file you are previewing, and copying run on separate SSH channels, so a download does not block the file list, and many files copy at once.

Which files open for editing is `editableExtensions` in `config.json`. The first launch copies `Support/config.json` to the library, and Settings → Extensions edits that copy.

## Where your data lives

| What | Where |
| --- | --- |
| Saved servers, stars, Live file records | `~/Library/Application Support/Transfer/transfer.sqlite`, and the `-wal` and `-shm` files beside it (`transfer.lock` there keeps a second copy of Transfer out) |
| Working copies of Live files | `~/Library/Application Support/Transfer/Live/` |
| Editable file extensions | `~/Library/Application Support/Transfer/config.json` (Settings → Extensions) |
| Passwords and passphrases you chose to save | Keychain, service "Transfer" |
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

`Scripts/package-app.sh` builds `Transfer.app` (in `.build`, or in the folder `SCRATCH` names) and prints its path. `TRANSFER_LIBRARY` gives the build a library of its own, with its caches inside it, so it never touches your saved servers, Live files, or caches.

<details>
<summary>Without <code>TRANSFER_LIBRARY</code>, and testing against a server</summary>

Leave `TRANSFER_LIBRARY` out only on purpose: without it the build opens your real library, and only one copy of Transfer opens a library at a time, so it quits while your installed copy is open and otherwise works on your saved servers and Live files. Either way the build shares the installed app's preferences, and `sftp://` links open in whichever copy macOS registered last; open the installed copy once to send them back to it.

`swift test` needs no server. The tests that log in run against an unprivileged local `sshd`, never Remote Login or a real server:

```bash
eval "$(Scripts/local-sshd.sh 2222)" && TRANSFER_REQUIRE_SERVER=1 swift test; kill $TRANSFER_TEST_SSHD
```

The port is optional (2222 by default). Without the server those suites report skipped; `TRANSFER_REQUIRE_SERVER=1` makes them fail instead.

</details>

## Documentation

| File | What it covers |
| --- | --- |
| [`docs/SPEC.md`](docs/SPEC.md) | What the app does: every action and the rules it keeps |
| [`HANDOFF.md`](HANDOFF.md) | How the code works, including the window layout and the traps that already cost a day |
| [`AGENTS.md`](AGENTS.md) | The short rule list for an automated session |
| [`docs/RELEASING.md`](docs/RELEASING.md) | How releases and updates work (`Scripts/release.sh X.Y.Z`) |
| [`CHANGELOG.md`](CHANGELOG.md) | What changed in each version |

## License

[MIT](LICENSE)
