import AppKit
import FolderSyncCore
import SwiftUI

struct ArchivedFilesView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var archives: [ArchiveRecord] = []
    @ViewState private var search = ""
    @ViewState private var stateFilter: ArchiveState?
    @ViewState private var selection: Set<ArchiveRecord.ID> = []
    @ViewState private var allPairs = false

    var shown: [ArchiveRecord] {
        archives.filter { a in
            (stateFilter == nil || a.state == stateFilter)
                && (search.isEmpty || a.originalPath.localizedCaseInsensitiveContains(search) || (a.archivePath ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("State", selection: $stateFilter) {
                    Text("All states").tag(ArchiveState?.none)
                    Text("Kept in destination").tag(ArchiveState?.some(.present))
                    Text("In Trash").tag(ArchiveState?.some(.trashed))
                    Text("Deleted (history only)").tag(ArchiveState?.some(.purged))
                    Text("Restored").tag(ArchiveState?.some(.restored))
                }
                .fixedSize()
                Toggle("All pairs", isOn: $allPairs).toggleStyle(.checkbox)
                Spacer()
                TextField("Search names", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            .padding(10)
            Divider()
            if shown.isEmpty {
                EmptyStateView(title: "No archived files", symbol: "archivebox",
                               message: "Files deleted from the source appear here according to each pair's deletion policy.")
            } else {
                Table(shown, selection: $selection) {
                    TableColumn("Original path") { a in Text(a.originalPath).lineLimit(1).truncationMode(.middle).help(a.originalPath) }
                    TableColumn("Kept as") { a in Text(a.archivePath ?? "—").foregroundStyle(Palette.archived).lineLimit(1).truncationMode(.middle) }
                    TableColumn("Policy") { a in Text(a.policy.title).font(.caption) }.width(120)
                    TableColumn("State") { a in Badge(text: label(a.state), color: color(a.state)) }.width(110)
                    TableColumn("Deleted") { a in Text(Format.date(a.deletedAt)).font(.caption) }.width(150)
                    TableColumn("Size") { a in Text(Format.size(a.size)).monospacedDigit() }.width(70)
                    TableColumn("Commit") { a in Text("#\(a.commitSeq)").monospacedDigit().foregroundStyle(.secondary) }.width(60)
                }
                .contextMenu(forSelectionType: ArchiveRecord.ID.self) { ids in
                    if let a = archives.first(where: { ids.contains($0.id) }) { menu(for: a) }
                }
            }
        }
        .task(id: "\(model.selectedPair?.id.uuidString ?? "")-\(allPairs)-\(model.historyRevision)") { load() }
    }

    @ViewBuilder
    func menu(for a: ArchiveRecord) -> some View {
        if a.state != .restored, let pair = model.pairs.first(where: { $0.id == a.pairID }) {
            Button("Restore to Original Location") { restore(a, pair: pair, export: false) }
            Button("Export Copy…") { restore(a, pair: pair, export: true) }
            if a.state == .present, let p = a.archivePath {
                Button("Show in Finder") {
                    _ = try? BookmarkAccess().withAccess(to: pair) { _, dst in
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dst).appendingPathComponent(p)])
                    }
                }
            }
        }
    }

    func restore(_ a: ArchiveRecord, pair: FolderPair, export: Bool) {
        guard let storage = model.storage else { return }
        var chosen: String?
        if export {
            guard let dir = RestoreActions.chooseFolder(prompt: "Export") else { return }
            chosen = dir.path
        }
        let exportDir = chosen
        RestoreActions.run(model, "Restore") {
            try BookmarkAccess().withAccess(to: pair) { _, dst in
                let out = try Restorer(storage: storage).restoreArchive(a, destination: dst, mode: exportDir.map { .export(directory: $0) } ?? .originalLocation)
                return "Restored to \(out)"
            }
        }
    }

    func load() {
        archives = (try? model.catalog?.archives(pair: allPairs ? nil : model.selectedPair?.id)) ?? []
    }

    func label(_ s: ArchiveState) -> String {
        switch s {
        case .present: return "Kept"
        case .trashed: return "In Trash"
        case .purged: return "History only"
        case .restored: return "Restored"
        case .missing: return "Missing"
        }
    }

    func color(_ s: ArchiveState) -> Color {
        switch s {
        case .present: return Palette.archived
        case .trashed: return Palette.deleted
        case .purged: return .secondary
        case .restored: return Palette.restored
        case .missing: return Palette.failed
        }
    }
}

struct ActivityLogView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var entries: [ActivityEntry] = []
    @ViewState private var level: ActivityLevel?
    @ViewState private var search = ""

    var shown: [ActivityEntry] {
        entries.filter { (level == nil || $0.level == level) && (search.isEmpty || $0.message.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Level", selection: $level) {
                    Text("All").tag(ActivityLevel?.none)
                    Text("Info").tag(ActivityLevel?.some(.info))
                    Text("Warnings").tag(ActivityLevel?.some(.warning))
                    Text("Errors").tag(ActivityLevel?.some(.error))
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
            }
            .padding(10)
            Divider()
            Table(shown) {
                TableColumn("") { e in
                    Image(systemName: e.level == .error ? "xmark.octagon.fill" : e.level == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(e.level == .error ? Palette.deleted : e.level == .warning ? Palette.failed : .secondary)
                }
                .width(24)
                TableColumn("Time") { e in Text(Format.date(e.timestamp)).font(.caption).monospacedDigit() }.width(170)
                TableColumn("Pair") { e in Text(model.pairs.first { $0.id == e.pairID }?.name ?? "—").font(.caption) }.width(120)
                TableColumn("Message") { e in Text(e.message).textSelection(.enabled).lineLimit(3).help(e.message) }
            }
            HStack {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("The log records file names, counts and errors only — never file contents. It is stored locally and never transmitted.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
        }
        .task(id: model.historyRevision) { load() }
    }

    func load() { entries = (try? model.catalog?.activity(limit: 2000)) ?? [] }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var busy = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch FolderSync at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                    .disabled(!AppModel.isBundled)
                Toggle("Show notifications", isOn: $model.notificationsEnabled)
                if !AppModel.isBundled {
                    Text("Login item and notifications require running the bundled FolderSync.app.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Version store") {
                LabeledContent("Location", value: (model.storage?.root.path as NSString?)?.abbreviatingWithTildeInPath ?? "—")
                LabeledContent("Size on disk", value: Format.size(model.storeSize))
                LabeledContent("Encryption", value: "AES-256-GCM, content-addressed (SHA-256)")
                LabeledContent("Key stored in", value: model.keySource == .keychain ? "macOS Keychain (this Mac only)" : model.keySource == .localFile ? "Local key file (Keychain unavailable)" : "—")
                HStack {
                    Button("Verify All Stored Versions") { busy = true; Task { await model.verifyStore(); busy = false } }
                    Button("Apply Retention & Clean Up") { busy = true; Task { await model.runMaintenance(); busy = false } }
                    if busy { ProgressView().controlSize(.small) }
                }
                .disabled(busy)
            }
            Section("Privacy") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No network access: the app is sandboxed without network entitlements.", systemImage: "network.slash")
                    Label("Files are treated as opaque bytes: never parsed, indexed, previewed or analyzed.", systemImage: "eye.slash")
                    Label("No telemetry, analytics, crash reporting or automatic updates.", systemImage: "chart.bar.xaxis")
                    Label("Access is limited to folders you select.", systemImage: "folder.badge.person.crop")
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
