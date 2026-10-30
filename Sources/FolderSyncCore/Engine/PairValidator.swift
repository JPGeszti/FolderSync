import Darwin
import Foundation

public enum PairValidationError: Error, CustomStringConvertible, Equatable {
    case sourceUnavailable(String)
    case destinationUnavailable(String)
    case sourceIdentityChanged
    case destinationIdentityChanged
    case sameFolder
    case destinationInsideSource
    case sourceInsideDestination
    case storeInsideFolder
    case rootIsSymlink(String)

    public var description: String {
        switch self {
        case let .sourceUnavailable(r): return "Source folder is unavailable (\(r)). Nothing was changed."
        case let .destinationUnavailable(r): return "Destination folder is unavailable (\(r))."
        case .sourceIdentityChanged: return "The source path now points to a different folder or volume. Synchronization is suspended until you confirm the folder."
        case .destinationIdentityChanged: return "The destination path now points to a different folder or volume."
        case .sameFolder: return "Source and destination are the same folder."
        case .destinationInsideSource: return "The destination is inside the source folder; this would synchronize the destination into itself."
        case .sourceInsideDestination: return "The source is inside the destination folder."
        case .storeInsideFolder: return "FolderSync's private storage may not be inside a synchronized folder."
        case let .rootIsSymlink(p): return "Folder root is a symbolic link: \(p)"
        }
    }
}

/// Validates that a pair is safe to synchronize *right now*.
public enum PairValidator {
    public struct Roots: Sendable {
        public var source: String
        public var destination: String
    }

    /// Identity of a folder (volume UUID + inode), recorded when the pair is configured.
    public static func identity(of path: String) -> RootIdentity? {
        guard let st = try? lstatPath(path), st.isDirectory else { return nil }
        let uuid = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return RootIdentity(volumeUUID: uuid, inode: st.inode)
    }

    public static func isCaseSensitive(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
    }

    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// All (device, inode) pairs from `path` up to "/". Catches nesting through firmlinks, bind
    /// mounts and alternative spellings that a string comparison would miss.
    static func ancestorIdentities(_ path: String) -> [(UInt64, UInt64)] {
        var out: [(UInt64, UInt64)] = []
        var current = path
        for _ in 0..<512 {
            var st = stat()
            if stat(current, &st) == 0 { out.append((UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino))) }
            if current == "/" || current.isEmpty { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return out
    }

    /// True when `inner` is strictly below `outer`.
    static func isWithin(_ inner: String, _ outer: String) -> Bool {
        if inner.hasPrefix(outer.hasSuffix("/") ? outer : outer + "/") { return true }
        guard let o = stat2(outer) else { return false }
        return ancestorIdentities(inner).dropFirst().contains { $0 == o }
    }

    static func sameNode(_ a: String, _ b: String) -> Bool {
        guard let x = stat2(a), let y = stat2(b) else { return false }
        return x == y
    }

    private static func stat2(_ p: String) -> (UInt64, UInt64)? {
        var st = stat()
        guard stat(p, &st) == 0 else { return nil }
        return (UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino))
    }

    /// Structural checks that do not depend on availability over time.
    public static func checkLayout(source: String, destination: String, storeRoot: String?) throws {
        guard let s = realPath(source) else { throw PairValidationError.sourceUnavailable("not found") }
        guard let d = realPath(destination) else { throw PairValidationError.destinationUnavailable("not found") }
        if s == d || sameNode(s, d) { throw PairValidationError.sameFolder }
        if isWithin(d, s) { throw PairValidationError.destinationInsideSource }
        if isWithin(s, d) { throw PairValidationError.sourceInsideDestination }
        if let storeRoot, let st = realPath(storeRoot) {
            if isWithin(st, s) || isWithin(st, d) || sameNode(st, s) || sameNode(st, d) {
                throw PairValidationError.storeInsideFolder
            }
        }
    }

    /// Full validation before every run. Returns resolved roots. Never throws for "folder is empty":
    /// emptiness is handled by the planner's deletion safety checks.
    public static func validate(pair: FolderPair, source: String, destination: String, storeRoot: String?) throws -> Roots {
        // Root symlinks: resolve once, but refuse a root whose *last component* is a symlink,
        // because that link could be retargeted between runs without the user noticing.
        guard let srcLstat = try? lstatPath(source) else { throw PairValidationError.sourceUnavailable("not found") }
        if srcLstat.isSymlink { throw PairValidationError.rootIsSymlink(source) }
        guard srcLstat.isDirectory else { throw PairValidationError.sourceUnavailable("not a folder") }
        guard access(source, R_OK | X_OK) == 0 else { throw PairValidationError.sourceUnavailable("permission denied") }

        guard let dstLstat = try? lstatPath(destination) else { throw PairValidationError.destinationUnavailable("not found") }
        if dstLstat.isSymlink { throw PairValidationError.rootIsSymlink(destination) }
        guard dstLstat.isDirectory else { throw PairValidationError.destinationUnavailable("not a folder") }
        guard access(destination, R_OK | W_OK | X_OK) == 0 else { throw PairValidationError.destinationUnavailable("not writable") }

        if let recorded = pair.sourceIdentity {
            guard let now = identity(of: source) else { throw PairValidationError.sourceUnavailable("not found") }
            if let a = recorded.volumeUUID, let b = now.volumeUUID, a != b { throw PairValidationError.sourceUnavailable("different volume mounted at this path") }
            if recorded.inode != now.inode { throw PairValidationError.sourceIdentityChanged }
        }
        if let recorded = pair.destinationIdentity {
            guard let now = identity(of: destination) else { throw PairValidationError.destinationUnavailable("not found") }
            if let a = recorded.volumeUUID, let b = now.volumeUUID, a != b { throw PairValidationError.destinationUnavailable("different volume mounted at this path") }
            if recorded.inode != now.inode { throw PairValidationError.destinationIdentityChanged }
        }
        try checkLayout(source: source, destination: destination, storeRoot: storeRoot)
        return Roots(source: realPath(source) ?? source, destination: realPath(destination) ?? destination)
    }
}
