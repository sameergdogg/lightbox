import ArgumentParser
import Foundation
import LightboxKit
import LightboxModels

extension ModelStore.Model: ExpressibleByArgument {}

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List the model weights lightbox can use, or download one.",
        discussion: """
            Weights are never bundled. `lightbox models pull arcface` fetches InsightFace's face \
            model, whose weights are licensed for non-commercial use only; `pull siglip2` fetches \
            Google's SigLIP 2 (Apache-2.0) for plain-language search.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "pull")
    var action: String?

    @Argument(help: "arcface | siglip2")
    var model: ModelStore.Model?

    func run() async throws {
        let store = ModelStore()
        switch (action, model) {
        case (nil, _):
            for model in ModelStore.Model.allCases {
                print("\(store.isInstalled(model) ? "installed" : "missing  ")  \(model.rawValue)  \(model.about)")
            }
        case ("pull"?, let model?):
            print(model.about)
            try await store.pull(model) { print($0) }
            print("\(model.rawValue) installed in \(store.root.path)")
        default:
            throw ValidationError("usage: lightbox models [pull arcface|siglip2]")
        }
    }
}

struct FacesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "faces",
        abstract: "Compute face identity vectors (ArcFace) for photos where Vision found faces.",
        discussion: """
            Needs `lightbox analyze` first (it decides which photos have faces) and \
            `lightbox models pull arcface`. Resumable; at most one batch is lost if stopped. \
            Add --fetch-shared to include photos from shared albums whose previews aren't on this Mac.
            """
    )

    @OptionGroup var options: GlobalOptions
    @Option(help: "all | library | shared") var scope: PhotoQuery.Scope = .all
    @Option(help: "Stop after this many photos.") var limit: Int?
    @Option(help: "Photos in flight at once.") var workers = 8
    @Flag(help: "Download previews of shared-album photos that aren't on this Mac yet.") var fetchShared = false

    func run() async throws {
        try await requirePhotosAccess()
        let index = try options.openIndex()
        let embedder = try ArcFace()
        var settings = VectorRunner.Options()
        settings.scope = scope
        settings.limit = limit
        settings.workers = workers
        settings.fetchShared = fetchShared
        let result = try await VectorRunner(index: index).faces(embedder, options: settings, progress: progressLine(options))
        finishProgress(options)
        let coverage = try index.vectorCoverage(model: embedder.model)
        if options.json { return try printJSON(coverage) }
        print("looked at \(result.done) photos in \(AnalyzeCommand.duration(result.seconds)): \(result.ok) ok, "
              + "\(result.waitingForPixels) waiting for pixels, \(result.failed) failed")
        print("\(coverage.faces) face vectors in \(coverage.ok) photos (\(embedder.model))")
    }
}

struct IdentifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identify",
        abstract: "Recognise a person everywhere, shared albums included, from the faces Photos has tagged.",
        discussion: """
            Builds a gallery from the faces Photos tagged with PERSON (needs `lightbox import-apple` \
            and `lightbox faces`), calibrates against everyone else Photos has named, and stores \
            matches. Then: lightbox search --face NAME --scope shared --sheet me.jpg
            """
    )

    @OptionGroup var options: GlobalOptions
    @Argument(help: "A People name from Photos.") var person: String
    @Option(name: .customLong("as"), help: "Name to search by (default: the person's name), e.g. me.") var name: String?

    func run() async throws {
        let index = try options.openIndex()
        let report = try Identity.build(index: index, person: person, name: name, model: "arcface-r50")
        if options.json { return try printJSON(report) }
        func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
        print("""
            \(report.name): \(report.taggedFaces) tagged faces of \(report.person); negatives: \(report.otherFaces) faces of \(report.otherPeople) other named people
            calibration on held-out faces (\(report.probes) of \(report.person), \(report.negativeProbes) of others): AUC \(String(format: "%.3f", report.auc))
              sure  (score < \(String(format: "%.3f", report.sure))): finds \(pct(report.recallSure)), others accepted \(pct(report.falseSure))
              maybe (score < \(String(format: "%.3f", report.maybe))): finds \(pct(report.recallMaybe)), others accepted \(pct(report.falseMaybe)) (\(pct(report.falseMaybeWithoutRule)) without the named-people rule)
            matched photos: \(report.matches.sorted { $0.key < $1.key }.map { "\($0.value) in \($0.key)" }.joined(separator: ", "))
            """)
    }
}

struct EmbedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "embed",
        abstract: "Compute image vectors (SigLIP 2) so `search --about \"…\"` can find photos by description.",
        discussion: "Needs `lightbox models pull siglip2`. Uses the small local renditions; resumable."
    )

    @OptionGroup var options: GlobalOptions
    @Option(help: "all | library | shared") var scope: PhotoQuery.Scope = .all
    @Option(help: "Stop after this many photos.") var limit: Int?
    @Option(help: "Photos in flight at once.") var workers = 8
    @Flag(help: "Download previews of shared-album photos that aren't on this Mac yet.") var fetchShared = false

    func run() async throws {
        try await requirePhotosAccess()
        let index = try options.openIndex()
        let embedder = try await SigLIP2()
        var settings = VectorRunner.Options()
        settings.scope = scope
        settings.limit = limit
        settings.workers = workers
        settings.fetchShared = fetchShared
        let result = try await VectorRunner(index: index).images(embedder, options: settings, progress: progressLine(options))
        finishProgress(options)
        if options.json { return try printJSON(result) }
        print("embedded \(result.ok) of \(result.done) photos in \(AnalyzeCommand.duration(result.seconds)) "
              + "(\(result.waitingForPixels) waiting for pixels, \(result.failed) failed)")
    }
}

func progressLine(_ options: GlobalOptions) -> (AnalysisRunner.Progress) -> Void {
    let show = !options.json && isatty(STDERR_FILENO) != 0
    return { p in
        guard show else { return }
        let eta = p.secondsLeft.map { " ETA \(AnalyzeCommand.duration($0))" } ?? ""
        FileHandle.standardError.write(Data(("\r\(p.done)/\(p.total)  ok \(p.ok)  waiting \(p.waitingForPixels)  failed \(p.failed)  "
            + String(format: "%.1f/s", p.rate) + eta + "   ").utf8))
    }
}

func finishProgress(_ options: GlobalOptions) {
    if !options.json && isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(Data("\n".utf8)) }
}
