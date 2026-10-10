import Accelerate
import Foundation

/// A named person, recognised by face vectors and calibrated on the library's own People tags.
///
/// Photos only names faces in the owner's library; it runs no face recognition on photos in
/// shared albums. An identity carries the names over: its gallery is the faces Photos has
/// tagged with the person, the faces of everyone else Photos has named are its negatives,
/// and its thresholds are measured, not guessed. Half of the tagged faces build a gallery,
/// the other half (and half of every other person's faces) are scored against it, and the
/// thresholds are the scores at which 1 % ("maybe") and 0.1 % ("sure") of other people's faces
/// would pass. On a 55k-photo library with ArcFace that found 96 % of the owner's faces at
/// under 0.1 % false matches.
public enum Identity {
    public struct Report: Sendable, Codable {
        public var name: String
        public var person: String
        public var model: String
        /// Faces of the person (tagged by Photos and matched to a face vector).
        public var taggedFaces: Int
        /// Faces of other named people used as negatives, and how many people.
        public var otherFaces: Int
        public var otherPeople: Int
        /// Calibration on held-out faces.
        public var probes: Int
        public var negativeProbes: Int
        /// Chance a held-out face of the person scores closer than a held-out face of someone else.
        public var auc: Double
        public var sure: Double
        public var maybe: Double
        /// Share of held-out faces of the person found at each threshold.
        public var recallSure: Double
        public var recallMaybe: Double
        /// Share of other people's held-out faces that passed (should be ≈ 0.1 % and 1 %).
        public var falseSure: Double
        public var falseMaybe: Double
        /// Without the "nearer this person than any other named person" rule, for comparison.
        public var falseMaybeWithoutRule: Double
        /// Matches stored, by where the photo lives.
        public var matches: [String: Int] = [:]
    }

    /// Faces scored against a gallery: mean distance (1 − cosine) to the `k` nearest.
    /// Lower is more alike.
    static let k = 5
    /// Gallery caps: enough faces to cover every age and look, few enough to score fast.
    static let maxGallery = 800
    static let maxPerOtherPerson = 80

    public static func build(index: LibraryIndex, person: String, name: String? = nil, model: String) throws -> Report {
        let labelled = try index.labelledFaces(model: model)
        let isPerson = { (p: String) in p.compare(person, options: .caseInsensitive) == .orderedSame }
        let own = labelled.filter { isPerson($0.person) }.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        guard own.count >= 2 * k else {
            throw DatabaseError(description: "only \(own.count) faces of \(person) have vectors; run `lightbox faces` first (and `lightbox import-apple` for People tags)")
        }
        let others = Dictionary(grouping: labelled.filter { !isPerson($0.person) }, by: \.person)
            .filter { $0.value.count >= 2 * k }

        // Calibrate: even positions build galleries, odd positions are scored. The galleries are
        // capped exactly as the final ones are: a gallery of every tagged face (13k on the test
        // library) also holds Photos' tagging mistakes, which pull other people's faces close and
        // made the "sure" threshold find 61 % instead of 9x %.
        let gallery = Matrix(spread(own.enumerated().filter { $0.offset % 2 == 0 }.map(\.element.face.vector), max: maxGallery))
        let probes = own.enumerated().filter { $0.offset % 2 == 1 }.map(\.element.face.vector)
        var negativeGalleries: [Matrix] = []
        var negativeProbes: [[Float]] = []
        for faces in others.values {
            let sorted = faces.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
            negativeGalleries.append(Matrix(spread(sorted.enumerated().filter { $0.offset % 2 == 0 }.map(\.element.face.vector),
                                                   max: maxPerOtherPerson)))
            negativeProbes += sorted.enumerated().filter { $0.offset % 2 == 1 }.map(\.element.face.vector)
        }
        let scorer = Scorer(person: gallery, others: negativeGalleries)
        let ownScores = scorer.scores(probes)
        let negScores = scorer.scores(negativeProbes)

        let plainNeg = negScores.map(\.plain).sorted()
        let ruledNeg = negScores.map(\.ruled).sorted()
        func threshold(_ rate: Double) -> Double {
            // The distance below which at most `rate` of other people's faces fall, before the
            // named-people rule. Calibrating after the rule could give no finite threshold at all
            // (the rule rejects every named face), and then a stranger Photos never named, far
            // from everyone, would pass. The rule is applied on top, as a second test.
            let allowed = Int((Double(plainNeg.count) * rate).rounded(.down))
            return plainNeg.isEmpty ? 0.4 : (allowed < plainNeg.count ? plainNeg[allowed] : plainNeg.last! + 1e-6)
        }
        let sure = threshold(0.001), maybe = threshold(0.01)
        func share(_ scores: [Double], below t: Double) -> Double {
            scores.isEmpty ? 0 : Double(scores.filter { $0 < t }.count) / Double(scores.count)
        }
        var report = Report(
            name: name ?? person, person: person, model: model, taggedFaces: own.count,
            otherFaces: others.values.reduce(0) { $0 + $1.count }, otherPeople: others.count,
            probes: probes.count, negativeProbes: negativeProbes.count,
            auc: auc(positive: ownScores.map(\.plain), negative: plainNeg),
            sure: sure, maybe: maybe,
            recallSure: share(ownScores.map(\.ruled), below: sure), recallMaybe: share(ownScores.map(\.ruled), below: maybe),
            falseSure: share(ruledNeg, below: sure), falseMaybe: share(ruledNeg, below: maybe),
            falseMaybeWithoutRule: share(plainNeg, below: maybe))

        // Final galleries use every tagged face, spread over time when there are too many.
        let finalScorer = Scorer(person: Matrix(spread(own.map(\.face.vector), max: maxGallery)),
                                 others: others.values.map { faces in
                                     Matrix(spread(faces.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
                                         .map(\.face.vector), max: maxPerOtherPerson))
                                 })
        let all = try index.faceVectors(model: model)
        var matches: [(FaceVector, Double, Bool)] = []
        for chunk in stride(from: 0, to: all.count, by: 4096) {
            let faces = Array(all[chunk..<min(chunk + 4096, all.count)])
            for (face, score) in zip(faces, finalScorer.scores(faces.map(\.vector))) where score.ruled < maybe {
                matches.append((face, score.ruled, score.ruled < sure))
            }
        }
        report.matches = try index.saveIdentity(report, matches: matches)
        return report
    }

    /// Evenly spaced picks, so a long-tagged person isn't represented only by their busiest year.
    static func spread<T>(_ items: [T], max: Int) -> [T] {
        guard items.count > max else { return items }
        return (0..<max).map { items[$0 * items.count / max] }
    }

    static func auc(positive: [Double], negative: [Double]) -> Double {
        guard !positive.isEmpty, !negative.isEmpty else { return 0 }
        let negative = negative.sorted()
        var wins = 0.0
        for p in positive {
            // Negatives scoring worse (higher) than p, plus half the ties.
            var low = 0, high = negative.count
            while low < high { let mid = (low + high) / 2; if negative[mid] <= p { low = mid + 1 } else { high = mid } }
            var tieLow = 0, tieHigh = negative.count
            while tieLow < tieHigh { let mid = (tieLow + tieHigh) / 2; if negative[mid] < p { tieLow = mid + 1 } else { tieHigh = mid } }
            wins += Double(negative.count - low) + 0.5 * Double(low - tieLow)
        }
        return wins / Double(positive.count * negative.count)
    }

    /// Row-major vectors, ready for one matrix multiply against many faces.
    struct Matrix {
        let rows: Int
        let columns: Int
        /// Transposed (columns × rows), the shape `vDSP_mmul` wants on the right.
        let transposed: [Float]

        init(_ vectors: [[Float]]) {
            rows = vectors.count
            columns = vectors.first?.count ?? 0
            var flat = vectors.flatMap { $0 }
            var t = [Float](repeating: 0, count: flat.count)
            if rows > 0 { vDSP_mtrans(&flat, 1, &t, 1, vDSP_Length(columns), vDSP_Length(rows)) }
            transposed = t
        }

        /// Cosine similarity of every query row against every row here: queries × rows.
        func similarities(_ queries: [Float], count: Int) -> [Float] {
            var out = [Float](repeating: 0, count: count * rows)
            guard rows > 0, count > 0 else { return out }
            vDSP_mmul(queries, 1, transposed, 1, &out, 1, vDSP_Length(count), vDSP_Length(rows), vDSP_Length(columns))
            return out
        }
    }

    struct Scorer {
        let person: Matrix
        let others: [Matrix]

        struct Score { var plain: Double; var ruled: Double }

        /// `plain`: distance to the person. `ruled`: the same, or infinity when some other
        /// named person is nearer (the rule that removed a look-alike's false matches). A face
        /// matches when `ruled` is under a threshold set on `plain`.
        func scores(_ vectors: [[Float]]) -> [Score] {
            guard !vectors.isEmpty else { return [] }
            let flat = vectors.flatMap { $0 }
            let toPerson = Self.nearest(person.similarities(flat, count: vectors.count), rows: person.rows, count: vectors.count)
            var nearestOther = [Double](repeating: .infinity, count: vectors.count)
            for other in others {
                let d = Self.nearest(other.similarities(flat, count: vectors.count), rows: other.rows, count: vectors.count)
                for i in nearestOther.indices { nearestOther[i] = min(nearestOther[i], d[i]) }
            }
            return zip(toPerson, nearestOther).map { Score(plain: $0, ruled: $0 < $1 ? $0 : .infinity) }
        }

        /// Mean distance to the `k` most similar rows, per query.
        static func nearest(_ similarities: [Float], rows: Int, count: Int) -> [Double] {
            let k = min(Identity.k, rows)
            guard k > 0 else { return [Double](repeating: .infinity, count: count) }
            return (0..<count).map { q in
                let row = similarities[(q * rows)..<((q + 1) * rows)]
                let top = row.sorted(by: >).prefix(k)
                return 1 - Double(top.reduce(0, +)) / Double(k)
            }
        }
    }
}

extension LibraryIndex {
    /// Replaces the identity and its matches. Returns match counts by scope ("library", "shared").
    func saveIdentity(_ report: Identity.Report, matches: [(FaceVector, Double, Bool)]) throws -> [String: Int] {
        let shared = try sharedIDs()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var counts: [String: Int] = [:]
        try db.transaction {
            let clear = try db.prepare("DELETE FROM identity_matches WHERE name = ?")
            clear.bind(1, report.name)
            try clear.step()
            let insert = try db.prepare("INSERT OR REPLACE INTO identity_matches (name, asset_id, idx, score, sure) VALUES (?, ?, ?, ?, ?)")
            var photos: [String: Set<String>] = [:]
            for (face, score, sure) in matches {
                insert.bind(1, report.name).bind(2, face.assetID).bind(3, face.index).bind(4, score).bind(5, sure)
                try insert.step()
                insert.reset()
                photos[shared.contains(face.assetID) ? "shared" : "library", default: []].insert(face.assetID)
            }
            counts = photos.mapValues(\.count)
            var stored = report
            stored.matches = counts
            let row = try db.prepare("""
                INSERT OR REPLACE INTO identities (name, person, model, sure, maybe, report, built_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            row.bind(1, report.name).bind(2, report.person).bind(3, report.model).bind(4, report.sure).bind(5, report.maybe)
                .bind(6, String(decoding: try encoder.encode(stored), as: UTF8.self)).bind(7, Date().timeIntervalSinceReferenceDate)
            try row.step()
        }
        return counts
    }

    /// Every identity built so far.
    public func identities() throws -> [Identity.Report] {
        let query = try db.prepare("SELECT report FROM identities ORDER BY name")
        var reports: [Identity.Report] = []
        while try query.step() {
            if let json = query.text(0), let report = try? JSONDecoder().decode(Identity.Report.self, from: Data(json.utf8)) {
                reports.append(report)
            }
        }
        return reports
    }
}
