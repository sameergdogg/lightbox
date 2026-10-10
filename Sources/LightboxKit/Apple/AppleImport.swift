import Foundation

/// Apple's own analysis of the library, imported through osxphotos.
///
/// Photos already computes a lot that PhotoKit doesn't expose: an aesthetic score and 20+
/// sub-scores per photo, who is in it (People), per-face eye and smile state, scene labels and
/// a one-line caption. All of it lives in Photos' private database. osxphotos is the
/// maintained reader of that database, so lightbox runs a short osxphotos script and stores
/// the result rather than parsing the database itself.
///
/// This is optional enrichment. Nothing else in LightboxKit depends on it, and a sandboxed
/// app can't do it: the sandbox blocks the Photos database.
public enum AppleImport {
    /// The script `lightbox import-apple` hands to `osxphotos run`. One compact JSON object
    /// per line on stdout, so the import can stream.
    ///
    /// Deliberately left out: osxphotos also exposes per-face age, gender and appearance
    /// guesses. lightbox has no use for them and doesn't store them.
    public static let osxphotosScript = #"""
        import json, os, sys
        import osxphotos

        def unnamed(name):
            return not name or name == "_UNKNOWN_"

        # An explicit path when given: on macOS 27 osxphotos can't find the system library on
        # its own ("Could not get path to photo library database").
        library = os.environ.get("LIGHTBOX_PHOTOS_LIBRARY")
        db = osxphotos.PhotosDB(dbfile=library) if library else osxphotos.PhotosDB()
        write = sys.stdout.write
        for p in db.photos(intrash=False):
            score = p.score.asdict() if p.score else {}
            faces = [{
                "n": None if unnamed(f.name) else f.name,
                "x": f.center_x, "y": f.center_y, "z": f.size, "q": f.quality,
                "e": f.eye_state, "m": f.smile_type, "h": bool(f.has_smile),
                "yaw": f.yaw, "pitch": f.pitch, "roll": f.roll,
            } for f in p.face_info]
            write(json.dumps({
                "u": p.uuid,
                "s": {k: v for k, v in score.items() if isinstance(v, (int, float))},
                "p": sorted({n for n in p.persons if not unnamed(n)}),
                "f": faces,
                "l": list(p.labels or []),
                "c": getattr(p, "ai_caption", None),
                "t": p.title,
                "d": p.description,
                "k": list(p.keywords or []),
            }, separators=(",", ":")) + "\n")
        """#

    /// One line of the script's output.
    public struct Record: Decodable, Sendable, Equatable {
        public struct Face: Decodable, Sendable, Equatable {
            public var n: String?
            public var x: Double?
            public var y: Double?
            public var z: Double?
            public var q: Double?
            public var e: Int?
            public var m: Int?
            public var h: Bool?
            public var yaw: Double?
            public var pitch: Double?
            public var roll: Double?
        }

        public var u: String
        public var s: [String: Double]
        public var p: [String]
        public var f: [Face]
        public var l: [String]?
        public var c: String?
        public var t: String?
        public var d: String?
        public var k: [String]?

        public static func decode(_ line: some StringProtocol) throws -> Record {
            try JSONDecoder().decode(Record.self, from: Data(line.utf8))
        }
    }

    /// Photos' face `eye_state`, as observed on a real library: 0 means the face wasn't
    /// analyzed (it occurs exactly as often as an unanalyzed smile), 1 closed, 2 open.
    public enum EyeState: Int, Sendable {
        case unknown = 0, closed = 1, open = 2
    }
}

/// What Apple knows about one photo, as stored in the index.
public struct AppleInfo: Sendable, Encodable, Equatable {
    public var overall: Double?
    /// Every ScoreInfo field Photos filled in (well_framed_subject, pleasant_lighting, …).
    public var scores: [String: Double]
    public var people: [String]
    public var caption: String?
    public var labels: [String]
    public var title: String?
    public var keywords: [String]
    public var faces: [Face]

    public struct Face: Sendable, Encodable, Equatable {
        public var person: String?
        public var quality: Double?
        /// See `AppleImport.EyeState`.
        public var eyeState: Int?
        public var smileType: Int?
        public var hasSmile: Bool
        public var size: Double?
    }
}

extension LibraryIndex {
    public struct AppleImportReport: Sendable, Encodable {
        public var read = 0
        /// Lines whose photo isn't in the index (shared-album items, or not yet indexed).
        public var unmatched = 0
        public var stored = 0
        /// Photos whose Apple data disappeared since the last import.
        public var removed = 0
        public var seconds = 0.0
    }

    /// Streams records into the index in batches. Afterwards, Apple data for photos that
    /// no longer appear in the export is dropped, so a full import leaves no stale rows.
    /// `progress` receives the number of records read, once per batch.
    public func importApple(_ records: some AsyncSequence<AppleImport.Record, any Error>,
                            batchSize: Int = 2_000,
                            progress: ((Int) -> Void)? = nil) async throws -> AppleImportReport {
        let started = Date()
        var report = AppleImportReport()
        let known = try uuidToID()
        var seen = Set<String>()
        var batch: [(String, AppleImport.Record)] = []

        for try await record in records {
            report.read += 1
            guard let id = known[record.u.uppercased()] else {
                report.unmatched += 1
                continue
            }
            seen.insert(id)
            batch.append((id, record))
            if batch.count >= batchSize {
                try saveApple(batch)
                report.stored += batch.count
                batch.removeAll(keepingCapacity: true)
                progress?(report.read)
            }
        }
        try saveApple(batch)
        report.stored += batch.count

        let stale = try appleIDs().subtracting(seen)
        try deleteAppleData(stale)
        report.removed = stale.count
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    private func uuidToID() throws -> [String: String] {
        let query = try db.prepare("SELECT uuid, id FROM assets")
        var map: [String: String] = [:]
        while try query.step() { map[(query.text(0) ?? "").uppercased()] = query.text(1) ?? "" }
        return map
    }

    private func appleIDs() throws -> Set<String> {
        let query = try db.prepare("SELECT id FROM apple")
        var ids = Set<String>()
        while try query.step() { ids.insert(query.text(0) ?? "") }
        return ids
    }

    func saveApple(_ batch: [(String, AppleImport.Record)]) throws {
        guard !batch.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try db.transaction {
            try deleteAppleData(batch.map(\.0))
            let row = try db.prepare("""
                INSERT INTO apple (id, overall, scores, caption, title, description, labels, keywords, imported_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let person = try db.prepare("INSERT OR IGNORE INTO people (asset_id, name) VALUES (?, ?)")
            let face = try db.prepare("""
                INSERT INTO apple_faces (asset_id, idx, person, center_x, center_y, size, quality,
                    eye_state, smile_type, has_smile, yaw, pitch, roll)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for (id, r) in batch {
                let scores = String(decoding: try encoder.encode(r.s), as: UTF8.self)
                try row.bind(1, id).bind(2, r.s["overall"]).bind(3, scores).bind(4, r.c.nilIfEmpty)
                    .bind(5, r.t.nilIfEmpty).bind(6, r.d.nilIfEmpty)
                    .bind(7, (r.l ?? []).joined(separator: "\t")).bind(8, (r.k ?? []).joined(separator: "\t"))
                    .bind(9, now).step()
                row.reset()
                for name in r.p {
                    try person.bind(1, id).bind(2, name).step()
                    person.reset()
                }
                for (index, f) in r.f.enumerated() {
                    try face.bind(1, id).bind(2, index).bind(3, f.n).bind(4, f.x).bind(5, f.y).bind(6, f.z)
                        .bind(7, f.q).bind(8, f.e).bind(9, f.m).bind(10, f.h ?? false)
                        .bind(11, f.yaw).bind(12, f.pitch).bind(13, f.roll).step()
                    face.reset()
                }
            }
        }
    }

    func deleteAppleData(_ ids: some Collection<String>) throws {
        guard !ids.isEmpty else { return }
        let work = {
            for table in ["apple WHERE id", "people WHERE asset_id", "apple_faces WHERE asset_id"] {
                let delete = try self.db.prepare("DELETE FROM \(table) = ?")
                for id in ids {
                    try delete.bind(1, id).step()
                    delete.reset()
                }
            }
        }
        if db.isInTransaction { try work() } else { try db.transaction(work) }
    }

    public func apple(for id: String) throws -> AppleInfo? {
        let query = try db.prepare("SELECT overall, scores, caption, title, labels, keywords FROM apple WHERE id = ?")
        query.bind(1, id)
        guard try query.step() else { return nil }
        var info = AppleInfo(
            overall: query.double(0),
            scores: (try? JSONDecoder().decode([String: Double].self, from: Data((query.text(1) ?? "{}").utf8))) ?? [:],
            people: [], caption: query.text(2),
            labels: Self.split(query.text(4)), title: query.text(3),
            keywords: Self.split(query.text(5)), faces: [])
        let people = try db.prepare("SELECT name FROM people WHERE asset_id = ? ORDER BY name")
        people.bind(1, id)
        while try people.step() { info.people.append(people.text(0) ?? "") }
        let faces = try db.prepare("""
            SELECT person, quality, eye_state, smile_type, has_smile, size FROM apple_faces WHERE asset_id = ? ORDER BY idx
            """)
        faces.bind(1, id)
        while try faces.step() {
            info.faces.append(.init(person: faces.text(0), quality: faces.double(1),
                                    eyeState: faces.isNull(2) ? nil : faces.int(2),
                                    smileType: faces.isNull(3) ? nil : faces.int(3),
                                    hasSmile: faces.int(4) != 0, size: faces.double(5)))
        }
        return info
    }

    public struct PersonCount: Sendable, Encodable {
        public var name: String
        public var photos: Int
    }

    /// Named people, most photographed first.
    public func people() throws -> [PersonCount] {
        let query = try db.prepare("SELECT name, COUNT(*) FROM people GROUP BY name ORDER BY 2 DESC, 1")
        var result: [PersonCount] = []
        while try query.step() { result.append(.init(name: query.text(0) ?? "", photos: query.int(1))) }
        return result
    }

    private static func split(_ text: String?) -> [String] {
        (text ?? "").split(separator: "\t").map(String.init)
    }
}

extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
