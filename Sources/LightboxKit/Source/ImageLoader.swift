import AppKit
import Foundation
import Photos

/// Loads pixels for analysis from PhotoKit, never from the network.
///
/// The request is asynchronous and `.opportunistic` on purpose. A synchronous request makes
/// PhotoKit ignore `deliveryMode` and insist on the full-quality image. For a photo whose
/// original is only in iCloud, that means "nothing", even though Photos keeps a local
/// preview that is fine for analysis. Opportunistic delivery hands back the best local
/// rendition first, then a better one if it has it. The loader keeps the largest frame
/// that arrives and stops at the final callback, an error, or a timeout, whichever comes first.
public final class ImageLoader: Sendable {
    public enum Outcome: Sendable {
        case image(CGImage)
        /// Only a rendition smaller than asked for exists on this Mac (its long side, in pixels).
        case tooSmall(Int)
        /// No local pixels at all (the original is in iCloud and no preview is cached).
        case unavailable(String)
        /// The id no longer resolves; the photo was deleted since the last index sync.
        case missing
    }

    /// One PhotoKit callback, for diagnostics.
    public struct Callback: Sendable {
        public let width: Int
        public let height: Int
        public let degraded: Bool
        public let inCloud: Bool
        public let error: String?
        public let elapsed: TimeInterval
    }

    private let manager = PHImageManager.default()
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    /// The best local image for `id`, scaled to fit `maxSide`. Anything whose long side is
    /// under `minSide` is reported as `.tooSmall` instead of being returned.
    ///
    /// `network` lets PhotoKit fetch from iCloud. It is off unless a caller opts in for a
    /// specific reason: library originals arrive through "Download Originals", but photos in
    /// shared albums never do, so they have no local rendition worth analyzing.
    public func load(_ id: String, maxSide: Int, minSide: Int, network: Bool = false) async -> Outcome {
        await load(id, maxSide: maxSide, minSide: minSide, network: network, trace: nil)
    }

    /// Same as `load`, also returning every callback PhotoKit made.
    public func probe(_ id: String, maxSide: Int) async -> (Outcome, [Callback]) {
        let trace = Trace()
        let outcome = await load(id, maxSide: maxSide, minSide: 1, network: false, trace: trace)
        return (outcome, trace.callbacks)
    }

    private func load(_ id: String, maxSide: Int, minSide: Int, network: Bool, trace: Trace?) async -> Outcome {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id],
                                              options: PhotoKitSource.fetchOptions()).firstObject else {
            return .missing
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = network
        options.version = .current
        let target = CGSize(width: maxSide, height: maxSide)

        let box = RequestBox()
        let started = Date()
        let best: CGImage? = await withCheckedContinuation { continuation in
            box.continuation = continuation
            let requestID = manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                                 options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? Error
                let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                trace?.add(Callback(width: cgImage?.width ?? 0, height: cgImage?.height ?? 0,
                                    degraded: degraded,
                                    inCloud: (info?[PHImageResultIsInCloudKey] as? Bool) ?? false,
                                    error: error.map { "\($0.localizedDescription)" },
                                    elapsed: Date().timeIntervalSince(started)))
                if let cgImage { box.offer(cgImage) }
                // A degraded frame is a preview; wait for the final callback unless the
                // request is already over.
                if !degraded || cancelled || error != nil { box.finish() }
            }
            box.requestID = requestID
            // Unstructured, so the continuation resumes even if PhotoKit never calls back
            // a final time.
            // A download needs longer than a local render; give it a fixed allowance.
            let deadline = network ? max(timeout, 45) : timeout
            Task { [manager] in
                try? await Task.sleep(for: .seconds(deadline))
                if box.finish() { manager.cancelImageRequest(requestID) }
            }
        }

        guard let best else { return .unavailable("no local pixels") }
        let longSide = max(best.width, best.height)
        return longSide >= minSide ? .image(best) : .tooSmall(longSide)
    }

    /// Keeps the largest frame and resumes the continuation exactly once.
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var best: CGImage?
        var continuation: CheckedContinuation<CGImage?, Never>?
        var requestID: PHImageRequestID = PHInvalidImageRequestID

        func offer(_ image: CGImage) {
            lock.lock(); defer { lock.unlock() }
            if best.map({ $0.width * $0.height < image.width * image.height }) ?? true { best = image }
        }

        /// True for the caller that actually finished it.
        @discardableResult
        func finish() -> Bool {
            lock.lock()
            guard !done else { lock.unlock(); return false }
            done = true
            let result = best
            let continuation = self.continuation
            lock.unlock()
            continuation?.resume(returning: result)
            return true
        }
    }

    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Callback] = []
        func add(_ callback: Callback) { lock.lock(); list.append(callback); lock.unlock() }
        var callbacks: [Callback] { lock.lock(); defer { lock.unlock() }; return list }
    }
}
