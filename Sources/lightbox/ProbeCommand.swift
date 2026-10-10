import ArgumentParser
import Foundation
import LightboxKit

/// Diagnostic: what PhotoKit hands back, callback by callback, for a random sample.
struct ProbeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Show PhotoKit's image callbacks for a random sample (diagnostic).",
        shouldDisplay: false
    )

    @OptionGroup var options: GlobalOptions

    @Option(help: "How many photos to sample.")
    var count = 20

    @Option(help: "Requested long side in pixels.")
    var maxSide = 1024

    func run() async throws {
        try await requirePhotosAccess()
        let ids = try options.openIndex().allIDs().shuffled().prefix(count)
        let loader = ImageLoader()
        for id in ids {
            let (outcome, callbacks) = await loader.probe(id, maxSide: maxSide)
            let summary: String = switch outcome {
            case .image(let image): "image \(image.width)x\(image.height)"
            case .tooSmall(let side): "too small \(side)"
            case .unavailable(let reason): "unavailable: \(reason)"
            case .missing: "missing"
            }
            let trail = callbacks.map {
                "\($0.width)x\($0.height)\($0.degraded ? " degraded" : "")\($0.inCloud ? " inCloud" : "")"
                    + "\($0.error.map { " error=\($0)" } ?? "") @\(String(format: "%.2f", $0.elapsed))s"
            }.joined(separator: " → ")
            print("\(id.prefix(8))  \(summary)  [\(trail)]")
        }
    }
}
