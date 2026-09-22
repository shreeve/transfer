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

## Window chrome

The window is an AppKit frame with SwiftUI columns, in `Sources/TransferUI/WindowChrome.swift`. `ChromeController` is an `NSSplitViewController` with sidebar, content, and inspector items and it installs the `NSToolbar`: the system sidebar toggle, the navigational back/forward group, the view-switcher group, Transfers, and an `NSSearchToolbarItem`. The columns are `SidebarColumn`, `DetailColumn`, and `InspectorColumn` in `ContentView.swift`, each hosted once and observing the model on its own. `ChromeContainer` gives the split view explicit size constraints because SwiftUI's host view does not run the constraint engine for a representable's subtree. The content and inspector columns start below the toolbar; the sidebar runs full height. The sidebar stays fixed when the inspector opens: `sidebarItem.holdingPriority` and `inspectorItem.holdingPriority` are 260 and `detailItem.holdingPriority` is 250, so the content pane alone yields the space, and `detailItem.minimumThickness` is 260 (one column) so the content pane can absorb the whole inspector without the split view pushing into the sidebar. The window cannot grow to make room because `ChromeContainer` pins the split to the SwiftUI-assigned size, so the space always comes from the content pane. The title bar is transparent and every separator style is `.none`; the faint line Finder shows on toolbar hover is the system's own scroll pocket, so the content views hide their scroll-edge effect and nothing draws a line by hand.

The list view is `ListTable.swift`, an `NSTableView` with 22-point rows, header sorting, per-connection column autosave, drag out, drop onto folders, and the row context menu. The column view is `TiledBrowser`, an `NSBrowser` with fixed 260-point columns; `CenteredBrowserCell` draws the icon and title itself so they sit on the row's midline. Both views are 22 points a row, matching Finder's column view.

## Working

- Login, askpass sheets, Keychain opt-in, one probe, browse, interactive, walker, and up to seven data channels. A reserved passenger that dies is reopened once. The master's death emits `.disconnected`.
- Host keys: the offered key is learned with a no-auth `ssh` run into a temporary known-hosts file, which honors `~/.ssh/config`, aliases, and `ProxyJump`. It is compared against the files `ssh -G` reports with `ssh-keygen -F`. Always Trust and Replace write only the first user file `ssh -G` names. Trust Once keeps the temporary file for that master and deletes it on disconnect.
- Listing keeps four `READDIR` requests in flight and streams pages; the model publishes at most every 80 ms in every view and shows a cached listing first on revisit. Icon, list, and column views share one path and selection. Selecting a folder in column view makes it the current location and keeps it selected.
- Sorting: directories first and case-insensitive names are global switches in Settings > General; column and direction persist per connection. View mode and hidden files persist globally.
- Downloads and uploads keep 2 MB in flight per channel. Directory copy walks on the walker and assigns file bodies to the data pool as names arrive. Both directions use temp-and-rename, size-and-mtime skip, symlinks as links, and record temps in SQLite.
- Drag to Finder writes real files through `NSFilePromiseProvider`; a multi-item drag moves every item on an internal drop. In icon view the whole cell is one AppKit drag source (`IconItemView`), so grabbing the glyph starts the drag, not only the label. Drop on the background uploads into the current folder; drop on a folder row, in any view, uploads into that folder. A drag between folders on the same server is one SFTP rename per item.
- Column-view drag-out has one trap, found the hard way. The browser is also a drop target, so while its own drag crosses the browser's empty area beyond the last column, AppKit asks `validateDrop` about row −1, column −1. Answering with any operation makes `NSBrowser` (whose `pasteboardWriterForRow` path is new in macOS 27) cancel its own session and slide the icon back; the session ends 600 ms later with operation `none`, the button still down, and an end point back at the row. `validateDrop` therefore returns `[]` for column −1 whenever the pasteboard carries our `remoteDragType`; Finder's drags never do, so drop-in still works. Hand paths cross that area, straight synthetic paths seldom do, which is why it looked random. Diagnose drag problems by logging `canDragRows`, `pasteboardWriterForRow`, `validateDrop` (row and column), `draggingSession:endedAt:operation:` with `NSEvent.pressedMouseButtons`, and the promise's `writePromiseTo`; AppKit reports end points in flipped screen coordinates. Spring-loading and column re-tiling were both blamed first and both proven innocent.
- Live files persist in `live_files` with a dirty flag and resume on the next login. The workspace folder and the file itself are both watched. Uploads read through `NSFileCoordinator` on the interactive lane 400 ms after size and mtime settle. Remote changes become conflicts with a `(server)` copy; Compare opens `opendiff` from IO. Keep Local and Keep Remote need a second press.
- Shelf rows offer Pause, Resume, Retry, and Remove. Dropped connections and timeouts retry at 1 s, 2 s, and 4 s. Live uploads can be paused too.
- Command-F expands the toolbar search. The search item shows the full field when the toolbar has room and a magnifier when it does not, as Finder's does. Space and Return leave text fields alone.
- Settings (Command-Comma) has General, Extensions, and Updates tabs. Extensions edits `config.json` through the provider; open sessions pick the list up at once.
- Preview cache names are SHA256 of the raw path, capped at 1 GB by last use, excluded from backup. `prepareViewFile` returns the cached copy without a download when its size and mtime match the remote file.
- The inspector (Command-Shift-I) is a split column: bold name, kind against size, a divider, date against time, permissions against `owner:group`, then the preview. Text files render as highlighted, wrapped-or-not source in a `WKWebView` (the `Wrap lines` checkbox is a preference); pictures are decoded off the main thread; everything else goes through `QLPreviewView`. `PreviewTiming` in `TransferModel.swift` is the choreography: the fetch starts on the selection change, the old preview holds 100 ms so a fast fetch swaps with no animation, then the pane clears, the file icon fades in at 500 ms, a spinner joins it at 1 s. After each preview the files on either side are prefetched one at a time. Sizes everywhere use `Units.scale`, three characters plus an SI prefix.
- Opening the inspector reads differently per view. Icon: the grid reflows narrower, items left-packed at a fixed 108-point cell so nothing shimmies; long names wrap to two lines and middle-truncate. List: the Name column gives up width and the others hold, with a horizontal scroller only when the window is too narrow. Column: the sidebar stays fixed and the inspector takes space from the content pane; when the columns fit it fills the empty space, when they overflow the browser scrolls itself. The full "slide the column stack left under the fixed sidebar" motion is not done; `INSPECTOR-SLIDE-SPEC.md` at the repo root is the build spec for it, including three approaches already tried and rejected.
- Quick Look opens on Space in every view (`togglePreview`), through `keyDown` on the table and the browser and `onKeyPress(.space)` on the icon grid; the model's `PreviewPanel` handles the panel. Space or Escape inside the panel closes it, and the arrow keys move the selection behind it so the panel follows, as Finder's does.
- Sidebar: Servers, Starred, Live Files (only while active), Conflicts. Starred holds files and folders; a star's kind is learned from the server once so a starred file is revealed, never listed. Server rows offer Connect, Edit, and Remove. Remove refuses while that server has unsynced Live bytes.
- Quit asks Cancel or Quit Anyway through the app delegate whenever any server has unsynced Live work, and disconnects every master on the way out.

## Updates

Sparkle 2 is a SwiftPM dependency of the app target. `Scripts/package-app.sh` copies the framework into the bundle, adds the rpath, and signs the inner pieces before the app. `Check for Updates…` sits in the app menu. The updater starts only when `SUPublicEDKey` in `Support/Info.plist` is non-empty, so a build without a key runs quietly.

To turn updates on: run `.build/artifacts/sparkle/Sparkle/bin/generate_keys` once, which keeps the private key in the login keychain and prints the public key; paste that into `SUPublicEDKey`. Each release is a zip of the signed, notarized app plus `appcast.xml` from `bin/generate_appcast`, attached to a GitHub release. The feed URL points at the latest release's `appcast.xml`. Ad-hoc signed builds cannot install an update over themselves; that needs Developer ID via `SIGN="Developer ID Application: …" Scripts/package-app.sh`.

## Still open

- The column-view inspector slide: columns should translate left as one piece and disappear under the fixed sidebar when the inspector opens and they overflow the pane. Today the sidebar is fixed and the browser scrolls itself, so the leftmost column clips at the content pane's left edge instead of sliding under the sidebar. `INSPECTOR-SLIDE-SPEC.md` is the full spec; the likely fix is the macOS 26 `automaticallyAdjustsSafeAreaInsets` overlay plus a custom column view in place of `NSBrowser`.
- Small files do not share a data channel; every file takes a channel from the pool of seven.
- Command-Down is not bound as a second shortcut for Open.
- Only one live window can own the frame autosave name; a second window or tab does not persist its frame.
- The fast directory engine stays unwired. `PerformanceDirectoryCopy.available()` returns false.

## Traps

- With `-s`, the subsystem name is the command argument and must follow the destination: `ssh -S sock -s -- host sftp`. The other order asks the server for a subsystem named after the host and every channel dies at the handshake. `PLAN.md` §3 was corrected.
- OpenSSH's sftp-server reads `SSH_FXP_SYMLINK` as target then link, the reverse of the draft. The draft order creates a stray link in the server user's home directory.
- Unix socket paths are capped at 104 bytes and ssh appends 17 bytes while binding. The socket name is `ConnectionID.socketName`, twelve hex characters, not the full UUID.
- ssh splits a bare `-o Name=value` on spaces, and the library lives under `Application Support`. Paths go through `-S`, `-i`, or a double-quoted `-o` value. A bare value silently wrote a known-hosts file at `~/Library/Application`.
- A directory watch does not see in-place writes to a file. Live files watch the file descriptor as well, re-armed after every event because safe-saves replace the inode.
- Re-hosting a SwiftUI column (assigning `rootView` on every update) resets its safe-area and scroll-edge state and keeps the toolbar's edge line drawn. Host each column once and let it observe the model.
- `URL.resourceValues` caches per URL instance. Size and mtime for a file that changes underneath are read with `FileManager.attributesOfItem`.
- On this SDK `NSFilePromiseProvider` is an `NSPasteboardWriting` object, not an `NSItemProvider`. `RemoteItemPromise` also writes `com.example.transfer.remote-items` so a drop inside Transfer knows the remote paths.
- Do not add libssh, a tunnel, HTTP/3, or compression. The transport is `/usr/bin/ssh`.
- Do not embed rsync. A later fast copy replaces `Tools/performance-version` and must not change the browser.
