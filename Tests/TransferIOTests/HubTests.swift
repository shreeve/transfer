import Foundation
import Testing
@testable import TransferIO

/// `TransferHub` with no server.
struct HubTests {
    /// A crash or force-quit leaves a login's askpass folder, host-key probe, and fingerprint scratch
    /// under the library root. The next launch removes them and nothing else.
    @Test func launchRemovesLeftoverLoginScratch() throws {
        let base = TestCaches.fresh("hub")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("library", isDirectory: true)
        let ask = root.appendingPathComponent("ask-\(UUID().uuidString)", isDirectory: true)
        let probe = root.appendingPathComponent("hostkey-\(UUID().uuidString)", isDirectory: true)
        let key = root.appendingPathComponent("key-\(UUID().uuidString)")
        let kept = root.appendingPathComponent("Live/\(UUID().uuidString)", isDirectory: true)
        for folder in [ask, probe, kept] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("#!/bin/sh\n".utf8).write(to: ask.appendingPathComponent("askpass.sh"))
        try Data("host ssh-ed25519 AAAA\n".utf8).write(to: probe.appendingPathComponent("known_hosts"))
        try Data("host ssh-ed25519 AAAA\n".utf8).write(to: key)

        _ = try TransferHub(root: root)

        #expect(!FileManager.default.fileExists(atPath: ask.path))
        #expect(!FileManager.default.fileExists(atPath: probe.path))
        #expect(!FileManager.default.fileExists(atPath: key.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("transfer.sqlite").path))
    }

    /// A library at a custom root, as in tests and development builds, keeps its caches inside
    /// that root, never in the user's `~/Library/Caches/Transfer`.
    @Test func aCustomLibraryKeepsItsCachesInside() throws {
        let base = TestCaches.fresh("cache")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("library", isDirectory: true)
        let store = try Store(root: root)
        #expect(store.cacheRoot == root.appendingPathComponent("Caches", isDirectory: true))
    }
}
