import Foundation

/// Watches repository worktrees with FSEvents and reports the root that changed,
/// so the app can refresh a repository as soon as files move underneath it.
nonisolated final class FileSystemWatcher: @unchecked Sendable {
    /// Called on a background queue with the absolute path of the watched root.
    private let onChange: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "com.commitbar.fsevents", qos: .utility)
    private let lock = NSLock()

    /// Read from the FSEvents queue, written when the repository list changes.
    private var roots: [String] = []
    private var stream: FSEventStreamRef?

    init(onChange: @escaping @Sendable (String) -> Void) {
        self.onChange = onChange
    }

    deinit {
        tearDownStream()
    }

    /// Replaces the watched set. Cheap enough to call whenever repositories change.
    func watch(roots newRoots: [String]) {
        let sorted = newRoots.sorted()
        let unchanged = lock.withLock { roots == sorted }
        guard !unchanged else { return }

        lock.withLock { roots = sorted }
        tearDownStream()
        guard !sorted.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        guard
            let stream = FSEventStreamCreate(
                nil,
                fileSystemEventsCallback,
                &context,
                sorted as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.4,
                flags
            )
        else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        lock.withLock { roots = [] }
        tearDownStream()
    }

    private func tearDownStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Called from the FSEvents queue.
    fileprivate func handle(paths: [String]) {
        let snapshot = lock.withLock { roots }
        guard !snapshot.isEmpty else { return }

        var changed: Set<String> = []
        for path in paths where Self.isRelevant(path) {
            // Longest match wins, so a repository nested inside another is attributed correctly.
            let match = snapshot
                .filter { path == $0 || path.hasPrefix($0 + "/") }
                .max(by: { $0.count < $1.count })
            if let match { changed.insert(match) }
        }

        for root in changed {
            onChange(root)
        }
    }

    /// Filters out the constant churn inside `.git` while keeping the few files
    /// that mean the branch, index or merge state actually moved.
    private static func isRelevant(_ path: String) -> Bool {
        if path.hasSuffix(".lock") { return false }

        guard let range = path.range(of: "/.git/") else {
            return true
        }

        let suffix = String(path[range.upperBound...])
        let interesting: Set<String> = [
            "HEAD", "index", "ORIG_HEAD", "MERGE_HEAD",
            "CHERRY_PICK_HEAD", "REVERT_HEAD", "packed-refs"
        ]
        if interesting.contains(suffix) { return true }
        return suffix.hasPrefix("refs/") || suffix.hasPrefix("rebase-")
    }
}

/// C callback trampoline. Must stay free of captured state to convert to a C function pointer.
private nonisolated func fileSystemEventsCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numberOfEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIdentifiers: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
    // kFSEventStreamCreateFlagUseCFTypes makes this a CFArray of CFString.
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    watcher.handle(paths: paths)
}
