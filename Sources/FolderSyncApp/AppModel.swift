import AppKit
import FolderSyncCore
import ServiceManagement
import SwiftUI
import UserNotifications

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, pairs, changes, history, archived, activity, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .pairs: return "Folder Pairs"
        case .changes: return "Changes"
        case .history: return "History"
        case .archived: return "Archived Files"
        case .activity: return "Activity Log"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .pairs: return "folder.badge.gearshape"
        case .changes: return "list.bullet.indent"
        case .history: return "point.3.connected.trianglepath.dotted"
        case .archived: return "archivebox"
        case .activity: return "text.alignleft"
        case .settings: return "gearshape"
        }
    }

    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String((SidebarSection.allCases.firstIndex(of: self) ?? 0) + 1)))
    }
}

enum PairState: Equatable {
    case idle
    case syncing
    case paused
    case unavailable(String)
    case needsAttention(String)
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Up to date"
        case .syncing: return "Synchronizing…"
        case .paused: return "Paused"
        case let .unavailable(m): return m
        case let .needsAttention(m): return m
        case let .error(m): return m
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "checkmark.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle.fill"
        case .unavailable: return "externaldrive.badge.xmark"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: return Palette.added
        case .syncing: return .accentColor
        case .paused: return .secondary
        case .unavailable: return .secondary
        case .needsAttention: return Palette.failed
        case .error: return Palette.deleted
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var section: SidebarSection = .dashboard
    @Published private(set) var pairs: [FolderPair] = []
    @Published var selectedPairID: UUID?
    @Published private(set) var states: [UUID: PairState] = [:]
    @Published private(set) var stats: [UUID: Catalog.PairStats] = [:]
    @Published private(set) var previews: [UUID: SyncPlan] = [:]
    @Published private(set) var lastReports: [UUID: SyncReport] = [:]
    @Published private(set) var startupError: String?
    @Published var alert: String?
    @Published private(set) var storeSize: Int64 = 0
    @Published private(set) var historyRevision = 0
    @Published var notificationsEnabled: Bool { didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notifications") } }

    let storage: FolderSyncStorage?
    let service: SyncService?
    let keySource: PreferredKeyProvider.Source?

    private var watchers: [UUID: FSEventsWatcher] = [:]
    private var watchedURLs: [UUID: URL] = [:]
    private var timers: [UUID: Timer] = [:]
    private var mountObserver: NSObjectProtocol?

    /// Notifications and login items need a real app bundle (not available under `swift run`).
    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    init() {
        notificationsEnabled = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true
        do {
            let root = FolderSyncStorage.defaultRoot
            let storeExists = FileManager.default.fileExists(atPath: root.appendingPathComponent("store/store.json").path)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Development runs (`swift run`, UI snapshots) get their own Keychain item, so they can
            // never claim the installed app's key or leave one it is not allowed to read.
            let keychain = AppModel.isBundled ? KeychainKeyProvider() : KeychainKeyProvider(service: "FolderSync Version Store (development)")
            let keys = PreferredKeyProvider(keychain: keychain, fallbackFile: root.appendingPathComponent("store-key.bin"), allowCreatingFallback: !storeExists)
            let storage = try FolderSyncStorage(root: root, keyProvider: keys)
            self.storage = storage
            keySource = keys.source
            service = SyncService(storage: storage, access: BookmarkAccess())
            if let recovery = storage.databaseRecovery {
                alert = "FolderSync's metadata database was damaged and has been recovered (\(recovery)). Your folders were not modified."
            }
        } catch {
            storage = nil
            service = nil
            keySource = nil
            if let keychain = error as? KeychainError, keychain.status == errSecUserCanceled || keychain.status == errSecAuthFailed {
                // Expected after an update of an app that is not signed by a registered developer:
                // macOS asks again whether the new version may read the existing key.
                startupError = "FolderSync needs its encryption key from your Keychain to open its version history. Quit and reopen FolderSync, and choose “Always Allow” when macOS asks. Nothing was changed in your folders."
            } else {
                startupError = "FolderSync could not open its private storage: \(error)"
            }
        }
        reload()
        selectedPairID = pairs.first?.id
        startMonitoring()
        observeMounts()
        if AppModel.isBundled, notificationsEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    var selectedPair: FolderPair? { pairs.first { $0.id == selectedPairID } ?? pairs.first }
    var catalog: Catalog? { storage?.catalog }

    func state(_ id: UUID) -> PairState { states[id] ?? .idle }

    var overallState: PairState {
        let all = pairs.map { state($0.id) }
        if all.contains(.syncing) { return .syncing }
        if let e = all.first(where: { if case .error = $0 { return true }; return false }) { return e }
        if let a = all.first(where: { if case .needsAttention = $0 { return true }; return false }) { return a }
        return .idle
    }

    // MARK: Loading

    func reload() {
        guard let catalog else { return }
        pairs = (try? catalog.pairs()) ?? []
        for p in pairs {
            stats[p.id] = try? catalog.stats(p.id)
            if p.paused, states[p.id] == nil || states[p.id] == .idle { states[p.id] = .paused }
        }
        storeSize = storage?.store.totalSize() ?? 0
        historyRevision += 1
    }

    // MARK: Pair management

    func validate(source: URL, destination: URL) -> String? {
        do {
            try PairValidator.checkLayout(source: source.path, destination: destination.path, storeRoot: storage?.root.path)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    func savePair(_ draft: FolderPair, sourceURL: URL?, destinationURL: URL?) throws {
        guard let catalog else { return }
        var pair = draft
        if let sourceURL {
            pair.sourcePath = sourceURL.path
            pair.sourceBookmark = Bookmarks.make(for: sourceURL)
            pair.sourceIdentity = PairValidator.identity(of: sourceURL.path)
        }
        if let destinationURL {
            pair.destinationPath = destinationURL.path
            pair.destinationBookmark = Bookmarks.make(for: destinationURL)
            pair.destinationIdentity = PairValidator.identity(of: destinationURL.path)
        }
        try PairValidator.checkLayout(source: pair.sourcePath, destination: pair.destinationPath, storeRoot: storage?.root.path)
        try catalog.savePair(pair)
        catalog.log(pair.id, .info, "Saved folder pair \(pair.name)")
        reload()
        selectedPairID = pair.id
        restartMonitoring(pair.id)
        Task { await refreshPreview(pair.id) }
    }

    func removePair(_ id: UUID) {
        stopMonitoring(id)
        try? catalog?.deletePair(id)
        catalog?.log(nil, .info, "Removed a folder pair (folders were not modified)")
        if selectedPairID == id { selectedPairID = nil }
        reload()
        selectedPairID = selectedPairID ?? pairs.first?.id
    }

    func setPaused(_ id: UUID, _ paused: Bool) {
        guard var pair = pairs.first(where: { $0.id == id }) else { return }
        pair.paused = paused
        try? catalog?.savePair(pair)
        states[id] = paused ? .paused : .idle
        reload()
        restartMonitoring(id)
    }

    func setAllPaused(_ paused: Bool) {
        for p in pairs { setPaused(p.id, paused) }
    }

    /// The user re-confirmed folder identity after a volume/folder swap.
    func reconfirmIdentity(_ id: UUID) {
        guard var pair = pairs.first(where: { $0.id == id }) else { return }
        let access = BookmarkAccess()
        _ = try? access.withAccess(to: pair) { src, dst in
            pair.sourceIdentity = PairValidator.identity(of: src)
            pair.destinationIdentity = PairValidator.identity(of: dst)
        }
        try? catalog?.savePair(pair)
        catalog?.log(id, .warning, "\(pair.name): folder identity re-confirmed by the user")
        states[id] = .idle
        reload()
    }

    // MARK: Synchronization

    func sync(_ id: UUID, allowMassDeletion: Bool = false) async {
        guard let service, let pair = pairs.first(where: { $0.id == id }) else { return }
        states[id] = .syncing
        do {
            let report = try await service.synchronize(pair, options: SyncOptions(allowMassDeletion: allowMassDeletion))
            lastReports[id] = report
            previews[id] = nil
            if let block = report.deletionBlock {
                states[id] = .needsAttention("Deletions held for confirmation")
                notify(pair.name, block.message)
            } else if !report.conflicts.isEmpty {
                states[id] = .needsAttention("\(report.conflicts.count) conflict(s)")
                notify(pair.name, "\(report.conflicts.count) file(s) need your attention.")
            } else if let c = report.commit, c.failed > 0 {
                states[id] = .error("\(c.failed) operation(s) failed")
                notify(pair.name, "\(c.failed) operation(s) failed during synchronization.")
            } else {
                states[id] = pair.paused ? .paused : .idle
            }
        } catch SyncError.busy {
            states[id] = .syncing
            return
        } catch let e as PairValidationError {
            let wasUnavailable: Bool = { if case .unavailable = state(id) { return true }; return false }()
            states[id] = .unavailable(e.description)
            if !wasUnavailable { notify(pair.name, e.description) }
        } catch {
            states[id] = .error(String(describing: error))
        }
        reload()
        await refreshPreview(id)
    }

    func syncSelected() {
        guard let id = selectedPair?.id else { return }
        Task { await sync(id) }
    }

    func syncAll() {
        for p in pairs where !p.paused { Task { await sync(p.id) } }
    }

    /// Dry run: computes pending changes without touching anything.
    func refreshPreview(_ id: UUID) async {
        guard let service, let pair = pairs.first(where: { $0.id == id }) else { return }
        if state(id) == .syncing { return }
        do {
            let report = try await service.synchronize(pair, options: SyncOptions(dryRun: true))
            previews[id] = report.plan
            // Keep the status honest about what the preview found.
            switch state(id) {
            case .idle, .unavailable, .needsAttention:
                if report.plan.deletionBlock != nil {
                    states[id] = .needsAttention("Deletions held for confirmation")
                } else if !report.plan.conflicts.isEmpty {
                    states[id] = .needsAttention("\(report.plan.conflicts.count) conflict(s)")
                } else {
                    states[id] = pair.paused ? .paused : .idle
                }
            default:
                break
            }
        } catch let e as PairValidationError {
            previews[id] = nil
            states[id] = .unavailable(e.description)
        } catch {
            previews[id] = nil
        }
    }

    // MARK: Monitoring (event driven + periodic reconciliation)

    private func startMonitoring() {
        for p in pairs { restartMonitoring(p.id) }
    }

    private func stopMonitoring(_ id: UUID) {
        watchers[id]?.stop()
        watchers[id] = nil
        timers[id]?.invalidate()
        timers[id] = nil
        if let url = watchedURLs.removeValue(forKey: id) { url.stopAccessingSecurityScopedResource() }
    }

    private func restartMonitoring(_ id: UUID) {
        stopMonitoring(id)
        guard let pair = pairs.first(where: { $0.id == id }), pair.autoSync, !pair.paused else { return }
        let src = Bookmarks.resolve(pair.sourceBookmark, fallbackPath: pair.sourcePath).url
        if src.startAccessingSecurityScopedResource() { watchedURLs[id] = src }
        watchers[id] = FSEventsWatcher(path: src.path, debounce: 3) { [weak self] in
            Task { @MainActor in await self?.sync(id) }
        }
        let interval = TimeInterval(max(pair.intervalMinutes, 1) * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync(id) }
        }
        timer.tolerance = interval * 0.2 // lets macOS coalesce wake-ups
        RunLoop.main.add(timer, forMode: .common)
        timers[id] = timer
    }

    private func observeMounts() {
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for p in self.pairs where !p.paused {
                    if case .unavailable = self.state(p.id) { await self.sync(p.id) }
                }
            }
        }
    }

    // MARK: Conflicts

    func resolveConflict(_ pairID: UUID, path: String, _ action: PathOverride) {
        try? catalog?.setOverride(pairID, path: path, action)
        catalog?.log(pairID, .info, "Conflict at \(path) resolved by user: \(action.rawValue)")
        Task { await refreshPreview(pairID) }
    }

    // MARK: Maintenance

    func runMaintenance() async {
        guard let service else { return }
        do {
            let r = try await service.runMaintenance()
            alert = "Retention removed \(r.pruned) old version record(s); \(r.collected) unreferenced stored object(s) deleted."
        } catch {
            alert = "Maintenance could not run now: \(error)"
        }
        reload()
    }

    func verifyStore() async {
        guard let service else { return }
        let problems = await service.verifyStore()
        alert = problems.isEmpty ? "All stored versions verified successfully." : "\(problems.count) stored version(s) failed verification. See the Activity Log."
        for (hash, p) in problems { catalog?.log(nil, .error, "Version \(hash.prefix(12)): \(p)") }
        reload()
    }

    // MARK: Notifications & login item

    func notify(_ title: String, _ body: String) {
        guard notificationsEnabled, AppModel.isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body // metadata only: names and counts, never file contents
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    var launchAtLogin: Bool {
        get { AppModel.isBundled && SMAppService.mainApp.status == .enabled }
        set {
            guard AppModel.isBundled else { return }
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                alert = "Could not change the login item: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}
