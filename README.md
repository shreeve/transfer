# Transfer

Transfer is a native Mac app for browsing an SFTP server. Open an editable file and later saves upload. Open a PDF or an image and it is only viewed. Press Space to preview. Drag a file to the Finder and you get a real copy. Command-C and Command-V copy files and folders to another folder, another server, or the Finder, and back; Option-Command-V moves them. A bar at the bottom shows what is copied, and Escape clears it.

It targets macOS 27 on Apple silicon. The bundle id is `com.github.shreeve.transfer`.

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

`Check for Updates…` is in the app menu and stays quiet until `SUPublicEDKey` in `Support/Info.plist` is set. Shipping an update needs a Developer ID signature: `SIGN="Developer ID Application: …" Scripts/package-app.sh`.

## For people changing it

`PLAN.md` is the product spec. `HANDOFF.md` is how the current code actually works, including the window layout and the mistakes that already cost a day. `AGENTS.md` is the short rule list for an automated session.
