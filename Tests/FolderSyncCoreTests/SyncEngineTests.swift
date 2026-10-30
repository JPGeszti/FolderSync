import Foundation
import Testing
@testable import FolderSyncCore

@Suite("One-way synchronization")
struct SyncEngineTests {
    @Test func initialSyncCopiesTreeAndNeverTouchesSource() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        try f.write("docs/b.pdf", "beta")
        try f.write("docs/deep/c.bin", randomData(10_000))
        try FileManager.default.createDirectory(at: f.src.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let before = f.sourceFingerprint()

        let report = try f.sync()

        #expect(f.sourceFingerprint() == before)
        #expect(f.tree(f.dst) == f.tree(f.src))
        #expect(f.exists("empty"))
        let commit = try #require(report.commit)
        #expect(commit.status == .success)
        #expect(commit.added == 3)
        #expect(commit.bytesTransferred == 5 + 4 + 10_000)
        #expect(try f.catalog.verifyHistoryChain(f.pair.id).isEmpty)
    }

    @Test func secondSyncWithoutChangesCreatesNoCommitAndHashesNothing() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        try f.sync()
        let report = try f.sync()
        #expect(report.commit == nil)
        #expect(report.plan.indexRefresh.isEmpty)
        #expect(try f.catalog.commits(pair: f.pair.id).count == 1)
    }

    @Test func modificationUpdatesDestinationAndKeepsPreviousVersion() throws {
        let f = try Fixture()
        try f.write("report.xlsx", "version 1", mtimeOffset: -100)
        try f.sync()
        try f.write("report.xlsx", "version 2 is longer")
        let report = try f.sync()

        #expect(f.read("report.xlsx") == "version 2 is longer")
        let change = try #require(try f.changes(of: report.commit).first)
        #expect(change.kind == .modified)
        #expect(change.oldHash == sha256Hex("version 1"))
        #expect(change.newHash == sha256Hex("version 2 is longer"))
        #expect(change.oldSize == 9)
        #expect(change.newSize == 19)
        #expect(f.storage.store.contains(sha256Hex("version 1")))

        let versions = try f.catalog.fileVersions(pair: f.pair.id, path: "report.xlsx", store: f.storage.store)
        #expect(versions.map(\.hash) == [sha256Hex("version 2 is longer"), sha256Hex("version 1")])
        #expect(versions.allSatisfy { $0.isStored })
    }

    @Test func touchedButIdenticalFileIsNotRewritten() throws {
        let f = try Fixture()
        try f.write("same.txt", "unchanged", mtimeOffset: -1000)
        try f.sync()
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.src.appendingPathComponent("same.txt").path)
        let report = try f.sync()
        #expect(report.commit == nil)
        #expect(report.plan.indexRefresh.count == 1)
    }

    @Test func replacedOnlyVersioningStoresOldVersionBeforeOverwrite() throws {
        let f = try Fixture(versioning: .replacedOnly)
        try f.write("x.doc", "first", mtimeOffset: -100)
        try f.sync()
        #expect(!f.storage.store.contains(sha256Hex("first")))
        try f.write("x.doc", "second!")
        try f.sync()
        #expect(f.storage.store.contains(sha256Hex("first")))
        #expect(f.read("x.doc") == "second!")
    }

    @Test func largeFileIsStreamedAndVerified() throws {
        let f = try Fixture()
        let big = randomData(ObjectStore.chunkSize * 5 + 12_345)
        try f.write("video.mov", big)
        let report = try f.sync()
        #expect(report.commit?.status == .success)
        #expect(try Data(contentsOf: f.dst.appendingPathComponent("video.mov")) == big)
        let hash = try #require(try f.changes(of: report.commit).first?.newHash)
        try f.storage.store.verify(hash)
    }

    @Test func renameIsDetectedAndAppliedWithoutCopying() throws {
        let f = try Fixture()
        try f.write("old-name.txt", "contents that move")
        try f.sync()
        try FileManager.default.moveItem(at: f.src.appendingPathComponent("old-name.txt"), to: f.src.appendingPathComponent("new-name.txt"))
        let report = try f.sync()
        let commit = try #require(report.commit)
        #expect(commit.renamed == 1)
        #expect(commit.bytesTransferred == 0)
        #expect(!f.exists("old-name.txt"))
        #expect(f.read("new-name.txt") == "contents that move")
        #expect(f.tree(f.dst) == f.tree(f.src))
    }

    @Test func folderRenameMovesAllFilesAndRemovesOldFolder() throws {
        let f = try Fixture()
        try f.write("Projects/Alpha/one.txt", "1")
        try f.write("Projects/Alpha/two.txt", "22")
        try f.write("Projects/Alpha/sub/three.txt", "333")
        try f.sync()
        try FileManager.default.moveItem(at: f.src.appendingPathComponent("Projects/Alpha"), to: f.src.appendingPathComponent("Projects/Beta"))
        let report = try f.sync()
        #expect(report.commit?.renamed == 3)
        #expect(!f.exists("Projects/Alpha"))
        #expect(f.tree(f.dst) == f.tree(f.src))
    }

    @Test func missingDestinationCopyIsRepaired() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        try f.sync()
        try FileManager.default.removeItem(at: f.dst.appendingPathComponent("a.txt"))
        let report = try f.sync()
        #expect(try f.changes(of: report.commit).first?.kind == .repaired)
        #expect(f.read("a.txt") == "alpha")
    }

    @Test func excludedAndTemporaryNamesAreNotSynchronized() throws {
        let f = try Fixture()
        try f.write(".DS_Store", "finder")
        try f.write("._resource", "appledouble")
        try f.write(".foldersync-tmp-evil", "pretend temp")
        try f.write("keep.txt", "ok")
        try f.sync()
        #expect(f.exists("keep.txt"))
        #expect(!f.exists(".DS_Store"))
        #expect(!f.exists("._resource"))
        #expect(!f.exists(".foldersync-tmp-evil"))
    }

    @Test func dryRunChangesNothing() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        let report = try f.sync(SyncOptions(dryRun: true))
        #expect(report.plan.copies.count == 1)
        #expect(report.commit == nil)
        #expect(f.tree(f.dst).isEmpty)
        #expect(try f.catalog.commits(pair: f.pair.id).isEmpty)
    }

    @Test func selectiveSyncAppliesOnlyChosenChanges() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        try f.write("dir/b.txt", "beta")
        let report = try f.sync(SyncOptions(limitTo: ["dir/b.txt"]))
        #expect(report.commit?.added == 1)
        #expect(f.read("dir/b.txt") == "beta")
        #expect(!f.exists("a.txt"))
        #expect(try f.sync(SyncOptions(dryRun: true)).plan.copies.map(\.path.string) == ["a.txt"])
    }

    @Test func concurrentRunsOnSamePairAreRejected() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        let hold = try PairLock(directory: f.appRoot.appendingPathComponent("locks"), pair: f.pair.id)
        #expect(throws: SyncError.busy) { try f.sync() }
        withExtendedLifetime(hold) {}
    }

    @Test func manyFilesInitialAndIncrementalSync() throws {
        let f = try Fixture()
        for i in 0..<2000 { try f.write("bulk/dir\(i % 40)/file\(i).dat", "payload \(i)") }
        let start = Date()
        let first = try f.sync()
        let initial = Date().timeIntervalSince(start)
        #expect(first.commit?.added == 2000)
        try f.write("bulk/dir3/file3.dat", "changed payload")
        let t2 = Date()
        let second = try f.sync()
        let incremental = Date().timeIntervalSince(t2)
        #expect(second.commit?.modified == 1)
        #expect(second.plan.indexRefresh.count <= 1)
        // Incremental runs must not re-copy or re-hash the tree.
        let budget = max(initial, 1.0)
        #expect(incremental < budget)
        #expect(f.tree(f.dst) == f.tree(f.src))
    }
}

@Suite("Deletion policies")
struct DeletionPolicyTests {
    @Test func preserveRenameKeepsExtensionAndIsNotTreatedAsSource() throws {
        let f = try Fixture(policy: .preserveRename)
        try f.write("anchor.txt", "keeps the source non-empty")
        try f.write("financial_report.xlsx", "numbers")
        try f.sync()
        try f.remove("financial_report.xlsx")
        let report = try f.sync()

        #expect(report.commit?.archived == 1)
        #expect(!f.exists("financial_report.xlsx"))
        #expect(f.read("financial_report_DELETED.xlsx") == "numbers")
        let archive = try #require(f.catalog.archives(pair: f.pair.id).first)
        #expect(archive.originalPath == "financial_report.xlsx")
        #expect(archive.archivePath == "financial_report_DELETED.xlsx")
        #expect(archive.state == .present)
        #expect(archive.commitSeq == report.commit?.seq)
        // The archive is owned by FolderSync, not mistaken for a new or deleted source file.
        #expect(try f.sync().commit == nil)
        #expect(f.read("financial_report_DELETED.xlsx") == "numbers")
    }

    @Test func repeatedDeletionAndRecreationCreatesUniqueArchives() throws {
        let f = try Fixture(policy: .preserveRename)
        try f.write("anchor.txt", "keeps the source non-empty")
        for round in 1...3 {
            try f.write("plan.docx", "round \(round)")
            try f.sync()
            try f.remove("plan.docx")
            try f.sync()
        }
        let archives = try f.catalog.archives(pair: f.pair.id)
        #expect(archives.count == 3)
        let names = Set(archives.compactMap(\.archivePath))
        #expect(names.count == 3)
        #expect(names.contains("plan_DELETED.docx"))
        #expect(names.allSatisfy { $0.hasPrefix("plan_DELETED") && $0.hasSuffix(".docx") })
        let contents = Set(names.compactMap { f.read($0) })
        #expect(contents == ["round 1", "round 2", "round 3"])
    }

    @Test func newSourceFileWithArchiveNameRelocatesArchive() throws {
        let f = try Fixture(policy: .preserveRename)
        try f.write("anchor.txt", "keeps the source non-empty")
        try f.write("memo.txt", "old memo")
        try f.sync()
        try f.remove("memo.txt")
        try f.sync()
        #expect(f.read("memo_DELETED.txt") == "old memo")
        // A genuine source file now uses the archive's name.
        try f.write("memo_DELETED.txt", "a real file")
        try f.sync()
        #expect(f.read("memo_DELETED.txt") == "a real file")
        let archive = try #require(f.catalog.archives(pair: f.pair.id).first)
        let moved = try #require(archive.archivePath)
        #expect(moved != "memo_DELETED.txt")
        #expect(f.read(moved) == "old memo")
    }

    @Test func moveToTrashUsesTrashHandler() throws {
        let f = try Fixture(policy: .moveToTrash)
        try f.write("anchor.txt", "keeps the source non-empty")
        try f.write("draft.txt", "draft")
        try f.sync()
        try f.remove("draft.txt")
        let report = try f.sync()
        #expect(report.commit?.archived == 1)
        #expect(!f.exists("draft.txt"))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: f.trashDir.path)
        #expect(trashed.count == 1)
        #expect(try f.catalog.archives(pair: f.pair.id).first?.state == .trashed)
        #expect(f.storage.store.contains(sha256Hex("draft")))
    }

    @Test func permanentDeletionRequiresExplicitConfirmation() throws {
        let f = try Fixture(policy: .permanentDelete, confirmPermanent: false)
        try f.write("anchor.txt", "keeps the source non-empty")
        try f.write("a.txt", "alpha")
        try f.sync()
        try f.remove("a.txt")
        try f.sync()
        // Not confirmed: degraded to the non-destructive policy.
        #expect(f.read("a_DELETED.txt") == "alpha")
    }

    @Test func permanentDeletionWhenConfirmedKeepsVersionInStore() throws {
        let f = try Fixture(policy: .permanentDelete, confirmPermanent: true)
        try f.write("anchor.txt", "keeps the source non-empty")
        try f.write("a.txt", "alpha")
        try f.sync()
        try f.remove("a.txt")
        let report = try f.sync()
        #expect(report.commit?.deleted == 1)
        #expect(f.tree(f.dst).keys.sorted() == ["anchor.txt"])
        #expect(f.storage.store.contains(sha256Hex("alpha")))
        #expect(try f.catalog.archives(pair: f.pair.id).first?.state == .purged)
    }

    @Test func massDeletionIsBlockedUntilConfirmed() throws {
        let f = try Fixture(policy: .permanentDelete, confirmPermanent: true)
        f.pair.massDeletionThresholdCount = 5
        try f.catalog.savePair(f.pair)
        for i in 0..<30 { try f.write("f\(i).txt", "\(i)") }
        try f.sync()
        for i in 0..<20 { try f.remove("f\(i).txt") }
        let blocked = try f.sync()
        #expect(blocked.deletionBlock == .massDeletion(count: 20, tracked: 30))
        #expect(f.tree(f.dst).count == 30)
        let confirmed = try f.sync(SyncOptions(allowMassDeletion: true))
        #expect(confirmed.commit?.deleted == 20)
        #expect(f.tree(f.dst).count == 10)
    }

    @Test func emptySourceNeverTriggersDeletion() throws {
        let f = try Fixture(policy: .permanentDelete, confirmPermanent: true)
        try f.write("a.txt", "alpha")
        try f.write("b.txt", "beta")
        try f.sync()
        try f.remove("a.txt")
        try f.remove("b.txt")
        let report = try f.sync()
        #expect(report.deletionBlock == .sourceAppearsEmpty(tracked: 2))
        #expect(f.read("a.txt") == "alpha")
        #expect(f.read("b.txt") == "beta")
    }

    @Test func untrackedDestinationFilesAreNeverDeleted() throws {
        let f = try Fixture(policy: .permanentDelete, confirmPermanent: true)
        try f.write("tracked.txt", "t")
        try f.write("mine.txt", "user's own file", in: f.dst)
        try f.sync()
        try f.remove("tracked.txt")
        try f.write("other.txt", "keep source non-empty")
        try f.sync()
        #expect(f.read("mine.txt") == "user's own file")
        #expect(!f.exists("tracked.txt"))
    }
}

@Suite("Availability and conflicts")
struct AvailabilityTests {
    @Test func unavailableSourceDeletesNothing() throws {
        let f = try Fixture(policy: .permanentDelete, confirmPermanent: true)
        try f.write("a.txt", "alpha")
        try f.sync()
        try FileManager.default.moveItem(at: f.src, to: f.base.appendingPathComponent("unplugged"))
        #expect(throws: PairValidationError.self) { try f.sync() }
        #expect(f.read("a.txt") == "alpha")
    }

    @Test func replacedSourceFolderIsDetectedAsDifferentIdentity() throws {
        let f = try Fixture(policy: .permanentDelete, confirmPermanent: true)
        try f.write("a.txt", "alpha")
        try f.sync()
        // Simulates an empty mount-point folder appearing where a drive used to be mounted.
        try FileManager.default.moveItem(at: f.src, to: f.base.appendingPathComponent("unplugged"))
        try FileManager.default.createDirectory(at: f.src, withIntermediateDirectories: true)
        #expect(throws: PairValidationError.sourceIdentityChanged) { try f.sync() }
        #expect(f.read("a.txt") == "alpha")
    }

    @Test func unavailableDestinationIsReported() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        try FileManager.default.removeItem(at: f.dst)
        #expect(throws: PairValidationError.self) { try f.sync() }
        #expect(!FileManager.default.fileExists(atPath: f.dst.path))
    }

    @Test func externallyModifiedDestinationBecomesConflict() throws {
        let f = try Fixture()
        try f.write("contract.pdf", "signed v1", mtimeOffset: -50)
        try f.sync()
        try f.write("contract.pdf", "edited directly in destination", in: f.dst)
        try f.write("contract.pdf", "signed v2")
        let report = try f.sync()
        #expect(report.conflicts.map(\.path) == ["contract.pdf"])
        #expect(report.conflicts.first?.kind == .destinationModified)
        #expect(f.read("contract.pdf") == "edited directly in destination")

        // User chooses to overwrite: the destination edit is preserved in history first.
        try f.catalog.setOverride(f.pair.id, path: "contract.pdf", .overwriteDestination)
        let resolved = try f.sync()
        #expect(resolved.conflicts.isEmpty)
        #expect(f.read("contract.pdf") == "signed v2")
        #expect(f.storage.store.contains(sha256Hex("edited directly in destination")))
        #expect(try f.catalog.overrides(f.pair.id).isEmpty)
    }

    @Test func unknownFileAtDestinationPathIsConflictUnlessIdentical() throws {
        let f = try Fixture()
        try f.write("same.txt", "identical")
        try f.write("same.txt", "identical", in: f.dst)
        try f.write("diff.txt", "source version")
        try f.write("diff.txt", "someone else's file", in: f.dst)
        let report = try f.sync()
        #expect(try f.changes(of: report.commit).map(\.kind) == [.adopted])
        #expect(report.conflicts.map(\.path) == ["diff.txt"])
        #expect(f.read("diff.txt") == "someone else's file")
    }

    @Test func modifiedDestinationIsNotDeleted() throws {
        let f = try Fixture(policy: .permanentDelete, confirmPermanent: true)
        try f.write("a.txt", "alpha", mtimeOffset: -50)
        try f.write("b.txt", "beta")
        try f.sync()
        try f.write("a.txt", "user changed this", in: f.dst)
        try f.remove("a.txt")
        let report = try f.sync()
        #expect(report.conflicts.first?.kind == .destinationModifiedBeforeDeletion)
        #expect(f.read("a.txt") == "user changed this")
    }

    @Test func ignoredPathIsLeftAlone() throws {
        let f = try Fixture()
        try f.write("skip.txt", "source")
        try f.write("skip.txt", "dest", in: f.dst)
        try f.catalog.setOverride(f.pair.id, path: "skip.txt", .ignore)
        let report = try f.sync()
        #expect(report.conflicts.isEmpty)
        #expect(f.read("skip.txt") == "dest")
    }

    @Test func caseCollisionsAreReportedForCaseInsensitiveDestination() throws {
        let pair = FolderPair(name: "p", sourcePath: "/s", destinationPath: "/d")
        var scan = ScanResult()
        let st = FileStat(device: 1, inode: 1, size: 1, mtimeNs: 1, mode: UInt16(S_IFREG) | 0o644)
        scan.files[try RelativePath(validating: "Readme.md")] = st
        scan.files[try RelativePath(validating: "README.md")] = FileStat(device: 1, inode: 2, size: 1, mtimeNs: 1, mode: st.mode)
        let planner = Planner(pair: pair, scan: scan, sourceIndex: [:], tracked: [:], trackedDirs: [], archivesByPath: [:], overrides: [:],
                              destinationCaseSensitive: false, allowMassDeletion: false,
                              destStat: { _ in nil }, hashSource: { p, _ in p.string }, hashDestination: { $0.string })
        let plan = try planner.plan()
        #expect(plan.copies.count == 1)
        #expect(plan.conflicts.first?.kind == .caseCollision)
    }

    @Test func nestedOrIdenticalFoldersAreRejected() throws {
        let f = try Fixture()
        let inner = f.src.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        #expect(throws: PairValidationError.destinationInsideSource) {
            try PairValidator.checkLayout(source: f.src.path, destination: inner.path, storeRoot: nil)
        }
        #expect(throws: PairValidationError.sourceInsideDestination) {
            try PairValidator.checkLayout(source: inner.path, destination: f.src.path, storeRoot: nil)
        }
        #expect(throws: PairValidationError.sameFolder) {
            try PairValidator.checkLayout(source: f.src.path, destination: f.src.path + "/.", storeRoot: nil)
        }
        #expect(throws: PairValidationError.storeInsideFolder) {
            try PairValidator.checkLayout(source: f.src.path, destination: f.dst.path, storeRoot: inner.path)
        }
        // A symlinked alias of the source used as destination is the same folder.
        let alias = f.base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.src)
        #expect(throws: PairValidationError.sameFolder) {
            try PairValidator.checkLayout(source: f.src.path, destination: alias.path, storeRoot: nil)
        }
    }

    @Test func permissionFailureIsRecordedAndOtherFilesStillSync() throws {
        let f = try Fixture()
        try f.write("ok.txt", "fine")
        let locked = try f.write("locked.txt", "secret")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o644) }
        let report = try f.sync()
        let commit = try #require(report.commit)
        #expect(commit.status == .partial)
        #expect(commit.failed == 1)
        #expect(f.read("ok.txt") == "fine")
        #expect(!f.exists("locked.txt"))
        let failed = try f.changes(of: commit).first { $0.status == .failed }
        #expect(failed?.path == "locked.txt")
        let leaked = failed?.error?.contains("secret") ?? false
        #expect(!leaked) // errors carry paths, never contents
    }

    @Test func readOnlyDestinationFolderFailsSafely() throws {
        let f = try Fixture()
        try f.write("sub/a.txt", "alpha")
        try f.sync()
        try f.write("sub/b.txt", "beta")
        chmod(f.dst.appendingPathComponent("sub").path, 0o555)
        defer { chmod(f.dst.appendingPathComponent("sub").path, 0o755) }
        let report = try f.sync()
        #expect(report.commit?.status == .failed)
        #expect(f.read("sub/a.txt") == "alpha")
        // No temp files left behind.
        chmod(f.dst.appendingPathComponent("sub").path, 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.dst.appendingPathComponent("sub").path) == ["a.txt"])
    }

    @Test func sourceChangingDuringCopyIsDiscardedAndRetried() throws {
        let f = try Fixture()
        let url = try f.write("growing.log", "line 1\n")
        f.engine.faultInjector = { op, _ in
            if op == "copied" {
                let h = try FileHandle(forWritingTo: url)
                try h.seekToEnd()
                try h.write(contentsOf: Data("line 2\n".utf8))
                try h.close()
            }
        }
        let report = try f.sync()
        #expect(try f.changes(of: report.commit).first?.status == .skipped)
        #expect(!f.exists("growing.log"))
        #expect(f.tree(f.dst, includeHidden: true).isEmpty) // temp file cleaned up
        f.engine.faultInjector = nil
        try f.sync()
        #expect(f.read("growing.log") == "line 1\nline 2\n")
    }

    @Test func concurrentSourceChangesConverge() throws {
        let f = try Fixture()
        for i in 0..<50 { try f.write("c/\(i).txt", "v0-\(i)") }
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            for i in 0..<50 { try? f.write("c/\(i).txt", "v1-\(i)-changed") }
        }
        _ = try? f.sync()
        group.wait()
        try f.sync()
        #expect(f.tree(f.dst) == f.tree(f.src))
        #expect(try f.catalog.verifyHistoryChain(f.pair.id).isEmpty)
    }
}
