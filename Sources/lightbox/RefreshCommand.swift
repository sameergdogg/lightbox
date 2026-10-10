import ArgumentParser
import Foundation
import LightboxKit
import LightboxModels

/// `index` then `analyze`, then (when their models are installed) `faces`, `identify` again
/// for every identity, and `embed`, as one quiet step with a one-line summary. This is what
/// the scheduled job runs. Like `analyze`, it never downloads anything. Kept as a single binary invocation, rather than a shell script,
/// so macOS attributes Photos access to lightbox and not to `/bin/sh`.
struct RefreshCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Sync the index and analyze whatever needs it; one summary line (for scheduled runs)."
    )

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await requirePhotosAccess()
        let index = try options.openIndex()
        let sync = try Indexer(source: PhotoKitSource(), index: index).sync()
        let analysis = try await AnalysisRunner(index: index).run()
        let coverage = try index.analysisCoverage(version: VisionAnalyzer.version)

        // Models are optional: each step runs only if its weights are installed.
        let store = ModelStore()
        var faces: AnalysisRunner.Progress?
        var identities: [Identity.Report] = []
        var images: AnalysisRunner.Progress?
        if store.isInstalled(.arcface) {
            let embedder = try ArcFace(store: store)
            faces = try await VectorRunner(index: index).faces(embedder)
            if (faces?.ok ?? 0) > 0 {
                identities = try index.identities().map {
                    try Identity.build(index: index, person: $0.person, name: $0.name, model: embedder.model)
                }
            }
        }
        if store.isInstalled(.siglip2) {
            images = try await VectorRunner(index: index).images(try await SigLIP2(store: store))
        }

        if options.json {
            struct Output: Encodable {
                let sync: Indexer.Report
                let analysis: AnalysisRunner.Progress
                let coverage: LibraryIndex.AnalysisCoverage
                let faces: AnalysisRunner.Progress?
                let identities: [Identity.Report]
                let images: AnalysisRunner.Progress?
            }
            return try printJSON(Output(sync: sync, analysis: analysis, coverage: coverage,
                                        faces: faces, identities: identities, images: images))
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("\(stamp) \(sync.mode.rawValue) sync +\(sync.inserted) ~\(sync.updated) -\(sync.deleted) "
              + "(\(sync.total) items); analyzed \(analysis.done) in \(Int(analysis.seconds))s: "
              + "\(analysis.ok) ok, \(analysis.waitingForPixels) waiting, \(analysis.failed) failed; "
              + "library: \(coverage.ok) done, \(coverage.waitingForPixels) waiting for pixels"
              + (faces.map { "; faces: \($0.ok) photos" } ?? "")
              + (identities.isEmpty ? "" : "; identities rebuilt: " + identities.map { "\($0.name) \($0.matches.values.reduce(0, +))" }.joined(separator: ", "))
              + (images.map { "; embedded \($0.ok)" } ?? ""))
    }
}
