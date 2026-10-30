import Foundation

public enum DeletionPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Policy A: keep the destination copy, renamed to `name_DELETED.ext`.
    case preserveRename
    /// Policy B: move the destination copy to the macOS Trash.
    case moveToTrash
    /// Policy C: unlink the destination copy (prior content kept in the version store).
    case permanentDelete

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .preserveRename: return "Preserve and rename"
        case .moveToTrash: return "Move to Trash"
        case .permanentDelete: return "Delete permanently"
        }
    }
}

public enum VersioningMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Every synchronized version is stored (encrypted) in the version store.
    case full
    /// Only versions that are about to be overwritten or removed from the destination are stored.
    case replacedOnly

    public var id: String { rawValue }
    public var title: String { self == .full ? "Every version" : "Replaced versions only" }
}

/// Identity of a folder root, used to detect unmounted / swapped volumes.
public struct RootIdentity: Codable, Hashable, Sendable {
    public var volumeUUID: String?
    public var inode: UInt64

    public init(volumeUUID: String?, inode: UInt64) {
        self.volumeUUID = volumeUUID
        self.inode = inode
    }
}

public struct FolderPair: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sourcePath: String
    public var destinationPath: String
    public var sourceBookmark: Data?
    public var destinationBookmark: Data?
    public var sourceIdentity: RootIdentity?
    public var destinationIdentity: RootIdentity?
    public var deletionPolicy: DeletionPolicy
    /// Must be set (after the user acknowledged the warning) for `.permanentDelete` to take effect.
    public var permanentDeletionConfirmed: Bool
    public var massDeletionThresholdCount: Int
    public var massDeletionThresholdPercent: Double
    public var versioningMode: VersioningMode
    /// 0 keeps history forever.
    public var retentionDays: Int
    public var autoSync: Bool
    public var intervalMinutes: Int
    public var paused: Bool
    public var excludePatterns: [String]
    public var createdAt: Date

    public static let defaultExcludes = [
        ".DS_Store", "._*", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems",
        ".DocumentRevisions-V100", "Icon\r", ".foldersync-tmp-*",
    ]

    public init(
        id: UUID = UUID(),
        name: String,
        sourcePath: String,
        destinationPath: String,
        deletionPolicy: DeletionPolicy = .preserveRename,
        versioningMode: VersioningMode = .full,
        retentionDays: Int = 90,
        autoSync: Bool = true,
        intervalMinutes: Int = 15
    ) {
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.deletionPolicy = deletionPolicy
        permanentDeletionConfirmed = false
        massDeletionThresholdCount = 100
        massDeletionThresholdPercent = 50
        self.versioningMode = versioningMode
        self.retentionDays = retentionDays
        self.autoSync = autoSync
        self.intervalMinutes = intervalMinutes
        paused = false
        excludePatterns = FolderPair.defaultExcludes
        createdAt = Date()
    }

    /// The policy actually applied. Permanent deletion without explicit confirmation degrades to
    /// the non-destructive default.
    public var effectiveDeletionPolicy: DeletionPolicy {
        deletionPolicy == .permanentDelete && !permanentDeletionConfirmed ? .preserveRename : deletionPolicy
    }
}

public enum ChangeKind: String, Codable, CaseIterable, Sendable {
    case added, modified, renamed
    case archived      // policy A
    case trashed       // policy B
    case deleted       // policy C
    case repaired      // destination copy was missing and was re-created
    case adopted       // identical file already present at destination, now tracked
    case restored      // written by a restore operation
    case untracked     // tracked file vanished from both sides
    case archiveRelocated

    public var isDeletion: Bool { self == .archived || self == .trashed || self == .deleted }
}

public enum ChangeStatus: String, Codable, Sendable {
    case applied, failed, skipped, planned
}

public enum CommitKind: String, Codable, Sendable {
    case sync, restore
}

public enum CommitStatus: String, Codable, Sendable {
    case inProgress, success, partial, failed, interrupted
}

public struct Commit: Identifiable, Hashable, Sendable {
    public var seq: Int64
    public var id: String
    public var pairID: UUID
    public var parentID: String?
    public var kind: CommitKind
    public var status: CommitStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var added: Int
    public var modified: Int
    public var deleted: Int
    public var renamed: Int
    public var archived: Int
    public var restored: Int
    public var failed: Int
    public var bytesTransferred: Int64
    public var message: String?
    public var restoredFromSeq: Int64?

    public var shortID: String { String(id.prefix(10)) }
    public var totalChanges: Int { added + modified + deleted + renamed + archived + restored }
}

public struct FileChange: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var commitSeq: Int64
    public var kind: ChangeKind
    public var path: String
    public var oldPath: String?
    public var oldSize: Int64?
    public var newSize: Int64?
    public var oldMtimeNs: Int64?
    public var newMtimeNs: Int64?
    public var oldHash: String?
    public var newHash: String?
    public var status: ChangeStatus
    public var error: String?
    public var archivePath: String?
}

public struct TrackedFile: Hashable, Sendable {
    public var hash: String
    public var size: Int64
    public var destMtimeNs: Int64
}

public struct SourceIndexEntry: Hashable, Sendable {
    public var size: Int64
    public var mtimeNs: Int64
    public var inode: UInt64
    public var hash: String

    func matches(_ st: FileStat) -> Bool { size == st.size && mtimeNs == st.mtimeNs && inode == st.inode }
}

public enum ArchiveState: String, Codable, Sendable {
    case present      // renamed file still in destination
    case trashed      // moved to Trash
    case purged       // permanently deleted from destination (content may remain in version store)
    case restored     // given back to the user
    case missing      // archived file no longer found at its archive path
}

public struct ArchiveRecord: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var pairID: UUID
    public var originalPath: String
    public var archivePath: String?
    public var hash: String
    public var size: Int64
    public var mtimeNs: Int64
    public var deletedAt: Date
    public var commitSeq: Int64
    public var policy: DeletionPolicy
    public var state: ArchiveState
}

public enum ConflictKind: String, Codable, Sendable {
    case destinationModified
    case destinationTypeChanged
    case untrackedFileAtDestination
    case caseCollision
    case destinationModifiedBeforeDeletion
}

public struct SyncConflict: Hashable, Sendable, Identifiable {
    public var path: String
    public var kind: ConflictKind
    public var detail: String
    public var id: String { path }
}

public enum PathOverride: String, Codable, Sendable {
    /// Overwrite the conflicting destination file on the next sync (its bytes are preserved in history first).
    case overwriteDestination
    /// Leave this path alone entirely.
    case ignore
}

public struct SnapshotEntry: Hashable, Sendable {
    public var path: String
    public var hash: String
    public var size: Int64
    public var mtimeNs: Int64
}

public enum SnapshotDiffKind: String, Sendable { case added, removed, modified, unchanged }

public struct SnapshotDiff: Hashable, Sendable, Identifiable {
    public var path: String
    public var kind: SnapshotDiffKind
    public var before: SnapshotEntry?
    public var after: SnapshotEntry?
    public var id: String { path }
}

public struct FileVersion: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var path: String
    public var hash: String
    public var size: Int64
    public var mtimeNs: Int64
    public var fromSeq: Int64
    public var toSeq: Int64?
    public var isStored: Bool
}

public enum ActivityLevel: String, Codable, Sendable { case info, warning, error }

public struct ActivityEntry: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var pairID: UUID?
    public var timestamp: Date
    public var level: ActivityLevel
    public var message: String
}
