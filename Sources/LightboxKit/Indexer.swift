import Foundation

/// Brings a `LibraryIndex` up to date with an `AssetSource`.
///
/// Two paths:
/// - **Incremental**: ask the source what changed since the stored token, re-read only
///   those ids, and diff them. Ten new photos cost ten rows.
/// - **Full**: read everything and diff against the index in memory. Used on the first
///   run, when the token has expired, or on request. It still writes only rows that
///   actually differ, so a full sync of an unchanged library writes nothing.
public final class Indexer {
    public let source: AssetSource
    public let index: LibraryIndex

    public init(source: AssetSource, index: LibraryIndex) {
        self.source = source
        self.index = index
    }

    public struct Report: Sendable, Encodable, Equatable {
        public enum Mode: String, Sendable, Encodable { case full, incremental }

        public var mode: Mode
        /// Records read from the source.
        public var scanned = 0
        public var inserted = 0
        public var updated = 0
        public var deleted = 0
        /// Rows in the index afterwards.
        public var total = 0
        public var seconds = 0.0
        /// Why an incremental sync turned into a full one.
        public var fallbackReason: String?
        public var albums = 0

        public var touched: Int { inserted + updated + deleted }
    }

    /// `progress` receives (records read, records expected) during a full sync.
    public func sync(forceFull: Bool = false, batchSize: Int = 2_000,
                     progress: ((Int, Int) -> Void)? = nil) throws -> Report {
        let started = Date()
        let token = source.currentChangeToken()

        var report: Report
        var fallback: String?
        if !forceFull, let saved = try index.meta(.changeToken) {
            switch try source.changes(since: saved) {
            case .changes(let changes):
                report = try applyIncremental(changes)
            case .unavailable(let reason):
                fallback = reason
                report = try fullSync(batchSize: batchSize, progress: progress)
            }
        } else {
            report = try fullSync(batchSize: batchSize, progress: progress)
        }

        try reconcileShared(&report)
        let albums = try source.albums()
        try index.replaceAlbums(albums)
        report.albums = albums.count

        report.fallbackReason = fallback
        report.total = try index.count()
        report.seconds = Date().timeIntervalSince(started)
        try index.setMeta(.changeToken, token)
        try index.setMeta(.syncedAt, ISO8601DateFormatter().string(from: Date()))
        try index.setMeta(.syncMode, report.mode.rawValue)
        return report
    }

    private func fullSync(batchSize: Int, progress: ((Int, Int) -> Void)?) throws -> Report {
        var report = Report(mode: .full)
        let existing = try index.allRecords()
        let expected = source.assetCount
        var seen = Set<String>()
        seen.reserveCapacity(existing.count)

        try source.enumerateAll(batchSize: batchSize) { batch in
            var writes: [AssetRecord] = []
            var repainted: [String] = []
            for record in batch {
                seen.insert(record.id)
                switch existing[record.id] {
                case nil:
                    report.inserted += 1
                    writes.append(record)
                case let old? where old != record:
                    report.updated += 1
                    writes.append(record)
                    if Self.pixelsMayDiffer(old, record) { repainted.append(record.id) }
                default:
                    break
                }
            }
            try index.upsert(writes)
            try index.deleteSignals(repainted)
            report.scanned += batch.count
            progress?(report.scanned, expected)
        }

        let gone = existing.keys.filter { !seen.contains($0) }
        report.deleted = try index.delete(ids: gone)
        return report
    }

    /// Photos' change history doesn't reliably cover shared albums, so after every sync the
    /// set of shared photos is compared directly: new ones are read and added, vanished ones
    /// removed. After a full sync this finds nothing to do.
    private func reconcileShared(_ report: inout Report) throws {
        let shared = try source.sharedAssetIDs()
        let indexed = try index.sharedIDs()
        let known = try index.records(ids: shared.subtracting(indexed))
        let missing = shared.subtracting(indexed).subtracting(known.keys)
        if !missing.isEmpty {
            let fresh = try source.records(for: Array(missing))
            try index.upsert(fresh)
            report.inserted += fresh.count
        }
        report.deleted += try index.delete(ids: indexed.subtracting(shared))
    }

    /// An edit (crop, filter, rotation) changes the pixels, so whatever was computed from
    /// them is stale. A new favourite or album membership doesn't change anything.
    static func pixelsMayDiffer(_ old: AssetRecord, _ new: AssetRecord) -> Bool {
        old.isEdited != new.isEdited || old.pixelWidth != new.pixelWidth || old.pixelHeight != new.pixelHeight
            || (new.isEdited && old.modified != new.modified)
    }

    private func applyIncremental(_ changes: ChangeSet) throws -> Report {
        var report = Report(mode: .incremental)
        guard !changes.isEmpty else { return report }

        // Re-read whatever was inserted or updated. An id that was inserted and then
        // deleted inside the same window simply doesn't come back, which makes it a delete.
        let changed = changes.inserted.union(changes.updated).subtracting(changes.deleted)
        let fresh = try source.records(for: Array(changed))
        report.scanned = fresh.count
        let existing = try index.records(ids: fresh.map(\.id))

        var writes: [AssetRecord] = []
        var repainted: [String] = []
        for record in fresh {
            switch existing[record.id] {
            case nil:
                report.inserted += 1
                writes.append(record)
            case let old? where old != record:
                report.updated += 1
                writes.append(record)
                if Self.pixelsMayDiffer(old, record) { repainted.append(record.id) }
            default:
                break
            }
        }
        try index.upsert(writes)
        try index.deleteSignals(repainted)

        let found = Set(fresh.map(\.id))
        let gone = changes.deleted.union(changed.subtracting(found))
        report.deleted = try index.delete(ids: gone)
        return report
    }
}
