import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A labelled grid of photos, rendered as one JPEG.
///
/// This is how a model looks through a library. Twenty photos on one sheet are one image in
/// its context instead of twenty, and every tile carries a big number the model can refer
/// back to ("#7 and #12 are the best"). `Key` maps those numbers to local identifiers.
public struct ContactSheet: Sendable {
    public struct Tile: Sendable {
        public var id: String
        /// One short line under the photo, e.g. the date and a score.
        public var caption: String

        public init(id: String, caption: String = "") {
            self.id = id
            self.caption = caption
        }
    }

    public struct Entry: Sendable, Encodable {
        public var number: Int
        public var id: String
        public var caption: String
        /// Pixels the tile was drawn from; 0 when nothing local could be loaded.
        public var sourceLongSide: Int
    }

    public struct Rendered: Sendable {
        public var jpeg: Data
        public var key: [Entry]
    }

    public var columns = 5
    /// Width of one tile in pixels. Tiles are square; photos are fitted, not cropped, so a
    /// model sees the whole frame.
    public var tileSize = 360
    public var maxSide = 768
    public var jpegQuality = 0.82

    public init() {}

    /// Renders photos from the library, numbered from `firstNumber`. Any local rendition will
    /// do for a sheet, even a thumbnail; tiles with nothing local say so.
    public func render(_ tiles: [Tile], firstNumber: Int = 1, loader: ImageLoader = ImageLoader(),
                       concurrency: Int = 8) async throws -> Rendered {
        let side = maxSide
        return try await render(tiles, firstNumber: firstNumber, concurrency: concurrency) { id in
            if case .image(let image) = await loader.load(id, maxSide: side, minSide: 1) { return image }
            return nil
        }
    }

    /// Renders with any image source. Used by tests, and by apps that already hold the pixels.
    public func render(_ tiles: [Tile], firstNumber: Int = 1, concurrency: Int = 8,
                       image load: @escaping @Sendable (String) async -> CGImage?) async throws -> Rendered {
        var images = [CGImage?](repeating: nil, count: tiles.count)
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            var next = 0
            func launch() {
                guard next < tiles.count else { return }
                let index = next, id = tiles[index].id
                next += 1
                group.addTask { (index, await load(id)) }
            }
            for _ in 0..<max(1, concurrency) { launch() }
            for await (index, image) in group {
                images[index] = image
                launch()
            }
        }

        let columns = max(1, min(self.columns, tiles.count))
        let rows = max(1, (tiles.count + columns - 1) / columns)
        let captionHeight = 34, gap = 6
        let cellHeight = tileSize + captionHeight
        let width = columns * tileSize + (columns + 1) * gap
        let height = rows * cellHeight + (rows + 1) * gap

        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw DatabaseError(description: "cannot allocate a \(width)×\(height) sheet")
        }
        context.interpolationQuality = .high
        context.setFillColor(gray: 0.08, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var key: [Entry] = []
        for (index, tile) in tiles.enumerated() {
            let column = index % columns, row = index / columns
            // CoreGraphics' origin is bottom-left; lay rows out from the top.
            let x = gap + column * (tileSize + gap)
            let y = height - (row + 1) * (cellHeight + gap)
            let photoRect = CGRect(x: x, y: y + captionHeight, width: tileSize, height: tileSize)
            let number = firstNumber + index

            context.setFillColor(gray: 0.13, alpha: 1)
            context.fill(photoRect)
            if let image = images[index] {
                context.draw(image, in: Self.fit(CGSize(width: image.width, height: image.height), in: photoRect))
            } else {
                Self.draw("no local pixels", at: CGPoint(x: photoRect.midX - 52, y: photoRect.midY),
                          size: 14, gray: 0.6, in: context)
            }

            // The number, big, on a dark chip in the corner, so it survives downscaling.
            let label = "#\(number)"
            let chip = CGRect(x: x + 6, y: Int(photoRect.maxY) - 40, width: 18 + 17 * label.count, height: 34)
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.72)
            context.fill(chip)
            Self.draw(label, at: CGPoint(x: chip.minX + 8, y: chip.minY + 8), size: 24, gray: 1, bold: true, in: context)

            let caption = tile.caption.isEmpty ? Self.shortID(tile.id) : "\(Self.shortID(tile.id))  \(tile.caption)"
            Self.draw(caption, at: CGPoint(x: x + 4, y: y + 11), size: 15, gray: 0.85, in: context)

            key.append(Entry(number: number, id: tile.id, caption: tile.caption,
                             sourceLongSide: images[index].map { max($0.width, $0.height) } ?? 0))
        }

        guard let sheet = context.makeImage() else { throw DatabaseError(description: "cannot render the sheet") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DatabaseError(description: "cannot encode JPEG")
        }
        CGImageDestinationAddImage(destination, sheet,
                                   [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DatabaseError(description: "cannot encode JPEG") }
        return Rendered(jpeg: data as Data, key: key)
    }

    /// The first 8 characters of the UUID: enough to find a photo again, short enough to read.
    public static func shortID(_ id: String) -> String { String(id.prefix(8)) }

    static func fit(_ size: CGSize, in box: CGRect) -> CGRect {
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, gray: CGFloat, bold: Bool = false,
                             in context: CGContext) {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
