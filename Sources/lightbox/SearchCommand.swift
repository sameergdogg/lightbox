import ArgumentParser
import Foundation
import LightboxKit
import LightboxModels

extension PhotoQuery.People: ExpressibleByArgument {}
extension PhotoQuery.Sort: ExpressibleByArgument {}
extension PhotoQuery.Scope: ExpressibleByArgument {}

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find photos by people, faces, quality, labels and date; optionally write contact sheets.",
        discussion: """
            Only analyzed photos can match (see `lightbox stats`). Examples:
              lightbox search --people solo --eyes-open --min-face-area 0.03 --sort aesthetic --distinct 30 --sheet ~/Desktop/portraits.jpg
              lightbox search --label beach --label sunset --from 2022 --sheet beach.jpg
              lightbox search --face me --scope shared --eyes-open --sheet ~/Desktop/me-shared.jpg
              lightbox search --about "dinner at a long table outdoors" --distinct 30
            """
    )

    @OptionGroup var options: GlobalOptions

    @Option(help: "none | solo | group | any (counts main faces, ignoring passers-by).")
    var people: PhotoQuery.People?

    @Option(name: .customLong("person"), help: "A People name from Photos (repeatable; all must be in the photo). See `lightbox people`.")
    var persons: [String] = []

    @Option(name: .customLong("face"), help: "Someone recognised by face, shared albums included (repeatable). See `lightbox identify`.")
    var faces: [String] = []

    @Flag(help: "With --face: also count likely matches (about 1% false matches instead of 0.1%).")
    var maybe = false

    @Option(help: "Describe the photo in plain words; results come best match first. Needs `lightbox embed`.")
    var about: String?

    @Flag(help: "Nobody else in the photo: Photos detected exactly as many faces as --person names (default 1).")
    var alone = false

    @Option(help: "Text in Apple's caption, title, labels or keywords (e.g. beach, wedding, dog).")
    var text: String?

    @Option(help: "Minimum Photos aesthetic score (Apple's own), roughly 0-1.")
    var minAppleScore: Double?

    @Option(name: .customLong("album"), help: "Only photos in this album, regular or shared (repeatable; all must match). See `lightbox albums`.")
    var albums: [String] = []

    @Option(help: "all | library | shared (photos from iCloud shared albums).")
    var scope: PhotoQuery.Scope = .all

    @Flag(help: "Every main face has open eyes.")
    var eyesOpen = false

    @Option(help: "Largest face covers at least this fraction of the frame (0.03 portrait, 0.15 close-up).")
    var minFaceArea: Double?

    @Option(help: "Minimum Vision face capture quality, 0-1.")
    var minFaceQuality: Double?

    @Option(help: "Minimum Vision aesthetics score, -1 to 1.")
    var minAesthetic: Double?

    @Option(help: "Minimum sharpness (Laplacian variance at 512 px; ~200 soft, ~1000+ crisp).")
    var minSharpness: Double?

    @Option(name: .customLong("label"), help: "Require a Vision scene label (repeatable), e.g. beach, dog, food.")
    var labels: [String] = []

    @Option(help: "Start date: YYYY, YYYY-MM or YYYY-MM-DD.")
    var from: String?

    @Option(help: "End date (exclusive): YYYY, YYYY-MM or YYYY-MM-DD.")
    var to: String?

    @Flag(help: "Favourites only.")
    var favorites = false

    @Flag(help: "Include screenshots, receipts and documents.")
    var includeUtility = false

    @Option(help: "newest | oldest | aesthetic | face-quality | sharpness | apple | random")
    var sort: PhotoQuery.Sort = .newest

    @Option(help: "At most one photo per this many minutes (skips the rest of the same shoot).")
    var distinct: Double?

    @Option(help: "Maximum results.")
    var limit = 40

    @Option(help: "Skip this many results (paging).")
    var offset = 0

    @Option(help: "Write contact sheets here (20 per sheet; extra sheets get -2, -3… and a .json key).")
    var sheet: String?

    func run() async throws {
        var query = PhotoQuery()
        query.people = people
        query.persons = persons
        query.alone = alone
        query.faces = faces
        query.includeMaybeFaces = maybe
        query.about = about
        query.text = text
        query.minAppleScore = minAppleScore
        query.albums = albums
        query.scope = scope
        query.eyesOpen = eyesOpen
        query.minFaceArea = minFaceArea
        query.minFaceQuality = minFaceQuality
        query.minAesthetic = minAesthetic
        query.minSharpness = minSharpness
        query.labels = labels
        query.from = try from.map(parseDate)
        query.to = try to.map(parseDate)
        query.favoritesOnly = favorites
        query.excludeUtility = !includeUtility
        query.sort = sort
        query.distinctWithin = distinct.map { $0 * 60 }
        query.limit = limit
        query.offset = offset

        var aboutVector: [Float]?
        var aboutModel: String?
        if let about {
            let embedder = try await SigLIP2()
            aboutVector = try embedder.embed(texts: [about]).first
            aboutModel = embedder.model
        }
        let result = try options.openIndex().search(query, aboutVector: aboutVector, aboutModel: aboutModel)
        var sheets: [String] = []
        if let sheet {
            try await requirePhotosAccess()
            sheets = try await writeSheets(result.hits.map { Tile.make($0) }, to: sheet, firstNumber: offset + 1)
        }

        if options.json {
            struct Output: Encodable { let result: SearchResult; let sheets: [String] }
            return try printJSON(Output(result: result, sheets: sheets))
        }
        for (n, hit) in result.hits.enumerated() {
            let about = hit.apple?.caption ?? hit.signals?.labels.prefix(4).map(\.identifier).joined(separator: ",") ?? ""
            let score = hit.relevance.map { String(format: "r%.3f  ", $0) } ?? ""
            print("#\(offset + n + 1)  \(hit.asset.id)  \(score)\(Tile.caption(hit))  \(about)")
        }
        print("\(result.hits.count) results" + (result.unanalyzedImages > 0
            ? " (\(result.unanalyzedImages) images not analyzed yet, so not searchable)" : "")
            + (result.unembeddedImages > 0 ? " (\(result.unembeddedImages) matching photos have no image vector yet; run `lightbox embed`)" : ""))
        for path in sheets { print("sheet: \(path)") }
    }
}

struct SheetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sheet",
        abstract: "Write a contact sheet for specific photos (ids or UUIDs)."
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .shortAndLong, help: "Output JPEG path.")
    var output: String

    @Option(help: "Photos per row (e.g. 2 or 4 to show photos in pairs).")
    var columns = 5

    @Argument(help: "Local identifiers or UUIDs.")
    var ids: [String]

    func run() async throws {
        try await requirePhotosAccess()
        let index = try options.openIndex()
        let tiles = try ids.map { key -> ContactSheet.Tile in
            guard let asset = try index.record(matching: key) else { throw ValidationError("not in the index: \(key)") }
            return Tile.make(PhotoHit(asset: asset, signals: try index.signals(for: asset.id)?.signals,
                                      apple: try index.apple(for: asset.id)))
        }
        let paths = try await writeSheets(tiles, to: output, firstNumber: 1, columns: columns)
        if options.json { return try printJSON(paths) }
        for path in paths { print("sheet: \(path)") }
    }
}

enum Tile {
    static func make(_ hit: PhotoHit) -> ContactSheet.Tile {
        ContactSheet.Tile(id: hit.asset.id, caption: caption(hit))
    }

    /// "2023-05-14 A.48 a.62 q.71 e.27": date, Apple's score, Vision aesthetics, best face
    /// quality, least-open eye. Whatever is known.
    static func caption(_ hit: PhotoHit) -> String {
        var parts: [String] = []
        if let date = hit.asset.created { parts.append(dateFormatter.string(from: date)) }
        if let apple = hit.apple?.overall { parts.append("A" + short(apple)) }
        if let s = hit.signals {
            if let a = s.aesthetic { parts.append("a" + short(a)) }
            if let q = s.bestFaceQuality { parts.append("q" + short(q)) }
            if let e = s.minEyeOpenness { parts.append("e" + short(e)) }
        }
        return parts.joined(separator: " ")
    }

    private static func short(_ value: Double) -> String {
        String(format: "%.2f", value).replacingOccurrences(of: "0.", with: ".")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Splits into sheets of 20 and writes `path`, `path-2`, … plus `path.json` with the key.
func writeSheets(_ tiles: [ContactSheet.Tile], to path: String, firstNumber: Int, columns: Int = 5) async throws -> [String] {
    let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
    let stem = base.deletingPathExtension().path
    let ext = base.pathExtension.isEmpty ? "jpg" : base.pathExtension
    var written: [String] = []
    var key: [ContactSheet.Entry] = []
    for (page, start) in stride(from: 0, to: tiles.count, by: 20).enumerated() {
        let chunk = Array(tiles[start..<min(start + 20, tiles.count)])
        var sheet = ContactSheet()
        sheet.columns = columns
        let rendered = try await sheet.render(chunk, firstNumber: firstNumber + start)
        let out = page == 0 ? "\(stem).\(ext)" : "\(stem)-\(page + 1).\(ext)"
        try rendered.jpeg.write(to: URL(fileURLWithPath: out))
        written.append(out)
        key += rendered.key
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(key).write(to: URL(fileURLWithPath: "\(stem).json"))
    return written
}

/// YYYY, YYYY-MM or YYYY-MM-DD, local time.
func parseDate(_ text: String) throws -> Date {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard (1...3).contains(parts.count), parts.count == text.split(separator: "-").count,
          let date = Calendar.current.date(from: DateComponents(
              year: parts[0], month: parts.count > 1 ? parts[1] : 1, day: parts.count > 2 ? parts[2] : 1))
    else { throw ValidationError("not a date: \(text) (use YYYY, YYYY-MM or YYYY-MM-DD)") }
    return date
}
