import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// Pastes and drops through `TransferEngine` against the local sshd, above all the moves, which
/// delete: an original goes only once this move is proven to have written a complete copy of it.
/// A second saved server for the same sshd stands in for an alias, an address, or a second host
/// on a shared disk.
@Suite(.enabled(if: ServerHarness.available, "needs the local sshd from Scripts/local-sshd.sh"))
struct MoveServerTests {
    /// Move Item Here into the folder the items came from, copied through a second saved server
    /// for the same host, found each item "already there" and deleted the only copy (CLIP-01).
    @Test func aMoveOntoItselfThroughASecondServerRemovesNothing() async throws {
        try await withHarness("alias", connected: true) { h in
            try await withAlias(h) { alias in
                let site = try h.folder("site", files: ["a.txt": "a", "sub/b.txt": "b"])
                let request = TransferRequest(.server(alias.connection.id, [site.appending("a.txt"), site.appending("sub")]), into: site, on: h.session.connection.id, moving: true)
                await #expect(throws: TransferError.self) { try await run(request, on: h.session, from: alias) }
                #expect(try h.read("site/a.txt") == "a")
                #expect(try h.read("site/sub/b.txt") == "b")
                #expect(try h.names("site") == ["a.txt", "sub"])
                #expect(h.prompts.collisions == 0)

                // Into a folder that really is another one, the same move goes ahead.
                let elsewhere = try h.folder("elsewhere")
                try await run(TransferRequest(request.sources, into: elsewhere, on: h.session.connection.id, moving: true), on: h.session, from: alias)
                #expect(try h.read("elsewhere/a.txt") == "a")
                #expect(try h.read("elsewhere/sub/b.txt") == "b")
                #expect(try h.names("site").isEmpty)
                // The probe folders were recorded, as temps are, and forgotten once removed.
                #expect(try Store(root: h.root).remoteTemps(connection: h.session.connection.id).isEmpty)
            }
        }
    }

    /// A file of the same size and time at the destination was skipped as "already there", and
    /// the original removed, though the two differed (CLIP-02). Now it is asked about; skipped, the
    /// original stays, and replaced, the copy is the move's own.
    @Test func aLookalikeAtTheDestinationIsAskedAndKeepsTheOriginalUnlessReplaced() async throws {
        try await withHarness("look", connected: true) { h in
            try await withAlias(h) { alias in
                let source = try h.folder("from", files: ["report.txt": "AAAA"])
                let destination = try h.folder("to", files: ["report.txt": "BBBB"])
                for path in ["from/report.txt", "to/report.txt"] { try h.setTime(path, 1_700_000_000) }
                let request = TransferRequest(.server(alias.connection.id, [source.appending("report.txt")]), into: destination, on: h.session.connection.id, moving: true)

                let skip = TestPrompts(collision: .skip)
                await #expect(throws: TransferKept([.init("report.txt", .alreadyThere)], moving: true, place: "on the other server")) {
                    try await OperationPrompts.$current.withValue(skip) { try await run(request, on: h.session, from: alias) }
                }
                #expect(skip.collisions == 1)
                #expect(try h.read("from/report.txt") == "AAAA")
                #expect(try h.read("to/report.txt") == "BBBB")

                let replace = TestPrompts(collision: .replace)
                try await OperationPrompts.$current.withValue(replace) { try await run(request, on: h.session, from: alias) }
                #expect(replace.collisions == 1)
                #expect(try h.read("to/report.txt") == "AAAA")
                #expect(try h.names("from").isEmpty)
            }
        }
    }

    /// A lookalike that reached the destination during the copy, after the move's snapshot of it,
    /// was answered Skip and then passed for the move's copy: the original was removed and only
    /// the lookalike was left (XFR-01). Only what the move wrote counts now.
    @Test func aLookalikeArrivingDuringTheCopyNeverPassesForIt() async throws {
        try await withHarness("late", connected: true) { h in
            try await withAlias(h) { alias in
                let from = try h.folder("from", files: ["report.txt": "AAAA"])
                try h.setTime("from/report.txt", 1_700_000_000)
                let to = try h.folder("to")
                let planted = Locked(false)
                let scratch = Locked<[String]>([])
                let scratchRoot = try Store(root: h.root).scratch.path
                let request = TransferRequest(.server(alias.connection.id, [from.appending("report.txt")]), into: to, on: h.session.connection.id, moving: true)
                // During the download, someone else writes a file of the same size and time.
                let engine = TransferEngine(request: request, destination: h.session) { _ in
                    guard !planted.withLock({ defer { $0 = true }; return $0 }) else { return }
                    try? h.write("to/report.txt", "BBBB")
                    try? h.setTime("to/report.txt", 1_700_000_000)
                    scratch.value = (try? FileManager.default.contentsOfDirectory(atPath: scratchRoot)) ?? []
                }
                let skip = TestPrompts(collision: .skip)
                await #expect(throws: TransferKept([.init("report.txt", .alreadyThere)], moving: true, place: "on the other server")) {
                    try await OperationPrompts.$current.withValue(skip) { try await engine.run(from: alias) }
                }
                #expect(planted.value)
                #expect(skip.collisions == 1)
                #expect(try h.read("from/report.txt") == "AAAA")
                #expect(try h.read("to/report.txt") == "BBBB")
                // The copy passed through the library's scratch folder, which the next launch
                // empties if a crash leaves anything there (XFR-07, FR-1), and was removed.
                #expect(scratch.value.count == 1)
                #expect(try FileManager.default.contentsOfDirectory(atPath: scratchRoot).isEmpty)
                #expect(try Store(root: h.root).localTemps().isEmpty)
            }
        }
    }

    /// With Keep Both the copy lands as "name 2", and the move checked the old name, kept the
    /// original, and said the copy was not complete (CLIP-15).
    @Test func keepBothIsFollowedToWhereTheCopyLanded() async throws {
        try await withHarness("kboth", connected: true) { h in
            try await withAlias(h) { alias in
                let source = try h.folder("from", files: ["k.txt": "new", "dir/x.txt": "new x"])
                let destination = try h.folder("to", files: ["k.txt": "old", "dir": nil])
                try FileManager.default.createSymbolicLink(atPath: h.remote.appendingPathComponent("to/dir/x.txt").path, withDestinationPath: "elsewhere")
                let keepBoth = TestPrompts(collision: .keepBoth)
                let request = TransferRequest(.server(alias.connection.id, [source.appending("k.txt"), source.appending("dir")]), into: destination, on: h.session.connection.id, moving: true)
                try await OperationPrompts.$current.withValue(keepBoth) { try await run(request, on: h.session, from: alias) }
                #expect(keepBoth.collisions == 2)
                #expect(try h.read("to/k.txt") == "old")
                #expect(try h.read("to/k 2.txt") == "new")
                #expect(try h.read("to/dir/x 2.txt") == "new x")
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: h.remote.appendingPathComponent("to/dir/x.txt").path) == "elsewhere")
                #expect(try h.names("from").isEmpty)
            }
        }
    }

    /// Two items of one move with the same name, p/VERSION and q/VERSION, alike in size and time:
    /// the second passed for the first's copy, since the memo of what the move wrote was shared by
    /// every item, and its original was removed unasked (R-T1). Now it is asked about; skipped, it
    /// stays, as between servers so from this Mac.
    @Test func twoItemsWithOneNameEachCountOnlyTheirOwnCopy() async throws {
        try await withHarness("twins", connected: true) { h in
            try await withAlias(h) { alias in
                let from = try h.folder("from", files: ["p/VERSION": "one", "q/VERSION": "two"])
                for path in ["from/p/VERSION", "from/q/VERSION"] { try h.setTime(path, 1_700_000_000) }
                let destination = try h.folder("to")
                let request = TransferRequest(.server(alias.connection.id, [from.appending("p").appending("VERSION"), from.appending("q").appending("VERSION")]), into: destination, on: h.session.connection.id, moving: true)
                let skip = TestPrompts(collision: .skip)
                await #expect(throws: TransferKept([.init("VERSION", .alreadyThere)], moving: true, place: "on the other server")) {
                    try await OperationPrompts.$current.withValue(skip) { try await run(request, on: h.session, from: alias) }
                }
                #expect(skip.collisions == 1)
                #expect(try h.read("to/VERSION") == "one")
                #expect(try h.names("from/p").isEmpty)
                #expect(try h.read("from/q/VERSION") == "two")
            }

            let mac = h.staging.appendingPathComponent("mac")
            for (folder, text) in [("p", "one"), ("q", "two")] {
                let file = mac.appendingPathComponent(folder).appendingPathComponent("VERSION")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
            }
            let sources = ["p", "q"].map { mac.appendingPathComponent($0).appendingPathComponent("VERSION") }
            let trashed = Locked<[URL]>([])
            let skip = TestPrompts(collision: .skip)
            await #expect(throws: TransferKept([.init("VERSION", .alreadyThere)], moving: true, place: "on this Mac")) {
                try await OperationPrompts.$current.withValue(skip) {
                    try await run(TransferRequest(.mac(sources), into: try h.folder("fromMac"), on: h.session.connection.id, moving: true), on: h.session, trash: { url in trashed.withLock { $0.append(url) } })
                }
            }
            #expect(skip.collisions == 1)
            #expect(trashed.value == [sources[0]])
            #expect(try h.read("fromMac/VERSION") == "one")
        }
    }

    /// Keep Both for the first of two same-named items sent the second, unasked, to where the
    /// first had landed, where the first's copy passed for its own (R-T1). Each item now settles
    /// its own name.
    @Test func keepBothForOneItemIsNotFollowedByAnother() async throws {
        try await withHarness("kb2", connected: true) { h in
            try await withAlias(h) { alias in
                let from = try h.folder("from", files: ["p/k.txt": "p", "q/k.txt": "q"])
                for path in ["from/p/k.txt", "from/q/k.txt"] { try h.setTime(path, 1_700_000_000) }
                let destination = try h.folder("to", files: ["k.txt": "old"])
                let keepBoth = TestPrompts(collision: .keepBoth)
                let request = TransferRequest(.server(alias.connection.id, [from.appending("p").appending("k.txt"), from.appending("q").appending("k.txt")]), into: destination, on: h.session.connection.id, moving: true)
                try await OperationPrompts.$current.withValue(keepBoth) { try await run(request, on: h.session, from: alias) }
                #expect(keepBoth.collisions == 2)
                #expect(try h.read("to/k.txt") == "old")
                #expect(try h.read("to/k 2.txt") == "p")
                #expect(try h.read("to/k 3.txt") == "q")
                #expect(try h.names("from/p").isEmpty && h.names("from/q").isEmpty)
            }
        }
    }

    /// A retry ran the whole paste again: a move failed on items it had already moved, and a
    /// paste beside the original made "name copy 2" next to its own partial "name copy" (CLIP-18,
    /// TD-06). Also, a Keep Both name chosen before the failure is reused, not asked again.
    @Test func aRetryPicksUpWhereTheFailedAttemptLeftOff() async throws {
        try await withHarness("retry", connected: true) { h in
            try await withAlias(h) { alias in
                // A move between servers whose second item is not there yet.
                let source = try h.folder("from", files: ["a.txt": "a"])
                let destination = try h.folder("to")
                let move = TransferRequest(.server(alias.connection.id, [source.appending("a.txt"), source.appending("b.txt")]), into: destination, on: h.session.connection.id, moving: true)
                await #expect(throws: TransferError.self) { try await run(move, on: h.session, from: alias) }
                #expect(try h.names("from") == [])
                try h.write("from/b.txt", "b")
                try await run(move, on: h.session, from: alias)
                #expect(try h.names("to") == ["a.txt", "b.txt"])
                #expect(try h.names("from").isEmpty)
            }

            // A paste into the folder it came from, whose folder holds a file the server cannot read.
            let site = try h.folder("site", files: ["dir/x.txt": "x", "dir/locked.txt": "locked", "dir copy": nil])
            let locked = h.remote.appendingPathComponent("site/dir/locked.txt")
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            let paste = TransferRequest(.server(h.session.connection.id, [site.appending("dir")]), into: site, on: h.session.connection.id, moving: false)
            await #expect(throws: TransferError.self) { try await run(paste, on: h.session) }
            #expect(try h.names("site") == ["dir", "dir copy", "dir copy 2"])
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
            try await run(paste, on: h.session)
            #expect(try h.names("site") == ["dir", "dir copy", "dir copy 2"])
            #expect(try h.names("site/dir copy 2") == ["locked.txt", "x.txt"])
            #expect(h.prompts.collisions == 0)

            // A copy that met a name, chose Keep Both, and then failed goes back to the same "x 2".
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            let keep = try h.folder("keep", files: ["dir/x.txt": "other"])
            let merge = TransferRequest(.server(h.session.connection.id, [site.appending("dir")]), into: keep, on: h.session.connection.id, moving: false)
            let keepBoth = TestPrompts(collision: .keepBoth)
            await #expect(throws: TransferError.self) {
                try await OperationPrompts.$current.withValue(keepBoth) { try await run(merge, on: h.session) }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
            try await OperationPrompts.$current.withValue(keepBoth) { try await run(merge, on: h.session) }
            #expect(keepBoth.collisions == 1)
            #expect(try h.names("keep/dir") == ["locked.txt", "x 2.txt", "x.txt"])
        }
    }

    /// One item that failed ended the whole paste, and the items after it were never tried (R-T6).
    /// Each has its turn now, on every route, and what failed is reported at the end: a single
    /// failure as it came, several together.
    @Test func aFailedItemDoesNotStopTheOthers() async throws {
        try await withHarness("each", connected: true) { h in
            let site = try h.folder("site", files: ["good.txt": "g", "also.txt": "a"])
            let to = try h.folder("to")
            let paste = TransferRequest(.server(h.session.connection.id, [site.appending("gone.txt"), site.appending("good.txt")]), into: to, on: h.session.connection.id, moving: false)
            await #expect(throws: TransferError.self) { try await run(paste, on: h.session) }
            #expect(try h.names("to") == ["good.txt"])

            try await withAlias(h) { alias in
                let move = TransferRequest(.server(alias.connection.id, [site.appending("gone.txt"), site.appending("missing.txt"), site.appending("also.txt")]), into: to, on: h.session.connection.id, moving: true)
                do {
                    try await run(move, on: h.session, from: alias)
                    Issue.record("the two missing items were not reported")
                } catch let kept as TransferKept {
                    #expect(kept.items.map(\.name) == ["gone.txt", "missing.txt"])
                }
                #expect(try h.read("to/also.txt") == "a")
                #expect(try h.names("site") == ["good.txt"])
            }

            let mac = h.staging.appendingPathComponent("mac.txt")
            try Data("m".utf8).write(to: mac)
            let upload = TransferRequest(.mac([h.staging.appendingPathComponent("gone.txt"), mac]), into: to, on: h.session.connection.id, moving: true)
            let trashed = Locked<[URL]>([])
            await #expect(throws: TransferError.self) { try await run(upload, on: h.session, trash: { url in trashed.withLock { $0.append(url) } }) }
            #expect(try h.read("to/mac.txt") == "m")
            #expect(trashed.value == [mac])
        }
    }

    /// A folder pasted beside itself was named as a file is, at its last dot: "v1.2" became
    /// "v1 copy.2" (R-C3).
    @Test func aFolderPastedBesideItselfKeepsItsWholeName() async throws {
        try await withHarness("vdup", connected: true) { h in
            let site = try h.folder("site", files: ["v1.2/a.txt": "a", "notes.txt": "n"])
            let id = h.session.connection.id
            try await run(TransferRequest(.server(id, [site.appending("v1.2"), site.appending("notes.txt")]), into: site, on: id, moving: false), on: h.session)
            #expect(try h.names("site") == ["notes copy.txt", "notes.txt", "v1.2", "v1.2 copy"])
        }
    }

    /// A move deleted a Live working copy's folder, edits and all, since the server's copy it
    /// compared was complete (CLIP-03).
    @Test func anUnsyncedLiveFileKeepsTheFolderItIsIn() async throws {
        try await withHarness("lmove", connected: true) { h in
            try await withAlias(h) { alias in
                let source = try h.folder("from", files: ["dir/note.txt": "first"])
                let note = source.appending("dir").appending("note.txt")
                let local = try await h.session.prepareLiveFile(note)
                await h.session.setLivePaused(note, paused: true)
                try Data("edited here".utf8).write(to: local)
                #expect(await waitUntil { await h.session.liveFiles().first?.dirty == true })

                let destination = try h.folder("to")
                let request = TransferRequest(.server(h.session.connection.id, [source.appending("dir")]), into: destination, on: alias.connection.id, moving: true)
                await #expect(throws: TransferKept([.init("dir", .live(1))], moving: true, place: "on the other server")) {
                    try await run(request, on: alias, from: h.session)
                }
                #expect(try h.read("from/dir/note.txt") == "first")
                #expect(try h.read("to/dir/note.txt") == "first")
                #expect(try Data(contentsOf: local) == Data("edited here".utf8))
            }
        }
    }

    /// Removing a moved original listed each folder again and removed all it held, so a file added
    /// or changed after the copy was verified went too, and its only copy with it (R-T2). Only the
    /// verified entries go now; what changed stays, with the folders holding it.
    @Test func aMovedOriginalLosesOnlyWhatWasVerified() async throws {
        try await withHarness("verified", connected: true) { h in
            let dir = try h.folder("dir", files: ["a.txt": "a", "sub/b.txt": "b", "sub/c.txt": "c", "gone/d.txt": "d"])
            let verified = try await h.session.tree(dir)
            try h.write("dir/sub/new.txt", "added")
            try h.write("dir/sub/c.txt", "changed")
            #expect(try await h.session.removeMoved(dir, verified: verified, savedSince: await h.live.saveMark()) == false)
            #expect(try h.names("dir") == ["sub"])
            #expect(try h.names("dir/sub") == ["c.txt", "new.txt"])

            let unchanged = try h.folder("unchanged", files: ["x/y.txt": "y"])
            #expect(try await h.session.removeMoved(unchanged, verified: try await h.session.tree(unchanged), savedSince: 0))
            #expect(try !h.names("").contains("unchanged"))
        }
    }

    /// A Live save that landed after the move walked its original and before the removal left
    /// the removal a clean Live file: the original, holding the newer bytes, was removed and the
    /// working copy with it (R-L2). The save here keeps the size and whole-second time the walk
    /// saw, so only the Live save count tells.
    @Test func aLiveSaveAfterTheWalkKeepsTheOriginal() async throws {
        try await withHarness("lsave", connected: true) { h in
            let dir = try h.folder("dir", files: ["note.txt": "first"])
            try h.setTime("dir/note.txt", 1_700_000_000)
            let local = try await h.session.prepareLiveFile(dir.appending("note.txt"))
            let mark = await h.live.saveMark()
            let verified = try await h.session.tree(dir)

            let saved = h.staging.appendingPathComponent("note.txt")
            try Data("FIRST".utf8).write(to: saved)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.5)], ofItemAtPath: saved.path)
            #expect(rename(saved.path, local.path) == 0)
            #expect(await waitUntil { (try? h.read("dir/note.txt")) == "FIRST" })
            #expect(await waitUntil { await h.session.liveFiles().first?.dirty == false })
            #expect(try await h.session.tree(dir) == verified)

            #expect(try await h.session.removeMoved(dir, verified: verified, savedSince: mark) == false)
            #expect(try h.read("dir/note.txt") == "FIRST")
            #expect(try Data(contentsOf: local) == Data("FIRST".utf8))
            #expect(await h.session.liveFiles().count == 1)
        }
    }

    /// The save mark was read after the copy, so a Live save that landed while the item was being
    /// copied, keeping its size and whole-second time, was in neither the copy nor the mark: the
    /// original holding it was removed, and the edit was nowhere (XFR-04, LIV2-01).
    @Test func aLiveSaveDuringTheCopyKeepsTheOriginal() async throws {
        try await withHarness("lcopy", connected: true) { h in
            try await withAlias(h) { alias in
                let dir = try h.folder("from", files: ["dir/note.txt": "first"])
                try h.setTime("from/dir/note.txt", 1_700_000_000)
                let local = try await h.session.prepareLiveFile(dir.appending("dir").appending("note.txt"))
                let saved = Locked(false)
                let request = TransferRequest(.server(h.session.connection.id, [dir.appending("dir")]), into: try h.folder("to"), on: alias.connection.id, moving: true)
                // The download's first progress holds the copy until the save is on the server.
                let engine = TransferEngine(request: request, destination: alias) { _ in
                    guard !saved.withLock({ defer { $0 = true }; return $0 }) else { return }
                    let landed = DispatchSemaphore(value: 0)
                    Task {
                        let next = h.staging.appendingPathComponent("note.txt")
                        try? Data("FIRST".utf8).write(to: next)
                        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.5)], ofItemAtPath: next.path)
                        _ = rename(next.path, local.path)
                        _ = await waitUntil { (try? h.read("from/dir/note.txt")) == "FIRST" }
                        _ = await waitUntil { await h.session.liveFiles().first?.dirty == false }
                        landed.signal()
                    }
                    _ = landed.wait(timeout: .now() + 10)
                }
                await #expect(throws: TransferKept([.init("dir", .changed)], moving: true, place: "on the other server")) {
                    try await engine.run(from: h.session)
                }
                #expect(saved.value)
                #expect(try h.read("from/dir/note.txt") == "FIRST")
                #expect(try Data(contentsOf: local) == Data("FIRST".utf8))
                #expect(await h.session.liveFiles().count == 1)
            }
        }
    }

    /// A move on one server is one rename per item, which never replaces, and a folder is never
    /// moved into itself (TD2-04).
    @Test func aMoveOnOneServerRenamesAndNeverReplaces() async throws {
        try await withHarness("rename", connected: true) { h in
            let from = try h.folder("from", files: ["a.txt": "a", "dir/c.txt": "c"])
            let to = try h.folder("to")
            let id = h.session.connection.id
            try await run(TransferRequest(.server(id, [from.appending("a.txt"), from.appending("dir")]), into: to, on: id, moving: true), on: h.session)
            #expect(try h.names("from").isEmpty)
            #expect(try h.read("to/a.txt") == "a")
            #expect(try h.read("to/dir/c.txt") == "c")
            #expect(h.prompts.collisions == 0)

            let into = to.appending("dir")
            await #expect(throws: TransferError.self) { try await run(TransferRequest(.server(id, [into]), into: into, on: id, moving: true), on: h.session) }
            await #expect(throws: TransferError.self) { try await run(TransferRequest(.server(id, [to]), into: into, on: id, moving: true), on: h.session) }
            #expect(try h.names("to") == ["a.txt", "dir"])
            #expect(try h.names("to/dir") == ["c.txt"])
        }
    }

    /// A rename whose reply was lost did its work, and the retry of the paste found the name taken
    /// and went on to copy an original that was gone (FR-15). The retry now counts the item moved.
    @Test func aRetryAfterALostRenameReplyFindsTheItemMoved() async throws {
        try await withHarness("lost", connected: true) { h in
            let id = h.session.connection.id
            let from = try h.folder("from", files: ["a.txt": "a"])
            let to = try h.folder("to")
            try FileManager.default.moveItem(at: h.remote.appendingPathComponent("from/a.txt"), to: h.remote.appendingPathComponent("to/a.txt"))
            try await run(TransferRequest(.server(id, [from.appending("a.txt")]), into: to, on: id, moving: true), on: h.session)
            #expect(try h.names("from").isEmpty)
            #expect(try h.names("to") == ["a.txt"])
            #expect(try h.read("to/a.txt") == "a")
            #expect(h.prompts.collisions == 0)
        }
    }

    /// A move on one server onto a name the folder held failed red with "already exists" instead
    /// of asking (UIB-02). It now asks, as every other route does: Skip keeps both, Keep Both and
    /// Replace move it, and a folder merges; the original goes only once its copy is verified.
    @Test func aMoveOnOneServerOntoATakenNameAsks() async throws {
        try await withHarness("taken", connected: true) { h in
            let id = h.session.connection.id
            let from = try h.folder("from", files: ["a.txt": "new", "dir/x.txt": "x"])
            let to = try h.folder("to", files: ["a.txt": "old", "dir/y.txt": "y"])
            let file = TransferRequest(.server(id, [from.appending("a.txt")]), into: to, on: id, moving: true)

            let skip = TestPrompts(collision: .skip)
            await #expect(throws: TransferKept([.init("a.txt", .alreadyThere)], moving: true, place: "on the server")) {
                try await OperationPrompts.$current.withValue(skip) { try await run(file, on: h.session) }
            }
            #expect(skip.collisions == 1)
            #expect(try h.read("from/a.txt") == "new")
            #expect(try h.read("to/a.txt") == "old")

            let keepBoth = TestPrompts(collision: .keepBoth)
            try await OperationPrompts.$current.withValue(keepBoth) { try await run(TransferRequest(file.sources, into: to, on: id, moving: true), on: h.session) }
            #expect(keepBoth.collisions == 1)
            #expect(try h.read("to/a.txt") == "old")
            #expect(try h.read("to/a 2.txt") == "new")
            #expect(try h.names("from") == ["dir"])

            try await run(TransferRequest(.server(id, [from.appending("dir")]), into: to, on: id, moving: true), on: h.session)
            #expect(try h.names("to/dir") == ["x.txt", "y.txt"])
            #expect(try h.names("from").isEmpty)

            try h.write("from/b.txt", "new b")
            try h.write("to/b.txt", "old b")
            let replace = TestPrompts(collision: .replace)
            try await OperationPrompts.$current.withValue(replace) {
                try await run(TransferRequest(.server(id, [from.appending("b.txt")]), into: to, on: id, moving: true), on: h.session)
            }
            #expect(try h.read("to/b.txt") == "new b")
            #expect(try h.names("from").isEmpty)
            #expect(h.prompts.collisions == 0)
        }
    }

    /// Two paths on one server can be one folder: moving an item into a link to its own folder
    /// would copy it onto itself and remove the only copy. The probe folder refuses it.
    @Test func aMoveOnOneServerIntoALinkToItsOwnFolderRemovesNothing() async throws {
        try await withHarness("onelink", connected: true) { h in
            let site = try h.folder("site", files: ["a.txt": "a"])
            try FileManager.default.createSymbolicLink(atPath: h.remote.appendingPathComponent("alias").path, withDestinationPath: "site")
            let id = h.session.connection.id
            let replace = TestPrompts(collision: .replace)
            await #expect(throws: TransferError.self) {
                try await OperationPrompts.$current.withValue(replace) {
                    try await run(TransferRequest(.server(id, [site.appending("a.txt")]), into: h.remotePath.appending("alias"), on: id, moving: true), on: h.session)
                }
            }
            #expect(replace.collisions == 0)
            #expect(try h.names("site") == ["a.txt"])
            #expect(try h.read("site/a.txt") == "a")
        }
    }

    /// A folder already at an item's name can be the item itself, reached another way: a bind
    /// mount or one share at two paths, whose parents are different folders. Replace would copy
    /// each file onto itself and the removal take the only copy (FR-14). A probe made in that
    /// folder and found under the item refuses it, on one server and between two. Without root
    /// there is no bind mount here: the item is a link to the folder, which the probe finds the
    /// same way.
    @Test func aMoveOntoAFolderThatIsTheItemItselfRemovesNothing() async throws {
        try await withHarness("sameitem", connected: true) { h in
            try await withAlias(h) { alias in
                let to = try h.folder("to", files: ["x/f.txt": "f"])
                _ = try h.folder("from")
                let link = h.remote.appendingPathComponent("from/x").path
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "../to/x")
                let item = h.remotePath.appending("from").appending("x")
                let refused = TransferKept.Reason.failed("the folder of that name at the destination is this item itself, reached another way")
                let replace = TestPrompts(collision: .replace)
                for (source, place) in [(nil, "on the server"), (alias, "on the other server")] {
                    let request = TransferRequest(.server((source ?? h.session).connection.id, [item]), into: to, on: h.session.connection.id, moving: true)
                    await #expect(throws: TransferKept([.init("x", refused)], moving: true, place: place)) {
                        try await OperationPrompts.$current.withValue(replace) { try await run(request, on: h.session, from: source) }
                    }
                    #expect(try h.names("to") == ["x"])
                    #expect(try h.names("to/x") == ["f.txt"])
                    #expect(try h.read("to/x/f.txt") == "f")
                    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "../to/x")
                }
                #expect(replace.collisions == 0)
                #expect(try Store(root: h.root).remoteTemps(connection: h.session.connection.id).isEmpty)
            }
        }
    }

    /// Files from this Mac go to the Trash only once their copy is verified; a folder holding a
    /// FIFO, which no copy can hold, stays. Moving a Mac folder onto itself on the server, which
    /// the local sshd serves from this very disk, removes nothing.
    @Test func aMoveFromThisMacTrashesOnlyVerifiedOriginals() async throws {
        try await withHarness("finder", connected: true) { h in
            let pack = h.staging.appendingPathComponent("pack")
            try FileManager.default.createDirectory(at: pack.appendingPathComponent("b"), withIntermediateDirectories: true)
            try Data("a".utf8).write(to: pack.appendingPathComponent("a.txt"))
            try Data("c".utf8).write(to: pack.appendingPathComponent("b/c.txt"))
            let odd = h.staging.appendingPathComponent("odd")
            try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
            try Data("f".utf8).write(to: odd.appendingPathComponent("f.txt"))
            #expect(mkfifo(odd.appendingPathComponent("pipe").path, 0o600) == 0)
            let destination = try h.folder("to")
            let trashed = Locked<[URL]>([])

            let request = TransferRequest(.mac([pack, odd]), into: destination, on: h.session.connection.id, moving: true)
            await #expect(throws: TransferKept([.init("odd", .incomplete)], moving: true, place: "on this Mac")) {
                try await run(request, on: h.session, trash: { url in trashed.withLock { $0.append(url) } })
            }
            #expect(trashed.value == [pack])
            #expect(try h.read("to/pack/b/c.txt") == "c")
            #expect(try h.read("to/odd/f.txt") == "f")

            let site = try h.folder("site", files: ["s.txt": "s"])
            let onto = TransferRequest(.mac([h.remote.appendingPathComponent("site/s.txt")]), into: site, on: h.session.connection.id, moving: true)
            await #expect(throws: TransferError.self) {
                try await run(onto, on: h.session, trash: { url in trashed.withLock { $0.append(url) } })
            }
            #expect(trashed.value == [pack])
            #expect(try h.names("site") == ["s.txt"])
        }
    }

    /// A folder from this Mac pasted into a folder inside itself, on a server that reaches this
    /// Mac's disk (a NAS mounted in Finder, or here the local sshd), copied its own output about a
    /// hundred levels deep before failing (XFR-02). It is refused, and a copy elsewhere goes ahead.
    @Test func aFolderFromThisMacIsNeverCopiedIntoItself() async throws {
        try await withHarness("macself", connected: true) { h in
            _ = try h.folder("site", files: ["a.txt": "a", "sub/b.txt": "b"])
            let site = h.remote.appendingPathComponent("site")
            let id = h.session.connection.id
            await #expect(throws: TransferError.failed("“site” cannot be pasted into itself.")) {
                try await run(TransferRequest(.mac([site]), into: h.remotePath.appending("site").appending("sub"), on: id, moving: false), on: h.session)
            }
            #expect(try h.names("site/sub") == ["b.txt"])
            try await run(TransferRequest(.mac([site]), into: try h.folder("elsewhere"), on: id, moving: false), on: h.session)
            #expect(try h.read("elsewhere/site/sub/b.txt") == "b")
        }
    }

    /// The folder-into-itself refusal compared names only, so a paste through a link that points
    /// inside the folder copied it into its own output until the disk filled (CLIP-08).
    @Test func aFolderIsNeverCopiedIntoItselfThroughALink() async throws {
        try await withHarness("inself", connected: true) { h in
            _ = try h.folder("site", files: ["sub/a.txt": "a"])
            try FileManager.default.createSymbolicLink(atPath: h.remote.appendingPathComponent("inside").path, withDestinationPath: "site/sub")
            let request = TransferRequest(.server(h.session.connection.id, [h.remotePath.appending("site")]), into: h.remotePath.appending("inside"), on: h.session.connection.id, moving: false)
            await #expect(throws: TransferError.failed("“site” cannot be pasted into itself.")) { try await run(request, on: h.session) }
            #expect(try h.names("site/sub") == ["a.txt"])
        }
    }
}

/// Placement without a server: a move never skips a lookalike (D9).
@Test func aMoveAsksAboutTheSameFileOrLink() {
    let print = Fingerprint(size: 4, mtime: 9)
    #expect(Placement.settle(.file(print), onto: .file(print)) == .skip)
    #expect(Placement.settle(.file(print), onto: .file(print), moving: true) == .collide)
    #expect(Placement.settle(.link("a"), onto: .link("a"), moving: true) == .collide)
    #expect(Placement.settle(.folder, onto: .folder, moving: true) == .merge)
    #expect(Placement.settle(.file(nil), onto: .file(nil), moving: false) == .collide)
}

/// Runs a paste as the hub does: `source` is the other server, nil when it is the destination's own.
private func run(
    _ request: TransferRequest,
    on destination: SSHConnection,
    from source: SSHConnection? = nil,
    trash: (@Sendable (URL) throws -> Void)? = nil
) async throws {
    var engine = TransferEngine(request: request, destination: destination) { _ in }
    if let trash { engine.trash = trash }
    try await engine.run(from: source)
}

/// A second saved server for the harness's sshd and folder, as an alias or an address for one
/// host: another `ConnectionID`, the same storage. Logged in, and always logged out after `body`.
private func withAlias(_ h: ServerHarness, _ body: (SSHConnection) async throws -> Void) async throws {
    var saved = h.session.connection
    saved.id = ConnectionID()
    saved.name = "alias"
    let alias = SSHConnection(connection: saved, store: try Store(root: h.root), editableExtensions: TransferConfig.builtIn.extensionSet, live: h.live, sshConfigFile: h.configFile.path)
    do {
        _ = try await alias.connect(prompts: h.prompts)
        try await body(alias)
    } catch {
        await alias.disconnect()
        throw error
    }
    await alias.disconnect()
}

private extension ServerHarness {
    /// Makes `name` in the served folder, with `files` inside by relative path: text, or nil for
    /// an empty folder. Returns its remote path.
    func folder(_ name: String, files: [String: String?] = [:]) throws -> RemotePath {
        try FileManager.default.createDirectory(at: remote.appendingPathComponent(name), withIntermediateDirectories: true)
        for (path, text) in files {
            let url = remote.appendingPathComponent(name).appendingPathComponent(path)
            if let text {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        return remotePath.appending(name)
    }

    func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: remote.appendingPathComponent(path))
    }

    func read(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: remote.appendingPathComponent(path)), as: UTF8.self)
    }

    /// What a served folder holds, sorted, hidden names too: a temp or a probe the engine left
    /// behind shows here.
    func names(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent(path).path).sorted()
    }

    func setTime(_ path: String, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: remote.appendingPathComponent(path).path)
    }
}
