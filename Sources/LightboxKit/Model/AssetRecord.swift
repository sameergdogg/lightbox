import Foundation
import Photos

/// One library item as lightbox indexes it: metadata only, no pixels.
///
/// A plain value so it can cross actors and go to SQLite or JSON without touching PhotoKit
/// again. `PHAsset` itself is neither `Sendable` nor something to hold 65k of.
public struct AssetRecord: Sendable, Equatable {
    public enum MediaType: String, Sendable, Encodable {
        case image, video, audio, unknown
    }

    /// PhotoKit local identifier (`<UUID>/L0/001`). The primary key everywhere.
    public var id: String
    public var mediaType: MediaType
    /// Raw `PHAssetMediaSubtype` bits.
    public var subtypes: UInt
    public var created: Date?
    public var modified: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Seconds; 0 for stills.
    public var duration: Double
    public var latitude: Double?
    public var longitude: Double?
    public var isFavorite: Bool
    public var isHidden: Bool
    /// Edited in Photos (`PHAsset.hasAdjustments`).
    public var isEdited: Bool
    public var burstID: String?
    /// Raw `PHAssetBurstSelectionType` bits: 1 auto pick, 2 user pick.
    public var burstSelection: UInt
    /// The frame Photos shows for its burst.
    public var representsBurst: Bool
    /// Raw `PHAssetSourceType`.
    public var sourceType: UInt

    public init(id: String, mediaType: MediaType = .image, subtypes: UInt = 0,
                created: Date? = nil, modified: Date? = nil,
                pixelWidth: Int = 0, pixelHeight: Int = 0, duration: Double = 0,
                latitude: Double? = nil, longitude: Double? = nil,
                isFavorite: Bool = false, isHidden: Bool = false, isEdited: Bool = false,
                burstID: String? = nil, burstSelection: UInt = 0, representsBurst: Bool = false,
                sourceType: UInt = 0) {
        self.id = id
        self.mediaType = mediaType
        self.subtypes = subtypes
        self.created = created
        self.modified = modified
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.latitude = latitude
        self.longitude = longitude
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.isEdited = isEdited
        self.burstID = burstID
        self.burstSelection = burstSelection
        self.representsBurst = representsBurst
        self.sourceType = sourceType
    }

    /// The UUID part of the local identifier, which is also `ZUUID` in Photos' database and
    /// the stem of its preview files.
    public var uuid: String {
        id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id
    }

    /// In an iCloud shared album rather than the library: someone else's photo, read-only.
    /// Never offer these for deletion.
    public var isShared: Bool { PHAssetSourceType(rawValue: sourceType).contains(.typeCloudShared) }

    public var isScreenshot: Bool { PHAssetMediaSubtype(rawValue: subtypes).contains(.photoScreenshot) }
    public var isLivePhoto: Bool { PHAssetMediaSubtype(rawValue: subtypes).contains(.photoLive) }

    /// A burst frame Photos does not show on its own: neither the burst's representative
    /// nor picked by the user. (Photos' own auto-picks are still hidden.) A default
    /// PhotoKit fetch leaves these out, even when asked for them by local identifier.
    /// Checked against a 55k-item library: this rule matches PhotoKit's misses exactly.
    public var isHiddenBurstFrame: Bool {
        burstID != nil && !representsBurst
            && !PHAssetBurstSelectionType(rawValue: burstSelection).contains(.userPick)
    }
}

extension AssetRecord: Encodable {
    private enum CodingKeys: String, CodingKey {
        case id, uuid, mediaType, subtypes, created, modified, pixelWidth, pixelHeight, duration
        case latitude, longitude, isFavorite, isHidden, isEdited, isScreenshot, isLivePhoto, isShared
        case burstID, burstSelection, representsBurst, sourceType
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(uuid, forKey: .uuid)
        try c.encode(mediaType, forKey: .mediaType)
        try c.encode(subtypes, forKey: .subtypes)
        try c.encodeIfPresent(created, forKey: .created)
        try c.encodeIfPresent(modified, forKey: .modified)
        try c.encode(pixelWidth, forKey: .pixelWidth)
        try c.encode(pixelHeight, forKey: .pixelHeight)
        if duration > 0 { try c.encode(duration, forKey: .duration) }
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(isHidden, forKey: .isHidden)
        try c.encode(isEdited, forKey: .isEdited)
        try c.encode(isScreenshot, forKey: .isScreenshot)
        try c.encode(isLivePhoto, forKey: .isLivePhoto)
        if isShared { try c.encode(true, forKey: .isShared) }
        try c.encodeIfPresent(burstID, forKey: .burstID)
        if burstID != nil {
            try c.encode(burstSelection, forKey: .burstSelection)
            try c.encode(representsBurst, forKey: .representsBurst)
        }
        try c.encode(sourceType, forKey: .sourceType)
    }
}
