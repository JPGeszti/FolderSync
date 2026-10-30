import Darwin
import Foundation

/// Brings the database back in line with the filesystem after an interrupted run.
///
/// Every mutating operation writes an intent row *before* touching the destination. For each
/// leftover intent, recovery inspects the real destination state and either rolls the bookkeeping
/// forward (the operation completed on disk) or discards it (it did not). Temporary files listed in
/// intents are removed. Open commits are closed with status `interrupted` — never `success`.
struct Recovery {
    let engine: SyncEngine
    var catalog: Catalog { engine.catalog }

    @discardableResult
    func recover(pair: FolderPair, writer: DestinationWriter) throws -> Int {
        let intents = try catalog.pendingIntents(pair.id)
        let openCommits = try catalog.interruptedCommits(pair.id)
        guard !intents.isEmpty || !openCommits.isEmpty else { return 0 }

        let tracked = try catalog.trackedFiles(pair.id)
        for intent in intents {
            do {
                try recover(intent, pair: pair, tracked: tracked, writer: writer)
            } catch {
                catalog.log(pair.id, .error, "\(pair.name): recovery of \(intent.op) \(intent.path.string) failed: \(error)")
            }
            if let temp = intent.temp { writer.removeTemporary(temp) }
            try catalog.removeIntent(intent.id)
        }
        for seq in openCommits {
            try catalog.finishCommit(seq: seq, status: .interrupted, message: "Interrupted; recovered on next run")
        }
        catalog.log(pair.id, .warning, "\(pair.name): recovered \(intents.count) interrupted operation(s)")
        return intents.count
    }

    private func recover(_ i: Catalog.Intent, pair: FolderPair, tracked: [RelativePath: TrackedFile], writer: DestinationWriter) throws {
        let note = "Recovered after interruption"
        switch i.op {
        case "copy":
            guard let expected = i.expectedHash, let ds = try writer.stat(i.path), ds.isRegularFile,
                  try writer.hash(i.path) == expected else {
                try addFailed(i, pair: pair, kind: i.priorHash == nil ? .added : .modified)
                return
            }
            if tracked[i.path]?.hash == expected { return } // already recorded
            try catalog.db.transaction {
                try engine.recordPublished(pair: pair.id, seq: i.commitSeq, path: i.path, hash: expected, destStat: ds,
                                           previous: tracked[i.path], kind: tracked[i.path] == nil ? .added : .modified,
                                           sourceStat: nil, bytes: nil, note: note)
            }

        case "rename":
            guard let to = i.path2, let prior = i.priorHash, let t = tracked[i.path] else { return }
            if try writer.stat(i.path) == nil, let ds = try writer.stat(to), ds.isRegularFile, try writer.hash(to) == prior {
                try catalog.db.transaction {
                    try engine.recordRenamed(pair: pair.id, seq: i.commitSeq, from: i.path, to: to, tracked: t, destStat: ds, sourceStat: nil, note: note)
                }
            } else {
                try addFailed(i, pair: pair, kind: .renamed)
            }

        case "archive", "trash", "delete":
            guard let t = tracked[i.path] else { return }
            let gone = try writer.stat(i.path) == nil
            let archiveOK = try i.op != "archive" || i.path2.flatMap { try writer.stat($0) } != nil
            let policy: DeletionPolicy = i.op == "archive" ? .preserveRename : i.op == "trash" ? .moveToTrash : .permanentDelete
            if gone && archiveOK {
                try catalog.db.transaction {
                    try engine.recordRemoved(pair: pair.id, seq: i.commitSeq, path: i.path, tracked: t, policy: policy,
                                             archivePath: i.op == "archive" ? i.path2 : nil, note: note)
                }
            } else {
                try addFailed(i, pair: pair, kind: policy == .preserveRename ? .archived : policy == .moveToTrash ? .trashed : .deleted)
            }

        case "relocate":
            guard let to = i.path2 else { return }
            if try writer.stat(i.path) == nil, try writer.stat(to) != nil,
               let a = try catalog.archives(pair: pair.id, states: [.present]).first(where: { $0.archivePath == i.path.string }) {
                try catalog.updateArchive(a.id, state: .present, archivePath: to.string)
            }

        default:
            break
        }
    }

    private func addFailed(_ i: Catalog.Intent, pair: FolderPair, kind: ChangeKind) throws {
        try catalog.addChange(FileChange(
            id: 0, commitSeq: i.commitSeq, kind: kind, path: (i.op == "rename" ? i.path2 ?? i.path : i.path).string,
            oldPath: i.op == "rename" ? i.path.string : nil, oldSize: nil, newSize: nil, oldMtimeNs: nil, newMtimeNs: nil,
            oldHash: i.priorHash, newHash: nil, status: .failed, error: "Interrupted before completion; destination left unchanged",
            archivePath: nil
        ), pair: pair.id)
    }
}
