import Foundation
import PhastPhotoImaging
import Vision

/// One recognised line of text and Vision's confidence in it.
public struct RecognizedLine: Hashable, Sendable {
    public var text: String
    public var confidence: Float
    public init(text: String, confidence: Float) {
        self.text = text
        self.confidence = confidence
    }
}

public struct BackReading: Hashable, Sendable {
    /// Lines of the winning orientation (confidence >= 0.4), in Vision's order.
    public var lines: [String]
    /// Clockwise degrees (0, 90, 180, 270) of the winning orientation; nil when nothing was read.
    public var rotation: Int?
    public var text: String { lines.joined(separator: "\n") }
}

/// On-device reading of handwriting and stamps on the back of a print. Ports `tools/orient.swift:49-67`
/// (`--text`): 2000 px, all four orientations, `.accurate`, automatic language, lines under 0.4 confidence
/// dropped, the orientation with the largest sum of confidence x length wins.
public enum BackReader {
    public static let maxPixelSize = 2000
    public static let minConfidence: Float = 0.4

    /// Pure choice between the four orientations' candidates (index = 90 degree steps, as in
    /// `VisionOrientations.all`). A candidate must score strictly more than the best so far, starting at 0.
    public static func best(of candidates: [[RecognizedLine]]) -> BackReading {
        var best: (score: Float, index: Int?, lines: [String]) = (0, nil, [])
        for (index, candidate) in candidates.enumerated() {
            let reads = candidate.filter { $0.confidence >= minConfidence }
            let score = reads.reduce(Float(0)) { $0 + $1.confidence * Float($1.text.count) }
            if score > best.score { best = (score, index, reads.map(\.text)) }
        }
        return BackReading(lines: best.lines, rotation: best.index.map { $0 * 90 })
    }

    /// Reads `image` (the stored scan of a back, in any orientation). Apply the human-text filter and the
    /// ink gate (``BackPolicy``) around this.
    public static func read(_ image: RGBImage, timeout: Double? = 120) async throws -> BackReading {
        let small = image.thumbnail(maxPixelSize: maxPixelSize)
        return try await withVisionTimeout(seconds: timeout) {
            let cg = small.cgImage()
            var candidates: [[RecognizedLine]] = []
            for orientation in VisionOrientations.all {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.automaticallyDetectsLanguage = true
                // orient.swift swallows per-orientation errors (a failed one scores 0)
                try? perform(request, on: cg, orientation: orientation)
                candidates.append((request.results ?? []).compactMap { $0.topCandidates(1).first }
                    .map { RecognizedLine(text: $0.string, confidence: $0.confidence) })
            }
            return best(of: candidates)
        }
    }
}
