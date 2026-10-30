import Foundation
import SQLite3

public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public struct Row {
    let values: [String: SQLValue]

    public subscript(_ key: String) -> SQLValue { values[key] ?? .null }

    public func int(_ k: String) -> Int64? {
        switch self[k] {
        case let .int(v): return v
        case let .double(v): return Int64(v)
        default: return nil
        }
    }

    public func double(_ k: String) -> Double? {
        switch self[k] {
        case let .double(v): return v
        case let .int(v): return Double(v)
        default: return nil
        }
    }

    public func string(_ k: String) -> String? {
        if case let .text(v) = self[k] { return v }
        return nil
    }

    public func data(_ k: String) -> Data? {
        if case let .blob(v) = self[k] { return v }
        return nil
    }

    public func bool(_ k: String) -> Bool { (int(k) ?? 0) != 0 }
}

public struct DatabaseError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// Minimal, dependency-free SQLite wrapper.
///
/// * WAL journal + `synchronous=FULL` for durability across crashes.
/// * All access serialized with a recursive lock; nested `transaction` calls become savepoints.
/// * The database file is created with mode 0600.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0
    public let path: String

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        self.path = path
        let oldMask = umask(0o077)
        defer { umask(oldMask) }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw DatabaseError(code: rc, message: msg)
        }
        chmod(path, 0o600)
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA foreign_keys=ON")
        // Run-time extension loading is disabled by default in SQLite and FolderSync never enables it,
        // so the database cannot be used to load code.
    }

    deinit { close() }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let h = handle {
            sqlite3_close_v2(h)
            handle = nil
        }
    }

    private func error(_ rc: Int32) -> DatabaseError {
        DatabaseError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    public func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw DatabaseError(code: rc, message: msg)
        }
    }

    private func prepare(_ sql: String, _ args: [SQLBindable]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else { throw error(rc) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            let brc: Int32
            switch arg.sqlValue {
            case .null: brc = sqlite3_bind_null(s, idx)
            case let .int(v): brc = sqlite3_bind_int64(s, idx, v)
            case let .double(v): brc = sqlite3_bind_double(s, idx, v)
            case let .text(v): brc = sqlite3_bind_text(s, idx, v, -1, Database.transient)
            case let .blob(v):
                brc = v.withUnsafeBytes { sqlite3_bind_blob(s, idx, $0.baseAddress, Int32($0.count), Database.transient) }
            }
            if brc != SQLITE_OK {
                sqlite3_finalize(s)
                throw error(brc)
            }
        }
        return s
    }

    @discardableResult
    public func run(_ sql: String, _ args: SQLBindable...) throws -> Int {
        try run(sql, args)
    }

    @discardableResult
    public func run(_ sql: String, _ args: [SQLBindable]) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        var rc = sqlite3_step(s)
        while rc == SQLITE_ROW { rc = sqlite3_step(s) }
        guard rc == SQLITE_DONE else { throw error(rc) }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ args: SQLBindable...) throws -> [Row] {
        try query(sql, args)
    }

    public func query(_ sql: String, _ args: [SQLBindable]) throws -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        var rows: [Row] = []
        let columnCount = sqlite3_column_count(s)
        let names = (0..<columnCount).map { String(cString: sqlite3_column_name(s, $0)) }
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var values: [String: SQLValue] = [:]
            for i in 0..<columnCount {
                let v: SQLValue
                switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER: v = .int(sqlite3_column_int64(s, i))
                case SQLITE_FLOAT: v = .double(sqlite3_column_double(s, i))
                case SQLITE_TEXT: v = .text(String(cString: sqlite3_column_text(s, i)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(s, i))
                    v = n == 0 ? .blob(Data()) : .blob(Data(bytes: sqlite3_column_blob(s, i), count: n))
                default: v = .null
                }
                values[names[Int(i)]] = v
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    public func scalarInt(_ sql: String, _ args: SQLBindable...) throws -> Int64? {
        guard let row = try query(sql, args).first, let first = row.values.values.first else { return nil }
        switch first {
        case let .int(v): return v
        case let .double(v): return Int64(v)
        default: return nil
        }
    }

    public var lastInsertRowID: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs `body` atomically. Nested calls use savepoints so inner failures roll back only their part.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let depth = transactionDepth
        let savepoint = "sp\(depth)"
        try execute(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        transactionDepth += 1
        do {
            let result = try body()
            transactionDepth -= 1
            try execute(depth == 0 ? "COMMIT" : "RELEASE \(savepoint)")
            return result
        } catch {
            transactionDepth -= 1
            if depth == 0 {
                try? execute("ROLLBACK")
            } else {
                try? execute("ROLLBACK TO \(savepoint)")
                try? execute("RELEASE \(savepoint)")
            }
            throw error
        }
    }

    /// Returns true when `PRAGMA quick_check` reports "ok".
    public func quickCheck() -> Bool {
        guard let rows = try? query("PRAGMA quick_check"), let first = rows.first else { return false }
        return first.values.values.first == .text("ok")
    }

    public var userVersion: Int {
        get { Int((try? scalarInt("PRAGMA user_version")) ?? 0) }
    }

    func setUserVersion(_ v: Int) throws { try execute("PRAGMA user_version=\(v)") }

    /// Consistent online copy using SQLite's backup API (safe while the DB is in use).
    public func backup(to destinationPath: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let oldMask = umask(0o077)
        defer { umask(oldMask) }
        var dest: OpaquePointer?
        let rc = sqlite3_open_v2(destinationPath, &dest, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        defer { sqlite3_close_v2(dest) }
        guard rc == SQLITE_OK else { throw DatabaseError(code: rc, message: "backup open failed") }
        guard let b = sqlite3_backup_init(dest, "main", handle, "main") else {
            throw DatabaseError(code: sqlite3_errcode(dest), message: String(cString: sqlite3_errmsg(dest)))
        }
        let step = sqlite3_backup_step(b, -1)
        sqlite3_backup_finish(b)
        guard step == SQLITE_DONE else { throw DatabaseError(code: step, message: "backup step failed") }
        chmod(destinationPath, 0o600)
    }
}
