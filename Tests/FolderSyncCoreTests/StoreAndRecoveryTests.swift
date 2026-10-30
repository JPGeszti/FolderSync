import CryptoKit
import Foundation
import Testing
@testable import FolderSyncCore

@Suite("Encrypted version store")
struct ObjectStoreTests {
    func makeStore(_ f: Fixture) -> ObjectStore { f.storage.store }

    func put(_ store: ObjectStore, _ data: Data) throws -> String {
        let w = try store.beginWrite()
        try data.withUnsafeBytes { try w.append($0) }
        return try w.finish()
    }

    func get(_ store: ObjectStore, _ hash: String) throws -> Data {
        var out = Data()
        try store.read(hash) { out.append(contentsOf: $0) }
        return out
    }

    @Test(arguments: [0, 1, 1000, ObjectStore.chunkSize, ObjectStore.chunkSize + 1, ObjectStore.chunkSize * 3 + 7])
    func roundTrip(size: Int) throws {
        let f = try Fixture()
        let data = randomData(size)
        let hash = try put(f.storage.store, data)
        #expect(hash == Data(SHA256.hash(data: data)).hexString)
        #expect(try get(f.storage.store, hash) == data)
    }

    @Test func contentIsEncryptedAtRestAndDeduplicated() throws {
        let f = try Fixture()
        let marker = Data("CONFIDENTIAL-PLAINTEXT-\(UUID().uuidString)".utf8)
        let h1 = try put(f.storage.store, marker)
        let h2 = try put(f.storage.store, marker)
        #expect(h1 == h2)
        #expect(f.storage.store.allHashes().count == 1)
        let raw = try Data(contentsOf: URL(fileURLWithPath: f.storage.store.objectPath(h1)))
        #expect(raw.range(of: marker) == nil)
    }

    @Test func tamperingIsDetected() throws {
        let f = try Fixture()
        let hash = try put(f.storage.store, randomData(ObjectStore.chunkSize + 500))
        let path = f.storage.store.objectPath(hash)
        chmod(path, 0o600)
        var raw = try Data(contentsOf: URL(fileURLWithPath: path))
        raw[raw.count - 40] ^= 0xFF
        try raw.write(to: URL(fileURLWithPath: path))
        #expect(throws: ObjectStoreError.self) { try f.storage.store.verify(hash) }
        #expect(Maintenance(storage: f.storage).verifyStore()[hash] != nil)
    }

    @Test func truncationIsDetected() throws {
        let f = try Fixture()
        let hash = try put(f.storage.store, randomData(ObjectStore.chunkSize * 2 + 10))
        let path = f.storage.store.objectPath(hash)
        chmod(path, 0o600)
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        // Drop the final chunk entirely: the remaining chunks are all individually valid.
        let finalChunkLength = 4 + 10 + 28
        try raw.prefix(raw.count - finalChunkLength).write(to: URL(fileURLWithPath: path))
        #expect(throws: ObjectStoreError.self) { try f.storage.store.verify(hash) }
    }

    @Test func wrongKeyIsRejected() throws {
        let f = try Fixture()
        #expect(throws: ObjectStoreError.wrongKey) {
            _ = try ObjectStore(root: f.storage.store.root, keyProvider: InMemoryKeyProvider())
        }
    }

    @Test func objectMovedToAnotherNameIsDetected() throws {
        let f = try Fixture()
        let a = try put(f.storage.store, Data("aaaa".utf8))
        let b = try put(f.storage.store, Data("bbbb".utf8))
        chmod(f.storage.store.objectPath(a), 0o600)
        chmod(f.storage.store.objectPath(b), 0o600)
        try FileManager.default.removeItem(atPath: f.storage.store.objectPath(a))
        try FileManager.default.copyItem(atPath: f.storage.store.objectPath(b), toPath: f.storage.store.objectPath(a))
        #expect(throws: ObjectStoreError.hashMismatch(expected: a, actual: b)) { try f.storage.store.verify(a) }
    }
}

/// Stands in for a Keychain that refuses access (denied prompt, missing entitlement, locked keychain).
struct FailingKeyProvider: KeyProvider {
    func loadOrCreateKey() throws -> SymmetricKey { throw KeychainError(status: errSecAuthFailed) }
}

@Suite("Key file fallback when the Keychain is unavailable")
struct KeyFallbackTests {
    @Test func createsPrivateKeyFileAndReusesIt() throws {
        let f = try Fixture()
        let file = f.base.appendingPathComponent("store-key.bin")
        let first = PreferredKeyProvider(keychain: FailingKeyProvider(), fallbackFile: file, allowCreatingFallback: true)
        let key = try first.loadOrCreateKey()
        #expect(first.source == .localFile)

        var st = stat()
        #expect(lstat(file.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(st.st_size == 32)

        // Once the store exists the file is reused and never regenerated.
        let again = PreferredKeyProvider(keychain: FailingKeyProvider(), fallbackFile: file, allowCreatingFallback: false)
        #expect(try again.loadOrCreateKey() == key)
        #expect(again.source == .localFile)
    }

    @Test func refusesToCreateKeyForExistingStore() throws {
        let f = try Fixture()
        let file = f.base.appendingPathComponent("store-key.bin")
        let keys = PreferredKeyProvider(keychain: FailingKeyProvider(), fallbackFile: file, allowCreatingFallback: false)
        #expect(throws: KeychainError.self) { try keys.loadOrCreateKey() }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func replacesTruncatedKeyFileForNewStore() throws {
        let f = try Fixture()
        let file = f.base.appendingPathComponent("store-key.bin")
        try Data([1, 2, 3]).write(to: file)
        let keys = PreferredKeyProvider(keychain: FailingKeyProvider(), fallbackFile: file, allowCreatingFallback: true)
        _ = try keys.loadOrCreateKey()
        #expect(try Data(contentsOf: file).count == 32)
    }

    @Test func storageOpensWithFallbackKey() throws {
        let f = try Fixture()
        let root = f.base.appendingPathComponent("fallback-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("store-key.bin")
        _ = try FolderSyncStorage(root: root, keyProvider: PreferredKeyProvider(keychain: FailingKeyProvider(), fallbackFile: file, allowCreatingFallback: true),
                                  trash: DirectoryTrash(directory: f.trashDir))
        _ = try FolderSyncStorage(root: root, keyProvider: PreferredKeyProvider(keychain: FailingKeyProvider(), fallbackFile: file, allowCreatingFallback: false),
                                  trash: DirectoryTrash(directory: f.trashDir))
    }
}

@Suite("Crash recovery and history integrity")
struct RecoveryTests {
    @Test func crashBeforePublishRollsBack() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        try f.write("b.txt", "beta")
        f.engine.faultInjector = { op, path in if op == "publish" && path.string == "b.txt" { throw InjectedCrash() } }
        #expect(throws: InjectedCrash.self) { try f.sync() }
        // State as left by a process that died: open commit, journal entry, temp file.
        #expect(try f.lastCommit()?.status == .inProgress)
        #expect(f.tree(f.dst, includeHidden: true).keys.contains { $0.hasPrefix(".foldersync-tmp-") })
        #expect(!f.exists("b.txt"))

        f.engine.faultInjector = nil
        let report = try f.sync()
        #expect(report.recoveredIntents == 1)
        #expect(!f.tree(f.dst, includeHidden: true).keys.contains { $0.hasPrefix(".foldersync-tmp-") })
        let commits = try f.catalog.commits(pair: f.pair.id)
        #expect(commits.map(\.status) == [.success, .interrupted])
        #expect(f.tree(f.dst) == f.tree(f.src))
        #expect(try f.catalog.verifyHistoryChain(f.pair.id).isEmpty)
    }

    @Test func crashAfterPublishBeforeBookkeepingRollsForward() throws {
        let f = try Fixture()
        try f.write("doc.txt", "v1", mtimeOffset: -100)
        try f.sync()
        try f.write("doc.txt", "v2-new")
        f.engine.faultInjector = { op, _ in if op == "record" { throw InjectedCrash() } }
        #expect(throws: InjectedCrash.self) { try f.sync() }
        #expect(f.read("doc.txt") == "v2-new") // on disk, but DB still says v1

        f.engine.faultInjector = nil
        let report = try f.sync()
        // Without the journal this would be misreported as an external destination modification.
        #expect(report.conflicts.isEmpty)
        let interrupted = try #require(f.catalog.commits(pair: f.pair.id).first { $0.status == .interrupted })
        #expect(interrupted.modified == 1)
        let doc = try RelativePath(validating: "doc.txt")
        let tracked = try f.catalog.trackedFiles(f.pair.id)
        #expect(tracked[doc]?.hash == sha256Hex("v2-new"))
    }

    @Test func crashBeforeArchiveLeavesFileAndRetries() throws {
        let f = try Fixture(policy: .preserveRename)
        try f.write("a.txt", "alpha")
        try f.write("b.txt", "beta")
        try f.sync()
        try f.remove("a.txt")
        f.engine.faultInjector = { op, _ in if op == "archive" { throw InjectedCrash() } }
        #expect(throws: InjectedCrash.self) { try f.sync() }
        f.engine.faultInjector = nil
        try f.sync()
        #expect(f.read("a_DELETED.txt") == "alpha")
        #expect(try f.catalog.archives(pair: f.pair.id).count == 1)
    }

    @Test func tamperedHistoryIsDetected() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        try f.sync()
        try f.write("b.txt", "beta")
        try f.sync()
        #expect(try f.catalog.verifyHistoryChain(f.pair.id).isEmpty)
        try f.catalog.db.run("UPDATE changes SET new_hash='0000' WHERE path='a.txt'")
        #expect(try f.catalog.verifyHistoryChain(f.pair.id).count == 1)
    }

    @Test func corruptDatabaseIsRestoredFromBackup() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        try f.sync()
        try f.storage.backupDatabase()
        let dbPath = f.appRoot.appendingPathComponent("foldersync.sqlite").path
        f.storage.catalog.db.close()
        try Data(repeating: 0xAB, count: 8192).write(to: URL(fileURLWithPath: dbPath))
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")

        try f.reopenStorage()
        guard case .restoredFromBackup = f.storage.databaseRecovery else {
            Issue.record("expected restore from backup, got \(String(describing: f.storage.databaseRecovery))")
            return
        }
        #expect(try f.catalog.pairs().count == 1)
        #expect(try f.sync().commit == nil) // state intact: nothing to do
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: f.appRoot.path).filter { $0.contains(".corrupt-") }
        #expect(!quarantined.isEmpty)
    }

    @Test func corruptDatabaseWithoutBackupIsRecreatedAndDestinationAdopted() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        try f.sync()
        let dbPath = f.appRoot.appendingPathComponent("foldersync.sqlite").path
        f.storage.catalog.db.close()
        try Data(repeating: 0x00, count: 4096).write(to: URL(fileURLWithPath: dbPath))
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")

        try f.reopenStorage()
        guard case .recreated = f.storage.databaseRecovery else {
            Issue.record("expected recreation")
            return
        }
        try f.catalog.savePair(f.pair)
        let report = try f.sync()
        #expect(report.conflicts.isEmpty)
        #expect(try f.changes(of: report.commit).map(\.kind) == [.adopted])
        #expect(f.read("a.txt") == "alpha")
    }
}
