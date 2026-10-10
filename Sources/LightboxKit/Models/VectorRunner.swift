import CoreGraphics
import Foundation

/// Fills `face_vectors` or `image_vectors` for one provider, the way `AnalysisRunner` fills
/// signals: whatever the provider hasn't seen, newest first, saved every batch, so it can be
/// stopped and resumed. Photos without local pixels wait and are retried on the next run.
public final class VectorRunner {
    public struct Options: Sendable {
        public var workers = 8
        public var batchSize = 64
        public var scope: PhotoQuery.Scope = .all
        public var limit: Int?
        public var includeWaiting = true
        /// Fetch previews for photos in shared albums (they never arrive with "Download Originals").
        public var fetchShared = false
        public init() {}
    }

    public typealias Progress = AnalysisRunner.Progress

    private let index: LibraryIndex
    private let loader: ImageLoader

    public init(index: LibraryIndex, loader: ImageLoader = ImageLoader()) {
        self.index = index
        self.loader = loader
    }

    /// Face vectors. Photos are loaded at 1600 px: faces in group photos are small, and a face
    /// model needs about 50 px across.
    public func faces(_ embedder: FaceEmbedder, aligner: FaceAligner = FaceAligner(),
                      options: Options = Options(), progress: ((Progress) -> Void)? = nil) async throws -> Progress {
        let queue = try index.vectorQueue(model: embedder.model, kind: .faces, scope: options.scope,
                                          includeWaiting: options.includeWaiting, limit: options.limit)
        return try await run(queue, model: embedder.model, options: options, maxSide: 1600, minSide: 512, progress: progress) { image in
            let found = try aligner.faces(in: image, side: embedder.cropSide, template: embedder.template)
            guard !found.isEmpty else { return .faces([]) }
            let vectors = try embedder.embed(faces: found.map(\.crop))
            return .faces(zip(found, vectors).enumerated().map { n, pair in
                FaceVector(assetID: "", index: n, box: pair.0.box, vector: pair.1)
            })
        }
    }

    /// Whole-image vectors. Small renditions are enough: the model sees 224 px.
    public func images(_ embedder: ImageTextEmbedder, options: Options = Options(),
                       progress: ((Progress) -> Void)? = nil) async throws -> Progress {
        let queue = try index.vectorQueue(model: embedder.model, kind: .images, scope: options.scope,
                                          includeWaiting: options.includeWaiting, limit: options.limit)
        return try await run(queue, model: embedder.model, options: options, maxSide: 384, minSide: 192, progress: progress) { image in
            guard let vector = try embedder.embed(images: [image]).first else { return .failed }
            return .image(vector)
        }
    }

    private func run(_ queue: [String], model: String, options: Options, maxSide: Int, minSide: Int,
                     progress: ((Progress) -> Void)?,
                     work: @escaping @Sendable (CGImage) throws -> LibraryIndex.VectorResult) async throws -> Progress {
        var state = Progress(total: queue.count)
        let started = Date()
        var pending: [(id: String, result: LibraryIndex.VectorResult)] = []
        let shared = options.fetchShared ? try index.sharedIDs() : []
        let loader = self.loader

        func record(_ id: String, _ result: LibraryIndex.VectorResult) throws {
            switch result {
            case .faces, .image: state.ok += 1
            case .waitingForPixels: state.waitingForPixels += 1
            case .failed: state.failed += 1
            }
            state.done += 1
            pending.append((id, result))
            if pending.count >= options.batchSize {
                try index.saveVectors(pending, model: model)
                pending.removeAll(keepingCapacity: true)
                state.seconds = Date().timeIntervalSince(started)
                progress?(state)
            }
        }

        try await withThrowingTaskGroup(of: (String, LibraryIndex.VectorResult).self) { group in
            var next = queue.makeIterator()
            func launch() {
                guard let id = next.next() else { return }
                let network = shared.contains(id)
                group.addTask {
                    switch await loader.load(id, maxSide: maxSide, minSide: minSide, network: network) {
                    case .image(let image):
                        do {
                            var result = try work(image)
                            if case .faces(let faces) = result {
                                result = .faces(faces.map { var f = $0; f.assetID = id; return f })
                            }
                            return (id, result)
                        } catch {
                            return (id, .failed)
                        }
                    case .tooSmall, .unavailable: return (id, .waitingForPixels)
                    case .missing: return (id, .failed)
                    }
                }
            }
            for _ in 0..<max(1, options.workers) { launch() }
            while let (id, result) = try await group.next() {
                try record(id, result)
                try Task.checkCancellation()
                launch()
            }
        }
        try index.saveVectors(pending, model: model)
        state.seconds = Date().timeIntervalSince(started)
        progress?(state)
        return state
    }
}
