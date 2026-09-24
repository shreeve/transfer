# Transfer: what it does

This is the product as users see it: what each action does and the rules it keeps. `HANDOFF.md` is how the code does it, and `AGENTS.md` is the rule list for changing it. When this file and the code disagree, find out which is wrong and fix that one; this file does not override either of them.

## The product

Transfer is a native Mac SFTP browser that feels like a small utility Apple shipped next to Finder. You browse a server, preview files, open editable files Live so every completed save uploads, and copy, drag and paste between servers and the Finder. It uses the Mac's own `/usr/bin/ssh`, so `~/.ssh/config`, the agent and `ProxyJump` just work, and every window and tab shares one login per saved server. It runs on macOS 27 on Apple silicon, and it never loses or silently overwrites a user's data, local or remote.

It is a browser window, not a second Finder and not a mounted disk: standard AppKit and SwiftUI controls, Finder's keys and conventions, no custom chrome, no dual pane.

### The four actions

| Action | Result |
| --- | --- |
| Double-click, Command-O, or Command-Down on an editable file | Live: the file opens in its usual editor, and every completed save uploads. |
| The same on any other file | View: the file opens from the preview cache. Nothing is uploaded. |
| Space | Quick Look. Never Live. |
| Drag to the Finder, or File → Download Copy… | A detached copy on the Mac. The remote file stays. |

A folder opens in the browser. File → Open Live (Option-Command-O) opens any file Live. An editable file is one whose extension is in `editableExtensions` in the user's `config.json` (Settings → Extensions), or whose type conforms to `public.plain-text` or `public.source-code`. Contents are never sniffed.

### Not built

These are absent, not disabled: a gallery view, a permissions editor, a trash on the server, a background helper or login item, a File Provider or mounted disk, protocols other than SFTP, sync folders, a command-line tool on the Mac, remote search, an editor, an embedded terminal, a diff viewer (Compare opens `opendiff`), spring-loaded folders, resuming a file from the middle, AppleDouble or resource forks, onboarding, a help book, and telemetry. Transfer never calls `rsync` and never installs anything on a server (`Tools/xfer` is the user's to install).

## Connecting

File → New Connection… (Command-K) or Add Server in the sidebar opens one sheet, which also edits a saved server:

| Field | When blank |
| --- | --- |
| Name | The host |
| Host | Required |
| User, Port | `~/.ssh/config` decides |
| Identity file | `~/.ssh/config` and the agent decide |
| Remote path | The remote home |

There is no password field, proxy field, or protocol picker. An edit applies at the next login.

- ssh asks for passwords, passphrases, and keyboard-interactive answers; each prompt is a sheet naming its server. The first prompt of a login may offer Save in Keychain, off by default. A saved password and a saved key passphrase are kept apart, and each answers only that server's own prompt of its kind, once per login; a second prompt means it was wrong, and the user is asked. Secrets never go into SQLite, argv, the environment, or a log.
- ssh checks the host key against the user's own known-hosts files. A known key logs in with no question. When ssh refuses a key, the sheet shows its type and SHA-256 fingerprint: a first-seen key offers Cancel, Trust Once, and Always Trust; a changed key offers Cancel and Replace Trusted Key. Cancel is the default; on this sheet or any other login sheet it stops the login and shows no error. Always Trust and Replace write only the first known-hosts file `ssh -G` names for the host, and fail with a message when `ssh -G` cannot read the configuration; Trust Once trusts the key for that login only. A revoked key is refused without a question. `StrictHostKeyChecking` is never `no`.
- One login serves every window and tab showing that server. A window that moves to another server mid-login takes back that login's sheets. Disconnect and quit end it; no master is left behind.
- Remove Server deletes the saved server, its stars, its Keychain secrets, and its Live folder, never remote files. It refuses while that server has Live edits the server lacks.

## Browsing

- Icon, list, and column views share one location and one selection. List columns are Name, Date Modified, Size, and Kind. Folders sort above files and names compare byte for byte unless Settings → General says otherwise; the sort column and direction are kept per server, the view mode and hidden files globally. Names starting with `.` are hidden until View → Show Hidden Files (Shift-Command-Period); `.` and `..` never show.
- A row is its raw path bytes: no Unicode normalization, no case folding. A name that is not valid UTF-8 displays with replacement characters and every operation uses its real bytes. A name that is not one path component (empty, `.`, `..`, or holding `/` or NUL) is dropped from a listing.
- A large folder shows its first names while the rest stream in. A folder visited before shows its last listing at once and updates in place. There is no polling: a folder is listed again when it is opened, on Go → Refresh (Command-R), and when Transfer itself changes it. A failed listing keeps what was shown and says why.
- Filter (Command-F) narrows the names already listed and never touches the network.
- Go → Go to Remote Folder… (Command-L) takes an absolute path, `~` or `~/path` (from the server's start folder: its saved remote path, else the login's home), a relative path, or `..`.
- A symlink is listed as itself. Opening it or previewing it follows the whole chain as the server's REALPATH resolves it: a folder at the end is shown, a file at the end is viewed or opened Live at its real path. A loop or dangling link is an error.
- The sidebar (Command-B) holds Servers, Starred, Live Files (only while one is edited, uploading, paused, or in conflict), and Conflicts. Starred holds files and folders: a starred folder opens, a starred file is revealed in its folder. Clicking a Live file or conflict reveals it without opening it.
- The inspector (Command-I) shows the selected item's name, kind, size, date, permissions, and owner and group, with a preview: the first 64 KB of a text file, highlighted, or a picture or Quick Look preview of a file up to 8 MB. Several selected items show a count; none shows the folder.
- Go → Open in Terminal opens the current folder (never the selection) in a running Terminal, iTerm2, or Ghostty, else the first of them installed, as another ssh client of the same login. It is disabled when disconnected or when none of the three is installed.

## Preview, view, and Live

- Space toggles Quick Look over the selection, and the arrow keys move the selection behind it. A text or source file previews as syntax-colored HTML made from its first 512 KB (one that is not UTF-8 previews as itself); everything else is downloaded whole into the preview cache. Previews are never Live and never uploaded. View → Clear Preview Cache empties the cache and never touches Live files.
- View downloads the whole file into the preview cache and opens it with its default app, asking once for an app when the type has none. Transfer does not watch it.
- A Live file is downloaded to its own private folder under the library's `Live` folder and opened. A pass runs once the working copy has held still for 350 ms. A touch without a change is not uploaded. An upload writes a temp beside the server file and renames it into place only if the server still holds what the working copy was based on; otherwise the file becomes a conflict and nothing is overwritten. The server file keeps its own permissions.
- A server that cannot be reached is not a conflict: the save waits and uploads after the next login. Other failures retry at 1, 2, and 4 s, then wait for the next save, login, or Retry.
- A working copy that disappears gets a second look a second later, as editors delete and recreate. A copy is refreshed from the server only when the user opens it again, never behind an open editor. A rename on the server moves the record, not the working copy, which keeps its name.
- Live records survive closing windows, quitting, and restarting; uploads run only while Transfer is open. A synced copy untouched for a day is forgotten at the next launch. File → Forget Synced Live Files drops every synced record; File → Discard Live File drops one, asking first when it holds edits the server lacks.
- A Live conflict sheet offers Compare, Keep Local, Keep Remote, and Keep Both, with Later to decide afterwards: the conflict stays in the sidebar, its row brings the sheet back, and it does not come back on its own. Compare writes the server's bytes beside the working copy as `<name> (server)` and opens `/usr/bin/opendiff`; it is disabled when there is no server file or no `opendiff`. Keep Local and Keep Remote each need a second press. Keep Both uploads the Mac's bytes beside the original as `<base> (from this Mac).<ext>`, so the copy opens in the same editor, and gives the working copy the server's bytes. Keep Local and Keep Both wait until the working copy has held still and refuse while it is still being written. Keep Remote and Keep Both never overwrite a save made after the choice: that save, and the conflict, stay. Keep Remote when the server file has gone since keeps both copies and raises the conflict again.

## Copy, paste, drag, and move

- With a selection and no text field focused, Command-C copies items; Command-V pastes them into the current folder, and Option-Command-V (Move Item Here) moves them there. Text fields keep their own Copy and Paste. A bar at the bottom of every window names what the clipboard holds, where it came from, and whether the Finder can paste it yet ("Copied 3 files and 1 folder (31 files in all, 12 MB)"). Escape or the bar's close button clears it.
- Within one server a paste copies on the server (with `copy-data` when the server offers it, else through the Mac). Pasting into the items' own folder makes `name copy`, `name copy 2`, …, as File → Duplicate (Command-D) does for any item; a folder keeps its whole name (`v1.2 copy`). A folder is never pasted into itself, however the server's links reach it.
- Between servers a paste downloads into a scratch folder on the Mac and uploads from it; an item holding two names the Mac's disk cannot tell apart (`README` and `readme`) is refused. From the Finder it uploads. To the Finder, Transfer downloads the copied items to a staging folder right after Command-C and offers them once complete; copies over 1 GB, trees it could not count in full, and trees holding such name pairs are not staged.
- Dragging to the Finder writes real files and folders, never a placeholder, and never removes the remote item. Dragging from the Finder uploads and leaves the original. A drop on a folder row lands in that folder; anywhere else, in the current folder.
- A drag between folders on one server moves the items (a rename each); with Option it copies them. A drag from a window showing another server copies, never moves.
- Every copy writes a hidden temp beside the final name and renames it into place, keeping the source's mode (never setuid, setgid, or sticky from a server) and modification time. A file already there with the same size and whole-second time is skipped. Anything else already there asks: Skip (the default), Keep Both (`name 2`, `name 3` before a file's extension; a folder keeps its whole name, `v1.2 2`), or Replace, with Apply to All for that operation only. A folder merges into a folder; a file never replaces a folder or the reverse, and that item fails. Links are copied as links, never followed; sockets, FIFOs, and devices are skipped. A Replace removes only what was asked about: whatever took the name since stays, and that item fails. A paste, and a folder copy, go on past an item that fails and name every failure at the end. With no window left to ask, a collision fails its operation rather than guess.
- Downloads are quarantined as a browser's are, so Gatekeeper checks an app or script before it first runs.
- A move removes an original only after checking that this move wrote a complete copy of it: every file with an equal size and a known, equal time, and nothing that was already at the destination counted unless the user chose Replace. In a move, a same-looking file already there is asked about, never skipped. A move first proves the destination is not the originals' own folder reached another way, such as two saved servers for one host. Between servers, a move removes only what it checked: anything added to the original or changed after the check stays. An original with a Live file holding unsynced edits is kept, and so is one whose Live file saved after the check. Moved Finder originals go to the Trash. Whatever a move keeps, it names, with the reason.

## Delete and the shelf

- Edit → Delete… (Command-Delete) asks once for the selection, says the delete is permanent and there is no trash on the server, and warns when Live edits under it will be discarded. Cancel is the default. Only the edits the sheet named are discarded, and only once the server has deleted the item; an item holding edits the sheet did not name is kept, and the sheet asks again. A folder is removed depth first; links are removed, not followed. What was already removed stays removed.
- The shelf (View → Transfers) shows one row per operation, with byte and item progress. It opens when an operation starts and hides when its last row goes; a row disappears when it succeeds. A transfer offers Stop, then Restart, which skips what earlier attempts finished and starts the file in progress over; a Live file's row offers Pause and Resume. A failed row offers Retry and Remove; a move that kept originals reads Kept, in grey, with the reason. A dropped connection, a timeout, or a file that changed on the server while it downloaded retries at 1, 2, and 4 s before it fails; an authentication failure, a permission denial, a host-key refusal, or a conflict does not retry.
- An error names the file and the reason, and stays in the window's message bar until dismissed or replaced. No file is reported copied unless its final rename succeeded.
- Sheets come one at a time: one that arrives while another is up waits its turn, except New Connection and Edit, which beep. A sheet about a server closes when the window leaves that server. Work started in a window stays with the server it was started on; Upload… or Download Copy… whose window moved to another server meanwhile does nothing and says so.
- Quit asks, with Cancel as the default, when a Live file holds edits the server lacks, when a transfer in any window (closed ones included) has not finished, or when Transfer cannot tell within 3 s.
- One copy of Transfer opens a library at a time; a second copy says so and quits.

## `sftp://` links

Transfer opens `sftp://user@host:port/path` links from other apps. The link names a saved server by its host, by the host name `ssh -G` gives it, or by an address that name resolves to; a user or port in the link must agree. A folder opens; a file is selected in its folder, never opened. Each link gets a window showing no server yet, else a new tab. A host no saved server matches fills in the New Connection sheet, and nothing is saved until Connect. Edit → Copy Remote URL (Option-Command-C) writes one password-free link per selected item, holding the path's exact bytes.

## Menus and keys

| Command | Key |
| --- | --- |
| Open (Live or View, as a double-click) | Command-O, Command-Down |
| Open Live | Option-Command-O |
| Quick Look | Space |
| Rename | Return |
| New Folder | Shift-Command-N |
| Duplicate | Command-D |
| Copy, Paste | Command-C, Command-V |
| Move Item Here | Option-Command-V |
| Copy Remote URL | Option-Command-C |
| Clear the clipboard | Escape |
| Delete… | Command-Delete |
| Filter | Command-F |
| Back, Forward, Parent | Command-[, Command-], Command-Up |
| Remote Home | Shift-Command-H |
| Go to Remote Folder… | Command-L |
| Refresh | Command-R |
| New Connection…, New Window, New Tab | Command-K, Command-N, Command-T |
| as Icons, as List, as Columns | Command-1, Command-2, Command-3 |
| Show Hidden Files | Shift-Command-Period |
| Sidebar, Inspector | Command-B, Command-I |
| Add to Starred, Remove from Starred | Control-Command-T |
| Settings… | Command-Comma |

Download Copy…, Upload…, Open in Terminal, Transfers, and Clear Preview Cache have no key. Command-Down and Space act once when held, and only in the browser, never in a text field, on a button, or in a sheet, the sidebar, or the inspector. Escape closes an open rename bar before it clears the clipboard.
