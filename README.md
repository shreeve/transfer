# Transfer

Transfer is a native Mac app for browsing an SFTP server. Open an editable file and later saves upload. Open a PDF or an image and it is only viewed. Press Space to preview. Drag a file to the Finder and you get a real copy. Command-C and Command-V copy files and folders to another folder, another server, or the Finder, and back; Option-Command-V moves them. A bar at the bottom shows what is copied, and Escape clears it.

It targets macOS 27 on Apple silicon. The bundle id is `com.github.shreeve.transfer`.

## Install

One command installs or updates the newest release into `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/shreeve/transfer/main/Scripts/install.sh | bash
```

The app is ad-hoc signed, with no Developer ID; `curl` sets no quarantine, so it opens on first launch. A copy downloaded in a browser needs System Settings → Privacy & Security → Open Anyway once. Uninstall with `… | bash -s -- --uninstall`; your servers and settings stay.

## Build and run

The Xcode 27 toolchain has to be selected (`xcode-select` pointing at Xcode.app). There is no Xcode project.

```bash
swift test
Scripts/package-app.sh
open .build/Transfer.app
```

`swift test` does not need a server. To run the tests that log in to a local `sshd`:

```bash
eval "$(Scripts/local-sshd.sh)" && swift test; kill $TRANSFER_TEST_SSHD
```

That starts an unprivileged server on 127.0.0.1:2222 and does not turn on Remote Login.

## How a connection works

Transfer uses the `ssh` already on the Mac. One login is shared by every window for that server. Listing, the file you are previewing, and copying run on separate SSH channels, so a download does not block the file list. Several files can copy at once.

Which files open for editing is `editableExtensions` in `Support/config.json`. The first launch copies that file to `~/Library/Application Support/Transfer/config.json`, and Settings > Extensions edits the copy.

## Updates

Installed copies update themselves through `Check for Updates…` in the app menu (Sparkle). To ship a version, from a clean, pushed `main`:

```bash
Scripts/release.sh 0.2.0 --dry-run
Scripts/release.sh 0.2.0
```

The dry run builds everything under `.build/release-0.2.0` and publishes nothing; the real run also commits the version, tags `v0.2.0`, and publishes the GitHub release.

## For people changing it

`PLAN.md` is the product spec. `HANDOFF.md` is how the current code actually works, including the window layout and the mistakes that already cost a day. `AGENTS.md` is the short rule list for an automated session.
