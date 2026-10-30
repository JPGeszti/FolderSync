import Foundation

/// Lanes of the history graph. History is strictly linear per folder pair, so each lane is a
/// single vertical line; there are no branches or merges to draw.
public enum GraphLane: Int, CaseIterable, Sendable {
    case source = 0, destination = 1, archive = 2

    public var title: String {
        switch self {
        case .source: return "Source"
        case .destination: return "Destination"
        case .archive: return "Archive"
        }
    }
}

public enum NodeFill: Sendable, Equatable {
    case solid       // all operations applied
    case partial     // some operations failed
    case hollow      // nothing applied (failed / interrupted)
}

public enum NodeTone: String, Sendable, Equatable, CaseIterable {
    case added, modified, deleted, renamed, archived, restored, failed, neutral
}

public struct GraphNode: Sendable, Equatable {
    public var lane: GraphLane
    public var fill: NodeFill
    /// Proportional segments for a multi-colored ring, derived from actual change counts.
    public var segments: [(tone: NodeTone, count: Int)]

    public static func == (a: GraphNode, b: GraphNode) -> Bool {
        a.lane == b.lane && a.fill == b.fill && a.segments.map(\.tone) == b.segments.map(\.tone) && a.segments.map(\.count) == b.segments.map(\.count)
    }

    public var dominantTone: NodeTone { segments.max { $0.count < $1.count }?.tone ?? .neutral }
}

public enum EdgeStyle: Sendable, Equatable { case solid, dashed }

/// Everything needed to draw one commit row, independent of neighbors (enables virtualization).
public struct GraphRow: Sendable, Equatable, Identifiable {
    public var seq: Int64
    public var nodes: [GraphLane: GraphNode]
    /// Lanes whose vertical line enters this row from above (a newer node exists in that lane).
    public var lineAbove: Set<GraphLane>
    /// Lanes whose vertical line leaves this row downward (an older node exists in that lane).
    public var lineBelow: Set<GraphLane>
    /// Source → Destination in the same commit: observed changes were applied.
    public var propagation: EdgeStyle?
    /// Destination → Archive: files left the active destination in this commit.
    public var archiveEdge: Bool
    /// For restore commits: the commit whose snapshot was restored.
    public var restoredFrom: Int64?

    public var id: Int64 { seq }
}

public enum GraphLayout {
    /// Pure function from commits (newest first, as returned by `Catalog.commits`) to rows.
    public static func rows(for commits: [Commit]) -> [GraphRow] {
        var rows: [GraphRow] = commits.map(node(for:))
        // Lane continuity: a line passes through/into a row if that lane has nodes on both sides.
        for lane in GraphLane.allCases {
            let indices = rows.indices.filter { rows[$0].nodes[lane] != nil }
            guard let first = indices.first, let last = indices.last else { continue }
            for i in rows.indices {
                if i > first && i <= last { rows[i].lineAbove.insert(lane) }
                if i >= first && i < last { rows[i].lineBelow.insert(lane) }
            }
        }
        return rows
    }

    static func node(for c: Commit) -> GraphRow {
        let fill: NodeFill
        switch c.status {
        case .success: fill = .solid
        case .partial: fill = .partial
        case .failed, .interrupted, .inProgress: fill = (c.totalChanges > 0) ? .partial : .hollow
        }

        var nodes: [GraphLane: GraphNode] = [:]
        var sourceSegments: [(NodeTone, Int)] = [(.added, c.added), (.modified, c.modified), (.renamed, c.renamed),
                                                 (.deleted, c.deleted + c.archived)]
        sourceSegments = sourceSegments.filter { $0.1 > 0 }
        if c.failed > 0 { sourceSegments.append((.failed, c.failed)) }

        if c.kind == .sync {
            // The source lane shows what was *observed*; it exists for every sync commit.
            nodes[.source] = GraphNode(lane: .source, fill: .solid, segments: sourceSegments.isEmpty ? [(.neutral, 1)] : sourceSegments.map { (tone: $0.0, count: $0.1) })
            var destSegments = [(NodeTone.added, c.added), (.modified, c.modified), (.renamed, c.renamed),
                                (.deleted, c.deleted + c.archived)].filter { $0.1 > 0 }
            if c.failed > 0 { destSegments.append((.failed, c.failed)) }
            nodes[.destination] = GraphNode(lane: .destination, fill: fill,
                                            segments: destSegments.isEmpty ? [(tone: .failed, count: 1)] : destSegments.map { (tone: $0.0, count: $0.1) })
        } else {
            var segs: [(tone: NodeTone, count: Int)] = []
            if c.restored > 0 { segs.append((.restored, c.restored)) }
            if c.deleted + c.archived > 0 { segs.append((.deleted, c.deleted + c.archived)) }
            if c.failed > 0 { segs.append((.failed, c.failed)) }
            nodes[.destination] = GraphNode(lane: .destination, fill: fill, segments: segs.isEmpty ? [(tone: .restored, count: 1)] : segs)
        }
        if c.archived + c.deleted > 0 && c.kind == .sync {
            var segs: [(tone: NodeTone, count: Int)] = []
            if c.archived > 0 { segs.append((.archived, c.archived)) }
            if c.deleted > 0 { segs.append((.deleted, c.deleted)) }
            nodes[.archive] = GraphNode(lane: .archive, fill: .solid, segments: segs)
        }

        let applied = c.totalChanges
        let propagation: EdgeStyle? = c.kind == .sync && applied > 0 ? (c.failed > 0 ? .dashed : .solid) : nil
        return GraphRow(seq: c.seq, nodes: nodes, lineAbove: [], lineBelow: [], propagation: propagation,
                        archiveEdge: nodes[.archive] != nil, restoredFrom: c.restoredFromSeq)
    }
}
