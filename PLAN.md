# Transfer — Product Specification and Development Roadmap

Status: Proposed build specification  
Target: macOS 27 and later, Apple silicon  
Working product name: **Transfer**  
Primary implementation language: Swift  
UI architecture: SwiftUI-first with narrowly scoped AppKit adapters

## 1. Executive summary

Transfer is a native macOS remote-file browser focused initially on SFTP. It is not a dual-pane Finder replacement and not a mounted remote filesystem. It gives users one clean, unmistakably Mac-native window for browsing a remote server, previewing files, opening remote files for live editing, and transferring files to or from Finder with ordinary drag and drop.

The defining behavioral distinction is between **live** files and **copies**:

- Opening a remote file directly creates a managed **live file**. Changes saved by any Mac application are automatically and safely uploaded to the server.
- Dragging or downloading a remote file to Finder creates an independent **local copy**. It has no continuing connection to the server.

The internal engineering term for a live file may be “hot,” but the user-facing term should be **Live**. The interface must always make pending uploads, conflicts, offline changes, and failures visible. The application must never silently overwrite a remotely changed file.

Transfer should feel like a capability Apple might have added to Finder: restrained, current, accessible, keyboard-friendly, and based on standard macOS controls. It should not imitate Finder with hand-drawn controls. It should use current SwiftUI components wherever they are adequate and AppKit only where macOS exposes essential behavior that SwiftUI does not.

## 2. Product thesis

### 2.1 Problem

Existing Mac file-transfer applications generally fall into one of four categories:

1. Mature and reliable but visually dated dedicated clients.
2. Dual-pane file managers that partially replace Finder and introduce their own interaction language.
3. Cross-platform tools that do not feel native to macOS.
4. Finder-mounted remote filesystems that inherit complex synchronization, caching, hydration, and File Provider edge cases.

The immediate motivating defect is that dragging a remote file from ForkLift into Finder can yield a text link instead of the file, while an internal pane-to-pane transfer succeeds. That indicates an external drag/file-promise failure. Transfer must make external drag-out a first-class, acceptance-tested behavior.

### 2.2 Opportunity

Users already have Finder for local files. A remote browser does not need its own local pane. A focused application can provide:

- Native remote navigation.
- Finder-style icon, list, column, and gallery modes.
- Reliable drag-out to Finder.
- Drag-in upload from Finder.
- Quick Look.
- Live editing with automatic upload.
- Explicit transfer state and conflict safety.
- Existing OpenSSH configuration compatibility.

### 2.3 Product statement

> Transfer is a native macOS remote-file browser that makes SFTP files feel natural: open to edit live, or drag out to make a copy.

### 2.4 Core interaction rule

> **Open means Live. Drag out means Copy.**

This rule must remain consistent across double-click, keyboard commands, context menus, drag and drop, and accessibility actions.

## 3. Goals and non-goals

### 3.1 Goals

- Feel unmistakably native on macOS 27.
- Browse SFTP servers with Finder-familiar navigation and view modes.
- Support remote-to-Finder drag as a real file, never a link or text clipping.
- Support Finder-to-remote drag as an upload.
- Open remote files in their normal applications as managed live files.
- Automatically upload completed saves, including atomic/safe-save replacements.
- Preserve data during disconnections, application termination, and crashes.
- Detect remote changes before upload and prevent silent data loss.
- Respect existing SSH identities, agents, host keys, configuration, and jump hosts wherever practical.
- Provide excellent keyboard navigation, accessibility, Voice Control, and standard Mac menus.
- Keep the remote-provider layer independent enough to add WebDAV, S3, or other backends later.

### 3.2 Non-goals for version 1

- Replacing Finder for local files.
- A permanent dual-pane interface.
- Mounting an SFTP server into Finder.
- Implementing a File Provider extension.
- Implementing a Finder Sync extension.
- Cross-platform support.
- iPhone or iPad support.
- A built-in code editor.
- A built-in terminal emulator.
- Real-time multi-user collaborative editing.
- Perfect mirroring of every Unix filesystem feature.
- A Rust or GPUI user interface.
- Supporting every remote protocol in the initial release.

### 3.3 Deferred possibilities

- Optional File Provider integration using the same backend.
- S3, WebDAV, Backblaze B2, Azure, and cloud-drive providers.
- Remote-to-remote transfers.
- Directory synchronization.
- Server bookmarks synchronized through iCloud.
- CLI companion.
- Rust transfer core shared by a CLI or non-Apple client.
- Remote search and indexing.
- Git-aware decorations.

## 4. Naming

The working name is **Transfer**. It is direct, understandable, and fits the restrained product concept, but it is generic and may be difficult to trademark, search for, or distinguish in the App Store.

Before public release, conduct naming and trademark research. Candidate names should feel like native Mac utilities, be easy to say, and avoid cute network metaphors. Until a final name is chosen:

- Use `Transfer` in documentation and UI.
- Use a reversible internal bundle namespace such as `com.example.Transfer` during prototyping.
- Do not bake the product name into database schemas or protocol identifiers.

## 5. User model: remote, live, cached, and copied

### 5.1 Remote item

A remote item exists only on the server and is represented by provider metadata. It may have cached metadata or preview data locally, but it is not a local user document.

### 5.2 Live file

A live file is a remote item opened through Transfer and backed by a managed local working copy. Transfer retains a durable mapping between the remote identity and local working URL. Saves to the local working copy are monitored and uploaded.

A live file remains live across:

- Safe-save file replacement.
- Temporary network loss.
- Closing the editor.
- Closing Transfer’s main window.
- Relaunching Transfer.
- Restarting the Mac, if pending work exists and background continuation is enabled.

### 5.3 Cached file

A cached file contains local bytes for previewing, Quick Look, or performance but is not necessarily live. Cache status and live status are orthogonal:

- A preview cache is not live.
- A live file is managed even when currently synchronized.
- “Keep Downloaded” retains bytes for offline availability but does not change remote identity.

### 5.4 Local copy

A local copy is exported to a user-selected Finder destination. It is detached from Transfer. Changes are not uploaded automatically.

The application should not add proprietary sidecars or extended attributes merely to simulate continued linkage after export. A future explicit “Link as Live File” command may opt a local file into management, but version 1 should avoid ambiguous implicit relationships.

### 5.5 Truth rule

Live status is determined by Transfer’s durable identity mapping, not by filename, bytes, or a decorative badge. The mapping includes:

- Connection/domain identifier.
- Remote stable identifier where available.
- Canonical remote path.
- Local working URL.
- Base remote version.
- Last uploaded version.
- Local content version.
- Current synchronization state.

## 6. Primary user workflows

### 6.1 Connect to a server

1. User chooses File > New Connection or clicks Add Server.
2. User selects or enters an SSH host.
3. Transfer resolves relevant OpenSSH configuration.
4. Transfer verifies the host key using familiar, explicit language.
5. Authentication uses agent, key, security key, certificate, password, or keyboard-interactive flow as supported.
6. Successful connections appear under Servers in the sidebar.
7. The starting directory is the configured path, otherwise the user’s remote home.

### 6.2 Browse

- Single-click selects.
- Double-clicking a directory navigates into it.
- Right arrow enters a selected directory; left arrow moves to the parent where appropriate.
- Back and Forward navigate location history.
- Command-Up moves to the parent.
- Command-L focuses a location field or opens “Go to Remote Folder.”
- Command-F searches or filters according to the active search mode.
- Space opens Quick Look.
- Command-I toggles the inspector.
- Command-J opens view options if implemented.

### 6.3 Open a remote file live

1. User double-clicks a remote file, presses Command-Down, presses Return according to configured behavior, or chooses Open Live.
2. Transfer downloads the current remote content into its managed Live workspace.
3. Transfer records a base version before opening the file.
4. Transfer opens the local working copy with `NSWorkspace` and the default application, or with a chosen application.
5. Transfer observes the containing directory for modifications and safe-save replacements.
6. After a completed save and a short stabilization debounce, Transfer compares the current server version with the base version.
7. If unchanged, Transfer uploads to a temporary remote name and atomically renames it into place where the server supports it.
8. Transfer updates the base version and marks the item Up to Date.
9. If the server version changed, Transfer creates a conflict and never silently overwrites either version.

### 6.4 Drag a remote file to Finder

1. User begins dragging one or more remote items.
2. Transfer initiates a native AppKit dragging session containing `NSFilePromiseProvider` instances.
3. Finder chooses the destination.
4. Transfer downloads each promised file directly to an appropriately staged destination.
5. Progress appears in Transfer and, where supported, in Finder.
6. Successful completion produces normal local files or folders.
7. The exported items are cold local copies.

Acceptance requirement: the result must never be `.textClipping`, `.webloc`, a URL string, a remote path string, or a zero-byte placeholder.

### 6.5 Drag local files into Transfer

1. User drags files or folders from Finder into the current remote directory or onto a remote folder.
2. The drop target highlights using standard macOS behavior.
3. Transfer creates an upload operation for each item.
4. Uploads use temporary remote names when feasible and rename atomically on success.
5. Conflicts invoke the standard conflict sheet with Replace, Keep Both, Skip, and Apply to All.

### 6.6 Download explicitly

Context menu and File menu provide **Download Copy…**. This uses a standard destination picker and produces a cold copy. It is equivalent in semantics to dragging into Finder.

### 6.7 Preview

- Space invokes Quick Look.
- Quick Look follows selection when the user navigates with arrow keys.
- Preview bytes are temporary cache entries, not live files.
- Large files should not be fully downloaded when a provider or file format permits a bounded preview, but ordinary SFTP may require complete download.
- An optional inspector can show preview and metadata without making preview a permanent third pane.

### 6.8 Rename, move, duplicate, and delete

- Return begins inline rename where standard for the active view.
- Remote rename should be atomic when supported.
- Moving within the same server should use remote rename rather than download/upload.
- Duplicate creates another remote item.
- Delete should use server-side trash only when a well-defined trash capability exists; otherwise show an explicit permanent-delete confirmation.
- Undo is offered only for operations Transfer can actually reverse. Never present false undo affordances.

## 7. Synchronization state model

### 7.1 User-visible states

Use restrained standard symbols and labels:

| State | Meaning |
| --- | --- |
| Remote | Metadata only; not live |
| Preparing | Downloading/opening the live working copy |
| Up to Date | Live local and remote versions match |
| Modified | A stable local change has been detected |
| Uploading | Upload in progress |
| Waiting | Queued behind another operation |
| Offline | Network unavailable; local changes preserved |
| Conflict | Remote changed since the local base version |
| Error | Operation failed and requires attention |
| Paused | Automatic synchronization paused by user |

Do not display the word `HOT` in the production interface. “Live” and “Up to Date” are clearer.

### 7.2 Suggested state transitions

```text
Remote
  -> Preparing
  -> Up to Date
  -> Modified
  -> Uploading
  -> Up to Date

Modified
  -> Offline
  -> Waiting
  -> Conflict
  -> Error

Offline
  -> Waiting when connectivity returns
  -> Uploading

Conflict
  -> Up to Date after explicit resolution
```

State transitions must be serialized per live file. Multiple rapid saves may coalesce, but the latest stable local revision must never be lost.

### 7.3 Save detection

Editors commonly perform safe save:

1. Write a temporary sibling file.
2. Flush and close it.
3. Rename or replace the original.

Therefore, do not watch only the original inode. Observe the containing directory, re-resolve the working URL after filesystem events, and debounce until size and modification metadata stabilize. Use Foundation file coordination where it provides value, but test against real applications rather than assuming uniform behavior.

Initial debounce target: 300–500 ms after the last relevant filesystem event. Large or actively growing files may require adaptive stabilization.

### 7.4 Version fingerprint

The provider should expose a version abstraction. For SFTP, use the strongest affordable combination available:

- File type.
- Size.
- Modification time with maximum available precision.
- Remote file identifier/inode if exposed and meaningful.
- Optional content hash for ambiguous or high-risk cases.

Do not hash every large remote file by default. Hash when metadata is insufficient, a conflict is suspected, or the user requests verification.

### 7.5 Conflict behavior

Before upload, compare the server’s current fingerprint to the live file’s base fingerprint.

If they differ:

- Preserve the local working copy.
- Preserve or fetch the current remote copy.
- Mark the file Conflict.
- Never overwrite automatically.
- Offer Compare, Keep Local, Keep Remote, and Keep Both.
- Require explicit confirmation for destructive resolution.
- For text files, “Compare” should open the user’s configured comparison tool or a standard diff integration rather than building an editor in version 1.

## 8. Interface specification

### 8.1 Design principles

- Use standard system components before custom components.
- Avoid custom chrome, browser-like tabs, thick activity bars, oversized lock icons, hand-drawn folders, and decorative rounded rectangles.
- Let macOS provide typography, spacing, materials, hover behavior, selection, focus rings, and reduced-motion behavior.
- Prefer semantic hierarchy over persistent labels and visual ornament.
- The application should remain visually quiet when no transfer needs attention.
- Remote files should look like files, not database records.
- Connection security should be visible but not dominate the content.

### 8.2 Window structure

The standard window contains:

1. Native unified toolbar/title area.
2. Optional collapsible server sidebar.
3. One browser content area.
4. Optional trailing inspector.
5. A transfer/status shelf that appears only when useful.

There is no permanent local pane.

### 8.3 Toolbar

Use native `ToolbarItem` controls for:

- Back and Forward.
- Current server/location title.
- View-mode picker.
- Sort/group menu where relevant.
- Share or copy URL if useful.
- Transfer activity.
- Inspector toggle.
- Search.

Avoid showing every possible action. Secondary operations belong in menus and context menus.

### 8.4 Sidebar

Use `NavigationSplitView` and `.listStyle(.sidebar)`. Suggested sections:

- Recents: recently visited remote locations and recently opened live files.
- Servers: configured connections such as `pop`, `live`, and `medlabs`.
- Saved Locations: pinned remote paths.
- Smart Groups: Live Files, Pending Uploads, Conflicts.

The sidebar is collapsible. A user with only one server should be able to hide it and work in a clean single browser.

### 8.5 View modes

Support familiar Finder-style modes:

1. **Icon view** — visual browsing using SwiftUI lazy grids or an AppKit collection view if later required for fidelity/performance.
2. **List view** — sortable metadata columns using SwiftUI `Table` initially.
3. **Column view** — true hierarchical navigation implemented with AppKit `NSBrowser` wrapped in `NSViewRepresentable`.
4. **Gallery view** — large preview with a horizontal or vertical item strip, deferred until after core modes if schedule requires.

View switching must preserve path and selection wherever possible.

### 8.6 Column view

Column view is a primary mode, not an optional experiment. It represents one browser path, not multiple independent panes.

Required behaviors:

- One successive column per selected hierarchy level.
- Automatic horizontal scrolling to reveal the newest column.
- User-resizable columns.
- Persisted column widths.
- Native row selection and keyboard navigation.
- Multiple selection in the final column.
- Right arrow enters a folder; left arrow returns focus to its parent.
- Async loading indicator in a newly opened column.
- Directory listing cache for fast backward traversal.
- Drag source and drop destination support.

`NSBrowser` is the preferred initial implementation. If visual testing shows that its current appearance materially diverges from macOS 27 Finder, retain the same public adapter and replace its internals with a custom AppKit/SwiftUI column implementation. Do not begin by recreating it.

### 8.7 List view columns

Default columns:

- Name.
- Status.
- Date Modified.
- Size.
- Kind.

Optional columns:

- Permissions.
- Owner.
- Group.
- Remote path.

Column visibility, order, widths, sort direction, and per-connection defaults should persist.

### 8.8 Inspector

Use SwiftUI `inspector` where possible. Show:

- Name and icon/thumbnail.
- Remote location.
- Kind, size, modification time.
- Permissions, owner, group when available.
- Live state and last synchronization.
- Transfer progress or error.
- Actions such as Open Live, Download Copy, Copy Remote URL, and Resolve Conflict.

### 8.9 Quick Look

Quick Look should behave like Finder:

- Space toggles it.
- It follows current selection.
- Escape closes it.
- Arrow-key selection continues to work.
- Preview caching is bounded and evictable.

Use Quick Look APIs through the smallest necessary AppKit bridge.

### 8.10 Native window tabs and multiple windows

Use macOS native window tabbing rather than custom in-content tabs. Users may open separate servers or locations in:

- Another native tab.
- Another window.

Command-T creates a new tab. Standard Window menu behavior should work.

### 8.11 Menus and keyboard commands

Provide standard macOS menus with appropriate enablement:

- File: New Connection, New Window, New Tab, Open Live, Download Copy, Upload, Close.
- Edit: Cut/Copy/Paste only where semantics are honest, Rename, Select All.
- View: view modes, sort/group, sidebar, inspector, Quick Look, hidden files, refresh.
- Go: Back, Forward, Parent, Home, Go to Remote Folder, recent locations.
- Transfer: pause/resume/cancel, retry failed, show activity.
- Window and Help: standard behaviors.

Suggested shortcuts:

| Command | Shortcut |
| --- | --- |
| Open Live | Command-Down or Command-O |
| Quick Look | Space |
| Rename | Return |
| Parent | Command-Up |
| Back/Forward | Command-[ / Command-] |
| Refresh | Command-R |
| Download Copy | Command-Shift-D |
| New Folder | Command-Shift-N |
| Toggle sidebar | Command-Control-S |
| Toggle inspector | Command-Control-I |

Validate shortcuts against current macOS conventions before release.

## 9. Technical architecture

### 9.1 High-level components

```text
TransferApp (SwiftUI lifecycle)
├── Window/UI layer
│   ├── SwiftUI toolbar/sidebar/list/icon/gallery/inspector
│   ├── NSBrowser adapter for column view
│   ├── AppKit file-promise drag adapter
│   └── Quick Look adapter
├── Browser domain
│   ├── BrowserModel
│   ├── NavigationHistory
│   ├── SelectionModel
│   └── DirectoryCache
├── Provider layer
│   ├── RemoteProvider protocol
│   └── SFTPProvider
├── Transfer engine
│   ├── Scheduler
│   ├── Progress
│   ├── Retry/cancellation
│   └── Atomic staging
├── Live-file subsystem
│   ├── LiveFileManager
│   ├── ChangeObserver
│   ├── ConflictDetector
│   └── WorkspaceManager
├── Persistence
│   ├── SQLite database
│   ├── Keychain
│   └── Preferences
└── Background continuation
    └── Login item/helper or agent, added only when required
```

### 9.2 SwiftUI/AppKit boundary

The application is SwiftUI-first. AppKit is used deliberately for capabilities without an adequate SwiftUI equivalent:

- `NSBrowser` for authentic hierarchical column view.
- `NSFilePromiseProvider` and native dragging sessions for remote-to-Finder export.
- Quick Look panel integration where necessary.
- `NSWorkspace` for opening live files and application selection.

Keep each AppKit integration behind a small SwiftUI adapter and protocol. AppKit views must not own business state; they bind to shared models.

### 9.3 Shared browser model

All view modes consume the same logical state:

```swift
@Observable
@MainActor
final class BrowserModel {
    var connectionID: ConnectionID
    var path: RemotePath
    var selection: Set<RemoteItemID>
    var viewMode: ViewMode
    var sort: SortConfiguration
    var history: NavigationHistory
    var loadingState: LoadingState
}
```

Business operations run outside the main actor. Only presentation state is main-actor isolated.

### 9.4 Remote provider protocol

Define provider-neutral operations early:

```swift
protocol RemoteProvider: Sendable {
    func connect() async throws
    func disconnect() async
    func list(_ path: RemotePath) async throws -> [RemoteItem]
    func stat(_ path: RemotePath) async throws -> RemoteItem
    func download(
        _ path: RemotePath,
        to destination: URL,
        progress: @Sendable (TransferProgress) -> Void
    ) async throws
    func upload(
        _ source: URL,
        to destination: RemotePath,
        progress: @Sendable (TransferProgress) -> Void
    ) async throws
    func createDirectory(_ path: RemotePath) async throws
    func move(_ source: RemotePath, to destination: RemotePath) async throws
    func remove(_ paths: [RemotePath]) async throws
    func setAttributes(_ attributes: RemoteAttributes, at path: RemotePath) async throws
}
```

Add capability reporting rather than assuming every backend supports every operation:

- Atomic rename.
- Resume.
- Symlinks.
- Permissions.
- Owner/group.
- Server-side copy.
- Trash.
- Checksums.
- Precise timestamps.

### 9.5 SFTP implementation decision

Do not implement SSH or SFTP from scratch.

Requirements include:

- `~/.ssh/config` compatibility.
- SSH agent support.
- Keychain/passphrase handling.
- Ed25519 and hardware/security keys where possible.
- Host-key verification and known-host persistence.
- `ProxyJump` and preferably `ProxyCommand`.
- Keyboard-interactive authentication.
- Connection reuse and keepalive.

Conduct a short implementation spike comparing:

1. A direct library implementation.
2. A controlled OpenSSH subprocess/helper architecture.
3. A Rust SFTP engine exposed through a narrow C/Swift interface.

Choose based on actual compatibility tests, not theoretical purity. Apple’s SwiftNIO SSH is a building block, not a complete production SFTP client; using it implies substantial protocol work.

Preferred v1 direction: reuse system/OpenSSH behavior when it materially improves compatibility with existing configuration. Isolate process control and parsing behind `SFTPTransport` so it can be replaced.

### 9.6 Transfer scheduler

The scheduler must support:

- Queued, active, paused, completed, failed, and canceled operations.
- Per-host and global concurrency limits.
- Progress by bytes and items.
- Cancellation.
- Retry with bounded exponential backoff for transient failures.
- Resume when supported and safe.
- Persistence of incomplete operations.
- Atomic temporary names for uploads.
- Cleanup of abandoned temporary files.
- Priority for interactive operations such as Open Live and Quick Look.

Never block UI interaction on network I/O.

### 9.7 Live workspace

Use an application-managed directory, for example:

```text
~/Library/Application Support/Transfer/Live/<connection-id>/<stable-item-id>/filename
```

Do not expose opaque IDs in the user-visible filename. Store mappings in SQLite rather than deriving remote identity solely from the path.

The workspace manager must:

- Use safe file permissions.
- Prevent different remote items from colliding.
- Preserve unsynchronized changes indefinitely unless the user explicitly discards them.
- Reconcile orphaned database records and files.
- Apply storage quotas only to disposable preview/cache data, never pending live edits.
- Support “Reveal Local Working Copy” for diagnostics.

### 9.8 Persistence

Use SQLite with migrations. Suggested entities:

- `connections`
- `saved_locations`
- `directory_cache`
- `live_files`
- `remote_versions`
- `transfers`
- `conflicts`
- `recent_locations`
- `preferences_by_connection`

Secrets do not belong in SQLite. Store passwords and private secret material in Keychain. Prefer existing keys and agents instead of copying private keys.

### 9.9 Background behavior

The first prototype may require the main application to remain running for live synchronization. Before claiming durable Live behavior, add a lightweight background component using current Apple-supported service/login-item mechanisms.

Responsibilities:

- Continue pending uploads after the last main window closes.
- Monitor live working directories.
- Restore queued work after relaunch or reboot.
- Surface notifications for conflicts and failures.

Avoid always-on background activity when there are no live or pending files. Provide a clear preference and status indicator.

## 10. File promise and drag specification

### 10.1 Why AppKit is required

A remote file does not have a local URL at drag start. Finder needs a promise that declares the eventual filename and type and supplies the bytes after Finder selects a destination. SwiftUI’s normal `Transferable` flow may stage temporary files and does not expose all required promised-file control.

Use `NSFilePromiseProvider` through a dedicated adapter.

### 10.2 Drag source requirements

- Drag starts from file icon/row, never accidentally from selectable filename text.
- Multiple selected items create multiple promises.
- Directories are supported after individual-file behavior is reliable.
- Drag image uses native file icons and multi-item badges.
- Copy cursor appears for remote-to-local drag.
- Option and Command modifiers follow truthful semantics.
- Canceling the drag does not download.
- Download starts only after promise fulfillment.
- Partial destination files are not exposed as completed files.

### 10.3 Drag destination requirements

- Accept file URLs, promised files, and standard Finder drags.
- Resolve whether the target is the current directory or a hovered subfolder.
- Spring-loaded folder navigation may be deferred, but target highlighting must be native.
- Never move/delete the local source unless the user explicitly invokes a move operation and the system semantics guarantee it.

## 11. SFTP and filesystem semantics

### 11.1 Paths and encoding

- Treat remote paths as byte-sensitive where the transport allows it.
- Do not assume Unicode normalization matches APFS.
- Display invalid byte sequences safely and preserve round-trip identity.
- Never construct shell commands through unsafe interpolation.
- Canonicalize navigation without resolving away meaningful symlinks unexpectedly.

### 11.2 Case sensitivity

Remote Linux directories may contain `README` and `readme`. Local managed storage and UI identifiers must not collapse these items. Use stable IDs and per-item storage directories rather than bare remote filenames.

### 11.3 Symlinks

- Distinguish symlink metadata from target metadata.
- Show a standard alias/symlink visual treatment.
- Avoid recursive loops during folder operations.
- Confirm whether download copies the link or dereferenced contents; default should match familiar SFTP-client behavior and be documented.

### 11.4 Permissions and resource forks

- Preserve Unix executable and permission bits when feasible.
- Do not promise full macOS metadata preservation over SFTP.
- Handle AppleDouble/resource-fork behavior deliberately for Mac-to-Mac transfers.
- Make metadata preservation rules visible in documentation and tests.

### 11.5 Large files and folders

- Stream transfers with bounded memory.
- Display determinate progress when total size is known.
- Enumerate folders incrementally.
- Allow cancellation between items and during file streams.
- Use bounded concurrency to avoid overwhelming servers.

## 12. Security and privacy

### 12.1 Authentication

- Prefer SSH agent and configured identities.
- Store passwords/passphrases only in Keychain when the user elects to save them.
- Support keyboard-interactive challenges without logging responses.
- Redact secrets from diagnostics.

### 12.2 Host verification

- Never silently accept a new or changed host key.
- Present algorithm and fingerprint in a clear native sheet.
- Distinguish first connection from changed-key danger.
- Integrate with known hosts where architecture permits.

### 12.3 Local data

- Live-file contents may be sensitive, including medical documents.
- Use restrictive permissions for live and preview workspaces.
- Exclude disposable caches from backup where appropriate.
- Do not exclude unsynchronized live edits from backup without a documented recovery strategy.
- Provide Clear Preview Cache separately from destructive live-file cleanup.
- Avoid telemetry containing paths, filenames, server names, document content, or patient information.

### 12.4 Sandboxing and distribution

Prototype outside App Store constraints if necessary to validate SSH configuration, agents, helpers, and file promises. Before choosing App Store distribution, evaluate whether sandbox restrictions compromise core compatibility. Notarized direct distribution may be the correct product choice.

## 13. Accessibility and native behavior

- Full VoiceOver labels for rows, columns, status, progress, and toolbar controls.
- Voice Control-accessible names.
- Complete keyboard operation without a mouse.
- Respect system text size, contrast, reduce transparency, and reduce motion.
- Use system accent color and selection colors.
- Expose transfer and synchronization state semantically, not only through color.
- Maintain predictable focus when changing view modes or loading directories.
- Support standard Services and Open With behavior where feasible.

## 14. Error handling

Errors must be actionable and associated with the affected item or connection.

Examples:

- Connection lost: retain queue and offer Retry.
- Authentication failed: identify authentication stage without exposing secrets.
- Permission denied: identify operation and path.
- Disk full: preserve remote state and pending local work.
- Host key changed: block connection and explain risk.
- Upload conflict: preserve both versions and enter Conflict state.
- Partial folder download: list completed and failed items.
- App crash during upload: reconcile temporary remote file on restart.

Use transient banners for recoverable informational events, sheets for decisions, and a durable activity/error view for operations requiring later attention.

## 15. Performance expectations

Initial targets for a normal broadband/LAN connection:

- Window usable within 500 ms excluding connection establishment.
- Cached directory revisit appears within 100 ms.
- Visible response to folder selection within one frame, even if content then loads.
- Directory UI remains responsive with 100,000 items through incremental loading/virtualization.
- File transfers stream with bounded memory independent of file size.
- Preview/live interactive downloads receive priority over background batch transfers.
- Main-thread stalls longer than 50 ms should be treated as defects during ordinary browsing.

Measure before optimizing. Include signposts for directory load, time-to-first-row, transfer setup, hashing, live-save detection, and upload completion.

## 16. Observability and diagnostics

Provide opt-in diagnostics suitable for support:

- Application and OS version.
- Provider/transport version.
- Connection phase and non-secret capability information.
- Transfer state transitions and error codes.
- Timing and retry information.
- Live-file state machine transitions.

Never log:

- Passwords or interactive responses.
- Private key material.
- File contents.
- Medical or other sensitive document names by default.
- Full remote paths unless the user explicitly includes them in an exported diagnostic package.

## 17. Proposed repository layout

```text
Transfer/
├── Transfer.xcodeproj
├── App/
│   ├── TransferApp.swift
│   ├── AppCommands.swift
│   └── AppState.swift
├── Features/
│   ├── Browser/
│   │   ├── BrowserModel.swift
│   │   ├── BrowserView.swift
│   │   ├── IconBrowserView.swift
│   │   ├── ListBrowserView.swift
│   │   ├── ColumnBrowserView.swift
│   │   └── GalleryBrowserView.swift
│   ├── Connections/
│   ├── Transfers/
│   ├── LiveFiles/
│   ├── Inspector/
│   └── Settings/
├── Core/
│   ├── Providers/
│   │   ├── RemoteProvider.swift
│   │   └── SFTPProvider.swift
│   ├── Transport/
│   ├── TransferEngine/
│   ├── LiveFiles/
│   ├── Persistence/
│   └── Security/
├── Platform/
│   ├── ColumnBrowser/
│   ├── FilePromises/
│   ├── QuickLook/
│   ├── Workspace/
│   └── Keychain/
├── Resources/
└── Tests/
    ├── Unit/
    ├── Integration/
    ├── UI/
    └── Fixtures/
```

Keep platform adapters small and test business logic independently of UI frameworks.

## 18. Development roadmap

### Phase 0 — Decision spikes

Purpose: retire the highest-risk unknowns before building the product shell.

Deliverables:

1. **Finder file-promise spike**
   - Hard-code one remote file or generated stream.
   - Drag it from a minimal Mac window to Desktop.
   - Confirm Finder creates the actual file.
   - Test cancellation, name collisions, multiple files, and a large file.

2. **Column-view spike**
   - Wrap `NSBrowser` in SwiftUI.
   - Load an asynchronous mock hierarchy.
   - Validate appearance on macOS 27, keyboard behavior, selection, resizing, and drag initiation.

3. **SFTP transport spike**
   - Test SSH config, agent, hardware key if available, keyboard-interactive authentication, ProxyJump, host-key handling, listing, upload, download, cancellation, and connection reuse.
   - Compare implementation options and record the decision.

4. **Live-save spike**
   - Open a managed test file in TextEdit, BBEdit/VS Code if available, Preview for supported editable formats, and an Office application if available.
   - Confirm detection of in-place writes and safe-save replacements.

Exit criteria:

- External drag produces actual files reliably.
- Column view looks acceptably native.
- A transport strategy is selected with documented limitations.
- Safe-save monitoring works for representative editors.

Estimated effort: 1–2 weeks.

### Phase 1 — Browsing MVP

Deliverables:

- SwiftUI app/window lifecycle.
- Connection model and one SFTP connection.
- Host-key verification.
- Sidebar with saved server.
- List view with Name, Modified, Size, Kind.
- Back, Forward, Parent, Home, Refresh.
- Column view using the proven adapter.
- Directory cache and asynchronous loading.
- Basic native toolbar and menus.
- Space/Quick Look for a selected file.

Exit criteria:

- User can connect and navigate a real server for an hour without UI corruption or leaked connections.
- Backward column navigation is effectively instant from cache.
- Network delay never freezes the UI.

Estimated effort: 2–3 weeks after Phase 0.

### Phase 2 — Transfers and Finder interoperability

Deliverables:

- Transfer scheduler and activity view.
- Drag remote files to Finder using file promises.
- Drag Finder files into remote folders.
- Download Copy and Upload commands.
- Progress, cancellation, retry, name conflicts.
- Temporary upload names and atomic rename.
- Folder transfers.
- Persistent incomplete-transfer records.

Exit criteria:

- Drag-out acceptance matrix passes for Desktop and Finder folders.
- No operation creates a link or text clipping.
- Canceling leaves neither false completed local files nor silent remote corruption.
- Large transfers use bounded memory.

Estimated effort: 2–4 weeks.

### Phase 3 — Live editing

Deliverables:

- Managed Live workspace.
- Persistent live-file mappings.
- Open Live/Open With.
- Directory-based save observer.
- Debounced upload.
- Base-version checking.
- Atomic remote replacement.
- Live status badges and activity.
- Offline queue.
- Conflict preservation and resolution.

Exit criteria:

- Edits from representative Mac applications upload automatically.
- Multiple rapid saves converge to the latest complete version.
- Remote concurrent modification never causes silent overwrite.
- Network loss does not lose local changes.
- Relaunch restores pending state.

Estimated effort: 3–5 weeks.

### Phase 4 — Native polish

Deliverables:

- Icon and gallery views.
- View-mode persistence.
- Inspector.
- Native window tabs and multi-window state.
- Inline rename.
- Permissions editing where supported.
- Saved remote locations and Recents.
- Refined menus and shortcuts.
- Accessibility and Voice Control pass.
- Reduced-motion/contrast testing.
- App icon, onboarding, help, and diagnostics.

Exit criteria:

- The app visually and behaviorally belongs beside Finder on macOS 27.
- Complete keyboard-only workflow passes.
- VoiceOver can connect, navigate, transfer, open live, and resolve an error.

Estimated effort: 3–5 weeks.

### Phase 5 — Background reliability and release

Deliverables:

- Background continuation for pending live changes.
- Crash/reboot recovery.
- Automatic cleanup and reconciliation.
- Signing, notarization, update mechanism, and distribution decision.
- Performance profiling and stress testing.
- Security review and privacy documentation.
- Migration/versioning strategy.
- Beta feedback and compatibility fixes.

Exit criteria:

- No known path to loss of a saved local live edit.
- Pending work survives forced termination and restart.
- Host-key and credential behavior passes security review.
- Release build is signed, notarized, and updateable.

Estimated effort: 3–6 weeks.

### Overall estimate

- Convincing prototype: 2–4 weeks.
- Strong personal daily-use application: approximately 8–12 weeks.
- Polished public release: approximately 4–6 months depending on transport complexity, background requirements, and beta findings.

These estimates assume one experienced developer/AI-assisted development stream and should be revised after Phase 0.

## 19. Testing strategy

### 19.1 Unit tests

- Remote path parsing and normalization.
- Filename encoding and normalization.
- Version comparison.
- Live-file state transitions.
- Conflict decisions.
- Retry classification.
- Transfer scheduling and cancellation.
- Cache eviction excluding unsynchronized work.
- Database migrations.

### 19.2 Integration test server

Maintain a disposable SFTP test environment with fixtures for:

- Password, key, agent, and keyboard-interactive authentication.
- Proxy/jump host.
- Permission-denied directories.
- Symlinks and symlink loops.
- Case-distinct filenames.
- Unicode normalization differences.
- Invalid filename bytes if supported.
- Huge sparse files.
- Many small files.
- Slow and interrupted connections.
- Remote concurrent modifications.
- Full disk/quota errors.

### 19.3 UI tests

- Connection and host verification.
- Navigation in every view mode.
- Switching views while preserving path/selection.
- Keyboard-only navigation.
- Sidebar show/hide.
- Quick Look behavior.
- Inline rename.
- Transfer conflict sheets.
- Live-state indicators.
- Error recovery.

### 19.4 Drag acceptance matrix

Test remote drag-out to:

- Desktop.
- Finder window in list, icon, and column view.
- Finder sidebar folder if supported.
- Mail compose window.
- Messages compose window.
- An application accepting file URLs.
- Trash only if semantics are explicitly supported.

For each target test:

- One file.
- Multiple files.
- Folder.
- Empty file.
- Large file.
- Unicode filename.
- Existing-name conflict.
- Canceled drag or canceled transfer.

### 19.5 Live-edit application matrix

Test at minimum:

- TextEdit.
- Preview where editable content applies.
- Xcode.
- Visual Studio Code or another common editor.
- BBEdit if available.
- Microsoft Word/Excel if available.
- An application known to save atomically by replacement.

Verify open, save, repeated save, Save As, app crash, file rename, local deletion, remote concurrent change, and offline save.

## 20. Acceptance criteria for version 1

Version 1 is acceptable when all of the following are true:

1. The app runs only on supported Apple-silicon macOS 27 systems and looks native without custom imitation chrome.
2. Users can configure and connect to representative SFTP servers securely.
3. List and column navigation are complete and keyboard accessible.
4. Icon mode is available or explicitly deferred with no misleading control.
5. Space provides useful Quick Look behavior.
6. Dragging a remote file to Desktop or Finder always creates the actual file.
7. Dragging a local file into the browser uploads it to the intended directory.
8. Double-click/Open Live creates a managed working copy and opens the default app.
9. Completed saves upload automatically.
10. Safe-save replacement is detected.
11. Offline saves remain pending without loss.
12. Concurrent remote changes produce a conflict rather than silent overwrite.
13. Transfer progress, cancellation, retry, and failure are visible.
14. No secret or sensitive filename/content is included in default diagnostics or telemetry.
15. Pending live work survives relaunch, and release readiness requires survival across forced termination/reboot.
16. Core workflows work with keyboard, VoiceOver, and Voice Control.

## 21. Product decisions already made

The following decisions should be treated as settled unless implementation evidence forces reconsideration:

- macOS 27+, Apple silicon only.
- Native Swift application.
- SwiftUI-first UI.
- Selective AppKit adapters are preferred over forcing pure SwiftUI.
- Single remote browser window, not permanent dual panes.
- Finder remains the local-file manager.
- No File Provider/Finder mount in version 1.
- Finder-style view switching is important.
- Column view is required and should begin with `NSBrowser`.
- Remote-to-Finder drag must use native file promises.
- Open means Live; drag/download means detached Copy.
- User-facing term is Live, not Hot.
- Conflicts must never silently overwrite remote or local work.
- Visual design uses standard Apple components with minimal overrides.
- AppKit does not imply an old appearance; custom styling should be the exception.
- GPUI is not the right UI foundation for this Mac-only product.
- Rust may be considered later for a shared transfer core, not as an initial requirement.

## 22. Open decisions requiring spikes or product choice

1. Final product name and bundle identity.
2. Direct notarized distribution versus Mac App Store.
3. Exact SFTP transport/library architecture.
4. Whether a background helper ships in the first public version or the main app remains running while Live files exist.
5. Whether Return renames or opens; default should follow current Finder behavior.
6. Exact delete/trash semantics for generic SFTP servers.
7. Whether Gallery view is version 1 or a subsequent release.
8. Whether hidden files are off by default and how the toggle persists.
9. How much OpenSSH configuration can be honored under the selected distribution/security model.
10. Whether remote directory polling is automatic, manual, or adaptive while Live files are open.
11. Default live-file retention policy after editors close.
12. Licensing and pricing if released publicly.

## 23. Guidance for the implementing AI

1. Begin with Phase 0 spikes. Do not build an elaborate UI before proving file promises, column view, SFTP compatibility, and save monitoring.
2. Prefer first-party Apple APIs and current platform conventions.
3. Do not recreate a standard control for styling reasons.
4. Keep all network and filesystem work off the main actor.
5. Make cancellation and failure explicit in every asynchronous operation.
6. Treat remote data and unsynchronized live edits as irreplaceable.
7. Write tests for state machines before connecting them to UI.
8. Never shell-interpolate remote paths, filenames, usernames, or credentials.
9. Preserve existing user SSH configuration when safely possible.
10. Add signposts and structured errors early.
11. Test with actual Finder and actual editing applications; mocks are insufficient for drag and safe-save correctness.
12. Keep AppKit adapters narrow and driven by shared domain state.
13. If a design choice starts making the application look like a custom cross-platform file manager, return to the standard macOS component.
14. Do not add dual-pane behavior unless future user evidence demonstrates a need.
15. Update this specification whenever an open decision is resolved or an implementation constraint changes product behavior.

## 24. First concrete implementation task

Create a minimal signed macOS 27 Swift project named Transfer containing:

- A SwiftUI window with a native toolbar.
- A mock remote hierarchy.
- A view-mode control for List and Columns.
- A SwiftUI `Table` list presentation.
- An `NSBrowser` column presentation through `NSViewRepresentable`.
- Shared path and selection state.
- A draggable mock remote file exported through `NSFilePromiseProvider`.
- Automated tests for view-state preservation.
- A manual acceptance script confirming that dragging the mock item to Desktop creates a real file with expected bytes.

Do not add real SFTP until that shell proves the native browsing and external-drag architecture.

