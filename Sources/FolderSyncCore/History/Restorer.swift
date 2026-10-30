import Darwin
import Foundation

/// Proof that the user explicitly confirmed writing into a *source* folder. The UI creates one
/// only after a dedicated confirmation dialog; the sync engine never creates or receives one.
public struct SourceWriteAuthorization: Sendable {
    public let pairID: UUID
    public let confirmedAt: Date

    public static func grantAfterExplicitUserConfirmation(pairID: UUID) -> SourceWriteAuthorization {
        SourceWriteAuthorization(pairID: pairID, confirmedAt: Date())
    }
}

public enum RestoreError: Error, CustomStringConvertible, Equatable {
    case notStored(String)
    case authorizationMismatch
    case archiveNotRestorable

    public var description: String {
        switch self {
        case let .notStored(h): return "Version \(h.prefix(12)) is not in the version store (pruned by retention or never stored)."
        case .authorizationMismatch: return "Source restore authorization does not match this folder pair."
        case .archiveNotRestorable: return "This archived file can no longer be restored."
        }
    }
}

/// Restores historical versions. By default restores never touch the source: they write into the
/// destination (under a new, non-colliding name) or into a user-selected export folder. All writes
/// go to a temporary file first and are published only after the stored content verified.
public struct Restorer {
    public let storage: FolderSyncStorage
    public init(storage: FolderSyncStorage) { self.storage = storage }

    var catalog: Catalog { storage.catalog }
    var store: ObjectStore { storage.store }

    /// Decrypts `hash` into a temp file next to `target`, verifies it, sets mtime, and publishes it
    /// under the first free name among `target` and its `_RESTORED` variants.
    @discardableResult
    func materialize(hash: String, mtimeNs: Int64?, writer: DestinationWriter, target: RelativePath,
                     allowOriginalName: Bool = true, replace: Bool = false) throws -> RelativePath {
        guard store.contains(hash) else { throw RestoreError.notStored(hash) }
        let (fd, temp) = try writer.createTemporary(near: target)
        do {
            try store.read(hash) { chunk in try writeFully(fd.fd, chunk.baseAddress!, chunk.count, temp.string) }
            if let mtimeNs {
                var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                             timespec(tv_sec: Int(mtimeNs / 1_000_000_000), tv_nsec: Int(mtimeNs % 1_000_000_000))]
                futimens(fd.fd, &times)
            }
            fchmod(fd.fd, 0o644)
            try fullSync(fd.fd, temp.string)
            fd.close()
            if replace {
                try writer.publish(temp, to: target, replace: true)
                return target
            }
            var name = target
            if try !allowOriginalName || writer.stat(target) != nil {
                name = try writer.uniqueSibling(of: target, marker: "RESTORED", date: Date())
            }
            try writer.publish(temp, to: name, replace: false)
            return name
        } catch {
            fd.close()
            writer.removeTemporary(temp)
            throw error
        }
    }

    // MARK: Export (default, safest)

    /// Writes one historical version into a user-selected folder. Returns the written path.
    public func exportVersion(hash: String, fileName: String, mtimeNs: Int64?, to directory: String) throws -> String {
        let writer = DestinationWriter(rootPath: directory)
        let name = try RelativePath(components: [fileName])
        let out = try materialize(hash: hash, mtimeNs: mtimeNs, writer: writer, target: name)
        return out.absolute(in: directory)
    }

    /// Recreates the full destination snapshot of commit `seq` inside a new subfolder of `directory`.
    public func exportSnapshot(pair: FolderPair, seq: Int64, to directory: String) throws -> (folder: String, failures: [String: String]) {
        guard let commit = try catalog.commit(seq) else { throw RestoreError.notStored("commit \(seq)") }
        let base = DestinationWriter(rootPath: directory)
        let folderName = try base.uniqueSibling(of: try RelativePath(components: ["\(pair.name) @ \(commit.shortID)"]), marker: "copy", date: Date())
        let folder = folderName.absolute(in: directory)
        guard mkdir(folder, 0o755) == 0 else { throw posixFail("mkdir", folder) }
        let writer = DestinationWriter(rootPath: folder)
        var failures: [String: String] = [:]
        for entry in try catalog.snapshot(pair: pair.id, at: seq) {
            do {
                let rel = try RelativePath(validating: entry.path)
                try materialize(hash: entry.hash, mtimeNs: entry.mtimeNs, writer: writer, target: rel)
            } catch {
                failures[entry.path] = String(describing: error)
            }
        }
        return (folder, failures)
    }

    // MARK: Restore into destination

    /// Places an old version next to the destination file as `name_RESTORED.ext`. The new file is
    /// not tracked (it belongs to the user), so later synchronizations never modify or delete it.
    public func restoreBeside(pair: FolderPair, destination: String, path: String, hash: String, mtimeNs: Int64?) throws -> String {
        let lock = try PairLock(directory: storage.root.appendingPathComponent("locks"), pair: pair.id)
        defer { withExtendedLifetime(lock) {} }
        let writer = DestinationWriter(rootPath: destination)
        let rel = try RelativePath(validating: path)
        let seq = try catalog.beginCommit(pair: pair.id, kind: .restore, message: "Restored \(rel.name)")
        do {
            let target = try writer.uniqueSibling(of: rel, marker: "RESTORED", date: Date())
            let out = try materialize(hash: hash, mtimeNs: mtimeNs, writer: writer, target: target, allowOriginalName: true)
            try catalog.addChange(FileChange(
                id: 0, commitSeq: seq, kind: .restored, path: out.string, oldPath: rel.string, oldSize: nil,
                newSize: store.storedSize(hash), oldMtimeNs: nil, newMtimeNs: mtimeNs, oldHash: nil, newHash: hash,
                status: .applied, error: nil, archivePath: nil
            ), pair: pair.id)
            try catalog.finishCommit(seq: seq)
            catalog.log(pair.id, .info, "\(pair.name): restored a previous version of \(rel.string) as \(out.name)")
            return out.absolute(in: destination)
        } catch {
            _ = try? catalog.finishCommit(seq: seq, status: .failed, message: String(describing: error))
            throw error
        }
    }

    /// Rewrites the destination so it matches the snapshot of commit `seq`. Every file that is
    /// replaced or removed is first preserved in the version store. Callers must pause automatic
    /// synchronization for the pair, otherwise the next sync re-applies the current source state
    /// (which is the correct one-way behavior, and also fully versioned).
    public func restoreDestination(pair: FolderPair, destination: String, toCommit seq: Int64) throws -> Commit {
        let lock = try PairLock(directory: storage.root.appendingPathComponent("locks"), pair: pair.id)
        defer { withExtendedLifetime(lock) {} }
        let writer = DestinationWriter(rootPath: destination)
        let target = Dictionary(uniqueKeysWithValues: try catalog.snapshot(pair: pair.id, at: seq).compactMap { e in
            (try? RelativePath(validating: e.path)).map { ($0, e) }
        })
        // Refuse up front if any needed version is unavailable: a partial restore is worse than none.
        for e in target.values where !store.contains(e.hash) {
            let current = try catalog.trackedFiles(pair.id)
            if let rel = try? RelativePath(validating: e.path), current[rel]?.hash == e.hash { continue }
            throw RestoreError.notStored(e.hash)
        }
        let tracked = try catalog.trackedFiles(pair.id)
        let commitSeq = try catalog.beginCommit(pair: pair.id, kind: .restore, restoredFrom: seq, message: "Destination restored to an earlier snapshot")

        func fail(_ path: String, _ kind: ChangeKind, _ error: Error) {
            _ = try? catalog.addChange(FileChange(id: 0, commitSeq: commitSeq, kind: kind, path: path, oldPath: nil, oldSize: nil, newSize: nil,
                                              oldMtimeNs: nil, newMtimeNs: nil, oldHash: nil, newHash: nil, status: .failed,
                                              error: String(describing: error), archivePath: nil), pair: pair.id)
        }

        for (path, entry) in target.sorted(by: { $0.key < $1.key }) {
            let current = tracked[path]
            if current?.hash == entry.hash { continue }
            do {
                if let current {
                    guard let ds = try writer.stat(path), ds.size == current.size, try ds.mtimeNs == current.destMtimeNs || writer.hash(path) == current.hash else {
                        throw FSError.destinationChanged(path.string)
                    }
                    try storage.engine.ensureStored(current.hash, from: path, writer: writer)
                } else if try writer.stat(path) != nil {
                    throw FSError.alreadyExists(path.string) // occupied by a file we do not own
                }
                if let parent = path.parent { try writer.ensureDirectory(parent) }
                try materialize(hash: entry.hash, mtimeNs: entry.mtimeNs, writer: writer, target: path, replace: current != nil)
                guard let ds = try writer.stat(path) else { throw FSError.destinationChanged(path.string) }
                try catalog.db.transaction {
                    try storage.engine.recordPublished(pair: pair.id, seq: commitSeq, path: path, hash: entry.hash, destStat: ds,
                                                       previous: current, kind: .restored, sourceStat: nil, bytes: nil)
                    try catalog.removeSourceIndex(pair.id, path)
                }
            } catch {
                fail(path.string, .restored, error)
            }
        }
        for (path, current) in tracked where target[path] == nil {
            do {
                guard let ds = try writer.stat(path), ds.size == current.size, (try writer.hash(path)) == current.hash else {
                    throw FSError.destinationChanged(path.string)
                }
                try storage.engine.ensureStored(current.hash, from: path, writer: writer)
                try writer.removeFile(path)
                try catalog.db.transaction {
                    try storage.engine.recordRemoved(pair: pair.id, seq: commitSeq, path: path, tracked: current, policy: nil, archivePath: nil,
                                                     note: "Removed to match restored snapshot (preserved in history)")
                }
            } catch {
                fail(path.string, .untracked, error)
            }
        }
        let commit = try catalog.finishCommit(seq: commitSeq)
        catalog.log(pair.id, .warning, "\(pair.name): destination restored to snapshot \(seq) (commit \(commit.shortID))")
        return commit
    }

    // MARK: Archives

    public enum ArchiveRestoreMode: Sendable {
        /// Put the file back at its original destination path (or a `_RESTORED` name if occupied).
        case originalLocation
        /// Write a copy into a user-selected folder.
        case export(directory: String)
    }

    /// Restored archives become ordinary user-owned files (untracked) so the next sync does not
    /// delete them again.
    public func restoreArchive(_ archive: ArchiveRecord, destination: String, mode: ArchiveRestoreMode) throws -> String {
        guard archive.state != .restored else { throw RestoreError.archiveNotRestorable }
        let original = try RelativePath(validating: archive.originalPath)
        switch mode {
        case let .export(directory):
            return try exportVersion(hash: archive.hash, fileName: original.name, mtimeNs: archive.mtimeNs, to: directory)
        case .originalLocation:
            let lock = try PairLock(directory: storage.root.appendingPathComponent("locks"), pair: archive.pairID)
            defer { withExtendedLifetime(lock) {} }
            let writer = DestinationWriter(rootPath: destination)
            let out: RelativePath
            if archive.state == .present, let ap = archive.archivePath.flatMap({ try? RelativePath(validating: $0) }),
               let st = try writer.stat(ap), st.isRegularFile, try writer.hash(ap) == archive.hash {
                if try writer.stat(original) == nil {
                    try writer.move(ap, to: original)
                    out = original
                } else {
                    out = ap // original name taken: leave it under its archive name, now user-owned
                }
            } else {
                if let parent = original.parent { try writer.ensureDirectory(parent) }
                out = try materialize(hash: archive.hash, mtimeNs: archive.mtimeNs, writer: writer, target: original)
            }
            try catalog.updateArchive(archive.id, state: .restored, archivePath: out.string)
            catalog.log(archive.pairID, .info, "Archived file \(archive.originalPath) restored to \(out.string)")
            return out.absolute(in: destination)
        }
    }

    // MARK: Explicit, authorized source restore

    /// Writes a historical version into the **source** folder as a new `_RESTORED` file. Never
    /// overwrites anything. Requires a `SourceWriteAuthorization` obtained from an explicit dialog.
    public func restoreIntoSource(_ authorization: SourceWriteAuthorization, pair: FolderPair, source: String,
                                  path: String, hash: String, mtimeNs: Int64?) throws -> String {
        guard authorization.pairID == pair.id else { throw RestoreError.authorizationMismatch }
        let writer = DestinationWriter(rootPath: source)
        let rel = try RelativePath(validating: path)
        let target = try writer.uniqueSibling(of: rel, marker: "RESTORED", date: Date())
        if let parent = target.parent { try writer.ensureDirectory(parent) }
        let out = try materialize(hash: hash, mtimeNs: mtimeNs, writer: writer, target: target)
        catalog.log(pair.id, .warning, "\(pair.name): user-authorized restore wrote \(out.string) into the SOURCE folder")
        return out.absolute(in: source)
    }
}
