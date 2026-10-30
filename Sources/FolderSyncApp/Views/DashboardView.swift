import FolderSyncCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.pairs.isEmpty {
            VStack(spacing: 16) {
                EmptyStateView(title: "No folder pairs", symbol: "folder.badge.plus",
                               message: "Create a pair to keep a one-way synchronized, versioned copy of a folder.")
                Button("Add Folder Pair…") {
                    model.section = .pairs
                    NotificationCenter.default.post(name: .newPairRequested, object: nil)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summary
                    ForEach(model.pairs) { PairCard(pair: $0) }
                }
                .padding(24)
            }
        }
    }

    var summary: some View {
        let syncing = model.pairs.filter { model.state($0.id) == .syncing }.count
        let archived = model.stats.values.reduce(0) { $0 + $1.archivedFiles }
        let pending = model.previews.values.reduce(0) { $0 + $1.pendingChangeCount }
        return HStack(spacing: 12) {
            MetricTile(title: "Folder pairs", value: "\(model.pairs.count)", symbol: "folder.badge.gearshape")
            MetricTile(title: "Active jobs", value: "\(syncing)", symbol: "arrow.triangle.2.circlepath", tint: syncing > 0 ? .accentColor : .secondary)
            MetricTile(title: "Pending changes", value: "\(pending)", symbol: "list.bullet.indent", tint: pending > 0 ? Palette.modified : .secondary)
            MetricTile(title: "Archived files", value: "\(archived)", symbol: "archivebox", tint: Palette.archived)
            MetricTile(title: "Version store", value: Format.size(model.storeSize), symbol: "internaldrive")
        }
    }
}

struct MetricTile: View {
    var title: String
    var value: String
    var symbol: String
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(tint == .secondary ? .primary : tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct PairCard: View {
    @EnvironmentObject var model: AppModel
    var pair: FolderPair

    var body: some View {
        let state = model.state(pair.id)
        let stats = model.stats[pair.id]
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: state.symbol).foregroundStyle(state.color).symbolEffect(.pulse, isActive: state == .syncing)
                Text(pair.name).font(.title3.weight(.semibold))
                Badge(text: state.label, color: state.color)
                Spacer()
                Button(pair.paused ? "Resume" : "Pause") { model.setPaused(pair.id, !pair.paused) }
                Button("Synchronize Now") { Task { await model.sync(pair.id) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(state == .syncing)
            }

            HStack(alignment: .center, spacing: 10) {
                FolderBox(title: "Source", path: pair.sourcePath, symbol: "folder", tint: Palette.sourceLane)
                Image(systemName: "arrow.right").font(.title3).foregroundStyle(.secondary)
                    .accessibilityLabel("synchronizes one way to")
                FolderBox(title: "Destination", path: pair.destinationPath, symbol: "folder.fill", tint: Palette.destinationLane)
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("Last successful sync").foregroundStyle(.secondary)
                    Text(Format.relative(stats?.lastSuccess))
                    Text("Deletion policy").foregroundStyle(.secondary)
                    Text(pair.effectiveDeletionPolicy.title)
                }
                GridRow {
                    Text("Tracked files").foregroundStyle(.secondary)
                    Text("\(stats?.trackedFiles ?? 0) · \(Format.size(stats?.trackedBytes))")
                    Text("Archived files").foregroundStyle(.secondary)
                    Text("\(stats?.archivedFiles ?? 0)")
                }
                GridRow {
                    Text("Pending changes").foregroundStyle(.secondary)
                    Text(model.previews[pair.id].map { "\($0.pendingChangeCount)" } ?? "—")
                    Text("Monitoring").foregroundStyle(.secondary)
                    Text(pair.paused ? "Paused" : pair.autoSync ? "Automatic · every \(pair.intervalMinutes) min + on change" : "Manual")
                }
            }
            .font(.callout)

            if case let .unavailable(message) = state {
                HStack {
                    Label(message, systemImage: "externaldrive.badge.xmark").foregroundStyle(.secondary)
                    Spacer()
                    if message.contains("different folder") {
                        Button("This Is the Right Folder") { model.reconfirmIdentity(pair.id) }
                    }
                }
                .font(.callout)
            }
            if let block = model.lastReports[pair.id]?.deletionBlock {
                DeletionBlockBanner(pair: pair, block: block)
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .task { if model.previews[pair.id] == nil { await model.refreshPreview(pair.id) } }
    }
}

struct FolderBox: View {
    var title: String
    var path: String
    var symbol: String
    var tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text((path as NSString).lastPathComponent).fontWeight(.medium)
                Text((path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .help(path)
    }
}

struct DeletionBlockBanner: View {
    @EnvironmentObject var model: AppModel
    var pair: FolderPair
    var block: DeletionBlock
    @ViewState private var confirming = false

    var body: some View {
        HStack {
            Label(block.message, systemImage: "exclamationmark.shield.fill").foregroundStyle(Palette.failed)
            Spacer()
            Button("Review Changes") { model.section = .changes; model.selectedPairID = pair.id }
            Button("Apply Deletions…") { confirming = true }
        }
        .padding(10)
        .background(Palette.failed.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog("Apply the held deletions for \(pair.name)?", isPresented: $confirming) {
            Button("Apply Deletions (\(pair.effectiveDeletionPolicy.title))", role: .destructive) {
                Task { await model.sync(pair.id, allowMassDeletion: true) }
            }
        } message: {
            Text("Make sure the source folder is the correct, fully available folder. Deleted destination files are handled by the pair's deletion policy and their content stays in the version history.")
        }
    }
}
