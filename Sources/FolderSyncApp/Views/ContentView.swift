import FolderSyncCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
                Section {
                    ForEach(SidebarSection.allCases.filter { $0 != .settings }) { s in
                        Label(s.title, systemImage: s.symbol)
                            .badge(badge(for: s))
                            .tag(s)
                    }
                }
                if !model.pairs.isEmpty {
                    Section("Folder Pairs") {
                        ForEach(model.pairs) { pair in
                            PairSidebarRow(pair: pair, state: model.state(pair.id), selected: pair.id == model.selectedPair?.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedPairID = pair.id }
                        }
                    }
                }
                Section {
                    Label(SidebarSection.settings.title, systemImage: SidebarSection.settings.symbol).tag(SidebarSection.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            Group {
                if let error = model.startupError {
                    EmptyStateView(title: "Storage unavailable", symbol: "lock.trianglebadge.exclamationmark", message: error)
                } else {
                    switch model.section {
                    case .dashboard: DashboardView()
                    case .pairs: PairsView()
                    case .changes: ChangesView()
                    case .history: HistoryView()
                    case .archived: ArchivedFilesView()
                    case .activity: ActivityLogView()
                    case .settings: ScrollView { SettingsView().padding(24).frame(maxWidth: 640) }
                    }
                }
            }
            .navigationTitle(model.section.title)
            .navigationSubtitle(model.section == .dashboard || model.section == .pairs || model.section == .settings || model.section == .activity ? "" : (model.selectedPair?.name ?? ""))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.section != .pairs && model.section != .settings && model.pairs.count > 1 {
                        Picker("Folder Pair", selection: Binding(get: { model.selectedPair?.id }, set: { model.selectedPairID = $0 })) {
                            ForEach(model.pairs) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                        .help("Folder pair shown in Changes, History and Archived Files")
                    }
                    Button {
                        model.syncSelected()
                    } label: {
                        Label("Synchronize", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Synchronize the selected folder pair now (⌘R)")
                    .disabled(model.selectedPair == nil || model.state(model.selectedPair!.id) == .syncing)
                }
            }
        }
        .task { await UISnapshots.run(model: model) }
        .alert("FolderSync", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }

    func badge(for s: SidebarSection) -> Int {
        guard let id = model.selectedPair?.id else { return 0 }
        switch s {
        case .changes: return (model.previews[id]?.pendingChangeCount ?? 0) + (model.previews[id]?.conflicts.count ?? 0)
        case .archived: return model.stats[id]?.archivedFiles ?? 0
        default: return 0
        }
    }
}

struct PairSidebarRow: View {
    var pair: FolderPair
    var state: PairState
    var selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.symbol)
                .foregroundStyle(state.color)
                .symbolEffect(.pulse, isActive: state == .syncing)
            VStack(alignment: .leading, spacing: 1) {
                Text(pair.name).fontWeight(selected ? .semibold : .regular)
                Text(state.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: model.overallState.symbol).foregroundStyle(model.overallState.color)
                Text("FolderSync").font(.headline)
                Spacer()
                Text(model.overallState == .syncing ? "Syncing" : "Idle").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if model.pairs.isEmpty {
                Text("No folder pairs yet").foregroundStyle(.secondary)
            }
            ForEach(model.pairs) { pair in
                HStack {
                    Image(systemName: model.state(pair.id).symbol).foregroundStyle(model.state(pair.id).color).frame(width: 18)
                    VStack(alignment: .leading) {
                        Text(pair.name)
                        Text("Last sync \(Format.relative(model.stats[pair.id]?.lastSuccess))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await model.sync(pair.id) }
                    } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.borderless)
                        .help("Synchronize now")
                        .disabled(model.state(pair.id) == .syncing)
                }
            }
            Divider()
            HStack {
                Button("Sync All") { model.syncAll() }
                Button(model.pairs.allSatisfy(\.paused) ? "Resume All" : "Pause All") {
                    model.setAllPaused(!model.pairs.allSatisfy(\.paused))
                }
                Spacer()
                Button("Open…") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button {
                    NSApp.terminate(nil)
                } label: { Image(systemName: "power") }
                    .help("Quit FolderSync")
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
