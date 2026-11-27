import Foundation
import PhastPhotoImaging
import Vision

public struct RotationDecision: Hashable, Sendable {
    /// Clockwise degrees the print is turned (0, 90, 180, 270): rotate it back by this much, or write it as
    /// the orientation tag.
    public var degrees: Int
    /// False means "no opinion": leave as scanned (and let an app fall back to something else, e.g. AI).
    public var decided: Bool
    public init(degrees: Int, decided: Bool) {
        self.degrees = degrees
        self.decided = decided
    }
}

/// Orientation of a scanned picture from Vision. Ports `tools/orient.swift:31-47, 91-105` and
/// `app.py:123-141` (`auto_rotation`).
public enum AutoRotation {
    public static let faceMaxPixelSize = 1024
    public static let faceMinConfidence: Float = 0.5
    public static let sceneMaxPixelSize = 512
    /// `SCENE_MARGIN` (`app.py:123`): measured on 14 photos on one OS; re-measure on each supported OS.
    public static let sceneMargin = 1.0

    /// Median face roll (radians, upper median of the sorted list) snapped to 90 degrees, in 0..<360.
    /// `orient.swift:98-104`. The roll sign is unconfirmed on real photos.
    public static func degrees(faceRolls rolls: [Double]) -> Int {
        guard !rolls.isEmpty else { return 0 }
        let sorted = rolls.sorted()
        let roll = sorted[sorted.count / 2] * 180 / .pi
        return (Int((roll / 90).rounded()) * 90 % 360 + 360) % 360
    }

    /// Scene scores for 0, 90, 180, 270 (`orient.swift:31-47`, `app.py:138-141`): the first best orientation
    /// wins only if it beats "as scanned" by at least `margin`.
    public static func decide(sceneScores scores: [Double], margin: Double = sceneMargin) -> RotationDecision {
        guard scores.count == 4, let top = scores.max(), let best = scores.firstIndex(of: top) else {
            return RotationDecision(degrees: 0, decided: false)
        }
        if top - scores[0] >= margin { return RotationDecision(degrees: best * 90, decided: true) }
        return RotationDecision(degrees: 0, decided: false)
    }

    /// Faces decide when there are any (`app.py:129-136`), otherwise `sceneScores` is asked (lazily: the
    /// four classifier runs are skipped when a face decides).
    public static func decide(faceRolls rolls: [Double], sceneScores: () throws -> [Double]) rethrows -> RotationDecision {
        if !rolls.isEmpty { return RotationDecision(degrees: degrees(faceRolls: rolls), decided: true) }
        return decide(sceneScores: try sceneScores())
    }

    /// Roll of each face with confidence above 0.5, on the image at most 1024 px.
    public static func faceRolls(_ image: RGBImage, timeout: Double? = 60) async throws -> [Double] {
        let small = image.thumbnail(maxPixelSize: faceMaxPixelSize)
        return try await withVisionTimeout(seconds: timeout) {
            let request = VNDetectFaceRectanglesRequest()
            try perform(request, on: small.cgImage())
            return (request.results ?? []).filter { $0.confidence > faceMinConfidence }.compactMap { $0.roll?.doubleValue }
        }
    }

    /// Per rotation (0, 90, 180, 270), the summed confidence of the five best scene labels, image at most 512 px.
    public static func sceneScores(_ image: RGBImage, timeout: Double? = 60) async throws -> [Double] {
        let small = image.thumbnail(maxPixelSize: sceneMaxPixelSize)
        return try await withVisionTimeout(seconds: timeout) {
            let cg = small.cgImage()
            return VisionOrientations.all.map { orientation in
                let request = VNClassifyImageRequest()
                try? perform(request, on: cg, orientation: orientation)
                let top = (request.results ?? []).sorted { $0.confidence > $1.confidence }.prefix(5)
                return top.reduce(0.0) { $0 + Double($1.confidence) }
            }
        }
    }

    /// Faces first, then the scene classifier, as `auto_rotation` does. A Vision failure or timeout gives
    /// "no opinion" rather than an error, like upstream when the helper is missing.
    public static func rotation(of image: RGBImage, timeout: Double? = 60) async -> RotationDecision {
        let undecided = RotationDecision(degrees: 0, decided: false)
        guard let rolls = try? await faceRolls(image, timeout: timeout) else { return undecided }
        if !rolls.isEmpty { return decide(faceRolls: rolls, sceneScores: { [] }) }
        guard let scores = try? await sceneScores(image, timeout: timeout) else { return undecided }
        return decide(sceneScores: scores)
    }
}
