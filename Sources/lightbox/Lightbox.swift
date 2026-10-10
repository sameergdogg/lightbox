import ArgumentParser
import Foundation
import LightboxKit
import Photos

@main
struct Lightbox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lightbox",
        abstract: "Index and search an Apple Photos library for AI tools.",
        version: "0.1.0",
        subcommands: [IndexCommand.self, AnalyzeCommand.self, RefreshCommand.self, SearchCommand.self, SheetCommand.self, ImportAppleCommand.self, PeopleCommand.self, AlbumsCommand.self, StatsCommand.self, ShowCommand.self, DoctorCommand.self, MCPCommand.self, ModelsCommand.self, FacesCommand.self, IdentifyCommand.self, EmbedCommand.self, ProbeCommand.self]
    )
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .customLong("db"), help: "Index database path (default: ~/Library/Application Support/lightbox/index.sqlite).")
    var databasePath: String?

    @Flag(help: "Print JSON instead of text.")
    var json = false

    func openIndex() throws -> LibraryIndex {
        let url = databasePath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? LibraryIndex.defaultURL
        return try LibraryIndex(url: url)
    }
}

// MARK: index

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Bring the index up to date with the Photos library.",
        discussion: "Incremental after the first run: only photos added, edited or deleted since the last sync are read."
    )

    @OptionGroup var options: GlobalOptions

    @Flag(help: "Read the whole library and diff, ignoring the stored change token.")
    var full = false

    func run() async throws {
        try await requirePhotosAccess()
        let index = try options.openIndex()
        let indexer = Indexer(source: PhotoKitSource(), index: index)
        let showProgress = !options.json && isatty(STDERR_FILENO) != 0
        let report = try indexer.sync(forceFull: full) { done, expected in
            guard showProgress else { return }
            FileHandle.standardError.write(Data("\rreading \(done)/\(expected)".utf8))
        }
        if showProgress && report.mode == .full { FileHandle.standardError.write(Data("\n".utf8)) }

        if options.json { return try printJSON(report) }
        var line = "\(report.mode.rawValue) sync: \(report.inserted) added, \(report.updated) updated, "
            + "\(report.deleted) removed; \(report.total) in index (\(String(format: "%.1f", report.seconds)) s)"
        if let reason = report.fallbackReason { line += "\n  full sync because: \(reason)" }
        print(line)
    }
}

// MARK: stats

struct StatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stats", abstract: "Summarise what is in the index.")

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let index = try options.openIndex()
        let stats = try index.stats()
        let syncedAt = try index.metaString(.syncedAt)
        let coverage = try index.analysisCoverage(version: VisionAnalyzer.version)
        if options.json {
            struct Output: Encodable {
                let stats: LibraryIndex.Stats
                let analysis: LibraryIndex.AnalysisCoverage
                let syncedAt: String?
            }
            return try printJSON(Output(stats: stats, analysis: coverage, syncedAt: syncedAt))
        }
        let years = [stats.earliest, stats.latest].compactMap { $0 }
            .map { String(Calendar.current.component(.year, from: $0)) }.joined(separator: "–")
        print("""
            \(stats.total) items (\(stats.images) photos, \(stats.videos) videos) \(years), \(stats.shared) of them from shared albums
              favourites      \(stats.favorites)
              screenshots     \(stats.screenshots)
              Live Photos     \(stats.livePhotos)
              edited          \(stats.edited)
              with location   \(stats.withLocation)
              hidden          \(stats.hidden)
              burst frames    \(stats.burstFrames) (\(stats.hiddenBurstFrames) not shown by Photos)
            last sync: \(syncedAt ?? "never")
            analysis (v\(VisionAnalyzer.version)): \(coverage.ok) done, \(coverage.waitingForPixels) waiting for pixels, \
            \(coverage.failed) failed, \(coverage.outdated) outdated, \(coverage.notYet) not yet
            """)
    }
}

// MARK: show

struct ShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print one item's metadata and analysis as JSON.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Local identifier or UUID.")
    var id: String

    func run() throws {
        let index = try options.openIndex()
        guard let record = try index.record(matching: id) else {
            throw ValidationError("not in the index: \(id)")
        }
        struct Output: Encodable { let asset: AssetRecord; let albums: [String]; let analysis: StoredSignals?; let apple: AppleInfo? }
        try printJSON(Output(asset: record, albums: try index.albumTitles(for: record.id),
                             analysis: try index.signals(for: record.id), apple: try index.apple(for: record.id)))
    }
}

// MARK: doctor

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check Photos access, index coverage, and how many items default PhotoKit lookups miss."
    )

    @OptionGroup var options: GlobalOptions

    struct Report: Encodable {
        var authorization: String
        var libraryCount: Int
        var indexCount: Int
        var resolvableWithLightboxOptions: Int
        var resolvableWithDefaultOptions: Int
        var hiddenBurstFramesInIndex: Int
        var hiddenInIndex: Int
    }

    func run() async throws {
        try await requirePhotosAccess()
        let index = try options.openIndex()
        let source = PhotoKitSource()
        let ids = try index.allIDs()
        let stats = try index.stats()
        let report = Report(
            authorization: describe(PhotoKitSource.authorization),
            libraryCount: source.assetCount,
            indexCount: ids.count,
            resolvableWithLightboxOptions: try source.records(for: ids).count,
            resolvableWithDefaultOptions: source.countResolvableWithDefaultOptions(ids),
            hiddenBurstFramesInIndex: stats.hiddenBurstFrames,
            hiddenInIndex: stats.hidden
        )
        if options.json { return try printJSON(report) }
        let missedByDefault = report.indexCount - report.resolvableWithDefaultOptions
        print("""
            Photos access        \(report.authorization)
            library items        \(report.libraryCount)
            indexed items        \(report.indexCount)\(report.indexCount == report.libraryCount ? "" : "  (run `lightbox index`)")
            found by id          \(report.resolvableWithLightboxOptions) with lightbox's fetch options
            found by id          \(report.resolvableWithDefaultOptions) with PhotoKit defaults (\(missedByDefault) missed)
              of which, burst frames Photos doesn't show: \(report.hiddenBurstFramesInIndex); hidden album: \(report.hiddenInIndex)
            """)
    }
}

// MARK: Helpers

func requirePhotosAccess() async throws {
    await MainActor.run { PhotoKitSource.prepareCommandLineProcess() }
    var status = PhotoKitSource.authorization
    if status == .notDetermined { status = await PhotoKitSource.requestAuthorization() }
    guard status == .authorized else {
        throw ValidationError("""
            Photos access is \(describe(status)). Allow it in System Settings › Privacy & Security › Photos \
            for the app running this command (your terminal), with Full Access, then run it again.
            """)
    }
}

func describe(_ status: PHAuthorizationStatus) -> String {
    switch status {
    case .authorized: "full access"
    case .limited: "limited"
    case .denied: "denied"
    case .restricted: "restricted"
    case .notDetermined: "not yet asked"
    @unknown default: "unknown"
    }
}

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}
