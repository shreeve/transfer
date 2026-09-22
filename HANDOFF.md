# Handoff

`PLAN.md` is the specification. This file is only the state of the code. Where they disagree, build what `PLAN.md` says.

The package builds on Apple-silicon macOS 27 with the Xcode 27 toolchain. `swift test` passes. `Scripts/package-app.sh` writes `.build/Transfer.app`.

## Layout

| Target | Role |
| --- | --- |
| `TransferCore` | Values and decisions. No SwiftUI, AppKit, or processes. |
| `TransferIO` | `/usr/bin/ssh`, the SFTP packet codec, SQLite, Keychain. |
| `TransferUI` | Windows, sheets, `NSBrowser`, file promises, Quick Look. |
| `Transfer` | `@main`. The only target that imports both UI and IO. |

`RemoteSession` in Core is the seam. `SSHConnection` is the implementation. Views must not import `TransferIO`.

`Support/config.json` lists `editableExtensions`. First launch copies it to `~/Library/Application Support/Transfer/config.json`.

## Already working

- One SSH master per connection, `Compression=no`, host-key sheet, askpass, Keychain opt-in.
- One probe of `performance-version --probe` after login. The stub in `Tools/performance-version` exits 2, so copies stay on SFTP.
- Channels: browse, interactive, and walker at login. Data channels open on demand, at most 7.
- Icon, list, and column view. Sidebar sections for servers, pins, recents, Live files, and conflicts.
- Back, forward, parent, remote home, go-to-folder, and a local name filter.
- Double-click follows the file. Open Live forces a working copy. Space previews. Text previews are simple colored HTML.
- Drag out uses `NSFilePromiseProvider` and writes a real file. Dropping files uploads into the current directory.
- Name-collision sheet, Live-conflict sheet, permanent delete, duplicate, rename, pin, discard Live, clear preview cache, quit with unsynced Live work.
- Directory download skips files with the same size and whole-second mtime, copies symlinks as links, and sets mode and mtime before the final rename.

## Still required by the spec

- Persist Live mappings in the existing `live_files` table and resume an unsynced upload after relaunch. The table is created and unused. Live state is only in memory.
- Watch Live files through `NSFileCoordinator`. Confirm before discarding unsynced bytes.
- Shelf: pause one operation, retry a failed one, and retry a dropped connection or timeout three times (1s, 2s, 4s). No cancel control for the running copy. Uploads are still one chunk at a time.
- Drop onto a folder row uploads into that folder. A drag onto another remote folder is one SFTP rename, not a copy.
- Tabs and extra windows share one login per saved server. Column widths, sort, and window frame are not saved.
- Command-F focuses the filter. Space toggles Quick Look closed. A new preview cancels the preview download already running.
- Cap the preview cache at 1 GB and exclude it from backup.
- Edit and remove a saved server in the sidebar. Trust a host key into the `known_hosts` file reported by `ssh -G`, not only Transfer’s own file.
- The fast directory engine stays unwired. `PerformanceDirectoryCopy.available()` returns false.

## Traps

- On this SDK `NSFilePromiseProvider` is an `NSPasteboardWriting` object, not an `NSItemProvider`. The drag starts from `PromiseText` in `Sources/TransferUI/FilePromise.swift`.
- Do not add libssh, a tunnel, HTTP/3, or compression. The transport is `/usr/bin/ssh`.
- Do not embed rsync. A later fast copy replaces `Tools/performance-version` and must not change the browser.
- `TransferUI` calling `FileManager` for the preview cache is a seam leak. Clearing the cache belongs on `RemoteSession`.
