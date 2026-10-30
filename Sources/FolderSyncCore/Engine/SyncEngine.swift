import Darwin
import Foundation
import os

public struct SyncOptions: Sendable {
    public var dryRun: Bool
    /// The user explicitly confirmed deletions that exceed the safety threshold.
    public var allowMassDeletion: Bool
    /// When set, only planned operations touching these relative paths are applied (user-selected
    /// changes). Everything else stays pending for a later run.
    public var limitTo: Set<String>?

    public init(dryRun: Bool = false, allowMassDeletion: Bool = false, limitTo: Set<String>? = nil) {
        self.dryRun = dryRun
        self.allowMassDeletion = allowMassDeletion
        self.limitTo = limitTo
    }
}

public struct SyncReport: Sendable {
    public var plan: SyncPlan
    public var commit: Commit?
    public var dryRun: Bool
    public var recoveredIntents: Int
    public var conflicts: [SyncConflict] { plan.conflicts }
    public var deletionBlock: DeletionBlock? { plan.deletionBlock }
}

public enum SyncError: Error, CustomStringConvertible, Equatable {
    case busy
    public var description: String { "Another synchronization of this folder pair is already running." }
}

/// Cross-process mutual exclusion for one folder pair (`flock`, released automatically if the
/// process dies, so a crash can never leave a pair permanently locked).
final class PairLock {
    private let fd: Int32

    init(directory: URL, pair: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("\(pair.uuidString).lock").path
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixFail("open", path) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw SyncError.busy
        }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Orchestrates validation → recovery → scan → plan → execute → commit for one folder pair.
public final class SyncEngine: @unchecked Sendable {
    public let catalog: Catalog
    public let store: ObjectStore
    let trash: TrashHandler
    let lockDirectory: URL
    static let log = Logger(subsystem: "app.foldersync", category: "engine")

    /// Test hook: called before each filesystem mutation with an operation label. Throwing from it
    /// simulates a crash at that exact point (the process "dies" with the journal as it is).
    var faultInjector: ((String, RelativePath) throws -> Void)?

    public init(catalog: Catalog, store: ObjectStore, trash: TrashHandler = SystemTrash(), lockDirectory: URL) {
        self.catalog = catalog
        self.store = store
        self.trash = trash
        self.lockDirectory = lockDirectory
    }

    public func preview(pair: FolderPair, source: String, destination: String) throws -> SyncReport {
        try synchronize(pair: pair, source: source, destination: destination, options: SyncOptions(dryRun: true))
    }

    public func synchronize(pair: FolderPair, source: String, destination: String, options: SyncOptions = SyncOptions()) throws -> SyncReport {
        let lock = try PairLock(directory: lockDirectory, pair: pair.id)
        defer { withExtendedLifetime(lock) {} }

        let roots = try PairValidator.validate(pair: pair, source: source, destination: destination, storeRoot: store.root.path)
        let reader = SourceReader(rootPath: roots.source, excludePatterns: pair.excludePatterns)
        let writer = DestinationWriter(rootPath: roots.destination)

        let recovered = options.dryRun ? 0 : try Recovery(engine: self).recover(pair: pair, writer: writer)

        let scan = try reader.scan()
        let planner = Planner(
            pair: pair, scan: scan,
            sourceIndex: try catalog.sourceIndex(pair.id),
            tracked: try catalog.trackedFiles(pair.id),
            trackedDirs: try catalog.trackedDirectories(pair.id),
            archivesByPath: try catalog.presentArchivesByPath(pair.id),
            overrides: try catalog.overrides(pair.id),
            destinationCaseSensitive: PairValidator.isCaseSensitive(roots.destination),
            allowMassDeletion: options.allowMassDeletion,
            destStat: { try writer.stat($0) },
            hashSource: { try reader.hash($0, expected: $1) },
            hashDestination: { try writer.hash($0) }
        )
        var plan = try planner.plan()
        if let only = options.limitTo { plan.restrict(to: only) }
        var report = SyncReport(plan: plan, commit: nil, dryRun: options.dryRun, recoveredIntents: recovered)
        if options.dryRun { return report }

        try catalog.replaceConflicts(pair.id, plan.conflicts)
        try catalog.db.transaction {
            for (p, e) in plan.indexRefresh { try catalog.setSourceIndex(pair.id, p, e) }
            for (p, t) in plan.trackedRefresh { try catalog.setTracked(pair.id, p, t) }
        }
        if let block = plan.deletionBlock { catalog.log(pair.id, .warning, "\(pair.name): \(block.message)") }
        for c in plan.conflicts { catalog.log(pair.id, .warning, "\(pair.name): conflict at \(c.path) — \(c.detail)") }

        // Directory creation needs no commit (idempotent, no content involved).
        for dir in plan.createDirectories {
            do {
                try writer.ensureDirectory(dir)
                try catalog.addTrackedDirectory(pair.id, dir)
            } catch {
                catalog.log(pair.id, .error, "\(pair.name): could not create folder \(dir.string): \(error)")
            }
        }

        let needsCommit = !plan.copies.isEmpty || !plan.renames.isEmpty || !plan.adoptions.isEmpty || !plan.vanished.isEmpty
            || !plan.archiveRelocations.isEmpty || (!plan.deletions.isEmpty && plan.deletionBlock == nil)
        if needsCommit {
            let seq = try catalog.beginCommit(pair: pair.id, kind: .sync)
            let run = Run(engine: self, pair: pair, seq: seq, reader: reader, writer: writer,
                          reservedNames: Set(scan.files.keys))
            try run.execute(plan)
            let commit = try catalog.finishCommit(seq: seq, bytes: run.bytes)
            report.commit = commit
            catalog.log(pair.id, commit.status == .success ? .info : .warning,
                        "\(pair.name): commit \(commit.shortID) \(commit.status.rawValue) — \(commit.totalChanges) changes, \(commit.failed) failed")
        }

        if plan.deletionBlock == nil {
            for dir in plan.removeDirectories {
                if (try? writer.removeDirectoryIfEmpty(dir)) != nil {
                    try? catalog.removeTrackedDirectory(pair.id, dir)
                }
            }
        }
        return report
    }

    // MARK: Shared bookkeeping (used by normal execution and crash recovery)

    func recordPublished(pair: UUID, seq: Int64, path: RelativePath, hash: String, destStat: FileStat, previous: TrackedFile?,
                         kind: ChangeKind, sourceStat: FileStat?, bytes: Int64?, note: String? = nil) throws {
        try catalog.setTracked(pair, path, TrackedFile(hash: hash, size: destStat.size, destMtimeNs: destStat.mtimeNs))
        if previous != nil { try catalog.closeVersion(pair, path, toSeq: seq) }
        try catalog.openVersion(pair, path, hash: hash, size: destStat.size, mtimeNs: destStat.mtimeNs, fromSeq: seq)
        if let st = sourceStat {
            try catalog.setSourceIndex(pair, path, SourceIndexEntry(size: st.size, mtimeNs: st.mtimeNs, inode: st.inode, hash: hash))
        }
        try catalog.addChange(FileChange(
            id: 0, commitSeq: seq, kind: kind, path: path.string, oldPath: nil, oldSize: previous?.size, newSize: destStat.size,
            oldMtimeNs: previous?.destMtimeNs, newMtimeNs: destStat.mtimeNs, oldHash: previous?.hash, newHash: hash,
            status: .applied, error: note, archivePath: nil
        ), pair: pair)
    }

    func recordRemoved(pair: UUID, seq: Int64, path: RelativePath, tracked: TrackedFile, policy: DeletionPolicy?,
                       archivePath: RelativePath?, note: String? = nil) throws {
        try catalog.removeTracked(pair, path)
        try catalog.closeVersion(pair, path, toSeq: seq)
        try catalog.removeSourceIndex(pair, path)
        let kind: ChangeKind
        if let policy {
            kind = policy == .preserveRename ? .archived : policy == .moveToTrash ? .trashed : .deleted
            try catalog.addArchive(ArchiveRecord(
                id: 0, pairID: pair, originalPath: path.string, archivePath: archivePath?.string, hash: tracked.hash,
                size: tracked.size, mtimeNs: tracked.destMtimeNs, deletedAt: Date(), commitSeq: seq, policy: policy,
                state: policy == .preserveRename ? .present : policy == .moveToTrash ? .trashed : .purged
            ))
        } else {
            kind = .untracked
        }
        try catalog.addChange(FileChange(
            id: 0, commitSeq: seq, kind: kind, path: path.string, oldPath: nil, oldSize: tracked.size, newSize: nil,
            oldMtimeNs: tracked.destMtimeNs, newMtimeNs: nil, oldHash: tracked.hash, newHash: nil, status: .applied,
            error: note, archivePath: archivePath?.string
        ), pair: pair)
    }

    func recordRenamed(pair: UUID, seq: Int64, from: RelativePath, to: RelativePath, tracked: TrackedFile, destStat: FileStat,
                       sourceStat: FileStat?, note: String? = nil) throws {
        try catalog.removeTracked(pair, from)
        try catalog.closeVersion(pair, from, toSeq: seq)
        try catalog.removeSourceIndex(pair, from)
        try catalog.setTracked(pair, to, TrackedFile(hash: tracked.hash, size: destStat.size, destMtimeNs: destStat.mtimeNs))
        try catalog.openVersion(pair, to, hash: tracked.hash, size: destStat.size, mtimeNs: destStat.mtimeNs, fromSeq: seq)
        if let st = sourceStat {
            try catalog.setSourceIndex(pair, to, SourceIndexEntry(size: st.size, mtimeNs: st.mtimeNs, inode: st.inode, hash: tracked.hash))
        }
        try catalog.addChange(FileChange(
            id: 0, commitSeq: seq, kind: .renamed, path: to.string, oldPath: from.string, oldSize: tracked.size, newSize: destStat.size,
            oldMtimeNs: tracked.destMtimeNs, newMtimeNs: destStat.mtimeNs, oldHash: tracked.hash, newHash: tracked.hash,
            status: .applied, error: note, archivePath: nil
        ), pair: pair)
    }

    /// Makes sure `hash` is in the version store, ingesting it from the destination file if needed.
    /// The bytes must hash to `hash`, otherwise the destination changed and nothing is stored.
    func ensureStored(_ hash: String, from path: RelativePath, writer: DestinationWriter) throws {
        if store.contains(hash) { return }
        let fd = try writer.openForReading(path)
        defer { fd.close() }
        try store.ingest(fd: fd.fd, pathForErrors: path.string, expectedHash: hash)
    }
}

/// Mutable state of one executing commit.
final class Run {
    let engine: SyncEngine
    let pair: FolderPair
    let seq: Int64
    let reader: SourceReader
    let writer: DestinationWriter
    let reservedNames: Set<RelativePath>
    var bytes: Int64 = 0

    init(engine: SyncEngine, pair: FolderPair, seq: Int64, reader: SourceReader, writer: DestinationWriter, reservedNames: Set<RelativePath>) {
        self.engine = engine
        self.pair = pair
        self.seq = seq
        self.reader = reader
        self.writer = writer
        self.reservedNames = reservedNames
    }

    var catalog: Catalog { engine.catalog }

    /// Throws only `InjectedCrash` (tests); real failures are recorded per operation.
    func execute(_ plan: SyncPlan) throws {
        for a in plan.archiveRelocations { try attempt(path: a.archivePath ?? a.originalPath, kind: .archiveRelocated) { try relocate(a) } }
        for r in plan.renames { try attempt(path: r.to.string, kind: .renamed, oldPath: r.from.string) { try rename(r) } }
        if plan.deletionBlock == nil {
            for d in plan.deletions { try attempt(path: d.path.string, kind: deletionKind) { try delete(d) } }
        }
        for c in plan.copies {
            let kind: ChangeKind = c.reason == .add ? .added : c.reason == .repair ? .repaired : .modified
            try attempt(path: c.path.string, kind: kind) { try copy(c) }
        }
        for a in plan.adoptions { try attempt(path: a.path.string, kind: .adopted) { try adopt(a) } }
        for v in plan.vanished {
            try attempt(path: v.path.string, kind: .untracked) {
                try catalog.db.transaction {
                    try engine.recordRemoved(pair: pair.id, seq: seq, path: v.path, tracked: v.tracked, policy: nil, archivePath: nil,
                                             note: "Missing from both source and destination")
                }
            }
        }
    }

    var deletionKind: ChangeKind {
        switch pair.effectiveDeletionPolicy {
        case .preserveRename: return .archived
        case .moveToTrash: return .trashed
        case .permanentDelete: return .deleted
        }
    }

    /// Runs one operation; failures are recorded as failed change rows and never abort the run.
    func attempt(path: String, kind: ChangeKind, oldPath: String? = nil, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let crash as InjectedCrash {
            // Simulated process death: leave journal, temp files and the open commit exactly as they are.
            throw crash
        } catch {
            let skipped: Bool
            if case FSError.changedDuringCopy = error { skipped = true } else { skipped = false }
            SyncEngine.log.error("operation failed: \(String(describing: error), privacy: .private)")
            _ = try? catalog.addChange(FileChange(
                id: 0, commitSeq: seq, kind: kind, path: path, oldPath: oldPath, oldSize: nil, newSize: nil, oldMtimeNs: nil,
                newMtimeNs: nil, oldHash: nil, newHash: nil, status: skipped ? .skipped : .failed,
                error: String(describing: error), archivePath: nil
            ), pair: pair.id)
        }
    }

    func fault(_ op: String, _ path: RelativePath) throws {
        try engine.faultInjector?(op, path)
    }

    // MARK: Operations

    func relocate(_ a: ArchiveRecord) throws {
        guard let current = a.archivePath.flatMap({ try? RelativePath(validating: $0) }),
              let original = try? RelativePath(validating: a.originalPath) else { return }
        let target = try writer.uniqueSibling(of: try current.replacingName(original.name), marker: "DELETED", date: a.deletedAt,
                                              avoiding: reservedNames.union([current]))
        let intent = try catalog.addIntent(pair: pair.id, commitSeq: seq, op: "relocate", path: current, path2: target)
        try fault("relocate", current)
        try writer.move(current, to: target)
        try catalog.db.transaction {
            try catalog.updateArchive(a.id, state: .present, archivePath: target.string)
            try catalog.addChange(FileChange(
                id: 0, commitSeq: seq, kind: .archiveRelocated, path: target.string, oldPath: current.string, oldSize: a.size,
                newSize: a.size, oldMtimeNs: nil, newMtimeNs: nil, oldHash: a.hash, newHash: a.hash, status: .applied,
                error: nil, archivePath: target.string
            ), pair: pair.id)
            try catalog.removeIntent(intent)
        }
    }

    func rename(_ r: PlannedRename) throws {
        guard let ds = try writer.stat(r.from), ds.isRegularFile, ds.size == r.tracked.size else {
            throw FSError.destinationChanged(r.from.string)
        }
        let intent = try catalog.addIntent(pair: pair.id, commitSeq: seq, op: "rename", path: r.from, path2: r.to, priorHash: r.tracked.hash)
        try fault("rename", r.from)
        try writer.move(r.from, to: r.to)
        guard let newStat = try writer.stat(r.to) else { throw FSError.destinationChanged(r.to.string) }
        try catalog.db.transaction {
            try engine.recordRenamed(pair: pair.id, seq: seq, from: r.from, to: r.to, tracked: r.tracked, destStat: newStat, sourceStat: r.sourceStat)
            try catalog.removeIntent(intent)
        }
    }

    func delete(_ d: PlannedDeletion) throws {
        // Re-check right before acting: never remove content we did not put there.
        guard let ds = try writer.stat(d.path), ds.isRegularFile else { throw FSError.destinationChanged(d.path.string) }
        if ds.size != d.tracked.size || ds.mtimeNs != d.tracked.destMtimeNs {
            guard try writer.hash(d.path) == d.tracked.hash else { throw FSError.destinationChanged(d.path.string) }
        }
        // The content is preserved in the version store before it leaves the destination.
        try engine.ensureStored(d.tracked.hash, from: d.path, writer: writer)

        let policy = pair.effectiveDeletionPolicy
        switch policy {
        case .preserveRename:
            let archive = try writer.uniqueSibling(of: d.path, marker: "DELETED", date: Date(), avoiding: reservedNames)
            let intent = try catalog.addIntent(pair: pair.id, commitSeq: seq, op: "archive", path: d.path, path2: archive, priorHash: d.tracked.hash)
            try fault("archive", d.path)
            try writer.move(d.path, to: archive)
            try catalog.db.transaction {
                try engine.recordRemoved(pair: pair.id, seq: seq, path: d.path, tracked: d.tracked, policy: .preserveRename, archivePath: archive)
                try catalog.removeIntent(intent)
            }
        case .moveToTrash:
            let intent = try catalog.addIntent(pair: pair.id, commitSeq: seq, op: "trash", path: d.path, priorHash: d.tracked.hash)
            try fault("trash", d.path)
            try writer.trash(d.path, using: engine.trash)
            try catalog.db.transaction {
                try engine.recordRemoved(pair: pair.id, seq: seq, path: d.path, tracked: d.tracked, policy: .moveToTrash, archivePath: nil)
                try catalog.removeIntent(intent)
            }
        case .permanentDelete:
            let intent = try catalog.addIntent(pair: pair.id, commitSeq: seq, op: "delete", path: d.path, priorHash: d.tracked.hash)
            try fault("delete", d.path)
            try writer.removeFile(d.path)
            try catalog.db.transaction {
                try engine.recordRemoved(pair: pair.id, seq: seq, path: d.path, tracked: d.tracked, policy: .permanentDelete, archivePath: nil)
                try catalog.removeIntent(intent)
            }
        }
    }

    func copy(_ c: PlannedCopy) throws {
        // Preserve what is about to be replaced.
        var preservedUnknown: (hash: String, stat: FileStat)?
        switch c.reason {
        case .modify:
            if let prev = c.previous { try engine.ensureStored(prev.hash, from: c.path, writer: writer) }
        case .overwriteConflict:
            if let ds = try writer.stat(c.path), ds.isRegularFile {
                let fd = try writer.openForReading(c.path)
                let h = try engine.store.ingest(fd: fd.fd, pathForErrors: c.path.string, expectedHash: nil)
                fd.close()
                preservedUnknown = (h, ds)
            }
        case .add, .repair:
            break
        }

        let src = try reader.openFile(c.path, expected: c.sourceStat)
        defer { src.close() }
        let before = try fstatFD(src.fd, c.path.string)

        let intent = try catalog.addIntent(pair: pair.id, commitSeq: seq, op: "copy", path: c.path, priorHash: c.previous?.hash)
        var temp: RelativePath?
        var objectWriter: ObjectWriter?
        do {
            let (dst, tempPath) = try writer.createTemporary(near: c.path)
            temp = tempPath
            defer { dst.close() }
            try catalog.setIntentTemp(intent, tempPath)
            if pair.versioningMode == .full { objectWriter = try engine.store.beginWrite() }

            let result = try StreamingCopier.copy(from: src.fd, srcPath: c.path.string, to: dst.fd, dstPath: tempPath.string, objectWriter: objectWriter)
            try fault("copied", c.path)
            let after = try fstatFD(src.fd, c.path.string)
            guard after.size == before.size, after.mtimeNs == before.mtimeNs, result.bytes == after.size else {
                throw FSError.changedDuringCopy(c.path.string)
            }
            // Data fork only: permission bits (setuid/setgid/sticky stripped) and modification time.
            fchmod(dst.fd, (before.permissionBits & 0o777) | 0o400)
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                         timespec(tv_sec: Int(before.mtimeNs / 1_000_000_000), tv_nsec: Int(before.mtimeNs % 1_000_000_000))]
            futimens(dst.fd, &times)
            try fullSync(dst.fd, tempPath.string)
            try objectWriter?.finish(expectedHash: result.hash)
            objectWriter = nil

            // Integrity: read back what actually reached the disk before publishing it.
            let written = try StreamHasher.hash(path: writer.absolute(tempPath))
            guard written == result.hash else {
                throw FSError.integrityMismatch(path: c.path.string, expected: result.hash, actual: written)
            }
            try catalog.setIntentExpectedHash(intent, result.hash)

            if c.reason == .modify, let prev = c.previous {
                guard let ds = try writer.stat(c.path), ds.size == prev.size, ds.mtimeNs == prev.destMtimeNs else {
                    throw FSError.destinationChanged(c.path.string)
                }
            }
            try fault("publish", c.path)
            try writer.publish(tempPath, to: c.path, replace: c.reason == .modify || c.reason == .overwriteConflict)
            temp = nil
            try fault("record", c.path)
            guard let published = try writer.stat(c.path) else { throw FSError.destinationChanged(c.path.string) }

            let kind: ChangeKind = c.reason == .add ? .added : c.reason == .repair ? .repaired : .modified
            try catalog.db.transaction {
                try engine.recordPublished(pair: pair.id, seq: seq, path: c.path, hash: result.hash, destStat: published,
                                           previous: c.previous, kind: kind, sourceStat: before, bytes: result.bytes,
                                           note: c.reason == .repair ? "Destination copy was missing" : nil)
                if let p = preservedUnknown {
                    try catalog.addArchive(ArchiveRecord(
                        id: 0, pairID: pair.id, originalPath: c.path.string, archivePath: nil, hash: p.hash, size: p.stat.size,
                        mtimeNs: p.stat.mtimeNs, deletedAt: Date(), commitSeq: seq, policy: .permanentDelete, state: .purged
                    ))
                    try catalog.setOverride(pair.id, path: c.path.string, nil)
                }
                try catalog.removeIntent(intent)
            }
            bytes += result.bytes
        } catch let crash as InjectedCrash {
            throw crash
        } catch {
            objectWriter?.abort()
            if let temp { writer.removeTemporary(temp) }
            try? catalog.removeIntent(intent)
            throw error
        }
    }

    func adopt(_ a: PlannedAdoption) throws {
        if pair.versioningMode == .full { try engine.ensureStored(a.hash, from: a.path, writer: writer) }
        try catalog.db.transaction {
            try engine.recordPublished(pair: pair.id, seq: seq, path: a.path, hash: a.hash, destStat: a.destStat, previous: nil,
                                       kind: .adopted, sourceStat: a.sourceStat, bytes: nil,
                                       note: "Identical file already present at destination")
        }
    }
}

/// Thrown by the test fault injector to simulate the process dying at a precise point.
public struct InjectedCrash: Error {
    public init() {}
}
