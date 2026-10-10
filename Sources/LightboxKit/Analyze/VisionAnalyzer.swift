import CoreGraphics
import Foundation
import Vision

/// What lightbox knows about one photo after the cheap tier: Apple Vision plus a few
/// pixel statistics. Roughly 50 ms of work per photo on Apple Silicon.
public struct VisionSignals: Sendable, Equatable {
    public struct Face: Sendable, Equatable, Encodable {
        /// Normalized to the image, top-left origin.
        public var x, y, width, height: Double
        public var confidence: Double
        /// Vision's face capture quality, 0...1. Only comparable between photos of the same
        /// person in similar conditions, which is exactly the near-duplicate case.
        public var quality: Double?
        /// Degrees.
        public var yaw, roll, pitch: Double
        /// Eye height ÷ width from the landmarks, in pixels. See `eyesOpenAtLeast`.
        public var leftEye, rightEye: Double?
        /// Laplacian variance inside the face box, on the same 512 px grayscale copy.
        public var sharpness: Double?

        public var area: Double { width * height }
    }

    public struct Label: Sendable, Equatable, Encodable {
        public var identifier: String
        public var confidence: Double
    }

    /// Pixels Vision actually looked at.
    public var sourceWidth: Int
    public var sourceHeight: Int
    /// Vision's aesthetics score, -1...1.
    public var aesthetic: Double?
    /// Screenshots, receipts, documents: photos taken to record something, not to keep.
    public var isUtility: Bool
    public var sharpness: Double?
    public var exposure: Grayscale.Exposure
    public var humans: Int
    public var faces: [Face]
    public var labels: [Label]
    /// Vision feature print (float32 vector) for similarity.
    public var featurePrint: Data?

    /// A face at least this fraction of the frame counts as a subject, not a passer-by.
    public static let mainFaceArea = 0.01

    /// Eye openness at or above this reads as open. Calibrated by eye on a real library:
    /// frontal faces scoring 0.20–0.26 were all clearly open, and the lowest-scoring ones
    /// (≤ 0.16) were all closed or squinting. Two caveats: a big laugh squints, so it scores
    /// low too, and sunglasses produce a number that means nothing. Always use the smaller
    /// eye. A face with one eye at 0.26 and the other at 0.02 had both shut.
    public static let eyesOpenAtLeast = 0.18

    public var mainFaces: [Face] { faces.filter { $0.area >= Self.mainFaceArea } }
    public var bestFaceQuality: Double? { faces.compactMap(\.quality).max() }
    public var largestFaceArea: Double? { faces.map(\.area).max() }
    /// The least-open eye among the main faces: low means someone blinked.
    public var minEyeOpenness: Double? {
        mainFaces.flatMap { [$0.leftEye, $0.rightEye] }.compactMap { $0 }.min()
    }
}

extension VisionSignals: Encodable {
    private enum CodingKeys: String, CodingKey {
        case sourceWidth, sourceHeight, aesthetic, isUtility, sharpness, exposure, humans
        case mainFaces, bestFaceQuality, largestFaceArea, minEyeOpenness, faces, labels, featurePrintBytes
    }

    /// The feature print is reported by size only; as JSON it would be kilobytes of noise.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceWidth, forKey: .sourceWidth)
        try c.encode(sourceHeight, forKey: .sourceHeight)
        try c.encodeIfPresent(aesthetic, forKey: .aesthetic)
        try c.encode(isUtility, forKey: .isUtility)
        try c.encodeIfPresent(sharpness, forKey: .sharpness)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(humans, forKey: .humans)
        try c.encode(mainFaces.count, forKey: .mainFaces)
        try c.encodeIfPresent(bestFaceQuality, forKey: .bestFaceQuality)
        try c.encodeIfPresent(largestFaceArea, forKey: .largestFaceArea)
        try c.encodeIfPresent(minEyeOpenness, forKey: .minEyeOpenness)
        try c.encode(faces, forKey: .faces)
        try c.encode(labels, forKey: .labels)
        try c.encode(featurePrint?.count ?? 0, forKey: .featurePrintBytes)
    }
}

/// Runs the cheap tier on one image. Stateless and `Sendable`, so one instance can serve
/// every worker.
public struct VisionAnalyzer: Sendable {
    /// Bump when the signals or how they are computed change; stored rows with an older
    /// version are re-analyzed.
    /// 2: eye openness measured along the eye's axis, not the image's.
    public static let version = 2

    /// Labels below this confidence are not stored.
    public var labelThreshold: Double = 0.2
    public var maxLabels = 10

    public init() {}

    public func analyze(_ image: CGImage) async throws -> VisionSignals {
        let handler = ImageRequestHandler(image)
        let (aesthetics, landmarks, humans, classes, print) = try await handler.perform(
            CalculateImageAestheticsScoresRequest(),
            DetectFaceLandmarksRequest(),
            DetectHumanRectanglesRequest(),
            ClassifyImageRequest(),
            GenerateImageFeaturePrintRequest()
        )

        var qualities: [UUID: Double] = [:]
        if !landmarks.isEmpty {
            var request = DetectFaceCaptureQualityRequest()
            request.inputFaceObservations = landmarks
            let rated = try await handler.perform(request)
            for (index, face) in rated.enumerated() {
                guard let score = face.captureQuality?.score else { continue }
                // Matched by uuid; fall back to order, which Vision preserves.
                let key = landmarks.contains(where: { $0.uuid == face.uuid }) ? face.uuid : landmarks[safe: index]?.uuid
                if let key { qualities[key] = Double(score) }
            }
        }

        let gray = Grayscale(image)
        let size = CGSize(width: image.width, height: image.height)
        let faces = landmarks.map { observation -> VisionSignals.Face in
            let box = observation.boundingBox
            let top = 1 - box.origin.y - box.height
            var face = VisionSignals.Face(
                x: box.origin.x, y: top, width: box.width, height: box.height,
                confidence: Double(observation.confidence),
                quality: qualities[observation.uuid],
                yaw: observation.yaw.converted(to: .degrees).value,
                roll: observation.roll.converted(to: .degrees).value,
                pitch: observation.pitch.converted(to: .degrees).value)
            if let marks = observation.landmarks {
                face.leftEye = Self.openness(marks.leftEye.pointsInImageCoordinates(size))
                face.rightEye = Self.openness(marks.rightEye.pointsInImageCoordinates(size))
            }
            if let gray {
                let rect = CGRect(x: face.x * Double(gray.width), y: face.y * Double(gray.height),
                                  width: face.width * Double(gray.width), height: face.height * Double(gray.height))
                face.sharpness = gray.sharpness(in: rect)
            }
            return face
        }

        let labels = classes
            .filter { Double($0.confidence) >= labelThreshold }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxLabels)
            .map { VisionSignals.Label(identifier: $0.identifier, confidence: Double($0.confidence)) }

        return VisionSignals(
            sourceWidth: image.width, sourceHeight: image.height,
            aesthetic: Double(aesthetics.overallScore),
            isUtility: aesthetics.isUtility,
            sharpness: gray?.sharpness(),
            exposure: gray?.exposure ?? .init(mean: 0, highlights: 0, shadows: 0),
            humans: humans.count,
            faces: faces,
            labels: Array(labels),
            featurePrint: print.data
        )
    }

    /// Height over width of an eye outline, measured along the eye's own axis.
    ///
    /// The two points farthest apart are the corners; the width is the distance between them
    /// and the height is the spread of the outline perpendicular to that line. Measuring in
    /// image axes instead (version 1) broke on tilted heads: a face lying sideways scored
    /// 3.9, "wide open". Nil for a degenerate outline.
    static func openness(_ points: [CGPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        var corners = (points[0], points[1])
        var widest = 0.0
        for i in points.indices {
            for j in points.indices where j > i {
                let d = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                if d > widest { widest = d; corners = (points[i], points[j]) }
            }
        }
        guard widest > 0 else { return nil }
        let axis = CGPoint(x: (corners.1.x - corners.0.x) / widest, y: (corners.1.y - corners.0.y) / widest)
        let offsets = points.map { p in
            // Signed distance from the corner-to-corner line.
            (p.x - corners.0.x) * -axis.y + (p.y - corners.0.y) * axis.x
        }
        guard let low = offsets.min(), let high = offsets.max() else { return nil }
        return Double((high - low) / widest)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
