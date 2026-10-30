import CryptoKit
import Darwin
import Foundation

public enum SkipReason: String, Codable, Sendable {
    case symbolicLink, specialFile, mountPoint, invalidName, excluded, unreadable, changedDuringScan
}

public struct ScanResult: Sendable {
    public var files: [RelativePath: FileStat] = [:]
    public var directories: Set<RelativePath> = []
    public var skipped: [(path: String, reason: SkipReason)] = []
}

/// Exclusion matching on single path components using `fnmatch` (no shell involved).
public struct ExclusionRules: Sendable {
    public let patterns: [String]
    public init(_ patterns: [String]) { self.patterns = patterns }

    public func excludes(_ name: String) -> Bool {
        if name.hasPrefix(DestinationWriter.tempPrefix) { return true }
        return patterns.contains { fnmatch($0, name, 0) == 0 }
    }
}

/// Read-only access to the source tree.
///
/// This type intentionally exposes **no** operation that can create, modify, rename or delete
/// anything: the synchronization engine only ever holds a `SourceReader` for the source, which
/// makes "the source is never modified" a structural property that can be audited in one file.
///
/// Traversal uses `openat(O_NOFOLLOW | O_DIRECTORY)` relative to already-open directory
/// descriptors, so a directory swapped for a symlink mid-scan cannot redirect the scan outside the
/// root. Symbolic links are reported as skipped and never followed. Directories on a different
/// device (mount points) are not descended into.
public final class SourceReader {
    public let rootPath: String
    let rules: ExclusionRules

    public init(rootPath: String, excludePatterns: [String]) {
        self.rootPath = rootPath
        rules = ExclusionRules(excludePatterns)
    }

    func openRoot() throws -> Int32 {
        let fd = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFail("open", rootPath) }
        return fd
    }

    public func scan() throws -> ScanResult {
        var result = ScanResult()
        let rootFD = try openRoot()
        defer { close(rootFD) }
        let rootStat = try fstatFD(rootFD, rootPath)
        try scanDirectory(fd: rootFD, relative: [], device: rootStat.device, into: &result)
        return result
    }

    private func scanDirectory(fd: Int32, relative: [String], device: UInt64, into result: inout ScanResult) throws {
        // Read all names first and close the DIR stream so open descriptors stay O(depth).
        let dupFD = dup(fd)
        guard dupFD >= 0, let dir = fdopendir(dupFD) else {
            if dupFD >= 0 { close(dupFD) }
            throw posixFail("opendir", relative.joined(separator: "/"))
        }
        var names: [String] = []
        var invalid = 0
        while let entry = readdir(dir) {
            let namlen = Int(entry.pointee.d_namlen)
            let name: String? = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(bytes: raw.prefix(namlen), encoding: .utf8)
            }
            guard let name else { invalid += 1; continue }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        closedir(dir)
        if invalid > 0 {
            result.skipped.append((relative.joined(separator: "/") + "/<\(invalid) undecodable names>", .invalidName))
        }

        for name in names.sorted() {
            let display = (relative + [name]).joined(separator: "/")
            if rules.excludes(name) { continue }
            guard let rel = try? RelativePath(components: relative + [name]) else {
                result.skipped.append((display, .invalidName))
                continue
            }
            var st = stat()
            if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue } // vanished during scan
                result.skipped.append((display, .unreadable))
                continue
            }
            let fs = FileStat(st)
            if fs.isSymlink {
                result.skipped.append((display, .symbolicLink))
            } else if fs.isRegularFile {
                result.files[rel] = fs
            } else if fs.isDirectory {
                if fs.device != device {
                    result.skipped.append((display, .mountPoint))
                    continue
                }
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else {
                    result.skipped.append((display, errno == ELOOP || errno == ENOTDIR ? .changedDuringScan : .unreadable))
                    continue
                }
                defer { close(child) }
                // The entry must still be the directory we stat'ed (no swap between fstatat and openat).
                guard let opened = try? fstatFD(child, display), opened.inode == fs.inode, opened.device == fs.device else {
                    result.skipped.append((display, .changedDuringScan))
                    continue
                }
                result.directories.insert(rel)
                try scanDirectory(fd: child, relative: relative + [name], device: device, into: &result)
            } else {
                result.skipped.append((display, .specialFile))
            }
        }
    }

    /// Opens a regular file for reading without following symlinks at any level below the root,
    /// and verifies it is the same file (device + inode) that the scan observed.
    func openFile(_ path: RelativePath, expected: FileStat?) throws -> FileDescriptor {
        var dirFD = try openRoot()
        for component in path.components.dropLast() {
            let next = openat(dirFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(dirFD)
            guard next >= 0 else {
                if code == ELOOP || code == ENOTDIR { throw FSError.symlinkEncountered(path.string) }
                throw posixFail("open", path.string, code)
            }
            dirFD = next
        }
        let fd = openat(dirFD, path.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let code = errno
        close(dirFD)
        guard fd >= 0 else {
            if code == ELOOP { throw FSError.symlinkEncountered(path.string) }
            throw posixFail("open", path.string, code)
        }
        let handle = FileDescriptor(fd: fd, path: path.string)
        let st = try fstatFD(fd, path.string)
        guard st.isRegularFile else { throw FSError.notRegularFile(path.string) }
        if let e = expected, e.inode != st.inode || e.device != st.device {
            throw FSError.changedDuringCopy(path.string)
        }
        return handle
    }

    /// Streaming SHA-256 of a source file. Never loads the whole file into memory.
    public func hash(_ path: RelativePath, expected: FileStat?) throws -> String {
        let handle = try openFile(path, expected: expected)
        defer { handle.close() }
        let before = try fstatFD(handle.fd, path.string)
        let digest = try StreamHasher.hash(fd: handle.fd, path: path.string)
        let after = try fstatFD(handle.fd, path.string)
        guard before.size == after.size, before.mtimeNs == after.mtimeNs else { throw FSError.changedDuringCopy(path.string) }
        return digest
    }
}

enum StreamHasher {
    static let bufferSize = 1 << 20

    static func hash(fd: Int32, path: String) throws -> String {
        var hasher = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = try readFully(fd, buffer, bufferSize, path)
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            if n < bufferSize { break }
        }
        return Data(hasher.finalize()).hexString
    }

    static func hash(path: String) throws -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFail("open", path) }
        defer { close(fd) }
        return try hash(fd: fd, path: path)
    }
}
