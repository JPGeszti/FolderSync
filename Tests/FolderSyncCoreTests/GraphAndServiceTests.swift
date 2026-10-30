import Foundation
import Testing
@testable import FolderSyncCore

@Suite("Commit graph layout")
struct GraphLayoutTests {
    func commit(_ seq: Int64, kind: CommitKind = .sync, status: CommitStatus = .success, added: Int = 0, modified: Int = 0,
                deleted: Int = 0, archived: Int = 0, restored: Int = 0, failed: Int = 0, from: Int64? = nil) -> Commit {
        Commit(seq: seq, id: "c\(seq)", pairID: UUID(), parentID: nil, kind: kind, status: status, startedAt: Date(), finishedAt: Date(),
               added: added, modified: modified, deleted: deleted, renamed: 0, archived: archived, restored: restored, failed: failed,
               bytesTransferred: 0, message: nil, restoredFromSeq: from)
    }

    @Test func linearHistoryHasOneNodePerCommitAndNoBranches() {
        let commits = [commit(4, modified: 4), commit(3, archived: 1), commit(2, modified: 2), commit(1, added: 3)]
        let rows = GraphLayout.rows(for: commits)
        #expect(rows.map(\.seq) == [4, 3, 2, 1])
        let everyRowHasBothNodes = rows.allSatisfy { $0.nodes[.source] != nil && $0.nodes[.destination] != nil }
        #expect(everyRowHasBothNodes)
        // Archive lane only where something was actually archived.
        let archivePresence = rows.map { $0.nodes[.archive] != nil }
        #expect(archivePresence == [false, true, false, false])
        #expect(rows.map(\.archiveEdge) == [false, true, false, false])
        // Continuous lines between first and last node, never beyond.
        #expect(rows.first?.lineAbove.isEmpty == true)
        #expect(rows.last?.lineBelow.isEmpty == true)
        #expect(rows[1].lineAbove.contains(.source))
        #expect(rows[1].lineBelow.contains(.source))
        // Archive lane has a single node: no line drawn above or below it.
        let archiveLines = rows.contains { $0.lineAbove.contains(.archive) || $0.lineBelow.contains(.archive) }
        #expect(!archiveLines)
    }

    @Test func nodeColorsAndFillReflectChangeCountsAndStatus() {
        let rows = GraphLayout.rows(for: [commit(2, status: .partial, added: 1, modified: 3, failed: 2), commit(1, status: .interrupted)])
        let dest = rows[0].nodes[.destination]!
        #expect(dest.fill == .partial)
        #expect(dest.segments.map(\.tone) == [.added, .modified, .failed])
        #expect(dest.segments.map(\.count) == [1, 3, 2])
        #expect(dest.dominantTone == .modified)
        #expect(rows[0].propagation == .dashed)
        #expect(rows[1].nodes[.destination]?.fill == .hollow)
        #expect(rows[1].propagation == nil)
    }

    @Test func restoreCommitHasNoSourceNodeAndRecordsProvenance() {
        let rows = GraphLayout.rows(for: [commit(3, kind: .restore, restored: 2, from: 1), commit(2, added: 1), commit(1, added: 2)])
        #expect(rows[0].nodes[.source] == nil)
        #expect(rows[0].nodes[.destination]?.dominantTone == .restored)
        #expect(rows[0].restoredFrom == 1)
        #expect(rows[0].propagation == nil)
        // The source lane begins at commit 2; nothing enters row 0's source lane from above.
        #expect(!rows[0].lineBelow.contains(.source))
        #expect(rows[1].lineBelow.contains(.source))
    }
}

@Suite("Sync service")
struct SyncServiceTests {
    @Test func serviceRejectsOverlappingRunsAndMaintenanceDuringSync() async throws {
        let f = try Fixture()
        for i in 0..<200 { try f.write("d/\(i).txt", String(repeating: "x", count: 10_000)) }
        let service = SyncService(storage: f.storage, access: PlainPathAccess())
        async let first = service.synchronize(f.pair)
        try await Task.sleep(nanoseconds: 5_000_000)
        await #expect(throws: SyncError.busy) { _ = try await service.synchronize(f.pair) }
        _ = try await first
        let result = try await service.runMaintenance()
        #expect(result.collected == 0)
    }

    @Test func fsEventsTriggerDebouncedCallback() async throws {
        let f = try Fixture()
        let counter = Counter()
        let watcher = FSEventsWatcher(path: f.src.path, debounce: 0.3) { counter.increment() }
        try await Task.sleep(nanoseconds: 300_000_000)
        for i in 0..<10 { try f.write("burst\(i).txt", "x") }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        watcher.stop()
        #expect(counter.value >= 1)
        #expect(counter.value <= 3) // a burst of 10 writes is coalesced
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
