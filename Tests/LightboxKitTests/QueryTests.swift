import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LightboxKit

@Suite struct QueryTests {
    static func face(area: Double, eyes: Double?, quality: Double = 0.5) -> VisionSignals.Face {
        let side = area.squareRoot()
        return .init(x: 0.3, y: 0.3, width: side, height: side, confidence: 0.9, quality: quality,
                     yaw: 0, roll: 0, pitch: 0, leftEye: eyes, rightEye: eyes, sharpness: 300)
    }

    static func signals(faces: [VisionSignals.Face] = [], humans: Int? = nil, aesthetic: Double = 0.5,
                        utility: Bool = false, labels: [String: Double] = [:], sharpness: Double = 800) -> VisionSignals {
        VisionSignals(sourceWidth: 1024, sourceHeight: 768, aesthetic: aesthetic, isUtility: utility,
                      sharpness: sharpness, exposure: .init(mean: 0.5, highlights: 0, shadows: 0),
                      humans: humans ?? faces.count, faces: faces,
                      labels: labels.map { .init(identifier: $0.key, confidence: $0.value) }, featurePrint: nil)
    }

    /// Ten photos covering each filter, numbered so failures read clearly.
    static func fixture() throws -> LibraryIndex {
        let index = try LibraryIndex.inMemory()
        var screenshot = photo(6); screenshot.subtypes = 4
        var hiddenFrame = photo(7); hiddenFrame.burstID = "B"
        var favourite = photo(8); favourite.isFavorite = true
        var located = photo(9); located.latitude = 1; located.longitude = 2
        try index.upsert([photo(1), photo(2), photo(3), photo(4), photo(5), screenshot, hiddenFrame,
                          favourite, located, photo(10)])
        try index.saveSignals([
            (photo(1).id, .ok(signals(faces: [face(area: 0.06, eyes: 0.28, quality: 0.8)], aesthetic: 0.7))),
            (photo(2).id, .ok(signals(faces: [face(area: 0.06, eyes: 0.08)], aesthetic: 0.6))),        // blink
            (photo(3).id, .ok(signals(faces: [face(area: 0.05, eyes: 0.3), face(area: 0.04, eyes: 0.3)]))),
            (photo(4).id, .ok(signals(aesthetic: 0.2, labels: ["beach": 0.8, "sky": 0.6]))),
            (photo(5).id, .ok(signals(faces: [face(area: 0.002, eyes: 0.3)], humans: 1, aesthetic: 0.4))),  // passer-by
            (photo(6).id, .ok(signals(aesthetic: 0.9))),
            (photo(7).id, .ok(signals(faces: [face(area: 0.06, eyes: 0.3)]))),
            (photo(8).id, .ok(signals(utility: true))),
            (photo(9).id, .ok(signals(aesthetic: -0.3, labels: ["beach": 0.2]))),
            (photo(10).id, .waitingForPixels("in iCloud")),
        ], version: VisionAnalyzer.version)
        return index
    }

    func ids(_ index: LibraryIndex, _ configure: (inout PhotoQuery) -> Void) throws -> [Int] {
        var query = PhotoQuery()
        configure(&query)
        return try index.search(query).hits.map { hit in
            Int(hit.asset.id.prefix(8), radix: 16) ?? -1
        }
    }

    @Test func defaultsHideUtilityAndHiddenBurstFrames() throws {
        let index = try Self.fixture()
        // Photo 10 isn't analyzed, but nothing in a default query needs analysis.
        #expect(try Set(ids(index) { _ in }) == [1, 2, 3, 4, 5, 9, 10])
        #expect(try index.search(PhotoQuery()).unanalyzedImages == 0)
        #expect(try !ids(index) { $0.minAesthetic = -1 }.contains(10), "a Vision filter needs analysis")
        #expect(try index.search({ var q = PhotoQuery(); q.minAesthetic = -1; return q }()).unanalyzedImages == 1)
        #expect(try Set(ids(index) { $0.excludeUtility = false }) == [1, 2, 3, 4, 5, 6, 8, 9, 10])
        #expect(try ids(index) { $0.excludeHiddenBurstFrames = false }.contains(7))
    }

    @Test func peopleCountsMainFacesOnly() throws {
        let index = try Self.fixture()
        #expect(try Set(ids(index) { $0.people = .solo }) == [1, 2])
        #expect(try Set(ids(index) { $0.people = .group }) == [3])
        #expect(try Set(ids(index) { $0.people = .any }) == [1, 2, 3])
        #expect(try Set(ids(index) { $0.people = PhotoQuery.People.none }) == [4, 9], "photo 5 has a person, just small")
    }

    @Test func eyesOpenDropsTheBlink() throws {
        let index = try Self.fixture()
        #expect(try Set(ids(index) { $0.people = .solo; $0.eyesOpen = true }) == [1])
    }

    @Test func thresholdsLabelsAndFlags() throws {
        let index = try Self.fixture()
        #expect(try Set(ids(index) { $0.minAesthetic = 0.55 }) == [1, 2])
        #expect(try Set(ids(index) { $0.minFaceQuality = 0.7 }) == [1])
        #expect(try Set(ids(index) { $0.minFaceArea = 0.045 }) == [1, 2, 3])
        #expect(try Set(ids(index) { $0.labels = ["beach"] }) == [4], "photo 9's beach label is below confidence")
        #expect(try Set(ids(index) { $0.labels = ["beach", "sky"] }) == [4])
        #expect(try Set(ids(index) { $0.withLocation = true }) == [9])
        #expect(try Set(ids(index) { $0.favoritesOnly = true; $0.excludeUtility = false }) == [8])
    }

    @Test func sortAndPaging() throws {
        let index = try Self.fixture()
        #expect(try ids(index) { $0.sort = .aesthetic; $0.limit = 3 } == [1, 2, 3])
        #expect(try ids(index) { $0.sort = .aesthetic; $0.limit = 2; $0.offset = 1 } == [2, 3])
        #expect(try ids(index) { $0.sort = .oldest; $0.limit = 2 } == [1, 2])
        #expect(try ids(index) { $0.sort = .newest; $0.limit = 1 } == [10])
    }

    @Test func datesBoundTheRange() throws {
        let index = try Self.fixture()
        // photo(n) is created 700_000_000 + n * 1.234567 seconds after 2001.
        var query = PhotoQuery()
        query.from = Date(timeIntervalSinceReferenceDate: 700_000_000 + 3)
        query.to = Date(timeIntervalSinceReferenceDate: 700_000_000 + 6)
        query.sort = .oldest
        #expect(try index.search(query).hits.map { Int($0.asset.id.prefix(8), radix: 16) } == [3, 4])
    }

    @Test func onePerMomentKeepsTheBestOfEachShoot() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let times: [String: Date] = [
            "a": t0, "b": t0.addingTimeInterval(60), "c": t0.addingTimeInterval(3_600),
            "d": t0.addingTimeInterval(3_650), "e": t0.addingTimeInterval(-500), "f": t0.addingTimeInterval(-700),
        ]
        // Rank order: a is best, then its neighbour b, then c, d (same shoot as c), e, f.
        let kept = LibraryIndex.onePerMoment(["a", "b", "c", "d", "e", "f", "undated"],
                                             created: { times[$0] }, window: 600)
        // e is 500 s before a, so it goes. f is only near e, which was dropped, and 700 s from
        // a, so it stays: only photos actually kept count as neighbours.
        #expect(kept == ["a", "c", "f", "undated"])
    }

    @Test func distinctSearchPagesAfterFiltering() throws {
        let index = try LibraryIndex.inMemory()
        // Two shoots an hour apart, five frames each; photo(n) dates are ~1.2 s apart, so
        // move the second shoot.
        var records = (1...10).map { photo($0) }
        for i in 5..<10 { records[i].created = records[i].created?.addingTimeInterval(3_600) }
        try index.upsert(records)
        try index.saveSignals(records.enumerated().map { i, r in
            (r.id, .ok(Self.signals(aesthetic: Double(i) / 10)))
        }, version: VisionAnalyzer.version)
        var query = PhotoQuery()
        query.sort = .aesthetic
        query.distinctWithin = 600
        let hits = try index.search(query).hits.map { Int($0.asset.id.prefix(8), radix: 16) }
        #expect(hits == [10, 5], "the best frame of each shoot, best shoot first")
    }
}

@Suite struct ContactSheetTests {
    @Test func rendersNumberedTilesAndAKey() async throws {
        let image = Synthetic.checkerboard(cell: 20)
        let tiles = (1...7).map { ContactSheet.Tile(id: photo($0).id, caption: "2024-01-0\($0)") }
        var sheet = ContactSheet()
        sheet.columns = 4
        sheet.tileSize = 200
        let rendered = try await sheet.render(tiles, firstNumber: 21) { id in
            id == photo(3).id ? nil : image   // one tile with no pixels
        }
        #expect(rendered.key.map(\.number) == Array(21...27))
        #expect(rendered.key[2].sourceLongSide == 0)
        #expect(rendered.key[0].sourceLongSide == 640)

        let source = try #require(CGImageSourceCreateWithData(rendered.jpeg as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 4 * 200 + 5 * 6, "4 columns of 200 px plus 6 px gaps")
        #expect(decoded.height == 2 * (200 + 34) + 3 * 6, "2 rows, each with a caption strip")
    }

    @Test func fitKeepsAspectRatioAndCentres() {
        let rect = ContactSheet.fit(CGSize(width: 400, height: 200), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(rect == CGRect(x: 0, y: 25, width: 100, height: 50))
    }
}
