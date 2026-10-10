import CoreGraphics
import Foundation

/// An 8-bit grayscale copy of an image at a fixed size, and the cheap statistics lightbox
/// computes from it: sharpness and exposure.
///
/// Everything is measured at one size (`side` on the long edge), so numbers are comparable
/// across photos, whatever resolution PhotoKit happened to hand over.
public struct Grayscale: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init?(_ image: CGImage, side: Int = 512) {
        let scale = Double(side) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * min(scale, 1)).rounded()))
        let height = max(1, Int((Double(image.height) * min(scale, 1)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Variance of the 4-neighbour Laplacian over `rect` (pixel coordinates, top-left
    /// origin), or the whole image. Higher means more fine detail in focus. Nil when the
    /// region is too small to say anything.
    public func sharpness(in rect: CGRect? = nil) -> Double? {
        let bounds = (rect ?? CGRect(x: 0, y: 0, width: width, height: height))
            .integral.intersection(CGRect(x: 1, y: 1, width: width - 2, height: height - 2))
        guard !bounds.isNull, bounds.width >= 16, bounds.height >= 16 else { return nil }
        var sum = 0.0, sumSquares = 0.0
        let x0 = Int(bounds.minX), x1 = Int(bounds.maxX), y0 = Int(bounds.minY), y1 = Int(bounds.maxY)
        pixels.withUnsafeBufferPointer { p in
            for y in y0..<y1 {
                let row = y * width
                for x in x0..<x1 {
                    let i = row + x
                    let laplacian = 4 * Int(p[i]) - Int(p[i - 1]) - Int(p[i + 1])
                        - Int(p[i - width]) - Int(p[i + width])
                    let value = Double(laplacian)
                    sum += value
                    sumSquares += value * value
                }
            }
        }
        let n = Double((x1 - x0) * (y1 - y0))
        let mean = sum / n
        return sumSquares / n - mean * mean
    }

    public struct Exposure: Sendable, Equatable, Encodable {
        /// Mean brightness, 0...1.
        public var mean: Double
        /// Fraction of pixels at or above 250 (blown highlights).
        public var highlights: Double
        /// Fraction of pixels at or below 5 (crushed shadows).
        public var shadows: Double
    }

    public var exposure: Exposure {
        var total = 0, bright = 0, dark = 0
        for value in pixels {
            total += Int(value)
            if value >= 250 { bright += 1 } else if value <= 5 { dark += 1 }
        }
        let n = Double(pixels.count)
        return Exposure(mean: Double(total) / n / 255, highlights: Double(bright) / n, shadows: Double(dark) / n)
    }
}
