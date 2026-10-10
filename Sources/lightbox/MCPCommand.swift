import ArgumentParser
import Foundation
import ImageIO
import LightboxKit
import LightboxModels
import MCP

/// `lightbox mcp`: the same index and searches, as tools for Claude (Claude Desktop, Claude
/// Code) over MCP's stdio transport.
///
/// Every tool is read-only: nothing here deletes, edits or writes to Photos. Photos reach
/// the model as contact sheets (twenty to an image, numbered), which is how a model looks
/// through a library without spending its context on single photos. Photos sent this way
/// leave the Mac for the model provider, unlike everything else lightbox does.
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve lightbox's searches as MCP tools over stdio (for Claude Desktop or Claude Code).",
        discussion: """
            Claude Desktop: add to ~/Library/Application Support/Claude/claude_desktop_config.json
              "lightbox": { "command": "\(NSHomeDirectory())/.local/bin/lightbox", "args": ["mcp"] }
            Claude Code: claude mcp add lightbox -- ~/.local/bin/lightbox mcp
            Read-only. Never print to stdout here: stdout is the protocol.
            """
    )

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await requirePhotosAccess()
        let tools = PhotoTools(index: try options.openIndex())
        let server = Server(
            name: "lightbox",
            version: Lightbox.configuration.version,
            title: "lightbox (Apple Photos)",
            instructions: PhotoTools.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: PhotoTools.definitions) }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                return try await tools.call(params.name, params.arguments ?? [:])
            } catch {
                return .init(content: [.text(text: "\(error)", annotations: nil, _meta: nil)], isError: true)
            }
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}

/// The tools. An actor, because the index is one SQLite connection and tool calls can overlap.
actor PhotoTools {
    private let index: LibraryIndex
    private var siglip: SigLIP2?

    init(index: LibraryIndex) {
        self.index = index
    }

    static let instructions = """
        lightbox searches the user's Apple Photos library on their Mac, including photos from iCloud \
        shared albums (other people's photos shared with them; scope "shared"). Typical flow: \
        search_photos (each result has a number and an id; a contact sheet shows the numbered photos), \
        then show_photo for a closer look at one. `faces` finds people by face, also in shared albums, \
        using identities listed by list_people; `people` filters on Photos' own People names (library only). \
        `about` ranks by a plain-language description. Use distinct_minutes to avoid ten frames of one moment. \
        All tools are read-only.
        """

    // MARK: Definitions

    static var definitions: [Tool] {
        let readOnly = Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        func string(_ about: String, _ options: [String]? = nil) -> Value {
            var schema: [String: Value] = ["type": "string", "description": .string(about)]
            if let options { schema["enum"] = .array(options.map(Value.string)) }
            return .object(schema)
        }
        func strings(_ about: String) -> Value { .object(["type": "array", "items": ["type": "string"], "description": .string(about)]) }
        func number(_ about: String) -> Value { .object(["type": "number", "description": .string(about)]) }
        func integer(_ about: String) -> Value { .object(["type": "integer", "description": .string(about)]) }
        func flag(_ about: String) -> Value { .object(["type": "boolean", "description": .string(about)]) }

        return [
            Tool(name: "search_photos", title: "Search photos",
                 description: "Find photos by description, person, face, quality, place in an album, labels and date. Returns a numbered list (id, date, scores, Photos' caption) and contact sheets of the results.",
                 inputSchema: .object(["type": "object", "properties": .object([
                    "about": string("Plain-language description, e.g. \"dinner at a long table outdoors\". Results come best match first."),
                    "faces": strings("Identities recognised by face (see list_people), e.g. [\"me\"]. Works in shared albums too."),
                    "include_maybe_faces": flag("With faces: also count likely matches (about 1% false matches instead of 0.1%)."),
                    "people": strings("People names from Photos (library only; all must be in the photo)."),
                    "alone": flag("With people: nobody else's face in the photo."),
                    "group_size": string("Main faces in the photo (passers-by ignored).", ["none", "solo", "group", "any"]),
                    "eyes_open": flag("Every main face has open eyes."),
                    "scope": string("library = the user's own photos; shared = iCloud shared albums; all = both (default).", ["all", "library", "shared"]),
                    "albums": strings("Album titles (regular or shared); all must contain the photo."),
                    "labels": strings("Vision scene labels that must be present, e.g. beach, dog, food."),
                    "text": string("Text in Photos' caption, title, labels or keywords."),
                    "from": string("Start date: YYYY, YYYY-MM or YYYY-MM-DD."),
                    "to": string("End date, exclusive."),
                    "min_aesthetic": number("Vision aesthetics, -1 to 1 (0.3 decent, 0.6 strong)."),
                    "min_face_area": number("Largest face covers at least this fraction of the frame (0.03 portrait, 0.15 close-up)."),
                    "min_face_quality": number("Vision face capture quality, 0 to 1."),
                    "min_apple_score": number("Photos' own aesthetic score, about 0 to 1."),
                    "favorites": flag("Favourites only."),
                    "include_utility": flag("Include screenshots, receipts and documents (left out by default)."),
                    "sort": string("Ignored when `about` is given.", ["newest", "oldest", "aesthetic", "face-quality", "sharpness", "apple", "random"]),
                    "distinct_minutes": number("At most one photo per this many minutes."),
                    "limit": integer("Results, 1 to 60 (default 20)."),
                    "offset": integer("Skip this many results (paging)."),
                    "contact_sheet": flag("Include contact sheets (default true)."),
                 ])]),
                 annotations: readOnly),
            Tool(name: "show_photo", title: "Show one photo",
                 description: "One photo larger, with everything known about it: date, place, albums, people, Vision signals, Photos' caption and scores.",
                 inputSchema: .object(["type": "object", "properties": .object([
                    "id": string("A local identifier or UUID from search_photos."),
                    "size": integer("Long side in pixels, 512 to 1536 (default 1024)."),
                 ]), "required": ["id"]]),
                 annotations: readOnly),
            Tool(name: "contact_sheet", title: "Contact sheet",
                 description: "A numbered contact sheet of specific photos, e.g. to compare a shortlist side by side.",
                 inputSchema: .object(["type": "object", "properties": .object([
                    "ids": strings("Local identifiers or UUIDs (up to 40)."),
                    "columns": integer("Photos per row (default 5; 2 or 3 for close comparison)."),
                 ]), "required": ["ids"]]),
                 annotations: readOnly),
            Tool(name: "list_people", title: "People",
                 description: "People named in Photos (most photographed first) and identities recognised by face (usable in search_photos `faces`, including shared albums).",
                 inputSchema: .object(["type": "object", "properties": .object([:])]),
                 annotations: readOnly),
            Tool(name: "list_albums", title: "Albums",
                 description: "The user's albums and the iCloud shared albums they belong to, biggest first.",
                 inputSchema: .object(["type": "object", "properties": .object([:])]),
                 annotations: readOnly),
            Tool(name: "library_stats", title: "Library",
                 description: "What the index holds: counts, years, how much is analysed, embedded and face-scanned.",
                 inputSchema: .object(["type": "object", "properties": .object([:])]),
                 annotations: readOnly),
        ]
    }

    // MARK: Calls

    func call(_ name: String, _ args: [String: Value]) async throws -> CallTool.Result {
        switch name {
        case "search_photos": return try await search(args)
        case "show_photo": return try await show(args)
        case "contact_sheet": return try await sheet(args)
        case "list_people": return try listPeople()
        case "list_albums": return try listAlbums()
        case "library_stats": return try stats()
        default: throw MCPError.methodNotFound("no tool \(name)")
        }
    }

    private func search(_ a: [String: Value]) async throws -> CallTool.Result {
        var q = PhotoQuery()
        q.about = a["about"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        q.faces = Self.strings(a["faces"])
        let known = Set(try index.identities().map { $0.name.lowercased() })
        if let unknown = q.faces.first(where: { !known.contains($0.lowercased()) }) {
            throw MCPError.invalidParams("no identity called \(unknown); list_people shows the ones that exist (\(known.sorted().joined(separator: ", ")))")
        }
        q.includeMaybeFaces = a["include_maybe_faces"]?.boolValue ?? false
        q.persons = Self.strings(a["people"])
        q.alone = a["alone"]?.boolValue ?? false
        q.people = a["group_size"]?.stringValue.flatMap(PhotoQuery.People.init(rawValue:))
        q.eyesOpen = a["eyes_open"]?.boolValue ?? false
        q.scope = a["scope"]?.stringValue.flatMap(PhotoQuery.Scope.init(rawValue:)) ?? .all
        q.albums = Self.strings(a["albums"])
        q.labels = Self.strings(a["labels"])
        q.text = a["text"]?.stringValue
        q.from = try a["from"]?.stringValue.map(parseDate)
        q.to = try a["to"]?.stringValue.map(parseDate)
        q.minAesthetic = Self.number(a["min_aesthetic"])
        q.minFaceArea = Self.number(a["min_face_area"])
        q.minFaceQuality = Self.number(a["min_face_quality"])
        q.minAppleScore = Self.number(a["min_apple_score"])
        q.favoritesOnly = a["favorites"]?.boolValue ?? false
        q.excludeUtility = !(a["include_utility"]?.boolValue ?? false)
        q.sort = a["sort"]?.stringValue.flatMap(PhotoQuery.Sort.init(rawValue:)) ?? .newest
        q.distinctWithin = Self.number(a["distinct_minutes"]).map { $0 * 60 }
        q.limit = min(max(a["limit"]?.intValue ?? 20, 1), 60)
        q.offset = max(a["offset"]?.intValue ?? 0, 0)

        var vector: [Float]?
        var model: String?
        if let about = q.about {
            let embedder = try await textEmbedder()
            vector = try embedder.embed(texts: [about]).first
            model = embedder.model
        }
        let result = try index.search(q, aboutVector: vector, aboutModel: model)
        var lines = result.hits.enumerated().map { n, hit in
            let caption = hit.apple?.caption ?? hit.signals?.labels.prefix(4).map(\.identifier).joined(separator: ", ") ?? ""
            let where_ = hit.asset.isShared ? " shared" : ""
            return "#\(q.offset + n + 1) \(hit.asset.id)\(where_) \(Tile.caption(hit))\(hit.relevance.map { String(format: " r%.3f", $0) } ?? "") — \(caption)"
        }
        lines.insert("\(result.hits.count) photo\(result.hits.count == 1 ? "" : "s")" + (result.hits.count == q.limit ? " (more with offset \(q.offset + q.limit))" : ""), at: 0)
        if result.unanalyzedImages > 0 { lines.append("\(result.unanalyzedImages) photos aren't analysed yet, so filters needing analysis skip them.") }
        if result.unembeddedImages > 0 { lines.append("\(result.unembeddedImages) matching photos have no image vector yet.") }
        lines.append("Scores: A = Photos' aesthetic, a = Vision aesthetic, q = best face quality, e = least-open eye (under 0.15 is a blink), r = match to `about`.")

        var content: [Tool.Content] = [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)]
        if a["contact_sheet"]?.boolValue ?? true, !result.hits.isEmpty {
            content += try await sheets(result.hits.map { Tile.make($0) }, firstNumber: q.offset + 1, columns: 5)
        }
        return .init(content: content)
    }

    private func show(_ a: [String: Value]) async throws -> CallTool.Result {
        guard let key = a["id"]?.stringValue, let asset = try index.record(matching: key) else {
            throw MCPError.invalidParams("no photo with that id")
        }
        let side = min(max(a["size"]?.intValue ?? 1024, 512), 1536)
        struct About: Encodable {
            let asset: AssetRecord
            let albums: [String]
            let analysis: StoredSignals?
            let apple: AppleInfo?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(About(asset: asset, albums: try index.albumTitles(for: asset.id),
                                                             analysis: try index.signals(for: asset.id),
                                                             apple: try index.apple(for: asset.id))), as: UTF8.self)
        var content: [Tool.Content] = [.text(text: json, annotations: nil, _meta: nil)]
        if case .image(let image) = await ImageLoader().load(asset.id, maxSide: side, minSide: 1, network: asset.isShared),
           let jpeg = Self.jpeg(image, quality: 0.75) {
            content.append(.image(data: jpeg.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil))
        } else {
            content.append(.text(text: "No local pixels for this photo.", annotations: nil, _meta: nil))
        }
        return .init(content: content)
    }

    private func sheet(_ a: [String: Value]) async throws -> CallTool.Result {
        let tiles = try Self.strings(a["ids"]).prefix(40).map { key -> ContactSheet.Tile in
            guard let asset = try index.record(matching: key) else { throw MCPError.invalidParams("not in the index: \(key)") }
            return Tile.make(PhotoHit(asset: asset, signals: try index.signals(for: asset.id)?.signals, apple: try index.apple(for: asset.id)))
        }
        guard !tiles.isEmpty else { throw MCPError.invalidParams("no ids") }
        let key = tiles.enumerated().map { "#\($0.offset + 1) \($0.element.id) \($0.element.caption)" }.joined(separator: "\n")
        let images = try await sheets(Array(tiles), firstNumber: 1, columns: min(max(a["columns"]?.intValue ?? 5, 1), 6))
        return .init(content: [.text(text: key, annotations: nil, _meta: nil)] + images)
    }

    private func listPeople() throws -> CallTool.Result {
        var lines = ["Identities recognised by face (use in search_photos `faces`; they also cover shared albums):"]
        for identity in try index.identities() {
            let matches = identity.matches.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            lines.append("- \(identity.name) (Photos' \(identity.person)): \(matches) photos; finds \(Int((identity.recallSure * 100).rounded()))% of their faces")
        }
        lines.append("\nPeople named in Photos (use in search_photos `people`; library only), photos each:")
        lines += try index.people().map { "- \($0.name): \($0.photos)" }
        return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    private func listAlbums() throws -> CallTool.Result {
        let lines = try index.albums().map { "- \($0.title) (\($0.kind == .shared ? "shared, " : "")\($0.count))" }
        return .init(content: [.text(text: lines.isEmpty ? "No albums indexed." : lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    private func stats() throws -> CallTool.Result {
        struct Output: Encodable {
            let stats: LibraryIndex.Stats
            let analysis: LibraryIndex.AnalysisCoverage
            let faces: LibraryIndex.VectorCoverage
            let embeddings: LibraryIndex.VectorCoverage
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(Output(stats: try index.stats(),
                                             analysis: try index.analysisCoverage(version: VisionAnalyzer.version),
                                             faces: try index.vectorCoverage(model: "arcface-r50"),
                                             embeddings: try index.vectorCoverage(model: "siglip2-b16")))
        return .init(content: [.text(text: String(decoding: json, as: UTF8.self), annotations: nil, _meta: nil)])
    }

    // MARK: Helpers

    /// Loaded on the first `about` search and kept: loading the text model takes a couple of seconds.
    private func textEmbedder() async throws -> SigLIP2 {
        if let siglip { return siglip }
        let loaded = try await SigLIP2()
        siglip = loaded
        return loaded
    }

    /// Twenty tiles to a sheet, sized for a model's image budget: about 1400 px wide (models
    /// downscale past ~1568 anyway) and under 500 KB, inside the ~1 MB chat clients allow per
    /// tool result. At 1500 px and quality 0.75 a busy sheet reached 626 KB.
    private func sheets(_ tiles: [ContactSheet.Tile], firstNumber: Int, columns: Int) async throws -> [Tool.Content] {
        var sheet = ContactSheet()
        sheet.columns = columns
        sheet.tileSize = columns <= 3 ? 440 : 280
        sheet.jpegQuality = 0.7
        var content: [Tool.Content] = []
        for start in stride(from: 0, to: tiles.count, by: 20) {
            let chunk = Array(tiles[start..<min(start + 20, tiles.count)])
            let rendered = try await sheet.render(chunk, firstNumber: firstNumber + start)
            content.append(.image(data: rendered.jpeg.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil))
        }
        return content
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func strings(_ value: Value?) -> [String] {
        if let list = value?.arrayValue { return list.compactMap(\.stringValue) }
        if let one = value?.stringValue, !one.isEmpty { return [one] }
        return []
    }

    static func number(_ value: Value?) -> Double? {
        value?.doubleValue ?? value?.intValue.map(Double.init)
    }
}
