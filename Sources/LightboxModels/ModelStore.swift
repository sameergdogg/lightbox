import Foundation

/// Where model weights live on this Mac, and how to get them.
///
/// Weights are downloaded on request, never bundled: some (InsightFace's) are licensed for
/// non-commercial use only, and the person running lightbox should see that before using them.
public struct ModelStore: Sendable {
    public enum Model: String, CaseIterable, Sendable {
        case arcface
        case siglip2

        public var about: String {
            switch self {
            case .arcface:
                return "InsightFace ArcFace R50 (buffalo_l), face identity. ~170 MB. Weights: non-commercial research use only (InsightFace)."
            case .siglip2:
                return "Google SigLIP 2 B/16 224 px (ONNX export by onnx-community), image–text search. ~1.5 GB. Apache-2.0."
            }
        }

        /// (URL, file name in the model folder, and, for a zip, the member to keep).
        var downloads: [(url: String, file: String, member: String?)] {
            switch self {
            case .arcface:
                return [("https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip", "w600k_r50.onnx", "w600k_r50.onnx")]
            case .siglip2:
                let base = "https://huggingface.co/onnx-community/siglip2-base-patch16-224-ONNX/resolve/main/"
                return ["onnx/vision_model.onnx", "onnx/text_model.onnx", "tokenizer.json", "tokenizer_config.json",
                        "special_tokens_map.json", "config.json", "preprocessor_config.json"]
                    .map { (base + $0, ($0 as NSString).lastPathComponent, nil) }
            }
        }

        var folderName: String { self == .siglip2 ? "siglip2-base" : rawValue }
    }

    public let root: URL

    public init(root: URL = URL.applicationSupportDirectory.appending(path: "lightbox/models", directoryHint: .isDirectory)) {
        self.root = root
    }

    public func folder(_ model: Model) throws -> URL {
        let url = root.appending(path: model.folderName, directoryHint: .isDirectory)
        guard isInstalled(model) else {
            throw ModelError("\(model.rawValue) isn't installed; run `lightbox models pull \(model.rawValue)`")
        }
        return url
    }

    public func file(_ model: Model, _ name: String) throws -> URL {
        try folder(model).appending(path: name)
    }

    public func isInstalled(_ model: Model) -> Bool {
        let folder = root.appending(path: model.folderName, directoryHint: .isDirectory)
        return model.downloads.allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0.file).path) }
    }

    /// Downloads whatever is missing. `progress` gets a line per file.
    public func pull(_ model: Model, progress: (String) -> Void) async throws {
        let folder = root.appending(path: model.folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in model.downloads {
            let target = folder.appending(path: item.file)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            progress("downloading \(item.url)")
            let (temporary, response) = try await URLSession.shared.download(from: URL(string: item.url)!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ModelError("download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)): \(item.url)")
            }
            if let member = item.member {
                // A zip: keep one file from it.
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-o", "-j", temporary.path, member, "-d", folder.path]
                unzip.standardOutput = FileHandle.nullDevice
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else { throw ModelError("could not unpack \(member) from \(item.url)") }
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        }
    }
}
