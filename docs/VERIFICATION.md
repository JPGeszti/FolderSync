# Verification matrix

Every claim below is backed by an automated test in `Tests/FolderSyncCoreTests` unless it is
explicitly marked **manual** or **unverified**. Run everything with `scripts/test.sh`.

All tests use synthetic data in fresh folders under the system temporary directory. The fixture
refuses to run outside it (`Fixture.init` precondition), and "Move to Trash" is redirected to a
fixture folder, so the real Trash is never touched.

Last run: 78 tests in 11 suites, all passing (Swift 6.4, macOS 27.0.1, Apple Silicon, Command Line Tools only).

| Requirement | Test(s) |
|---|---|
| One-way sync; source never modified (full metadata + content fingerprint) | `initialSyncCopiesTreeAndNeverTouchesSource`, `restoreDestinationToEarlierSnapshotAndBack` |
| Additions / modifications, previous version kept | `modificationUpdatesDestinationAndKeepsPreviousVersion`, `replacedOnlyVersioningStoresOldVersionBeforeOverwrite` |
| No repeated hashing of unchanged files; no empty commits | `secondSyncWithoutChangesCreatesNoCommitAndHashesNothing`, `touchedButIdenticalFileIsNotRewritten` |
| Large files, streaming, multi-chunk store | `largeFileIsStreamedAndVerified`, `roundTrip(size:)` |
| Renames / folder renames (no re-copy) | `renameIsDetectedAndAppliedWithoutCopying`, `folderRenameMovesAllFilesAndRemovesOldFolder` |
| Policy A (preserve & rename), extension kept, not mistaken for source | `preserveRenameKeepsExtensionAndIsNotTreatedAsSource`, `archiveNamesPreserveExtensionAndStayUnique` |
| Repeated deletion & recreation, filename collisions | `repeatedDeletionAndRecreationCreatesUniqueArchives`, `newSourceFileWithArchiveNameRelocatesArchive` |
| Policy B (Trash) | `moveToTrashUsesTrashHandler` (injected trash handler; real `FileManager.trashItem` path is **manual**) |
| Policy C requires confirmation; content kept in history | `permanentDeletionRequiresExplicitConfirmation`, `permanentDeletionWhenConfirmedKeepsVersionInStore` |
| Mass-deletion threshold | `massDeletionIsBlockedUntilConfirmed` |
| Unavailable / replaced source never causes deletion | `unavailableSourceDeletesNothing`, `replacedSourceFolderIsDetectedAsDifferentIdentity`, `emptySourceNeverTriggersDeletion` |
| Offline destination | `unavailableDestinationIsReported` |
| Unowned destination files never deleted/overwritten | `untrackedDestinationFilesAreNeverDeleted`, `unknownFileAtDestinationPathIsConflictUnlessIdentical` |
| Unexpected destination changes → conflicts, explicit resolution | `externallyModifiedDestinationBecomesConflict`, `modifiedDestinationIsNotDeleted`, `ignoredPathIsLeftAlone` |
| Case-insensitive collisions | `caseCollisionsAreReportedForCaseInsensitiveDestination` |
| Overlap / nesting / aliases / store inside folder | `nestedOrIdenticalFoldersAreRejected` |
| Permission failures | `permissionFailureIsRecordedAndOtherFilesStillSync`, `readOnlyDestinationFolderFailsSafely` |
| Source changing during copy; concurrent changes | `sourceChangingDuringCopyIsDiscardedAndRetried`, `concurrentSourceChangesConverge` |
| No concurrent operations on one pair | `concurrentRunsOnSamePairAreRejected`, `serviceRejectsOverlappingRunsAndMaintenanceDuringSync` |
| Symlink attacks (source and destination), path traversal, special files | `sourceSymlinksAreNeverFollowed`, `fileSwappedForSymlinkAfterScanIsRefused`, `destinationDirectoryReplacedBySymlinkIsNotWrittenThrough`, `symlinkedDestinationFileIsTreatedAsConflictNotOverwritten`, `relativePathRejectsTraversal`, `mountedVolumeBoundaryAndSpecialFilesAreSkipped` |
| Interrupted sync / crash recovery (roll back and roll forward) | `crashBeforePublishRollsBack`, `crashAfterPublishBeforeBookkeepingRollsForward`, `crashBeforeArchiveLeavesFileAndRetries` |
| Snapshot integrity: encryption, tamper / truncation / substitution / wrong key | `ObjectStoreTests` suite |
| History tamper evidence (hash chain) | `tamperedHistoryIsDetected` |
| Snapshots, metadata-only comparison | `snapshotsReflectExactStatePerCommit`, `compareIsMetadataBased` |
| Restoration (export, beside, destination snapshot, archives, authorized source restore) | `HistoryAndRestoreTests` suite |
| Retention & garbage collection | `retentionPrunesOldVersionsAndGarbageCollects` |
| Destination integrity verification | `destinationVerificationFindsSilentCorruption` |
| Database corruption recovery | `corruptDatabaseIsRestoredFromBackup`, `corruptDatabaseWithoutBackupIsRecreatedAndDestinationAdopted` |
| Selective sync of chosen changes | `selectiveSyncAppliesOnlyChosenChanges` |
| Commit graph is faithful to data (no invented branches) | `GraphLayoutTests` suite |
| FSEvents debouncing | `fsEventsTriggerDebouncedCallback` |
| No network / process execution / content-inspection APIs in shipped code | `shippedCodeUsesNoNetworkExecutionOrContentInspectionAPIs` (static scan), `packageHasNoThirdPartyDependencies` |
| Sandbox entitlements without network | `entitlementsAreSandboxedWithoutNetwork`; `scripts/build-app.sh` prints the signed entitlements |
| No sockets opened during sync | `synchronizationOpensNoNetworkSockets` (`lsof` on the test process) |
| No file contents in DB, WAL, backups, store or logs | `metadataDatabaseNeverContainsFileContents`, `contentIsEncryptedAtRestAndDeduplicated` |
| Private storage permissions (0600 / 0700 / 0400) | `storeFilesAreOwnerOnly` |
| Performance: 2,000-file initial sync and incremental re-sync | `manyFilesInitialAndIncrementalSync` (asserts incremental is faster and re-hashes ≤ 1 file) |

## Verified manually

* UI rendering of all sections against synthetic demo data (`DemoSeeder` plus the `FOLDERSYNC_UI_SNAPSHOT_DIR` hook): the graph lanes, edges, node colors, details panel and archive table were reviewed.
* `scripts/build-app.sh` produces a bundle whose signature verifies, with exactly the three sandbox entitlements.

## Not yet verified

* Launching the **sandboxed** bundle end to end: bookmark persistence across relaunch, Keychain key creation, notifications and the `SMAppService` login item.
* Real Trash behavior on external, network or non-APFS volumes.
* Behavior on HFS+, exFAT and SMB destinations (e.g. timestamp granularity).
* Scale beyond about 2,000 files and long histories; the UI pages history 300 commits at a time but has not been profiled with tens of thousands of commits.
* Memory and CPU when idle (expected to be minimal because monitoring is event driven, but not measured).
