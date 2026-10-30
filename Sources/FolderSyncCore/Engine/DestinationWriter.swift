import Darwin
import Foundation

/// Moves destination files to the Trash. Injectable so tests never touch the user's real Trash.
public protocol TrashHandler: Sendable {
    func trash(_ url: URL) throws
}

public struct SystemTrash: TrashHandler {
    public init() {}
    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// The only component allowed to mutate the destination folder.
///
/// Every operation takes a validated `RelativePath` and checks that each ancestor below the root
/// is a real directory (not a symlink) immediately before acting, and final components are
/// opened with `O_NOFOLLOW`. New content is always written to a temporary file in the target
/// directory and published with an atomic rename.
public final class DestinationWriter {
    public static let tempPrefix = ".foldersync-tmp-"
    public let rootPath: String
    private var verifiedDirectories: Set<RelativePath> = []

    public init(rootPath: String) {
        self.rootPath = rootPath
    }

    func absolute(_ p: RelativePath) -> String { p.absolute(in: rootPath) }

    /// Confirms every ancestor of `path` is a real directory. Cached per run, but `recheck`
    /// forces a fresh lstat (used right before publishing).
    func verifyParents(of path: RelativePath, recheck: Bool = false) throws {
        for ancestor in path.ancestors {
            if !recheck, verifiedDirectories.contains(ancestor) { continue }
            guard let st = try lstatPath(absolute(ancestor)) else { throw posixFail("lstat", ancestor.string, ENOENT) }
            if st.isSymlink { throw FSError.symlinkEncountered(ancestor.string) }
            guard st.isDirectory else { throw posixFail("lstat", ancestor.string, ENOTDIR) }
            verifiedDirectories.insert(ancestor)
        }
    }

    /// lstat of a destination entry. A symlinked ancestor is reported as an error, never followed.
    public func stat(_ path: RelativePath) throws -> FileStat? {
        do {
            try verifyParents(of: path)
        } catch let e as FSError where e.errnoCode == ENOENT || e.errnoCode == ENOTDIR {
            return nil
        }
        return try lstatPath(absolute(path))
    }

    func ensureDirectory(_ path: RelativePath) throws {
        for dir in path.ancestors + [path] {
            if verifiedDirectories.contains(dir) { continue }
            let abs = absolute(dir)
            if mkdir(abs, 0o755) != 0 && errno != EEXIST { throw posixFail("mkdir", dir.string) }
            guard let st = try lstatPath(abs) else { throw posixFail("mkdir", dir.string, ENOENT) }
            if st.isSymlink { throw FSError.symlinkEncountered(dir.string) }
            guard st.isDirectory else { throw posixFail("mkdir", dir.string, ENOTDIR) }
            verifiedDirectories.insert(dir)
        }
    }

    /// Removes a directory only if it is empty. Returns false if it still has content.
    func removeDirectoryIfEmpty(_ path: RelativePath) throws -> Bool {
        try verifyParents(of: path, recheck: true)
        guard let st = try lstatPath(absolute(path)) else { return true }
        guard st.isDirectory else { return false }
        if rmdir(absolute(path)) != 0 {
            if errno == ENOTEMPTY || errno == EEXIST { return false }
            throw posixFail("rmdir", path.string)
        }
        verifiedDirectories.remove(path)
        return true
    }

    /// Creates an exclusive temporary file next to `target`.
    func createTemporary(near target: RelativePath) throws -> (FileDescriptor, RelativePath) {
        if let parent = target.parent { try ensureDirectory(parent) }
        let tempName = DestinationWriter.tempPrefix + UUID().uuidString
        let tempRel = try target.replacingName(tempName)
        let abs = absolute(tempRel)
        let fd = open(abs, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFail("create", tempRel.string) }
        return (FileDescriptor(fd: fd, path: abs), tempRel)
    }

    func removeTemporary(_ temp: RelativePath) {
        guard temp.name.hasPrefix(DestinationWriter.tempPrefix) else { return }
        unlink(absolute(temp))
    }

    /// Atomically moves `temp` to `target`. When `replace` is false the target must not exist.
    func publish(_ temp: RelativePath, to target: RelativePath, replace: Bool) throws {
        try verifyParents(of: target, recheck: true)
        if replace {
            if let st = try lstatPath(absolute(target)), !st.isRegularFile { throw FSError.notRegularFile(target.string) }
            try renameReplacing(absolute(temp), absolute(target))
        } else {
            try renameExclusive(absolute(temp), absolute(target))
        }
        if let parent = target.parent { syncDirectory(absolute(parent)) } else { syncDirectory(rootPath) }
    }

    func move(_ from: RelativePath, to: RelativePath) throws {
        try verifyParents(of: from, recheck: true)
        if let parent = to.parent { try ensureDirectory(parent) }
        try verifyParents(of: to, recheck: true)
        guard let st = try lstatPath(absolute(from)), st.isRegularFile else { throw FSError.notRegularFile(from.string) }
        try renameExclusive(absolute(from), absolute(to))
    }

    func removeFile(_ path: RelativePath) throws {
        try verifyParents(of: path, recheck: true)
        guard let st = try lstatPath(absolute(path)) else { return }
        guard st.isRegularFile else { throw FSError.notRegularFile(path.string) }
        if unlink(absolute(path)) != 0 { throw posixFail("unlink", path.string) }
    }

    func trash(_ path: RelativePath, using handler: TrashHandler) throws {
        try verifyParents(of: path, recheck: true)
        guard let st = try lstatPath(absolute(path)), st.isRegularFile else { throw FSError.notRegularFile(path.string) }
        try handler.trash(URL(fileURLWithPath: absolute(path)))
    }

    func openForReading(_ path: RelativePath) throws -> FileDescriptor {
        try verifyParents(of: path, recheck: true)
        let abs = absolute(path)
        let fd = open(abs, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw FSError.symlinkEncountered(path.string) }
            throw posixFail("open", path.string)
        }
        let handle = FileDescriptor(fd: fd, path: abs)
        guard try fstatFD(fd, path.string).isRegularFile else { throw FSError.notRegularFile(path.string) }
        return handle
    }

    public func hash(_ path: RelativePath) throws -> String {
        let h = try openForReading(path)
        defer { h.close() }
        return try StreamHasher.hash(fd: h.fd, path: path.string)
    }

    /// Finds a free sibling name for `path` using `marker` (e.g. DELETED, RESTORED).
    func uniqueSibling(of path: RelativePath, marker: String, date: Date, avoiding reserved: Set<RelativePath> = []) throws -> RelativePath {
        for name in NameGenerator.candidates(for: path.name, marker: marker, date: date) {
            guard let candidate = try? path.replacingName(name) else { continue }
            if reserved.contains(candidate) { continue }
            if try stat(candidate) == nil { return candidate }
        }
        throw FSError.alreadyExists(path.string)
    }
}

/// Copies bytes from an open descriptor to a temporary destination file, optionally feeding the
/// version store at the same time, in a single streaming pass.
enum StreamingCopier {
    struct Result {
        var hash: String
        var bytes: Int64
    }

    static func copy(from src: Int32, srcPath: String, to dst: Int32, dstPath: String, objectWriter: ObjectWriter?) throws -> Result {
        var hasher = SHA256Stream()
        let size = StreamHasher.bufferSize
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var total: Int64 = 0
        while true {
            let n = try readFully(src, buffer, size, srcPath)
            if n == 0 { break }
            let chunk = UnsafeRawBufferPointer(start: buffer, count: n)
            hasher.update(chunk)
            try writeFully(dst, buffer, n, dstPath)
            try objectWriter?.append(chunk)
            total += Int64(n)
            if n < size { break }
        }
        return Result(hash: hasher.finalize(), bytes: total)
    }
}

import CryptoKit

struct SHA256Stream {
    private var h = SHA256()
    mutating func update(_ b: UnsafeRawBufferPointer) { h.update(bufferPointer: b) }
    func finalize() -> String { Data(h.finalize()).hexString }
}
