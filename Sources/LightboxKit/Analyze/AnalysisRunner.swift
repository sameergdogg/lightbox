import Foundation

/// Works through `LibraryIndex.analysisQueue`: load local pixels, run Vision, save.
///
/// Resumable by construction. Results are written every `batchSize` photos, and the queue
/// is "whatever has no current result", so killing the process loses at most one batch and
/// the next run carries on. Photos without local pixels are recorded as waiting and picked
/// up again on later runs, so the index fills in as iCloud originals download.
public final class AnalysisRunner {
    public struct Options: Sendable {
        /// Concurrent photos in flight. Vision and PhotoKit both parallelise well.
        public var workers = 8
        /// Long side requested from PhotoKit.
        public var maxSide = 1024
        /// Smaller local renditions are treated as "waiting for pixels" rather than
        /// analyzed. Faces and sharpness are unreliable on a thumbnail.
        public var minSide = 512
        public var batchSize = 100
        public var includeWaiting = true
        public var limit: Int?
        /// Only these photos (still only the ones that need it). An app that cares about a
        /// subset, like Dedupe and the members of duplicate sets, pays only for that subset.
        public var only: Set<String>?
        /// Download previews of photos in shared albums to analyze them. Off by default:
        /// lightbox otherwise never touches the network. Shared photos never arrive through
        /// "Download Originals", so without this they stay "waiting for pixels" forever.
        public var fetchShared = false

        public init() {}
    }

    public struct Progress: Sendable, Encodable {
        public var total = 0
        public var done = 0
        public var ok = 0
        public var waitingForPixels = 0
        public var failed = 0
        public var seconds = 0.0

        public var rate: Double { seconds > 0 ? Double(done) / seconds : 0 }
        public var secondsLeft: Double? { rate > 0 ? Double(total - done) / rate : nil }
    }

    private let index: LibraryIndex
    private let loader: ImageLoader
    private let analyzer: VisionAnalyzer

    public init(index: LibraryIndex, loader: ImageLoader = ImageLoader(), analyzer: VisionAnalyzer = VisionAnalyzer()) {
        self.index = index
        self.loader = loader
        self.analyzer = analyzer
    }

    public func run(_ options: Options = Options(), progress: ((Progress) -> Void)? = nil) async throws -> Progress {
        var queue = try index.analysisQueue(version: VisionAnalyzer.version, includeWaiting: options.includeWaiting,
                                            limit: options.only == nil ? options.limit : nil)
        if let only = options.only {
            queue = queue.filter { only.contains($0) }
            if let limit = options.limit { queue = Array(queue.prefix(limit)) }
        }
        var state = Progress(total: queue.count)
        let started = Date()
        var pending: [(id: String, result: LibraryIndex.AnalysisResult)] = []
        let loader = self.loader, analyzer = self.analyzer

        func record(_ id: String, _ result: LibraryIndex.AnalysisResult) throws {
            switch result {
            case .ok: state.ok += 1
            case .waitingForPixels: state.waitingForPixels += 1
            case .failed: state.failed += 1
            }
            state.done += 1
            pending.append((id, result))
            if pending.count >= options.batchSize {
                try index.saveSignals(pending, version: VisionAnalyzer.version)
                pending.removeAll(keepingCapacity: true)
                state.seconds = Date().timeIntervalSince(started)
                progress?(state)
            }
        }

        let shared = options.fetchShared ? try index.sharedIDs() : []
        try await withThrowingTaskGroup(of: (String, LibraryIndex.AnalysisResult).self) { group in
            var next = queue.makeIterator()
            func launch() {
                guard let id = next.next() else { return }
                let network = shared.contains(id)
                group.addTask {
                    (id, await Self.analyze(id, loader: loader, analyzer: analyzer, options: options, network: network))
                }
            }
            for _ in 0..<max(1, options.workers) { launch() }
            while let (id, result) = try await group.next() {
                try record(id, result)
                try Task.checkCancellation()
                launch()
            }
        }

        try index.saveSignals(pending, version: VisionAnalyzer.version)
        state.seconds = Date().timeIntervalSince(started)
        progress?(state)
        return state
    }

    private static func analyze(_ id: String, loader: ImageLoader, analyzer: VisionAnalyzer,
                                options: Options, network: Bool) async -> LibraryIndex.AnalysisResult {
        switch await loader.load(id, maxSide: options.maxSide, minSide: options.minSide, network: network) {
        case .unavailable(let why):
            return .waitingForPixels(why)
        case .missing:
            return .failed("no longer in the library; run `lightbox index`")
        case .tooSmall(let side):
            return .waitingForPixels("only a \(side) px rendition on this Mac")
        case .image(let image):
            do {
                return .ok(try await analyzer.analyze(image))
            } catch {
                return .failed("vision: \(error.localizedDescription)")
            }
        }
    }
}
