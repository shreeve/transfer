import CoreServices
import Foundation

/// One FSEvents stream over the Live root. It watches paths, not inodes, so a safe-save that
/// replaces a working copy needs no re-arming. Every event is only a hint to look at that file
/// again: FSEvents groups events and carries flags over from earlier ones, so neither the count
/// nor the flags mean anything. When events were dropped, it asks for everything to be looked at.
final class LiveWatcher: @unchecked Sendable {
    enum Signal: Sendable {
        case changed([String])
        case rescan
    }

    let signals: AsyncStream<Signal>
    /// The root as FSEvents reports it: symlinks resolved.
    let root: String
    private let continuation: AsyncStream<Signal>.Continuation
    private let queue = DispatchQueue(label: "transfer.live.watcher")
    private var stream: FSEventStreamRef?

    init?(root url: URL) {
        (signals, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        // FSEvents reports real paths; `resolvingSymlinksInPath` would strip `/private` instead.
        root = url.path.withCString { path in
            guard let real = realpath(path, nil) else { return url.standardizedFileURL.path }
            defer { free(real) }
            return String(cString: real)
        }
        // The stream holds the watcher for as long as it may call back; `stop` lets it go.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                if let info { _ = Unmanaged<LiveWatcher>.fromOpaque(info).retain() }
                return info
            },
            release: { info in
                if let info { Unmanaged<LiveWatcher>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<LiveWatcher>.fromOpaque(info).takeUnretainedValue()
            let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            if (0..<count).contains(where: { flags[$0] & lost != 0 }) { watcher.continuation.yield(.rescan) }
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            if !changed.isEmpty { watcher.continuation.yield(.changed(changed)) }
        }
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, options) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            stop()
            return nil
        }
    }

    /// The two path components under the root, `<connection>/<live file>`, and the rest.
    func components(of path: String) -> [String]? {
        guard path.hasPrefix(root + "/") else { return nil }
        return path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        continuation.finish()
    }
}
