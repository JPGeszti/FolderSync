import AppKit
import SwiftUI

/// Development aid for reviewing the UI without screen-recording permission: when
/// `FOLDERSYNC_UI_SNAPSHOT_DIR` is set, each sidebar section is rendered from the app's own window
/// into a PNG in that directory, then the app quits. Never active in normal use.
@MainActor
enum UISnapshots {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["FOLDERSYNC_UI_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(model: AppModel) async {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for section in SidebarSection.allCases {
            model.section = section
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            capture(name: section.rawValue, dir: dir)
        }
        NSApp.terminate(nil)
    }

    static func capture(name: String, dir: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
