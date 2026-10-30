import Foundation
import Testing
@testable import FolderSyncCore

@Suite("Snapshots, comparison and restoration")
struct HistoryAndRestoreTests {
    /// Three commits: {a1, b1} → {a2, b1, c1} → {a2, c1} (b deleted).
    func threeCommits(_ f: Fixture) throws -> [Commit] {
        try f.write("a.txt", "a1", mtimeOffset: -300)
        try f.write("b.txt", "b1", mtimeOffset: -300)
        try f.sync()
        try f.write("a.txt", "a2-changed", mtimeOffset: -200)
        try f.write("c.txt", "c1", mtimeOffset: -200)
        try f.sync()
        try f.remove("b.txt")
        try f.sync()
        return try f.catalog.commits(pair: f.pair.id).reversed()
    }

    @Test func snapshotsReflectExactStatePerCommit() throws {
        let f = try Fixture()
        let c = try threeCommits(f)
        #expect(c.count == 3)
        #expect(try f.catalog.snapshot(pair: f.pair.id, at: c[0].seq).map(\.path) == ["a.txt", "b.txt"])
        #expect(try f.catalog.snapshot(pair: f.pair.id, at: c[1].seq).map(\.hash) == [sha256Hex("a2-changed"), sha256Hex("b1"), sha256Hex("c1")])
        #expect(try f.catalog.snapshot(pair: f.pair.id, at: c[2].seq).map(\.path) == ["a.txt", "c.txt"])
    }

    @Test func compareIsMetadataBased() throws {
        let f = try Fixture()
        let c = try threeCommits(f)
        let diff = try f.catalog.compare(pair: f.pair.id, from: c[0].seq, to: c[2].seq)
        #expect(diff.map(\.path) == ["a.txt", "b.txt", "c.txt"])
        #expect(diff.map(\.kind) == [.modified, .removed, .added])
        #expect(diff[0].before?.size == 2)
        #expect(diff[0].after?.size == 10)
    }

    @Test func restoreDestinationToEarlierSnapshotAndBack() throws {
        let f = try Fixture(policy: .permanentDelete, confirmPermanent: true)
        let c = try threeCommits(f)
        let sourceBefore = f.sourceFingerprint()
        let restorer = Restorer(storage: f.storage)
        let commit = try restorer.restoreDestination(pair: f.pair, destination: f.dst.path, toCommit: c[0].seq)
        #expect(commit.kind == .restore)
        #expect(commit.restoredFromSeq == c[0].seq)
        #expect(commit.status == .success)
        #expect(f.tree(f.dst) == ["a.txt": sha256Hex("a1"), "b.txt": sha256Hex("b1")])
        #expect(f.sourceFingerprint() == sourceBefore)
        // c.txt was removed from the destination but is still recoverable.
        #expect(f.storage.store.contains(sha256Hex("c1")))
        // Resuming synchronization re-applies the authoritative source state, with no conflicts.
        let resync = try f.sync()
        #expect(resync.conflicts.isEmpty)
        #expect(f.tree(f.dst) == f.tree(f.src))
        #expect(try f.catalog.verifyHistoryChain(f.pair.id).isEmpty)
    }

    @Test func restoreBesideNeverOverwritesAndIsLeftAloneBySync() throws {
        let f = try Fixture()
        _ = try threeCommits(f)
        let restorer = Restorer(storage: f.storage)
        let out = try restorer.restoreBeside(pair: f.pair, destination: f.dst.path, path: "a.txt", hash: sha256Hex("a1"), mtimeNs: nil)
        let restoredName = URL(fileURLWithPath: out).lastPathComponent
        #expect(restoredName == "a_RESTORED.txt")
        #expect(f.read("a.txt") == "a2-changed")
        #expect(f.read("a_RESTORED.txt") == "a1")
        #expect(try f.sync().commit == nil)
        #expect(f.read("a_RESTORED.txt") == "a1")
    }

    @Test func exportVersionAndSnapshotToSeparateFolder() throws {
        let f = try Fixture()
        let c = try threeCommits(f)
        let export = f.base.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        let restorer = Restorer(storage: f.storage)
        let file = try restorer.exportVersion(hash: sha256Hex("b1"), fileName: "b.txt", mtimeNs: nil, to: export.path)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "b1")
        let (folder, failures) = try restorer.exportSnapshot(pair: f.pair, seq: c[1].seq, to: export.path)
        #expect(failures.isEmpty)
        #expect(f.tree(URL(fileURLWithPath: folder)).count == 3)
    }

    @Test func restoringArchiveGivesFileBackWithoutResurrectingDeletion() throws {
        let f = try Fixture(policy: .preserveRename)
        try f.write("keep.txt", "k")
        try f.write("gone.txt", "precious")
        try f.sync()
        try f.remove("gone.txt")
        try f.sync()
        let archive = try #require(f.catalog.archives(pair: f.pair.id).first)
        let restorer = Restorer(storage: f.storage)
        _ = try restorer.restoreArchive(archive, destination: f.dst.path, mode: .originalLocation)
        #expect(f.read("gone.txt") == "precious")
        #expect(!f.exists("gone_DELETED.txt"))
        // Restored file is user-owned; the next sync neither deletes nor re-archives it.
        try f.sync()
        #expect(f.read("gone.txt") == "precious")
        #expect(try f.catalog.archive(archive.id)?.state == .restored)
    }

    @Test func restoringTrashedArchiveComesFromVersionStore() throws {
        let f = try Fixture(policy: .moveToTrash)
        try f.write("keep.txt", "k")
        try f.write("t.txt", "trashed content")
        try f.sync()
        try f.remove("t.txt")
        try f.sync()
        let archive = try #require(f.catalog.archives(pair: f.pair.id).first)
        _ = try Restorer(storage: f.storage).restoreArchive(archive, destination: f.dst.path, mode: .originalLocation)
        #expect(f.read("t.txt") == "trashed content")
    }

    @Test func sourceRestoreRequiresMatchingAuthorizationAndNeverOverwrites() throws {
        let f = try Fixture()
        _ = try threeCommits(f)
        let restorer = Restorer(storage: f.storage)
        let wrong = SourceWriteAuthorization.grantAfterExplicitUserConfirmation(pairID: UUID())
        #expect(throws: RestoreError.authorizationMismatch) {
            _ = try restorer.restoreIntoSource(wrong, pair: f.pair, source: f.src.path, path: "a.txt", hash: sha256Hex("a1"), mtimeNs: nil)
        }
        let ok = SourceWriteAuthorization.grantAfterExplicitUserConfirmation(pairID: f.pair.id)
        let out = try restorer.restoreIntoSource(ok, pair: f.pair, source: f.src.path, path: "a.txt", hash: sha256Hex("a1"), mtimeNs: nil)
        #expect(out.hasSuffix("a_RESTORED.txt"))
        #expect(f.read("a.txt", in: f.src) == "a2-changed")
    }

    @Test func retentionPrunesOldVersionsAndGarbageCollects() throws {
        let f = try Fixture()
        f.pair.retentionDays = 30
        try f.catalog.savePair(f.pair)
        _ = try threeCommits(f)
        let maintenance = Maintenance(storage: f.storage)
        // Nothing is old enough yet.
        #expect(try maintenance.applyRetention(pair: f.pair).versionsPruned == 0)
        #expect(try maintenance.collectGarbage() == 0)

        let later = Date().addingTimeInterval(31 * 86_400)
        let result = try maintenance.applyRetention(pair: f.pair, now: later)
        #expect(result.versionsPruned == 2) // a1 (replaced), b1 (deleted & archived → archive keeps its hash)
        let removed = try maintenance.collectGarbage()
        #expect(removed == 1) // a1 only; b1 is still referenced by its present archive
        #expect(!f.storage.store.contains(sha256Hex("a1")))
        #expect(f.storage.store.contains(sha256Hex("b1")))
        #expect(f.storage.store.contains(sha256Hex("a2-changed")))
        #expect(f.storage.store.contains(sha256Hex("c1")))
        #expect(maintenance.verifyStore().isEmpty)
    }

    @Test func destinationVerificationFindsSilentCorruption() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        try f.sync()
        let url = f.dst.appendingPathComponent("a.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        try Data("alphX".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: url.path)
        let problems = try Maintenance(storage: f.storage).verifyDestination(pair: f.pair, destination: f.dst.path)
        #expect(problems["a.txt"] != nil)
    }
}
