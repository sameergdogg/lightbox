import CoreGraphics
import Foundation
import Testing
@testable import LightboxKit

@Suite struct VectorTests {
    @Test func float16RoundTripKeepsCosines() {
        let v = VectorCoding.normalized((0..<512).map { Float(sin(Double($0) * 0.37)) })
        let back = VectorCoding.decode(VectorCoding.encode(v))
        #expect(back.count == 512)
        let dot = zip(v, back).map(*).reduce(0, +)
        #expect(abs(dot - 1) < 1e-3)
        #expect(VectorCoding.encode(v).count == 1024, "two bytes a dimension")
    }

    @Test func similarityRecoversRotationScaleAndShift() throws {
        let template = [CGPoint(x: 38, y: 52), CGPoint(x: 74, y: 52), CGPoint(x: 56, y: 72), CGPoint(x: 42, y: 92), CGPoint(x: 70, y: 92)]
        // The template turned 20°, doubled and moved: the fit must undo exactly that.
        let angle = 20.0 * .pi / 180, scale = 2.0
        let source = template.map { p in
            CGPoint(x: scale * (cos(angle) * p.x - sin(angle) * p.y) + 300,
                    y: scale * (sin(angle) * p.x + cos(angle) * p.y) + 120)
        }
        let m = try #require(FaceAligner.similarity(from: source, to: template))
        for (s, t) in zip(source, template) {
            let x = m.a * s.x - m.b * s.y + m.tx, y = m.b * s.x + m.a * s.y + m.ty
            #expect(abs(x - t.x) < 1e-6 && abs(y - t.y) < 1e-6)
        }
    }

    /// A white dot drawn where a landmark is must land where the template puts it.
    @Test func cropPutsLandmarksOnTheTemplate() throws {
        let w = 640, h = 480
        let context = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let leftEye = CGPoint(x: 250, y: 200)                       // top-left pixel coordinates
        context.fill(CGRect(x: leftEye.x - 3, y: Double(h) - leftEye.y - 3, width: 6, height: 6))
        let image = try #require(context.makeImage())
        let template = [CGPoint(x: 38.3, y: 51.7), CGPoint(x: 73.5, y: 51.5), CGPoint(x: 56.0, y: 71.7),
                        CGPoint(x: 41.5, y: 92.4), CGPoint(x: 70.7, y: 92.2)]
        // Landmarks: the template scaled ×3 and moved so the left eye is at the dot.
        let points = template.map { CGPoint(x: ($0.x - 38.3) * 3 + leftEye.x, y: ($0.y - 51.7) * 3 + leftEye.y) }
        let crop = try #require(FaceAligner.crop(image, from: points, to: template, side: 112))
        let bytes = try #require(crop.dataProvider?.data as Data?)
        // Brightest pixel in the crop (top-left origin rows).
        var best = (x: 0, y: 0, value: UInt8(0))
        for y in 0..<112 { for x in 0..<112 {
            let v = bytes[y * crop.bytesPerRow + x * 4]
            if v > best.value { best = (x, y, v) }
        } }
        #expect(abs(Double(best.x) - 38.3) <= 2 && abs(Double(best.y) - 51.7) <= 2, "dot at \(best.x),\(best.y)")
    }

    /// Three people with distinct face vectors; Photos has tagged two of them. The identity
    /// must find the owner in the library and in a shared album, and not the look-alike.
    @Test func identityCalibratesOnTagsAndFindsSharedPhotos() throws {
        let index = try LibraryIndex.inMemory()
        var generator = SplitMix(seed: 7)
        // Real face vectors have 512 dimensions, where unrelated faces are nearly orthogonal;
        // 128 keeps that property (32 let a random stranger land near the owner by chance).
        let dims = 128
        func centre() -> [Float] { VectorCoding.normalized((0..<dims).map { _ in Float(generator.gaussian()) }) }
        func face(near c: [Float], spread: Float = 0.4) -> [Float] {
            VectorCoding.normalized(zip(c, (0..<dims).map { _ in Float(generator.gaussian()) })
                .map { $0 + spread * $1 / Float(dims).squareRoot() })
        }
        let owner = centre(), other = centre(), stranger = centre()
        var records: [AssetRecord] = []
        var vectors: [(id: String, result: LibraryIndex.VectorResult)] = []
        var tags: [(String, String)] = []
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        func add(_ n: Int, _ vector: [Float], tag: String?, shared: Bool = false) {
            let record = AssetRecord(id: photo(n).id, created: photo(n).created, pixelWidth: 4032, pixelHeight: 3024,
                                     sourceType: shared ? 2 : 1)
            records.append(record)
            vectors.append((record.id, .faces([FaceVector(assetID: record.id, index: 0, box: box, vector: vector)])))
            if let tag { tags.append((record.id, tag)) }
        }
        for n in 1...60 { add(n, face(near: owner), tag: "Owner") }
        for n in 61...100 { add(n, face(near: other), tag: "Other") }
        add(101, face(near: owner), tag: nil, shared: true)        // the owner in a shared album
        add(102, face(near: stranger), tag: nil, shared: true)     // someone Photos never named
        try index.upsert(records)
        try index.saveVectors(vectors, model: "test")
        let insert = try index.db.prepare("""
            INSERT INTO apple_faces (asset_id, idx, person, center_x, center_y, size, has_smile) VALUES (?, 0, ?, 0.5, 0.5, 0.2, 0)
            """)
        for (id, person) in tags {
            insert.bind(1, id).bind(2, person)
            try insert.step()
            insert.reset()
        }

        let report = try Identity.build(index: index, person: "owner", name: "me", model: "test")
        #expect(report.taggedFaces == 60)
        #expect(report.otherPeople == 1)
        #expect(report.auc > 0.99)
        #expect(report.recallMaybe > 0.9)
        #expect(report.matches["shared"] == 1)

        var query = PhotoQuery()
        query.faces = ["me"]
        query.scope = .shared
        query.includeMaybeFaces = true
        #expect(try index.search(query).hits.map(\.asset.id) == [photo(101).id])
        #expect(try index.identities().map(\.name) == ["me"])
    }

    @Test func aboutRanksByCosineAndCountsUnembedded() throws {
        let index = try LibraryIndex.inMemory()
        try index.upsert([photo(1), photo(2), photo(3)])
        try index.saveVectors([(photo(1).id, .image([1, 0, 0])), (photo(2).id, .image([0.6, 0.8, 0]))], model: "m")
        var query = PhotoQuery()
        query.about = "anything"
        let result = try index.search(query, aboutVector: [0, 1, 0], aboutModel: "m")
        #expect(result.hits.map(\.asset.id) == [photo(2).id, photo(1).id])
        #expect(result.unembeddedImages == 1)
        #expect(abs((result.hits.first?.relevance ?? 0) - 0.8) < 1e-3)
        #expect(throws: (any Error).self) { try index.search(query) }
    }
}

/// Deterministic randomness for tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Standard normal (Box–Muller).
    mutating func gaussian() -> Double {
        let u = max(Double(next() >> 11) / Double(1 << 53), 1e-12), v = Double(next() >> 11) / Double(1 << 53)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}
