// swift-tools-version:6.0
import PackageDescription

// FolderSync deliberately has NO third-party dependencies: everything used is
// part of the macOS SDK (Foundation, CryptoKit, SQLite3, CoreServices, SwiftUI).
// This keeps the dependency surface auditable and guarantees no network SDKs.
let package = Package(
    name: "FolderSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FolderSyncCore", targets: ["FolderSyncCore"]),
        .executable(name: "FolderSync", targets: ["FolderSyncApp"]),
    ],
    targets: [
        .target(
            name: "FolderSyncCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "FolderSyncApp",
            dependencies: ["FolderSyncCore"]
        ),
        .testTarget(
            name: "FolderSyncCoreTests",
            dependencies: ["FolderSyncCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
