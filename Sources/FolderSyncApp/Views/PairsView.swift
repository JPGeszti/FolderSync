import AppKit
import FolderSyncCore
import SwiftUI
import UniformTypeIdentifiers

struct PairsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var editing: FolderPair?
    @ViewState private var creating = false
    @ViewState private var confirmRemove: FolderPair?

    var body: some View {
        VStack(spacing: 0) {
            if model.pairs.isEmpty {
                EmptyStateView(title: "No folder pairs", symbol: "folder.badge.plus", message: "Drag two folders onto the new-pair sheet, or choose them with the file picker.")
            } else {
                List(selection: Binding(get: { model.selectedPair?.id }, set: { model.selectedPairID = $0 })) {
                    ForEach(model.pairs) { pair in
                        HStack(spacing: 12) {
                            Image(systemName: "folder.badge.gearshape").font(.title2).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pair.name).font(.headline)
                                Text("\((pair.sourcePath as NSString).abbreviatingWithTildeInPath)  →  \((pair.destinationPath as NSString).abbreviatingWithTildeInPath)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                HStack(spacing: 6) {
                                    Badge(text: pair.effectiveDeletionPolicy.title, color: pair.effectiveDeletionPolicy == .permanentDelete ? Palette.deleted : Palette.archived)
                                    Badge(text: pair.versioningMode.title, color: .secondary)
                                    Badge(text: pair.retentionDays == 0 ? "Keep history forever" : "\(pair.retentionDays)-day history", color: .secondary)
                                    if pair.paused { Badge(text: "Paused", color: .secondary, symbol: "pause.fill") }
                                }
                            }
                            Spacer()
                            Button("Edit…") { editing = pair }
                        }
                        .padding(.vertical, 6)
                        .tag(pair.id)
                        .contextMenu {
                            Button("Edit…") { editing = pair }
                            Button(pair.paused ? "Resume" : "Pause") { model.setPaused(pair.id, !pair.paused) }
                            Divider()
                            Button("Remove Pair…", role: .destructive) { confirmRemove = pair }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { creating = true } label: { Label("Add Folder Pair", systemImage: "plus") }
                    .help("Add a folder pair (⌘N)")
            }
        }
        .sheet(isPresented: $creating) { PairEditorView(existing: nil) }
        .sheet(item: $editing) { PairEditorView(existing: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .newPairRequested)) { _ in creating = true }
        .confirmationDialog("Remove “\(confirmRemove?.name ?? "")”?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove Pair and Its History", role: .destructive) {
                if let p = confirmRemove { model.removePair(p.id) }
            }
        } message: {
            Text("Files in the source and destination folders are not touched. Version history recorded for this pair is removed; unreferenced stored versions are cleaned up by the next maintenance run.")
        }
    }
}

struct PairEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let existing: FolderPair?

    @ViewState private var draft: FolderPair
    @ViewState private var sourceURL: URL?
    @ViewState private var destinationURL: URL?
    @ViewState private var warnPermanent = false
    @ViewState private var error: String?
    @ViewState private var excludesText: String

    init(existing: FolderPair?) {
        self.existing = existing
        let d = existing ?? FolderPair(name: "", sourcePath: "", destinationPath: "")
        _draft = State(initialValue: d)
        _excludesText = State(initialValue: d.excludePatterns.joined(separator: "\n"))
    }

    var sourcePath: String { sourceURL?.path ?? draft.sourcePath }
    var destinationPath: String { destinationURL?.path ?? draft.destinationPath }

    var layoutProblem: String? {
        guard !sourcePath.isEmpty, !destinationPath.isEmpty else { return nil }
        return model.validate(source: URL(fileURLWithPath: sourcePath), destination: URL(fileURLWithPath: destinationPath))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. Contracts backup"))
                    HStack(spacing: 12) {
                        FolderDropZone(title: "Source (read only)", path: sourcePath, tint: Palette.sourceLane) { url in
                            sourceURL = url
                            if draft.name.isEmpty { draft.name = url.lastPathComponent }
                        }
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        FolderDropZone(title: "Destination", path: destinationPath, tint: Palette.destinationLane) { destinationURL = $0 }
                    }
                    if let layoutProblem {
                        Label(layoutProblem, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.deleted).font(.callout)
                    }
                } footer: {
                    Text("Synchronization is one-way. FolderSync never modifies the source folder.").font(.caption).foregroundStyle(.secondary)
                }

                Section("When a file is deleted in the source") {
                    Picker("Deletion policy", selection: Binding(get: { draft.deletionPolicy }, set: { newValue in
                        if newValue == .permanentDelete && !draft.permanentDeletionConfirmed {
                            warnPermanent = true
                        } else {
                            draft.deletionPolicy = newValue
                        }
                    })) {
                        ForEach(DeletionPolicy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    Text(policyExplanation).font(.caption).foregroundStyle(.secondary)
                    Stepper("Hold deletions above \(draft.massDeletionThresholdCount) files", value: $draft.massDeletionThresholdCount, in: 1...100_000, step: 10)
                    Stepper("…or above \(Int(draft.massDeletionThresholdPercent))% of tracked files", value: $draft.massDeletionThresholdPercent, in: 5...100, step: 5)
                }

                Section("Version history") {
                    Picker("Keep", selection: $draft.versioningMode) {
                        ForEach(VersioningMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Retention", selection: $draft.retentionDays) {
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                        Text("Forever").tag(0)
                    }
                    Text("Stored versions are encrypted (AES-256-GCM) in FolderSync's private storage, outside both folders.").font(.caption).foregroundStyle(.secondary)
                }

                Section("Schedule") {
                    Toggle("Synchronize automatically when the source changes", isOn: $draft.autoSync)
                    Stepper("Full reconciliation every \(draft.intervalMinutes) minutes", value: $draft.intervalMinutes, in: 1...1440, step: 5)
                        .disabled(!draft.autoSync)
                }

                Section("Excluded names") {
                    TextEditor(text: $excludesText)
                        .font(.system(.callout, design: .monospaced))
                        .frame(height: 90)
                    Text("One pattern per line, matched against each file or folder name (* and ? wildcards).").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.deleted).padding(.horizontal)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create Pair" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.isEmpty || sourcePath.isEmpty || destinationPath.isEmpty || layoutProblem != nil)
            }
            .padding()
        }
        .frame(width: 620, height: 720)
        .alert("Enable permanent deletion?", isPresented: $warnPermanent) {
            Button("Cancel", role: .cancel) {}
            Button("Enable Permanent Deletion", role: .destructive) {
                draft.permanentDeletionConfirmed = true
                draft.deletionPolicy = .permanentDelete
            }
        } message: {
            Text("When a file is deleted in the source, its destination copy will be deleted immediately, without using the Trash. A copy is kept in FolderSync's version history only until the retention period ends. Mass deletions are still held for confirmation.")
        }
    }

    var policyExplanation: String {
        switch draft.deletionPolicy {
        case .preserveRename: return "The destination copy is kept and renamed, e.g. report.xlsx → report_DELETED.xlsx. Archived files are listed under Archived Files."
        case .moveToTrash: return "The destination copy is moved to the macOS Trash."
        case .permanentDelete: return "The destination copy is deleted immediately. Use with care."
        }
    }

    func save() {
        draft.excludePatterns = excludesText.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if draft.deletionPolicy != .permanentDelete { draft.permanentDeletionConfirmed = false }
        do {
            try model.savePair(draft, sourceURL: sourceURL, destinationURL: destinationURL)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// Accepts a folder by drag and drop or the native open panel.
struct FolderDropZone: View {
    var title: String
    var path: String
    var tint: Color
    var onSelect: (URL) -> Void
    @ViewState private var targeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: path.isEmpty ? "folder.badge.plus" : "folder.fill").font(.largeTitle).foregroundStyle(tint)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(path.isEmpty ? "Drop a folder here" : (path as NSString).lastPathComponent)
                .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            Button("Choose…") { choose() }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(targeted ? 0.18 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(targeted ? 0.8 : 0.3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .help(path)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            onSelect(url)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drop a folder or choose one")
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { onSelect(url) }
    }
}
