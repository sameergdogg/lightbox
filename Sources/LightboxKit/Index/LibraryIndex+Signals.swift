import Foundation

/// Where an item stands in the cheap analysis tier.
public enum SignalStatus: Int, Sendable, Encodable {
    case ok = 0
    /// No local rendition big enough yet, typically because the original is still in
    /// iCloud. Retried on every run, so these fill in as originals download.
    case waitingForPixels = 1
    /// Vision or PhotoKit failed. Retried on every run.
    case failed = 2
}

/// One stored analysis row, as read back from the index.
public struct StoredSignals: Sendable, Encodable {
    public var id: String
    public var version: Int
    public var status: SignalStatus
    public var detail: String?
    public var analyzedAt: Date
    /// Present when `status == .ok`.
    public var signals: VisionSignals?
}

extension LibraryIndex {
    /// What `analyze` should look at: images with no signals, signals from an older analyzer
    /// version, or a previous attempt that didn't succeed. Newest first, because recent
    /// photos are the ones people ask about.
    public func analysisQueue(version: Int, includeWaiting: Bool = true, limit: Int? = nil) throws -> [String] {
        let waiting = includeWaiting ? "OR s.status != 0" : "OR s.status = \(SignalStatus.failed.rawValue)"
        let query = try db.prepare("""
            SELECT a.id FROM assets a LEFT JOIN signals s ON s.id = a.id
            WHERE a.media_type = 'image' AND (s.id IS NULL OR s.version < ?1 \(waiting))
            ORDER BY a.created DESC
            \(limit.map { "LIMIT \($0)" } ?? "")
            """)
        query.bind(1, version)
        var ids: [String] = []
        while try query.step() { ids.append(query.text(0) ?? "") }
        return ids
    }

    public enum AnalysisResult: Sendable {
        case ok(VisionSignals)
        case waitingForPixels(String)
        case failed(String)
    }

    /// Replaces the stored analysis for each id, in one transaction.
    public func saveSignals(_ results: [(id: String, result: AnalysisResult)], version: Int) throws {
        guard !results.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        try db.transaction {
            try deleteSignals(results.map(\.id), inTransaction: true)
            let row = try db.prepare("""
                INSERT INTO signals (id, version, status, detail, source_width, source_height, aesthetic,
                    utility, sharpness, luma, highlights, shadows, humans, faces, main_faces,
                    best_face_quality, largest_face, min_eye_openness, feature_print, analyzed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let face = try db.prepare("""
                INSERT INTO faces (asset_id, idx, x, y, w, h, confidence, quality, yaw, roll, pitch,
                    left_eye, right_eye, sharpness)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let label = try db.prepare("INSERT OR REPLACE INTO labels (asset_id, label, confidence) VALUES (?, ?, ?)")

            for (id, result) in results {
                row.bind(1, id).bind(2, version).bind(20, now)
                switch result {
                case .waitingForPixels(let why):
                    row.bind(3, SignalStatus.waitingForPixels.rawValue).bind(4, why)
                case .failed(let why):
                    row.bind(3, SignalStatus.failed.rawValue).bind(4, why)
                case .ok(let s):
                    row.bind(3, SignalStatus.ok.rawValue)
                        .bind(5, s.sourceWidth).bind(6, s.sourceHeight)
                        .bind(7, s.aesthetic).bind(8, s.isUtility).bind(9, s.sharpness)
                        .bind(10, s.exposure.mean).bind(11, s.exposure.highlights).bind(12, s.exposure.shadows)
                        .bind(13, s.humans).bind(14, s.faces.count).bind(15, s.mainFaces.count)
                        .bind(16, s.bestFaceQuality).bind(17, s.largestFaceArea).bind(18, s.minEyeOpenness)
                        .bind(19, s.featurePrint)
                    for (index, f) in s.faces.enumerated() {
                        face.bind(1, id).bind(2, index).bind(3, f.x).bind(4, f.y).bind(5, f.width).bind(6, f.height)
                            .bind(7, f.confidence).bind(8, f.quality).bind(9, f.yaw).bind(10, f.roll).bind(11, f.pitch)
                            .bind(12, f.leftEye).bind(13, f.rightEye).bind(14, f.sharpness)
                        try face.step()
                        face.reset()
                    }
                    for l in s.labels {
                        try label.bind(1, id).bind(2, l.identifier).bind(3, l.confidence).step()
                        label.reset()
                    }
                }
                try row.step()
                row.reset()
            }
        }
    }

    public func signals(for id: String) throws -> StoredSignals? {
        let query = try db.prepare("""
            SELECT version, status, detail, analyzed_at, source_width, source_height, aesthetic, utility,
                   sharpness, luma, highlights, shadows, humans, feature_print
            FROM signals WHERE id = ?
            """)
        query.bind(1, id)
        guard try query.step() else { return nil }
        var stored = StoredSignals(
            id: id, version: query.int(0),
            status: SignalStatus(rawValue: query.int(1)) ?? .failed,
            detail: query.text(2),
            analyzedAt: Date(timeIntervalSinceReferenceDate: query.double(3) ?? 0))
        guard stored.status == .ok else { return stored }

        var signals = VisionSignals(
            sourceWidth: query.int(4), sourceHeight: query.int(5),
            aesthetic: query.double(6), isUtility: query.int(7) != 0, sharpness: query.double(8),
            exposure: .init(mean: query.double(9) ?? 0, highlights: query.double(10) ?? 0, shadows: query.double(11) ?? 0),
            humans: query.int(12), faces: [], labels: [], featurePrint: query.data(13))

        let faces = try db.prepare("""
            SELECT x, y, w, h, confidence, quality, yaw, roll, pitch, left_eye, right_eye, sharpness
            FROM faces WHERE asset_id = ? ORDER BY idx
            """)
        faces.bind(1, id)
        while try faces.step() {
            signals.faces.append(.init(
                x: faces.double(0) ?? 0, y: faces.double(1) ?? 0, width: faces.double(2) ?? 0, height: faces.double(3) ?? 0,
                confidence: faces.double(4) ?? 0, quality: faces.double(5),
                yaw: faces.double(6) ?? 0, roll: faces.double(7) ?? 0, pitch: faces.double(8) ?? 0,
                leftEye: faces.double(9), rightEye: faces.double(10), sharpness: faces.double(11)))
        }
        let labels = try db.prepare("SELECT label, confidence FROM labels WHERE asset_id = ? ORDER BY confidence DESC")
        labels.bind(1, id)
        while try labels.step() {
            signals.labels.append(.init(identifier: labels.text(0) ?? "", confidence: labels.double(1) ?? 0))
        }
        stored.signals = signals
        return stored
    }

    /// Drops analysis for these ids (deleted, or edited so the pixels changed).
    public func deleteSignals(_ ids: some Collection<String>) throws {
        try deleteSignals(ids, inTransaction: false)
    }

    func deleteSignals(_ ids: some Collection<String>, inTransaction: Bool) throws {
        guard !ids.isEmpty else { return }
        let work = {
            for table in ["signals WHERE id", "faces WHERE asset_id", "labels WHERE asset_id"] {
                let delete = try self.db.prepare("DELETE FROM \(table) = ?")
                for id in ids {
                    try delete.bind(1, id).step()
                    delete.reset()
                }
            }
        }
        // `delete(ids:)` calls this from inside its own transaction.
        if inTransaction || db.isInTransaction { try work() } else { try db.transaction(work) }
    }

    /// The few numbers an app ranks photos by, without faces or labels.
    public struct SignalSummary: Sendable, Equatable {
        public var aesthetic: Double?
        /// Faces at least `faceArea` of the frame; the face fields below cover only these.
        public var mainFaces: Int
        public var bestFaceQuality: Double?
        public var minEyeOpenness: Double?
        /// Sharpness of the least sharp counted face.
        public var minMainFaceSharpness: Double?
        public var sharpness: Double?
    }

    /// Summaries for every id that has a current, successful analysis, in one query.
    ///
    /// `faceArea` sets which faces count. The default matches `mainFaces` (anyone who isn't a
    /// passer-by). A ranking that compares faces, like eye openness or face sharpness, should
    /// ask for bigger faces: on a face a few dozen pixels wide, landmarks and sharpness
    /// are mostly noise (a mirror selfie's face is about 1 % of the frame).
    public func signalSummaries(ids: some Sequence<String>, faceArea: Double = VisionSignals.mainFaceArea,
                                version: Int = VisionAnalyzer.version) throws -> [String: SignalSummary] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [:] }
        let query = try db.prepare("""
            SELECT s.id, s.aesthetic, s.sharpness,
                   (SELECT COUNT(*) FROM faces f WHERE f.asset_id = s.id AND f.w * f.h >= ?2),
                   (SELECT MAX(f.quality) FROM faces f WHERE f.asset_id = s.id AND f.w * f.h >= ?2),
                   (SELECT MIN(MIN(f.left_eye, f.right_eye)) FROM faces f
                     WHERE f.asset_id = s.id AND f.w * f.h >= ?2 AND f.left_eye IS NOT NULL AND f.right_eye IS NOT NULL),
                   (SELECT MIN(f.sharpness) FROM faces f WHERE f.asset_id = s.id AND f.w * f.h >= ?2)
            FROM signals s WHERE s.status = 0 AND s.version >= ?1
            """)
        query.bind(1, version).bind(2, faceArea)
        var result: [String: SignalSummary] = [:]
        while try query.step() {
            let id = query.text(0) ?? ""
            guard wanted.contains(id) else { continue }
            result[id] = SignalSummary(aesthetic: query.double(1), mainFaces: query.int(3),
                                       bestFaceQuality: query.double(4), minEyeOpenness: query.double(5),
                                       minMainFaceSharpness: query.double(6), sharpness: query.double(2))
        }
        return result
    }

    public struct AnalysisCoverage: Sendable, Encodable, Equatable {
        public var images = 0
        public var ok = 0
        public var waitingForPixels = 0
        public var failed = 0
        public var outdated = 0
        public var notYet: Int { images - ok - waitingForPixels - failed - outdated }
    }

    public func analysisCoverage(version: Int) throws -> AnalysisCoverage {
        let query = try db.prepare("""
            SELECT COUNT(*),
                   SUM(s.status = 0 AND s.version >= ?1), SUM(s.status = 1 AND s.version >= ?1),
                   SUM(s.status = 2 AND s.version >= ?1), SUM(s.version < ?1)
            FROM assets a LEFT JOIN signals s ON s.id = a.id WHERE a.media_type = 'image'
            """)
        query.bind(1, version)
        guard try query.step() else { return .init() }
        return AnalysisCoverage(images: query.int(0), ok: query.int(1), waitingForPixels: query.int(2),
                                failed: query.int(3), outdated: query.int(4))
    }
}
