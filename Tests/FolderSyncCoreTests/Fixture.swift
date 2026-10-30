import CryptoKit
import Foundation
import Testing
@testable import FolderSyncCore

/// Moves "trashed" files into a fixture directory so tests never touch the user's real Trash.
struct DirectoryTrash: TrashHandler {
    let directory: URL
    func trash(_ url: URL) throws {
        let target = directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
    }
}

/// Isolated, synthetic test environment under the system temporary directory.
/// Every test gets fresh source/destination/storage folders; nothing outside is ever touched.
final class Fixture {
    let base: URL
    let src: URL
    let dst: URL
    let appRoot: URL
    let trashDir: URL
    let keyProvider: InMemoryKeyProvider
    var storage: FolderSyncStorage
    var pair: FolderPair

    init(policy: DeletionPolicy = .preserveRename, versioning: VersioningMode = .full, confirmPermanent: Bool = false) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        base = tmp.appendingPathComponent("FolderSyncTests-\(UUID().uuidString)", isDirectory: true)
        // Hard guard: destructive tests may only ever run inside the temporary directory.
        precondition(base.standardizedFileURL.path.hasPrefix(tmp.standardizedFileURL.path), "fixture outside temp dir")
        src = base.appendingPathComponent("source", isDirectory: true)
        dst = base.appendingPathComponent("destination", isDirectory: true)
        appRoot = base.appendingPathComponent("app-support", isDirectory: true)
        trashDir = base.appendingPathComponent("fake-trash", isDirectory: true)
        for d in [src, dst, appRoot, trashDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        keyProvider = InMemoryKeyProvider()
        storage = try FolderSyncStorage(root: appRoot, keyProvider: keyProvider, trash: DirectoryTrash(directory: trashDir))
        pair = FolderPair(name: "Test pair", sourcePath: src.path, destinationPath: dst.path, deletionPolicy: policy, versioningMode: versioning)
        pair.permanentDeletionConfirmed = confirmPermanent
        pair.sourceIdentity = PairValidator.identity(of: src.path)
        pair.destinationIdentity = PairValidator.identity(of: dst.path)
        try storage.catalog.savePair(pair)
    }

    deinit {
        // Restore permissions changed by permission tests, then remove everything.
        if let e = FileManager.default.enumerator(atPath: base.path) {
            for case let p as String in e { chmod(base.appendingPathComponent(p).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: base)
    }

    var engine: SyncEngine { storage.engine }
    var catalog: Catalog { storage.catalog }

    func reopenStorage() throws {
        storage = try FolderSyncStorage(root: appRoot, keyProvider: keyProvider, trash: DirectoryTrash(directory: trashDir))
    }

    @discardableResult
    func write(_ rel: String, _ content: String, in root: URL? = nil, mtimeOffset: TimeInterval? = nil) throws -> URL {
        try write(rel, Data(content.utf8), in: root, mtimeOffset: mtimeOffset)
    }

    @discardableResult
    func write(_ rel: String, _ data: Data, in root: URL? = nil, mtimeOffset: TimeInterval? = nil) throws -> URL {
        let url = (root ?? src).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let mtimeOffset {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(mtimeOffset)], ofItemAtPath: url.path)
        }
        return url
    }

    func read(_ rel: String, in root: URL? = nil) -> String? {
        (try? Data(contentsOf: (root ?? dst).appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ rel: String, in root: URL? = nil) -> Bool {
        (try? lstatPath((root ?? dst).appendingPathComponent(rel).path)) != nil
    }

    func remove(_ rel: String, in root: URL? = nil) throws {
        try FileManager.default.removeItem(at: (root ?? src).appendingPathComponent(rel))
    }

    @discardableResult
    func sync(_ options: SyncOptions = SyncOptions()) throws -> SyncReport {
        try engine.synchronize(pair: pair, source: src.path, destination: dst.path, options: options)
    }

    /// Path → SHA-256 for every regular file (symlinks recorded as "symlink→target").
    func tree(_ root: URL, includeHidden: Bool = false) -> [String: String] {
        var out: [String: String] = [:]
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return out }
        for case let rel as String in e {
            let full = root.appendingPathComponent(rel).path
            guard let st = try? lstatPath(full) else { continue }
            if !includeHidden && (rel as NSString).lastPathComponent.hasPrefix(".") { continue }
            if st.isSymlink {
                out[rel] = "symlink→" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? "?")
            } else if st.isRegularFile {
                out[rel] = (try? Data(contentsOf: URL(fileURLWithPath: full))).map { Data(SHA256.hash(data: $0)).hexString } ?? "unreadable"
            }
        }
        return out
    }

    /// Snapshot of the full source tree including metadata, to prove the source is never modified.
    func sourceFingerprint() -> [String: String] {
        var out: [String: String] = [:]
        guard let e = FileManager.default.enumerator(atPath: src.path) else { return out }
        for case let rel as String in e {
            let full = src.appendingPathComponent(rel).path
            guard let st = try? lstatPath(full) else { continue }
            var digest = "\(st.mode)-\(st.size)-\(st.mtimeNs)-\(st.inode)"
            if st.isRegularFile, let d = try? Data(contentsOf: URL(fileURLWithPath: full)) { digest += "-" + Data(SHA256.hash(data: d)).hexString }
            out[rel] = digest
        }
        return out
    }

    func lastCommit() throws -> Commit? { try catalog.commits(pair: pair.id, limit: 1).first }

    func changes(of commit: Commit?) throws -> [FileChange] {
        guard let commit else { return [] }
        return try catalog.changes(commitSeq: commit.seq)
    }
}

func sha256Hex(_ s: String) -> String { Data(SHA256.hash(data: Data(s.utf8))).hexString }

func randomData(_ count: Int) -> Data {
    var d = Data(count: count)
    d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    return d
}
