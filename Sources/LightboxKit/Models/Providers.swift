import CoreGraphics
import Foundation

/// The jobs lightbox gives to models, each a protocol so the model behind it can change.
///
/// Models change every few months; the jobs and the owner's ground truth don't. A provider
/// names itself (`model`), every stored result carries that name, and `lightbox eval` scores a
/// new provider against the same ground truth before it replaces the old one. LightboxKit
/// defines the jobs and stores the results; runtimes and weights live in `LightboxModels`, so
/// an app linking only LightboxKit ships no model runtime.

/// Turns aligned face crops into identity vectors: close vectors, same person.
public protocol FaceEmbedder: Sendable {
    /// Stored with every vector, e.g. "arcface-r50". Change it when the vectors change.
    var model: String { get }
    /// The square crop side the model expects (112 for the ArcFace family).
    var cropSide: Int { get }
    /// Where the eyes, nose tip and mouth corners must land in a `cropSide` crop, top-left origin,
    /// in that order (image-left eye first).
    var template: [CGPoint] { get }
    /// One L2-normalised vector per crop.
    func embed(faces: [CGImage]) throws -> [[Float]]
}

/// Puts photos and text in one space, so text can find photos and photos can find their like.
public protocol ImageTextEmbedder: Sendable {
    var model: String { get }
    /// The square side images are resized to.
    var imageSide: Int { get }
    /// One L2-normalised vector per image.
    func embed(images: [CGImage]) throws -> [[Float]]
    /// One L2-normalised vector per text.
    func embed(texts: [String]) throws -> [[Float]]
}

extension FaceEmbedder {
    /// The five-point template every InsightFace ArcFace model was trained on (112×112).
    public static var arcFaceTemplate: [CGPoint] {
        [CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
         CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041)]
    }
}
