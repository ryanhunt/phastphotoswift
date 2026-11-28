import Foundation
import PhastPhotoImaging
import Vision

/// One recognised line of text, Vision's confidence in it, and where it is.
public struct RecognizedLine: Hashable, Sendable {
    public var text: String
    public var confidence: Float
    /// Where the line is in the image that was read, in its stored orientation.
    public var box: NormalizedBox?
    public init(text: String, confidence: Float, box: NormalizedBox? = nil) {
        self.text = text
        self.confidence = confidence
        self.box = box
    }
}

public struct BackReading: Hashable, Sendable {
    /// Lines of the winning orientation (confidence >= 0.4), in Vision's order.
    public var lines: [String]
    /// Where each of ``lines`` is, in the stored orientation of the image that was read (same order).
    public var boxes: [NormalizedBox?] = []
    /// Clockwise degrees (0, 90, 180, 270) of the winning orientation; nil when nothing was read.
    public var rotation: Int?
    public var text: String { lines.joined(separator: "\n") }

    public init(lines: [String], boxes: [NormalizedBox?] = [], rotation: Int?) {
        self.lines = lines
        self.boxes = boxes
        self.rotation = rotation
    }

    /// The lines, each marked as pen or not by the ink under its box in `image` (the image that was read, at any
    /// size), for ``BackText/humanText(_:)-([BackLine])``.
    public func backLines(in image: RGBImage) -> [BackLine] {
        let paper = PenInk.paper(of: image)
        return lines.enumerated().map { i, text in
            let box = i < boxes.count ? boxes[i] : nil
            return BackLine(text: text, penInk: box.map { PenInk.isWritten(in: image, box: $0, paper: paper) } ?? false)
        }
    }
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
        var best: (score: Float, index: Int?, lines: [RecognizedLine]) = (0, nil, [])
        for (index, candidate) in candidates.enumerated() {
            let reads = candidate.filter { $0.confidence >= minConfidence }
            let score = reads.reduce(Float(0)) { $0 + $1.confidence * Float($1.text.count) }
            if score > best.score { best = (score, index, reads) }
        }
        return BackReading(lines: best.lines.map(\.text), boxes: best.lines.map(\.box), rotation: best.index.map { $0 * 90 })
    }

    /// Maps a Vision bounding box (normalised, origin bottom-left, in the upright image Vision saw) back to the
    /// stored image, which Vision was told is turned `quarterTurns` x 90 degrees (index into
    /// `VisionOrientations.all`: up, right, down, left).
    public static func storedBox(fromVision rect: CGRect, quarterTurns: Int) -> NormalizedBox {
        // upright, origin top-left
        let ux0 = Double(rect.minX), ux1 = Double(rect.maxX)
        let uy0 = 1 - Double(rect.maxY), uy1 = 1 - Double(rect.minY)
        func stored(_ x: Double, _ y: Double) -> (Double, Double) {
            switch ((quarterTurns % 4) + 4) % 4 {
            case 1: (y, 1 - x)  // .right: shown turned 90 degrees clockwise
            case 2: (1 - x, 1 - y)
            case 3: (1 - y, x)  // .left: shown turned 90 degrees anticlockwise
            default: (x, y)
            }
        }
        let a = stored(ux0, uy0), b = stored(ux1, uy1)
        return NormalizedBox(x0: min(a.0, b.0), y0: min(a.1, b.1), x1: max(a.0, b.0), y1: max(a.1, b.1))
    }

    /// Reads `image` (the stored scan of a back, in any orientation). Apply the human-text filter and the
    /// ink gate (``BackPolicy``) around this; ``humanText(of:timeout:)`` does the filter with the pen check.
    public static func read(_ image: RGBImage, timeout: Double? = 120) async throws -> BackReading {
        let small = image.thumbnail(maxPixelSize: maxPixelSize)
        return try await withVisionTimeout(seconds: timeout) {
            let cg = small.cgImage()
            var candidates: [[RecognizedLine]] = []
            for (turns, orientation) in VisionOrientations.all.enumerated() {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.automaticallyDetectsLanguage = true
                // orient.swift swallows per-orientation errors (a failed one scores 0)
                try? perform(request, on: cg, orientation: orientation)
                candidates.append((request.results ?? []).compactMap { observation in
                    observation.topCandidates(1).first.map {
                        RecognizedLine(text: $0.string, confidence: $0.confidence,
                                       box: storedBox(fromVision: observation.boundingBox, quarterTurns: turns))
                    }
                })
            }
            return best(of: candidates)
        }
    }

    /// The person-written text on a back: ``read(_:timeout:)``, each line checked for pen ink (``PenInk``), then
    /// ``BackText/humanText(_:)-([BackLine])``.
    public static func humanText(of image: RGBImage, timeout: Double? = 120) async throws -> String {
        let reading = try await read(image, timeout: timeout)
        return BackText.humanText(reading.backLines(in: image))
    }
}
