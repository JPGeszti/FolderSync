# FolderSync

A native macOS app for **one-way folder synchronization** with configurable deletion handling,
an encrypted local version history, and a Git-style visual commit graph. It is private by
construction: it makes no network connections, sends no telemetry, and never interprets file contents.

* Architecture, security model, graph semantics and data-loss mitigations: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
* Which test verifies which requirement, plus what is not yet verified: [docs/VERIFICATION.md](docs/VERIFICATION.md)

## Build & run

Requires macOS 14+ and Swift 6 (the Command Line Tools are enough; Xcode is optional).

```bash
scripts/test.sh                 # 78 automated tests on synthetic data in the temp directory
scripts/build-app.sh            # → build/FolderSync.app (sandboxed, ad-hoc signed)
cp -R build/FolderSync.app /Applications/
```

With Xcode installed you can also generate a project: `brew install xcodegen && xcodegen generate`.

### Development helpers

* `FOLDERSYNC_STORAGE_ROOT=<dir>` keeps the database and version store somewhere other than Application Support.
* `FOLDERSYNC_SEED_DEMO=<empty dir> scripts/test.sh --filter DemoSeeder` creates a synthetic demo history.
* `FOLDERSYNC_UI_SNAPSHOT_DIR=<dir>` makes an unsandboxed debug build render every section to a PNG and quit.

## Layout

```
Sources/FolderSyncCore   engine: scanner, planner, executor, recovery, encrypted object store, SQLite catalog
Sources/FolderSyncApp    SwiftUI app: dashboard, pairs, changes, commit graph, archives, activity, settings
Tests/FolderSyncCoreTests Swift Testing suites (sync, deletion policies, security, crash recovery, privacy…)
Resources/               Info.plist, entitlements (sandbox, user-selected folders, bookmarks — no network)
```

## Toolchain notes

* `scripts/test.sh` passes the Swift Testing macro plugin path explicitly. Without it, some Command Line Tools
  builds fail at random with "plugin for module 'TestingMacros' not found".
* The app uses `ViewState` (a typealias for SwiftUI's `State` property wrapper) instead of `@State`, because
  recent SDKs implement `@State` as a macro whose plugin ships only with Xcode.
