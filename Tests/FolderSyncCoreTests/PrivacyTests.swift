import Foundation
import Testing
@testable import FolderSyncCore

/// Auditable privacy guarantees: no networking, no content interpretation, no content at rest
/// outside the encrypted store.
@Suite("Privacy and network isolation")
struct PrivacyTests {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func shippedSources() throws -> [(String, String)] {
        let sources = repoRoot.appendingPathComponent("Sources")
        var out: [(String, String)] = []
        let e = try #require(FileManager.default.enumerator(atPath: sources.path))
        for case let rel as String in e where rel.hasSuffix(".swift") {
            out.append((rel, try String(contentsOf: sources.appendingPathComponent(rel), encoding: .utf8)))
        }
        return out
    }

    /// APIs that would allow network access, process execution, or content interpretation.
    static let forbidden: [String] = [
        // networking
        "URLSession", "URLRequest", "NSURLConnection", "import Network", "NWConnection", "NWListener", "NWPathMonitor",
        "CFSocket", "CFStream", "getaddrinfo", "socket(", "connect(", "WKWebView", "import WebKit", "import MultipeerConnectivity",
        "CloudKit", "CKContainer", "NSUbiquitous",
        // process / script execution
        "Process(", "NSTask", "posix_spawn", "popen(", "system(", "NSAppleScript", "OSAScript", "execv",
        // content interpretation / indexing / previews
        "import PDFKit", "import QuickLook", "QLThumbnail", "QLPreview", "import CoreSpotlight", "CSSearchableItem",
        "NSMetadataQuery", "MDItemCopy", "import Vision", "import NaturalLanguage", "NSAttributedString(url",
        "import UniformTypeIdentifiers.UTType(filenameExtension", "NSImage(contentsOf", "CGImageSourceCreate",
        // analytics / telemetry
        "Analytics", "Telemetry", "Crashlytics", "Sentry", "Firebase",
    ]

    /// Call-style tokens like `system(` must be a free function call: `.font(.system(.body))`
    /// (member access) or `filesystem(` (longer identifier) do not count.
    static func uses(_ token: String, in text: String) -> Bool {
        guard token.hasSuffix("("), token.first?.isLetter == true else { return text.contains(token) }
        let pattern = "(^|[^.\\w])" + NSRegularExpression.escapedPattern(for: token)
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    @Test func forbiddenCallDetectionIsPrecise() {
        #expect(Self.uses("system(", in: "let r = system(cmd)"))
        #expect(Self.uses("popen(", in: "x\npopen(\"ls\", \"r\")"))
        #expect(!Self.uses("system(", in: ".font(.system(.caption))"))
        #expect(!Self.uses("socket(", in: "makeSocket(1)"))
    }

    @Test func shippedCodeUsesNoNetworkExecutionOrContentInspectionAPIs() throws {
        let files = try Self.shippedSources()
        #expect(files.count > 10)
        var violations: [String] = []
        for (name, text) in files {
            for token in Self.forbidden where Self.uses(token, in: text) {
                violations.append("\(name): \(token)")
            }
        }
        #expect(violations.isEmpty, "Forbidden API usage: \(violations)")
    }

    @Test func packageHasNoThirdPartyDependencies() throws {
        let manifest = try String(contentsOf: Self.repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!manifest.contains(".package("))
    }

    @Test func entitlementsAreSandboxedWithoutNetwork() throws {
        let url = Self.repoRoot.appendingPathComponent("Resources/FolderSync.entitlements")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(plist["com.apple.security.files.user-selected.read-write"] as? Bool == true)
        #expect(plist["com.apple.security.files.bookmarks.app-scope"] as? Bool == true)
        for key in plist.keys {
            #expect(!key.contains("network"), "unexpected entitlement \(key)")
            #expect(!key.contains("temporary-exception"), "unexpected entitlement \(key)")
            #expect(!key.contains("all-files") && !key.contains("downloads"), "unexpected entitlement \(key)")
        }
    }

    @Test func metadataDatabaseNeverContainsFileContents() throws {
        let f = try Fixture()
        let marker = "TOP-SECRET-CONTENT-\(UUID().uuidString)"
        try f.write("secret.txt", marker)
        try f.write("nested/also-secret.bin", Data((marker + marker).utf8))
        try f.sync()
        try f.write("secret.txt", marker + " v2")
        try f.sync()
        try f.storage.backupDatabase()

        var scanned = 0
        if let e = FileManager.default.enumerator(atPath: f.appRoot.path) {
            for case let rel as String in e {
                let url = f.appRoot.appendingPathComponent(rel)
                guard (try? lstatPath(url.path))??.isRegularFile == true, let data = try? Data(contentsOf: url) else { continue }
                scanned += 1
                #expect(data.range(of: Data(marker.utf8)) == nil, "plaintext content found in \(rel)")
            }
        }
        #expect(scanned >= 4) // db, wal/backup, store.json, objects…
        // Activity log contains metadata only.
        for entry in try f.catalog.activity() { #expect(!entry.message.contains(marker)) }
    }

    @Test func synchronizationOpensNoNetworkSockets() throws {
        let f = try Fixture()
        for i in 0..<20 { try f.write("f\(i).txt", "data \(i)") }
        try f.sync()
        // lsof lists Internet sockets owned by this test process. The test runner itself is
        // not expected to hold any, so any socket would have to come from the engine.
        let lsof = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: lsof) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: lsof)
        p.arguments = ["-a", "-i", "-n", "-P", "-p", String(getpid())]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "open sockets: \(output)")
    }
}
