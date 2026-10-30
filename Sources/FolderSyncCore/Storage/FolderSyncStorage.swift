import Foundation

public enum DatabaseRecovery: Equatable, Sendable {
    case restoredFromBackup(String)
    case recreated(quarantinedCopy: String)
}

/// Owns FolderSync's private storage directory: metadata database, backups, version store, locks.
/// The directory lives in the sandbox container and must never be inside a synchronized folder.
public final class FolderSyncStorage: @unchecked Sendable {
    public let root: URL
    public let catalog: Catalog
    public let store: ObjectStore
    public let engine: SyncEngine
    public let databaseRecovery: DatabaseRecovery?

    static let databaseName = "foldersync.sqlite"
    static let keptBackups = 5

    /// `~/Library/Application Support/FolderSync` (inside the sandbox container when sandboxed).
    /// `FOLDERSYNC_STORAGE_ROOT` overrides it for development and demos with synthetic data.
    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["FOLDERSYNC_STORAGE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FolderSync", isDirectory: true)
    }

    public init(root: URL = FolderSyncStorage.defaultRoot, keyProvider: KeyProvider = KeychainKeyProvider(), trash: TrashHandler = SystemTrash()) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(root.path, 0o700)
        let (db, recovery) = try FolderSyncStorage.openDatabase(root: root)
        databaseRecovery = recovery
        catalog = try Catalog(database: db)
        store = try ObjectStore(root: root.appendingPathComponent("store"), keyProvider: keyProvider)
        engine = SyncEngine(catalog: catalog, store: store, trash: trash, lockDirectory: root.appendingPathComponent("locks"))
        if let recovery {
            catalog.log(nil, .warning, "Metadata database was damaged and has been recovered: \(recovery)")
        }
    }

    static var backupsName: String { "backups" }

    static func openHealthy(_ path: String) -> Database? {
        guard let db = try? Database(path: path) else { return nil }
        guard db.quickCheck() else { db.close(); return nil }
        do { try Schema.migrate(db) } catch { db.close(); return nil }
        return db
    }

    static func openDatabase(root: URL) throws -> (Database, DatabaseRecovery?) {
        let path = root.appendingPathComponent(databaseName).path
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            return (try Database(path: path), nil)
        }
        if let db = openHealthy(path) { return (db, nil) }

        // Quarantine the damaged database (never delete it: it may still be forensically useful).
        let stamp = Clock.compactStamp(Date())
        let quarantined = path + ".corrupt-" + stamp
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try? fm.moveItem(atPath: path + suffix, toPath: quarantined + suffix)
        }
        let backups = root.appendingPathComponent(backupsName)
        let candidates = ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? []).filter { $0.hasSuffix(".sqlite") }.sorted(by: >)
        for name in candidates {
            let src = backups.appendingPathComponent(name).path
            try? fm.removeItem(atPath: path)
            guard (try? fm.copyItem(atPath: src, toPath: path)) != nil else { continue }
            if let db = openHealthy(path) { return (db, .restoredFromBackup(name)) }
        }
        try? fm.removeItem(atPath: path)
        return (try Database(path: path), .recreated(quarantinedCopy: quarantined))
    }

    /// Writes a consistent copy of the metadata database and keeps the newest few.
    public func backupDatabase() throws {
        let dir = root.appendingPathComponent(FolderSyncStorage.backupsName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "foldersync-\(Clock.compactStamp(Date()))-\(UUID().uuidString.prefix(6)).sqlite"
        try catalog.db.backup(to: dir.appendingPathComponent(name).path)
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".sqlite") }.sorted(by: >)
        for old in all.dropFirst(FolderSyncStorage.keptBackups) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
        }
    }
}
