import ArgumentParser
import Foundation
import LightboxKit

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Run the cheap tier (Apple Vision + pixel statistics) on photos that need it.",
        discussion: """
            Looks only at pixels already on this Mac; nothing is downloaded unless you pass \
            --fetch-shared, which fetches previews for photos in shared albums only. Photos whose \
            originals are still in iCloud are marked as waiting and retried on the next run. \
            Safe to interrupt: at most one batch of work is lost. Run `lightbox index` first. \
            For a whole library, build with `swift build -c release`; the debug build is several times slower.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Option(help: "Stop after this many photos.")
    var limit: Int?

    @Option(help: "Photos analyzed concurrently.")
    var workers = 8

    @Option(help: "Smallest acceptable local rendition (long side, px). Smaller ones wait for the original.")
    var minSide = 512

    @Flag(help: "Skip photos already marked as waiting for pixels.")
    var skipWaiting = false

    @Flag(help: "Download previews of shared-album photos to analyze them (they never come down with \"Download Originals\"; a few hundred KB each). Library originals are still never downloaded.")
    var fetchShared = false

    func run() async throws {
        try await requirePhotosAccess()
        let index = try options.openIndex()
        var settings = AnalysisRunner.Options()
        settings.workers = workers
        settings.minSide = minSide
        settings.limit = limit
        settings.includeWaiting = !skipWaiting
        settings.fetchShared = fetchShared

        let showProgress = !options.json && isatty(STDERR_FILENO) != 0
        let result = try await AnalysisRunner(index: index).run(settings) { p in
            guard showProgress else { return }
            let eta = p.secondsLeft.map { " ETA \(Self.duration($0))" } ?? ""
            let line = "\r\(p.done)/\(p.total)  ok \(p.ok)  waiting \(p.waitingForPixels)  failed \(p.failed)  "
                + String(format: "%.1f/s", p.rate) + eta + "   "
            FileHandle.standardError.write(Data(line.utf8))
        }
        if showProgress { FileHandle.standardError.write(Data("\n".utf8)) }

        if options.json { return try printJSON(result) }
        print("analyzed \(result.done) in \(Self.duration(result.seconds)): \(result.ok) ok, "
              + "\(result.waitingForPixels) waiting for pixels, \(result.failed) failed")
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? "\(s / 3600)h\(s % 3600 / 60)m" : s >= 60 ? "\(s / 60)m\(s % 60)s" : "\(s)s"
    }
}
