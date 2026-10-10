import CoreGraphics
import Foundation
import Vision

/// Finds faces with Vision and cuts each into the aligned crop a face model expects.
///
/// Face models are trained on crops where the eyes, nose tip and mouth corners sit at fixed
/// points; a crop that is merely centred on the face box scores far worse. Vision's 76-point
/// landmarks give the five points; a similarity transform (rotation, uniform scale,
/// translation: no shear, so the face isn't distorted) maps them onto the template.
public struct FaceAligner: Sendable {
    /// Faces smaller than this fraction of the frame are skipped: below about 40 px a side,
    /// identity vectors are mostly noise. 0.0015 of a 1600 px photo is about 50 px square.
    public var minFaceArea: Double = 0.0015

    public init() {}

    public struct Face {
        /// Normalised to the image, top-left origin.
        public var box: CGRect
        public var crop: CGImage
    }

    public func faces(in image: CGImage, side: Int, template: [CGPoint]) throws -> [Face] {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { face -> Face? in
            let b = face.boundingBox
            guard Double(b.width * b.height) >= minFaceArea,
                  let points = Self.fivePoints(face, imageSize: size),
                  let crop = Self.crop(image, from: points, to: template, side: side) else { return nil }
            return Face(box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), crop: crop)
        }
    }

    /// Image-left eye, image-right eye, nose, mouth corner under the first eye, mouth corner
    /// under the second; pixels, top-left origin.
    static func fivePoints(_ face: VNFaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let marks = face.landmarks, let eyeA = marks.leftEye, let eyeB = marks.rightEye,
              let nose = marks.nose, let lips = marks.outerLips else { return nil }
        func pixels(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
            region.pointsInImage(imageSize: imageSize).map { CGPoint(x: $0.x, y: imageSize.height - $0.y) }
        }
        func centre(_ points: [CGPoint]) -> CGPoint {
            CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                    y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        var eyes = [centre(pixels(eyeA)), centre(pixels(eyeB))]
        if eyes[0].x > eyes[1].x { eyes.swapAt(0, 1) }
        // Mouth corners: the lip points furthest along the eye line, so a tilted head still
        // pairs each corner with the eye above it.
        let axis = CGPoint(x: eyes[1].x - eyes[0].x, y: eyes[1].y - eyes[0].y)
        let lipPoints = pixels(lips)
        guard let first = lipPoints.min(by: { $0.x * axis.x + $0.y * axis.y < $1.x * axis.x + $1.y * axis.y }),
              let second = lipPoints.max(by: { $0.x * axis.x + $0.y * axis.y < $1.x * axis.x + $1.y * axis.y })
        else { return nil }
        return [eyes[0], eyes[1], centre(pixels(nose)), first, second]
    }

    /// The least-squares similarity transform taking `source` onto `target` (Umeyama), as
    /// x' = a·x − b·y + tx, y' = b·x + a·y + ty.
    static func similarity(from source: [CGPoint], to target: [CGPoint]) -> (a: Double, b: Double, tx: Double, ty: Double)? {
        let n = Double(source.count)
        guard source.count == target.count, source.count >= 2 else { return nil }
        let sx = source.map { Double($0.x) }.reduce(0, +) / n, sy = source.map { Double($0.y) }.reduce(0, +) / n
        let tx = target.map { Double($0.x) }.reduce(0, +) / n, ty = target.map { Double($0.y) }.reduce(0, +) / n
        var dot = 0.0, cross = 0.0, norm = 0.0
        for (s, t) in zip(source, target) {
            let px = Double(s.x) - sx, py = Double(s.y) - sy
            let qx = Double(t.x) - tx, qy = Double(t.y) - ty
            dot += px * qx + py * qy
            cross += px * qy - py * qx
            norm += px * px + py * py
        }
        guard norm > 0 else { return nil }
        let a = dot / norm, b = cross / norm
        return (a, b, tx - (a * sx - b * sy), ty - (b * sx + a * sy))
    }

    /// Draws the aligned `side`×`side` crop.
    static func crop(_ image: CGImage, from points: [CGPoint], to template: [CGPoint], side: Int) -> CGImage? {
        guard let m = similarity(from: points, to: template),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // The transform is in top-left pixel coordinates; Core Graphics draws bottom-up, so
        // flip on both sides: source point (u, v) = (x, H − y), destination Y = side − y'.
        let h = Double(image.height), s = Double(side)
        context.concatenate(CGAffineTransform(a: m.a, b: -m.b, c: m.b, d: m.a,
                                              tx: m.tx - m.b * h, ty: s - m.ty - m.a * h))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
