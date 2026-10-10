import Foundation
import Testing
@testable import LightboxKit

/// Fictional names only; this is a public repo.
@Suite struct AppleImportTests {
    static func line(_ n: Int, overall: Double, people: [String], faces: [(String?, Int)],
                     caption: String? = nil, labels: [String] = []) -> String {
        let uuid = photo(n).uuid
        let faceJSON = faces.map { name, eye in
            "{\"n\":\(name.map { "\"\($0)\"" } ?? "null"),\"x\":0.5,\"y\":0.5,\"z\":0.2,\"q\":0.6,\"e\":\(eye),\"m\":2,\"h\":true,\"yaw\":0,\"pitch\":0,\"roll\":0}"
        }.joined(separator: ",")
        let peopleJSON = people.map { "\"\($0)\"" }.joined(separator: ",")
        let labelJSON = labels.map { "\"\($0)\"" }.joined(separator: ",")
        return """
            {"u":"\(uuid.lowercased())","s":{"overall":\(overall),"well_framed_subject":0.3},"p":[\(peopleJSON)],\
            "f":[\(faceJSON)],"l":[\(labelJSON)],"c":\(caption.map { "\"\($0)\"" } ?? "null"),"t":null,"d":null,"k":["trip"]}
            """
    }

    static func stream(_ lines: [String]) -> AsyncThrowingStream<AppleImport.Record, any Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(try! AppleImport.Record.decode(line)) }
            continuation.finish()
        }
    }

    static func fixture() async throws -> LibraryIndex {
        let index = try LibraryIndex.inMemory()
        try index.upsert((1...6).map { photo($0) })
        let open = AppleImport.EyeState.open.rawValue, closed = AppleImport.EyeState.closed.rawValue
        let report = try await index.importApple(stream([
            line(1, overall: 0.8, people: ["Alice"], faces: [("Alice", open)], caption: "a woman on a beach"),
            line(2, overall: 0.6, people: ["Alice"], faces: [("Alice", closed)]),                    // blinking
            line(3, overall: 0.7, people: ["Alice", "Bob"], faces: [("Alice", open), ("Bob", open)]),
            line(4, overall: 0.9, people: ["Alice"], faces: [("Alice", open), (nil, open)]),        // a stranger too
            line(5, overall: 0.2, people: [], faces: [], labels: ["Beach", "Sky"]),
            line(99, overall: 0.5, people: ["Carol"], faces: [("Carol", open)]),                    // not in the index
        ]))
        #expect(report.read == 6 && report.stored == 5 && report.unmatched == 1)
        return index
    }

    func ids(_ index: LibraryIndex, _ configure: (inout PhotoQuery) -> Void) throws -> [Int] {
        var query = PhotoQuery()
        configure(&query)
        return try index.search(query).hits.map { Int($0.asset.id.prefix(8), radix: 16) ?? -1 }
    }

    @Test func importsScoresPeopleFacesAndCaptions() async throws {
        let index = try await Self.fixture()
        let info = try #require(try index.apple(for: photo(3).id))
        #expect(info.overall == 0.7)
        #expect(info.scores["well_framed_subject"] == 0.3)
        #expect(info.people == ["Alice", "Bob"])
        #expect(info.faces.count == 2 && info.faces[0].eyeState == 2)
        #expect(info.keywords == ["trip"])
        #expect(try index.people().map(\.name) == ["Alice", "Bob"])
        #expect(try index.people().first?.photos == 4)
    }

    @Test func personAloneAndEyesWorkWithoutLightboxAnalysis() async throws {
        let index = try await Self.fixture()   // no signals at all
        #expect(try Set(ids(index) { $0.persons = ["alice"] }) == [1, 2, 3, 4], "names match case-insensitively")
        #expect(try Set(ids(index) { $0.persons = ["Alice", "Bob"] }) == [3])
        #expect(try Set(ids(index) { $0.persons = ["Alice"]; $0.alone = true }) == [1, 2])
        #expect(try Set(ids(index) { $0.persons = ["Alice"]; $0.alone = true; $0.eyesOpen = true }) == [1])
        #expect(try ids(index) { $0.persons = ["Alice"]; $0.sort = .apple } == [4, 1, 3, 2])
        #expect(try Set(ids(index) { $0.minAppleScore = 0.75 }) == [1, 4])
    }

    @Test func textSearchesCaptionsAndLabels() async throws {
        let index = try await Self.fixture()
        #expect(try Set(ids(index) { $0.text = "beach" }) == [1, 5])
        #expect(try Set(ids(index) { $0.text = "TRIP" }) == [1, 2, 3, 4, 5])
    }

    @Test func lightboxEyeMeasureCanStillVetoAPersonSearch() async throws {
        let index = try await Self.fixture()
        var signals = QueryTests.signals(faces: [QueryTests.face(area: 0.06, eyes: 0.05)])
        signals.humans = 1
        try index.saveSignals([(photo(1).id, .ok(signals))], version: VisionAnalyzer.version)
        #expect(try ids(index) { $0.persons = ["Alice"]; $0.alone = true; $0.eyesOpen = true }.isEmpty)
    }

    @Test func reimportReplacesAndDropsStaleRows() async throws {
        let index = try await Self.fixture()
        let report = try await index.importApple(Self.stream([
            Self.line(1, overall: 0.1, people: ["Dana"], faces: [("Dana", 2)]),
        ]))
        #expect(report.removed == 4)
        #expect(try index.apple(for: photo(1).id)?.people == ["Dana"])
        #expect(try index.apple(for: photo(3).id) == nil)
        #expect(try index.people().map(\.name) == ["Dana"])
    }

    @Test func deletingAPhotoDeletesItsAppleData() async throws {
        let index = try await Self.fixture()
        try index.delete(ids: [photo(1).id])
        #expect(try index.apple(for: photo(1).id) == nil)
        #expect(try index.people().first?.photos == 3)
    }
}
