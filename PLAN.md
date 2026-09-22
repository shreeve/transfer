# Transfer — Build Specification

Status: Locked for a one-pass build  
Target: macOS 27 and later, Apple silicon  
Bundle identifier for this pass: `com.example.Transfer`  
Language: Swift  
UI: SwiftUI, with AppKit only for `NSBrowser`, `NSFilePromiseProvider`, Quick Look, and `NSWorkspace`  
Project: the existing Swift package. No Xcode project. Three libraries, one app: `TransferCore` (values), `TransferIO` (the machine), `TransferUI` (views). The `Transfer` executable only connects them.

This document is the specification. Where an older note disagrees with this file, this file wins.

## 1. Product

Transfer is one remote browser window, not a second Finder and not a mounted disk. The user connects to an SFTP server, browses it, previews files, opens editable files so saves upload, and drags files to and from Finder.

It should feel like a small utility Apple might have shipped next to Finder: standard controls, no custom chrome, no dual pane.

### 1.1 The four actions

| Action | Result |
| --- | --- |
| Double-click, Command-O, or Command-Down on an editable file | Live. The file opens in its normal editor. Completed saves upload. |
| Double-click, Command-O, or Command-Down on anything else | View. The file opens from the preview cache. Saves are not uploaded. |
| Space | Preview in Quick Look. Not Live. |
| Drag to Finder, or Download Copy | A detached local copy. |

Open Live (Option-Command-O) forces a Live file even when double-click would only view. Return renames. Drag never deletes the remote file.

An editable file is one whose filename UTI conforms to `public.plain-text` or `public.source-code`, or whose extension is exactly one of: `rip`, `txt`, `json`, `ts`, `rs`, `c`, `md`, `swift`, `py`, `js`, `jsx`, `tsx`, `html`, `css`, `yaml`, `yml`, `toml`, `sh`. Do not sniff contents. PDF, images, and every other type view.

### 1.2 What this pass builds

- Connect, host-key prompt, and password or keyboard-interactive prompt.
- Sidebar, toolbar, icon view, list view, column view, inspector, transfer shelf.
- Native tabs and extra windows that share one login per saved server.
- Quick Look, including a syntax-colored text preview when the system preview would be generic.
- Drag in, drag out, Download Copy, Upload, duplicate, rename, new folder, permanent delete.
- Directory copy on the SFTP channels.
- Live open, view open, conflicts, and Open in Terminal.
- A performance-mode probe and a `DirectoryCopyEngine` seam. The fast engine is a stub.

### 1.3 What this pass does not build

Do not add disabled controls for these. They are absent.

Gallery, a permissions editor, trash, a background helper or login item, File Provider, any protocol other than SFTP, remote-to-remote copy, sync roots, iCloud, a CLI, remote search, git decorations, an editor, an embedded terminal, a diff viewer, spring-loaded folders, block checksums, byte-range resume, Keep Downloaded, AppleDouble or resource forks, onboarding, a help book, telemetry, and an updater.

`rsync` is not called. The fast directory copy is the later program that replaces `Tools/performance-version`. This pass only reserves that slot.

## 2. Connection

### 2.1 The sheet

File > New Connection, or Add Server in the sidebar, opens one sheet:

| Field | Required | When blank |
| --- | --- | --- |
| Name | no | Use the Host text |
| Host | yes | — |
| User | no | Let `~/.ssh/config` decide |
| Port | no | Let `~/.ssh/config` decide |
| Identity file | no | Let `~/.ssh/config` and the agent decide |
| Remote path | no | Start at the remote home (`realpath(".")`) |

There is no password field, proxy field, compression field, or protocol picker. The same sheet edits a saved connection. Edits apply on the next connect. Remove deletes the saved connection after confirmation, never remote files, and refuses while that connection has unsynced Live bytes.

### 2.2 Login

Each saved connection has its own SSH master. Two saved connections never share a socket, even on the same host.

The socket directory is `~/Library/Application Support/Transfer/ssh`, mode `0700`. The socket path includes the connection's stable id.

Login runs `/usr/bin/ssh` and no other SSH binary. These options override user config: `ControlMaster=yes`, `Compression=no`, `ControlPath` set to that socket. The master uses `-N` and does not speak SFTP. Every later `ssh` for this connection, including passengers, the probe, and Open in Terminal, also passes `Compression=no`.

The agent holds keys. The app never reads private-key bytes, never puts secrets in argv or the environment, and never logs passwords, passphrases, or prompt replies.

Password and keyboard-interactive prompts are sheets, driven by an askpass helper with `SSH_ASKPASS_REQUIRE=force`. Each sheet shows ssh's prompt text, a secure field, Cancel, and Continue. The first prompt of a connection may offer "Save in Keychain", off by default. A saved secret is replayed only as the first prompt of a later login. Secrets are not stored in SQLite.

On disconnect or quit, the app runs `ssh -S <socket> -O exit` and does not leave a master behind. A stale socket whose process is dead is removed before the next login.

### 2.3 Host keys

`StrictHostKeyChecking` is never `no`.

| Situation | Sheet | Default button |
| --- | --- | --- |
| Key already stored and unchanged | no sheet | connect |
| First-seen key | Cancel, Trust Once, Always Trust | Cancel |
| Changed key | Cancel, Replace Trusted Key | Cancel |

Show the key type and SHA256 fingerprint. Always Trust and Replace Trusted Key write only the known-hosts file that `ssh -G` reports. Trust Once uses a temporary known-hosts file for that master and discards it on disconnect. A rejected or changed key does not open channels. Acceptance starts a new login.

### 2.4 Performance probe

Immediately after the master is up, probe once. Do not probe again until the next login.

The probe runs:

```text
/usr/bin/ssh -S <socket> -o Compression=no -- performance-version --probe
```

The connection stores one boolean, `performanceModeEnabled`, in memory only:

- `true` only when the exit code is 0 and stdout is one non-empty version line.
- `false` on any other result, including command-not-found, timeout at 10 seconds, or an SFTP-only server that refuses the command.

v1 servers do not have this program, so the flag is false and every copy uses SFTP. The repository still contains `Tools/performance-version`, which prints `performance-version 0` and exits 2, so the contract has a home. The app does not install it on the server.

Listing, preview, view, and Live editing always use SFTP, even when the flag is true.

## 3. Channels

After the probe, open SFTP passengers on the master. Each is its own process:

```text
/usr/bin/ssh -S <socket> -o Compression=no -s sftp -- <destination>
```

Open them in this order: browse, interactive, walker, data 1, data 2, data 3, data 4. Speak SFTP version 3 on stdin and stdout (length-prefixed packets). Do not parse the `sftp` command's text. If the server's version is not 3, mark that passenger down.

Stop at the first refusal. Do not retry that refusal during this login. A passenger that dies later gets one reopen. A second death marks it down until the next login.

| Role | Count | Work |
| --- | --- | --- |
| Browse | 1 | Browser listings and metadata. At most one request in flight. |
| Interactive | 1 | The one file the user is waiting on: Quick Look, view, Live open, or Live save. |
| Walker | 1 | Names, mkdir, readlink, and delete for a tree copy. No file bodies. |
| Data | 4 | File bodies for drag, download, upload, duplicate, and directory copy. |

A new preview, open, or save cancels whatever the interactive channel is doing, deletes that temp, and starts the new request. A displaced preview or view is dropped. A displaced Live save stays pending and is next on that channel.

File bodies never use the browse channel. If browse failed to open, listings use interactive between its jobs. If interactive failed, preview and Live borrow one data channel and follow the same preempt rule. If the walker failed, the name walk uses browse when it is idle. If no data channel opened, transfers fail and browsing still works.

Concurrent files use the four data channels. A fifth file waits. A file of 2 MB or larger occupies its channel alone. Smaller files may share a channel while its window has room. Do not open a channel per file.

Each data channel keeps 2 MB (2,097,152 bytes of payload, not packet overhead) of READ or WRITE in flight, in 64 KB chunks, the last chunk shorter. Outstanding requests on one channel are all reads or all writes.

Metadata operations use `LSTAT` and `READDIR` and do not follow links. `READLINK` reads a link target.

## 4. Directory copy

`DirectoryCopyEngine` has two implementations.

- `SftpDirectoryCopy` is the v1 engine. The walker emits each directory page as it arrives. Directories are created as their names arrive. File bodies are assigned to data channels immediately. The copy does not wait for the whole tree to be listed.
- `PerformanceDirectoryCopy` is the later engine. v1's probe is false, so it is not selected. If a future probe is true and that engine then fails to start, that copy uses `SftpDirectoryCopy` and the flag is cleared for the rest of the connection.

Upload walks the local disk and does not use the walker for that walk. Download walks on the walker.

### 4.1 One file

1. Stat the destination without following links.
2. If it is a regular file with the same size and the same whole-second mtime, skip it. Live saves do not use this skip.
3. If it exists and differs, show the collision sheet (§7). If a file name is occupied by a directory, or the reverse, fail that item and continue.
4. Otherwise write `.<basename>.transfer-<uuid>` in the same parent directory. Record that temp in SQLite before the first byte.
5. On success, set the temp's mode and mtime from the source, then rename it onto the final name. Prefer `posix-rename@openssh.com` when the server advertises it. Otherwise delete the destination only after the temp is complete, then rename.
6. If the rename fails, leave the temp, mark the item failed, and do not report success.
7. Cancel or failure before rename deletes the temp. Finished files and directories already created stay.

A later launch deletes only temps still recorded in SQLite. There is no byte-range resume.

Symlinks are copied as symlinks, using the exact `READLINK` target, and are never followed. Anything that is not a file, directory, or symlink is skipped.

## 5. Browsing

### 5.1 Window

A `NavigationSplitView`: sidebar, browser, optional inspector. The transfer shelf is a bottom bar, not a second pane. The toolbar uses the standard unified style and contains back, forward, path, view mode (Icon, List, Columns), and a transfers button that shows the active count and toggles the shelf.

Icon is a SwiftUI grid. List is a SwiftUI table. Columns are `NSBrowser`. All three read the same `BrowserModel`. The AppKit view does not own that model.

List columns default to Name, Status, Date Modified, Size, and Kind. Status is blank unless the row is Live or transferring. Directory and symlink sizes are blank. The default sort is name ascending, raw bytes, case-sensitive, directories not pinned. Column layout and sort persist per connection. The view mode persists globally. Names that start with `.` are hidden. The choice is global, off by default, toggled by View > Show Hidden Files (Command-Shift-Period). `.` and `..` are never shown.

### 5.2 Identity and listing

A row's identity is the connection id plus the raw path bytes. Do not Unicode-normalize, case-fold, or use a server inode. Invalid UTF-8 is displayed with replacement characters and the original bytes are what every operation uses.

`list` is an `AsyncThrowingStream` of `READDIR` pages. The browser appends rows as pages arrive and does not publish one main-actor update per name. On revisit, show the cached page immediately, then refresh in place matched by raw path. A failed refresh keeps the rows and shows the error.

There is no polling. Reload a directory when it is entered, on Command-R, and after Transfer itself changes that directory.

Command-F filters the names already listed. It does not touch the network.

### 5.3 Sidebar

Sections, top to bottom: Servers, Recents, Saved Locations, Live Files, Conflicts. Empty sections other than Servers are hidden.

Recents are the last 10 remote directories. Saved Locations are directories pinned from the context menu. Selecting a server connects and opens its start path. Selecting a location navigates. Selecting a Live file or a conflict reveals and selects it and does not open it.

### 5.4 Inspector

Hidden by default. Command-Option-I toggles it. One selection shows name, icon, remote path, kind, size, modified time, read-only permissions, owner, group, Live state, and progress or error. Actions are Open, Open Live, Download Copy, and Copy Remote URL. Copy Remote URL writes one `sftp://` URL per item, with no password. Multiple selection shows a count. Empty selection shows the current folder. There is no preview inside the inspector. Permissions cannot be edited.

### 5.5 Menus and keys

| Command | Shortcut |
| --- | --- |
| Follow double-click (Live or View) | Command-O, Command-Down |
| Open Live | Option-Command-O |
| Quick Look | Space |
| Rename | Return |
| Parent | Command-Up |
| Back / Forward | Command-[ / Command-] |
| Remote Home | Command-Shift-H |
| Go to Remote Folder | Command-L or Command-Shift-G |
| Filter listed names | Command-F |
| Refresh | Command-R |
| New Folder | Command-Shift-N |
| Duplicate | Command-D |
| Delete | Command-Delete |
| New Connection | Command-K |
| New Window | Command-N |
| New Tab | Command-T |
| Icon / List / Columns | Command-1 / 2 / 3 |
| Sidebar | Command-Option-S |
| Inspector | Command-Option-I |
| Hidden files | Command-Shift-Period |

Download Copy, Upload, and Open in Terminal have no shortcut. There is no Command-J and no gallery shortcut.

Open, Open Live, and Quick Look use the primary selection. Transfers use the whole selection. Command-Z works only in text fields.

Go > Open in Terminal is disabled when disconnected or when none of Terminal, iTerm2, and Ghostty is installed. It opens the current remote directory, not the selection, in a running Terminal, iTerm2, or Ghostty if one is running, otherwise the first of those three that is installed. That app runs `/usr/bin/ssh` as another client of the same master, `cd`s to the remote path (POSIX single quotes), and starts the remote login shell. It does not take an SFTP channel. There is no terminal view inside Transfer.

## 6. Preview, view, and Live

### 6.1 Preview

Space toggles `QLPreviewPanel`. Escape closes it. Changing the selection aborts the previous preview download on the interactive channel.

PDF, images, and other non-text files are downloaded whole into the preview cache and handed to Quick Look. For text and source, if the system preview would be generic, read at most the first 512 KB, write a temporary HTML file in the system monospace font with simple syntax coloring, and preview that HTML. Do not add a Quick Look extension. Invalid UTF-8 uses the generic system preview. Preview files are never Live and are never uploaded.

The preview cache is `~/Library/Caches/Transfer/Preview/`, names hashed from the raw path, LRU-capped at 1 GB, and is not backed up. View > Clear Preview Cache does not touch Live files.

### 6.2 View

A non-editable double-click downloads the whole file into the preview cache and opens it with `NSWorkspace`. Transfer does not watch it and does not upload it.

### 6.3 Live

A Live open downloads into:

```text
~/Library/Application Support/Transfer/Live/<connection-uuid>/<live-uuid>/<basename>
```

Mode `0700` for the directory and `0600` for the file. The mapping is a UUID stored in SQLite. The remote identity remains the raw path. A rename updates the path and the basename and keeps the UUID.

Before opening, record the base fingerprint: type, size, and whole-second mtime. No hash and no inode. Open with `NSWorkspace`.

Watch the workspace directory. A safe-save that replaces the file is the same Live file. Upload 400 ms after size and mtime stop changing, reading through `NSFileCoordinator`, on the interactive channel, using the temp-and-rename rule in §4.1. The pre-check is the base fingerprint, not the size-and-mtime skip. If the remote fingerprint changed, or the remote file is gone, the state becomes Conflict and nothing is uploaded.

The mapping remains after the editor closes, the window closes, quit, and reboot. Uploads run only while Transfer is open. On launch, resume Live uploads. Do not resume drags or directory copies. Quit with unsynced or active Live work asks Cancel (default) or Quit Anyway.

Save As outside the workspace is a detached file. If a clean working file disappears, drop the mapping. If a dirty one disappears, mark it failed and do not upload. File > Discard Live File removes a clean mapping immediately and asks before discarding unsynced bytes. It is disabled while an upload of that file is in flight.

A symlink is listed as itself. Double-click, Open, and Quick Look follow one hop. A directory hop is navigated. A file hop is viewed or opened Live at the resolved path, so a save writes the file that was read. A loop or a second hop is an error. The inspector fetches the target when that row is selected.

## 7. Collisions, conflicts, and delete

Two different sheets.

**Name collision** (upload, download, or directory copy onto an existing item that is not an exact size-and-mtime match): Skip (default), Keep Both, Replace, and Apply to All for that operation only. Keep Both inserts ` 2`, ` 3`, before the extension. The sheet blocks that operation. Other operations continue.

**Live conflict:** Compare, Keep Local, Keep Remote, Keep Both. No Apply to All and no destructive default. Compare writes the remote bytes beside the working copy as `<basename> (server)` and opens `/usr/bin/opendiff` when both sides are valid UTF-8 and `opendiff` exists. Otherwise Compare is disabled. Keep Local and Keep Remote each require a second confirmation. Keep Both uploads the local bytes as `<basename> (from this Mac)`, leaves the original remote file, and rebases the working copy on the remote bytes. That sibling is not Live.

Delete is permanent. There is no trash. Command-Delete asks once for the selection, names the count, says the delete is permanent, and says when unsynced Live bytes will be discarded. Cancel is the default. The button says Delete. A directory is walked depth-first. Symlink nodes are removed and not followed. Files already removed are not rolled back. On success, delete the matching Live workspace folders.

## 8. Drag and the shelf

Drag to Finder uses `NSFilePromiseProvider`, one promise per dragged root. A directory promise is fulfilled by §4. Option and Command do not change the drag and never remove the remote item. The result is a real file or folder, never a clipping, a URL, or a zero-byte placeholder.

Drag from Finder uploads. The local original stays. A drop on the background uses the current directory. A drop on a folder row uses that folder. There is no spring-loading.

A drag inside the browser, to another folder on the same server, is one SFTP rename. If rename fails, show the error. Do not copy-then-delete.

Duplicate (Command-D) creates `name copy`, then `name copy 2`, through §4.1.

With a selection and no text field focused, Command-C copies the `sftp://` URLs. Command-V does not upload. Cut is disabled outside text fields.

The shelf is one row per top-level operation. A directory copy is one row, with byte and item progress. It is hidden when nothing is active, paused, failed, or in conflict. Successful rows disappear when they finish. Failed rows stay and offer Retry and Remove. Remove does not delete finished files. Pause applies to that one operation, including one Live upload. There is no global pause.

Retry a dropped connection or a timeout three times, at 1 s, 2 s, and 4 s, then show the error. Do not auto-retry an authentication failure, a permission denial, a host-key failure, or a conflict. The user presses Retry to log in again.

## 9. Storage

SQLite in Application Support holds connections (no secrets), recents, saved locations, Live mappings, the operation queue, and temp-file records. Preferences hold the view mode, hidden-files flag, and window state. The Keychain holds only the secrets the user chose to save.

## 10. Errors

Every failed operation names the file and the reason in the shelf and, for a connection failure, in the window. A partial `READDIR` keeps the names already shown. The app never reports success for a file whose rename did not finish.

## 11. Code layout

Three libraries and one executable. Dependencies point one way: UI and IO may use Core. Core uses neither. UI does not use IO. The executable is the only place that may import both UI and IO.

```text
Sources/TransferCore/     values and decisions
Sources/TransferIO/       ssh, SFTP, files, SQLite, Keychain
Sources/TransferUI/       SwiftUI and the four AppKit adapters
Sources/Transfer/         @main, wiring only
Tests/TransferCoreTests/  no network, no window
Tools/performance-version/
```

| Target | Holds | Must not import |
| --- | --- | --- |
| `TransferCore` | The types in §11.1 and the `RemoteSession` methods in §11.2 | SwiftUI, AppKit, `Process`, `FileManager`, Network, SQLite, Keychain |
| `TransferIO` | `SSHConnection` and everything that touches a process, a socket, a file, SQLite, or the Keychain | SwiftUI, AppKit |
| `TransferUI` | Windows, lists, columns, sheets, `NSBrowser`, file promises, Quick Look | `TransferIO`, `Process` |
| `Transfer` | Creates `SSHConnection`, passes it to the window as a `RemoteSession` | — |

A Core function returns a decision, such as "this file is editable" or "skip this copy", and does not open a socket or a file. A view holds those values and calls `RemoteSession`. It does not know the bytes came from `/usr/bin/ssh`. Tests for Core run with no network and no window.

### 11.1 Where each type lives

**TransferCore**

- `RemotePath`: the raw path bytes. No normalization, no case folding.
- `ConnectionID`, `LiveFileID`: stable UUIDs.
- `RemoteItem`: path, name bytes, kind (file, directory, symlink, other), size, whole-second mtime, mode, owner, group, and the symlink target when already known.
- `Fingerprint`: type, size, whole-second mtime.
- `OpenKind`: the decision `live` or `view`, from the rule in §1.1. `func openKind(name:extension:uti:) -> OpenKind`.
- `ChannelRole`: browse, interactive, walker, and the four data roles. This type already exists.
- `NameCollisionChoice`: skip, keep both, replace. `KeepBothName` produces `name 2`, `name 3`.
- `LiveConflictChoice`: compare, keep local, keep remote, keep both.
- `CopyDisposition`: skip, fail, or write `.<basename>.transfer-<uuid>`. Pure comparison of two `RemoteItem`s. No I/O.
- `TransferProgress`, `OperationState`: queued, active, paused, succeeded, failed, canceled.
- `HostKeyEvent`: unchanged, first seen, changed, plus the key type and SHA256 fingerprint. The sheet is not in Core.
- `ProbeResult`: the boolean and the version line. Parsing stdout is pure. Running the process is not.
- `SftpURL`: one password-free `sftp://` string for a path.
- `BrowserSnapshot`: connection, path, selection (raw paths), view mode, sort, hidden-files flag. A value, not an `@Observable` object.

**TransferIO**

- `SSHConnection`: the master, the probe, the passengers, and the `RemoteSession` implementation.
- `SFTPChannel`, the version-3 packet codec, and the scheduler that fills the data channels.
- `SftpDirectoryCopy`, `PerformanceDirectoryCopy`, and `DirectoryCopyEngine`.
- SQLite, the Keychain, the preview-cache files, the Live workspace files, and the directory watcher.
- The askpass helper that feeds prompt replies back to `ssh`. It does not draw the sheet.

**TransferUI**

- `@Observable` window state that holds a `BrowserSnapshot` and a `RemoteSession`.
- Sidebar, toolbar, icon grid, table, `NSBrowser` adapter, inspector, shelf, menus.
- Sheets for the connection, host key, password, name collision, Live conflict, delete, and quit. Each sheet returns a Core choice. It does not apply the choice itself.
- File-promise and drop adapters. They call `RemoteSession`.
- Quick Look. The HTML for a syntax preview is produced from bytes the session already returned.

### 11.2 The seam

`RemoteSession` is a protocol in `TransferCore`. `SSHConnection` is the only implementation, and it stays in `TransferIO`. Views depend on the protocol.

The protocol covers connect, disconnect, list, stat, readlink, download, upload, mkdir, rename, remove, symlink, the one probe result, and directory copy. Listing returns an asynchronous stream of `RemoteItem`. Progress is a stream of `TransferProgress`. Methods return Core values and Core errors. They do not return file descriptors, process objects, or SwiftUI types.

The app target constructs `SSHConnection`, erases it to `RemoteSession`, and hands that to the window. A preview, a test, or a later performance engine can supply another implementation without changing a view.

## 12. Build order

Build on the existing package, in this order. Each step compiles and is worth a commit. New code goes into the target named in §11.

1. The `TransferCore` types in §11.1, including `RemoteSession` and `openKind`, with tests and no network.
2. `SSHConnection` in `TransferIO`, as the `RemoteSession` implementation: master, askpass replies, the one probe, and the seven passengers. The sheets that collect those replies stay in `TransferUI`.
3. SFTP version-3 session in `TransferIO`: list, stat, readlink, mkdir, rename, remove.
4. The browser in `TransferUI`: sidebar, icon, list, columns, hidden files, and cached reload.
5. `SftpDirectoryCopy` in `TransferIO`; the shelf and drag adapters in `TransferUI`. Download Copy and delete.
6. View, Live, the conflict sheets, and quit-with-unsynced-work.
7. Quick Look, the inspector, and Open in Terminal.
8. `Tools/performance-version` and `PerformanceDirectoryCopy`, present and unused.

`Tools/performance-version` prints `performance-version 0` and exits 2. `PerformanceDirectoryCopy` is not selected while the probe is false. Replacing that tool later must not require a change to the browser.

## 13. Acceptance

This pass is done when all of the following are true.

1. The app runs on Apple-silicon macOS 27, from the Swift package, and uses standard controls.
2. A new connection honors `~/.ssh/config`, the agent, `ProxyJump`, and keyboard-interactive prompts, with compression forced off.
3. A first-seen host key and a changed host key use the sheets in §2.3.
4. The probe runs once after login. A missing `performance-version` leaves the connection on SFTP.
5. Listing a large directory shows the first page before the listing finishes, and a download does not block that listing.
6. Icon, list, and column view share one selection and one path. There is no gallery control.
7. Space previews PDF and images, and previews text and source with syntax coloring. Preview does not upload.
8. Dragging a remote file to the Desktop creates the real file. Dragging a local file in uploads it.
9. Double-clicking `.json`, `.rs`, `.c`, `.ts`, `.txt`, or `.rip` opens a Live file and a completed save uploads. Double-clicking `.pdf`, `.jpg`, or `.png` views it and does not upload.
10. A remote change during a Live edit becomes a conflict and does not overwrite either side.
11. A directory copy starts before the walk finishes, uses at most four data channels, skips matching size and mtime, copies symlinks as links, and deletes only its own temp on cancel.
12. Delete is permanent, confirmed, and has no trash.
13. Open in Terminal opens the current directory in Terminal, iTerm2, or Ghostty and does not add a pane to the window.
14. No secret is written to the log or to SQLite.
15. `TransferUI` does not import `TransferIO`. `TransferCore` does not import `TransferUI` or `TransferIO`. A view reaches the server only through `RemoteSession`.
