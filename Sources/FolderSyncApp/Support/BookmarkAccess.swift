import FolderSyncCore
import Foundation

/// Persists and resolves app-scoped security-scoped bookmarks for user-selected folders.
///
/// The sandbox only grants access to folders the user picked (open panel or drag & drop). A
/// bookmark lets FolderSync regain exactly that access after relaunch — nothing more.
enum Bookmarks {
    static func make(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data?, fallbackPath: String) -> (url: URL, stale: Bool) {
        guard let data else { return (URL(fileURLWithPath: fallbackPath), false) }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        return (URL(fileURLWithPath: fallbackPath), false)
    }
}

/// `FolderAccess` backed by security-scoped bookmarks. Access is held only for the duration of
/// an operation (monitoring holds its own long-lived access in `AppModel`).
struct BookmarkAccess: FolderAccess {
    func withAccess<T>(to pair: FolderPair, _ body: (String, String) throws -> T) throws -> T {
        let src = Bookmarks.resolve(pair.sourceBookmark, fallbackPath: pair.sourcePath).url
        let dst = Bookmarks.resolve(pair.destinationBookmark, fallbackPath: pair.destinationPath).url
        let a = src.startAccessingSecurityScopedResource()
        let b = dst.startAccessingSecurityScopedResource()
        defer {
            if a { src.stopAccessingSecurityScopedResource() }
            if b { dst.stopAccessingSecurityScopedResource() }
        }
        return try body(src.path, dst.path)
    }
}
