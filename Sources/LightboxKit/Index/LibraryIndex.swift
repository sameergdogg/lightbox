import Foundation

/// The on-disk index every lightbox front end reads: the CLI, the MCP server and apps.
///
/// It is a cache of the library plus whatever lightbox has computed about it. The asset
/// rows can always be rebuilt from PhotoKit, but later tables (Vision signals, embeddings,
/// model judgements) cost hours, so the schema only ever moves forward through
/// `migrations`. It is never dropped and rebuilt.
public final class LibraryIndex {
    let db: Database

    /// `~/Library/Application Support/lightbox/index.sqlite`. Sandboxed apps pass their own
    /// container URL instead.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "lightbox", directoryHint: .isDirectory)
            .appending(path: "index.sqlite")
    }

    public init(url: URL) throws {
        db = try Database(url: url)
        try migrate()
    }

    private init(memory: Void) throws {
        db = try Database(url: nil)
        try migrate()
    }

    /// A throwaway index, for tests and dry runs.
    public static func inMemory() throws -> LibraryIndex {
        try LibraryIndex(memory: ())
    }

    // MARK: Schema

    /// Each entry moves the schema one version forward. Append; never edit a shipped entry.
    ///
    /// Dates are stored as seconds since 2001 (`timeIntervalSinceReferenceDate`), which is
    /// what `Date` holds internally. Converting to 1970-based seconds and back is not
    /// exact, and an inexact round trip would make every full sync see every row as
    /// changed.
    static let migrations: [String] = [
        """
        CREATE TABLE assets (
            id               TEXT PRIMARY KEY,
            uuid             TEXT    NOT NULL,
            media_type       TEXT    NOT NULL,
            subtypes         INTEGER NOT NULL,
            created          REAL,
            modified         REAL,
            width            INTEGER NOT NULL,
            height           INTEGER NOT NULL,
            duration         REAL    NOT NULL,
            latitude         REAL,
            longitude        REAL,
            favorite         INTEGER NOT NULL,
            hidden           INTEGER NOT NULL,
            edited           INTEGER NOT NULL,
            burst_id         TEXT,
            burst_selection  INTEGER NOT NULL,
            represents_burst INTEGER NOT NULL,
            source_type      INTEGER NOT NULL,
            indexed_at       REAL    NOT NULL
        );
        CREATE INDEX assets_uuid ON assets(uuid);
        CREATE INDEX assets_created ON assets(created);
        CREATE INDEX assets_burst ON assets(burst_id) WHERE burst_id IS NOT NULL;
        CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
        """,
        // 2: the cheap analysis tier (Vision + pixel statistics).
        """
        CREATE TABLE signals (
            id                TEXT PRIMARY KEY,
            version           INTEGER NOT NULL,
            status            INTEGER NOT NULL,   -- SignalStatus
            detail            TEXT,               -- why, when status is not ok
            source_width      INTEGER,
            source_height     INTEGER,
            aesthetic         REAL,
            utility           INTEGER,
            sharpness         REAL,
            luma              REAL,
            highlights        REAL,
            shadows           REAL,
            humans            INTEGER,
            faces             INTEGER,
            main_faces        INTEGER,
            best_face_quality REAL,
            largest_face      REAL,
            min_eye_openness  REAL,
            feature_print     BLOB,
            analyzed_at       REAL NOT NULL
        );
        CREATE INDEX signals_status ON signals(status, version);
        CREATE TABLE faces (
            asset_id   TEXT    NOT NULL,
            idx        INTEGER NOT NULL,
            x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
            confidence REAL,
            quality    REAL,
            yaw REAL, roll REAL, pitch REAL,
            left_eye   REAL,
            right_eye  REAL,
            sharpness  REAL,
            PRIMARY KEY (asset_id, idx)
        ) WITHOUT ROWID;
        CREATE TABLE labels (
            asset_id   TEXT NOT NULL,
            label      TEXT NOT NULL,
            confidence REAL NOT NULL,
            PRIMARY KEY (asset_id, label)
        ) WITHOUT ROWID;
        CREATE INDEX labels_by_label ON labels(label, confidence);
        """,
        // 3: Apple's own analysis, imported through osxphotos (optional).
        """
        CREATE TABLE apple (
            id          TEXT PRIMARY KEY,
            overall     REAL,
            scores      TEXT NOT NULL,   -- every ScoreInfo field as JSON
            caption     TEXT,
            title       TEXT,
            description TEXT,
            labels      TEXT NOT NULL,   -- tab-separated
            keywords    TEXT NOT NULL,   -- tab-separated
            imported_at REAL NOT NULL
        );
        CREATE TABLE people (
            asset_id TEXT NOT NULL,
            name     TEXT NOT NULL,
            PRIMARY KEY (asset_id, name)
        ) WITHOUT ROWID;
        CREATE INDEX people_by_name ON people(name COLLATE NOCASE, asset_id);
        CREATE TABLE apple_faces (
            asset_id   TEXT    NOT NULL,
            idx        INTEGER NOT NULL,
            person     TEXT,
            center_x   REAL, center_y REAL, size REAL,
            quality    REAL,
            eye_state  INTEGER,
            smile_type INTEGER,
            has_smile  INTEGER NOT NULL,
            yaw REAL, pitch REAL, roll REAL,
            PRIMARY KEY (asset_id, idx)
        ) WITHOUT ROWID;
        """,
        // 4: albums (the user's own and shared ones) and who is in them.
        """
        CREATE TABLE albums (
            id    TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            kind  TEXT NOT NULL,      -- Album.Kind
            count INTEGER NOT NULL
        );
        CREATE TABLE album_members (
            album_id TEXT NOT NULL,
            asset_id TEXT NOT NULL,
            PRIMARY KEY (album_id, asset_id)
        ) WITHOUT ROWID;
        CREATE INDEX album_members_by_asset ON album_members(asset_id);
        """,
        // 5: what model providers computed (face and whole-image vectors), and the named
        // identities built from face vectors. Vectors are Float16, L2-normalised; `model` names
        // the provider, so vectors from different models never mix.
        """
        CREATE TABLE vector_runs (
            asset_id TEXT    NOT NULL,
            model    TEXT    NOT NULL,
            status   INTEGER NOT NULL,   -- SignalStatus
            count    INTEGER NOT NULL,   -- faces found (face models); 1 for image models
            at       REAL    NOT NULL,
            PRIMARY KEY (asset_id, model)
        ) WITHOUT ROWID;
        CREATE TABLE face_vectors (
            asset_id TEXT    NOT NULL,
            model    TEXT    NOT NULL,
            idx      INTEGER NOT NULL,
            x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,  -- like `faces`: oriented, top-left origin
            vector   BLOB    NOT NULL,
            PRIMARY KEY (asset_id, model, idx)
        ) WITHOUT ROWID;
        CREATE TABLE image_vectors (
            asset_id TEXT NOT NULL,
            model    TEXT NOT NULL,
            vector   BLOB NOT NULL,
            PRIMARY KEY (model, asset_id)
        ) WITHOUT ROWID;
        CREATE TABLE identities (
            name     TEXT PRIMARY KEY,
            person   TEXT NOT NULL,      -- the Photos People name it was built from
            model    TEXT NOT NULL,
            sure     REAL NOT NULL,      -- score thresholds: lower is more alike
            maybe    REAL NOT NULL,
            report   TEXT NOT NULL,      -- calibration, as JSON
            built_at REAL NOT NULL
        );
        CREATE TABLE identity_matches (
            name     TEXT    NOT NULL,
            asset_id TEXT    NOT NULL,
            idx      INTEGER NOT NULL,
            score    REAL    NOT NULL,
            sure     INTEGER NOT NULL,
            PRIMARY KEY (name, asset_id, idx)
        ) WITHOUT ROWID;
        CREATE INDEX identity_matches_by_asset ON identity_matches(asset_id, name);
        """,
    ]

    public static var schemaVersion: Int { migrations.count }

    private func migrate() throws {
        let current = try db.userVersion
        guard current <= Self.schemaVersion else {
            throw DatabaseError(description:
                "index schema v\(current) is newer than this lightbox (v\(Self.schemaVersion)); update lightbox")
        }
        for version in current..<Self.schemaVersion {
            try db.transaction {
                try db.execute(Self.migrations[version])
                try db.setUserVersion(version + 1)
            }
        }
    }

    // MARK: Assets

    private static let columns = """
        id, media_type, subtypes, created, modified, width, height, duration, latitude, longitude,
        favorite, hidden, edited, burst_id, burst_selection, represents_burst, source_type
        """

    private static func record(from row: Statement) -> AssetRecord {
        AssetRecord(
            id: row.text(0) ?? "",
            mediaType: AssetRecord.MediaType(rawValue: row.text(1) ?? "") ?? .unknown,
            subtypes: UInt(row.int(2)),
            created: row.double(3).map(Date.init(timeIntervalSinceReferenceDate:)),
            modified: row.double(4).map(Date.init(timeIntervalSinceReferenceDate:)),
            pixelWidth: row.int(5),
            pixelHeight: row.int(6),
            duration: row.double(7) ?? 0,
            latitude: row.double(8),
            longitude: row.double(9),
            isFavorite: row.int(10) != 0,
            isHidden: row.int(11) != 0,
            isEdited: row.int(12) != 0,
            burstID: row.text(13),
            burstSelection: UInt(row.int(14)),
            representsBurst: row.int(15) != 0,
            sourceType: UInt(row.int(16))
        )
    }

    /// Inserts or replaces rows. Callers diff first; this writes whatever it is given.
    public func upsert(_ records: some Collection<AssetRecord>) throws {
        guard !records.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        try db.transaction {
            let insert = try db.prepare("""
                INSERT OR REPLACE INTO assets (\(Self.columns), uuid, indexed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for r in records {
                insert.bind(1, r.id).bind(2, r.mediaType.rawValue).bind(3, Int(r.subtypes))
                    .bind(4, r.created?.timeIntervalSinceReferenceDate)
                    .bind(5, r.modified?.timeIntervalSinceReferenceDate)
                    .bind(6, r.pixelWidth).bind(7, r.pixelHeight).bind(8, r.duration)
                    .bind(9, r.latitude).bind(10, r.longitude)
                    .bind(11, r.isFavorite).bind(12, r.isHidden).bind(13, r.isEdited)
                    .bind(14, r.burstID).bind(15, Int(r.burstSelection)).bind(16, r.representsBurst)
                    .bind(17, Int(r.sourceType)).bind(18, r.uuid).bind(19, now)
                try insert.step()
                insert.reset()
            }
        }
    }

    /// Removes rows; returns how many existed.
    @discardableResult
    public func delete(ids: some Collection<String>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try db.transaction {
            let delete = try db.prepare("DELETE FROM assets WHERE id = ?")
            let changes = try db.prepare("SELECT changes()")
            var removed = 0
            for id in ids {
                delete.bind(1, id)
                try delete.step()
                delete.reset()
                if try changes.step() { removed += changes.int(0) }
                changes.reset()
            }
            try deleteSignals(ids)
            try deleteAppleData(ids)
            let memberships = try db.prepare("DELETE FROM album_members WHERE asset_id = ?")
            for id in ids {
                try memberships.bind(1, id).step()
                memberships.reset()
            }
            return removed
        }
    }

    /// Every row, keyed by id. 65k rows load in well under a second; the full sync
    /// diffs against this in memory.
    public func allRecords() throws -> [String: AssetRecord] {
        let query = try db.prepare("SELECT \(Self.columns) FROM assets")
        var result: [String: AssetRecord] = [:]
        while try query.step() {
            let record = Self.record(from: query)
            result[record.id] = record
        }
        return result
    }

    public func records(ids: some Sequence<String>) throws -> [String: AssetRecord] {
        let query = try db.prepare("SELECT \(Self.columns) FROM assets WHERE id = ?")
        var result: [String: AssetRecord] = [:]
        for id in ids {
            query.bind(1, id)
            if try query.step() { result[id] = Self.record(from: query) }
            query.reset()
        }
        return result
    }

    /// Looks up by full local identifier, or by UUID alone (what Photos' database and
    /// file names use).
    public func record(matching key: String) throws -> AssetRecord? {
        let query = try db.prepare(
            "SELECT \(Self.columns) FROM assets WHERE id = ?1 OR uuid = ?1 COLLATE NOCASE LIMIT 1")
        query.bind(1, key)
        return try query.step() ? Self.record(from: query) : nil
    }

    public func allIDs() throws -> [String] {
        let query = try db.prepare("SELECT id FROM assets ORDER BY created")
        var ids: [String] = []
        while try query.step() { ids.append(query.text(0) ?? "") }
        return ids
    }

    public func count() throws -> Int {
        let query = try db.prepare("SELECT COUNT(*) FROM assets")
        return try query.step() ? query.int(0) : 0
    }

    // MARK: Stats

    public struct Stats: Sendable, Encodable, Equatable {
        public var total = 0
        public var images = 0
        public var videos = 0
        public var screenshots = 0
        public var livePhotos = 0
        public var favorites = 0
        public var hidden = 0
        public var edited = 0
        public var withLocation = 0
        public var burstFrames = 0
        /// Burst frames a default PhotoKit fetch leaves out (`AssetRecord.isHiddenBurstFrame`).
        public var hiddenBurstFrames = 0
        /// Photos from iCloud shared albums (not in the library).
        public var shared = 0
        public var earliest: Date?
        public var latest: Date?
    }

    public func stats() throws -> Stats {
        let screenshot = 4, live = 8   // PHAssetMediaSubtype.photoScreenshot, .photoLive
        let userPick = 2               // PHAssetBurstSelectionType.userPick
        let query = try db.prepare("""
            SELECT COUNT(*),
                   SUM(media_type = 'image'), SUM(media_type = 'video'),
                   SUM((subtypes & \(screenshot)) != 0), SUM((subtypes & \(live)) != 0),
                   SUM(favorite), SUM(hidden), SUM(edited), SUM(latitude IS NOT NULL),
                   SUM(burst_id IS NOT NULL),
                   SUM(burst_id IS NOT NULL AND represents_burst = 0 AND (burst_selection & \(userPick)) = 0),
                   MIN(created), MAX(created), SUM((source_type & 2) != 0)
            FROM assets
            """)
        var stats = Stats()
        guard try query.step() else { return stats }
        stats.total = query.int(0)
        stats.images = query.int(1)
        stats.videos = query.int(2)
        stats.screenshots = query.int(3)
        stats.livePhotos = query.int(4)
        stats.favorites = query.int(5)
        stats.hidden = query.int(6)
        stats.edited = query.int(7)
        stats.withLocation = query.int(8)
        stats.burstFrames = query.int(9)
        stats.hiddenBurstFrames = query.int(10)
        stats.earliest = query.double(11).map(Date.init(timeIntervalSinceReferenceDate:))
        stats.latest = query.double(12).map(Date.init(timeIntervalSinceReferenceDate:))
        stats.shared = query.int(13)
        return stats
    }

    // MARK: Meta

    public enum MetaKey: String, Sendable {
        /// Archived `PHPersistentChangeToken` as of the last successful sync.
        case changeToken = "sync.changeToken"
        /// ISO 8601 time of the last successful sync.
        case syncedAt = "sync.at"
        /// `full` or `incremental`.
        case syncMode = "sync.mode"
    }

    public func meta(_ key: MetaKey) throws -> Data? {
        let query = try db.prepare("SELECT value FROM meta WHERE key = ?")
        query.bind(1, key.rawValue)
        return try query.step() ? query.data(0) : nil
    }

    public func metaString(_ key: MetaKey) throws -> String? {
        try meta(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setMeta(_ key: MetaKey, _ value: Data?) throws {
        if let value {
            let upsert = try db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
            try upsert.bind(1, key.rawValue).bind(2, value).step()
        } else {
            let delete = try db.prepare("DELETE FROM meta WHERE key = ?")
            try delete.bind(1, key.rawValue).step()
        }
    }

    public func setMeta(_ key: MetaKey, _ value: String) throws {
        try setMeta(key, Data(value.utf8))
    }
}
