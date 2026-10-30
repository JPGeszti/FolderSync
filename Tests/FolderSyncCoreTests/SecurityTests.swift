import Foundation
import Testing
@testable import FolderSyncCore

@Suite("Path and symlink safety")
struct SecurityTests {
    @Test func relativePathRejectsTraversal() {
        for bad in ["", "/etc/passwd", "../x", "a/../../b", "a/./b", "a//b", "a/", ".", "..", "a\u{0}b", String(repeating: "x", count: 256)] {
            #expect(throws: FSError.self, "\(bad.debugDescription) must be rejected") { try RelativePath(validating: bad) }
        }
        #expect((try? RelativePath(validating: "Docs/Q3 report (final).xlsx"))?.components.count == 2)
        #expect((try? RelativePath(validating: "..hidden/...dots"))?.components == ["..hidden", "...dots"])
    }

    @Test func archiveNamesPreserveExtensionAndStayUnique() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let names = Array(NameGenerator.candidates(for: "financial_report.xlsx", marker: "DELETED", date: date).prefix(3))
        #expect(names[0] == "financial_report_DELETED.xlsx")
        #expect(names[1].hasPrefix("financial_report_DELETED_") && names[1].hasSuffix(".xlsx"))
        #expect(Set(names).count == 3)
        #expect(NameGenerator.candidates(for: ".bashrc", marker: "DELETED", date: date).next() == ".bashrc_DELETED")
        #expect(NameGenerator.candidates(for: "archive.tar.gz", marker: "DELETED", date: date).next() == "archive.tar_DELETED.gz")
        let long = String(repeating: "n", count: 250) + ".pdf"
        #expect(NameGenerator.candidates(for: long, marker: "DELETED", date: date).next()!.utf8.count <= 255)
    }

    @Test func sourceSymlinksAreNeverFollowed() throws {
        let f = try Fixture()
        let outside = f.base.appendingPathComponent("outside-secret")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try f.write("secret.txt", "must not leave its folder", in: outside)
        try FileManager.default.createSymbolicLink(at: f.src.appendingPathComponent("link-to-file"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: f.src.appendingPathComponent("link-to-dir"), withDestinationURL: outside)
        try f.write("normal.txt", "ok")

        let report = try f.sync()
        #expect(Set(report.plan.skipped.map(\.path)) == ["link-to-file", "link-to-dir"])
        #expect(report.plan.skipped.allSatisfy { $0.reason == .symbolicLink })
        #expect(f.tree(f.dst) == ["normal.txt": sha256Hex("ok")])
    }

    @Test func fileSwappedForSymlinkAfterScanIsRefused() throws {
        let f = try Fixture()
        let outside = try f.write("outside.txt", "outside data", in: f.base)
        try f.write("victim.txt", "inside data")
        f.engine.faultInjector = nil
        // Plan sees a regular file; before copying, an attacker swaps it for a symlink.
        let reader = SourceReader(rootPath: f.src.path, excludePatterns: [])
        let scan = try reader.scan()
        let st = try #require(scan.files[try RelativePath(validating: "victim.txt")])
        try f.remove("victim.txt")
        try FileManager.default.createSymbolicLink(at: f.src.appendingPathComponent("victim.txt"), withDestinationURL: outside)
        #expect(throws: FSError.self) { _ = try reader.openFile(try RelativePath(validating: "victim.txt"), expected: st) }
    }

    @Test func destinationDirectoryReplacedBySymlinkIsNotWrittenThrough() throws {
        let f = try Fixture()
        try f.write("sub/a.txt", "alpha")
        try f.sync()
        // Attacker replaces destination/sub with a symlink pointing somewhere else.
        let elsewhere = f.base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: f.dst.appendingPathComponent("sub"))
        try FileManager.default.createSymbolicLink(at: f.dst.appendingPathComponent("sub"), withDestinationURL: elsewhere)
        try f.write("sub/b.txt", "beta")
        try f.write("sub/a.txt", "alpha modified")

        _ = try? f.sync()
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func symlinkedDestinationFileIsTreatedAsConflictNotOverwritten() throws {
        let f = try Fixture()
        let target = try f.write("target.txt", "do not overwrite", in: f.base)
        try f.write("a.txt", "alpha")
        try FileManager.default.createSymbolicLink(at: f.dst.appendingPathComponent("a.txt"), withDestinationURL: target)
        let report = try f.sync()
        #expect(report.conflicts.first?.kind == .destinationTypeChanged)
        #expect(try String(contentsOf: target, encoding: .utf8) == "do not overwrite")
    }

    @Test func mountedVolumeBoundaryAndSpecialFilesAreSkipped() throws {
        let f = try Fixture()
        let fifo = f.src.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        try f.write("a.txt", "alpha")
        let report = try f.sync()
        #expect(report.plan.skipped.contains { $0.path == "pipe" && $0.reason == .specialFile })
        #expect(!f.exists("pipe"))
    }

    @Test func storeFilesAreOwnerOnly() throws {
        let f = try Fixture()
        try f.write("a.txt", "alpha")
        try f.sync()
        let dbMode = try #require(try lstatPath(f.appRoot.appendingPathComponent("foldersync.sqlite").path)).permissionBits
        #expect(dbMode == 0o600)
        let storeMode = try #require(try lstatPath(f.storage.store.root.path)).permissionBits
        #expect(storeMode == 0o700)
        let objMode = try #require(try lstatPath(f.storage.store.objectPath(sha256Hex("alpha")))).permissionBits
        #expect(objMode == 0o400)
    }
}
