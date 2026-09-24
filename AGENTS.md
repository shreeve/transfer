# Agent rules

Transfer is a native Mac SFTP browser that feels like a small utility Apple shipped next to Finder: browse a server, preview files, open editable files Live so every completed save uploads, and copy, drag and paste between servers and the Finder. It rides the Mac's own `/usr/bin/ssh`, so `~/.ssh/config`, the agent and `ProxyJump` just work, and it shares one login per server across windows. It targets macOS 27 on Apple silicon only. It never loses or silently overwrites a user's data, local or remote; every rule below serves that or the native feel.

`docs/SPEC.md` is what the product does. `HANDOFF.md` is how the code does it, with the Traps: read it before changing the window, the SSH session, Live files, or transfers.

## Shape

- `TransferCore`: values and decisions. No SwiftUI, AppKit, `Process`, or `FileManager`.
- `TransferIO`: `/usr/bin/ssh`, SFTP, SQLite, Keychain, Live files, the transfer engine. No SwiftUI or AppKit.
- `TransferUI`: views and AppKit adapters. No `TransferIO`. It writes and removes no file except the clipboard's staging folders; everything else goes through `RemoteSession` or `SessionProvider`.
- `Transfer`: `@main`, the only target that imports both UI and IO.

A rule with a decision in it belongs in Core, with a test.

## Rules

- The transport is `/usr/bin/ssh`: no libssh, no SSH stack of our own, no tunnel, no compression, and no rsync. Passengers are `ssh -S sock -s -- <host> sftp`. A faster copy, if one comes, must not change the browser.
- Every `ssh` command line puts `--` before the destination: a user or host from an `sftp://` link comes from another app, and one starting with `-` would be an option such as `-oProxyCommand`. Processes start with an argument vector, never through a shell; the one command typed into a shell, Open in Terminal's, quotes every field and is refused when any holds a control character.
- A server is untrusted. Every name it sends that reaches the Mac's disk goes through `LocalPlacement` (`child`, `occupant`, `makeFolder`, `makeLink`): one path component, read with `lstat`, never followed through a local link, never removed without the user's answer.
- A name collision is asked through the operation's own prompt, `OperationPrompts.current`, never the login's sheet. With nobody to ask, the operation fails; it never guesses Skip or Replace. A rename the user asks for never replaces anything.
- Moves and pastes run only through `SessionProvider.transfer` (`TransferEngine` in TransferIO, tested in `MoveServerTests`); TransferUI only queues a `TransferRequest`. A move removes an original only when `MoveCheck` finds this move wrote a complete copy of it.
- Live files belong to `LiveSync`. Only its per-server worker changes a Live file's sync state; anything else (a conflict choice, discard, a rename or delete under a Live path) is a command on that worker. What a pass does is `LiveDecision` in TransferCore: change the rules there, with a test. Never write the working copy behind an open editor, and never rename it. A Live open rides the interactive lane as `.open`, which a preview never drops.
- Every AppKit callback that takes a row or column (`NSBrowser`, `NSTableView`, a menu's `clickedRow`, a drop's −1) checks it against the listing that view was loaded with before using it. An Objective-C exception must never escape an `updateNSView` or a layout pass: AppKit catches it, and the Observation crash that follows lands somewhere else.
- Keys the content pane handles go through one local key monitor each: Command-Down and Space in `ContentKeys`, Escape in `Clipboard`. Copy and Paste reach the window through the responder chain, with the app delegate as the fallback (`KeyWindowEdit`). Do not add per-view key handlers.
- Drags start in the AppKit views (`IconItemView`, `ListTable`, `TiledBrowser`) with `NSFilePromiseProvider`. A drop honors remote paths only from a drag this process started (`dropAction(for:onto:model:)`).
- Finder pastes only file URLs: copied items are staged and their URLs added when complete. No file promise or lazy URL on the general pasteboard.
- `transfer.sqlite` and `config.json` change only with an automatic forward migration (a step in `Store.migrate`, `Store.schemaVersion` raised) and a `StoreTests` case that opens a 0.1.7 library.
- The Traps in `HANDOFF.md` were measured on macOS 27 and stay unless something proven better replaces them: the `-s` argument order, OpenSSH's SYMLINK order, the 104-byte socket path (`ConnectionID.socketName`), `-o` quoting, FSEvents timing, `.useConstraints`, `NSScrollPocket`, safe-area pinning, `NSBrowser` width and `validateDrop` for column −1, hosting each column once, frame autosave names, and `handlesExternalEvents`.
- Fix a bug with a test in the lowest layer that can host it (Core, then IO without a server, then the server suites). Never weaken a test to make it pass.

## Check

```bash
swift build          # no warnings
swift test           # the server suites report skipped
```

Server tests need the local, unprivileged `sshd` (never a real server). Pass a free port when other sessions run tests too, and build in your own `--scratch-path`:

```bash
eval "$(Scripts/local-sshd.sh 2222)" && TRANSFER_REQUIRE_SERVER=1 swift test; kill $TRANSFER_TEST_SSHD
```

`TRANSFER_REQUIRE_SERVER=1` makes a missing server fail every server test instead of skipping it. Run the server suites after any change to IO behavior.

`Scripts/package-app.sh` builds `Transfer.app` and prints its path. Launch a development build only with its own library:

```bash
open --env TRANSFER_LIBRARY=/tmp/transfer-dev "$(Scripts/package-app.sh)"
```

Without `TRANSFER_LIBRARY` it uses the real library in `~/Library/Application Support/Transfer`: it removes the installed app's login scratch and starts Live sync on the user's own records. `TRANSFER_ANIMATION_SCALE=6` stretches the sidebar and inspector animations for watching them.
