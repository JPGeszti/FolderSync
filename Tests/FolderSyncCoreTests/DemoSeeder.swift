import Foundation
import Testing
@testable import FolderSyncCore

/// Not a test of behavior: generates a realistic synthetic history for manual UI review.
/// Runs only when FOLDERSYNC_SEED_DEMO=<empty directory> is set, e.g.
///   FOLDERSYNC_SEED_DEMO=/tmp/fs-demo scripts/test.sh --filter DemoSeeder
/// then launch the app with FOLDERSYNC_STORAGE_ROOT=/tmp/fs-demo/storage.
@Suite("Demo seeder", .enabled(if: ProcessInfo.processInfo.environment["FOLDERSYNC_SEED_DEMO"] != nil))
struct DemoSeeder {
    @Test func seedDemoHistory() throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDERSYNC_SEED_DEMO"]!)
        let src = base.appendingPathComponent("Company Documents")
        let dst = base.appendingPathComponent("Backup Drive/Company Documents")
        let root = base.appendingPathComponent("storage")
        for d in [src, dst, root] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        // The app's PreferredKeyProvider picks up this key file (no Keychain item is created).
        let key = randomData(32)
        try key.write(to: root.appendingPathComponent("store-key.bin"))
        let storage = try FolderSyncStorage(root: root, keyProvider: InMemoryKeyProvider(key: .init(data: key)), trash: DirectoryTrash(directory: base))
        var pair = FolderPair(name: "Company Documents", sourcePath: src.path, destinationPath: dst.path)
        pair.sourceIdentity = PairValidator.identity(of: src.path)
        pair.destinationIdentity = PairValidator.identity(of: dst.path)
        try storage.catalog.savePair(pair)

        func put(_ rel: String, _ bytes: Int) throws {
            let url = src.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try randomData(bytes).write(to: url)
        }
        func sync() throws { _ = try storage.engine.synchronize(pair: pair, source: src.path, destination: dst.path) }

        for q in 1...4 { try put("Finance/Q\(q) report.xlsx", 40_000 + q * 900) }
        try put("Legal/NDA template.docx", 22_000)
        try put("Legal/Contracts/Supplier agreement.pdf", 180_000)
        try put("HR/Handbook.pages", 64_000)
        try sync()
        try put("Finance/Budget 2027.numbers", 51_000)
        try put("Projects/Atlas/Roadmap.key", 900_000)
        try put("Projects/Atlas/Notes.txt", 2_000)
        try sync()
        try put("Finance/Q4 report.xlsx", 47_000)
        try put("Legal/NDA template.docx", 23_500)
        try sync()
        try FileManager.default.removeItem(at: src.appendingPathComponent("Finance/Q1 report.xlsx"))
        try sync()
        try FileManager.default.moveItem(at: src.appendingPathComponent("Projects/Atlas"), to: src.appendingPathComponent("Projects/Atlas 2027"))
        try sync()
        try put("HR/Handbook.pages", 66_000)
        try put("Projects/Atlas 2027/Budget.numbers", 30_000)
        try "edited on the backup drive".write(to: dst.appendingPathComponent("Legal/Contracts/Supplier agreement.pdf"), atomically: true, encoding: .utf8)
        try put("Legal/Contracts/Supplier agreement.pdf", 181_000)
        try sync()
        let first = try storage.catalog.commits(pair: pair.id).last!.seq
        _ = try Restorer(storage: storage).restoreBeside(pair: pair, destination: dst.path, path: "Finance/Q4 report.xlsx",
                                                         hash: try storage.catalog.snapshot(pair: pair.id, at: first).first { $0.path == "Finance/Q4 report.xlsx" }!.hash, mtimeNs: nil)
        try put("Marketing/Brand guide.pdf", 250_000)
        try put("Marketing/Logo.svg", 8_000)
        try FileManager.default.removeItem(at: src.appendingPathComponent("Projects/Atlas 2027/Notes.txt"))
        try sync()
        try put("Finance/Q2 report.xlsx", 44_000)
        #expect(try storage.catalog.commits(pair: pair.id).count >= 8)
    }
}
