import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// Downloads against the local sshd where a server's links and names meet what the Mac already
/// has: nothing outside the chosen folder is written, and nothing already there is removed or
/// replaced without the operation's prompt. Serialized: each test logs in, and more logins at once
/// than the local sshd's MaxStartups (10) drops some.
@Suite(.serialized, .enabled(if: ServerHarness.available, "needs the local sshd from Scripts/local-sshd.sh"))
struct PlacementServerTests {
    /// A remote link over a local folder of the same name deleted the whole folder (SEC-4, SES-01).
    @Test func aLinkNeverReplacesALocalFolder() async throws {
        try await withHarness("linkdir", connected: true) { h in
            let elsewhere = h.remote.appendingPathComponent("elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: h.remote.appendingPathComponent("Projects").path, withDestinationPath: "elsewhere")
            let downloads = h.staging.appendingPathComponent("Downloads")
            let main = downloads.appendingPathComponent("Projects/app/src/main.swift")
            try FileManager.default.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("main".utf8).write(to: main)

            let projects = h.remotePath.appending(name: Array("Projects".utf8))
            await #expect(throws: TransferError.typeMismatch("Projects")) {
                try await h.session.download(projects, to: downloads.appendingPathComponent("Projects")) { _ in }
            }
            #expect(try Data(contentsOf: main) == Data("main".utf8))

            // Inside a folder download, too.
            let docs = h.remote.appendingPathComponent("dl")
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: docs.appendingPathComponent("Projects").path, withDestinationPath: "../elsewhere")
            await #expect(throws: TransferError.self) {
                try await h.session.download(h.remotePath.appending(name: Array("dl".utf8)), to: downloads) { _ in }
            }
            #expect(try Data(contentsOf: main) == Data("main".utf8))
            #expect(h.prompts.collisions == 0)
        }
    }

    /// A remote link over a local file is a collision like any other: asked, and replaced only on Replace.
    @Test func aLinkOverAFileIsAsked() async throws {
        try await withHarness("linkfile", connected: true) { h in
            try FileManager.default.createSymbolicLink(atPath: h.remote.appendingPathComponent("latest").path, withDestinationPath: "v2")
            let latest = h.remotePath.appending(name: Array("latest".utf8))
            let local = h.staging.appendingPathComponent("latest")
            try Data("mine".utf8).write(to: local)

            await OperationPrompts.$current.withValue(nil) {
                await #expect(throws: TransferError.self) { try await h.session.download(latest, to: local) { _ in } }
            }
            #expect(try Data(contentsOf: local) == Data("mine".utf8))

            try await h.session.download(latest, to: local) { _ in }
            #expect(h.prompts.collisions == 1)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: local.path) == "v2")

            // The same link again is already there: nothing asked.
            try await h.session.download(latest, to: local) { _ in }
            #expect(h.prompts.collisions == 1)
        }
    }

    /// A stock server: `site/cur` was a link out of the download folder on the first download,
    /// then became a real folder. The second download wrote through the stale local link (SEC-3).
    @Test func aStaleLocalLinkIsNeverWrittenThrough() async throws {
        try await withHarness("stale", connected: true) { h in
            let victim = h.staging.appendingPathComponent("victim")
            try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
            let site = h.remote.appendingPathComponent("site")
            try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
            try Data("index".utf8).write(to: site.appendingPathComponent("index.html"))
            try FileManager.default.createSymbolicLink(atPath: site.appendingPathComponent("cur").path, withDestinationPath: victim.path)
            let remoteSite = h.remotePath.appending(name: Array("site".utf8))
            let local = h.staging.appendingPathComponent("Downloads/site")

            try await h.session.download(remoteSite, to: local) { _ in }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: local.appendingPathComponent("cur").path) == victim.path)

            try FileManager.default.removeItem(at: site.appendingPathComponent("cur"))
            try FileManager.default.createDirectory(at: site.appendingPathComponent("cur"), withIntermediateDirectories: true)
            try Data("through".utf8).write(to: site.appendingPathComponent("cur/through.txt"))

            await OperationPrompts.$current.withValue(nil) {
                await #expect(throws: TransferError.self) { try await h.session.download(remoteSite, to: local) { _ in } }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path).isEmpty)

            // Replace swaps the link for a real folder; the link's target is untouched.
            try await h.session.download(remoteSite, to: local) { _ in }
            #expect(h.prompts.collisions == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path).isEmpty)
            #expect(try Data(contentsOf: local.appendingPathComponent("cur/through.txt")) == Data("through".utf8))
            #expect(try LocalPlacement.occupant(local.appendingPathComponent("cur")) == .folder)
        }
    }

    /// The download's own destination may already be a link, left by the user or an earlier copy.
    @Test func aLinkAtTheDestinationIsNeverFollowed() async throws {
        try await withHarness("destlink", connected: true) { h in
            let victim = h.staging.appendingPathComponent("victim")
            try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
            let site = h.remote.appendingPathComponent("site")
            try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
            try Data("index".utf8).write(to: site.appendingPathComponent("index.html"))
            let local = h.staging.appendingPathComponent("site")
            try FileManager.default.createSymbolicLink(atPath: local.path, withDestinationPath: victim.path)

            await OperationPrompts.$current.withValue(nil) {
                await #expect(throws: TransferError.self) {
                    try await h.session.download(h.remotePath.appending(name: Array("site".utf8)), to: local) { _ in }
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path).isEmpty)
        }
    }
}
