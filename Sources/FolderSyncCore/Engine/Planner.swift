import Foundation

public struct PlannedCopy: Hashable, Sendable {
    public enum Reason: String, Sendable { case add, modify, repair, overwriteConflict }
    public var path: RelativePath
    public var reason: Reason
    public var sourceStat: FileStat
    /// Hash already known from the source index or computed during planning; nil = computed while copying.
    public var knownHash: String?
    public var previous: TrackedFile?
}

public struct PlannedRename: Hashable, Sendable {
    public var from: RelativePath
    public var to: RelativePath
    public var tracked: TrackedFile
    public var sourceStat: FileStat
}

public struct PlannedDeletion: Hashable, Sendable {
    public var path: RelativePath
    public var tracked: TrackedFile
}

public struct PlannedAdoption: Hashable, Sendable {
    public var path: RelativePath
    public var hash: String
    public var sourceStat: FileStat
    public var destStat: FileStat
}

public enum DeletionBlock: Hashable, Sendable {
    /// The source looks empty while files are tracked — typical of an unmounted or replaced drive.
    case sourceAppearsEmpty(tracked: Int)
    /// More deletions than the configured safety threshold.
    case massDeletion(count: Int, tracked: Int)

    public var message: String {
        switch self {
        case let .sourceAppearsEmpty(n): return "The source folder appears empty while \(n) files are tracked. Deletions were not applied."
        case let .massDeletion(c, t): return "\(c) of \(t) tracked files would be deleted, exceeding the safety threshold. Confirm to apply."
        }
    }
}

public struct SyncPlan: Sendable {
    public var createDirectories: [RelativePath] = []
    public var copies: [PlannedCopy] = []
    public var renames: [PlannedRename] = []
    public var deletions: [PlannedDeletion] = []
    public var adoptions: [PlannedAdoption] = []
    /// Tracked files gone from both sides; only bookkeeping is needed.
    public var vanished: [PlannedDeletion] = []
    /// Archives whose current path is needed by a new source file.
    public var archiveRelocations: [ArchiveRecord] = []
    public var removeDirectories: [RelativePath] = []
    public var conflicts: [SyncConflict] = []
    public var skipped: [(path: String, reason: SkipReason)] = []
    /// Source files whose metadata changed but content did not (cache refresh only).
    public var indexRefresh: [RelativePath: SourceIndexEntry] = [:]
    /// Destination files whose metadata changed but content is identical to what was recorded.
    public var trackedRefresh: [RelativePath: TrackedFile] = [:]
    public var deletionBlock: DeletionBlock?
    public var sourceFileCount = 0

    public var hasWork: Bool {
        !createDirectories.isEmpty || !copies.isEmpty || !renames.isEmpty || !adoptions.isEmpty || !vanished.isEmpty
            || !archiveRelocations.isEmpty || !removeDirectories.isEmpty || (!deletions.isEmpty && deletionBlock == nil)
    }

    /// Keeps only operations that touch `paths` (directory creation for their parents is kept).
    mutating func restrict(to paths: Set<String>) {
        copies = copies.filter { paths.contains($0.path.string) }
        renames = renames.filter { paths.contains($0.to.string) || paths.contains($0.from.string) }
        deletions = deletions.filter { paths.contains($0.path.string) }
        adoptions = adoptions.filter { paths.contains($0.path.string) }
        vanished = vanished.filter { paths.contains($0.path.string) }
        let needed = Set(copies.map(\.path) + renames.map(\.to)).flatMap { $0.ancestors }
        createDirectories = createDirectories.filter { needed.contains($0) }
        archiveRelocations = archiveRelocations.filter { a in a.archivePath.map { paths.contains($0) } ?? false }
        removeDirectories = []
    }

    public var pendingChangeCount: Int {
        copies.count + renames.count + deletions.count + adoptions.count + vanished.count
    }
}

/// Computes what must happen to make the destination reflect the source.
///
/// The planner never mutates anything. Its only side effects are reads through the injected
/// closures (`destStat`, `hashSource`, `hashDestination`), which keeps it deterministic and testable.
struct Planner {
    var pair: FolderPair
    var scan: ScanResult
    var sourceIndex: [RelativePath: SourceIndexEntry]
    var tracked: [RelativePath: TrackedFile]
    var trackedDirs: Set<RelativePath>
    var archivesByPath: [RelativePath: ArchiveRecord]
    var overrides: [RelativePath: PathOverride]
    var destinationCaseSensitive: Bool
    var allowMassDeletion: Bool
    var destStat: (RelativePath) throws -> FileStat?
    var hashSource: (RelativePath, FileStat) throws -> String
    var hashDestination: (RelativePath) throws -> String

    func plan() throws -> SyncPlan {
        var plan = SyncPlan()
        plan.skipped = scan.skipped
        plan.sourceFileCount = scan.files.count

        // Paths the user asked us to leave alone are invisible to the planner.
        let ignored = Set(overrides.filter { $0.value == .ignore }.keys)
        var sourceFiles = scan.files.filter { !ignored.contains($0.key) }
        let sourceDirs = scan.directories.filter { !ignored.contains($0) }

        // Case/normalization collisions on case-insensitive destinations.
        if !destinationCaseSensitive {
            var seen: [String: RelativePath] = [:]
            for path in (Array(sourceDirs) + Array(sourceFiles.keys)).sorted() {
                let key = path.foldedKey
                if let first = seen[key], first != path {
                    plan.conflicts.append(SyncConflict(path: path.string, kind: .caseCollision, detail: "Collides with \(first.string) on a case-insensitive destination"))
                    sourceFiles.removeValue(forKey: path)
                } else {
                    seen[key] = path
                }
            }
        }

        var hashCache: [RelativePath: String] = [:]
        func sourceHash(_ path: RelativePath, _ st: FileStat) throws -> String {
            if let h = hashCache[path] { return h }
            if let cached = sourceIndex[path], cached.matches(st) { return cached.hash }
            let h = try hashSource(path, st)
            hashCache[path] = h
            plan.indexRefresh[path] = SourceIndexEntry(size: st.size, mtimeNs: st.mtimeNs, inode: st.inode, hash: h)
            return h
        }

        /// Returns nil when the destination still holds exactly what we recorded.
        func destinationDivergence(_ path: RelativePath, _ t: TrackedFile) throws -> (FileStat?, ConflictKind?) {
            guard let ds = try destStat(path) else { return (nil, nil) }
            guard ds.isRegularFile else { return (ds, .destinationTypeChanged) }
            if ds.size == t.size && ds.mtimeNs == t.destMtimeNs { return (ds, nil) }
            let h = try hashDestination(path)
            if h == t.hash {
                plan.trackedRefresh[path] = TrackedFile(hash: h, size: ds.size, destMtimeNs: ds.mtimeNs)
                return (ds, nil)
            }
            return (ds, .destinationModified)
        }

        var newPaths: [RelativePath] = []

        for (path, st) in sourceFiles.sorted(by: { $0.key < $1.key }) {
            guard let t = tracked[path] else {
                newPaths.append(path)
                continue
            }
            let (ds, divergence) = try destinationDivergence(path, t)
            let forced = overrides[path] == .overwriteDestination
            if let divergence, !forced {
                plan.conflicts.append(SyncConflict(path: path.string, kind: divergence, detail: "The destination copy was changed outside FolderSync"))
                continue
            }
            if ds == nil {
                plan.copies.append(PlannedCopy(path: path, reason: .repair, sourceStat: st, knownHash: nil, previous: t))
                continue
            }
            if divergence != nil {
                plan.copies.append(PlannedCopy(path: path, reason: .overwriteConflict, sourceStat: st, knownHash: nil, previous: t))
                continue
            }
            if let cached = sourceIndex[path], cached.matches(st), cached.hash == t.hash { continue }
            if st.size == t.size {
                // Same size, different metadata: hash to avoid rewriting identical content.
                let h = try sourceHash(path, st)
                if h == t.hash { continue }
                plan.copies.append(PlannedCopy(path: path, reason: .modify, sourceStat: st, knownHash: h, previous: t))
            } else {
                plan.copies.append(PlannedCopy(path: path, reason: .modify, sourceStat: st, knownHash: nil, previous: t))
            }
        }

        // Removed = tracked but no longer in the source (and not ignored).
        let conflictPaths = Set(plan.conflicts.map(\.path))
        let removed = tracked.keys.filter { sourceFiles[$0] == nil && !ignored.contains($0) && !conflictPaths.contains($0.string) }.sorted()
        var intactRemoved: [Int64: [RelativePath]] = [:]
        var removedState: [RelativePath: FileStat?] = [:]
        var removedConflict: Set<RelativePath> = []
        for path in removed {
            let t = tracked[path]!
            let (ds, divergence) = try destinationDivergence(path, t)
            removedState[path] = ds
            if divergence != nil {
                removedConflict.insert(path)
                plan.conflicts.append(SyncConflict(path: path.string, kind: .destinationModifiedBeforeDeletion, detail: "Deleted in source, but the destination copy was changed; it was left in place"))
            } else if ds != nil {
                intactRemoved[t.size, default: []].append(path)
            }
        }

        var renamedAway: Set<RelativePath> = []
        for path in newPaths {
            let st = sourceFiles[path]!
            let destExisting = try destStat(path)
            let archiveHere = archivesByPath[path]

            // Rename detection: same size + same hash as a tracked file that disappeared.
            if destExisting == nil || archiveHere != nil, let candidates = intactRemoved[st.size]?.filter({ !renamedAway.contains($0) }), !candidates.isEmpty {
                let h = try sourceHash(path, st)
                if let match = candidates.first(where: { tracked[$0]!.hash == h }) {
                    renamedAway.insert(match)
                    if let a = archiveHere { plan.archiveRelocations.append(a) }
                    plan.renames.append(PlannedRename(from: match, to: path, tracked: tracked[match]!, sourceStat: st))
                    continue
                }
            }

            if let a = archiveHere {
                plan.archiveRelocations.append(a)
                plan.copies.append(PlannedCopy(path: path, reason: .add, sourceStat: st, knownHash: hashCache[path], previous: nil))
                continue
            }
            guard let ds = destExisting else {
                plan.copies.append(PlannedCopy(path: path, reason: .add, sourceStat: st, knownHash: hashCache[path], previous: nil))
                continue
            }
            // Something we do not own is already at the destination path.
            if overrides[path] == .overwriteDestination, ds.isRegularFile {
                plan.copies.append(PlannedCopy(path: path, reason: .overwriteConflict, sourceStat: st, knownHash: nil, previous: nil))
                continue
            }
            guard ds.isRegularFile else {
                plan.conflicts.append(SyncConflict(path: path.string, kind: .destinationTypeChanged, detail: "A non-file item occupies this path in the destination"))
                continue
            }
            let sh = try sourceHash(path, st)
            if ds.size == st.size, try hashDestination(path) == sh {
                plan.adoptions.append(PlannedAdoption(path: path, hash: sh, sourceStat: st, destStat: ds))
            } else {
                plan.conflicts.append(SyncConflict(path: path.string, kind: .untrackedFileAtDestination, detail: "A different file not created by FolderSync already exists here"))
            }
        }

        for path in removed where !renamedAway.contains(path) && !removedConflict.contains(path) {
            if removedState[path] ?? nil == nil {
                plan.vanished.append(PlannedDeletion(path: path, tracked: tracked[path]!))
            } else {
                plan.deletions.append(PlannedDeletion(path: path, tracked: tracked[path]!))
            }
        }

        // Deletion safety: never infer mass deletion from an empty or unavailable-looking source.
        if !plan.deletions.isEmpty && !allowMassDeletion {
            let trackedCount = tracked.count
            if scan.files.isEmpty && scan.directories.isEmpty && trackedCount > 0 {
                plan.deletionBlock = .sourceAppearsEmpty(tracked: trackedCount)
            } else {
                let n = plan.deletions.count
                let percent = Double(n) / Double(max(trackedCount, 1)) * 100
                if n > pair.massDeletionThresholdCount || (trackedCount >= 20 && percent > pair.massDeletionThresholdPercent) {
                    plan.deletionBlock = .massDeletion(count: n, tracked: trackedCount)
                }
            }
        }

        // Directories: create missing ones, adopt existing ones, remove the ones we created that vanished.
        for dir in sourceDirs.sorted() where !trackedDirs.contains(dir) {
            if let ds = try destStat(dir) {
                if !ds.isDirectory {
                    plan.conflicts.append(SyncConflict(path: dir.string, kind: .destinationTypeChanged, detail: "A file occupies the path of a source folder"))
                    continue
                }
            }
            plan.createDirectories.append(dir)
        }
        if plan.deletionBlock == nil {
            plan.removeDirectories = trackedDirs.filter { !sourceDirs.contains($0) && !ignored.contains($0) }
                .sorted { $0.depth > $1.depth }
        }
        plan.conflicts.sort { $0.path < $1.path }
        return plan
    }
}
