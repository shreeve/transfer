import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// `LiveSync` against an in-memory server. No sshd, no FSEvents: edits are reported through
/// `localChanged`, as the watcher would.
struct LiveSyncTests {
    // MARK: Harness

    private struct Harness {
        let base: URL
        let store: Store
        let live: LiveSync
        let fake: FakeServer
        let connection: ConnectionID

        func files() async -> [LiveFile] { await live.files(on: connection) }
        func file() async -> LiveFile? { await live.files(on: connection).first }
    }

    private static func harness(_ name: String) throws -> Harness {
        let base = TestCaches.fresh("livesync-\(name)")
        let root = base.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try Store(root: root)
        return Harness(base: base, store: store, live: LiveSync(store: store, watches: false), fake: FakeServer(), connection: ConnectionID())
    }

    /// Runs `body` with a connected harness and always cleans up.
    private func withLive(_ name: String, _ body: (Harness) async throws -> Void) async throws {
        let h = try Self.harness(name)
        await h.live.connected(h.connection, server: h.fake)
        do {
            try await body(h)
        } catch {
            await h.live.closeAll()
            try? FileManager.default.removeItem(at: h.base)
            throw error
        }
        await h.live.closeAll()
        withExtendedLifetime(h.fake) {}
        try? FileManager.default.removeItem(at: h.base)
    }

    private func waitUntil(_ seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    private func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    /// Waits for the worker to have nothing queued, due, or running, so a check that something
    /// did not happen tests something however slow the machine is.
    private func settled(_ h: Harness) async -> Bool {
        await waitUntil { await h.live.workCount(on: h.connection) == 0 }
    }

    /// The last state the shelf showed for `note`.
    private func shelf(_ h: Harness) -> OperationState? {
        h.fake.events.compactMap { event -> OperationState? in
            if case .operation(let operation) = event, operation.livePath == note { return operation.state }
            return nil
        }.last
    }

    private static var serverNow: UInt32 { UInt32(Date().timeIntervalSince1970) - 600 }

    /// Puts `text` on the server at `path` and opens it Live. Returns the working copy and its id.
    private func openLive(_ h: Harness, _ path: RemotePath, _ text: String) async throws -> (URL, LiveFileID) {
        await h.fake.put(path, text, mtime: Self.serverNow)
        let local = try await h.live.open(path, on: h.connection)
        let id = try #require(await h.files().first { $0.path == path }?.id)
        return (local, id)
    }

    private func edit(_ h: Harness, _ local: URL, _ id: LiveFileID, _ text: String, mtime: Date? = nil) async throws {
        try Data(text.utf8).write(to: local)
        if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: local.path) }
        await h.live.localChanged(id)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func serverCopy(_ local: URL) -> URL {
        local.deletingLastPathComponent().appendingPathComponent("\(local.lastPathComponent) (server)")
    }

    private let note = RemotePath(string: "/srv/note.txt")

    /// The conflict flag is set and the `.conflict` event was emitted.
    private func raised(_ h: Harness) async -> Bool {
        let flagged = await h.file()?.conflict == true
        return flagged && h.fake.conflicts.contains(note)
    }

    // MARK: 1–3 Uploads

    @Test func editUploadsOnceAndEndsClean() async throws {
        try await withLive("edit") { h in
            let (local, id) = try await openLive(h, note, "first")
            #expect(read(local) == "first")
            #expect(await h.file()?.dirty == false)
            try await edit(h, local, id, "second edit")
            #expect(await waitUntil { await h.fake.contents(note) == "second edit" })
            #expect(await waitUntil { await h.file().map { !$0.dirty && !$0.uploading } == true })
            #expect(await settled(h))
            #expect(await h.fake.saves == 1)
            #expect(await h.file()?.conflict == false)
        }
    }

    /// The working copy was named by joining the server's name onto the Live folder, so a name
    /// such as `..` or one holding NUL reached outside the copy's own folder.
    @Test func aHostileServerNameNeverLeavesTheLiveFolder() async throws {
        try await withLive("hostile") { h in
            let live = h.store.root.appendingPathComponent("Live", isDirectory: true)
            for bytes in [Array("/srv/..".utf8), Array("/srv/a".utf8) + [0] + Array("b".utf8)] {
                let path = RemotePath(bytes: bytes)
                await h.fake.put(path, "hostile", mtime: Self.serverNow)
                await #expect(throws: TransferError.self) { _ = try await h.live.open(path, on: h.connection) }
            }
            #expect(await h.files().isEmpty)
            try #expect(FileManager.default.subpathsOfDirectory(atPath: live.path) == [])
        }
    }

    @Test func touchOnlyDoesNotUpload() async throws {
        try await withLive("touch") { h in
            let (local, id) = try await openLive(h, note, "same bytes")
            let touched = Date()
            try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: local.path)
            let stamp = try #require(LiveSync.stamp(local))
            await h.live.localChanged(id)
            // The pass restamps: the stored synced mtime becomes the touched one.
            let restamped = await waitUntil {
                h.store.liveFiles(connection: h.connection).first?.syncedMtime == stamp.mtime.timeIntervalSinceReferenceDate
            }
            #expect(restamped)
            #expect(await h.fake.saves == 0)
            #expect(await h.file()?.dirty == false)
        }
    }

    @Test func twoSameSizeEditsWithinOneSecondBothUpload() async throws {
        try await withLive("samesize") { h in
            let (local, id) = try await openLive(h, note, "init")
            let second = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            try await edit(h, local, id, "aaaa", mtime: second.addingTimeInterval(0.1))
            #expect(await waitUntil {
                let saves = await h.fake.saves
                let file = await h.file()
                return saves == 1 && file.map { !$0.dirty && !$0.uploading } == true
            })
            #expect(await h.fake.contents(note) == "aaaa")
            let firstBase = h.store.liveFiles(connection: h.connection).first?.baseMtime
            #expect(firstBase == UInt32(second.timeIntervalSince1970))
            try await edit(h, local, id, "bbbb", mtime: second.addingTimeInterval(0.5))
            #expect(await waitUntil { await h.fake.contents(note) == "bbbb" })
            #expect(await h.fake.saves == 2)
            #expect(await waitUntil { await h.file()?.dirty == false })
            // Both saves have the same whole-second fingerprint on the server; only the exact
            // local mtime told them apart.
            #expect(h.store.liveFiles(connection: h.connection).first?.baseMtime == firstBase)
        }
    }

    // MARK: 4–6 Server state

    @Test func serverChangedBehindTheAppIsAConflict() async throws {
        try await withLive("conflict") { h in
            let (local, id) = try await openLive(h, note, "first")
            await h.fake.changeBehind(note, "their edit")
            try await edit(h, local, id, "my edit")
            #expect(await waitUntil { await raised(h) })
            #expect(read(serverCopy(local)) == "their edit")
            #expect(read(local) == "my edit")
            #expect(await h.fake.contents(note) == "their edit")
            #expect(await h.fake.saves == 0)
            #expect(await h.file()?.dirty == true)
        }
    }

    @Test func serverFileDeletedIsARemovedConflict() async throws {
        try await withLive("removed") { h in
            let (local, id) = try await openLive(h, note, "first")
            await h.fake.delete(note)
            try await edit(h, local, id, "my edit")
            #expect(await waitUntil { await raised(h) })
            #expect(await h.fake.saves == 0)
            #expect(await h.fake.contents(note) == nil)
            #expect(h.store.liveFiles(connection: h.connection).first?.conflict == "removed")
        }
    }

    @Test func unreachableServerIsNotAConflictAndRetries() async throws {
        try await withLive("unreachable") { h in
            let (local, id) = try await openLive(h, note, "first")
            let before = await h.fake.lookups
            await h.fake.setFailing(true)
            try await edit(h, local, id, "offline edit")
            // A second lookup is the retry a second later: the first pass ended in a retry, not a conflict.
            #expect(await waitUntil { await h.fake.lookups >= before + 2 })
            #expect(await h.file()?.conflict == false)
            #expect(await h.file()?.dirty == true)
            #expect(await h.fake.saves == 0)
            #expect(h.fake.conflicts.isEmpty)
            await h.fake.setFailing(false)
            await h.live.connected(h.connection, server: h.fake)
            #expect(await waitUntil { await h.fake.contents(note) == "offline edit" })
            #expect(await waitUntil { await h.file()?.dirty == false })
            #expect(await h.file()?.conflict == false)
        }
    }

    // MARK: 7–8 Disconnected, paused

    @Test func disconnectedEditWaitsForLogin() async throws {
        try await withLive("disconnected") { h in
            let (local, id) = try await openLive(h, note, "first")
            await h.live.disconnected(h.connection, server: h.fake)
            let lookups = await h.fake.lookups
            try await edit(h, local, id, "while away")
            #expect(await h.file()?.dirty == true)
            #expect(await waitUntil { shelf(h) == .queued })
            #expect(await settled(h))
            #expect(await h.fake.saves == 0)
            #expect(await h.fake.lookups == lookups)
            #expect(await h.fake.contents(note) == "first")
            await h.live.connected(h.connection, server: h.fake)
            #expect(await waitUntil { await h.fake.contents(note) == "while away" })
            #expect(await waitUntil { await h.file()?.dirty == false })
            #expect(await h.fake.saves == 1)
        }
    }

    @Test func pausedEditIsDirtyUntilResumed() async throws {
        try await withLive("paused") { h in
            let (local, id) = try await openLive(h, note, "first")
            await h.live.setPaused(note, on: h.connection, paused: true)
            try await edit(h, local, id, "paused edit")
            #expect(await settled(h))
            #expect(await h.file()?.dirty == true)
            #expect(h.store.liveFiles(connection: h.connection).first?.dirty == true)
            #expect(await h.fake.saves == 0)
            #expect(await h.file()?.paused == true)
            await h.live.setPaused(note, on: h.connection, paused: false)
            #expect(await waitUntil { await h.fake.contents(note) == "paused edit" })
            #expect(await waitUntil { await h.file().map { !$0.dirty && !$0.paused } == true })
            #expect(await h.fake.saves == 1)
        }
    }

    // MARK: 9–11 Resolving

    private func conflicted(_ h: Harness, server: String, local text: String) async throws -> (URL, LiveFileID) {
        let (local, id) = try await openLive(h, note, "first")
        await h.fake.changeBehind(note, server)
        try await edit(h, local, id, text)
        let isRaised = await waitUntil { await raised(h) }
        try #require(isRaised)
        return (local, id)
    }

    @Test func keepLocalUploadsAndClears() async throws {
        try await withLive("keeplocal") { h in
            let (local, _) = try await conflicted(h, server: "theirs", local: "mine")
            #expect(FileManager.default.fileExists(atPath: serverCopy(local).path))
            try await h.live.resolve(note, on: h.connection, choice: .keepLocal)
            #expect(await h.fake.contents(note) == "mine")
            #expect(await h.fake.saves == 1)
            #expect(await h.file()?.conflict == false)
            #expect(await h.file()?.dirty == false)
            #expect(!FileManager.default.fileExists(atPath: serverCopy(local).path))
        }
    }

    @Test func keepLocalRefusesWhenTheServerChangedAgain() async throws {
        try await withLive("keeplocal2") { h in
            let (local, _) = try await conflicted(h, server: "theirs", local: "mine")
            await h.fake.changeBehind(note, "theirs again")
            await #expect(throws: (any Error).self) {
                try await h.live.resolve(note, on: h.connection, choice: .keepLocal)
            }
            #expect(await h.fake.contents(note) == "theirs again")
            #expect(await h.fake.saves == 0)
            #expect(await h.file()?.conflict == true)
            #expect(read(local) == "mine")
            #expect(read(serverCopy(local)) == "theirs again")
        }
    }

    @Test func keepRemoteTakesTheServerCopy() async throws {
        try await withLive("keepremote") { h in
            let (local, _) = try await conflicted(h, server: "theirs", local: "mine")
            try await h.live.resolve(note, on: h.connection, choice: .keepRemote)
            #expect(read(local) == "theirs")
            #expect(await h.file()?.conflict == false)
            #expect(await h.file()?.dirty == false)
            #expect(await h.fake.saves == 0)
            #expect(!FileManager.default.fileExists(atPath: serverCopy(local).path))
            // Stays clean: a later pass does not see the fetched copy as an edit.
            await h.live.localChanged(try #require(await h.file()?.id))
            #expect(await settled(h))
            #expect(await h.fake.saves == 0)
            #expect(await h.file()?.dirty == false)
        }
    }

    @Test func keepRemoteWhenTheServerFileIsGoneForgets() async throws {
        try await withLive("keepremote-gone") { h in
            let (local, id) = try await openLive(h, note, "first")
            await h.fake.delete(note)
            try await edit(h, local, id, "mine")
            #expect(await waitUntil { await h.file()?.conflict == true })
            try await h.live.resolve(note, on: h.connection, choice: .keepRemote)
            #expect(await h.files().isEmpty)
            #expect(h.store.liveFiles(connection: h.connection).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: local.deletingLastPathComponent().path))
        }
    }

    @Test func keepBothSavesASiblingAndPicksAFreeName() async throws {
        try await withLive("keepboth") { h in
            let (local, id) = try await conflicted(h, server: "theirs", local: "mine")
            try await h.live.resolve(note, on: h.connection, choice: .keepBoth)
            let sibling = RemotePath(string: "/srv/note (from this Mac).txt")
            #expect(await h.fake.contents(sibling) == "mine")
            #expect(await h.fake.contents(note) == "theirs")
            #expect(read(local) == "theirs")
            #expect(await h.file()?.conflict == false)
            #expect(await h.file()?.dirty == false)

            await h.fake.changeBehind(note, "theirs 2")
            try await edit(h, local, id, "mine 2")
            #expect(await waitUntil { await h.file()?.conflict == true })
            try await h.live.resolve(note, on: h.connection, choice: .keepBoth)
            #expect(await h.fake.contents(RemotePath(string: "/srv/note (from this Mac 2).txt")) == "mine 2")
            #expect(await h.fake.contents(sibling) == "mine")
            #expect(read(local) == "theirs 2")
            #expect(await h.files().count == 1)
        }
    }

    // MARK: 12–13 Missing working copy

    @Test func missingCleanCopyIsForgotten() async throws {
        try await withLive("missing-clean") { h in
            let (local, id) = try await openLive(h, note, "first")
            try FileManager.default.removeItem(at: local)
            await h.live.localChanged(id)
            #expect(await waitUntil(4) { await h.files().isEmpty })
            #expect(h.store.liveFiles(connection: h.connection).isEmpty)
        }
    }

    @Test func missingDirtyCopyIsKeptAndReported() async throws {
        try await withLive("missing-dirty") { h in
            let (local, id) = try await openLive(h, note, "first")
            await h.live.setPaused(note, on: h.connection, paused: true)
            try await edit(h, local, id, "unsynced")
            #expect(await settled(h))
            #expect(await h.file()?.dirty == true)
            try FileManager.default.removeItem(at: local)
            await h.live.localChanged(id)
            #expect(await waitUntil(4) { h.fake.failures.contains { $0.contains("disappeared") } })
            #expect(await h.file()?.dirty == true)
            #expect(await h.fake.saves == 0)
        }
    }

    @Test func copyRecreatedWithinGraceSurvivesAndUploads() async throws {
        try await withLive("recreated") { h in
            let (local, id) = try await openLive(h, note, "first")
            try FileManager.default.removeItem(at: local)
            await h.live.localChanged(id)
            // Recreated once a pass has seen it missing, well inside the grace.
            #expect(await waitUntil { await h.live.isMissing(id) })
            try await edit(h, local, id, "rewritten by the editor")
            #expect(await waitUntil { await h.fake.contents(note) == "rewritten by the editor" })
            #expect(await h.files().count == 1)
            #expect(await waitUntil { await h.file()?.dirty == false })
            // No pass is left over from the grace to forget it.
            #expect(await settled(h))
            #expect(await h.files().count == 1)
        }
    }

    // MARK: 14–15 Discard, rename

    @Test func discardRefusesUnsyncedEditsUnlessForced() async throws {
        try await withLive("discard") { h in
            let (local, id) = try await openLive(h, note, "first")
            await h.live.setPaused(note, on: h.connection, paused: true)
            try await edit(h, local, id, "unsynced")
            #expect(await settled(h))
            #expect(await h.file()?.dirty == true)
            await #expect(throws: TransferError.liveUnsynced(1)) {
                try await h.live.discard(note, on: h.connection, force: false)
            }
            #expect(await h.files().count == 1)
            try await h.live.discard(note, on: h.connection, force: true)
            #expect(await h.files().isEmpty)
            #expect(h.store.liveFiles(connection: h.connection).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: local.deletingLastPathComponent().path))
        }
    }

    @Test func renameMovesTheRecordAndKeepsTheWorkingCopy() async throws {
        try await withLive("rename") { h in
            let path = RemotePath(string: "/srv/dir/note.txt")
            let (local, id) = try await openLive(h, path, "first")
            let folder = RemotePath(string: "/srv/dir")
            let moved = RemotePath(string: "/srv/moved")
            try await h.live.rename(folder, to: moved, on: h.connection) { await h.fake.move(folder, to: moved) }
            let inside = RemotePath(string: "/srv/moved/note.txt")
            #expect(await h.file()?.path == inside)

            let renamed = RemotePath(string: "/srv/moved/other.txt")
            try await h.live.rename(inside, to: renamed, on: h.connection) { await h.fake.move(inside, to: renamed) }
            #expect(await h.file()?.path == renamed)
            // The editor still holds the working copy under its old name, so it stays there.
            #expect(FileManager.default.fileExists(atPath: local.path))
            #expect(!FileManager.default.fileExists(atPath: local.deletingLastPathComponent().appendingPathComponent("other.txt").path))

            // The editor's next save, to the name it opened, goes to the new remote path.
            try await edit(h, local, id, "after rename")
            #expect(await waitUntil { await h.fake.contents(renamed) == "after rename" })
            #expect(await h.fake.contents(path) == nil)
            #expect(await h.fake.contents(inside) == nil)

            let ran = Locked(false)
            try await h.live.rename(RemotePath(string: "/srv/elsewhere"), to: RemotePath(string: "/srv/else2"), on: h.connection) { ran.value = true }
            #expect(ran.value)
            #expect(await h.file()?.path == renamed)
        }
    }

    /// A rename that arrives while a Live open of a file under it is still downloading waits for
    /// that open, so the record follows the rename instead of keeping the old path.
    @Test func renameWaitsForAnOpenInFlight() async throws {
        try await withLive("rename-open") { h in
            let path = RemotePath(string: "/srv/dir/note.txt")
            await h.fake.put(path, "first", mtime: Self.serverNow)
            await h.fake.holdFetches()
            let opening = Task { try await h.live.open(path, on: h.connection) }
            #expect(await waitUntil { await h.fake.heldFetches == 1 })

            let folder = RemotePath(string: "/srv/dir")
            let moved = RemotePath(string: "/srv/moved")
            let ran = Locked(false)
            let renaming = Task {
                try await h.live.rename(folder, to: moved, on: h.connection) {
                    ran.value = true
                    await h.fake.move(folder, to: moved)
                }
            }
            await pause(150)
            #expect(!ran.value)
            await h.fake.releaseFetches()
            let local = try await opening.value
            try await renaming.value
            #expect(ran.value)

            let inside = RemotePath(string: "/srv/moved/note.txt")
            let file = try #require(await h.file())
            #expect(file.path == inside)
            try await edit(h, local, file.id, "after rename")
            #expect(await waitUntil { await h.fake.contents(inside) == "after rename" })
            #expect(await h.fake.contents(path) == nil)
        }
    }

    // MARK: 16–17 Relaunch, reopen

    @Test func conflictAndFlagsSurviveRelaunch() async throws {
        try await withLive("relaunch") { h in
            _ = try await conflicted(h, server: "theirs", local: "mine")
            await h.live.setPaused(note, on: h.connection, paused: true)
            let before = try #require(await h.file())
            #expect(before.conflict && before.dirty && before.paused)
            await h.live.closeAll()

            let again = LiveSync(store: h.store, watches: false)
            let after = try #require(await again.files(on: h.connection).first)
            #expect(after.path == note)
            #expect(after.conflict)
            #expect(after.dirty)
            #expect(after.paused)
            #expect(await again.unsyncedCount(on: h.connection) == 1)
            await again.closeAll()
        }
    }

    @Test func reopenRefreshesAnUntouchedCopy() async throws {
        try await withLive("reopen") { h in
            let (local, _) = try await openLive(h, note, "first")
            await h.fake.changeBehind(note, "newer on server")
            let again = try await h.live.open(note, on: h.connection)
            #expect(again == local)
            #expect(read(local) == "newer on server")
            #expect(await h.file()?.dirty == false)
            #expect(await h.file()?.conflict == false)
            #expect(await settled(h))
            #expect(await h.fake.saves == 0)
        }
    }

    @Test func reopenKeepsAnEditedCopy() async throws {
        try await withLive("reopen-edited") { h in
            let (local, _) = try await openLive(h, note, "first")
            try Data("local edit".utf8).write(to: local)
            await h.fake.changeBehind(note, "newer on server")
            let again = try await h.live.open(note, on: h.connection)
            #expect(again == local)
            #expect(read(local) == "local edit")
            // Open looks at the edit, and the pass it schedules finds the server moved on.
            #expect(await waitUntil { await raised(h) })
            #expect(read(local) == "local edit")
            #expect(read(serverCopy(local)) == "newer on server")
            #expect(await h.fake.contents(note) == "newer on server")
            #expect(await h.fake.saves == 0)
        }
    }

    // MARK: From the independent review

    @Test func aReplacedConnectionCannotTakeTheServerAway() async throws {
        try await withLive("stale") { h in
            let (local, id) = try await openLive(h, note, "first")
            // An older connection object for the same server disconnects on its own.
            await h.live.disconnected(h.connection, server: FakeServer())
            try await edit(h, local, id, "still uploads")
            #expect(await waitUntil { await h.fake.contents(note) == "still uploads" })
        }
    }

    @Test func anEditNoPassHasSeenStillCountsAsUnsynced() async throws {
        try await withLive("unsynced") { h in
            let (local, _) = try await openLive(h, note, "first")
            #expect(await h.live.unsyncedCount(on: h.connection) == 0)
            try Data("typed but not yet seen".utf8).write(to: local)
            #expect(await h.live.unsyncedCount(on: h.connection) == 1)
            #expect(await h.live.unsyncedCount() == 1)
        }
    }

    @Test func aWaitingRowClearsWhenTheFileNoLongerWaits() async throws {
        try await withLive("waiting") { h in
            let (local, id) = try await openLive(h, note, "first")
            let states = { h.fake.events.compactMap { event -> OperationState? in
                if case .operation(let operation) = event, operation.livePath == note { return operation.state }
                return nil
            } }
            await h.live.disconnected(h.connection, server: h.fake)
            try await edit(h, local, id, "while away")
            #expect(await waitUntil { states().last == .queued })
            // Edited again while still offline: the row stays, it does not flicker off and back.
            let before = states().count
            try await edit(h, local, id, "while away, twice")
            #expect(await waitUntil { states().count > before })
            #expect(!states()[before...].contains(.succeeded))
            // Put back offline: the next pass needs no server and uploads nothing, yet the row goes.
            try await edit(h, local, id, "first")
            #expect(await waitUntil { states().last == .succeeded })
            #expect(await waitUntil { await h.file()?.dirty == false })
            // Waiting again, then login: the row goes before the upload.
            try await edit(h, local, id, "while away again")
            #expect(await waitUntil { states().last == .queued })
            await h.live.connected(h.connection, server: h.fake)
            #expect(await waitUntil { await h.fake.contents(note) == "while away again" })
            #expect(await h.fake.saves == 1)
        }
    }

    // MARK: Retries (LIVE-01)

    /// Every upload reads its snapshot, and the watcher reports that read as a change of the
    /// working copy. That echo used to reset the attempts and schedule a pass 350 ms out, so a save
    /// that kept timing out was retried about every 0.4 s, forever.
    @Test func aFailingSaveBacksOffDespiteItsOwnEcho() async throws {
        try await withLive("backoff") { h in
            let (local, id) = try await openLive(h, note, "first")
            await h.fake.setSaveError(TransferError.timeout("the test's server"))
            // The watcher's echo, a little after each attempt.
            await h.fake.setOnSave { _ in
                Task {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    await h.live.localChanged(id)
                }
            }
            try await edit(h, local, id, "cannot upload yet")
            #expect(await waitUntil(8) { await h.fake.saveTimes.count >= 3 })
            let times = await h.fake.saveTimes
            try #require(times.count >= 3)
            #expect(times[1].timeIntervalSince(times[0]) >= 0.9)
            #expect(times[2].timeIntervalSince(times[1]) >= 1.9)
            #expect(await h.file()?.dirty == true)
        }
    }

    // MARK: Removal and discard (LIVE-02, LIVE-04, CLIP-03)

    @Test func removingAFolderAboveUnsyncedEditsRefusesAndRemovesNothing() async throws {
        try await withLive("remove-unsynced") { h in
            let (local, id) = try await openLive(h, note, "first")
            await h.live.setPaused(note, on: h.connection, paused: true)
            try await edit(h, local, id, "unsynced edit")
            #expect(await settled(h))
            let folder = RemotePath(string: "/srv")
            let ran = Locked(false)
            await #expect(throws: TransferError.liveUnsynced(1)) {
                try await h.live.remove(folder, on: h.connection) { ran.value = true }
            }
            #expect(!ran.value)
            #expect(read(local) == "unsynced edit")
            #expect(await h.files().count == 1)
            // The user chose to discard those edits.
            try await h.live.remove(folder, on: h.connection, force: true) {
                ran.value = true
                await h.fake.delete(RemotePath(string: "/srv/note.txt"))
            }
            #expect(ran.value)
            #expect(await h.files().isEmpty)
            #expect(h.store.liveFiles(connection: h.connection).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: local.deletingLastPathComponent().path))
        }
    }

    @Test func removingAFolderAboveAnEditNoPassHasSeenRefuses() async throws {
        try await withLive("remove-unseen") { h in
            let (local, _) = try await openLive(h, note, "first")
            try Data("saved, not yet seen".utf8).write(to: local)
            await #expect(throws: TransferError.liveUnsynced(1)) {
                try await h.live.remove(RemotePath(string: "/srv"), on: h.connection) {}
            }
            #expect(read(local) == "saved, not yet seen")
            #expect(await h.files().count == 1)
        }
    }

    @Test func removingAFolderAboveSyncedCopiesForgetsThem() async throws {
        try await withLive("remove-synced") { h in
            let (local, _) = try await openLive(h, note, "first")
            try await h.live.remove(RemotePath(string: "/srv"), on: h.connection) { await h.fake.delete(RemotePath(string: "/srv/note.txt")) }
            #expect(await h.files().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: local.deletingLastPathComponent().path))
        }
    }

    /// An editor save that lands while the removal runs on the server is kept, as a file removed
    /// from the server, and Keep Local puts it back.
    @Test func anEditSavedDuringARemovalIsKeptAsRemovedFromTheServer() async throws {
        try await withLive("remove-race") { h in
            let (local, _) = try await openLive(h, note, "first")
            try await h.live.remove(RemotePath(string: "/srv"), on: h.connection) {
                await h.fake.delete(RemotePath(string: "/srv/note.txt"))
                try? Data("saved during the removal".utf8).write(to: local)
            }
            #expect(read(local) == "saved during the removal")
            #expect(await raised(h))
            #expect(await h.file()?.dirty == true)
            #expect(h.store.liveFiles(connection: h.connection).first?.conflict == "removed")
            try await h.live.resolve(note, on: h.connection, choice: .keepLocal)
            #expect(await h.fake.contents(note) == "saved during the removal")
            #expect(await h.file()?.conflict == false)
        }
    }

    /// "Forget All Synced Live Files" discards every file the shelf shows clean, which an edit
    /// saved a moment ago can still be: discard must see it.
    @Test func discardRefusesAnEditNoPassHasSeen() async throws {
        try await withLive("discard-unseen") { h in
            let (local, _) = try await openLive(h, note, "first")
            try Data("typed and saved, no pass yet".utf8).write(to: local)
            #expect(await h.file()?.dirty == true)
            await #expect(throws: TransferError.liveUnsynced(1)) {
                try await h.live.discard(note, on: h.connection, force: false)
            }
            #expect(read(local) == "typed and saved, no pass yet")
            #expect(await h.files().count == 1)
        }
    }

    @Test func removeServerRefusesUnsyncedEditsInOneStep() async throws {
        try await withLive("close-unsynced") { h in
            let (local, id) = try await openLive(h, note, "first")
            try Data("not yet uploaded".utf8).write(to: local)
            await #expect(throws: TransferError.liveUnsynced(1)) { try await h.live.closeIfSynced(h.connection) }
            #expect(await h.files().count == 1)
            await h.live.localChanged(id)
            #expect(await waitUntil { await h.fake.contents(note) == "not yet uploaded" })
            #expect(await waitUntil { await h.file()?.dirty == false })
            try await h.live.closeIfSynced(h.connection)
            #expect(await h.files().isEmpty)
        }
    }

    // MARK: Conflict choices under a save (LIVE-03, LIVE-21)

    @Test func keepBothKeepsASaveMadeDuringItsUpload() async throws {
        try await withLive("keepboth-race") { h in
            let (local, _) = try await conflicted(h, server: "theirs", local: "mine")
            await h.fake.setOnSave { path in
                if path.name.hasSuffix("(from this Mac).txt") { try? Data("mine, saved again".utf8).write(to: local) }
            }
            await #expect(throws: (any Error).self) {
                try await h.live.resolve(note, on: h.connection, choice: .keepBoth)
            }
            #expect(read(local) == "mine, saved again")
            #expect(await h.fake.contents(RemotePath(string: "/srv/note (from this Mac).txt")) == "mine")
            #expect(await h.fake.contents(note) == "theirs")
            #expect(await h.file()?.conflict == true)
            #expect(await h.file()?.dirty == true)
        }
    }

    @Test func keepRemoteKeepsASaveMadeDuringItsDownload() async throws {
        try await withLive("keepremote-race") { h in
            let (local, _) = try await conflicted(h, server: "theirs", local: "mine")
            await h.fake.holdFetches()
            let resolving = Task { try await h.live.resolve(note, on: h.connection, choice: .keepRemote) }
            #expect(await waitUntil { await h.fake.heldFetches == 1 })
            try Data("mine, saved again".utf8).write(to: local)
            await h.fake.releaseFetches()
            await #expect(throws: (any Error).self) { try await resolving.value }
            #expect(read(local) == "mine, saved again")
            #expect(await h.file()?.conflict == true)
        }
    }

    @Test func keepBothWhenTheServerFileIsGoneUploadsTheSiblingAndForgets() async throws {
        try await withLive("keepboth-gone") { h in
            let (local, id) = try await openLive(h, note, "first")
            await h.fake.delete(note)
            try await edit(h, local, id, "mine")
            #expect(await waitUntil { await raised(h) })
            try await h.live.resolve(note, on: h.connection, choice: .keepBoth)
            #expect(await h.fake.contents(RemotePath(string: "/srv/note (from this Mac).txt")) == "mine")
            #expect(await h.files().isEmpty)
        }
    }

    @Test func keepLocalOverSomethingThatIsNotAFileRefuses() async throws {
        try await withLive("keeplocal-folder") { h in
            let (local, id) = try await openLive(h, note, "first")
            await h.fake.putFolder(note)
            try await edit(h, local, id, "mine")
            #expect(await waitUntil { await raised(h) })
            await #expect(throws: TransferError.typeMismatch(note.display)) {
                try await h.live.resolve(note, on: h.connection, choice: .keepLocal)
            }
            #expect(await h.fake.saves == 0)
            #expect(await h.file()?.conflict == true)
        }
    }

    @Test func aFailedServerCopyFetchLeavesNoOutdatedCopy() async throws {
        try await withLive("stale-copy") { h in
            let (local, _) = try await conflicted(h, server: "theirs", local: "mine")
            #expect(read(serverCopy(local)) == "theirs")
            await h.fake.changeBehind(note, "theirs again")
            await h.fake.setFailingFetches(true)
            await #expect(throws: (any Error).self) {
                try await h.live.resolve(note, on: h.connection, choice: .keepLocal)
            }
            #expect(!FileManager.default.fileExists(atPath: serverCopy(local).path))
            #expect(await h.file()?.conflict == true)
        }
    }

    // MARK: Uploading only settled bytes (LIVE-05)

    /// An in-place writer that starts while the pass looks the server up, as a chunked writer's
    /// first chunk: those bytes are uploaded only once they have held still for the settle time,
    /// never straight after the lookup, when the writer may be about to write the rest.
    @Test func aWriteDuringTheLookupWaitsToSettle() async throws {
        try await withLive("mid-lookup") { h in
            let (local, id) = try await openLive(h, note, "first")
            try Data("complete edit".utf8).write(to: local)
            let written = Locked<Date?>(nil)
            await h.fake.setOnLookup {
                guard written.value == nil else { return }
                try? Data("PART".utf8).write(to: local)
                written.value = Date()
            }
            await h.live.localChanged(id)
            #expect(await waitUntil { await h.fake.contents(note) == "PART" })
            let saved = try #require(await h.fake.saveTimes.first)
            let wrote = try #require(written.value)
            #expect(saved.timeIntervalSince(wrote) >= 0.3, "uploaded \(saved.timeIntervalSince(wrote)) s after the write")
            #expect(await h.fake.savedContents == ["PART"])
        }
    }

    // MARK: Adopting only our own upload (LIVE-09)

    /// Someone else's file with the edit's size and second used to be taken as our own save, and
    /// the edit was marked synced without ever uploading.
    @Test func aServerFileThatOnlyLooksLikeTheEditIsAConflict() async throws {
        try await withLive("lookalike") { h in
            let (local, id) = try await openLive(h, note, "first")
            let second = floor(Date().timeIntervalSince1970)
            try Data("mine!".utf8).write(to: local)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: second + 0.3)], ofItemAtPath: local.path)
            await h.fake.put(note, "their", mtime: UInt32(second))
            await h.live.localChanged(id)
            #expect(await waitUntil { await raised(h) })
            #expect(await h.fake.saves == 0)
            #expect(await h.fake.contents(note) == "their")
            #expect(read(local) == "mine!")
        }
    }

    @Test func aSaveWhoseReplyWasLostIsAdoptedNotSentAgain() async throws {
        try await withLive("lost-reply") { h in
            let (local, id) = try await openLive(h, note, "first")
            await h.fake.landNextSaveThenFail()
            try await edit(h, local, id, "mine")
            #expect(await waitUntil { await h.file().map { !$0.dirty && !$0.conflict } == true })
            #expect(await settled(h))
            #expect(await h.fake.saveTimes.count == 1)
            #expect(await h.fake.contents(note) == "mine")
            #expect(await h.file()?.conflict == false)
        }
    }

    // MARK: Refreshing beside an editor (LIVE-06)

    /// An NSDocument editor holding the copy is told before a refresh replaces it. One that saves
    /// its unsaved text first keeps it: the refresh does not happen, and the save meets the
    /// server's newer file as a conflict.
    @Test func reopenTellsAnEditorFirstAndKeepsWhatItSaves() async throws {
        try await withLive("reopen-editor") { h in
            let (local, _) = try await openLive(h, note, "first")
            await h.fake.changeBehind(note, "newer on server")
            let editor = SavingEditor(local, saves: "unsaved typing")
            NSFileCoordinator.addFilePresenter(editor)
            defer { NSFileCoordinator.removeFilePresenter(editor) }
            _ = try await h.live.open(note, on: h.connection)
            #expect(editor.relinquished.value)
            #expect(read(local) == "unsaved typing")
            #expect(await waitUntil { await raised(h) })
            #expect(read(serverCopy(local)) == "newer on server")
            #expect(await h.fake.saves == 0)
        }
    }

    // MARK: Without the watcher (LIVE-20)

    @Test func pollingUploadsEditsWhenTheFolderCannotBeWatched() async throws {
        try await withLive("polling") { h in
            await h.live.startPolling(every: .milliseconds(100))
            let (local, _) = try await openLive(h, note, "first")
            try Data("seen by the poll".utf8).write(to: local)
            #expect(await waitUntil { await h.fake.contents(note) == "seen by the poll" })
            #expect(await waitUntil { await h.file()?.dirty == false })
        }
    }

    // MARK: Launch (LIVE-22, LIVE-23)

    @Test func aCopyIdleForADayExpiresAtLaunchUnlessItHoldsEdits() async throws {
        try await withLive("expiry") { h in
            let other = RemotePath(string: "/srv/other.txt")
            let (synced, _) = try await openLive(h, note, "first")
            let (edited, _) = try await openLive(h, other, "first")
            // Same size, so only the bytes tell: one is untouched, one holds an edit no pass saw.
            try Data("fir5t".utf8).write(to: edited)
            let old = Date().addingTimeInterval(-2 * LiveSync.expiry)
            for url in [synced, edited, synced.deletingLastPathComponent(), edited.deletingLastPathComponent()] {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            }
            await h.live.closeAll()

            let again = LiveSync(store: h.store, watches: false)
            let files = await again.files(on: h.connection)
            #expect(files.map(\.path) == [other])
            #expect(files.first?.dirty == true)
            #expect(!FileManager.default.fileExists(atPath: synced.deletingLastPathComponent().path))
            #expect(read(edited) == "fir5t")
            await again.closeAll()
        }
    }

    @Test func aGoneCopyWithEditsIsReportedAndACleanOneLeavesNoFolder() async throws {
        try await withLive("gone") { h in
            let other = RemotePath(string: "/srv/other.txt")
            let (dirty, dirtyID) = try await openLive(h, note, "first")
            let (clean, _) = try await openLive(h, other, "first")
            await h.live.setPaused(note, on: h.connection, paused: true)
            try await edit(h, dirty, dirtyID, "edited")
            #expect(await settled(h))
            await h.live.closeAll()
            try FileManager.default.removeItem(at: dirty)
            try FileManager.default.removeItem(at: clean)

            let again = LiveSync(store: h.store, watches: false)
            let fake = FakeServer()
            await again.connected(h.connection, server: fake)
            #expect(await again.files(on: h.connection).isEmpty)
            #expect(fake.events.contains { if case .notice(let text) = $0 { text.contains(note.display) } else { false } })
            #expect(!fake.events.contains { if case .notice(let text) = $0 { text.contains(other.display) } else { false } })
            #expect(!FileManager.default.fileExists(atPath: clean.deletingLastPathComponent().path))
            await again.closeAll()
        }
    }

    // MARK: The worker and the watcher

    @Test func closingCancelsQueuedCommands() async throws {
        try await withLive("close-queued") { h in
            await h.fake.put(note, "first", mtime: Self.serverNow)
            await h.fake.holdFetches()
            let opening = Task { try await h.live.open(note, on: h.connection) }
            #expect(await waitUntil { await h.fake.heldFetches == 1 })
            let discarding = Task { try await h.live.discard(note, on: h.connection, force: false) }
            // The open runs and the discard waits behind it.
            #expect(await waitUntil { await h.live.workCount(on: h.connection) == 2 })
            await h.live.close(h.connection)
            await #expect(throws: TransferError.cancelled) { try await discarding.value }
            await h.fake.releaseFetches()
            _ = try? await opening.value
        }
    }

    @Test func watcherPathsAreSplitUnderTheRealRoot() throws {
        let base = TestCaches.fresh("watcher")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let watcher = try #require(LiveWatcher(root: base))
        defer { watcher.stop() }
        #expect(watcher.components(of: watcher.root + "/conn/file/note.txt") == ["conn", "file", "note.txt"])
        #expect(watcher.components(of: watcher.root + "sibling/conn") == nil)
        #expect(watcher.components(of: "/elsewhere/conn/file") == nil)
    }
}

/// An NSDocument-like editor with unsaved text: asked to let a writer in, it saves first.
private final class SavingEditor: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let text: String
    let relinquished = Locked(false)

    init(_ url: URL, saves text: String) {
        presentedItemURL = url
        self.text = text
    }

    func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        relinquished.value = true
        if let url = presentedItemURL { try? Data(text.utf8).write(to: url) }
        writer(nil)
    }
}

// MARK: - Fake server

/// An in-memory server keyed by path. Files carry whole-second mtimes, as SFTP does.
actor FakeServer: LiveServer {
    struct File {
        var data: Data
        var mtime: UInt32
        var kind = ItemKind.file
        var print: Fingerprint { Fingerprint(size: UInt64(data.count), mtime: mtime) }
    }

    private var files: [RemotePath: File] = [:]
    /// Saves that landed, and the bytes each put there.
    private(set) var saves = 0
    private(set) var savedContents: [String] = []
    /// When each save was attempted, landed or not.
    private(set) var saveTimes: [Date] = []
    private(set) var lookups = 0
    private var failing = false
    private var failingFetches = false
    private var saveError: Error?
    private var landThenFail = false
    private var onSave: (@Sendable (RemotePath) async -> Void)?
    private var onLookup: (@Sendable () async -> Void)?
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private let log = Locked<[SessionEvent]>([])

    // Knobs

    func put(_ path: RemotePath, _ text: String, mtime: UInt32) {
        files[path] = File(data: Data(text.utf8), mtime: mtime)
    }

    /// Someone puts a folder where the file was.
    func putFolder(_ path: RemotePath) {
        files[path] = File(data: Data(), mtime: UInt32(Date().timeIntervalSince1970), kind: .directory)
    }

    /// Every save throws `error` before it lands.
    func setSaveError(_ error: Error?) { saveError = error }

    /// The next save lands, and then its reply is lost: it throws a timeout.
    func landNextSaveThenFail() { landThenFail = true }

    func setFailingFetches(_ failing: Bool) { failingFetches = failing }

    /// Runs inside each save attempt, after it landed if it lands.
    func setOnSave(_ hook: (@Sendable (RemotePath) async -> Void)?) { onSave = hook }

    /// Runs inside each lookup, before it answers.
    func setOnLookup(_ hook: (@Sendable () async -> Void)?) { onLookup = hook }

    /// Someone else writes the file: new bytes and a later mtime.
    func changeBehind(_ path: RemotePath, _ text: String) {
        let mtime = max(files[path]?.mtime ?? 0, UInt32(Date().timeIntervalSince1970)) + 60
        files[path] = File(data: Data(text.utf8), mtime: mtime)
    }

    func delete(_ path: RemotePath) { files[path] = nil }

    func setFailing(_ failing: Bool) { self.failing = failing }

    /// Fetches read the server's bytes, then wait for `releaseFetches` before writing them.
    func holdFetches() { holding = true }

    var heldFetches: Int { held.count }

    func releaseFetches() {
        holding = false
        for fetch in held { fetch.resume() }
        held.removeAll()
    }

    func contents(_ path: RemotePath) -> String? {
        files[path].map { String(decoding: $0.data, as: UTF8.self) }
    }

    func move(_ source: RemotePath, to destination: RemotePath) {
        for (path, file) in files {
            guard let moved = path.replacing(prefix: source, with: destination) else { continue }
            files[path] = nil
            files[moved] = file
        }
    }

    nonisolated var events: [SessionEvent] { log.value }
    nonisolated var conflicts: [RemotePath] {
        events.compactMap { if case .conflict(let path, _) = $0 { path } else { nil } }
    }
    nonisolated var failures: [String] {
        events.compactMap { if case .operation(let op) = $0, op.state == .failed { op.message ?? "" } else { nil } }
    }

    // LiveServer

    func liveLookup(_ path: RemotePath) async throws -> RemoteItem? {
        lookups += 1
        await onLookup?()
        if failing { throw TransferError.connectionLost("fake server unreachable") }
        guard let file = files[path] else { return nil }
        return RemoteItem(path: path, kind: file.kind, size: UInt64(file.data.count), mtime: file.mtime)
    }

    func liveFetch(_ item: RemoteItem, to local: URL, interactive: Bool) async throws {
        if failing || failingFetches { throw TransferError.connectionLost("fake server unreachable") }
        guard let file = files[item.path] else { throw TransferError.noSuchFile(item.path.display) }
        if holding { await withCheckedContinuation { held.append($0) } }
        let temp = local.deletingLastPathComponent().appendingPathComponent(".fetch-\(UUID().uuidString)")
        try file.data.write(to: temp)
        let mtime = TimeInterval(item.mtime ?? file.mtime)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: temp.path)
        guard Darwin.rename(temp.path, local.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw TransferError.failed("rename failed: \(errno)")
        }
    }

    func liveSave(_ snapshot: URL, to path: RemotePath, expecting: ServerExpectation, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> Fingerprint {
        saveTimes.append(Date())
        if failing { throw TransferError.connectionLost("fake server unreachable") }
        if let saveError {
            await onSave?(path)
            throw saveError
        }
        let data = try Data(contentsOf: snapshot)
        let date = try FileManager.default.attributesOfItem(atPath: snapshot.path)[.modificationDate] as? Date ?? Date()
        let written = File(data: data, mtime: UInt32(date.timeIntervalSince1970))
        let now = files[path]
        let matches = switch expecting {
        case .file(let print): now?.print == print
        case .absent: now == nil
        }
        // A save that already landed finds its own bytes there.
        let ownBytes = now.map { $0.data == data && $0.print == written.print } ?? false
        if !matches, !ownBytes { throw LiveRemoteChanged() }
        files[path] = written
        saves += 1
        savedContents.append(String(decoding: data, as: UTF8.self))
        await onSave?(path)
        if landThenFail {
            landThenFail = false
            throw TransferError.timeout("the reply was lost")
        }
        progress(TransferProgress(completed: UInt64(data.count), total: UInt64(data.count)))
        return written.print
    }

    func liveNames(in folder: RemotePath) async throws -> Set<String> {
        if failing { throw TransferError.connectionLost("fake server unreachable") }
        return Set(files.keys.filter { $0.parent == folder }.map(\.name))
    }

    nonisolated func liveEmit(_ event: SessionEvent) {
        log.withLock { $0.append(event) }
    }
}
