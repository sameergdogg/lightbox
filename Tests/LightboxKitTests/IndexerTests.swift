import Foundation
import Testing
@testable import LightboxKit

/// A library in memory with a change log, so incremental sync can be exercised without
/// PhotoKit. Tokens are change-log positions.
final class FakeSource: AssetSource {
    var assets: [String: AssetRecord] = [:]
    private var log: [(position: Int, changes: ChangeSet)] = []
    private var position = 0
    /// Tokens older than this report `unavailable`, like Photos pruning its history.
    var oldestValidToken = 0
    private(set) var recordsRequested = 0

    init(_ records: [AssetRecord] = []) {
        for record in records { assets[record.id] = record }
    }

    func add(_ records: [AssetRecord]) {
        for record in records { assets[record.id] = record }
        commit(ChangeSet(inserted: Set(records.map(\.id))))
    }

    func update(_ records: [AssetRecord]) {
        for record in records { assets[record.id] = record }
        commit(ChangeSet(updated: Set(records.map(\.id))))
    }

    func remove(_ ids: [String]) {
        for id in ids { assets[id] = nil }
        commit(ChangeSet(deleted: Set(ids)))
    }

    private func commit(_ changes: ChangeSet) {
        position += 1
        log.append((position, changes))
    }

    /// Shared-album photos: in `assets`, but never mentioned by the change log, the way
    /// Photos' history leaves them out.
    var shared = Set<String>()
    var albumList: [Album] = []

    func addShared(_ records: [AssetRecord]) {
        for record in records {
            var copy = record
            copy.sourceType = 2   // PHAssetSourceType.typeCloudShared
            assets[copy.id] = copy
            shared.insert(copy.id)
        }
    }

    func removeShared(_ ids: [String]) {
        for id in ids { assets[id] = nil; shared.remove(id) }
    }

    func sharedAssetIDs() throws -> Set<String> { shared }
    func albums() throws -> [Album] { albumList }

    var assetCount: Int { assets.count }

    func enumerateAll(batchSize: Int, _ body: ([AssetRecord]) throws -> Void) throws {
        let all = assets.values.sorted { $0.id < $1.id }
        recordsRequested += all.count
        for start in stride(from: 0, to: all.count, by: batchSize) {
            try body(Array(all[start..<min(start + batchSize, all.count)]))
        }
    }

    func records(for ids: [String]) throws -> [AssetRecord] {
        recordsRequested += ids.count
        return ids.compactMap { assets[$0] }
    }

    func currentChangeToken() -> Data? { Data(String(position).utf8) }

    func changes(since token: Data) throws -> ChangeResult {
        guard let since = Int(String(decoding: token, as: UTF8.self)), since >= oldestValidToken else {
            return .unavailable(reason: "expired")
        }
        var merged = ChangeSet()
        for entry in log where entry.position > since {
            merged.inserted.formUnion(entry.changes.inserted)
            merged.updated.formUnion(entry.changes.updated)
            merged.deleted.formUnion(entry.changes.deleted)
        }
        return .changes(merged)
    }
}

func photo(_ n: Int, modified: Double = 0, favorite: Bool = false) -> AssetRecord {
    AssetRecord(
        id: String(format: "%08X-0000-0000-0000-000000000000/L0/001", n),
        created: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(n) * 1.234567),
        modified: Date(timeIntervalSinceReferenceDate: 700_000_000 + modified),
        pixelWidth: 4032, pixelHeight: 3024,
        isFavorite: favorite
    )
}

@Suite struct IndexerTests {
    @Test func firstSyncIsFullAndInsertsEverything() throws {
        let source = FakeSource((0..<500).map { photo($0) })
        let index = try LibraryIndex.inMemory()
        let report = try Indexer(source: source, index: index).sync(batchSize: 64)
        #expect(report.mode == .full)
        #expect(report.inserted == 500)
        #expect(report.total == 500)
    }

    @Test func unchangedFullSyncWritesNothing() throws {
        let source = FakeSource((0..<300).map { photo($0) })
        let index = try LibraryIndex.inMemory()
        let indexer = Indexer(source: source, index: index)
        _ = try indexer.sync()
        let again = try indexer.sync(forceFull: true)
        #expect(again.mode == .full)
        #expect(again.touched == 0, "a full sync of an unchanged library must not rewrite rows")
    }

    /// The L1 acceptance criterion: ten new photos cost ten rows, not a library walk.
    @Test func tenNewPhotosTouchTenRows() throws {
        let source = FakeSource((0..<1_000).map { photo($0) })
        let index = try LibraryIndex.inMemory()
        let indexer = Indexer(source: source, index: index)
        _ = try indexer.sync()

        source.add((1_000..<1_010).map { photo($0) })
        let before = source.recordsRequested
        let report = try indexer.sync()
        #expect(report.mode == .incremental)
        #expect(report.inserted == 10)
        #expect(report.touched == 10)
        #expect(source.recordsRequested - before == 10)
        #expect(report.total == 1_010)
    }

    @Test func incrementalAppliesUpdatesAndDeletes() throws {
        let source = FakeSource((0..<50).map { photo($0) })
        let index = try LibraryIndex.inMemory()
        let indexer = Indexer(source: source, index: index)
        _ = try indexer.sync()

        source.update([photo(1, modified: 99, favorite: true), photo(2, modified: 99), photo(3, modified: 99)])
        source.remove([photo(10).id, photo(11).id])
        let report = try indexer.sync()
        #expect(report.mode == .incremental)
        #expect(report.updated == 3)
        #expect(report.deleted == 2)
        #expect(report.total == 48)
        #expect(try index.record(matching: photo(1).id)?.isFavorite == true)
        #expect(try index.record(matching: photo(10).id) == nil)
    }

    @Test func updateThatChangesNothingIsNotCounted() throws {
        let source = FakeSource((0..<5).map { photo($0) })
        let index = try LibraryIndex.inMemory()
        let indexer = Indexer(source: source, index: index)
        _ = try indexer.sync()
        source.update([photo(2)])   // Photos reports it, but nothing we index differs
        let report = try indexer.sync()
        #expect(report.touched == 0)
    }

    @Test func insertedThenDeletedInOneWindowEndsUpAbsent() throws {
        let source = FakeSource((0..<5).map { photo($0) })
        let index = try LibraryIndex.inMemory()
        let indexer = Indexer(source: source, index: index)
        _ = try indexer.sync()
        source.add([photo(7)])
        source.remove([photo(7).id])
        let report = try indexer.sync()
        #expect(report.inserted == 0)
        #expect(try index.count() == 5)
    }

    @Test func expiredTokenFallsBackToFullSync() throws {
        let source = FakeSource((0..<20).map { photo($0) })
        let index = try LibraryIndex.inMemory()
        let indexer = Indexer(source: source, index: index)
        _ = try indexer.sync()

        source.add([photo(20), photo(21)])
        source.remove([photo(0).id])
        source.oldestValidToken = 100
        let report = try indexer.sync()
        #expect(report.mode == .full)
        #expect(report.fallbackReason == "expired")
        #expect(report.inserted == 2)
        #expect(report.deleted == 1)
        #expect(report.total == 21)
    }
}

@Suite struct LibraryIndexTests {
    /// Every field must survive SQLite exactly. An inexact date round trip would make each
    /// full sync rewrite every row.
    @Test func recordsRoundTripExactly() throws {
        let index = try LibraryIndex.inMemory()
        let full = AssetRecord(
            id: "ABCDEF01-2345-6789-ABCD-EF0123456789/L0/001", mediaType: .video, subtypes: 8 | 4,
            created: Date(timeIntervalSinceReferenceDate: 712_345_678.123456789),
            modified: Date(timeIntervalSinceReferenceDate: 712_399_999.987654321),
            pixelWidth: 1920, pixelHeight: 1080, duration: 12.345,
            latitude: 40.712776, longitude: -74.005974,
            isFavorite: true, isHidden: true, isEdited: true,
            burstID: "B1", burstSelection: 2, representsBurst: true, sourceType: 1)
        let bare = AssetRecord(id: "00000000-0000-0000-0000-000000000001/L0/001")
        try index.upsert([full, bare])
        let back = try index.allRecords()
        #expect(back[full.id] == full)
        #expect(back[bare.id] == bare)
    }

    @Test func lookupByUUIDIgnoresCase() throws {
        let index = try LibraryIndex.inMemory()
        let record = photo(42)
        try index.upsert([record])
        #expect(try index.record(matching: record.uuid.lowercased())?.id == record.id)
        #expect(try index.record(matching: record.id)?.id == record.id)
        #expect(try index.record(matching: "nope") == nil)
    }

    @Test func statsCountBurstFramesPhotosHides() throws {
        let index = try LibraryIndex.inMemory()
        var shown = photo(1); shown.burstID = "B"; shown.representsBurst = true
        var picked = photo(2); picked.burstID = "B"; picked.burstSelection = 2
        var hidden = photo(3); hidden.burstID = "B"
        var autoPicked = photo(5); autoPicked.burstID = "B"; autoPicked.burstSelection = 1
        var screenshot = photo(4); screenshot.subtypes = 4; screenshot.isFavorite = true
        try index.upsert([shown, picked, hidden, autoPicked, screenshot])
        let stats = try index.stats()
        #expect(stats.total == 5)
        #expect(stats.burstFrames == 4)
        #expect(stats.hiddenBurstFrames == 2, "Photos' own auto-picks are hidden too; only user picks show")
        #expect(autoPicked.isHiddenBurstFrame)
        #expect(stats.screenshots == 1)
        #expect(stats.favorites == 1)
        #expect(hidden.isHiddenBurstFrame && !picked.isHiddenBurstFrame && !shown.isHiddenBurstFrame)
    }

    @Test func reopeningKeepsDataAndSchemaVersion() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "lightbox-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let index = try LibraryIndex(url: url)
            try index.upsert([photo(1)])
            try index.setMeta(.syncMode, "full")
        }
        let reopened = try LibraryIndex(url: url)
        #expect(try reopened.count() == 1)
        #expect(try reopened.metaString(.syncMode) == "full")
        #expect(try reopened.db.userVersion == LibraryIndex.schemaVersion)
    }

    @Test func deleteReportsOnlyRowsThatExisted() throws {
        let index = try LibraryIndex.inMemory()
        try index.upsert([photo(1), photo(2)])
        #expect(try index.delete(ids: [photo(1).id, "missing"]) == 1)
        #expect(try index.count() == 1)
    }
}

@Suite struct SharedAlbumTests {
    @Test func sharedPhotosArriveAndLeaveWithoutChangeHistory() throws {
        let source = FakeSource((0..<10).map { photo($0) })
        let index = try LibraryIndex.inMemory()
        let indexer = Indexer(source: source, index: index)
        _ = try indexer.sync()

        source.addShared([photo(100), photo(101), photo(102)])
        let added = try indexer.sync()
        #expect(added.mode == .incremental)
        #expect(added.inserted == 3, "found by comparing the shared set, not the change log")
        #expect(try index.sharedIDs() == [photo(100).id, photo(101).id, photo(102).id])
        #expect(try index.stats().shared == 3)
        #expect(try index.record(matching: photo(100).id)?.isShared == true)

        source.removeShared([photo(101).id])
        let removed = try indexer.sync()
        #expect(removed.deleted == 1)
        #expect(try index.count() == 12)

        let quiet = try indexer.sync()
        #expect(quiet.touched == 0)
    }

    @Test func fullSyncIncludesSharedPhotos() throws {
        let source = FakeSource((0..<5).map { photo($0) })
        source.addShared([photo(50)])
        let index = try LibraryIndex.inMemory()
        let report = try Indexer(source: source, index: index).sync()
        #expect(report.mode == .full && report.inserted == 6)
    }

    @Test func albumsAreReplacedEverySync() throws {
        let source = FakeSource((0..<6).map { photo($0) })
        source.addShared([photo(60), photo(61)])
        source.albumList = [
            Album(id: "A", title: "Trip", kind: .regular, memberIDs: [photo(1).id, photo(2).id]),
            Album(id: "S", title: "Friends", kind: .shared, memberIDs: [photo(60).id, photo(61).id]),
        ]
        let index = try LibraryIndex.inMemory()
        let indexer = Indexer(source: source, index: index)
        #expect(try indexer.sync().albums == 2)
        #expect(try index.albums().map(\.title) == ["Friends", "Trip"])
        #expect(try index.albumTitles(for: photo(1).id) == ["Trip"])

        source.albumList = [Album(id: "A", title: "Trip", kind: .regular, memberIDs: [photo(3).id])]
        _ = try indexer.sync()
        #expect(try index.albums().map(\.count) == [1])
        #expect(try index.albumTitles(for: photo(1).id).isEmpty)
        #expect(try index.albumTitles(for: photo(3).id) == ["Trip"])
    }

    @Test func scopeAndAlbumFilters() throws {
        let source = FakeSource((0..<4).map { photo($0) })
        source.addShared([photo(70), photo(71)])
        source.albumList = [
            Album(id: "A", title: "Trip", kind: .regular, memberIDs: [photo(1).id, photo(70).id]),
            Album(id: "B", title: "Beach", kind: .regular, memberIDs: [photo(1).id]),
        ]
        let index = try LibraryIndex.inMemory()
        _ = try Indexer(source: source, index: index).sync()
        func ids(_ configure: (inout PhotoQuery) -> Void) throws -> Set<Int> {
            var query = PhotoQuery()
            configure(&query)
            return Set(try index.search(query).hits.compactMap { Int($0.asset.id.prefix(8), radix: 16) })
        }
        #expect(try ids { _ in } == [0, 1, 2, 3, 70, 71])
        #expect(try ids { $0.scope = .library } == [0, 1, 2, 3])
        #expect(try ids { $0.scope = .shared } == [70, 71])
        #expect(try ids { $0.albums = ["trip"] } == [1, 70], "titles match ignoring case")
        #expect(try ids { $0.albums = ["Trip", "Beach"] } == [1])
        #expect(try ids { $0.albums = ["Trip"]; $0.scope = .library } == [1])
    }

    @Test func deletingAPhotoDropsItsMemberships() throws {
        let source = FakeSource((0..<3).map { photo($0) })
        source.albumList = [Album(id: "A", title: "Trip", kind: .regular, memberIDs: [photo(1).id])]
        let index = try LibraryIndex.inMemory()
        _ = try Indexer(source: source, index: index).sync()
        try index.delete(ids: [photo(1).id])
        #expect(try index.albumTitles(for: photo(1).id).isEmpty)
    }
}
