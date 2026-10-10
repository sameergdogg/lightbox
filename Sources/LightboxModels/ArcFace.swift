import CoreGraphics
import Foundation
import LightboxKit

/// InsightFace's ArcFace ResNet-50 (buffalo_l's `w600k_r50.onnx`), the face model behind
/// `lightbox identify`. On a 55k-photo library it separated the owner from 40 other named
/// people with AUC 0.998, flat across 17 years; Apple's Vision feature prints managed 0.88.
///
/// The weights are InsightFace's and licensed for non-commercial research only, so lightbox
/// never ships them: `lightbox models pull arcface` downloads them to this Mac.
public final class ArcFace: FaceEmbedder {
    public let model = "arcface-r50"
    public let cropSide = 112
    public var template: [CGPoint] { Self.arcFaceTemplate }

    private let onnx: ONNXModel

    public init(store: ModelStore = ModelStore()) throws {
        onnx = try ONNXModel(path: try store.file(.arcface, "w600k_r50.onnx"))
    }

    public func embed(faces: [CGImage]) throws -> [[Float]] {
        guard !faces.isEmpty else { return [] }
        var batch: [Float] = []
        batch.reserveCapacity(faces.count * 3 * cropSide * cropSide)
        for face in faces {
            guard let pixels = planarRGB(face, width: cropSide, height: cropSide, transform: { ($0 - 127.5) / 127.5 }) else {
                throw ModelError("could not read a face crop")
            }
            batch += pixels
        }
        let out = try onnx.run(["input.1": .float(batch, shape: [faces.count, 3, cropSide, cropSide])], output: "683")
        let width = out.count / faces.count
        return (0..<faces.count).map { VectorCoding.normalized(Array(out[($0 * width)..<(($0 + 1) * width)])) }
    }
}
