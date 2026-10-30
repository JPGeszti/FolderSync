import Foundation

/// A validated path relative to a sync root.
///
/// All file names are untrusted input. A `RelativePath` can only be constructed from components
/// that cannot escape the root: no `..`, no `.`, no empty components, no `/` or NUL inside a
/// component, and components no longer than NAME_MAX bytes. Combining it with a root therefore
/// always yields a path lexically inside that root (symlinks are handled separately by the
/// reader/writer, which refuse to traverse them).
public struct RelativePath: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let components: [String]

    public static let maxComponentBytes = 255
    public static let maxPathBytes = 1023

    public init(validating string: String) throws {
        guard !string.isEmpty, !string.hasPrefix("/") else { throw FSError.unsafePath(string) }
        try self.init(components: string.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
    }

    public init(components: [String]) throws {
        guard !components.isEmpty else { throw FSError.unsafePath("") }
        var total = 0
        for c in components {
            try RelativePath.validate(component: c)
            total += c.utf8.count + 1
        }
        guard total <= RelativePath.maxPathBytes else { throw FSError.unsafePath(components.joined(separator: "/")) }
        self.components = components
    }

    public static func validate(component c: String) throws {
        if c.isEmpty || c == "." || c == ".." { throw FSError.unsafePath(c) }
        if c.contains("/") || c.utf8.contains(0) { throw FSError.unsafePath(c) }
        if c.utf8.count > maxComponentBytes { throw FSError.unsafePath(c) }
    }

    public var string: String { components.joined(separator: "/") }
    public var description: String { string }
    public var name: String { components[components.count - 1] }
    public var depth: Int { components.count }

    public var parent: RelativePath? {
        components.count > 1 ? try? RelativePath(components: Array(components.dropLast())) : nil
    }

    /// All ancestor directories, outermost first.
    public var ancestors: [RelativePath] {
        (1..<max(components.count, 1)).compactMap { try? RelativePath(components: Array(components.prefix($0))) }
    }

    public func appending(_ name: String) throws -> RelativePath {
        try RelativePath(components: components + [name])
    }

    public func replacingName(_ name: String) throws -> RelativePath {
        try RelativePath(components: Array(components.dropLast()) + [name])
    }

    public func absolute(in root: String) -> String {
        root.hasSuffix("/") ? root + string : root + "/" + string
    }

    /// Case- and Unicode-normalization-insensitive key, used to detect paths that would collide
    /// on a case-insensitive destination volume (the APFS/HFS+ default).
    public var foldedKey: String {
        string.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    public static func < (a: RelativePath, b: RelativePath) -> Bool {
        a.components.lexicographicallyPrecedes(b.components)
    }

    public func isDescendant(of other: RelativePath) -> Bool {
        components.count > other.components.count && Array(components.prefix(other.components.count)) == other.components
    }
}

/// Builds collision-free names for archived and restored files.
enum NameGenerator {
    /// `report.xlsx` → `report_DELETED.xlsx`, `report_DELETED_20261030-121500.xlsx`,
    /// `report_DELETED_20261030-121500-2.xlsx`, … The original extension is preserved.
    static func candidates(for name: String, marker: String, date: Date) -> AnyIterator<String> {
        let (base, ext) = name.splitExtension
        let stamp = Clock.compactStamp(date)
        var i = 0
        return AnyIterator {
            defer { i += 1 }
            let candidate: String
            switch i {
            case 0: candidate = "\(base)_\(marker)\(ext)"
            case 1: candidate = "\(base)_\(marker)_\(stamp)\(ext)"
            case 2..<10_000: candidate = "\(base)_\(marker)_\(stamp)-\(i)\(ext)"
            case 10_000: candidate = "\(base)_\(marker)_\(UUID().uuidString.prefix(8))\(ext)"
            default: return nil
            }
            return Self.truncateToNameMax(candidate, ext: ext)
        }
    }

    private static func truncateToNameMax(_ s: String, ext: String) -> String {
        guard s.utf8.count > RelativePath.maxComponentBytes else { return s }
        var base = String(s.dropLast(ext.count))
        while (base + ext).utf8.count > RelativePath.maxComponentBytes { base.removeFirst() }
        return base + ext
    }
}
