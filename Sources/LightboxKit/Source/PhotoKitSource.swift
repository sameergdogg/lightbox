import AppKit
import CoreLocation
import Foundation
import Photos

/// Reads the System Photo Library through PhotoKit.
///
/// Every fetch, including lookups by local identifier, sets `includeAllBurstAssets` and
/// `includeHiddenAssets`. PhotoKit's default leaves out burst frames that were never picked
/// and anything in the Hidden album, even when asked for them by id. Dedupe's iPhone app
/// fingerprinted those frames during its scan but looked them up later with default
/// options, so their tiles could never load.
public final class PhotoKitSource: AssetSource {
    private let library = PHPhotoLibrary.shared()
    /// Longest an incremental sync may spend reading Photos' change history before giving
    /// up in favour of a full sync. Replaying history costs per change, a full sync costs
    /// per photo (about 17 s for 55k), so after a big batch of edits the full sync is faster.
    /// Measured: a sync spanning a People merge that touched 12k+ photos took 16 minutes
    /// incrementally.
    public var changeHistoryBudget: TimeInterval
    /// Past this fraction of the library changed, a full sync is cheaper too.
    public var maxChangedFraction = 0.25

    public init(changeHistoryBudget: TimeInterval = 10) {
        self.changeHistoryBudget = changeHistoryBudget
    }

    // MARK: Authorization

    public static var authorization: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Asks once; later calls return the stored answer without a prompt.
    public static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Command-line tools must call this once, on the main thread, before requesting images.
    ///
    /// Without an `NSApplication`, `PHImageManager.requestImage` returns nil with no error,
    /// even for photos stored on the Mac. Metadata fetches and `requestImageDataAndOrientation`
    /// work either way, which makes the failure easy to miss. Found 2026-10-04 on macOS 26.5.
    /// `.prohibited` keeps the process out of the Dock. GUI apps already have an
    /// `NSApplication` and don't need this.
    @MainActor
    public static func prepareCommandLineProcess() {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    // MARK: Fetching

    /// The options lightbox uses for every fetch. See the type comment for why.
    public static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.includeHiddenAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return options
    }

    /// Library photos plus photos in shared albums. A library fetch never returns the latter:
    /// they belong to shared-album collections only.
    public var assetCount: Int {
        PHAsset.fetchAssets(with: Self.fetchOptions()).count + ((try? sharedAssetIDs().count) ?? 0)
    }

    public func enumerateAll(batchSize: Int, _ body: ([AssetRecord]) throws -> Void) throws {
        try enumerate(PHAsset.fetchAssets(with: Self.fetchOptions()), batchSize: batchSize, body)
        var seen = Set<String>()
        for album in Self.sharedAlbums() {
            let fetch = PHAsset.fetchAssets(in: album, options: Self.fetchOptions())
            try enumerate(fetch, batchSize: batchSize) { batch in
                let fresh = batch.filter { seen.insert($0.id).inserted }
                if !fresh.isEmpty { try body(fresh) }
            }
        }
    }

    private func enumerate(_ fetch: PHFetchResult<PHAsset>, batchSize: Int,
                           _ body: ([AssetRecord]) throws -> Void) throws {
        var start = 0
        while start < fetch.count {
            let end = min(start + batchSize, fetch.count)
            var batch: [AssetRecord] = []
            batch.reserveCapacity(end - start)
            autoreleasepool {
                fetch.enumerateObjects(at: IndexSet(integersIn: start..<end), options: []) { asset, _, _ in
                    batch.append(AssetRecord(asset))
                }
            }
            try body(batch)
            start = end
        }
    }

    // MARK: Albums

    static func sharedAlbums() -> [PHAssetCollection] {
        var result: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
            .enumerateObjects { album, _, _ in result.append(album) }
        return result
    }

    public func sharedAssetIDs() throws -> Set<String> {
        var ids = Set<String>()
        for album in Self.sharedAlbums() {
            PHAsset.fetchAssets(in: album, options: Self.fetchOptions())
                .enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        }
        return ids
    }

    public func albums() throws -> [Album] {
        var result: [Album] = []
        for (subtype, kind) in [(PHAssetCollectionSubtype.albumRegular, Album.Kind.regular), (.albumCloudShared, .shared)] {
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: subtype, options: nil).enumerateObjects { album, _, _ in
                var members: [String] = []
                PHAsset.fetchAssets(in: album, options: Self.fetchOptions())
                    .enumerateObjects { asset, _, _ in members.append(asset.localIdentifier) }
                result.append(Album(id: album.localIdentifier, title: album.localizedTitle ?? "", kind: kind, memberIDs: members))
            }
        }
        return result
    }

    public func records(for ids: [String]) throws -> [AssetRecord] {
        var result: [AssetRecord] = []
        result.reserveCapacity(ids.count)
        var start = 0
        while start < ids.count {
            let slice = Array(ids[start..<min(start + 500, ids.count)])
            autoreleasepool {
                PHAsset.fetchAssets(withLocalIdentifiers: slice, options: Self.fetchOptions())
                    .enumerateObjects { asset, _, _ in result.append(AssetRecord(asset)) }
            }
            start += slice.count
        }
        return result
    }

    /// How many of `ids` a fetch with PhotoKit's *default* options can find. This is a
    /// diagnostic only: it measures how many photos code that forgets
    /// `includeAllBurstAssets` cannot see.
    public func countResolvableWithDefaultOptions(_ ids: [String]) -> Int {
        var found = 0
        var start = 0
        while start < ids.count {
            let slice = Array(ids[start..<min(start + 500, ids.count)])
            found += PHAsset.fetchAssets(withLocalIdentifiers: slice, options: nil).count
            start += slice.count
        }
        return found
    }

    // MARK: Change tracking

    public func currentChangeToken() -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: library.currentChangeToken,
                                          requiringSecureCoding: true)
    }

    public func changes(since data: Data) throws -> ChangeResult {
        let token: PHPersistentChangeToken?
        do {
            token = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
        } catch {
            return .unavailable(reason: "stored change token is unreadable")
        }
        guard let token else { return .unavailable(reason: "stored change token is unreadable") }

        var set = ChangeSet()
        let started = Date()
        let cap = Int(Double(assetCount) * maxChangedFraction)
        do {
            let changes = try library.fetchPersistentChanges(since: token)
            for change in changes {
                let details = try change.changeDetails(for: .asset)
                set.inserted.formUnion(details.insertedLocalIdentifiers)
                set.updated.formUnion(details.updatedLocalIdentifiers)
                set.deleted.formUnion(details.deletedLocalIdentifiers)
                if Date().timeIntervalSince(started) > changeHistoryBudget {
                    return .unavailable(reason: "change history too long to replay; a full sync is faster")
                }
                if set.inserted.count + set.updated.count + set.deleted.count > cap {
                    return .unavailable(reason: "more than \(Int(maxChangedFraction * 100)) % of the library changed")
                }
            }
        } catch let error as PHPhotosError where
            error.code == .persistentChangeTokenExpired || error.code == .persistentChangeDetailsUnavailable {
            return .unavailable(reason: "Photos no longer has history that far back (\(error.code.rawValue))")
        }
        return .changes(set)
    }
}

extension AssetRecord {
    init(_ asset: PHAsset) {
        let mediaType: MediaType = switch asset.mediaType {
        case .image: .image
        case .video: .video
        case .audio: .audio
        default: .unknown
        }
        let coordinate = asset.location?.coordinate
        self.init(
            id: asset.localIdentifier,
            mediaType: mediaType,
            subtypes: asset.mediaSubtypes.rawValue,
            created: asset.creationDate,
            modified: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude,
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            isEdited: asset.hasAdjustments,
            burstID: asset.burstIdentifier,
            burstSelection: asset.burstSelectionTypes.rawValue,
            representsBurst: asset.representsBurst,
            sourceType: asset.sourceType.rawValue
        )
    }
}
