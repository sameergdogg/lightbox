import Accelerate
import Foundation

/// Vectors as stored: Float16, which halves the index (55k image vectors of 768 dims are
/// 84 MB) and loses nothing a cosine ranking can see.
public enum VectorCoding {
    public static func encode(_ vector: [Float]) -> Data {
        var source = vector
        var halves = [UInt16](repeating: 0, count: vector.count)
        source.withUnsafeMutableBufferPointer { src in
            halves.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: src.baseAddress, height: 1, width: vImagePixelCount(vector.count), rowBytes: vector.count * 4)
                var d = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(vector.count), rowBytes: vector.count * 2)
                vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
            }
        }
        return halves.withUnsafeBytes { Data($0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / 2
        var halves = [UInt16](repeating: 0, count: count)
        _ = halves.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        var floats = [Float](repeating: 0, count: count)
        halves.withUnsafeMutableBufferPointer { src in
            floats.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: src.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                var d = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
            }
        }
        return floats
    }

    /// Scaled to unit length, so a dot product is the cosine.
    public static func normalized(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}

/// One face a face model has seen: where it is and its vector.
public struct FaceVector: Sendable {
    public var assetID: String
    public var index: Int
    /// Normalised to the oriented image, top-left origin (the same convention as `faces`).
    public var box: CGRect
    public var vector: [Float]

    public init(assetID: String, index: Int, box: CGRect, vector: [Float]) {
        self.assetID = assetID
        self.index = index
        self.box = box
        self.vector = vector
    }
}

extension LibraryIndex {
    public enum VectorKind: Sendable { case faces, images }

    /// Photos a model still has to see. Faces: analyzed library photos in which Vision found a
    /// face, and every photo from a shared album (where finding people is the point, and the
    /// first Vision pass at 1024 px missed faces the 1600 px landmark pass finds). Images: every image. Hidden burst frames
    /// are left out of image vectors, since search never returns them; face models see them,
    /// because a burst frame can be the only sharp picture of someone.
    public func vectorQueue(model: String, kind: VectorKind, scope: PhotoQuery.Scope = .all,
                            includeWaiting: Bool = true, limit: Int? = nil) throws -> [String] {
        var conditions = ["a.media_type = 'image'"]
        switch kind {
        case .faces: conditions.append("((a.source_type & 2) != 0 OR EXISTS (SELECT 1 FROM signals s WHERE s.id = a.id AND s.status = 0 AND s.faces > 0))")
        case .images: conditions.append("NOT (a.burst_id IS NOT NULL AND a.represents_burst = 0 AND (a.burst_selection & 2) = 0)")
        }
        switch scope {
        case .all: break
        case .library: conditions.append("(a.source_type & 2) = 0")
        case .shared: conditions.append("(a.source_type & 2) != 0")
        }
        let retry = includeWaiting ? "r.status = 0" : "r.status != \(SignalStatus.failed.rawValue)"
        conditions.append("NOT EXISTS (SELECT 1 FROM vector_runs r WHERE r.asset_id = a.id AND r.model = ?1 AND \(retry))")
        let query = try db.prepare("""
            SELECT a.id FROM assets a WHERE \(conditions.joined(separator: " AND "))
            ORDER BY a.created DESC \(limit.map { "LIMIT \($0)" } ?? "")
            """)
        query.bind(1, model)
        var ids: [String] = []
        while try query.step() { ids.append(query.text(0) ?? "") }
        return ids
    }

    public enum VectorResult: Sendable {
        case faces([FaceVector])
        case image([Float])
        case waitingForPixels
        case failed
    }

    /// Replaces what `model` stored for each photo, in one transaction.
    public func saveVectors(_ results: [(id: String, result: VectorResult)], model: String) throws {
        guard !results.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        try db.transaction {
            let clearFaces = try db.prepare("DELETE FROM face_vectors WHERE asset_id = ? AND model = ?")
            let run = try db.prepare("INSERT OR REPLACE INTO vector_runs (asset_id, model, status, count, at) VALUES (?, ?, ?, ?, ?)")
            let face = try db.prepare("INSERT INTO face_vectors (asset_id, model, idx, x, y, w, h, vector) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
            let image = try db.prepare("INSERT OR REPLACE INTO image_vectors (asset_id, model, vector) VALUES (?, ?, ?)")
            for (id, result) in results {
                clearFaces.bind(1, id).bind(2, model)
                try clearFaces.step()
                clearFaces.reset()
                let (status, count): (SignalStatus, Int)
                switch result {
                case .faces(let faces):
                    (status, count) = (.ok, faces.count)
                    for f in faces {
                        face.bind(1, id).bind(2, model).bind(3, f.index)
                            .bind(4, Double(f.box.minX)).bind(5, Double(f.box.minY))
                            .bind(6, Double(f.box.width)).bind(7, Double(f.box.height))
                            .bind(8, VectorCoding.encode(f.vector))
                        try face.step()
                        face.reset()
                    }
                case .image(let vector):
                    (status, count) = (.ok, 1)
                    image.bind(1, id).bind(2, model).bind(3, VectorCoding.encode(vector))
                    try image.step()
                    image.reset()
                case .waitingForPixels: (status, count) = (.waitingForPixels, 0)
                case .failed: (status, count) = (.failed, 0)
                }
                run.bind(1, id).bind(2, model).bind(3, status.rawValue).bind(4, count).bind(5, now)
                try run.step()
                run.reset()
            }
        }
    }

    /// Every face vector from `model`, optionally only for some photos.
    public func faceVectors(model: String, ids: Set<String>? = nil) throws -> [FaceVector] {
        let query = try db.prepare("SELECT asset_id, idx, x, y, w, h, vector FROM face_vectors WHERE model = ?")
        query.bind(1, model)
        var faces: [FaceVector] = []
        while try query.step() {
            let id = query.text(0) ?? ""
            if let ids, !ids.contains(id) { continue }
            faces.append(FaceVector(assetID: id, index: query.int(1),
                                    box: CGRect(x: query.double(2) ?? 0, y: query.double(3) ?? 0,
                                                width: query.double(4) ?? 0, height: query.double(5) ?? 0),
                                    vector: VectorCoding.decode(query.data(6) ?? Data())))
        }
        return faces
    }

    /// Image vectors from `model` for these photos (all of them when `ids` is nil).
    public func imageVectors(model: String, ids: Set<String>? = nil) throws -> [String: [Float]] {
        let query = try db.prepare("SELECT asset_id, vector FROM image_vectors WHERE model = ?")
        query.bind(1, model)
        var vectors: [String: [Float]] = [:]
        while try query.step() {
            let id = query.text(0) ?? ""
            if let ids, !ids.contains(id) { continue }
            vectors[id] = VectorCoding.decode(query.data(1) ?? Data())
        }
        return vectors
    }

    public struct VectorCoverage: Sendable, Encodable {
        public var model: String
        public var ok = 0
        public var waitingForPixels = 0
        public var failed = 0
        /// Faces stored (face models only).
        public var faces = 0
    }

    public func vectorCoverage(model: String) throws -> VectorCoverage {
        var coverage = VectorCoverage(model: model)
        let query = try db.prepare("SELECT status, COUNT(*), SUM(count) FROM vector_runs WHERE model = ? GROUP BY status")
        query.bind(1, model)
        while try query.step() {
            switch SignalStatus(rawValue: query.int(0)) {
            case .ok?: coverage.ok = query.int(1)
            case .waitingForPixels?: coverage.waitingForPixels = query.int(1)
            case .failed?: coverage.failed = query.int(1)
            case nil: break
            }
        }
        let faces = try db.prepare("SELECT COUNT(*) FROM face_vectors WHERE model = ?")
        faces.bind(1, model)
        if try faces.step() { coverage.faces = faces.int(0) }
        return coverage
    }

    /// Face vectors that Photos has tagged with a person's name, matched by position: Apple's
    /// face centre (bottom-left origin) against the vector's box (top-left origin). About
    /// 80 % of tagged faces on single-face photos pair up this way.
    public func labelledFaces(model: String, tolerance: Double = 0.03) throws -> [(person: String, face: FaceVector, created: Date?)] {
        let query = try db.prepare("""
            SELECT f.person, v.asset_id, v.idx, v.x, v.y, v.w, v.h, v.vector, a.created
            FROM apple_faces f
            JOIN face_vectors v ON v.asset_id = f.asset_id AND v.model = ?1
            JOIN assets a ON a.id = f.asset_id
            WHERE f.person IS NOT NULL AND f.person != '' AND substr(f.person, 1, 1) != '_'
              AND abs((v.x + v.w / 2) - f.center_x) < ?2
              AND abs((1 - (v.y + v.h / 2)) - f.center_y) < ?2
            """)
        query.bind(1, model).bind(2, tolerance)
        var seen = Set<String>()
        var labelled: [(String, FaceVector, Date?)] = []
        while try query.step() {
            let id = query.text(1) ?? "", index = query.int(2)
            // A vector that matched two tagged faces is ambiguous; keep the first only.
            guard seen.insert("\(id)#\(index)").inserted else { continue }
            let face = FaceVector(assetID: id, index: index,
                                  box: CGRect(x: query.double(3) ?? 0, y: query.double(4) ?? 0,
                                              width: query.double(5) ?? 0, height: query.double(6) ?? 0),
                                  vector: VectorCoding.decode(query.data(7) ?? Data()))
            labelled.append((query.text(0) ?? "", face, query.double(8).map(Date.init(timeIntervalSinceReferenceDate:))))
        }
        return labelled
    }
}
