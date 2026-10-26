# Changelog

What changed in each release of Transfer. `Scripts/release.sh <version>` publishes that version's section as the GitHub release notes and as the notes Sparkle shows in the update dialog, and refuses to release a version that has no section here. Changes not yet released collect under Unreleased, whose heading becomes the version's when it ships.

## 2.0.0 — 2026-10-26

The inspector becomes a preview panel, Live files are easy to see and to stop, downloads of many small files get two to four times faster, and copies between servers about twice as fast. Many more source and config files preview and open Live as text, and Quick Look extensions you have installed draw previews, as in Finder. The library upgrades itself once: Transfer 0.2.0 to 0.3.1 cannot open it afterwards (0.1.7 still can).

### Preview panel

- The inspector is now a preview panel with a steady layout: one line at the top with the file's icon, its name in bold, and its size, date, time, and permissions (fewer when the panel is narrow, the size always), plus a small symbol for a link, a Live file, or a transfer; the kind, owner and group, and the rest are in the line's tooltip. The preview fills everything below it. A picture is scaled to fit and centered, and text and Quick Look fill the space. Nothing moves as the selection changes; a file that is loading or cannot be previewed shows its icon in the same place, and a missing detail reads "—".
- Arrowing between files no longer flickers the preview, and the first text or Quick Look preview no longer flashes an empty box: the previous preview, of any kind, or the icon stays up until the next one has drawn (for up to half a second, then the file's icon shows), and text, pictures, and Quick Look previews change in place.
- Text and code preview on a white page (near-black in dark mode) with a thin border, like a document, instead of on gray; keywords, strings, and comments take their dark-mode colors in dark mode.
- Selecting several items shows how many ("3 items selected · 1 folder") and their files' total, as `77,933,067 ( 78MB)`, and lists them, one row each in the browser's order, with size, permissions, owner and group, and date and time.
- The panel previews any file up to 10 MB (was 8 MB) through Quick Look, so the Quick Look extensions you have installed draw it, as in Finder; text still shows its first 64 KB at any size. Files on either side of the selection are fetched ahead only when Quick Look can draw them without an extension, so arrowing past archives and programs never downloads them.
- A file of a type the Mac doesn't know, or with no extension (`README`, `LICENSE`), previews as highlighted text in the panel and in Quick Look when its first 64 KB are UTF-8 text; otherwise the panel shows its icon. Only the first 64 KB are downloaded to find out.
- Pictures are drawn by Quick Look's thumbnailer, in its own sandboxed process, at the size they show, instead of being decoded inside Transfer, which holds your Keychain access and SSH agent.
- An Inspector button beside Transfers in the toolbar shows and hides the panel, as View → Show Inspector (Command-I) does. The panel stays open or closed as you left it, in new windows and after relaunching, and opens at the width it last had.
- The panel can be widened to 60% of the window's width (at least 240 points; was 320), and a window made narrower pulls a too-wide panel in; the content pane keeps its 260 points.

### Live files

- Live is easy to see and easy to turn off. While any file is open Live, on any server, a red "LIVE" capsule sits in the toolbar ("LIVE 4" for four); click it for every Live file with its server and state, each with Stop, and Stop All or Stop Selected. A Live file's icon has a small red dot in every view (with "!" for a conflict), and the panel's header shows a small "LIVE" capsule that stops it, or "CONFLICT", which opens the conflict sheet. File → Discard Live File is now Stop Live Editing; stopping a file that holds edits the server doesn't have asks once, naming those files, with Cancel the default, and Cancel stops nothing.
- A Live file changed on the server while you have it open is flagged within about a minute, instead of only at your next save: its Live Files row and the panel say "Changed on the server", and the message bar says it once. Your copy is never touched: your next save asks which to keep, as before, and opening an unedited file again takes the new version. A file with edits not yet uploaded becomes a conflict at once. A file removed from the server is flagged as removed and kept.
- Many more source and config files open Live and preview as text: Zig, Go, Ruby, Java, Kotlin (and `.kts`), Lua, SQL, C and C++ and their headers, Objective-C, C#, PHP, Perl, R, Scala, Elixir, Erlang, Haskell, OCaml, Nim, Verilog/V, Dart, Gradle, CMake, `.mk`, Vue, Svelte, GraphQL, Terraform and HCL, `.ini`, `.conf`, `.cfg`, `.env`, `Makefile`, `Dockerfile`, `Gemfile`, `Rakefile`, `Justfile`, `.gitignore`, `.gitattributes`, `.dockerignore`, and `.editorconfig`. macOS has no type for many of these, so they showed only an icon and opened View. Your list in Settings → Extensions gets the new entries once, after your own, which keep their order; one you remove afterwards stays removed. `.mts` is left out because the Mac reads it as video. Whether a file opens Live still depends only on its name.

### Browsing

- View → Show Path Bar (Option-Command-P) shows a path bar at the foot of the window, as in Finder: the server, each folder down to where you are, and the selected item. Click a folder in it to go there (Back returns), or drop files onto one to copy or move them into it. It stays shown or hidden as you left it.
- Back and Forward are dimmed, in the toolbar and in the Go menu, when there is nowhere to go, also in a window showing no server, and light up as you browse.
- Sizes read compact everywhere, in the list's Size column, the panel, the clipboard bar, and the shelf: ` 22 B`, `6.1kB`, ` 78MB`, `1.2GB`, with no space before the unit (0.3.1's "6.4 GB" had one), so sizes in a column line up. Speeds read the same: `1.2MB/s`.
- Quick Look: Space while a preview is still loading cancels it, a file over 256 MB is not downloaded for it (the message bar says it is too large and suggests Download Copy), and a folder is no longer fetched.
- Dragging from a background Transfer window (icon and list view) no longer brings it over the window you drop on, whether a Finder window or another Transfer window; a plain click still selects and brings the window forward.

### Transfers and speed

- A running transfer on the shelf shows its speed and time left, as Finder words them: " 12MB/s · about 2 minutes left". The speed averages the last five seconds, so it holds steady; a transfer that receives nothing for five seconds reads Stalled. The panel shows the same. Download Copy's row has a bar and a time left too: a file's size is known at once, and a folder's once its files are counted, which happens while it comes down.
- Downloading a folder of many small files over a distant link is two to four times faster. Transfer still lists and checks every name over SFTP, then, when at least 150 small files (32 KB or less) are to come, has the server's own `tar` send their bytes in a few streams over the same login, and places each file as before: a hidden temp renamed into place, quarantined, with the server's mode and time. At 20 ms of latency, 2,000 small files in ten folders come down in 0.42 s (was 1.14 s), and 500 files of 16 KB in 0.25 s (was 0.39 s); at 80 ms, 2,000 files in 0.93 s (was 3.7 s); with no latency, 0.27 s (was 0.42 s). GNU tar, as Linux servers have, and the BSD tar of Macs both work. Nothing is installed on the server. A smaller folder, a server without `tar`, or one whose shell prints text when it starts gets SFTP as before, and any file a stream does not deliver whole and unchanged comes over SFTP, as does every file of a stream that reports a read error or falls silent for a minute. Uploads and pastes between servers are unchanged.
- Folder listings end a round trip sooner, and walking a folder tree, as a folder download, a move's check, a paste between servers, and the clipboard's count do, lists several folders at once: 2,000 files in ten folders walk in 225 ms at 20 ms of latency (was 761 ms), and 200 files of 64 KB in four folders come down in about 0.25 s (was 0.37 s).
- Pasting or dragging between two servers is faster: files come down from one while earlier ones go up to the other, instead of each item coming down whole first, and the items of one paste no longer wait for each other. At 20 ms of latency, 2,000 small files in a folder copy in 1.6 s (was 3.1 s) and 50 files of 8 MB in 1.6 s (was 2.7 s; pasted as 50 separate items, 1.5 s, was 15 s); with no latency, 0.87 s (was 1.0 s) and 0.3 s (was 0.37 s). At most 256 MB waits on the Mac at once, however large the paste; a single file larger than that, or a paste of one large file, still comes down whole before it goes up (512 MB: 3.3 s at 20 ms, as before). The row counts each byte twice, once down and once up, as before, so its speed is the two halves together; it now counts each file once, not twice.

### Behavior changes

- Between servers, a question about a name already taken at the destination may now come while earlier files are still copying, and it comes before the file is downloaded; Skip, Keep Both, Replace, and Apply to All answer as before. A name that something else takes at the destination while the file is on its way fails that file, and both are kept, instead of being asked about.
- Replace replaces only what you were asked about: if something else has taken the name by the time the file is ready to go in, that file fails and what is there stays, on every paste and upload.
- A folder holding names this Mac's disk cannot tell apart (`README` and `readme`), or names that are not UTF-8, is no longer refused between servers: no name reaches the Mac's disk on the way. Copying such a folder to the Finder still refuses it.

### Fixes

- A retry after a dropped connection no longer downloads again what had already landed, and its row, like any paste's, counts what was already there, so it reaches its total.
- Closing a window while its inspector was still closing no longer leaves every later window unable to show the inspector.
- A window whose saved split had the inspector open while the preference said closed (or the reverse) stopped following the model: the toolbar's view switcher and inspector toggle did nothing. The saved split is now brought to the preference's state before the window sets up.
- The inspector no longer comes back at its narrowest after a window closed with it hidden.

### The library

- The library's format changes once, automatically, to add the new source and config types to your Settings → Extensions list. Transfer 0.2.0 to 0.3.1 cannot open the library afterwards; 0.1.7 still can.

## 0.3.1 — 2026-09-27

- In column view, Command-click and Shift-click select several folders in a column, as in Finder, so they can be copied, dragged, or deleted together; no column opens beside them.

## 0.3.0 — 2026-09-26

A second pass over the whole app. It closes a way for a server's script to run on a double-click and a way for a `ProxyJump` host to get a saved password, fixes rare ways to lose an edit or an original, and changes a few behaviors (listed below). The library's format does not change: 0.2.0 and 0.1.7 still open it.

### Data safety

- A move no longer removes an original when a file that looks like its copy reached the destination during the copy and you chose Skip: a file counts as the copy only where this move wrote it.
- A Live save made while a move between servers is copying keeps the original, including a save whose reply was lost.
- A Live upload no longer makes a document-based editor, such as TextEdit, save text you had not saved yet and upload it.
- A Live save no longer replaces another writer's file that happens to have the edit's size and modification second; that is a conflict. An edit refused because the server's file changed can no longer be marked synced later without having uploaded.
- Reopening a Live file that an editor re-saved unchanged picks up the server's newer version, instead of leaving you to edit old bytes into a conflict.
- Live files survive a moved or restored library folder: unsynced edits are no longer forgotten, and a damaged record can never delete anything outside Transfer's Live folder.
- A file a replace set aside, including one Transfer 0.2.0 set aside, is never deleted if you go back to Transfer 0.1.7.
- A folder listing no longer stops at a page holding only names Transfer drops (such as `.` and `..`), so a folder copy no longer reports success with files missing.
- A file shortened on the server while it downloads is read again instead of being saved short.
- Moving a folder onto a folder of the same name that is the folder itself, reached another way (a bind mount, or one network share at two paths), is refused instead of copying it onto itself and removing the only copy.
- Pasting a Mac folder into a folder inside itself, through a server that reaches this Mac's disk, is refused instead of copying itself about a hundred levels deep.

### Security

- A `.command` or script opened Live no longer runs in Terminal without Gatekeeper's check: Live copies are quarantined like every other download, and a file whose default app would run it opens in the text editor (see Behavior changes). A Live `.command` or `.tool`, which Gatekeeper lets no app open while quarantined, is instead written without the execute bit.
- A saved password answers only the prompt ssh itself writes for that server, so a `ProxyJump` host can no longer get it by asking for it by name.
- A password typed into a login sheet that was withdrawn, and its Save in Keychain, no longer fill in the next login sheet, which could be another server's.
- A server that lists wrong or missing sizes can no longer fill the disk: copying for the Finder stops staging at 1 GB actually received, and the inspector previews a file only up to 8 MB whatever its listing said. A huge listed size no longer crashes a copy or a drag to the Finder.
- The launch removes a leftover download temp only when it is a file with a temp's name, so a copied or edited library cannot make it delete a folder. Copies passing through this Mac, between servers or on a server without `copy-data`, go through a folder in Transfer's caches that each launch empties, instead of `$TMPDIR`.
- A name holding a slash followed by a combining accent is refused as a file name, as any name with a slash is.
- `xfer` shows C1 control characters in a file name as `?`, as it does other control characters, so a crafted name cannot drive the terminal.

### Logins and reliability

- A window that moves away or closes during a login no longer stops it for another window waiting on the same server; that window is asked instead.
- After a server is edited or removed, windows, queued transfers, and pastes from it use its current settings: the old login can no longer start again and end the new one. Saving a server without changes no longer cancels a login in progress.
- Clicking a star, Live file, or conflict while the window logs in to another server no longer cancels that login.
- The title names the server as soon as its login lands, and a Live conflict found during the login still gets its sheet.
- Choosing Trust after leaving a host-key question up for a long time no longer fails the login with a timeout, and Cancel during the host-key check ends the login in about a second, not two.
- A connection that drops at the very end of a login is retried instead of failing.
- Browsing quickly no longer leaks the server's folder and file handles until it stops listing folders.
- Retrying a move on one server after the connection dropped or timed out during a rename no longer fails on an item that had already moved, and the timeout ends the move instead of starting a copy.
- An item a move kept because it changed during the move says to move it again: Retry keeps it again.
- One file that changes on the server during a folder copy fails alone and is retried, instead of restarting the whole copy.
- A library file whose version is damaged is refused with a message instead of crashing Transfer at every launch, and a saved server with a damaged id no longer shows up as one that cannot be edited or removed.
- Right-clicking a folder that is not selected in column view opens its menu, instead of failing and leaving the view out of step. The right-click menu's Quick Look and Rename act on the item clicked, and Open Live works on a link to a file.
- Escape in the search field gives the keyboard back to the files, and Command-F with the search item in the toolbar's overflow no longer turns off Return and Space. Clicking back into a search field that holds text keeps Space, Return, and Command-Delete in the field instead of acting on the files.
- Finder's Stop always stops a drag's download.
- Choosing Keep Local again after its upload's reply was lost clears the conflict, instead of raising it again over your own bytes.
- Retry on a Live conflict's row keeps the conflict on the shelf, and two refused Live discards each ask in turn.
- An Extensions edit made just before closing Settings is saved.
- View → Clear Preview Cache works in a window with no server open.
- Go to Remote Folder refuses a path holding a control character, instead of sending a NUL that ended the server's SFTP channel.
- A server's error message shows as one short line, and a failed case-only rename shows the real reason.
- The inspector names a transfer's state as the shelf does.

### Performance

- A preview, a view, or a Live open no longer waits behind a folder copy.
- Copies return to full speed about 10 s after the server refused an extra channel (for example, while a Terminal tab was open), instead of staying slow to the end.
- Select All in a large folder followed by a filter keystroke no longer stalls the window.
- An editor slow to answer no longer stalls Live sync for every server.
- Quick Look no longer fetches a large UTF-8 text file whole when its first 512 KB end inside a character.

### Behavior changes

- Every download is quarantined, Live working copies included, so macOS checks an app or script from a server before it first runs. A Live `.command` or `.tool` is the exception, as macOS would let no editor open it; it is written private and not executable instead.
- A file whose default app would run it (Terminal, iTerm2, Ghostty, Python Launcher, or Jar Launcher) opens in the default text editor instead, whether opened Live or to view. Choosing such an app when Transfer asks which app opens a type no longer makes it the Mac's default for that type.
- Copies opened to view or preview are read-only, so an editor says the file is locked instead of saving edits that never upload and are later overwritten.
- A move on one server onto a name the destination already holds asks Replace, Keep Both, or Skip, instead of failing.
- Saved servers are listed in Finder's order.
- In icon view, Shift-click adds or removes an item, and clicking one of several selected items selects just that one, as in Finder. In list and icon view, once a folder has listed, the selection keeps only the items shown, so a filter never leaves items selected out of sight.
- A click or drag on an item in a background window selects or drags it at once, as in Finder, instead of only bringing the window forward.
- Rename selects a file's name up to its extension, as Finder does; a folder's whole name stays selected.
- A folder's shortcut menu no longer offers Open Live or Quick Look.
- The inspector shows the time in the Mac's own clock format, for example 24-hour; the date stays year-month-day.
- Command-Delete in the filter or rename field edits the text instead of offering to delete files.
- Open in Terminal says why when it does nothing.
- Compare is offered for a Live conflict only up to 16 MB, so a huge file is no longer read whole.
- Downloaded files take the server's permissions under your umask, as `sftp get` does.
- `config.json` is written from the built-in defaults on first launch; the app no longer bundles a copy.

### For maintainers

- A `TransferUITests` target drives the real window model against fake sessions and a fake library; `swift test` runs it without a server.
- With the local sshd, the full test run takes about 18 s instead of about 75: `EditorMatrix`, `MoveServerTests`, and `ThroughputServerTests` run their cases in parallel.
- A file a replace set aside is recorded in the `temps` table under the owner `<uuid> aside`, which 0.1.7 and 0.2.0 never select; records 0.2.0 wrote are still read. There is no schema change.

## 0.2.0 — 2026-09-24

A revamp of the whole app. Transfer looks much the same, but what it does with your files is safer, logins are sturdier, copies are much faster, and a few behaviors change (listed below). The library upgrades itself on first launch.

### Data safety

- A move removes an original only once it has checked that this move wrote a complete copy. A file of the same name, size, and time already at the destination no longer passes for the copy: it is asked about, and an original the user did not replace it with stays. Two saved servers that reach one disk, or a destination that is the originals' own folder reached another way, never copy an item onto itself and delete it. A folder holding a socket or FIFO, which no copy can write, keeps its original. Two items of one move with the same name (`p/VERSION` and `q/VERSION`) never count each other's copy. Between servers a move removes only what it checked: anything added to the original or changed after the check stays and is named, and so does an original whose Live file saved during the move.
- Live files never lose edits the server lacks: a delete or move of a folder above one, Discard, Forget Synced Live Files, a conflict choice, and Remove Server all leave unsynced bytes alone unless you confirm. Delete discards only the edits its sheet named, and only after the server's delete succeeded. Keep Local and Keep Both wait until the working copy holds still, Keep Remote or Keep Both never overwrite a save made after the choice, and Keep Remote on a file removed from the server since keeps both copies. A save by someone else with the same size and second is no longer taken for your own upload, which left your edit marked synced and never uploaded.
- A server's names can no longer reach outside the folder you chose: a name that is not one path component is dropped from listings, and a link on the Mac is never followed or removed while downloading. A server link that met a local folder of the same name used to delete that folder.
- A change of case alone (`a.txt` to `A.txt`) no longer replaces a different file on a case-sensitive server. A server without `posix-rename` keeps the old file until the new one is in place. A name that appears after a folder was listed is never overwritten without asking, and a Replace removes only what you were asked about: a file that took the name while the question was up stays.
- A folder copy into itself through a link on the server is refused; it used to copy until the disk filled.
- A temp that could not be removed stays recorded, and the next login removes it. On a server without `posix-rename`, a file a replace set aside is recorded too, and the next login puts it back.
- A download checks the file it opened against its listing, so a file that changed on the server since is read again, never placed cut short.
- Quit asks when Transfer cannot tell within 3 s whether Live edits are unsynced (it used to quit without asking), and names transfers that have not finished, closed windows' included; its question comes to the front.
- Stars, Live files, and temps whose names are not UTF-8 keep their exact bytes.

### Security

- Downloads are quarantined as a browser's are, so Gatekeeper checks an app or script before it first runs, and never take setuid, setgid, or sticky bits from the server.
- A saved password or passphrase answers only that server's own prompt, never a `ProxyJump` host's. A saved key passphrase is stored apart from the server's password, so it is never sent to the server as a password.
- A channel whose login has gone fails at once instead of logging in on its own with the default port and keys.
- A drop honors remote paths only from a drag that began in Transfer, so another app cannot have a drop rename files on your server.
- An `sftp://` link with a control character in its path is refused, and Copy Remote URL brackets an IPv6 host.
- Open in Terminal refuses a folder name holding a control character, which would have run the rest of the line as a command.
- A malformed, silent, or non-reading server fails its channel with a clear error instead of hanging it or filling memory.
- The installer installs only an app signed with Transfer's Developer ID and accepted by Gatekeeper as notarized, and follows redirects only over HTTPS.

### Logins and reliability

- ssh checks host keys itself, so keys known through a global known-hosts file, `@cert-authority`, or `KnownHostsCommand` log in without a question, a known host costs one connection instead of two, and a `@revoked` key is refused. Always Trust honors `HashKnownHosts`.
- Two windows or a retry logging in to one server share one login instead of asking twice and leaving a stray master behind. Cancel on any login question stops the login at once, with no error, and a window that moves to another server takes back that login's questions. Always Trust fails with a message when `ssh -G` cannot read the configuration, instead of trusting for one login only. A login no longer runs a remote `performance-version` command.
- `ControlPersist`, `ForkAfterAuthentication`, `RemoteCommand`, `RequestTTY`, `LocalForward`, and `PermitLocalCommand` in `~/.ssh/config` no longer break channels, hold your forwarded ports, or leave a master Transfer cannot stop.
- A server whose shell prints text before SFTP starts fails with a clear error within 15 s, and one that stops answering for 60 s fails its requests, which then retry.
- Every `sftp://` link in a burst gets its own window; one could be lost before.
- The column view no longer crashes when a drag crosses the area beyond its last column.
- A paste or folder copy goes on past an item that fails and names every failure at the end.
- A file whose name nearly fills the 255-byte limit copies both ways, and a Live file with such a name still gets its `(server)` copy.
- Copy Remote URL writes a name that is not UTF-8 byte for byte, and such a link opens that file. A server's error is no longer labeled twice ("Permission denied: Permission denied").
- A sheet never replaces another: one that arrives meanwhile waits its turn. A sheet about a server closes when the window leaves it, and Upload…, Download Copy…, and pastes act on the server they were started on or do nothing and say so.
- The rename bar's field takes the focus with Full Keyboard Access on, and emptying the search field keeps its focus, so Return no longer starts a rename.
- An unreadable `config.json` is kept as `config.json.bak` before the defaults take over.

### Performance

Measured at 20 ms round trip against 0.1.7:

- 2,000 small files: download 151 → 2,221 files/s, upload 44 → 1,616, copy on the server 60 → 1,488. Small files share a data channel, sixteen at a time, and a file's requests go out together.
- One 256 MB file: download 83 → 306 MB/s, upload 83 → 292 MB/s. A file of 8 MB or more uses up to four data channels.
- Listing 10,000 names: 670 → 224 ms.
- Column view with 10,000 items: Select All took one to ten minutes and takes about 12 ms; opening the column sorted by date, 3.3 s → 0.1 s.
- The inspector fetches only the first 64 KB of a text file it previews, and progress reaches the window ten times a second instead of once per 64 KB.

### Behavior changes

- A name collision with no window left to ask fails its operation instead of skipping the file.
- Dragging between folders on one server moves; Option-drag copies (it used to move). A drag from another server's window copies (it used to be refused).
- Right-clicking an empty area acts on that folder: the list and icon views clear the selection, and the column view makes that column's folder the location.
- Command-Down and Space act once when held.
- A transfer's shelf row offers Stop and Restart, since a stopped transfer starts its current file over; a Live file's row keeps Pause and Resume.
- Duplicate works on folders and links, not only files, and a folder keeps its whole name: `v1.2 copy`, and `v1.2 2` for Keep Both.
- Keep Both for a Live conflict names the Mac's copy `notes (from this Mac).txt`, so it keeps its extension.
- A move that kept originals reads Kept on the shelf, in grey, with the reason. Later on a Live conflict keeps its sheet away until you click its sidebar row.
- Opening a link follows the whole chain, as the server resolves it, not one hop.
- Errors stay in a bar at the top of the window until dismissed; a successful listing used to clear them at once.
- A paste or move between servers of a folder holding two names this Mac's disk cannot tell apart (`README` and `readme`, or `Straße` and `STRASSE`) keeps that item and says why; such a copy is not staged for the Finder either.
- Go to Remote Folder understands `~` (the server's start folder), `~/path`, relative paths, and `..`.
- The list view keeps Name as its first column.
- Transfer refuses to open a library written by a newer version, says why, and quits.
- Only one copy of Transfer opens a library at a time; a second copy says so and quits. (Two copies swept each other's login files and temps and could end each other's connections.)
- The installer stops, changing nothing, on a Mac where Gatekeeper's assessments are turned off.

### The library

`transfer.sqlite` now carries a schema version and upgrades itself on first launch, one step at a time: version 1 is the 0.1.0–0.1.7 schema; version 2 drops the unused recents table; version 3 changes no row and marks that paths are kept as the server's exact bytes, as text when they are UTF-8 (as before) and as bytes only when not. The file switches to WAL mode, so `transfer.sqlite-wal` and `transfer.sqlite-shm` appear beside it. Transfer 0.1.7 can still open an upgraded library, and still unstars and forgets what it finds there. The preview cache is keyed per server, so existing previews are fetched again once, and clipboard staging moves into one `Staging` folder, emptied at launch.

### For maintainers

- `docs/SPEC.md` replaces `PLAN.md`; `HANDOFF.md` and `AGENTS.md` describe the code as it is.
- `TRANSFER_LIBRARY` gives a development build or a test its own library and caches.
- `Scripts/local-sshd.sh [port]` prints its exports once sshd listens and removes its keys when stopped; `TRANSFER_REQUIRE_SERVER=1` makes a missing test server fail the server suites instead of skipping them.
- `Scripts/package-app.sh` prints the app's path and builds in `SCRATCH` when given.
- `Scripts/release.sh` publishes the version's section of this file as the release notes and in Sparkle's feed, refuses a version without one, and undoes a failed release.

## 0.1.7 — 2026-09-24

- Shift with a mouse wheel, or a sideways swipe, pans the column view to the columns hidden on the left.

## 0.1.6 — 2026-09-23

Fixes eight serious bugs:

- An `sftp://` link from another app could pass a user or host starting with `-` to `ssh` as an option. Every `ssh` command line now ends its options with `--`, and such a link is refused.
- A Live save gave the server file the working copy's private mode (0600). It now keeps the server file's permissions.
- A rename could replace a file or empty folder that already had the new name. It now fails instead; only a change of case within one folder still renames in place.
- A download that got a short read reply could finish with a gap. It now asks again for the rest, and a download that would leave a gap fails.
- A move could delete an original whose copy was not complete, when a file of the same name and size was already at the destination. The copy check now compares modification times too.
- "Apply to all" in the name-collision prompt stuck for later operations. It now covers only the operations running when it was chosen.
- Transfer could quit on `SIGPIPE` when an `ssh` process exited. A lost channel is now a lost connection, which a transfer retries.
- Copying a file dated before 1970, or after February 2106, crashed. Its time is now clamped to what SFTP can hold.

## 0.1.5 — 2026-09-23

- Releases are signed with a Developer ID and notarized, with the ticket stapled, so Gatekeeper accepts Transfer downloaded from a browser or installed with Homebrew.
- Transfer runs with the hardened runtime, with an entitlement for the Apple events that Go > Open in Terminal sends to Terminal and iTerm2.

## 0.1.4 — 2026-09-23

- A new tab appears finished: toolbar, title bar, tab group, and server list are all in its first frame.

## 0.1.3 — 2026-09-22

- Column view has the right-click menu of the list view. Add to Starred stars the whole selection, becomes Remove from Starred when all of it is starred, and uses Finder's Add to Sidebar key, Control-Command-T.
- Command-B shows and hides the sidebar, and Command-I the inspector.

## 0.1.2 — 2026-09-22

- `sftp://` links open in Transfer: the folder opens, or the file is selected in its folder, on the saved server whose host, `ssh -G` host name, or address the link names. A host no saved server matches fills in the New Connection sheet.
- `Tools/xfer`, installed on a server, prints the current folder as a link to Command-click in Ghostty or any terminal that shows OSC 8 links.

## 0.1.1 — 2026-09-22

- A new app icon: a white page with a yellow badge on a blue tile, legible down to 16 pixels.

## 0.1.0 — 2026-09-22

The first release, ad-hoc signed, with a one-command installer and updates through Sparkle.

- Browse an SFTP server in icon, list, or column view, over the Mac's own `ssh`, with one login shared by every window for that server.
- Press Space to preview; the inspector shows a preview and the details of the selection.
- Open an editable file Live, and every completed save uploads; a conflict with the server keeps both versions.
- Copy and paste files and folders between folders, servers, and the Finder, and drag them to and from the Finder; Option-Command-V moves them.
- Starred folders in the sidebar, tabs, and windows that remember their size.
