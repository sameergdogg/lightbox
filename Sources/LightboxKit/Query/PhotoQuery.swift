import Accelerate
import Foundation

/// A structured search over the index. Every field narrows the result; nil means "any".
///
/// Deliberately a value type of plain filters rather than a query language: the CLI maps
/// flags onto it, the MCP server will map tool arguments onto it, and an app can build one
/// from UI controls. All three get the same SQL.
public struct PhotoQuery: Sendable, Equatable, Encodable {
    public enum People: String, Sendable, Encodable, CaseIterable {
        /// No faces and no people.
        case none
        /// Exactly one main face (passers-by ignored).
        case solo
        /// Two or more main faces.
        case group
        /// At least one main face.
        case any
    }

    public enum Scope: String, Sendable, Encodable, CaseIterable {
        /// Library photos and photos in shared albums.
        case all
        /// Only the library: what the user owns and can delete.
        case library
        /// Only photos from iCloud shared albums.
        case shared
    }

    public enum Sort: String, Sendable, Encodable, CaseIterable {
        case newest, oldest
        /// Vision aesthetics, best first.
        case aesthetic
        /// Best face capture quality first.
        case faceQuality = "face-quality"
        /// Sharpest first.
        case sharpness
        /// Photos' own aesthetic score, best first (needs `import-apple`).
        case apple
        case random
    }

    public var people: People?
    /// Every one of these People names must be tagged in the photo (needs `import-apple`).
    /// Matching ignores case.
    public var persons: [String] = []
    /// Nobody but `persons` was detected: Photos found exactly that many faces. A good
    /// "photos of just me" filter, and it works on photos not yet analyzed by lightbox.
    public var alone = false
    /// Recognised by face: identities built with `lightbox identify`. Unlike `persons`, these
    /// also find people in photos from shared albums, where Photos names nobody.
    public var faces: [String] = []
    /// Count "maybe" face matches too (calibrated at 1 % false matches rather than 0.1 %).
    public var includeMaybeFaces = false
    /// A plain-language description ("dinner at a long table outdoors"), ranked by an
    /// image–text model's vectors (`lightbox embed`). Results come best match first, whatever
    /// `sort` says; the other filters still apply.
    public var about: String?
    /// Case-insensitive substring of Apple's caption, title, labels or keywords.
    public var text: String?
    /// Photos' own overall aesthetic score.
    public var minAppleScore: Double?
    /// The photo must be in every one of these albums (titles, ignoring case).
    public var albums: [String] = []
    public var scope: Scope = .all
    /// Eyes open. Without `persons`: every main face, by lightbox's own measure (see
    /// `VisionSignals.eyesOpenAtLeast`), so analysis is required. With `persons`: Photos marks
    /// each named person's face as open, and lightbox's measure agrees where it exists. Photos
    /// also catches eyes cast down at a phone, which a shape measure reads as open.
    public var eyesOpen = false
    /// The largest face covers at least this fraction of the frame (0.05 ≈ a portrait from
    /// a few metres, 0.15 ≈ head and shoulders).
    public var minFaceArea: Double?
    public var minFaceQuality: Double?
    /// Vision aesthetics, -1...1.
    public var minAesthetic: Double?
    public var minSharpness: Double?
    /// Leave out screenshots, receipts and documents (Vision's utility flag or the
    /// screenshot subtype).
    public var excludeUtility = true
    public var favoritesOnly = false
    public var withLocation = false
    public var includeHidden = false
    /// Hide burst frames Photos itself doesn't show.
    public var excludeHiddenBurstFrames = true
    public var from: Date?
    public var to: Date?
    /// Every label must be present with at least `labelConfidence`.
    public var labels: [String] = []
    public var labelConfidence = 0.3
    public var sort: Sort = .newest
    /// At most one photo per moment: after taking a hit, skip any other taken within this
    /// many seconds of it. Results otherwise bunch into a few shoots (ten frames of the same
    /// pose), which is useless when the goal is choosing.
    public var distinctWithin: TimeInterval?
    public var limit = 50
    public var offset = 0

    public init() {}

    /// SQL plus its bindings. Only analyzed photos (`signals.status = 0`) can match, because
    /// every useful filter needs signals; unanalyzed photos are counted separately.
    /// True when some filter or the sort order needs lightbox's own analysis. Otherwise the
    /// search also covers photos not yet analyzed (by person, caption, date, Apple score).
    public var needsAnalysis: Bool {
        people != nil || (eyesOpen && persons.isEmpty) || minFaceArea != nil || minFaceQuality != nil || minAesthetic != nil
            || minSharpness != nil || [.aesthetic, .faceQuality, .sharpness].contains(sort)
    }

    func sql(eyesOpenAtLeast: Double = VisionSignals.eyesOpenAtLeast,
             mainFaceArea: Double = VisionSignals.mainFaceArea) -> (String, [SQLBinding]) {
        var conditions = ["a.media_type = 'image'"]
        if needsAnalysis { conditions.append("s.status = 0") }
        var bindings: [SQLBinding] = []
        func bind(_ value: SQLBinding) -> String {
            bindings.append(value)
            return "?"
        }

        switch people {
        case .none?: conditions.append("s.main_faces = 0 AND s.humans = 0")
        case .solo?: conditions.append("s.main_faces = 1")
        case .group?: conditions.append("s.main_faces >= 2")
        case .any?: conditions.append("s.main_faces >= 1")
        case nil: break
        }
        if eyesOpen && persons.isEmpty {
            conditions.append("s.main_faces >= 1 AND s.min_eye_openness >= \(bind(.double(eyesOpenAtLeast)))")
        } else if eyesOpen {
            for person in persons {
                conditions.append("""
                    EXISTS (SELECT 1 FROM apple_faces f WHERE f.asset_id = a.id AND f.person = \(bind(.text(person))) \
                    COLLATE NOCASE AND f.eye_state = \(AppleImport.EyeState.open.rawValue))
                    """)
            }
            conditions.append("(s.status IS NOT 0 OR s.min_eye_openness IS NULL OR s.min_eye_openness >= \(bind(.double(eyesOpenAtLeast))))")
        }
        if let minFaceArea { conditions.append("s.largest_face >= \(bind(.double(minFaceArea)))") }
        if let minFaceQuality { conditions.append("s.best_face_quality >= \(bind(.double(minFaceQuality)))") }
        if let minAesthetic { conditions.append("s.aesthetic >= \(bind(.double(minAesthetic)))") }
        if let minSharpness { conditions.append("s.sharpness >= \(bind(.double(minSharpness)))") }
        if excludeUtility { conditions.append("COALESCE(s.utility, 0) = 0 AND (a.subtypes & 4) = 0") }
        for person in persons {
            conditions.append("EXISTS (SELECT 1 FROM people p WHERE p.asset_id = a.id AND p.name = \(bind(.text(person))) COLLATE NOCASE)")
        }
        for name in faces {
            let certainty = includeMaybeFaces ? "" : " AND m.sure = 1"
            conditions.append("EXISTS (SELECT 1 FROM identity_matches m WHERE m.asset_id = a.id AND m.name = \(bind(.text(name))) COLLATE NOCASE\(certainty))")
        }
        if alone {
            conditions.append("(SELECT COUNT(*) FROM apple_faces f WHERE f.asset_id = a.id) = \(bind(.double(Double(max(1, persons.count)))))")
        }
        if let text, !text.isEmpty {
            // One placeholder per use: positional `?`s don't share a binding.
            let fields = ["x.caption", "x.title", "x.labels", "x.keywords"]
                .map { "\($0) LIKE \(bind(.text("%\(text)%")))" }.joined(separator: " OR ")
            conditions.append("EXISTS (SELECT 1 FROM apple x WHERE x.id = a.id AND (\(fields)))")
        }
        switch scope {
        case .all: break
        case .library: conditions.append("(a.source_type & 2) = 0")    // PHAssetSourceType.typeCloudShared
        case .shared: conditions.append("(a.source_type & 2) != 0")
        }
        for album in albums {
            conditions.append("""
                EXISTS (SELECT 1 FROM album_members m JOIN albums al ON al.id = m.album_id \
                WHERE m.asset_id = a.id AND al.title = \(bind(.text(album))) COLLATE NOCASE)
                """)
        }
        if let minAppleScore {
            conditions.append("(SELECT x.overall FROM apple x WHERE x.id = a.id) >= \(bind(.double(minAppleScore)))")
        }
        if favoritesOnly { conditions.append("a.favorite = 1") }
        if withLocation { conditions.append("a.latitude IS NOT NULL") }
        if !includeHidden { conditions.append("a.hidden = 0") }
        if excludeHiddenBurstFrames {
            conditions.append("NOT (a.burst_id IS NOT NULL AND a.represents_burst = 0 AND (a.burst_selection & 2) = 0)")
        }
        if let from { conditions.append("a.created >= \(bind(.double(from.timeIntervalSinceReferenceDate)))") }
        if let to { conditions.append("a.created < \(bind(.double(to.timeIntervalSinceReferenceDate)))") }
        for label in labels {
            conditions.append("""
                EXISTS (SELECT 1 FROM labels l WHERE l.asset_id = a.id AND l.label = \(bind(.text(label))) \
                AND l.confidence >= \(bind(.double(labelConfidence))))
                """)
        }

        let order = switch sort {
        case .newest: "a.created DESC"
        case .oldest: "a.created ASC"
        case .aesthetic: "s.aesthetic DESC"
        case .faceQuality: "s.best_face_quality DESC NULLS LAST"
        case .sharpness: "s.sharpness DESC"
        case .apple: "(SELECT x.overall FROM apple x WHERE x.id = a.id) DESC NULLS LAST"
        case .random: "random()"
        }
        let sql = """
            SELECT a.id FROM assets a LEFT JOIN signals s ON s.id = a.id
            WHERE \(conditions.joined(separator: "\n  AND "))
            ORDER BY \(order), a.id
            LIMIT \(candidateLimit < 0 ? -1 : candidateLimit) OFFSET \(max(0, candidateOffset))
            """
        return (sql, bindings)
    }
}

extension PhotoQuery {
    /// With `distinctWithin`, paging happens after the moment filter, so SQL fetches a wide
    /// window of candidates from the start.
    /// With `about`, every candidate is ranked by vector after SQL, so SQL returns them all.
    var candidateLimit: Int {
        if about != nil { return -1 }
        return distinctWithin == nil ? limit : min(max((limit + offset) * 25, 500), 20_000)
    }
    var candidateOffset: Int { distinctWithin == nil && about == nil ? offset : 0 }
}

enum SQLBinding: Equatable {
    case double(Double)
    case text(String)
}

/// One search hit: the asset and its signals, ready to print or put on a sheet.
public struct PhotoHit: Sendable, Encodable {
    public var asset: AssetRecord
    public var signals: VisionSignals?
    public var apple: AppleInfo?
    /// Cosine similarity to the `about` text, when the search had one.
    public var relevance: Double?

    public init(asset: AssetRecord, signals: VisionSignals?, apple: AppleInfo? = nil, relevance: Double? = nil) {
        self.asset = asset
        self.signals = signals
        self.apple = apple
        self.relevance = relevance
    }
}

public struct SearchResult: Sendable, Encodable {
    public var query: PhotoQuery
    public var hits: [PhotoHit]
    /// How many images the filters could not be applied to because they aren't analyzed
    /// yet (usually: original still in iCloud). A hint that results are incomplete. Zero
    /// when the query doesn't need analysis.
    public var unanalyzedImages: Int
    /// With `about`: candidates that have no image vector yet, so couldn't be ranked.
    public var unembeddedImages = 0
}

extension LibraryIndex {
    /// `aboutVector` is the `about` text embedded by the same model (`aboutModel`) that made the
    /// stored image vectors; the CLI computes it, since LightboxKit runs no models.
    public func search(_ query: PhotoQuery, aboutVector: [Float]? = nil, aboutModel: String? = nil) throws -> SearchResult {
        if query.about != nil, aboutVector == nil || aboutModel == nil {
            throw DatabaseError(description: "a search with `about` needs its text embedded by an image–text model")
        }
        let (sql, bindings) = query.sql()
        let statement = try db.prepare(sql)
        for (offset, binding) in bindings.enumerated() {
            switch binding {
            case .double(let value): statement.bind(Int32(offset + 1), value)
            case .text(let value): statement.bind(Int32(offset + 1), value)
            }
        }
        var ids: [String] = []
        while try statement.step() { ids.append(statement.text(0) ?? "") }

        var relevance: [String: Double] = [:]
        var unembedded = 0
        if let aboutVector, let aboutModel {
            let vectors = try imageVectors(model: aboutModel, ids: Set(ids))
            unembedded = ids.count - vectors.count
            for (id, vector) in vectors {
                var dot: Float = 0
                vDSP_dotpr(vector, 1, aboutVector, 1, &dot, vDSP_Length(min(vector.count, aboutVector.count)))
                relevance[id] = Double(dot)
            }
            ids = ids.filter { relevance[$0] != nil }.sorted { relevance[$0]! > relevance[$1]! }
            if query.distinctWithin == nil { ids = Array(ids.dropFirst(query.offset).prefix(query.limit)) }
        }

        var records = try self.records(ids: ids)
        if let window = query.distinctWithin {
            ids = Self.onePerMoment(ids, created: { records[$0]?.created }, window: window)
            ids = Array(ids.dropFirst(query.offset).prefix(query.limit))
            records = records.filter { ids.contains($0.key) }
        }
        let hits = try ids.compactMap { id -> PhotoHit? in
            guard let asset = records[id] else { return nil }
            return PhotoHit(asset: asset, signals: try signals(for: id)?.signals, apple: try apple(for: id),
                            relevance: relevance[id])
        }
        let coverage = try analysisCoverage(version: VisionAnalyzer.version)
        return SearchResult(query: query, hits: hits,
                            unanalyzedImages: query.needsAnalysis ? coverage.images - coverage.ok : 0,
                            unembeddedImages: unembedded)
    }

    /// Greedy, in rank order: keep a photo unless one already kept was taken within
    /// `window` seconds of it. Undated photos are always kept.
    static func onePerMoment(_ ids: [String], created: (String) -> Date?, window: TimeInterval) -> [String] {
        var kept: [String] = []
        var times: [Date] = []   // sorted, for a binary search per candidate
        for id in ids {
            guard let date = created(id) else { kept.append(id); continue }
            var low = 0, high = times.count
            while low < high {
                let mid = (low + high) / 2
                if times[mid] < date { low = mid + 1 } else { high = mid }
            }
            let near = (low < times.count && times[low].timeIntervalSince(date) <= window)
                || (low > 0 && date.timeIntervalSince(times[low - 1]) <= window)
            guard !near else { continue }
            times.insert(date, at: low)
            kept.append(id)
        }
        return kept
    }
}
