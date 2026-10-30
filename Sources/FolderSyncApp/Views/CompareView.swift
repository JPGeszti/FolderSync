import FolderSyncCore
import SwiftUI

/// Metadata-only comparison of two destination snapshots (paths, sizes, timestamps, hashes).
/// No file contents are read, parsed or displayed.
struct CompareView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var pair: FolderPair
    @ViewState var from: Int64
    @ViewState var to: Int64
    var commits: [Commit]
    @ViewState private var diffs: [SnapshotDiff] = []
    @ViewState private var showUnchanged = false
    @ViewState private var search = ""

    var shown: [SnapshotDiff] {
        diffs.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare Snapshots").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack {
                picker("Older", $from)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                picker("Newer", $to)
                Spacer()
                Toggle("Show unchanged", isOn: $showUnchanged).toggleStyle(.checkbox)
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            HStack(spacing: 10) {
                summary(.added, Palette.added)
                summary(.removed, Palette.deleted)
                summary(.modified, Palette.modified)
                if showUnchanged { summary(.unchanged, .secondary) }
                Spacer()
                Text("Comparison uses metadata and hashes only.").font(.caption).foregroundStyle(.secondary)
            }
            Table(shown) {
                TableColumn("Status") { d in Badge(text: d.kind.rawValue.capitalized, color: color(d.kind)) }.width(90)
                TableColumn("Path") { d in Text(d.path).lineLimit(1).truncationMode(.middle).help(d.path) }
                TableColumn("Size") { d in Text("\(Format.size(d.before?.size)) → \(Format.size(d.after?.size))").font(.caption).monospacedDigit() }.width(140)
                TableColumn("Modified") { d in Text("\(Format.mtime(d.before?.mtimeNs)) → \(Format.mtime(d.after?.mtimeNs))").font(.caption) }.width(min: 160, ideal: 260)
                TableColumn("Hash") { d in HStack(spacing: 2) { HashText(hash: d.before?.hash); Text("→").foregroundStyle(.secondary); HashText(hash: d.after?.hash) } }.width(200)
            }
        }
        .padding(20)
        .frame(width: 960, height: 600)
        .task(id: "\(from)-\(to)-\(showUnchanged)") {
            diffs = (try? model.catalog?.compare(pair: pair.id, from: min(from, to), to: max(from, to), includeUnchanged: showUnchanged)) ?? []
        }
    }

    func picker(_ title: String, _ binding: Binding<Int64>) -> some View {
        Picker(title, selection: binding) {
            ForEach(commits) { c in Text("#\(c.seq) · \(c.shortID) · \(c.startedAt.formatted(date: .abbreviated, time: .shortened))").tag(c.seq) }
        }
        .frame(maxWidth: 300)
    }

    func summary(_ kind: SnapshotDiffKind, _ color: Color) -> some View {
        Badge(text: "\(diffs.filter { $0.kind == kind }.count) \(kind.rawValue)", color: color)
    }

    func color(_ k: SnapshotDiffKind) -> Color {
        switch k {
        case .added: return Palette.added
        case .removed: return Palette.deleted
        case .modified: return Palette.modified
        case .unchanged: return .secondary
        }
    }
}
