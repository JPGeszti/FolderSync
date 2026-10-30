import AppKit
import FolderSyncCore
import SwiftUI

/// Runs restore/export operations with folder access and reports results through the model.
@MainActor
enum RestoreActions {
    static func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = "Choose where FolderSync should write the restored copy. Existing files are never overwritten."
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func run(_ model: AppModel, _ label: String, _ work: @escaping @Sendable () throws -> String) {
        Task.detached(priority: .userInitiated) {
            let message: String
            do { message = try work() } catch { message = "\(label) failed: \(error)" }
            await MainActor.run {
                model.alert = message
                model.reload()
            }
        }
    }

    static func exportVersion(_ model: AppModel, hash: String, name: String, mtimeNs: Int64?) {
        guard let storage = model.storage, let dir = chooseFolder(prompt: "Export") else { return }
        run(model, "Export") {
            let path = try Restorer(storage: storage).exportVersion(hash: hash, fileName: name, mtimeNs: mtimeNs, to: dir.path)
            return "Exported to \(path)"
        }
    }

    static func restoreBeside(_ model: AppModel, pair: FolderPair, path: String, hash: String, mtimeNs: Int64?) {
        guard let storage = model.storage else { return }
        run(model, "Restore") {
            try BookmarkAccess().withAccess(to: pair) { _, dst in
                let out = try Restorer(storage: storage).restoreBeside(pair: pair, destination: dst, path: path, hash: hash, mtimeNs: mtimeNs)
                return "Restored as \((out as NSString).lastPathComponent) in the destination. The current file was not changed."
            }
        }
    }

    static func restoreIntoSource(_ model: AppModel, pair: FolderPair, path: String, hash: String, mtimeNs: Int64?) {
        guard let storage = model.storage else { return }
        let auth = SourceWriteAuthorization.grantAfterExplicitUserConfirmation(pairID: pair.id)
        run(model, "Restore into source") {
            try BookmarkAccess().withAccess(to: pair) { src, _ in
                let out = try Restorer(storage: storage).restoreIntoSource(auth, pair: pair, source: src, path: path, hash: hash, mtimeNs: mtimeNs)
                return "Wrote \((out as NSString).lastPathComponent) into the source folder. No existing file was overwritten."
            }
        }
    }
}

struct CommitDetailView: View {
    @EnvironmentObject var model: AppModel
    var pair: FolderPair
    var commit: Commit
    var compareSeq: Int64?
    var onCompare: () -> Void
    var onJump: (Int64) -> Void

    @ViewState private var changes: [FileChange] = []
    @ViewState private var search = ""
    @ViewState private var selection: Set<FileChange.ID> = []
    @ViewState private var fileHistoryPath: String?
    @ViewState private var confirmRestore = false

    var filtered: [FileChange] {
        search.isEmpty ? changes : changes.filter { $0.path.localizedCaseInsensitiveContains(search) || ($0.oldPath ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    countsGrid
                    actions
                }
                .padding(16)
            }
            .frame(maxHeight: 360)
            Divider()
            HStack {
                Text("File changes").font(.headline)
                Text("\(changes.count)").foregroundStyle(.secondary)
                Spacer()
                TextField("Filter paths", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            changeTable
        }
        .task(id: commit.seq) { changes = (try? model.catalog?.changes(commitSeq: commit.seq)) ?? [] }
        .sheet(item: Binding(get: { fileHistoryPath.map { IdentifiedPath(path: $0) } }, set: { fileHistoryPath = $0?.path })) {
            FileHistoryView(pair: pair, path: $0.path)
        }
        .confirmationDialog("Restore the destination to commit \(commit.shortID)?", isPresented: $confirmRestore) {
            Button("Restore Destination and Pause Syncing", role: .destructive) { restoreDestination() }
        } message: {
            Text("The destination will be rewritten to match this snapshot. Every file that is replaced or removed is kept in the version history first. The source is not touched. Automatic synchronization of this pair is paused so the restored state is not immediately replaced.")
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(commit.kind == .restore ? "Restore" : "Synchronization").font(.title3.weight(.semibold))
                Badge(text: commit.status.label, color: commit.status.color)
                Spacer()
                Text("#\(commit.seq)").foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 6) {
                Text(commit.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.id, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy commit ID")
            }
            if let parent = commit.parentID {
                Text("Parent \(String(parent.prefix(10)))").font(.caption).foregroundStyle(.secondary)
            }
            if let from = commit.restoredFromSeq {
                Button("Restored from snapshot #\(from)") { onJump(from) }.buttonStyle(.link)
            }
            if let m = commit.message, commit.kind != .restore { Text(m).font(.callout).foregroundStyle(.secondary) }
        }
    }

    var countsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("Started").foregroundStyle(.secondary); Text(Format.date(commit.startedAt))
            }
            GridRow {
                Text("Finished").foregroundStyle(.secondary); Text(Format.date(commit.finishedAt))
            }
            GridRow {
                Text("Added").foregroundStyle(.secondary); Text("\(commit.added)").foregroundStyle(Palette.added)
            }
            GridRow {
                Text("Modified").foregroundStyle(.secondary); Text("\(commit.modified)").foregroundStyle(Palette.modified)
            }
            GridRow {
                Text("Deleted / archived").foregroundStyle(.secondary); Text("\(commit.deleted) / \(commit.archived)").foregroundStyle(Palette.deleted)
            }
            GridRow {
                Text("Renamed").foregroundStyle(.secondary); Text("\(commit.renamed)").foregroundStyle(Palette.renamed)
            }
            if commit.restored > 0 {
                GridRow { Text("Restored").foregroundStyle(.secondary); Text("\(commit.restored)").foregroundStyle(Palette.restored) }
            }
            GridRow {
                Text("Failed").foregroundStyle(.secondary); Text("\(commit.failed)").foregroundStyle(commit.failed > 0 ? Palette.failed : .primary)
            }
            GridRow {
                Text("Bytes transferred").foregroundStyle(.secondary); Text(Format.size(commit.bytesTransferred))
            }
        }
        .font(.callout)
        .monospacedDigit()
    }

    var actions: some View {
        HStack {
            if let other = compareSeq, other != commit.seq {
                Button("Compare with #\(other)", action: onCompare)
            }
            Menu("Snapshot") {
                Button("Export Snapshot to Folder…") { exportSnapshot() }
                Button("Restore Destination to This Snapshot…") { confirmRestore = true }
            }
            .fixedSize()
        }
    }

    var changeTable: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Change") { c in
                HStack(spacing: 4) {
                    Image(systemName: c.status == .applied ? c.kind.symbol : "exclamationmark.triangle.fill")
                        .foregroundStyle(c.status == .applied ? Palette.color(c.kind) : Palette.failed)
                    Text(c.status == .applied ? c.kind.label : c.status.rawValue.capitalized)
                }
                .help(c.error ?? "")
            }
            .width(min: 90, ideal: 110)
            TableColumn("Path") { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.path).lineLimit(1).truncationMode(.middle)
                    if let old = c.oldPath { Text("from \(old)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if let a = c.archivePath, a != c.path { Text("kept as \(a)").font(.caption).foregroundStyle(Palette.archived).lineLimit(1) }
                    if let e = c.error, c.status != .applied { Text(e).font(.caption).foregroundStyle(Palette.failed).lineLimit(2) }
                }
                .help(c.path)
            }
            .width(min: 160, ideal: 240)
            TableColumn("Size") { c in
                Text("\(Format.size(c.oldSize)) → \(Format.size(c.newSize))").font(.caption).monospacedDigit()
            }
            .width(min: 110, ideal: 130)
            TableColumn("Modified") { c in
                Text(Format.mtime(c.newMtimeNs ?? c.oldMtimeNs)).font(.caption)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Hash (old → new)") { c in
                HStack(spacing: 2) { HashText(hash: c.oldHash); Text("→").foregroundStyle(.secondary); HashText(hash: c.newHash) }
            }
            .width(min: 170, ideal: 200)
        }
        .contextMenu(forSelectionType: FileChange.ID.self) { ids in
            if let c = changes.first(where: { ids.contains($0.id) }) {
                Button("File History…") { fileHistoryPath = c.oldPath != nil && c.kind != .renamed ? c.oldPath : c.path }
                if let h = c.newHash ?? c.oldHash {
                    Button("Export This Version…") {
                        RestoreActions.exportVersion(model, hash: h, name: (c.path as NSString).lastPathComponent, mtimeNs: c.newMtimeNs ?? c.oldMtimeNs)
                    }
                    Button("Restore Beside Destination File") {
                        RestoreActions.restoreBeside(model, pair: pair, path: c.path, hash: h, mtimeNs: c.newMtimeNs ?? c.oldMtimeNs)
                    }
                }
            }
        } primaryAction: { ids in
            if let c = changes.first(where: { ids.contains($0.id) }) { fileHistoryPath = c.path }
        }
    }

    func exportSnapshot() {
        guard let storage = model.storage, let dir = RestoreActions.chooseFolder(prompt: "Export Snapshot") else { return }
        let pair = self.pair
        let seq = commit.seq
        RestoreActions.run(model, "Snapshot export") {
            let (folder, failures) = try Restorer(storage: storage).exportSnapshot(pair: pair, seq: seq, to: dir.path)
            return failures.isEmpty ? "Snapshot exported to \(folder)" : "Snapshot exported to \(folder) with \(failures.count) file(s) unavailable (pruned by retention)."
        }
    }

    func restoreDestination() {
        guard let storage = model.storage else { return }
        model.setPaused(pair.id, true)
        let pair = self.pair
        let seq = commit.seq
        RestoreActions.run(model, "Destination restore") {
            try BookmarkAccess().withAccess(to: pair) { _, dst in
                let c = try Restorer(storage: storage).restoreDestination(pair: pair, destination: dst, toCommit: seq)
                return "Destination restored (commit \(c.shortID): \(c.restored) restored, \(c.failed) failed). Synchronization for \(pair.name) is paused; resume it to return to the current source state."
            }
        }
    }
}

struct IdentifiedPath: Identifiable {
    var path: String
    var id: String { path }
}

struct FileHistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var pair: FolderPair
    var path: String
    @ViewState private var versions: [FileVersion] = []
    @ViewState private var events: [FileChange] = []
    @ViewState private var commitDates: [Int64: Date] = [:]
    @ViewState private var sourceRestore: FileVersion?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text((path as NSString).lastPathComponent).font(.title3.weight(.semibold))
                    Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Versions").font(.headline)
            Table(versions) {
                TableColumn("From") { v in Text("#\(v.fromSeq) · \(Format.date(commitDates[v.fromSeq]))").font(.caption) }
                TableColumn("Until") { v in Text(v.toSeq.map { "#\($0) · \(Format.date(commitDates[$0]))" } ?? "Current").font(.caption) }
                TableColumn("Size") { v in Text(Format.size(v.size)).monospacedDigit() }.width(80)
                TableColumn("Modified") { v in Text(Format.mtime(v.mtimeNs)).font(.caption) }
                TableColumn("SHA-256") { v in HashText(hash: v.hash) }.width(110)
                TableColumn("Stored") { v in Image(systemName: v.isStored ? "lock.fill" : "minus").foregroundStyle(v.isStored ? Palette.added : .secondary).help(v.isStored ? "Encrypted copy in version store" : "Not stored (current file lives in the destination, or pruned)") }.width(50)
                TableColumn("") { v in
                    Menu("Restore") {
                        Button("Export to Folder…") { RestoreActions.exportVersion(model, hash: v.hash, name: (path as NSString).lastPathComponent, mtimeNs: v.mtimeNs) }
                        Button("Restore Beside Destination File") { RestoreActions.restoreBeside(model, pair: pair, path: path, hash: v.hash, mtimeNs: v.mtimeNs) }
                        Divider()
                        Button("Restore Into Source Folder…") { sourceRestore = v }
                    }
                    .disabled(!v.isStored)
                    .fixedSize()
                }
                .width(90)
            }
            .frame(minHeight: 160)
            Text("Metadata events").font(.headline)
            List(events) { e in
                HStack {
                    Image(systemName: e.kind.symbol).foregroundStyle(Palette.color(e.kind))
                    Text(e.kind.label)
                    if let old = e.oldPath, old != path { Text("from \(old)").foregroundStyle(.secondary) }
                    Spacer()
                    Text("#\(e.commitSeq)").foregroundStyle(.secondary).monospacedDigit()
                    Text("\(Format.size(e.oldSize)) → \(Format.size(e.newSize))").font(.caption).monospacedDigit()
                }
                .font(.callout)
            }
            .frame(minHeight: 120)
        }
        .padding(20)
        .frame(width: 820, height: 560)
        .task {
            versions = (try? model.catalog?.fileVersions(pair: pair.id, path: path, store: model.storage?.store)) ?? []
            events = (try? model.catalog?.changes(pair: pair.id, path: path)) ?? []
            for seq in Set(versions.flatMap { [$0.fromSeq] + ($0.toSeq.map { [$0] } ?? []) }) {
                commitDates[seq] = try? model.catalog?.commit(seq)?.startedAt
            }
        }
        .alert("Write into the SOURCE folder?", isPresented: Binding(get: { sourceRestore != nil }, set: { if !$0 { sourceRestore = nil } }), presenting: sourceRestore) { v in
            Button("Cancel", role: .cancel) {}
            Button("Write Copy Into Source", role: .destructive) {
                RestoreActions.restoreIntoSource(model, pair: pair, path: path, hash: v.hash, mtimeNs: v.mtimeNs)
            }
        } message: { _ in
            Text("This is the only operation that writes into your source folder. A new file named “…_RESTORED…” is created next to the original; nothing is overwritten. The next synchronization will copy it to the destination like any other new source file.")
        }
    }
}
