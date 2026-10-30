import FolderSyncCore
import SwiftUI

/// Status categories of the change explorer (colors per the product spec).
enum PendingKind: String, CaseIterable, Identifiable {
    case added, modified, deleted, renamed, archived, failed, conflict

    var id: String { rawValue }
    var label: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .archived: return "Archived"
        case .failed: return "Failed"
        case .conflict: return "Conflict"
        }
    }
    var color: Color {
        switch self {
        case .added: return Palette.added
        case .modified: return Palette.modified
        case .deleted: return Palette.deleted
        case .renamed: return Palette.renamed
        case .archived: return Palette.archived
        case .failed, .conflict: return Palette.failed
        }
    }
    var symbol: String {
        switch self {
        case .added: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .renamed: return "arrow.right.circle.fill"
        case .archived: return "archivebox.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .conflict: return "exclamationmark.2"
        }
    }
}

struct PendingChange: Hashable {
    var path: String
    var kind: PendingKind
    var detail: String
    var size: Int64?
    var mtimeNs: Int64?
    var previousSize: Int64?
    var previousHash: String?
    var oldPath: String?
}

final class ChangeNode: Identifiable, Hashable {
    let id: String
    let name: String
    var change: PendingChange?
    var children: [ChangeNode]?
    var counts: [PendingKind: Int] = [:]

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    static func == (a: ChangeNode, b: ChangeNode) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Builds a folder tree from flat change paths. Folders aggregate counts of their descendants.
    static func tree(_ changes: [PendingChange]) -> [ChangeNode] {
        let root = ChangeNode(id: "", name: "")
        root.children = []
        var index: [String: ChangeNode] = ["": root]
        for change in changes.sorted(by: { $0.path < $1.path }) {
            let parts = change.path.split(separator: "/").map(String.init)
            var parent = root
            var prefix = ""
            for (i, part) in parts.enumerated() {
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                let isLeaf = i == parts.count - 1
                let key = isLeaf ? "f:" + prefix : "d:" + prefix
                let node: ChangeNode
                if let existing = index[key] {
                    node = existing
                } else {
                    node = ChangeNode(id: key, name: part)
                    if !isLeaf { node.children = [] }
                    parent.children?.append(node)
                    index[key] = node
                }
                if isLeaf { node.change = change } else { node.counts[change.kind, default: 0] += 1 }
                parent = node
            }
        }
        func sort(_ n: ChangeNode) {
            n.children?.sort { ($0.children == nil ? 1 : 0, $0.name.lowercased()) < ($1.children == nil ? 1 : 0, $1.name.lowercased()) }
            n.children?.forEach(sort)
        }
        sort(root)
        return root.children ?? []
    }
}

struct ChangesView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var selection: Set<String> = []
    @ViewState private var visibleKinds: Set<PendingKind> = Set(PendingKind.allCases)
    @ViewState private var loading = false

    var pair: FolderPair? { model.selectedPair }

    var changes: [PendingChange] {
        guard let pair, let plan = model.previews[pair.id] else { return [] }
        var out: [PendingChange] = []
        for c in plan.copies {
            let kind: PendingKind = c.reason == .add || c.reason == .repair ? .added : .modified
            out.append(PendingChange(path: c.path.string, kind: kind, detail: c.reason == .repair ? "Destination copy missing; will be re-created" : c.reason == .overwriteConflict ? "Will overwrite the destination copy (preserved in history first)" : "",
                                     size: c.sourceStat.size, mtimeNs: c.sourceStat.mtimeNs, previousSize: c.previous?.size, previousHash: c.previous?.hash))
        }
        for r in plan.renames {
            out.append(PendingChange(path: r.to.string, kind: .renamed, detail: "Renamed from \(r.from.string)", size: r.sourceStat.size, mtimeNs: r.sourceStat.mtimeNs,
                                     previousSize: r.tracked.size, previousHash: r.tracked.hash, oldPath: r.from.string))
        }
        let policy = pair.effectiveDeletionPolicy
        for d in plan.deletions {
            let kind: PendingKind = policy == .preserveRename ? .archived : .deleted
            let note = policy == .preserveRename ? "Will be kept as an archived _DELETED copy" : policy == .moveToTrash ? "Will be moved to the Trash" : "Will be deleted permanently"
            out.append(PendingChange(path: d.path.string, kind: kind, detail: plan.deletionBlock == nil ? note : note + " (held: safety threshold)",
                                     size: nil, mtimeNs: nil, previousSize: d.tracked.size, previousHash: d.tracked.hash))
        }
        for a in plan.adoptions {
            out.append(PendingChange(path: a.path.string, kind: .added, detail: "Identical file already in destination; will be tracked", size: a.sourceStat.size, mtimeNs: a.sourceStat.mtimeNs))
        }
        for c in plan.conflicts {
            out.append(PendingChange(path: c.path, kind: .conflict, detail: c.detail))
        }
        if let commit = model.lastReports[pair.id]?.commit, let failed = try? model.catalog?.changes(commitSeq: commit.seq).filter({ $0.status == .failed }) {
            for f in failed where !out.contains(where: { $0.path == f.path }) {
                out.append(PendingChange(path: f.path, kind: .failed, detail: f.error ?? "Failed"))
            }
        }
        return out.filter { visibleKinds.contains($0.kind) }
    }

    var body: some View {
        if let pair {
            let items = changes
            HSplitView {
                VStack(spacing: 0) {
                    header(pair, items)
                    Divider()
                    if items.isEmpty {
                        EmptyStateView(title: loading ? "Scanning…" : "No pending changes", symbol: loading ? "magnifyingglass" : "checkmark.circle",
                                       message: loading ? "Comparing metadata of source and destination." : "The destination matches the source.")
                    } else {
                        List(ChangeNode.tree(items), children: \.children, selection: $selection) { node in
                            ChangeRow(node: node).tag(node.id)
                        }
                        .listStyle(.inset(alternatesRowBackgrounds: true))
                    }
                }
                .frame(minWidth: 420)
                ChangeInspector(pair: pair, changes: items.filter { selection.contains("f:" + $0.path) })
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            }
            .task(id: pair.id) { await refresh(pair) }
        } else {
            EmptyStateView(title: "No folder pair selected", symbol: "folder", message: "Add or select a folder pair.")
        }
    }

    func refresh(_ pair: FolderPair) async {
        loading = true
        await model.refreshPreview(pair.id)
        loading = false
    }

    @ViewBuilder
    func header(_ pair: FolderPair, _ items: [PendingChange]) -> some View {
        let selectedPaths = Set(selection.filter { $0.hasPrefix("f:") }.map { String($0.dropFirst(2)) })
        let actionable = selectedPaths.filter { p in items.contains { $0.path == p && $0.kind != .conflict && $0.kind != .failed } }
        HStack(spacing: 8) {
            ForEach(PendingKind.allCases) { kind in
                let n = items.filter { $0.kind == kind }.count
                Toggle(isOn: Binding(get: { visibleKinds.contains(kind) }, set: { on in if on { visibleKinds.insert(kind) } else { visibleKinds.remove(kind) } })) {
                    HStack(spacing: 3) {
                        Image(systemName: kind.symbol).foregroundStyle(kind.color)
                        Text("\(n)").monospacedDigit()
                    }
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help("\(kind.label): \(n). Click to show or hide.")
                .accessibilityLabel("\(kind.label) \(n)")
            }
            Spacer()
            Button { Task { await refresh(pair) } } label: { Image(systemName: "arrow.clockwise") }
                .fixedSize()
                .help("Recompute pending changes (dry run, nothing is modified)")
            if !actionable.isEmpty {
                Button("Sync \(actionable.count) Selected") {
                    Task {
                        guard let service = model.service else { return }
                        _ = try? await service.synchronize(pair, options: SyncOptions(limitTo: Set(actionable)))
                        model.reload()
                        await refresh(pair)
                    }
                }
                .fixedSize()
            }
            Button("Synchronize All") { Task { await model.sync(pair.id) } }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(model.state(pair.id) == .syncing)
        }
        .padding(10)
        if let block = model.previews[pair.id]?.deletionBlock {
            DeletionBlockBanner(pair: pair, block: block).padding([.horizontal, .bottom], 10)
        }
    }
}

struct ChangeRow: View {
    let node: ChangeNode

    var body: some View {
        HStack(spacing: 8) {
            if let change = node.change {
                Image(systemName: change.kind.symbol).foregroundStyle(change.kind.color)
                Text(node.name)
                if let old = change.oldPath { Text("← \((old as NSString).lastPathComponent)").foregroundStyle(.secondary).font(.caption) }
                Spacer()
                if let s = change.size ?? change.previousSize { Text(Format.size(s)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                Badge(text: change.kind.label, color: change.kind.color)
            } else {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(node.name)
                Spacer()
                ForEach(PendingKind.allCases.filter { node.counts[$0] != nil }) { k in
                    Text("\(node.counts[k]!)").font(.caption2.weight(.semibold)).foregroundStyle(k.color)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ChangeInspector: View {
    @EnvironmentObject var model: AppModel
    var pair: FolderPair
    var changes: [PendingChange]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if changes.isEmpty {
                    Text("Select a file to inspect its metadata.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else if changes.count > 1 {
                    Text("\(changes.count) files selected").font(.headline)
                } else if let c = changes.first {
                    Label(c.kind.label, systemImage: c.kind.symbol).foregroundStyle(c.kind.color).font(.headline)
                    Text(c.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    if !c.detail.isEmpty { Text(c.detail).foregroundStyle(.secondary) }
                    Grid(alignment: .leading, verticalSpacing: 6) {
                        if let old = c.oldPath { GridRow { Text("Previous path").foregroundStyle(.secondary); Text(old).textSelection(.enabled) } }
                        GridRow { Text("Source size").foregroundStyle(.secondary); Text(Format.size(c.size)) }
                        GridRow { Text("Source modified").foregroundStyle(.secondary); Text(Format.mtime(c.mtimeNs)) }
                        GridRow { Text("Destination size").foregroundStyle(.secondary); Text(Format.size(c.previousSize)) }
                        GridRow { Text("Destination hash").foregroundStyle(.secondary); HashText(hash: c.previousHash) }
                    }
                    .font(.callout)
                    if c.kind == .conflict {
                        Divider()
                        Text("Resolve conflict").font(.headline)
                        Button("Overwrite Destination (Keep Its Copy in History)") { model.resolveConflict(pair.id, path: c.path, .overwriteDestination) }
                        Button("Ignore This Path") { model.resolveConflict(pair.id, path: c.path, .ignore) }
                        Text("Conflicts are never resolved automatically. The current destination file is preserved in the encrypted version history before it is replaced.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary)
    }
}
