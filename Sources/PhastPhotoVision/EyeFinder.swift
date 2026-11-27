import Foundation
import PhastPhotoImaging
import Vision

public struct Eye: Hashable, Sendable {
    /// Centre and radius in pixels of the image passed in (stored orientation).
    public var x: Double
    public var y: Double
    public var radius: Double
    public init(x: Double, y: Double, radius: Double) {
        self.x = x
        self.y = y
        self.radius = radius
    }
}

/// Eyes from Vision face landmarks for red-eye removal. Ports `tools/orient.swift:69-89` and `find_eyes`
/// (`enhance.py:14-21`). Untested on real flash photos upstream too.
public enum EyeFinder {
    public static let maxPixelSize = 3000
    public static let minConfidence: Float = 0.5

    /// An eye as fractions (origin top-left; radius as a fraction of image width), scaled to pixels
    /// (`enhance.py:20`: x*w, y*h, r*w).
    public static func eye(fractionX: Double, fractionY: Double, fractionRadius: Double, width: Int, height: Int) -> Eye {
        Eye(x: fractionX * Double(width), y: fractionY * Double(height), radius: fractionRadius * Double(width))
    }

    /// Maps an eye contour (points normalised to the face box, Vision origin bottom-left) to the whole image:
    /// centre of the contour's bounding box, half its width as radius, y flipped to top-left.
    /// Returns nil for an empty contour.
    public static func eyeFraction(contour: [CGPoint], faceBox: CGRect) -> (x: Double, y: Double, radius: Double)? {
        let pts = contour.map { CGPoint(x: faceBox.minX + $0.x * faceBox.width, y: faceBox.minY + $0.y * faceBox.height) }
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return nil }
        return (Double((minX + maxX) / 2), Double(1 - (minY + maxY) / 2), Double((maxX - minX) / 2))
    }

    /// Eyes (pixels of `image`) of faces with confidence above 0.5: left then right eye per face.
    public static func findEyes(in image: RGBImage, timeout: Double? = 90) async throws -> [Eye] {
        let small = image.thumbnail(maxPixelSize: maxPixelSize)
        let fractions: [Fraction] = try await withVisionTimeout(seconds: timeout) {
            let request = VNDetectFaceLandmarksRequest()
            try perform(request, on: small.cgImage())
            var out: [Fraction] = []
            for face in request.results ?? [] where face.confidence > minConfidence {
                for region in [face.landmarks?.leftEye, face.landmarks?.rightEye].compactMap({ $0 }) {
                    if let f = eyeFraction(contour: region.normalizedPoints, faceBox: face.boundingBox) {
                        out.append(Fraction(x: f.x, y: f.y, radius: f.radius))
                    }
                }
            }
            return out
        }
        return fractions.map { eye(fractionX: $0.x, fractionY: $0.y, fractionRadius: $0.radius, width: image.width, height: image.height) }
    }

    private struct Fraction: Sendable { var x: Double, y: Double, radius: Double }
}

extension Eye {
    /// This eye as the input red-eye removal takes (`RGBImage.removingRedEye` in PhastPhotoImaging).
    public var position: EyePosition { EyePosition(x: x, y: y, radius: radius) }
}
