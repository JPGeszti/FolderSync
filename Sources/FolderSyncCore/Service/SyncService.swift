import CoreServices
import Foundation

/// Grants temporary access to a pair's folders (security-scoped bookmarks in the app; plain paths
/// in tests) for the duration of `body`.
public protocol FolderAccess: Sendable {
    func withAccess<T>(to pair: FolderPair, _ body: (_ source: String, _ destination: String) throws -> T) throws -> T
}

public struct PlainPathAccess: FolderAccess {
    public init() {}
    public func withAccess<T>(to pair: FolderPair, _ body: (String, String) throws -> T) throws -> T {
        try body(pair.sourcePath, pair.destinationPath)
    }
}

/// Serializes work per folder pair and keeps maintenance (garbage collection) from overlapping
/// with synchronization. Heavy work runs off the actor on detached tasks so the UI stays responsive.
public actor SyncService {
    public let storage: FolderSyncStorage
    let access: FolderAccess
    private var running: Set<UUID> = []
    private var maintenanceRunning = false

    public init(storage: FolderSyncStorage, access: FolderAccess) {
        self.storage = storage
        self.access = access
    }

    public func isRunning(_ pair: UUID) -> Bool { running.contains(pair) }
    public var runningPairs: Set<UUID> { running }

    public func synchronize(_ pair: FolderPair, options: SyncOptions = SyncOptions()) async throws -> SyncReport {
        guard !running.contains(pair.id), !maintenanceRunning else { throw SyncError.busy }
        running.insert(pair.id)
        defer { running.remove(pair.id) }
        let engine = storage.engine
        let access = self.access
        let report = try await Task.detached(priority: options.dryRun ? .userInitiated : .utility) {
            try access.withAccess(to: pair) { src, dst in
                try engine.synchronize(pair: pair, source: src, destination: dst, options: options)
            }
        }.value
        if report.commit != nil, !options.dryRun {
            try? storage.backupDatabase()
        }
        return report
    }

    /// Retention for every pair, then garbage collection, only while no sync is running.
    public func runMaintenance() async throws -> (pruned: Int, collected: Int) {
        guard running.isEmpty, !maintenanceRunning else { throw SyncError.busy }
        maintenanceRunning = true
        defer { maintenanceRunning = false }
        let storage = self.storage
        return try await Task.detached(priority: .background) {
            let m = Maintenance(storage: storage)
            var pruned = 0
            for pair in try storage.catalog.pairs() { pruned += try m.applyRetention(pair: pair).versionsPruned }
            let collected = try m.collectGarbage()
            return (pruned, collected)
        }.value
    }

    public func verifyStore() async -> [String: String] {
        let storage = self.storage
        return await Task.detached(priority: .utility) { Maintenance(storage: storage).verifyStore() }.value
    }
}

/// Event-driven change monitoring with FSEvents and debouncing.
///
/// Events are only a *trigger*: every run still performs a full metadata reconciliation, because
/// FSEvents may coalesce or drop events (e.g. `kFSEventStreamEventFlagMustScanSubDirs`).
/// No polling happens while the folder is idle.
public final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.foldersync.fsevents", qos: .utility)
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval
    private let handler: @Sendable () -> Void

    public init(path: String, debounce: TimeInterval = 3, handler: @escaping @Sendable () -> Void) {
        self.debounce = debounce
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [handler] in handler() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    public func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
        }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit { stop() }
}
