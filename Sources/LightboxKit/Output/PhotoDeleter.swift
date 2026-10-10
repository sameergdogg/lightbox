import Foundation
import os
import Photos

/// Deletes photos from the library, with the guards every lightbox caller needs.
///
/// Two steps, by design: `plan` says exactly what would go and what is refused, and only
/// `delete(_:)` changes anything. It does that in one PhotoKit change, so the user sees one
/// system confirmation and the photos land in Recently Deleted for 30 days. With iCloud
/// Photos the deletion reaches every device.
///
/// Refused, always:
/// - favourites (the user marked them; unfavourite in Photos first),
/// - photos from shared albums (someone else's; PhotoKit can't delete them anyway),
/// - ids that no longer resolve (already deleted elsewhere).
///
/// One opt-in exception: `.favouritedBurstFrames`. Favouriting a burst in Photos marks every
/// frame, but the user only sees (and chose) the burst's representative and any frames they
/// picked. With the option, the other frames of a favourited burst may be deleted; the
/// frames Photos shows never are.
public final class PhotoDeleter: Sendable {
    public enum Refusal: String, Sendable, Encodable {
        case favorite, shared, missing
    }

    public struct Allowance: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Hidden frames of a burst favourited as a whole.
        public static let favouritedBurstFrames = Allowance(rawValue: 1 << 0)
    }

    private let allowing: Allowance

    public struct Plan: Sendable, Encodable, Equatable {
        public var deletable: [String]
        public var refused: [String: Refusal]
    }

    private static let log = Logger(subsystem: "com.sameer.lightbox", category: "delete")

    public init(allowing: Allowance = []) {
        self.allowing = allowing
    }

    /// A frame Photos doesn't show on its own: in a burst, not its representative, not a user pick.
    static func isHiddenBurstFrame(_ asset: PHAsset) -> Bool {
        asset.burstIdentifier != nil && !asset.representsBurst && !asset.burstSelectionTypes.contains(.userPick)
    }

    /// What `delete` would do with these ids. Changes nothing.
    public func plan(_ ids: [String]) -> Plan {
        var plan = Plan(deletable: [], refused: [:])
        let found = Self.assets(ids)
        for id in ids {
            guard let asset = found[id] else {
                plan.refused[id] = .missing
                continue
            }
            if asset.isFavorite && !(allowing.contains(.favouritedBurstFrames) && Self.isHiddenBurstFrame(asset)) {
                plan.refused[id] = .favorite
            } else if asset.sourceType.contains(.typeCloudShared) {
                plan.refused[id] = .shared
            } else {
                plan.deletable.append(id)
            }
        }
        return plan
    }

    /// Deletes what the plan allows, re-checking each photo first (it may have been
    /// favourited or deleted since the plan was made). Returns the ids actually deleted.
    /// Throws `PHPhotosError.userCancelled` if the user declines the system prompt.
    @discardableResult
    public func delete(_ plan: Plan) async throws -> [String] {
        let fresh = self.plan(plan.deletable)
        guard !fresh.deletable.isEmpty else { return [] }
        let assets = Self.assets(fresh.deletable)
        let targets = fresh.deletable.compactMap { assets[$0] }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(targets as NSArray)
        }
        Self.log.notice("deleted \(targets.count) photos; refused \(fresh.refused.count + plan.refused.count)")
        return targets.map(\.localIdentifier)
    }

    private static func assets(_ ids: [String]) -> [String: PHAsset] {
        var result: [String: PHAsset] = [:]
        var start = 0
        while start < ids.count {
            let slice = Array(ids[start..<min(start + 500, ids.count)])
            PHAsset.fetchAssets(withLocalIdentifiers: slice, options: PhotoKitSource.fetchOptions())
                .enumerateObjects { asset, _, _ in result[asset.localIdentifier] = asset }
            start += slice.count
        }
        return result
    }
}
