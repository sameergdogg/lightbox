import CoreGraphics
import Foundation
import Testing
@testable import LightboxKit

/// Synthetic images only; this is a public repo and personal photos never go in it.
enum Synthetic {
    /// A gray image filled by `shade(x, y)` → 0...255.
    static func image(width: Int = 640, height: Int = 480, _ shade: (Int, Int) -> UInt8) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = shade(x, y) } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func checkerboard(cell: Int) -> CGImage {
        image { x, y in ((x / cell) + (y / cell)) % 2 == 0 ? 30 : 220 }
    }

    /// The same pattern with soft edges: a sine wave instead of hard steps.
    static func smooth(period: Double) -> CGImage {
        image { x, y in UInt8(125 + 90 * sin(Double(x) / period) * sin(Double(y) / period)) }
    }

    static func flat(_ value: UInt8) -> CGImage { image { _, _ in value } }
}

@Suite struct PixelStatsTests {
    @Test func sharpEdgesScoreHigherThanSoftOnes() throws {
        let sharp = try #require(Grayscale(Synthetic.checkerboard(cell: 8))?.sharpness())
        let soft = try #require(Grayscale(Synthetic.smooth(period: 30))?.sharpness())
        #expect(sharp > soft * 10)
    }

    @Test func flatImageHasNoDetail() throws {
        let value = try #require(Grayscale(Synthetic.flat(128))?.sharpness())
        #expect(value < 0.001)
    }

    @Test func exposureReportsClipping() throws {
        let white = try #require(Grayscale(Synthetic.flat(255))).exposure
        #expect(white.highlights > 0.99 && white.shadows == 0 && white.mean > 0.99)
        let black = try #require(Grayscale(Synthetic.flat(0))).exposure
        #expect(black.shadows > 0.99 && black.highlights == 0 && black.mean < 0.01)
    }

    @Test func grayscaleIsScaledToTheRequestedLongSide() throws {
        let gray = try #require(Grayscale(Synthetic.flat(10), side: 512))
        #expect(gray.width == 512 && gray.height == 384)
    }

    @Test func regionTooSmallReturnsNil() throws {
        let gray = try #require(Grayscale(Synthetic.checkerboard(cell: 4)))
        #expect(gray.sharpness(in: CGRect(x: 10, y: 10, width: 8, height: 8)) == nil)
        #expect(gray.sharpness(in: CGRect(x: 10, y: 10, width: 64, height: 64)) != nil)
    }

    @Test func eyeOpennessIsHeightOverWidth() {
        let open = [CGPoint(x: 0, y: 5), CGPoint(x: 5, y: 8), CGPoint(x: 10, y: 5), CGPoint(x: 5, y: 2)]
        #expect(abs((VisionAnalyzer.openness(open) ?? 0) - 0.6) < 1e-9)
        #expect(VisionAnalyzer.openness([CGPoint(x: 1, y: 1)]) == nil)
    }

    /// A tilted head must not change the reading. In image axes, an eye lying at 90°
    /// read as 1 / 0.6 ≈ 1.67, "wide open".
    @Test func eyeOpennessIgnoresHeadTilt() {
        let open = [CGPoint(x: 0, y: 5), CGPoint(x: 5, y: 8), CGPoint(x: 10, y: 5), CGPoint(x: 5, y: 2),
                    CGPoint(x: 2, y: 6.5), CGPoint(x: 8, y: 3.5)]
        let level = VisionAnalyzer.openness(open) ?? 0
        for degrees in [30.0, 90.0, 145.0, -60.0] {
            let r = degrees * .pi / 180
            let turned = open.map { CGPoint(x: $0.x * cos(r) - $0.y * sin(r) + 40, y: $0.x * sin(r) + $0.y * cos(r) - 7) }
            #expect(abs((VisionAnalyzer.openness(turned) ?? 0) - level) < 1e-9, "at \(degrees)°")
        }
    }
}

@Suite struct VisionAnalyzerTests {
    /// Runs real Vision requests. A pattern has no faces or people; the point is that the
    /// whole pipeline runs and fills in what it should.
    @Test func analyzesASyntheticImage() async throws {
        let signals = try await VisionAnalyzer().analyze(Synthetic.checkerboard(cell: 16))
        #expect(signals.sourceWidth == 640 && signals.sourceHeight == 480)
        #expect(signals.faces.isEmpty)
        #expect(signals.humans == 0)
        #expect(signals.aesthetic.map { (-1...1).contains($0) } == true)
        #expect((signals.featurePrint?.count ?? 0) > 0)
        #expect((signals.sharpness ?? 0) > 0)
    }
}

@Suite struct SignalStorageTests {
    static func sample() -> VisionSignals {
        VisionSignals(
            sourceWidth: 1024, sourceHeight: 768, aesthetic: 0.42, isUtility: false, sharpness: 812.5,
            exposure: .init(mean: 0.5, highlights: 0.01, shadows: 0.02), humans: 2,
            faces: [
                .init(x: 0.1, y: 0.2, width: 0.2, height: 0.25, confidence: 0.99, quality: 0.7,
                      yaw: 5, roll: -2, pitch: 1, leftEye: 0.31, rightEye: 0.29, sharpness: 400),
                .init(x: 0.7, y: 0.1, width: 0.05, height: 0.05, confidence: 0.8, quality: nil,
                      yaw: 0, roll: 0, pitch: 0, leftEye: nil, rightEye: nil, sharpness: nil),
            ],
            labels: [.init(identifier: "outdoor", confidence: 0.9), .init(identifier: "people", confidence: 0.6)],
            featurePrint: Data(repeating: 7, count: 3072))
    }

    @Test func signalsRoundTrip() throws {
        let index = try LibraryIndex.inMemory()
        try index.upsert([photo(1)])
        try index.saveSignals([(photo(1).id, .ok(Self.sample()))], version: VisionAnalyzer.version)
        let stored = try #require(try index.signals(for: photo(1).id))
        #expect(stored.status == .ok)
        #expect(stored.signals == Self.sample())
        #expect(stored.signals?.mainFaces.count == 1, "the 0.25 % face is a passer-by")
        #expect(stored.signals?.minEyeOpenness == 0.29)
    }

    @Test func reanalysisReplacesFacesAndLabels() throws {
        let index = try LibraryIndex.inMemory()
        try index.upsert([photo(1)])
        try index.saveSignals([(photo(1).id, .ok(Self.sample()))], version: 1)
        var fewer = Self.sample()
        fewer.faces = []
        fewer.labels = [.init(identifier: "indoor", confidence: 0.5)]
        try index.saveSignals([(photo(1).id, .ok(fewer))], version: 1)
        #expect(try index.signals(for: photo(1).id)?.signals == fewer)
    }

    @Test func queueHoldsNewOutdatedAndUnfinishedImagesOnly() throws {
        let index = try LibraryIndex.inMemory()
        var video = photo(9); video.mediaType = .video
        try index.upsert([photo(1), photo(2), photo(3), photo(4), photo(5), video])
        try index.saveSignals([
            (photo(1).id, .ok(Self.sample())),
            (photo(2).id, .waitingForPixels("in iCloud")),
            (photo(3).id, .failed("vision")),
        ], version: 2)
        try index.saveSignals([(photo(4).id, .ok(Self.sample()))], version: 1)

        let queue = Set(try index.analysisQueue(version: 2))
        #expect(queue == [photo(2).id, photo(3).id, photo(4).id, photo(5).id])
        let skippingWaiting = Set(try index.analysisQueue(version: 2, includeWaiting: false))
        #expect(skippingWaiting == [photo(3).id, photo(4).id, photo(5).id])

        let coverage = try index.analysisCoverage(version: 2)
        #expect(coverage == .init(images: 5, ok: 1, waitingForPixels: 1, failed: 1, outdated: 1))
        #expect(coverage.notYet == 1)
    }

    @Test func summariesComeBackForAnalyzedIdsOnly() throws {
        let index = try LibraryIndex.inMemory()
        try index.upsert([photo(1), photo(2), photo(3)])
        try index.saveSignals([
            (photo(1).id, .ok(Self.sample())), (photo(2).id, .waitingForPixels("in iCloud")),
        ], version: VisionAnalyzer.version)
        let summaries = try index.signalSummaries(ids: [photo(1).id, photo(2).id, photo(3).id])
        #expect(Set(summaries.keys) == [photo(1).id])
        let summary = try #require(summaries[photo(1).id])
        #expect(summary.mainFaces == 1 && summary.minEyeOpenness == 0.29 && summary.bestFaceQuality == 0.7)
        #expect(summary.minMainFaceSharpness == 400, "the passer-by's face doesn't count")
        #expect(try index.signalSummaries(ids: [photo(1).id], version: VisionAnalyzer.version + 1).isEmpty)
        // Asking for faces of at least 10 % of the frame leaves only the 5 % face out too.
        let strict = try #require(try index.signalSummaries(ids: [photo(1).id], faceArea: 0.1)[photo(1).id])
        #expect(strict.mainFaces == 0 && strict.minEyeOpenness == nil && strict.minMainFaceSharpness == nil)
        #expect(strict.aesthetic == 0.42, "photo-level fields don't depend on faces")
    }

    @Test func deletingAnAssetDeletesItsAnalysis() throws {
        let index = try LibraryIndex.inMemory()
        try index.upsert([photo(1)])
        try index.saveSignals([(photo(1).id, .ok(Self.sample()))], version: 1)
        try index.delete(ids: [photo(1).id])
        #expect(try index.signals(for: photo(1).id) == nil)
        let leftovers = try index.db.prepare("SELECT (SELECT COUNT(*) FROM faces) + (SELECT COUNT(*) FROM labels)")
        #expect(try leftovers.step() && leftovers.int(0) == 0)
    }

    @Test func editingAPhotoInvalidatesItsAnalysisButFavouritingDoesNot() throws {
        let source = FakeSource([photo(1), photo(2)])
        let index = try LibraryIndex.inMemory()
        let indexer = Indexer(source: source, index: index)
        _ = try indexer.sync()
        try index.saveSignals([(photo(1).id, .ok(Self.sample())), (photo(2).id, .ok(Self.sample()))], version: 1)

        var edited = photo(1, modified: 50); edited.isEdited = true
        source.update([edited, photo(2, modified: 50, favorite: true)])
        _ = try indexer.sync()
        #expect(try index.signals(for: photo(1).id) == nil)
        #expect(try index.signals(for: photo(2).id)?.status == .ok)
    }
}
