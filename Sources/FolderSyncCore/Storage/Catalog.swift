import CryptoKit
import Foundation

/// Typed access to FolderSync's metadata database. Holds paths, sizes, timestamps and hashes only.
public final class Catalog: @unchecked Sendable {
    public let db: Database

    public init(database: Database) throws {
        db = database
        try Schema.migrate(db)
    }

    // MARK: Pairs

    public func savePair(_ pair: FolderPair) throws {
        let json = String(decoding: try JSONEncoder().encode(pair), as: UTF8.self)
        try db.run(
            "INSERT INTO pairs(id, json, created_at) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
            pair.id.uuidString, json, pair.createdAt.timeIntervalSince1970
        )
    }

    public func pairs() throws -> [FolderPair] {
        try db.query("SELECT json FROM pairs ORDER BY created_at").compactMap { row in
            row.string("json").flatMap { try? JSONDecoder().decode(FolderPair.self, from: Data($0.utf8)) }
        }
    }

    public func pair(_ id: UUID) throws -> FolderPair? {
        try db.query("SELECT json FROM pairs WHERE id=?", id.uuidString).first?.string("json")
            .flatMap { try? JSONDecoder().decode(FolderPair.self, from: Data($0.utf8)) }
    }

    /// Removes a pair's configuration and metadata. Never touches files in either folder.
    public func deletePair(_ id: UUID) throws {
        let p = id.uuidString
        try db.transaction {
            for table in ["tracked_files", "tracked_dirs", "source_index", "conflicts", "path_overrides", "intents", "file_versions", "archives", "changes", "commits"] {
                try db.run("DELETE FROM \(table) WHERE pair_id=?", p)
            }
            try db.run("DELETE FROM pairs WHERE id=?", p)
        }
    }

    // MARK: Tracked destination state

    public func trackedFiles(_ pair: UUID) throws -> [RelativePath: TrackedFile] {
        var out: [RelativePath: TrackedFile] = [:]
        for row in try db.query("SELECT path, hash, size, dest_mtime FROM tracked_files WHERE pair_id=?", pair.uuidString) {
            guard let p = row.string("path"), let rel = try? RelativePath(validating: p) else { continue }
            out[rel] = TrackedFile(hash: row.string("hash") ?? "", size: row.int("size") ?? 0, destMtimeNs: row.int("dest_mtime") ?? 0)
        }
        return out
    }

    func setTracked(_ pair: UUID, _ path: RelativePath, _ t: TrackedFile) throws {
        try db.run(
            "INSERT INTO tracked_files(pair_id, path, hash, size, dest_mtime) VALUES(?,?,?,?,?) ON CONFLICT(pair_id, path) DO UPDATE SET hash=excluded.hash, size=excluded.size, dest_mtime=excluded.dest_mtime",
            pair.uuidString, path.string, t.hash, t.size, t.destMtimeNs
        )
    }

    func removeTracked(_ pair: UUID, _ path: RelativePath) throws {
        try db.run("DELETE FROM tracked_files WHERE pair_id=? AND path=?", pair.uuidString, path.string)
    }

    public func trackedDirectories(_ pair: UUID) throws -> Set<RelativePath> {
        Set(try db.query("SELECT path FROM tracked_dirs WHERE pair_id=?", pair.uuidString).compactMap {
            $0.string("path").flatMap { try? RelativePath(validating: $0) }
        })
    }

    func addTrackedDirectory(_ pair: UUID, _ path: RelativePath) throws {
        try db.run("INSERT OR IGNORE INTO tracked_dirs(pair_id, path) VALUES(?,?)", pair.uuidString, path.string)
    }

    func removeTrackedDirectory(_ pair: UUID, _ path: RelativePath) throws {
        try db.run("DELETE FROM tracked_dirs WHERE pair_id=? AND path=?", pair.uuidString, path.string)
    }

    // MARK: Source hash cache

    public func sourceIndex(_ pair: UUID) throws -> [RelativePath: SourceIndexEntry] {
        var out: [RelativePath: SourceIndexEntry] = [:]
        for row in try db.query("SELECT path, size, mtime, inode, hash FROM source_index WHERE pair_id=?", pair.uuidString) {
            guard let p = row.string("path"), let rel = try? RelativePath(validating: p) else { continue }
            out[rel] = SourceIndexEntry(size: row.int("size") ?? -1, mtimeNs: row.int("mtime") ?? -1, inode: UInt64(bitPattern: row.int("inode") ?? -1), hash: row.string("hash") ?? "")
        }
        return out
    }

    func setSourceIndex(_ pair: UUID, _ path: RelativePath, _ e: SourceIndexEntry) throws {
        try db.run(
            "INSERT INTO source_index(pair_id, path, size, mtime, inode, hash) VALUES(?,?,?,?,?,?) ON CONFLICT(pair_id, path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, inode=excluded.inode, hash=excluded.hash",
            pair.uuidString, path.string, e.size, e.mtimeNs, Int64(bitPattern: e.inode), e.hash
        )
    }

    func removeSourceIndex(_ pair: UUID, _ path: RelativePath) throws {
        try db.run("DELETE FROM source_index WHERE pair_id=? AND path=?", pair.uuidString, path.string)
    }

    // MARK: Commits

    func beginCommit(pair: UUID, kind: CommitKind, restoredFrom: Int64? = nil, message: String? = nil) throws -> Int64 {
        let parent = try latestCommitID(pair)
        try db.run(
            "INSERT INTO commits(id, pair_id, parent_id, kind, status, started_at, message, restored_from_seq) VALUES(?,?,?,?,?,?,?,?)",
            "pending-" + UUID().uuidString, pair.uuidString, parent, kind.rawValue, CommitStatus.inProgress.rawValue,
            Date().timeIntervalSince1970, message, restoredFrom
        )
        return db.lastInsertRowID
    }

    func latestCommitID(_ pair: UUID) throws -> String? {
        try db.query("SELECT id FROM commits WHERE pair_id=? AND id NOT LIKE 'pending-%' ORDER BY seq DESC LIMIT 1", pair.uuidString).first?.string("id")
    }

    /// Finalizes a commit: aggregates its change rows and assigns the hash-chained commit ID.
    @discardableResult
    func finishCommit(seq: Int64, status: CommitStatus? = nil, bytes: Int64? = nil, message: String? = nil) throws -> Commit {
        try db.transaction {
            guard var commit = try commit(seq) else { throw DatabaseError(code: -1, message: "commit \(seq) missing") }
            let changes = try changes(commitSeq: seq)
            func count(_ kinds: Set<ChangeKind>) -> Int { changes.filter { $0.status == .applied && kinds.contains($0.kind) }.count }
            commit.added = count([.added, .repaired, .adopted])
            commit.modified = count([.modified])
            commit.renamed = count([.renamed])
            commit.archived = count([.archived, .trashed])
            commit.deleted = count([.deleted])
            commit.restored = count([.restored])
            commit.failed = changes.filter { $0.status == .failed }.count
            let applied = changes.filter { $0.status == .applied }.count
            commit.status = status ?? (commit.failed == 0 ? .success : (applied == 0 ? .failed : .partial))
            if let bytes { commit.bytesTransferred = bytes }
            if let message { commit.message = message }
            commit.finishedAt = Date()
            commit.parentID = try latestCommitID(commit.pairID)
            commit.id = Catalog.commitHash(commit, changes: changes)
            try db.run(
                """
                UPDATE commits SET id=?, parent_id=?, status=?, finished_at=?, added=?, modified=?, deleted=?, renamed=?, archived=?, restored=?, failed=?, bytes_transferred=?, message=? WHERE seq=?
                """,
                commit.id, commit.parentID, commit.status.rawValue, commit.finishedAt!.timeIntervalSince1970,
                commit.added, commit.modified, commit.deleted, commit.renamed, commit.archived, commit.restored, commit.failed,
                commit.bytesTransferred, commit.message, seq
            )
            return commit
        }
    }

    /// `SHA-256(parent ‖ pair ‖ seq ‖ kind ‖ status ‖ started ‖ each change)`. Any later edit of a
    /// commit or its change list breaks the chain, which `verifyHistoryChain` detects.
    static func commitHash(_ c: Commit, changes: [FileChange]) -> String {
        var h = SHA256()
        func add(_ s: String?) { h.update(data: Data((s ?? "∅").utf8)); h.update(data: Data([0])) }
        add(c.parentID); add(c.pairID.uuidString); add(String(c.seq)); add(c.kind.rawValue); add(c.status.rawValue)
        add(String(Int64(c.startedAt.timeIntervalSince1970 * 1000)))
        for ch in changes.sorted(by: { $0.id < $1.id }) {
            add(ch.kind.rawValue); add(ch.path); add(ch.oldPath); add(ch.oldHash); add(ch.newHash); add(ch.status.rawValue)
        }
        return Data(h.finalize()).hexString
    }

    /// Returns the seqs of commits whose stored ID or parent link does not match a recomputation.
    public func verifyHistoryChain(_ pair: UUID) throws -> [Int64] {
        var bad: [Int64] = []
        var previous: String?
        for c in try commits(pair: pair, limit: Int.max, offset: 0).reversed() where c.status != .inProgress {
            let expected = Catalog.commitHash(c, changes: try changes(commitSeq: c.seq))
            if c.id != expected || c.parentID != previous { bad.append(c.seq) }
            previous = c.id
        }
        return bad
    }

    static func commit(from row: Row) -> Commit? {
        guard let seq = row.int("seq"), let id = row.string("id"), let pair = row.string("pair_id").flatMap(UUID.init(uuidString:)) else { return nil }
        return Commit(
            seq: seq, id: id, pairID: pair, parentID: row.string("parent_id"),
            kind: CommitKind(rawValue: row.string("kind") ?? "") ?? .sync,
            status: CommitStatus(rawValue: row.string("status") ?? "") ?? .failed,
            startedAt: Date(timeIntervalSince1970: row.double("started_at") ?? 0),
            finishedAt: row.double("finished_at").map(Date.init(timeIntervalSince1970:)),
            added: Int(row.int("added") ?? 0), modified: Int(row.int("modified") ?? 0), deleted: Int(row.int("deleted") ?? 0),
            renamed: Int(row.int("renamed") ?? 0), archived: Int(row.int("archived") ?? 0), restored: Int(row.int("restored") ?? 0),
            failed: Int(row.int("failed") ?? 0), bytesTransferred: row.int("bytes_transferred") ?? 0,
            message: row.string("message"), restoredFromSeq: row.int("restored_from_seq")
        )
    }

    public func commit(_ seq: Int64) throws -> Commit? {
        try db.query("SELECT * FROM commits WHERE seq=?", seq).first.flatMap(Catalog.commit(from:))
    }

    /// Newest first. `pair == nil` returns commits of all pairs.
    public func commits(pair: UUID?, limit: Int = 200, offset: Int = 0, since: Date? = nil, until: Date? = nil) throws -> [Commit] {
        var sql = "SELECT * FROM commits WHERE 1=1"
        var args: [SQLBindable] = []
        if let pair { sql += " AND pair_id=?"; args.append(pair.uuidString) }
        if let since { sql += " AND started_at>=?"; args.append(since.timeIntervalSince1970) }
        if let until { sql += " AND started_at<=?"; args.append(until.timeIntervalSince1970) }
        sql += " ORDER BY seq DESC LIMIT ? OFFSET ?"
        args.append(Int64(min(limit, Int(Int32.max))))
        args.append(offset)
        return try db.query(sql, args).compactMap(Catalog.commit(from:))
    }

    public func interruptedCommits(_ pair: UUID) throws -> [Int64] {
        try db.query("SELECT seq FROM commits WHERE pair_id=? AND status=?", pair.uuidString, CommitStatus.inProgress.rawValue).compactMap { $0.int("seq") }
    }

    // MARK: Changes

    @discardableResult
    func addChange(_ c: FileChange, pair: UUID) throws -> Int64 {
        try db.run(
            """
            INSERT INTO changes(commit_seq, pair_id, kind, path, old_path, old_size, new_size, old_mtime, new_mtime, old_hash, new_hash, status, error, archive_path)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            c.commitSeq, pair.uuidString, c.kind.rawValue, c.path, c.oldPath, c.oldSize, c.newSize, c.oldMtimeNs, c.newMtimeNs,
            c.oldHash, c.newHash, c.status.rawValue, c.error, c.archivePath
        )
        return db.lastInsertRowID
    }

    static func change(from row: Row) -> FileChange? {
        guard let id = row.int("id"), let seq = row.int("commit_seq"), let path = row.string("path") else { return nil }
        return FileChange(
            id: id, commitSeq: seq, kind: ChangeKind(rawValue: row.string("kind") ?? "") ?? .modified, path: path,
            oldPath: row.string("old_path"), oldSize: row.int("old_size"), newSize: row.int("new_size"),
            oldMtimeNs: row.int("old_mtime"), newMtimeNs: row.int("new_mtime"), oldHash: row.string("old_hash"),
            newHash: row.string("new_hash"), status: ChangeStatus(rawValue: row.string("status") ?? "") ?? .failed,
            error: row.string("error"), archivePath: row.string("archive_path")
        )
    }

    public func changes(commitSeq: Int64) throws -> [FileChange] {
        try db.query("SELECT * FROM changes WHERE commit_seq=? ORDER BY id", commitSeq).compactMap(Catalog.change(from:))
    }

    public func changes(pair: UUID, path: String) throws -> [FileChange] {
        try db.query("SELECT * FROM changes WHERE pair_id=? AND (path=? OR old_path=?) ORDER BY id DESC", pair.uuidString, path, path)
            .compactMap(Catalog.change(from:))
    }

    // MARK: Version intervals

    func openVersion(_ pair: UUID, _ path: RelativePath, hash: String, size: Int64, mtimeNs: Int64, fromSeq: Int64) throws {
        try db.run(
            "INSERT INTO file_versions(pair_id, path, hash, size, mtime, from_seq) VALUES(?,?,?,?,?,?)",
            pair.uuidString, path.string, hash, size, mtimeNs, fromSeq
        )
    }

    func closeVersion(_ pair: UUID, _ path: RelativePath, toSeq: Int64) throws {
        try db.run("UPDATE file_versions SET to_seq=? WHERE pair_id=? AND path=? AND to_seq IS NULL", toSeq, pair.uuidString, path.string)
    }

    /// Exact destination state as of commit `seq` (inclusive).
    public func snapshot(pair: UUID, at seq: Int64) throws -> [SnapshotEntry] {
        try db.query(
            "SELECT path, hash, size, mtime FROM file_versions WHERE pair_id=? AND from_seq<=? AND (to_seq IS NULL OR to_seq>?) ORDER BY path",
            pair.uuidString, seq, seq
        ).compactMap { row in
            guard let p = row.string("path"), let h = row.string("hash") else { return nil }
            return SnapshotEntry(path: p, hash: h, size: row.int("size") ?? 0, mtimeNs: row.int("mtime") ?? 0)
        }
    }

    /// Metadata-only comparison of two snapshots (no content diffing).
    public func compare(pair: UUID, from a: Int64, to b: Int64, includeUnchanged: Bool = false) throws -> [SnapshotDiff] {
        let left = Dictionary(uniqueKeysWithValues: try snapshot(pair: pair, at: a).map { ($0.path, $0) })
        let right = Dictionary(uniqueKeysWithValues: try snapshot(pair: pair, at: b).map { ($0.path, $0) })
        var out: [SnapshotDiff] = []
        for path in Set(left.keys).union(right.keys).sorted() {
            switch (left[path], right[path]) {
            case let (nil, r?): out.append(SnapshotDiff(path: path, kind: .added, before: nil, after: r))
            case let (l?, nil): out.append(SnapshotDiff(path: path, kind: .removed, before: l, after: nil))
            case let (l?, r?):
                if l.hash != r.hash { out.append(SnapshotDiff(path: path, kind: .modified, before: l, after: r)) }
                else if includeUnchanged { out.append(SnapshotDiff(path: path, kind: .unchanged, before: l, after: r)) }
            default: break
            }
        }
        return out
    }

    public func fileVersions(pair: UUID, path: String, store: ObjectStore?) throws -> [FileVersion] {
        try db.query("SELECT * FROM file_versions WHERE pair_id=? AND path=? ORDER BY from_seq DESC", pair.uuidString, path).compactMap { row in
            guard let id = row.int("id"), let h = row.string("hash") else { return nil }
            return FileVersion(id: id, path: path, hash: h, size: row.int("size") ?? 0, mtimeNs: row.int("mtime") ?? 0,
                               fromSeq: row.int("from_seq") ?? 0, toSeq: row.int("to_seq"), isStored: store?.contains(h) ?? false)
        }
    }

    public func knownPaths(pair: UUID) throws -> [String] {
        try db.query("SELECT DISTINCT path FROM file_versions WHERE pair_id=? ORDER BY path", pair.uuidString).compactMap { $0.string("path") }
    }

    // MARK: Archives

    @discardableResult
    func addArchive(_ a: ArchiveRecord) throws -> Int64 {
        try db.run(
            "INSERT INTO archives(pair_id, original_path, archive_path, hash, size, mtime, deleted_at, commit_seq, policy, state) VALUES(?,?,?,?,?,?,?,?,?,?)",
            a.pairID.uuidString, a.originalPath, a.archivePath, a.hash, a.size, a.mtimeNs, a.deletedAt.timeIntervalSince1970,
            a.commitSeq, a.policy.rawValue, a.state.rawValue
        )
        return db.lastInsertRowID
    }

    func updateArchive(_ id: Int64, state: ArchiveState, archivePath: String?) throws {
        try db.run("UPDATE archives SET state=?, archive_path=? WHERE id=?", state.rawValue, archivePath, id)
    }

    static func archive(from row: Row) -> ArchiveRecord? {
        guard let id = row.int("id"), let pair = row.string("pair_id").flatMap(UUID.init(uuidString:)) else { return nil }
        return ArchiveRecord(
            id: id, pairID: pair, originalPath: row.string("original_path") ?? "", archivePath: row.string("archive_path"),
            hash: row.string("hash") ?? "", size: row.int("size") ?? 0, mtimeNs: row.int("mtime") ?? 0,
            deletedAt: Date(timeIntervalSince1970: row.double("deleted_at") ?? 0), commitSeq: row.int("commit_seq") ?? 0,
            policy: DeletionPolicy(rawValue: row.string("policy") ?? "") ?? .preserveRename,
            state: ArchiveState(rawValue: row.string("state") ?? "") ?? .missing
        )
    }

    public func archives(pair: UUID?, states: Set<ArchiveState>? = nil) throws -> [ArchiveRecord] {
        var sql = "SELECT * FROM archives"
        var args: [SQLBindable] = []
        if let pair { sql += " WHERE pair_id=?"; args.append(pair.uuidString) }
        sql += " ORDER BY deleted_at DESC, id DESC"
        let all = try db.query(sql, args).compactMap(Catalog.archive(from:))
        guard let states else { return all }
        return all.filter { states.contains($0.state) }
    }

    public func archive(_ id: Int64) throws -> ArchiveRecord? {
        try db.query("SELECT * FROM archives WHERE id=?", id).first.flatMap(Catalog.archive(from:))
    }

    /// Archives currently occupying a destination path (owned by FolderSync, never source files).
    func presentArchivesByPath(_ pair: UUID) throws -> [RelativePath: ArchiveRecord] {
        var out: [RelativePath: ArchiveRecord] = [:]
        for a in try archives(pair: pair, states: [.present]) {
            if let p = a.archivePath, let rel = try? RelativePath(validating: p) { out[rel] = a }
        }
        return out
    }

    // MARK: Intent journal

    func addIntent(pair: UUID, commitSeq: Int64, op: String, path: RelativePath, path2: RelativePath? = nil, temp: RelativePath? = nil, priorHash: String? = nil) throws -> Int64 {
        try db.run(
            "INSERT INTO intents(pair_id, commit_seq, op, path, path2, temp_path, prior_hash, created_at) VALUES(?,?,?,?,?,?,?,?)",
            pair.uuidString, commitSeq, op, path.string, path2?.string, temp?.string, priorHash, Date().timeIntervalSince1970
        )
        return db.lastInsertRowID
    }

    func setIntentExpectedHash(_ id: Int64, _ hash: String) throws {
        try db.run("UPDATE intents SET expected_hash=? WHERE id=?", hash, id)
    }

    func setIntentTemp(_ id: Int64, _ temp: RelativePath) throws {
        try db.run("UPDATE intents SET temp_path=? WHERE id=?", temp.string, id)
    }

    func removeIntent(_ id: Int64) throws {
        try db.run("DELETE FROM intents WHERE id=?", id)
    }

    struct Intent {
        var id: Int64
        var commitSeq: Int64
        var op: String
        var path: RelativePath
        var path2: RelativePath?
        var temp: RelativePath?
        var expectedHash: String?
        var priorHash: String?
    }

    func pendingIntents(_ pair: UUID) throws -> [Intent] {
        try db.query("SELECT * FROM intents WHERE pair_id=? ORDER BY id", pair.uuidString).compactMap { row in
            guard let id = row.int("id"), let p = row.string("path").flatMap({ try? RelativePath(validating: $0) }) else { return nil }
            return Intent(
                id: id, commitSeq: row.int("commit_seq") ?? 0, op: row.string("op") ?? "", path: p,
                path2: row.string("path2").flatMap { try? RelativePath(validating: $0) },
                temp: row.string("temp_path").flatMap { try? RelativePath(validating: $0) },
                expectedHash: row.string("expected_hash"), priorHash: row.string("prior_hash")
            )
        }
    }

    // MARK: Conflicts & overrides

    func replaceConflicts(_ pair: UUID, _ conflicts: [SyncConflict]) throws {
        try db.transaction {
            try db.run("DELETE FROM conflicts WHERE pair_id=?", pair.uuidString)
            for c in conflicts {
                try db.run("INSERT OR REPLACE INTO conflicts(pair_id, path, kind, detail, detected_at) VALUES(?,?,?,?,?)",
                           pair.uuidString, c.path, c.kind.rawValue, c.detail, Date().timeIntervalSince1970)
            }
        }
    }

    public func conflicts(_ pair: UUID) throws -> [SyncConflict] {
        try db.query("SELECT * FROM conflicts WHERE pair_id=? ORDER BY path", pair.uuidString).compactMap { row in
            guard let p = row.string("path"), let k = row.string("kind").flatMap(ConflictKind.init(rawValue:)) else { return nil }
            return SyncConflict(path: p, kind: k, detail: row.string("detail") ?? "")
        }
    }

    public func setOverride(_ pair: UUID, path: String, _ action: PathOverride?) throws {
        if let action {
            try db.run("INSERT OR REPLACE INTO path_overrides(pair_id, path, action) VALUES(?,?,?)", pair.uuidString, path, action.rawValue)
        } else {
            try db.run("DELETE FROM path_overrides WHERE pair_id=? AND path=?", pair.uuidString, path)
        }
    }

    public func overrides(_ pair: UUID) throws -> [RelativePath: PathOverride] {
        var out: [RelativePath: PathOverride] = [:]
        for row in try db.query("SELECT path, action FROM path_overrides WHERE pair_id=?", pair.uuidString) {
            if let p = row.string("path").flatMap({ try? RelativePath(validating: $0) }), let a = row.string("action").flatMap(PathOverride.init(rawValue:)) {
                out[p] = a
            }
        }
        return out
    }

    // MARK: Activity log (metadata only)

    public func log(_ pair: UUID?, _ level: ActivityLevel, _ message: String) {
        _ = try? db.run("INSERT INTO activity(pair_id, ts, level, message) VALUES(?,?,?,?)", pair?.uuidString, Date().timeIntervalSince1970, level.rawValue, message)
    }

    public func activity(limit: Int = 500, pair: UUID? = nil) throws -> [ActivityEntry] {
        var sql = "SELECT * FROM activity"
        var args: [SQLBindable] = []
        if let pair { sql += " WHERE pair_id=?"; args.append(pair.uuidString) }
        sql += " ORDER BY id DESC LIMIT ?"
        args.append(limit)
        return try db.query(sql, args).compactMap { row in
            guard let id = row.int("id") else { return nil }
            return ActivityEntry(id: id, pairID: row.string("pair_id").flatMap(UUID.init(uuidString:)),
                                 timestamp: Date(timeIntervalSince1970: row.double("ts") ?? 0),
                                 level: ActivityLevel(rawValue: row.string("level") ?? "") ?? .info, message: row.string("message") ?? "")
        }
    }

    // MARK: Statistics

    public struct PairStats: Sendable {
        public var trackedFiles: Int
        public var trackedBytes: Int64
        public var archivedFiles: Int
        public var commits: Int
        public var lastSuccess: Date?
        public var conflicts: Int
    }

    public func stats(_ pair: UUID) throws -> PairStats {
        let p = pair.uuidString
        let tracked = try db.query("SELECT COUNT(*) AS n, COALESCE(SUM(size),0) AS b FROM tracked_files WHERE pair_id=?", p).first
        return PairStats(
            trackedFiles: Int(tracked?.int("n") ?? 0),
            trackedBytes: tracked?.int("b") ?? 0,
            archivedFiles: Int(try db.scalarInt("SELECT COUNT(*) FROM archives WHERE pair_id=? AND state IN ('present','trashed')", p) ?? 0),
            commits: Int(try db.scalarInt("SELECT COUNT(*) FROM commits WHERE pair_id=?", p) ?? 0),
            lastSuccess: try db.query("SELECT MAX(finished_at) AS t FROM commits WHERE pair_id=? AND status='success'", p).first?.double("t").map(Date.init(timeIntervalSince1970:)),
            conflicts: Int(try db.scalarInt("SELECT COUNT(*) FROM conflicts WHERE pair_id=?", p) ?? 0)
        )
    }

    /// Every content hash that history still needs. Used by retention / garbage collection.
    func referencedHashes() throws -> Set<String> {
        var out = Set<String>()
        for row in try db.query("SELECT DISTINCT hash FROM file_versions UNION SELECT DISTINCT hash FROM archives WHERE state != 'restored'") {
            if let h = row.values.values.first, case let .text(s) = h { out.insert(s) }
        }
        return out
    }
}
