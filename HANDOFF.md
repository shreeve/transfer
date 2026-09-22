# Handoff

`PLAN.md` is the specification. This file is only the state of the code. Where they disagree, build what `PLAN.md` says.

The package builds on Apple-silicon macOS 27 with the Xcode 27 toolchain, with no warnings. `swift test` passes. `Scripts/package-app.sh` writes `.build/Transfer.app`.

## Layout

| Target | Role |
| --- | --- |
| `TransferCore` | Values and decisions. No SwiftUI, AppKit, or processes. |
| `TransferIO` | `/usr/bin/ssh`, the SFTP packet codec, SQLite, Keychain, Live workspaces. |
| `TransferUI` | Windows, sheets, `NSBrowser`, file promises, Quick Look. |
| `Transfer` | `@main`. The only target that imports both UI and IO. |

Two protocols in Core are the seam. `SessionProvider` is the library: saved servers and one `RemoteSession` per server. `RemoteSession` is one server. `TransferHub` and `SSHConnection` in IO implement them. Every window has its own `TransferModel` and asks the hub for the session, so windows and tabs share one login per saved server. Views never import `TransferIO`.

`Support/config.json` lists `editableExtensions`. First launch copies it to `~/Library/Application Support/Transfer/config.json`.

## Tests

`Tests/TransferCoreTests` and `Tests/TransferIOTests/WireTests.swift` run with no network.

`Tests/TransferIOTests/ServerTests.swift` runs the real SSH master, SFTP channels, directory copy, Live sync, conflicts, and relaunch against a local server. It is skipped unless two variables are set. Start the server and run:

```bash
eval "$(Scripts/local-sshd.sh)" && swift test; kill $TRANSFER_TEST_SSHD
```

The script starts an unprivileged `sshd` on 127.0.0.1:2222 with its own keys and never touches the system's Remote Login. The tests use Trust Once, so the user's `known_hosts` is never written. Their library roots live under `~/Library/Caches/TransferTests` and are removed afterwards.

## Working

- Login, askpass sheets, Keychain opt-in, one probe, browse, interactive, walker, and up to seven data channels. A reserved passenger that dies is reopened once. The master's death emits `.disconnected`.
- Host keys: the offered key is learned with a no-auth `ssh` run into a temporary known-hosts file, which honors `~/.ssh/config`, aliases, and `ProxyJump`. It is compared against the files `ssh -G` reports with `ssh-keygen -F`. Always Trust and Replace write only the first user file `ssh -G` names. Trust Once keeps the temporary file for that master and deletes it on disconnect.
- Listing streams pages; the model publishes at most every 80 ms and shows a cached listing first on revisit. Icon, list, and column views share one path and selection. Column view is `NSBrowser` with real selection, double-click, drag out, and drop.
- Sort and column layout persist per connection in preferences. View mode and hidden files persist globally. The window frame autosaves.
- Downloads and uploads keep 2 MB in flight per channel. Directory copy walks on the walker and assigns file bodies to the data pool as names arrive. Both directions use temp-and-rename, size-and-mtime skip, symlinks as links, and record temps in SQLite. A later launch deletes local temps; the next login deletes that server's remote temps.
- Drag to Finder writes real files through `NSFilePromiseProvider`. Drop on the background uploads into the current folder; drop on a folder row, in any view, uploads into that folder. A drag between folders on the same server is one SFTP rename per item.
- Live files persist in `live_files` with a dirty flag and resume on the next login. The workspace folder and the file itself are both watched, so safe-saves and in-place writes are seen. Uploads read through `NSFileCoordinator`, run on the interactive lane, and go 400 ms after size and mtime settle. Remote changes become conflicts with a `(server)` copy beside the working file; Compare opens `opendiff` from IO. Keep Local and Keep Remote need a second press.
- Shelf rows offer Pause, Resume, Retry, and Remove. Dropped connections and timeouts retry at 1 s, 2 s, and 4 s. A paused or retried operation re-runs its body; finished files are skipped by size and mtime. Live uploads can be paused too.
- Command-F focuses the filter. Space toggles Quick Look, and a new selection replaces the preview and cancels the download in flight. Space and Return leave text fields alone.
- Preview cache names are SHA256 of the raw path, capped at 1 GB by last use, excluded from backup. View files keep their extension so `NSWorkspace` picks the right app.
- Sidebar: Servers, Recents, Saved Locations, Live Files, Conflicts. Server rows offer Connect, Edit, and Remove. Remove refuses while that server has unsynced Live bytes.
- Delete names the count, says it is permanent, and mentions unsynced Live bytes only when the selection has them. Deleting a Live file also removes its workspace.
- Open in Terminal joins the same master with `-S` and is disabled without a connection or a terminal app.
- Quit asks Cancel or Quit Anyway through the app delegate whenever any server has unsynced Live work, and disconnects every master on the way out.

## Still open

- Small files do not share a data channel; every file takes a channel from the pool of seven.
- Command-Down is not bound as a second shortcut for Open.
- New Tab sends `newWindowForTab:`; the tab bar itself was not exercised.
- The list view's name cell is an AppKit view so it can start a promise drag; clicks on it select the row but shift-click ranges only work in the other columns.
- The fast directory engine stays unwired. `PerformanceDirectoryCopy.available()` returns false.

## Traps

- With `-s`, the subsystem name is the command argument and must follow the destination: `ssh -S sock -s -- host sftp`. The other order asks the server for a subsystem named after the host and every channel dies at the handshake. `PLAN.md` §3 was corrected.
- OpenSSH's sftp-server reads `SSH_FXP_SYMLINK` as target then link, the reverse of the draft. The draft order creates a stray link in the server user's home directory.
- Unix socket paths are capped at 104 bytes and ssh appends 17 bytes while binding. The socket name is `ConnectionID.socketName`, twelve hex characters, not the full UUID.
- ssh splits a bare `-o Name=value` on spaces, and the library lives under `Application Support`. Paths go through `-S`, `-i`, or a double-quoted `-o` value. A bare value silently wrote a known-hosts file at `~/Library/Application`.
- `URL.resourceValues` caches per URL instance. Size and mtime for a file that changes underneath are read with `FileManager.attributesOfItem`.
- A directory watch does not see in-place writes to a file. Live files watch the file descriptor as well, re-armed after every event because safe-saves replace the inode.
- On this SDK `NSFilePromiseProvider` is an `NSPasteboardWriting` object, not an `NSItemProvider`. `RemoteItemPromise` also writes `com.example.transfer.remote-items` so a drop inside Transfer knows the remote paths.
- Do not add libssh, a tunnel, HTTP/3, or compression. The transport is `/usr/bin/ssh`.
- Do not embed rsync. A later fast copy replaces `Tools/performance-version` and must not change the browser.
