# FolderSync — Architecture & Security Design

Status: implemented in `Sources/FolderSyncCore` (engine) and
`Sources/FolderSyncApp` (UI). Every guarantee listed here is linked to the test
that verifies it in [`docs/VERIFICATION.md`](VERIFICATION.md). Anything that is
not covered by a test is listed there as **unverified**.

---

## 1. Software architecture

```
┌──────────────────────────── FolderSync.app (sandboxed, no network entitlement) ───────────────────────────┐
│                                                                                                          │
│  FolderSyncApp (SwiftUI, @MainActor)                                                                     │
│   ├─ AppModel ─ observable state, pair list, selection, notifications, launch-at-login                   │
│   ├─ Views: Dashboard · Folder Pairs · Changes · History (commit graph) · Archived · Activity · Settings  │
│   ├─ MenuBarExtra · keyboard commands · drag & drop · NSOpenPanel                                        │
│   └─ BookmarkAccess ─ security-scoped bookmarks → resolves URLs, start/stopAccessing                     │
│                       │                                                                                  │
│ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│─ trust boundary: UI ⇄ engine (value types only, no file handles) ─ ─ ─ ─ ─ ─ ─ ─ │
│                       ▼                                                                                  │
│  FolderSyncCore (no UI, no network, no Process)                                                          │
│   ├─ SyncService (actor) ─ per-pair mutual exclusion, scheduling, FSEvents debouncing                    │
│   ├─ PairValidator ─ availability, volume identity, overlap/nesting, symlinked roots                    │
│   ├─ SourceReader ─ READ-ONLY view of source: openat(O_NOFOLLOW) traversal, lstat, streaming reads      │
│   ├─ Planner ─ pure function: (source scan, tracked state, dest stat) → SyncPlan                         │
│   ├─ Executor ─ applies a plan with intent journal, temp files, fsync, verify, atomic rename             │
│   ├─ DestinationWriter ─ the ONLY component that mutates the destination; path-safety enforced          │
│   ├─ ObjectStore ─ content-addressed, AES-GCM encrypted, chunked, append-only version store             │
│   ├─ Database ─ SQLite (WAL, transactions, migrations, integrity check, rotating backups)               │
│   ├─ History ─ commits (hash-chained), changes, file-version intervals, snapshot queries & compare      │
│   ├─ Restorer ─ export / restore-to-destination / authorised restore-to-source                          │
│   └─ Recovery ─ replays or rolls back the intent journal after a crash                                  │
│                                                                                                          │
│  Private storage: ~/Library/Containers/<bundle-id>/Data/Library/Application Support/FolderSync/          │
│    foldersync.sqlite (0600) · backups/ · objects/ab/cdef… (0400) · tmp/ · locks/                         │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Modules and responsibilities

| Component | Mutates | Reads | Notes |
|---|---|---|---|
| `SourceReader` | nothing | source tree (metadata + bytes for copy/hash) | API has no write methods; this is a structural guarantee that the sync engine cannot modify the source. |
| `DestinationWriter` | destination | destination | Every path goes through `SafePath`; parents re-verified to be real directories (not symlinks); temp files created with `O_CREAT|O_EXCL|O_NOFOLLOW`. |
| `ObjectStore` | private store | private store | Objects are immutable once written; AEAD makes tampering detectable. |
| `Database` | private DB | private DB | Holds metadata only: paths, sizes, timestamps, hashes. Never file contents. |
| `Restorer.restoreToSource` | source | store | Only reachable with a `SourceWriteAuthorization` token that the UI mints after an explicit confirmation dialog. Never overwrites; writes a uniquely named copy. |

### Data model (SQLite)

* `pairs` – configuration, security-scoped bookmarks, recorded volume UUID + root inode of both folders.
* `commits` – one row per sync/restore run: `seq`, `id` (hash-chained, see §3), `parent_id`, `kind`, `status`, counts, bytes, timestamps.
* `changes` – per-file operations of a commit: kind, path, old/new path, old/new size, mtime and hash, status, error.
* `file_versions` – validity intervals `(path, hash, size, mtime, from_seq, to_seq)`. The destination state at commit *N* is every row with `from_seq ≤ N < to_seq` (or `to_seq IS NULL`). This gives exact snapshots without copying a manifest per commit.
* `tracked_files` – what FolderSync believes it put in the destination (hash, size, mtime). Destination files not in this table are **not owned** and are never modified or deleted.
* `source_index` – cache of `(size, mtime, inode) → hash` so unchanged files are never re-hashed.
* `archives` – preserved deleted files (policy A) and trashed/purged records, with original path, deletion time and commit.
* `intents` – write-ahead journal of filesystem operations (see §5).
* `conflicts` – unexpected destination modifications awaiting a user decision.
* `activity` – human-readable log (metadata only).

---

## 2. Security & privacy model

### Assets
Contents of user documents (highest), file names/paths (high – can be confidential), version history.

### Trust boundaries & adversaries
1. **Filenames and directory structure are untrusted input.** Anyone who can write to the source (e.g. a shared folder) controls names, symlinks, and can race the engine.
2. **Destination may be on removable or network media** that disappears, is replaced, or contains files not created by FolderSync.
3. **Other local processes running as the user** – outside the threat model for confidentiality of the data that is already readable by the user, but in scope for integrity (they can modify store files → detected by AEAD).
4. **The application itself** must be auditable: no network, no content interpretation.

### Controls

| Requirement | Control | Enforcement |
|---|---|---|
| No network | App Sandbox **without** `com.apple.security.network.client/server`; no networking APIs linked | Kernel sandbox denies sockets. A source-scan test fails the build on networking symbols; an entitlements test checks the plist; a runtime test asserts no sockets are open after a sync. |
| No content interpretation | Bytes flow only through `StreamingCopier` (copy + SHA-256 + encrypt). No `NSDocument`, `QuickLook`, `PDFKit`, `Spotlight`/`CoreSpotlight`, `NSAttributedString` loaders, thumbnails | Source-scan test for forbidden frameworks/APIs. |
| No content in logs/DB | Logging via `os.Logger` with `privacy: .private` for paths; DB stores only metadata | Test asserts DB contains no fixture byte sequences after a sync. |
| Least privilege FS access | Sandbox + `files.user-selected.read-write` + app-scoped bookmarks. No Full Disk Access, no helper tools, no admin rights | Entitlements test. |
| Source never modified | `SourceReader` has no mutating API; `O_RDONLY` opens; source tree checksum test before/after every scenario | Tests. |
| Symlink attacks | Traversal uses `openat(…, O_NOFOLLOW|O_DIRECTORY)`, `fstatat(AT_SYMLINK_NOFOLLOW)`; symlinks are recorded as *skipped* and never followed; file opened for reading is re-checked with `fstat` (regular file, same inode). Destination writes verify every parent is a real directory under the root | Symlink-attack tests (source symlink to outside, dest dir replaced by symlink). |
| Path traversal | `SafePath` rejects `..`, `.`, empty components, NUL, absolute paths, over-long components | Unit tests. |
| Atomic replacement | Temp file in the same directory → `fsync` → re-hash → `renameat`/`renamex_np(RENAME_EXCL)` | Interrupted-sync tests. |
| No shell execution | No `Process`, `system`, `popen`, `NSTask`, AppleScript in the app/engine | Source-scan test. |
| Store confidentiality | AES-256-GCM, 1 MiB chunks, AAD binds object hash + chunk index + final flag (prevents reordering/truncation). Key in the login Keychain (`AfterFirstUnlockThisDeviceOnly`) | Crypto tests (tamper, truncate, reorder, wrong key). |
| Store integrity | Object name = SHA-256 of plaintext; verified on every read; files 0400; dirs 0700 | Integrity tests. |
| History integrity | Commit IDs are hash-chained: `id = SHA256(parent_id ‖ pair ‖ seq ‖ kind ‖ status ‖ sorted change digests)` | Chain-verification test. |

### Residual risks (honest list)
* File **names** in the SQLite database are not encrypted (SQLCipher would require a third-party dependency). Mitigation: DB is inside the sandbox container with mode 0600; FileVault protects at rest.
* TOCTOU races on the *destination* between parent verification and `renameat` are narrowed (re-verification immediately before rename, `O_NOFOLLOW` on final component) but not eliminated, because Foundation lacks `openat2(RESOLVE_BENEATH)`. Destination is normally a user-controlled folder.
* Extended attributes, ACLs, resource forks and Finder tags are **not** copied (only data fork, POSIX permission bits without setuid/setgid, and modification date).
* Ad-hoc signed local builds cannot use the data-protection keychain; the legacy login keychain is used.

---

## 3. How the commit graph represents history accurately

Synchronization history for a folder pair is **strictly linear**: one sync run at a time (enforced by an actor lock and a per-pair `flock`), each run has exactly one parent. The graph therefore draws **no branches and no merges**.

Each commit row is drawn across up to three lanes:

| Lane | Node meaning | Source of truth |
|---|---|---|
| **Source** | Source state observed by the scan that started this run (counts of adds/mods/deletes/renames observed). | `changes` rows of the commit |
| **Destination** | Destination state *after* the run applied the changes; filled = all applied, half = partial, hollow ring with ✕ = failed/interrupted. | `commits.status`, `file_versions` |
| **Archive** | Present only if the run archived, trashed or permanently deleted files. | `changes` with kind archived/trashed/deleted |

Edges:
* Vertical edges in each lane connect consecutive commits that have a node in that lane (a lane line continues "through" rows where nothing happened in that lane – drawn thinner).
* A horizontal **propagation edge** Source → Destination in the same row means "these observed changes were applied". It is dashed when only partially applied and absent when nothing was applied.
* A **Destination → Archive** edge means "files left the active destination in this run".
* A **restore commit** has no source node (the source was not involved). Its provenance (the commit whose snapshot was restored) is shown as a `from #N` link on the row and in the details panel, which jumps to that commit. Rows are virtualized, so a long curved edge across off-screen rows is deliberately not drawn; it is still a real data-flow relationship, never a merge.

Node colors: added green, modified amber, deleted red, renamed blue, archived purple, restored teal, failed yellow-warning. A node with mixed kinds is drawn as a ring segmented proportionally by change counts.

Filters (operation type, date range) are applied *after* layout, so lane lines keep running through hidden commits instead of falsely connecting distant ones. Each folder pair has its own graph; histories of different pairs are never interleaved in one graph.

Accuracy is enforced by `GraphLayout` being a pure function of `[CommitSummary]` with unit tests (no node without a commit, no edges between non-adjacent commits except restore provenance, lane presence matches change kinds).

Scale: rows are virtualized (`LazyVStack`), each row draws only its own segment, and commits are fetched in pages of 200 from SQLite.

---

## 4. Version snapshots without parsing contents

* Files are treated as opaque byte streams. A single streaming pass (1 MiB buffer) computes SHA-256, writes the destination temp file, and – when versioning is `full` – feeds an AES-GCM chunk sealer writing to the object store's `tmp/`.
* After `fsync`, the destination temp file is **re-read and re-hashed**; only if the digest matches is it atomically renamed into place.
* The object is renamed to `objects/<hh>/<sha256>` (content addressing ⇒ deduplication of identical content across paths, commits and pairs).
* Version mode `replacedOnly` stores nothing on add, but before a destination file is overwritten, archived, trashed or deleted its bytes are ingested into the store and verified against the recorded hash. Both modes guarantee every historical version referenced by `file_versions` is restorable or explicitly marked pruned.
* Nothing ever looks inside the bytes: no MIME sniffing, no extension-based behavior, no previews.
* Retention: version intervals that ended more than *N* days ago are pruned; objects no longer referenced by any interval or archive are garbage-collected.

---

## 5. Data-loss risks and mitigations

| Risk | Mitigation |
|---|---|
| Source drive unmounted → empty folder looks like "everything deleted" | Pair records source volume UUID and root inode. Mismatch or missing root ⇒ `sourceUnavailable`, nothing is planned. A scan that finds 0 entries while files are tracked is treated as suspicious and blocks all deletions until the user confirms — this deliberately includes the legitimate case of deleting the last file in a source folder. |
| Mass accidental deletion in source | Configurable threshold (count and %) – deletions beyond it are held until the user confirms. Applies to all policies. |
| Permanent deletion | Off by default, requires explicit confirmation with warning; prior content is ingested into the version store before unlink (subject to retention). |
| Deleting/overwriting files FolderSync doesn't own | Only paths in `tracked_files` are ever overwritten/deleted. A new source file whose destination path is occupied by an unknown file becomes a conflict (adopted silently only if byte-identical). |
| Destination edited by user | Size/mtime mismatch → re-hash → conflict. Never silently overwritten. |
| Crash mid-copy | Temp file + atomic rename ⇒ destination is either old or new version. Intent journal is written before each operation; `Recovery` inspects the actual file hash and rolls the DB forward or back; orphaned temp files listed in intents are removed. Commit marked `interrupted`, never `success`. |
| Source file changes during copy | `fstat` before/after; mismatch ⇒ copy discarded, retried next run. |
| DB corruption | `PRAGMA quick_check` at open; rotating backups via SQLite backup API after successful syncs; restore latest healthy backup; otherwise rebuild with "adopt identical, conflict otherwise". |
| Store corruption | AEAD + hash verification on every read; `verifyStore()` reports corrupt objects; restoration never writes unverified data. |
| Case-insensitive destination | Source paths colliding case-/normalization-insensitively are reported as conflicts rather than overwriting each other. |
| Archive name collisions | `name_DELETED.ext` → `name_DELETED_yyyyMMdd-HHmmss.ext` → `…-<counter>`; created with `RENAME_EXCL`. Archives are tracked so they are never treated as source files; if a new source file later needs that path the archive is relocated, not overwritten. |
| Recursive sync | Overlap detection by real path **and** `(st_dev, st_ino)` ancestor walk (handles firmlinks/mount aliases); store location may not be inside either folder. |

---

## 6. Implementation plan

| Phase | Deliverable | Verification |
|---|---|---|
| 1 | This document | review |
| 2 | `SafePath`, `SourceReader`, `Planner`, `Executor`, `DestinationWriter`, deletion policies, conflicts | engine tests |
| 3 | `ObjectStore` (encrypted, chunked), `History`, retention, `Recovery`, DB backup/restore | store/recovery tests |
| 4 | SwiftUI: sidebar, dashboard, changes tree, commit graph, details, compare, file history, archives | `GraphLayout` tests, manual run |
| 5 | Menu bar, notifications, SMAppService launch-at-login, FSEvents watcher, mount notifications | manual |
| 6 | Privacy tests (static + runtime), symlink attacks, crash simulation, perf test on 5k files | tests |
| 7 | `scripts/build-app.sh` (bundle + entitlements + ad-hoc sign), `project.yml` (XcodeGen) | script run |
