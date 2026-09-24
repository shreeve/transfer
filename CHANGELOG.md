# Changelog

What changed in each release of Transfer. `Scripts/release.sh <version>` publishes that version's section as the GitHub release notes and as the notes Sparkle shows in the update dialog, and refuses to release a version that has no section here.

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
