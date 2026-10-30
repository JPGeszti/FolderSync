import FolderSyncCore
import SwiftUI

/// Geometry of the graph columns, scaled by the zoom factor.
struct GraphMetrics {
    var zoom: CGFloat
    var rowHeight: CGFloat { 46 * zoom }
    var laneSpacing: CGFloat { 38 * max(zoom, 0.8) }
    var leading: CGFloat { 20 }
    var nodeRadius: CGFloat { min(8 * zoom, rowHeight * 0.3) }
    var width: CGFloat { leading * 2 + laneSpacing * CGFloat(GraphLane.allCases.count - 1) }
    func x(_ lane: GraphLane) -> CGFloat { leading + laneSpacing * CGFloat(lane.rawValue) }
}

/// Draws one commit row of the graph: lane lines, nodes and in-row edges. Rows are drawn
/// independently so the list can be virtualized for very long histories.
struct GraphCell: View {
    var row: GraphRow
    var metrics: GraphMetrics
    var selected: Bool
    var compared: Bool

    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            let r = metrics.nodeRadius

            // 1. Lane lines (continuity between commits of the same lane).
            for lane in GraphLane.allCases {
                let x = metrics.x(lane)
                let hasNode = row.nodes[lane] != nil
                let color = Palette.lane(lane).opacity(lane == .archive ? 0.55 : 0.7)
                let w: CGFloat = lane == .destination ? 2.5 : 2
                if row.lineAbove.contains(lane) {
                    var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: hasNode ? midY - r : midY))
                    ctx.stroke(p, with: .color(color), lineWidth: w)
                }
                if row.lineBelow.contains(lane) {
                    var p = Path(); p.move(to: CGPoint(x: x, y: hasNode ? midY + r : midY)); p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(color), lineWidth: w)
                }
            }

            // 2. Horizontal edges inside the commit.
            if let style = row.propagation, row.nodes[.source] != nil, row.nodes[.destination] != nil {
                let from = CGPoint(x: metrics.x(.source) + r + 2, y: midY)
                let to = CGPoint(x: metrics.x(.destination) - r - 3, y: midY)
                var p = Path(); p.move(to: from); p.addLine(to: to)
                ctx.stroke(p, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: style == .dashed ? [3, 3] : []))
                var head = Path()
                head.move(to: CGPoint(x: to.x - 5, y: midY - 3.5)); head.addLine(to: to); head.addLine(to: CGPoint(x: to.x - 5, y: midY + 3.5))
                ctx.stroke(head, with: .color(.secondary), lineWidth: 1.5)
            }
            if row.archiveEdge {
                var p = Path()
                p.move(to: CGPoint(x: metrics.x(.destination) + r + 2, y: midY))
                p.addLine(to: CGPoint(x: metrics.x(.archive) - r - 2, y: midY))
                ctx.stroke(p, with: .color(Palette.archived.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            }

            // 3. Nodes.
            for (lane, node) in row.nodes {
                let center = CGPoint(x: metrics.x(lane), y: midY)
                draw(node, at: center, radius: r, in: &ctx)
            }

            // 4. Selection rings.
            if selected || compared, let dest = row.nodes[.destination] ?? row.nodes.values.first {
                let c = CGPoint(x: metrics.x(dest.lane), y: midY)
                let ring = Path(ellipseIn: CGRect(x: c.x - r - 4, y: c.y - r - 4, width: (r + 4) * 2, height: (r + 4) * 2))
                ctx.stroke(ring, with: .color(compared ? Palette.renamed : .accentColor), style: StrokeStyle(lineWidth: 2, dash: compared && !selected ? [3, 2] : []))
            }
        }
        .frame(width: metrics.width, height: metrics.rowHeight)
        .accessibilityHidden(true)
    }

    private func draw(_ node: GraphNode, at c: CGPoint, radius r: CGFloat, in ctx: inout GraphicsContext) {
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        let circle = Path(ellipseIn: rect)
        let dominant = Palette.color(node.dominantTone)

        // Background disc so lines never show through the node.
        ctx.fill(circle, with: .color(Color(nsColor: .windowBackgroundColor)))

        // Segmented ring proportional to change counts.
        let total = max(node.segments.reduce(0) { $0 + $1.count }, 1)
        var start = Angle.degrees(-90)
        for seg in node.segments {
            let sweep = Angle.degrees(360 * Double(seg.count) / Double(total))
            var arc = Path()
            arc.addArc(center: c, radius: r - 1, startAngle: start, endAngle: start + sweep, clockwise: false)
            ctx.stroke(arc, with: .color(Palette.color(seg.tone)), lineWidth: 2.5)
            start += sweep
        }

        switch node.fill {
        case .solid:
            ctx.fill(Path(ellipseIn: rect.insetBy(dx: r * 0.38, dy: r * 0.38)), with: .color(dominant))
        case .partial:
            var half = Path()
            half.addArc(center: c, radius: r * 0.6, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            half.closeSubpath()
            ctx.fill(half, with: .color(dominant))
        case .hollow:
            var x = Path()
            let d = r * 0.4
            x.move(to: CGPoint(x: c.x - d, y: c.y - d)); x.addLine(to: CGPoint(x: c.x + d, y: c.y + d))
            x.move(to: CGPoint(x: c.x + d, y: c.y - d)); x.addLine(to: CGPoint(x: c.x - d, y: c.y + d))
            ctx.stroke(x, with: .color(Palette.failed), lineWidth: 1.8)
        }
    }
}

/// Column headers aligned with the lanes.
struct LaneHeader: View {
    var metrics: GraphMetrics

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(GraphLane.allCases, id: \.self) { lane in
                Text(lane.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.lane(lane))
                    .fixedSize()
                    .rotationEffect(.degrees(-40), anchor: .bottomLeading)
                    .offset(x: metrics.x(lane) - 2, y: -4)
            }
        }
        .frame(width: metrics.width, height: 58, alignment: .bottomLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lanes: source, destination, archive")
    }
}

/// Legend explaining node colors and fills.
struct GraphLegend: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { legend }
    }

    var legend: some View {
        HStack(spacing: 12) {
            ForEach([NodeTone.added, .modified, .deleted, .renamed, .archived, .restored, .failed], id: \.self) { tone in
                HStack(spacing: 4) {
                    Circle().fill(Palette.color(tone)).frame(width: 8, height: 8)
                    Text(tone.rawValue.capitalized)
                }
            }
            Divider().frame(height: 12)
            HStack(spacing: 4) { Image(systemName: "circle.fill"); Text("applied") }
            HStack(spacing: 4) { Image(systemName: "circle.lefthalf.filled"); Text("partial") }
            HStack(spacing: 4) { Image(systemName: "xmark.circle"); Text("failed") }
            HStack(spacing: 4) { Image(systemName: "arrow.right"); Text("propagated") }
        }
        .font(.caption2)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(.secondary)
    }
}
