import Darwin
import Foundation

/// Errors raised by the filesystem layer. Messages contain paths (metadata) but never file contents.
public enum FSError: Error, CustomStringConvertible, Equatable {
    case posix(op: String, path: String, code: Int32)
    case notRegularFile(String)
    case symlinkEncountered(String)
    case unsafePath(String)
    case changedDuringCopy(String)
    case integrityMismatch(path: String, expected: String, actual: String)
    case alreadyExists(String)
    case destinationChanged(String)
    case invalidName(String)

    public var description: String {
        switch self {
        case let .posix(op, path, code):
            return "\(op) failed for \(path): \(String(cString: strerror(code))) (errno \(code))"
        case let .notRegularFile(p): return "Not a regular file: \(p)"
        case let .symlinkEncountered(p): return "Symbolic link refused: \(p)"
        case let .unsafePath(p): return "Unsafe path rejected: \(p)"
        case let .changedDuringCopy(p): return "Source changed while being copied: \(p)"
        case let .integrityMismatch(p, e, a): return "Integrity check failed for \(p): expected \(e.prefix(12)), got \(a.prefix(12))"
        case let .alreadyExists(p): return "Destination already exists: \(p)"
        case let .destinationChanged(p): return "Destination changed unexpectedly: \(p)"
        case let .invalidName(p): return "Invalid file name: \(p)"
        }
    }

    public var errnoCode: Int32? {
        if case let .posix(_, _, code) = self { return code }
        return nil
    }
}

@inline(__always)
func posixFail(_ op: String, _ path: String, _ code: Int32 = errno) -> FSError {
    .posix(op: op, path: path, code: code)
}

/// The subset of `struct stat` FolderSync relies on. Timestamps are kept in nanoseconds so that
/// equality survives a round trip through SQLite without floating point drift.
public struct FileStat: Equatable, Hashable, Sendable, Codable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var mtimeNs: Int64
    public var mode: UInt16

    public init(device: UInt64, inode: UInt64, size: Int64, mtimeNs: Int64, mode: UInt16) {
        self.device = device
        self.inode = inode
        self.size = size
        self.mtimeNs = mtimeNs
        self.mode = mode
    }

    init(_ st: stat) {
        device = UInt64(bitPattern: Int64(st.st_dev))
        inode = UInt64(st.st_ino)
        size = Int64(st.st_size)
        mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        mode = UInt16(st.st_mode)
    }

    public var isRegularFile: Bool { (mode & UInt16(S_IFMT)) == UInt16(S_IFREG) }
    public var isDirectory: Bool { (mode & UInt16(S_IFMT)) == UInt16(S_IFDIR) }
    public var isSymlink: Bool { (mode & UInt16(S_IFMT)) == UInt16(S_IFLNK) }
    public var permissionBits: mode_t { mode_t(mode) & 0o777 }
    public var modificationDate: Date { Date(timeIntervalSince1970: Double(mtimeNs) / 1e9) }

    /// Fields that identify "the same unchanged file" for change detection.
    public func sameContentSignature(as other: FileStat) -> Bool {
        size == other.size && mtimeNs == other.mtimeNs && inode == other.inode
    }
}

/// `lstat` that returns nil for a missing path instead of throwing.
public func lstatPath(_ path: String) throws -> FileStat? {
    var st = stat()
    if lstat(path, &st) != 0 {
        if errno == ENOENT || errno == ENOTDIR { return nil }
        throw posixFail("lstat", path)
    }
    return FileStat(st)
}

func fstatFD(_ fd: Int32, _ pathForErrors: String) throws -> FileStat {
    var st = stat()
    guard fstat(fd, &st) == 0 else { throw posixFail("fstat", pathForErrors) }
    return FileStat(st)
}

/// Read until the buffer is full or EOF, retrying on EINTR.
func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, _ path: String) throws -> Int {
    var total = 0
    while total < count {
        let n = read(fd, buffer + total, count - total)
        if n < 0 {
            if errno == EINTR { continue }
            throw posixFail("read", path)
        }
        if n == 0 { break }
        total += n
    }
    return total
}

func writeFully(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int, _ path: String) throws {
    var total = 0
    while total < count {
        let n = write(fd, buffer + total, count - total)
        if n < 0 {
            if errno == EINTR { continue }
            throw posixFail("write", path)
        }
        total += n
    }
}

/// `fsync` is not enough on macOS to reach stable storage; F_FULLFSYNC is.
/// Falls back to fsync on filesystems that do not support it (e.g. some network volumes).
func fullSync(_ fd: Int32, _ path: String) throws {
    if fcntl(fd, F_FULLFSYNC) == 0 { return }
    if fsync(fd) != 0 { throw posixFail("fsync", path) }
}

func syncDirectory(_ path: String) {
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { return }
    _ = fsync(fd)
    close(fd)
}

/// Owns a file descriptor and closes it exactly once.
final class FileDescriptor {
    let fd: Int32
    let path: String
    private var closed = false

    init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    func close() {
        if !closed {
            closed = true
            Darwin.close(fd)
        }
    }

    deinit { close() }
}

/// Atomic rename that fails instead of replacing an existing target.
func renameExclusive(_ from: String, _ to: String) throws {
    if renamex_np(from, to, UInt32(RENAME_EXCL)) != 0 {
        let code = errno
        if code == EEXIST { throw FSError.alreadyExists(to) }
        throw posixFail("rename", to, code)
    }
}

func renameReplacing(_ from: String, _ to: String) throws {
    if rename(from, to) != 0 { throw posixFail("rename", to) }
}

extension String {
    /// Splits "name.ext" into ("name", ".ext"). Dot-files and names without an extension keep
    /// the whole name as base. Extensions are preserved verbatim; they are never trusted for behavior.
    var splitExtension: (base: String, ext: String) {
        guard let dot = lastIndex(of: "."), dot != startIndex else { return (self, "") }
        let ext = String(self[dot...])
        if ext.count <= 1 || ext.count > 16 || ext.contains(" ") { return (self, "") }
        return (String(self[..<dot]), ext)
    }
}

public enum Clock {
    public static func nowNs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    static let compactFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func compactStamp(_ date: Date) -> String { compactFormatter.string(from: date) }
}
