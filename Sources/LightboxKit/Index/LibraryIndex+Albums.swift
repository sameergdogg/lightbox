import Foundation

extension LibraryIndex {
    /// Ids of indexed photos that come from shared albums.
    public func sharedIDs() throws -> Set<String> {
        let query = try db.prepare("SELECT id FROM assets WHERE (source_type & 2) != 0")   // PHAssetSourceType.typeCloudShared
        var ids = Set<String>()
        while try query.step() { ids.insert(query.text(0) ?? "") }
        return ids
    }

    /// Replaces every album and membership. Called on each sync with the full list; cheap,
    /// because a library has tens of albums.
    public func replaceAlbums(_ albums: [Album]) throws {
        try db.transaction {
            try db.execute("DELETE FROM album_members; DELETE FROM albums;")
            let album = try db.prepare("INSERT OR REPLACE INTO albums (id, title, kind, count) VALUES (?, ?, ?, ?)")
            let member = try db.prepare("INSERT OR IGNORE INTO album_members (album_id, asset_id) VALUES (?, ?)")
            for a in albums {
                try album.bind(1, a.id).bind(2, a.title).bind(3, a.kind.rawValue).bind(4, a.memberIDs.count).step()
                album.reset()
                for id in a.memberIDs {
                    try member.bind(1, a.id).bind(2, id).step()
                    member.reset()
                }
            }
        }
    }

    public struct AlbumSummary: Sendable, Encodable, Equatable {
        public var id: String
        public var title: String
        public var kind: Album.Kind
        public var count: Int
    }

    /// Albums, biggest first.
    public func albums() throws -> [AlbumSummary] {
        let query = try db.prepare("SELECT id, title, kind, count FROM albums ORDER BY count DESC, title")
        var result: [AlbumSummary] = []
        while try query.step() {
            result.append(.init(id: query.text(0) ?? "", title: query.text(1) ?? "",
                                kind: Album.Kind(rawValue: query.text(2) ?? "") ?? .regular, count: query.int(3)))
        }
        return result
    }

    /// Album titles each photo belongs to.
    public func albumTitles(for id: String) throws -> [String] {
        let query = try db.prepare("""
            SELECT a.title FROM album_members m JOIN albums a ON a.id = m.album_id WHERE m.asset_id = ? ORDER BY a.title
            """)
        query.bind(1, id)
        var titles: [String] = []
        while try query.step() { titles.append(query.text(0) ?? "") }
        return titles
    }
}
