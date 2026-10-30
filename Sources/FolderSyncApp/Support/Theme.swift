import FolderSyncCore
import SwiftUI

/// Semantic colors shared by the change explorer, commit graph and archive views.
enum Palette {
    static let added = Color(nsColor: .systemGreen)
    static let modified = Color(nsColor: .systemOrange)
    static let deleted = Color(nsColor: .systemRed)
    static let renamed = Color(nsColor: .systemBlue)
    static let archived = Color(nsColor: .systemPurple)
    static let restored = Color(nsColor: .systemTeal)
    static let failed = Color(nsColor: .systemYellow)
    static let neutral = Color.secondary

    static let sourceLane = Color(nsColor: .systemIndigo)
    static let destinationLane = Color.accentColor
    static let archiveLane = Color(nsColor: .systemPurple)

    static func color(_ tone: NodeTone) -> Color {
        switch tone {
        case .added: return added
        case .modified: return modified
        case .deleted: return deleted
        case .renamed: return renamed
        case .archived: return archived
        case .restored: return restored
        case .failed: return failed
        case .neutral: return neutral
        }
    }

    static func color(_ kind: ChangeKind) -> Color {
        switch kind {
        case .added, .repaired, .adopted: return added
        case .modified: return modified
        case .renamed, .archiveRelocated: return renamed
        case .archived, .trashed: return archived
        case .deleted, .untracked: return deleted
        case .restored: return restored
        }
    }

    static func lane(_ lane: GraphLane) -> Color {
        switch lane {
        case .source: return sourceLane
        case .destination: return destinationLane
        case .archive: return archiveLane
        }
    }
}

extension ChangeKind {
    var label: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .renamed: return "Renamed"
        case .archived: return "Archived"
        case .trashed: return "Moved to Trash"
        case .deleted: return "Deleted"
        case .repaired: return "Repaired"
        case .adopted: return "Adopted"
        case .restored: return "Restored"
        case .untracked: return "Untracked"
        case .archiveRelocated: return "Archive moved"
        }
    }

    var symbol: String {
        switch self {
        case .added, .repaired, .adopted: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .renamed, .archiveRelocated: return "arrow.right.circle.fill"
        case .archived: return "archivebox.fill"
        case .trashed: return "trash.circle.fill"
        case .deleted, .untracked: return "minus.circle.fill"
        case .restored: return "clock.arrow.circlepath"
        }
    }
}

extension CommitStatus {
    var label: String {
        switch self {
        case .inProgress: return "In progress"
        case .success: return "Synchronized"
        case .partial: return "Partially applied"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }

    var color: Color {
        switch self {
        case .success: return Palette.added
        case .partial, .interrupted: return Palette.failed
        case .failed: return Palette.deleted
        case .inProgress: return .secondary
        }
    }
}

enum Format {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func size(_ n: Int64?) -> String { n.map { bytes.string(fromByteCount: $0) } ?? "—" }

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(date: .abbreviated, time: .standard)
    }

    static func mtime(_ ns: Int64?) -> String {
        guard let ns else { return "—" }
        return date(Date(timeIntervalSince1970: Double(ns) / 1e9))
    }

    static func relative(_ d: Date?) -> String {
        guard let d else { return "Never" }
        return d.formatted(.relative(presentation: .named))
    }

    static func shortHash(_ h: String?) -> String { h.map { String($0.prefix(10)) } ?? "—" }
}

/// Small capsule used for statuses and counts.
struct Badge: View {
    var text: String
    var color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

struct HashText: View {
    var hash: String?
    var body: some View {
        Text(Format.shortHash(hash))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .help(hash ?? "")
            .textSelection(.enabled)
    }
}

struct EmptyStateView: View {
    var title: String
    var symbol: String
    var message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}

/// `@State` is implemented as a macro in recent SDKs, and its plugin ships only with Xcode.
/// Referring to the `State` property-wrapper type through a typealias keeps the app buildable
/// with the Command Line Tools alone, with identical behavior.
typealias ViewState<Value> = SwiftUI.State<Value>
