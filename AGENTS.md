# Agent rules

Read `HANDOFF.md` before changing the window or the SSH session. Read `PLAN.md` for product behavior. When the window chrome in `HANDOFF.md` disagrees with the opening lines of `PLAN.md`, follow `HANDOFF.md`.

## Shape

- `TransferCore`: values and decisions. No SwiftUI, AppKit, `Process`, or `FileManager`.
- `TransferIO`: `/usr/bin/ssh`, SFTP packets, SQLite, Keychain. No SwiftUI or AppKit.
- `TransferUI`: views and AppKit adapters. No `TransferIO`.
- `Transfer`: `@main` only. The only target that imports both UI and IO.

Views talk to a `RemoteSession`. `SSHConnection` is the implementation. Do not put a socket, a process, or a file write in a view.

## Do not reopen these

- The transport is `/usr/bin/ssh`. No libssh, no custom SSH stack, no HTTP/3, no tunnel, no compression. Passengers are `ssh -S sock -s -- <host> sftp`.
- Do not embed rsync. A fast copy, when it exists, must not change the browser.
- The window frame is AppKit (`WindowChrome.swift`): `NSSplitViewController`, `NSToolbar`, content pane spanning the window, sidebar and inspector as safe-area insets, columns pinned to `safeAreaLayoutGuide`, collapse behavior `.useConstraints`, title-bar separator forced to `.none`. Do not move that frame back to SwiftUI.
- Hide `NSScrollPocket` views over the content. Leave the sidebar’s pocket. Draw the toolbar line with `hoverLine`, and read the pointer on each refresh.
- Host each SwiftUI column once. Do not assign `rootView` on every update.
- `NSBrowser` must be at least as wide as its columns (`ColumnStack`). Do not try to scroll it from outside.
- In column view, `validateDrop` returns no operation for column −1 when the pasteboard has `remoteDragType`. Any other answer cancels the browser’s own drag.
- `NSFilePromiseProvider` is not an `NSItemProvider`. Drags start in the AppKit views (`PromiseText`, `IconItemView`, `ListTable`, `TiledBrowser`).
- Finder pastes only file URLs. Copied items are staged in the caches folder and their URLs added when complete. Do not put a file promise or a lazy URL on the general pasteboard for Finder.
- A move removes a source only after `MoveCheck` finds that this move wrote a complete copy: an entry the destination held before the move began counts only when the user replaced it (in a move a lookalike is asked about, never skipped), and a file needs an equal size and a known, equal time. Finder originals go to the Trash. The move and paste engine is `TransferEngine` in TransferIO, reached through `SessionProvider.transfer` and tested in `MoveServerTests`; TransferUI only queues it.
- Copy and Paste reach the window through the responder chain, with the app delegate as the fallback (`KeyWindowEdit`). Escape for the clipboard is one key monitor in `Clipboard`. Do not add per-view Escape handlers.
- Live files belong to `LiveSync`. Only its per-server worker changes a Live file's sync state; anything else (a conflict choice, discard, a rename or delete under a Live path) is a command on that worker. What a pass does is `LiveDecision` in TransferCore; change the rules there, with a test. Never write the working copy behind an open editor, and never rename it: a remote rename changes only the record's path. A Live open rides the interactive lane as `.open`, which a preview never drops.
- Never let an Objective-C exception escape an `updateNSView` or a layout pass. AppKit catches it, and the Observation crash that follows lands somewhere else. Check `NSBrowser` column indices against `lastColumn` on every use.
- Socket names use `ConnectionID.socketName` (12 hex digits). SSH option paths that contain spaces go through `-S`, `-i`, or a quoted `-o` value.
- Every `ssh` command line puts `--` before the destination. A user or host from an `sftp://` link comes from another app, and without `--` one starting with `-` is an ssh option such as `-oProxyCommand`.
- `SSH_FXP_SYMLINK` on OpenSSH is target, then link.

## Check

```bash
swift test
```

Server tests, only when the behavior under test needs a real `sshd`:

```bash
eval "$(Scripts/local-sshd.sh)" && swift test; kill $TRANSFER_TEST_SSHD
```

Package with `Scripts/package-app.sh`. To watch sidebar and inspector animation, launch with `TRANSFER_ANIMATION_SCALE=6`.
