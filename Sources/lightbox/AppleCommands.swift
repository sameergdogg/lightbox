import ArgumentParser
import Foundation
import LightboxKit

struct ImportAppleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-apple",
        abstract: "Import Photos' own analysis (People, scores, faces, captions) through osxphotos.",
        discussion: """
            Needs osxphotos (https://github.com/RhetTbull/osxphotos), e.g. `uv tool install osxphotos`, \
            and read access to the Photos library (Full Disk Access or Photos access for your terminal). \
            Reads Photos' database read-only; nothing is written to it. Re-run any time; it replaces \
            what was imported before. Run `lightbox index` first so new photos can be matched.
            """
    )

    @OptionGroup var options: GlobalOptions

    @Option(help: "Path to the osxphotos executable (default: found on PATH or in ~/.local/bin).")
    var osxphotos: String?

    @Option(help: "The Photos library to read (default: ~/Pictures/Photos Library.photoslibrary). osxphotos can't discover it by itself on macOS 27.")
    var library = "~/Pictures/Photos Library.photoslibrary"

    func run() async throws {
        let executable = try locateOsxphotos()
        let script = FileManager.default.temporaryDirectory.appending(path: "lightbox-apple-\(UUID().uuidString).py")
        try AppleImport.osxphotosScript.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["run", script.path]
        let libraryPath = (library as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw ValidationError("no Photos library at \(libraryPath); pass --library <path to .photoslibrary>")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["LIGHTBOX_PHOTOS_LIBRARY"] = libraryPath
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let showProgress = !options.json && isatty(STDERR_FILENO) != 0
        let records = output.fileHandleForReading.bytes.lines.compactMap { try? AppleImport.Record.decode($0) }
        let report = try await options.openIndex().importApple(records) { read in
            if showProgress { FileHandle.standardError.write(Data("\rread \(read)".utf8)) }
        }
        process.waitUntilExit()
        if showProgress { FileHandle.standardError.write(Data("\r".utf8)) }

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ValidationError("osxphotos failed (\(process.terminationStatus)):\n\(message.suffix(2_000))")
        }
        if options.json { return try printJSON(report) }
        print("imported Apple data for \(report.stored) photos in \(Int(report.seconds))s "
              + "(\(report.unmatched) not in the index, \(report.removed) stale entries removed)")
    }

    private func locateOsxphotos() throws -> URL {
        if let osxphotos { return URL(fileURLWithPath: (osxphotos as NSString).expandingTildeInPath) }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in path + [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin"] {
            let candidate = URL(fileURLWithPath: dir).appending(path: "osxphotos")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw ValidationError("osxphotos not found. Install it with `uv tool install osxphotos` (or pipx), or pass --osxphotos <path>.")
    }
}

struct PeopleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "people",
        abstract: "List the people named in Photos, most photographed first (after import-apple)."
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let people = try options.openIndex().people()
        if options.json { return try printJSON(people) }
        if people.isEmpty { print("no People data; run `lightbox import-apple`") }
        for person in people { print("\(String(person.photos).padding(toLength: 7, withPad: " ", startingAt: 0)) \(person.name)") }
    }
}

struct AlbumsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "albums",
        abstract: "List albums, your own and iCloud shared ones, biggest first."
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let albums = try options.openIndex().albums()
        if options.json { return try printJSON(albums) }
        if albums.isEmpty { print("no albums indexed; run `lightbox index`") }
        for a in albums {
            print("\(String(a.count).padding(toLength: 7, withPad: " ", startingAt: 0)) \(a.kind == .shared ? "shared " : "       ") \(a.title)")
        }
    }
}
