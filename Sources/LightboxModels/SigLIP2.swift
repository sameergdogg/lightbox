import CoreGraphics
import Foundation
import LightboxKit
import Tokenizers

/// Google's SigLIP 2 B/16 at 224 px (Apache-2.0), the model behind plain-language search.
/// Among six image–text models tried on a 55k-photo library it ranked best (P@10 0.70 on 30
/// everyday queries), ahead of its 400M sibling at a fourteenth of the compute, and far
/// ahead of Photos' own captions (0.56).
public final class SigLIP2: ImageTextEmbedder, @unchecked Sendable {
    public let model = "siglip2-b16"
    public let imageSide = 224
    /// SigLIP 2 was trained on 64-token texts, padded to the end.
    static let textLength = 64
    static let eos: Int64 = 1
    static let pad: Int64 = 0

    private let store: ModelStore
    private let tokenizer: Tokenizer
    private let lock = NSLock()
    private var visionModel: ONNXModel?
    private var textModel: ONNXModel?

    public init(store: ModelStore = ModelStore()) async throws {
        self.store = store
        tokenizer = try await AutoTokenizer.from(modelFolder: try store.folder(.siglip2))
    }

    /// Each half loads on first use: a search needs only the text model, `embed` only the
    /// vision one. Both run on the CPU: Core ML can't compile the exported vision model, and
    /// compiling the text model cost 10 s a launch for a model that runs once per query.
    private func model(_ name: String, _ slot: ReferenceWritableKeyPath<SigLIP2, ONNXModel?>) throws -> ONNXModel {
        lock.lock()
        defer { lock.unlock() }
        if let loaded = self[keyPath: slot] { return loaded }
        let loaded = try ONNXModel(path: try store.file(.siglip2, name), accelerator: .cpu)
        self[keyPath: slot] = loaded
        return loaded
    }

    public func embed(images: [CGImage]) throws -> [[Float]] {
        guard !images.isEmpty else { return [] }
        var batch: [Float] = []
        for image in images {
            guard let pixels = planarRGB(image, width: imageSide, height: imageSide, transform: { $0 / 127.5 - 1 }) else {
                throw ModelError("could not read an image")
            }
            batch += pixels
        }
        let out = try model("vision_model.onnx", \.visionModel).run(["pixel_values": .float(batch, shape: [images.count, 3, imageSide, imageSide])],
                                 output: "pooler_output")
        return split(out, count: images.count)
    }

    public func embed(texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let ids = texts.flatMap(tokens)
        let out = try model("text_model.onnx", \.textModel).run(["input_ids": .int64(ids, shape: [texts.count, Self.textLength])], output: "pooler_output")
        return split(out, count: texts.count)
    }

    /// The text as SigLIP 2 was trained on it (open_clip's "canonicalize" cleaning): lower
    /// case, punctuation removed, single spaces; then the end-of-text token and padding.
    func tokens(_ text: String) -> [Int64] {
        let cleaned = text.lowercased()
            .unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0) }
            .map(String.init).joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var ids = tokenizer.encode(text: cleaned, addSpecialTokens: false).map(Int64.init).prefix(Self.textLength - 1) + [Self.eos]
        ids += [Int64](repeating: Self.pad, count: Self.textLength - ids.count)
        return Array(ids)
    }

    private func split(_ flat: [Float], count: Int) -> [[Float]] {
        let width = flat.count / count
        return (0..<count).map { VectorCoding.normalized(Array(flat[($0 * width)..<(($0 + 1) * width)])) }
    }
}
