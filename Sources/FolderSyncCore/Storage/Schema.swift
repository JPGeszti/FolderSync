import Foundation

/// Versioned schema migrations. The database stores metadata only — never file contents.
enum Schema {
    static let migrations: [String] = [
        // v1
        """
        CREATE TABLE pairs (
            id TEXT PRIMARY KEY,
            json TEXT NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE TABLE commits (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            pair_id TEXT NOT NULL,
            parent_id TEXT,
            kind TEXT NOT NULL,
            status TEXT NOT NULL,
            started_at REAL NOT NULL,
            finished_at REAL,
            added INTEGER NOT NULL DEFAULT 0,
            modified INTEGER NOT NULL DEFAULT 0,
            deleted INTEGER NOT NULL DEFAULT 0,
            renamed INTEGER NOT NULL DEFAULT 0,
            archived INTEGER NOT NULL DEFAULT 0,
            restored INTEGER NOT NULL DEFAULT 0,
            failed INTEGER NOT NULL DEFAULT 0,
            bytes_transferred INTEGER NOT NULL DEFAULT 0,
            message TEXT,
            restored_from_seq INTEGER
        );
        CREATE INDEX commits_pair ON commits(pair_id, seq);

        CREATE TABLE changes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            commit_seq INTEGER NOT NULL REFERENCES commits(seq) ON DELETE CASCADE,
            pair_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            path TEXT NOT NULL,
            old_path TEXT,
            old_size INTEGER,
            new_size INTEGER,
            old_mtime INTEGER,
            new_mtime INTEGER,
            old_hash TEXT,
            new_hash TEXT,
            status TEXT NOT NULL,
            error TEXT,
            archive_path TEXT
        );
        CREATE INDEX changes_commit ON changes(commit_seq);
        CREATE INDEX changes_path ON changes(pair_id, path);

        CREATE TABLE file_versions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pair_id TEXT NOT NULL,
            path TEXT NOT NULL,
            hash TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime INTEGER NOT NULL,
            from_seq INTEGER NOT NULL,
            to_seq INTEGER
        );
        CREATE INDEX versions_open ON file_versions(pair_id, path, to_seq);
        CREATE INDEX versions_from ON file_versions(pair_id, from_seq);
        CREATE INDEX versions_hash ON file_versions(hash);

        CREATE TABLE tracked_files (
            pair_id TEXT NOT NULL,
            path TEXT NOT NULL,
            hash TEXT NOT NULL,
            size INTEGER NOT NULL,
            dest_mtime INTEGER NOT NULL,
            PRIMARY KEY (pair_id, path)
        );

        CREATE TABLE tracked_dirs (
            pair_id TEXT NOT NULL,
            path TEXT NOT NULL,
            PRIMARY KEY (pair_id, path)
        );

        CREATE TABLE source_index (
            pair_id TEXT NOT NULL,
            path TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime INTEGER NOT NULL,
            inode INTEGER NOT NULL,
            hash TEXT NOT NULL,
            PRIMARY KEY (pair_id, path)
        );

        CREATE TABLE archives (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pair_id TEXT NOT NULL,
            original_path TEXT NOT NULL,
            archive_path TEXT,
            hash TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime INTEGER NOT NULL,
            deleted_at REAL NOT NULL,
            commit_seq INTEGER NOT NULL,
            policy TEXT NOT NULL,
            state TEXT NOT NULL
        );
        CREATE INDEX archives_pair ON archives(pair_id, state);

        CREATE TABLE intents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pair_id TEXT NOT NULL,
            commit_seq INTEGER NOT NULL,
            op TEXT NOT NULL,
            path TEXT NOT NULL,
            path2 TEXT,
            temp_path TEXT,
            expected_hash TEXT,
            prior_hash TEXT,
            created_at REAL NOT NULL
        );

        CREATE TABLE conflicts (
            pair_id TEXT NOT NULL,
            path TEXT NOT NULL,
            kind TEXT NOT NULL,
            detail TEXT,
            detected_at REAL NOT NULL,
            PRIMARY KEY (pair_id, path)
        );

        CREATE TABLE path_overrides (
            pair_id TEXT NOT NULL,
            path TEXT NOT NULL,
            action TEXT NOT NULL,
            PRIMARY KEY (pair_id, path)
        );

        CREATE TABLE activity (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pair_id TEXT,
            ts REAL NOT NULL,
            level TEXT NOT NULL,
            message TEXT NOT NULL
        );
        CREATE INDEX activity_ts ON activity(ts);
        """,
    ]

    static func migrate(_ db: Database) throws {
        let current = db.userVersion
        guard current < migrations.count else { return }
        for v in current..<migrations.count {
            try db.transaction {
                try db.execute(migrations[v])
                try db.setUserVersion(v + 1)
            }
        }
    }
}
