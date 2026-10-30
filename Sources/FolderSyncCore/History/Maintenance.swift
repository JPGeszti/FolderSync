import Foundation

/// Retention, garbage collection and integrity verification.
public struct Maintenance {
    public let storage: FolderSyncStorage
    public init(storage: FolderSyncStorage) { self.storage = storage }

    var catalog: Catalog { storage.catalog }

    public struct RetentionResult: Equatable, Sendable {
        public var versionsPruned: Int
        public var archivesExpired: Int
    }

    /// Drops version intervals that ended before the retention cutoff, and expires archive records
    /// whose content no longer exists in the destination. Archives still present in the
    /// destination are always kept. Current versions are never pruned.
    @discardableResult
    public func applyRetention(pair: FolderPair, now: Date = Date()) throws -> RetentionResult {
        guard pair.retentionDays > 0 else { return RetentionResult(versionsPruned: 0, archivesExpired: 0) }
        let cutoff = now.addingTimeInterval(-Double(pair.retentionDays) * 86_400).timeIntervalSince1970
        let p = pair.id.uuidString
        return try catalog.db.transaction {
            let versions = try catalog.db.run(
                """
                DELETE FROM file_versions WHERE pair_id=? AND to_seq IS NOT NULL
                AND to_seq IN (SELECT seq FROM commits WHERE pair_id=? AND COALESCE(finished_at, started_at) < ?)
                """, p, p, cutoff)
            let archives = try catalog.db.run(
                "DELETE FROM archives WHERE pair_id=? AND state IN ('trashed','purged','restored','missing') AND deleted_at < ?", p, cutoff)
            return RetentionResult(versionsPruned: versions, archivesExpired: archives)
        }
    }

    /// Deletes stored objects that no history row references. Must not run concurrently with a
    /// sync (an in-flight sync may have stored an object it has not recorded yet); `SyncService`
    /// guarantees this.
    @discardableResult
    public func collectGarbage() throws -> Int {
        let referenced = try catalog.referencedHashes()
        var removed = 0
        for hash in storage.store.allHashes() where !referenced.contains(hash) {
            storage.store.remove(hash)
            removed += 1
        }
        return removed
    }

    /// Decrypts and re-hashes every stored object. Returns problems keyed by hash.
    public func verifyStore() -> [String: String] {
        var problems: [String: String] = [:]
        for hash in storage.store.allHashes() {
            do { try storage.store.verify(hash) } catch { problems[hash] = String(describing: error) }
        }
        for hash in (try? catalog.referencedHashes()) ?? [] where !storage.store.contains(hash) {
            // Referenced but absent is only a problem when versioning promised to keep it;
            // reported for visibility either way.
            problems[hash] = problems[hash] ?? "not in version store"
        }
        return problems
    }

    /// Re-hashes every tracked destination file and reports mismatches (no repairs are made).
    public func verifyDestination(pair: FolderPair, destination: String) throws -> [String: String] {
        let writer = DestinationWriter(rootPath: destination)
        var problems: [String: String] = [:]
        for (path, t) in try catalog.trackedFiles(pair.id) {
            do {
                guard try writer.stat(path) != nil else { problems[path.string] = "missing"; continue }
                let h = try writer.hash(path)
                if h != t.hash { problems[path.string] = "content differs from recorded version" }
            } catch {
                problems[path.string] = String(describing: error)
            }
        }
        return problems
    }
}
