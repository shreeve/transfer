# Changelog

What changed in each release of Transfer. `Scripts/release.sh <version>` publishes that version's section as the GitHub release notes and as the notes Sparkle shows in the update dialog, and refuses to release a version that has no section here. Changes not yet released collect under Unreleased, whose heading becomes the version's when it ships.

## Unreleased

A revamp of the whole app. Transfer looks much the same, but what it does with your files is safer, logins are sturdier, copies are much faster, and a few behaviors change (listed below). The library upgrades itself on first launch.

### Data safety

- A move removes an original only once it has checked that this move wrote a complete copy. A file of the same name, size, and time already at the destination no longer passes for the copy: it is asked about, and an original the user did not replace it with stays. Two saved servers that reach one disk, or a destination that is the originals' own folder reached another way, never copy an item onto itself and delete it. A folder holding a socket or FIFO, which no copy can write, keeps its original.
- Live files never lose edits the server lacks: a delete or move of a folder above one, Discard, Forget Synced Live Files, a conflict choice, and Remove Server all leave unsynced bytes alone unless you confirm, and Keep Remote or Keep Both never overwrite a save made after the choice. A save by someone else with the same size and second is no longer taken for your own upload, which left your edit marked synced and never uploaded.
- A server's names can no longer reach outside the folder you chose: a name that is not one path component is dropped from listings, and a link on the Mac is never followed or removed while downloading. A server link that met a local folder of the same name used to delete that folder.
- A change of case alone (`a.txt` to `A.txt`) no longer replaces a different file on a case-sensitive server. A server without `posix-rename` keeps the old file until the new one is in place. A name that appears after a folder was listed is never overwritten without asking.
- A folder copy into itself through a link on the server is refused; it used to copy until the disk filled.
- A temp that could not be removed stays recorded, and the next login removes it.
- Quit asks when Transfer cannot tell within 3 s whether Live edits are unsynced (it used to quit without asking), and names transfers that have not finished.
- Stars, Live files, and temps whose names are not UTF-8 keep their exact bytes.

### Security

- Downloads are quarantined as a browser's are, so Gatekeeper checks an app or script before it first runs, and never take setuid, setgid, or sticky bits from the server.
- A saved password or passphrase answers only that server's own prompt, never a `ProxyJump` host's.
- A drop honors remote paths only from a drag that began in Transfer, so another app cannot have a drop rename files on your server.
- An `sftp://` link with a control character in its path is refused, and Copy Remote URL brackets an IPv6 host.
- Open in Terminal refuses a folder name holding a control character, which would have run the rest of the line as a command.
- A malformed, silent, or non-reading server fails its channel with a clear error instead of hanging it or filling memory.
- The installer installs only an app signed with Transfer's Developer ID and accepted by Gatekeeper as notarized, and follows redirects only over HTTPS.

### Logins and reliability

- ssh checks host keys itself, so keys known through a global known-hosts file, `@cert-authority`, or `KnownHostsCommand` log in without a question, a known host costs one connection instead of two, and a `@revoked` key is refused. Always Trust honors `HashKnownHosts`.
- Two windows or a retry logging in to one server share one login instead of asking twice and leaving a stray master behind. A login no longer runs a remote `performance-version` command.
- `ControlPersist`, `ForkAfterAuthentication`, `RemoteCommand`, `RequestTTY`, `LocalForward`, and `PermitLocalCommand` in `~/.ssh/config` no longer break channels, hold your forwarded ports, or leave a master Transfer cannot stop.
- A server whose shell prints text before SFTP starts fails with a clear error within 15 s, and one that stops answering for 60 s fails its requests, which then retry.
- Every `sftp://` link in a burst gets its own window; one could be lost before.
- The column view no longer crashes when a drag crosses the area beyond its last column.
- A folder copy goes on past an item that fails and names every failure at the end.
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
- Right-clicking an empty area acts on that folder: the list view clears the selection, the column view makes that column's folder the location, and the icon view shows the folder's menu.
- Command-Down and Space act once when held.
- A transfer's shelf row offers Stop and Restart, since a stopped transfer starts its current file over; a Live file's row keeps Pause and Resume.
- Duplicate works on folders and links, not only files.
- Opening a link follows the whole chain, as the server resolves it, not one hop.
- Errors stay in a bar at the top of the window until dismissed; a successful listing used to clear them at once.
- A paste or move between servers of a folder holding two names this Mac's disk cannot tell apart (`README` and `readme`) keeps that item and says why; such a copy is not staged for the Finder either.
- Go to Remote Folder understands `~`, `~/path`, relative paths, and `..`.
- The list view keeps Name as its first column.
- Transfer refuses to open a library written by a newer version, says why, and quits.
- Only one copy of Transfer opens a library at a time; a second copy says so and quits. (Two copies swept each other's login files and temps and could end each other's connections.)
- The installer stops, changing nothing, on a Mac where Gatekeeper's assessments are turned off.

### The library

`transfer.sqlite` now carries a schema version and upgrades itself on first launch, one step at a time: version 1 is the 0.1.0–0.1.7 schema; version 2 drops the unused recents table and stores Live paths as the server's exact bytes; version 3 does the same for stars and temps. The file switches to WAL mode, so `transfer.sqlite-wal` and `transfer.sqlite-shm` appear beside it. Transfer 0.1.7 can still open an upgraded library. The preview cache is keyed per server, so existing previews are fetched again once, and clipboard staging moves into a `Staging` folder per running copy.

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
