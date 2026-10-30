import FolderSyncCore
import SwiftUI

enum HistoryFilter: String, CaseIterable, Identifiable {
    case added, modified, deleted, renamed, restored, failed
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    func matches(_ c: Commit) -> Bool {
        switch self {
        case .added: return c.added > 0
        case .modified: return c.modified > 0
        case .deleted: return c.deleted + c.archived > 0
        case .renamed: return c.renamed > 0
        case .restored: return c.kind == .restore || c.restored > 0
        case .failed: return c.failed > 0 || c.status == .failed || c.status == .interrupted
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var commits: [Commit] = []
    @ViewState private var rows: [GraphRow] = []
    @ViewState private var exhausted = false
    @ViewState private var selectedSeq: Int64?
    @ViewState private var compareSeq: Int64?
    @ViewState private var filters: Set<HistoryFilter> = []
    @ViewState private var useDateRange = false
    @ViewState private var fromDate = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @ViewState private var toDate = Date()
    @ViewState private var zoom: CGFloat = 1
    @ViewState private var pinchBase: CGFloat = 1
    @ViewState private var showCompare = false
    @FocusState private var focused: Bool

    static let pageSize = 300

    var pair: FolderPair? { model.selectedPair }
    var metrics: GraphMetrics { GraphMetrics(zoom: zoom) }

    /// Rows are laid out on the full chronological history and filtered afterwards, so lane lines
    /// keep running through hidden commits instead of falsely connecting distant ones.
    var visible: [(Commit, GraphRow)] {
        zip(commits, rows).filter { c, _ in
            (filters.isEmpty || filters.contains { $0.matches(c) })
                && (!useDateRange || (c.startedAt >= Calendar.current.startOfDay(for: fromDate) && c.startedAt <= Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: toDate))!))
        }
    }

    var body: some View {
        if let pair {
            HSplitView {
                VStack(spacing: 0) {
                    filterBar
                    Divider()
                    graph(pair)
                    Divider()
                    GraphLegend().padding(.horizontal, 12).padding(.vertical, 6)
                }
                .frame(minWidth: 520)
                Group {
                    if let seq = selectedSeq, let commit = commits.first(where: { $0.seq == seq }) {
                        CommitDetailView(pair: pair, commit: commit, compareSeq: compareSeq, onCompare: { showCompare = true },
                                         onJump: { jump(to: $0) })
                            .id(commit.seq)
                    } else {
                        EmptyStateView(title: "No commit selected", symbol: "point.3.connected.trianglepath.dotted",
                                       message: "Select a node to inspect a synchronization. ⌘-click a second node to compare snapshots.")
                    }
                }
                .frame(minWidth: 340, idealWidth: 420)
            }
            .task(id: "\(pair.id)-\(model.historyRevision)") { load(pair, reset: true) }
            .sheet(isPresented: $showCompare) {
                if let a = compareSeq, let b = selectedSeq {
                    CompareView(pair: pair, from: min(a, b), to: max(a, b), commits: commits)
                }
            }
        } else {
            EmptyStateView(title: "No folder pair selected", symbol: "folder", message: "Add or select a folder pair to see its history.")
        }
    }

    var filterBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(HistoryFilter.allCases) { f in
                    Toggle(f.label, isOn: Binding(get: { filters.contains(f) }, set: { if $0 { filters.insert(f) } else { filters.remove(f) } }))
                }
                Divider()
                Button("Show All") { filters.removeAll() }
            } label: {
                Label(filters.isEmpty ? "All operations" : filters.map(\.label).sorted().joined(separator: ", "), systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            Toggle("Date range", isOn: $useDateRange).toggleStyle(.checkbox)
            if useDateRange {
                DatePicker("From", selection: $fromDate, displayedComponents: .date).labelsHidden()
                Text("–").foregroundStyle(.secondary)
                DatePicker("To", selection: $toDate, displayedComponents: .date).labelsHidden()
            }
            Spacer()
            if compareSeq != nil, selectedSeq != nil, compareSeq != selectedSeq {
                Button("Compare Snapshots") { showCompare = true }
            }
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $zoom, in: 0.6...2.0).frame(width: 110).help("Zoom the graph (or pinch)")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(10)
    }

    @ViewBuilder
    func graph(_ pair: FolderPair) -> some View {
        let items = visible
        if commits.isEmpty {
            EmptyStateView(title: "No history yet", symbol: "clock", message: "Commits appear here after the first synchronization.")
        } else {
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(items, id: \.0.seq) { commit, row in
                                CommitRow(commit: commit, row: row, metrics: metrics, selected: selectedSeq == commit.seq, compared: compareSeq == commit.seq)
                                    .id(commit.seq)
                                    .contentShape(Rectangle())
                                    .onTapGesture { select(commit.seq, comparing: NSEvent.modifierFlags.contains(.command)) }
                                    .onAppear { if commit.seq == commits.last?.seq, !exhausted { load(pair, reset: false) } }
                            }
                            if !exhausted {
                                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding()
                                    .onAppear { load(pair, reset: false) }
                            }
                        } header: {
                            HStack(spacing: 12) {
                                LaneHeader(metrics: metrics)
                                Text("Commit").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .background(.bar)
                        }
                    }
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { move(+1, items, proxy); return .handled }
                .onKeyPress(.upArrow) { move(-1, items, proxy); return .handled }
                .gesture(MagnifyGesture()
                    .onChanged { zoom = min(2, max(0.6, pinchBase * $0.magnification)) }
                    .onEnded { _ in pinchBase = zoom })
                .onChange(of: selectedSeq) { _, seq in
                    if let seq { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(seq, anchor: .center) } }
                }
            }
        }
    }

    func select(_ seq: Int64, comparing: Bool) {
        focused = true
        if comparing, selectedSeq != nil, selectedSeq != seq {
            compareSeq = seq
        } else {
            selectedSeq = seq
        }
    }

    func move(_ delta: Int, _ items: [(Commit, GraphRow)], _ proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        let idx = items.firstIndex { $0.0.seq == selectedSeq } ?? -1
        let next = min(max(idx + delta, 0), items.count - 1)
        selectedSeq = items[next].0.seq
    }

    func jump(to seq: Int64) {
        filters.removeAll()
        useDateRange = false
        selectedSeq = seq
    }

    func load(_ pair: FolderPair, reset: Bool) {
        guard let catalog = model.catalog else { return }
        let offset = reset ? 0 : commits.count
        let page = (try? catalog.commits(pair: pair.id, limit: HistoryView.pageSize, offset: offset)) ?? []
        if reset { commits = page } else { commits.append(contentsOf: page) }
        exhausted = page.count < HistoryView.pageSize
        rows = GraphLayout.rows(for: commits)
        if reset, selectedSeq == nil || !commits.contains(where: { $0.seq == selectedSeq }) { selectedSeq = commits.first?.seq }
    }
}

struct CommitRow: View {
    var commit: Commit
    var row: GraphRow
    var metrics: GraphMetrics
    var selected: Bool
    var compared: Bool

    var body: some View {
        HStack(spacing: 12) {
            GraphCell(row: row, metrics: metrics, selected: selected, compared: compared)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    if commit.status != .success { Badge(text: commit.status.label, color: commit.status.color) }
                    if let from = commit.restoredFromSeq { Badge(text: "from #\(from)", color: Palette.restored, symbol: "arrow.uturn.backward") }
                }
                if metrics.zoom >= 0.85 {
                    HStack(spacing: 8) {
                        Text(commit.shortID).font(.system(.caption, design: .monospaced))
                        Text(commit.startedAt.formatted(date: .abbreviated, time: .shortened))
                        if commit.bytesTransferred > 0 { Text(Format.size(commit.bytesTransferred)) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            CountsStrip(commit: commit)
        }
        .padding(.horizontal, 8)
        .frame(height: metrics.rowHeight)
        .background(selected ? Color.accentColor.opacity(0.14) : compared ? Palette.renamed.opacity(0.08) : .clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(commit.status.label), \(commit.startedAt.formatted())")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var title: String {
        if commit.kind == .restore { return commit.message ?? "Restore" }
        var parts: [String] = []
        if commit.added > 0 { parts.append("\(commit.added) added") }
        if commit.modified > 0 { parts.append("\(commit.modified) modified") }
        if commit.renamed > 0 { parts.append("\(commit.renamed) renamed") }
        if commit.archived > 0 { parts.append("\(commit.archived) archived") }
        if commit.deleted > 0 { parts.append("\(commit.deleted) deleted") }
        if commit.failed > 0 { parts.append("\(commit.failed) failed") }
        return parts.isEmpty ? "No file changes" : parts.joined(separator: " · ")
    }
}

struct CountsStrip: View {
    var commit: Commit
    var body: some View {
        HStack(spacing: 6) {
            count(commit.added, Palette.added, "plus")
            count(commit.modified, Palette.modified, "pencil")
            count(commit.renamed, Palette.renamed, "arrow.right")
            count(commit.archived, Palette.archived, "archivebox")
            count(commit.deleted, Palette.deleted, "minus")
            count(commit.restored, Palette.restored, "clock.arrow.circlepath")
            count(commit.failed, Palette.failed, "exclamationmark.triangle")
        }
        .font(.caption.monospacedDigit())
    }

    @ViewBuilder
    func count(_ n: Int, _ color: Color, _ symbol: String) -> some View {
        if n > 0 {
            HStack(spacing: 2) { Image(systemName: symbol); Text("\(n)") }.foregroundStyle(color)
        }
    }
}
