import CoreGraphics
import Foundation
@preconcurrency import OnnxRuntimeBindings

/// One ONNX Runtime session. `run` may be called from many tasks at once: ORT sessions are
/// safe for concurrent runs.
final class ONNXModel: @unchecked Sendable {
    enum Accelerator: String { case cpu, coreml }

    // One environment per process, as ORT requires; it is thread-safe.
    nonisolated(unsafe) private static let env = try! ORTEnv(loggingLevel: .error)
    private let session: ORTSession

    /// Core ML lets the GPU and Neural Engine run what they support; `LIGHTBOX_ORT=cpu` turns it
    /// off. A model Core ML can't compile (SigLIP 2's patch convolution, as exported) runs on
    /// the CPU instead.
    init(path: URL, accelerator: Accelerator? = nil) throws {
        let choice = accelerator ?? Accelerator(rawValue: ProcessInfo.processInfo.environment["LIGHTBOX_ORT"] ?? "") ?? .coreml
        if choice == .coreml {
            let options = try ORTSessionOptions()
            try options.appendCoreMLExecutionProvider(withOptionsV2: ["MLComputeUnits": "ALL", "ModelFormat": "MLProgram"])
            if let session = try? ORTSession(env: Self.env, modelPath: path.path, sessionOptions: options) {
                self.session = session
                return
            }
        }
        session = try ORTSession(env: Self.env, modelPath: path.path, sessionOptions: try ORTSessionOptions())
    }

    enum Tensor {
        case float([Float], shape: [Int])
        case int64([Int64], shape: [Int])
    }

    /// Runs the model and returns one output, flattened.
    func run(_ inputs: [String: Tensor], output: String) throws -> [Float] {
        var values: [String: ORTValue] = [:]
        for (name, tensor) in inputs {
            switch tensor {
            case .float(let data, let shape):
                values[name] = try ORTValue(tensorData: NSMutableData(data: data.withUnsafeBytes { Data($0) }),
                                            elementType: .float, shape: shape.map { NSNumber(value: $0) })
            case .int64(let data, let shape):
                values[name] = try ORTValue(tensorData: NSMutableData(data: data.withUnsafeBytes { Data($0) }),
                                            elementType: .int64, shape: shape.map { NSNumber(value: $0) })
            }
        }
        let outputs = try session.run(withInputs: values, outputNames: [output], runOptions: nil)
        guard let value = outputs[output] else { throw ModelError("model gave no \(output)") }
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

struct ModelError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Pixels of `image` scaled to `width`×`height` (aspect ignored), as planar RGB floats
/// (`[R…, G…, B…]`), each channel mapped by `transform` from 0–255.
func planarRGB(_ image: CGImage, width: Int, height: Int, transform: (Float) -> Float) -> [Float]? {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return nil }
    let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    let plane = width * height
    var out = [Float](repeating: 0, count: plane * 3)
    for i in 0..<plane {
        out[i] = transform(Float(bytes[i * 4]))
        out[plane + i] = transform(Float(bytes[i * 4 + 1]))
        out[2 * plane + i] = transform(Float(bytes[i * 4 + 2]))
    }
    return out
}
