import Foundation

/// Where asset metadata comes from. `PhotoKitSource` in production; tests use a fake.
///
/// Change tracking is optional. A source that can say "these ids changed since token T"
/// makes a sync cost proportional to what changed. Without that, the indexer falls back
/// to reading everything and diffing.
public protocol AssetSource {
    /// How many assets a full enumeration will visit, for progress reporting.
    var assetCount: Int { get }

    /// Visits every asset, in batches so memory stays flat.
    func enumerateAll(batchSize: Int, _ body: ([AssetRecord]) throws -> Void) throws

    /// Current metadata for these ids. Ids that no longer exist are simply absent.
    func records(for ids: [String]) throws -> [AssetRecord]

    /// An opaque token for "now", or nil if the source cannot track changes. Taken
    /// *before* reading, so anything that changes mid-sync is seen again next time.
    func currentChangeToken() -> Data?

    /// What changed since `token`.
    func changes(since token: Data) throws -> ChangeResult

    /// Ids of photos that live in shared albums rather than the library. Photos' change
    /// history doesn't reliably cover them, so the indexer compares this set on every sync.
    func sharedAssetIDs() throws -> Set<String>

    /// Albums (the user's own and shared ones) with their members. Read in full on every
    /// sync: there are tens of them, not tens of thousands.
    func albums() throws -> [Album]
}

extension AssetSource {
    public func sharedAssetIDs() throws -> Set<String> { [] }
    public func albums() throws -> [Album] { [] }
}

public struct Album: Sendable, Equatable, Encodable {
    public enum Kind: String, Sendable, Encodable {
        /// An album in the library.
        case regular
        /// An iCloud shared album: other people's photos, read-only to apps.
        case shared
    }

    public var id: String
    public var title: String
    public var kind: Kind
    public var memberIDs: [String]

    public init(id: String, title: String, kind: Kind, memberIDs: [String]) {
        self.id = id
        self.title = title
        self.kind = kind
        self.memberIDs = memberIDs
    }
}

public enum ChangeResult: Sendable {
    case changes(ChangeSet)
    /// The token is too old or unreadable; a full sync is required.
    case unavailable(reason: String)
}

public struct ChangeSet: Sendable, Equatable {
    public var inserted: Set<String> = []
    public var updated: Set<String> = []
    public var deleted: Set<String> = []

    public init(inserted: Set<String> = [], updated: Set<String> = [], deleted: Set<String> = []) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
    }

    public var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && deleted.isEmpty }
}
