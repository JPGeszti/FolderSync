import FolderSyncCore
import SwiftUI

@main
struct FolderSyncApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("FolderSync", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1240, height: 780)
        .commands { FolderSyncCommands(model: model) }

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            Image(systemName: model.overallState == .syncing ? "arrow.triangle.2.circlepath" : "folder.badge.gearshape")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520)
                .padding()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep running in the menu bar after the window closes so monitoring continues.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched without a bundle (e.g. `swift run`) make sure we still get a Dock icon and menu.
        if Bundle.main.bundleIdentifier == nil { NSApp.setActivationPolicy(.regular) }
    }
}

struct FolderSyncCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder Pair…") {
                model.section = .pairs
                NotificationCenter.default.post(name: .newPairRequested, object: nil)
            }
            .keyboardShortcut("n")
        }
        CommandMenu("Sync") {
            Button("Synchronize Selected Pair") { model.syncSelected() }
                .keyboardShortcut("r")
                .disabled(model.selectedPair == nil)
            Button("Synchronize All") { model.syncAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Preview Changes (Dry Run)") {
                if let id = model.selectedPair?.id {
                    model.section = .changes
                    Task { await model.refreshPreview(id) }
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            if let pair = model.selectedPair {
                Button(pair.paused ? "Resume \(pair.name)" : "Pause \(pair.name)") { model.setPaused(pair.id, !pair.paused) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        CommandGroup(after: .sidebar) {
            ForEach(SidebarSection.allCases) { s in
                Button(s.title) {
                    openWindow(id: "main")
                    model.section = s
                }
                .keyboardShortcut(s.shortcut)
            }
        }
    }
}

extension Notification.Name {
    static let newPairRequested = Notification.Name("FolderSync.newPairRequested")
}
