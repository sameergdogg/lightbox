import Foundation
import Testing
@testable import LightboxModels

/// Runs only where the weights are installed (`lightbox models pull siglip2`).
@Suite(.enabled(if: ModelStore().isInstalled(.siglip2))) struct SigLIP2Tests {
    /// The tokens open_clip feeds SigLIP 2 for this text, which is how the search experiment
    /// scored it: punctuation dropped, then end-of-text (1), then padding (0) to 64.
    @Test func tokensMatchOpenCLIP() async throws {
        let model = try await SigLIP2()
        let tokens = model.tokens("A photo of a lighthouse.")
        #expect(Array(tokens.prefix(7)) == [235250, 2686, 576, 476, 89428, 1, 0])
        #expect(tokens.count == 64)
    }

    @Test func textFindsTheMatchingDescription() async throws {
        let model = try await SigLIP2()
        let v = try model.embed(texts: ["a photo of a dog", "a photo of a puppy", "a spreadsheet of numbers"])
        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map(*).reduce(0, +) }
        #expect(dot(v[0], v[1]) > dot(v[0], v[2]))
    }
}
