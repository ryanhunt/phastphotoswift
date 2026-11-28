import Foundation

/// A rectangle as fractions of an image's width and height (0...1), origin top-left, in the image's stored
/// orientation.
public struct NormalizedBox: Hashable, Sendable {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }

    /// The box in pixels of a `width` x `height` image, clamped to it; nil when nothing of it is inside.
    public func pixels(width: Int, height: Int) -> PhotoBox? {
        func clamp(_ v: Double, _ n: Int) -> Int { min(n, max(0, Int((v * Double(n)).rounded()))) }
        let box = PhotoBox(x0: clamp(min(x0, x1), width), y0: clamp(min(y0, y1), height),
                           x1: clamp(max(x0, x1), width), y1: clamp(max(y0, y1), height))
        return box.width > 0 && box.height > 0 ? box : nil
    }
}

/// Whether a line of text on a print's back was written in pen (or stamped) rather than printed faintly by the paper
/// maker. Not in ffscan: added so a back with one handwritten word ("Mum", a name) is not dropped as blank.
///
/// The paper maker's pattern ("Fujicolor Crystal Archive Paper") and a lab's dot-matrix code are pale: on the first
/// four real backs (FF-680W, 300 dpi, 28 Nov 2026) no pixel under a recognised line of either differed from the paper
/// by more than ``strongDifference``, apart from isolated specks. Under one word in blue ballpoint, 7% of the line's
/// box did. ``minStrongShare`` sits well inside that gap; with one real handwritten back it is provisional (roadmap
/// 1.2).
public enum PenInk {
    /// Summed channel difference from the paper that counts as strong ink.
    public static let strongDifference = 150
    /// Share of a line's box in strong ink that makes it pen.
    public static let minStrongShare = 0.01

    /// The paper colour: the per-channel median of the back, as ``InkFraction`` takes it (600 px thumbnail, 4%
    /// border ignored, every second pixel).
    public static func paper(of image: RGBImage) -> RGB {
        let t = image.thumbnail(maxPixelSize: 600)
        let w = t.width, h = t.height
        let bx = Int(Double(w) * 0.04), by = Int(Double(h) * 0.04)
        guard h - by > by, w - bx > bx else { return RGB(255, 255, 255) }
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var count = 0
        t.pixels.withUnsafeBufferPointer { p in
            for y in stride(from: by, to: h - by, by: 2) {
                for x in stride(from: bx, to: w - bx, by: 2) {
                    let o = (y * w + x) * 3
                    hist[0][Int(p[o])] += 1; hist[1][Int(p[o + 1])] += 1; hist[2][Int(p[o + 2])] += 1
                    count += 1
                }
            }
        }
        let m = (0 ..< 3).map { UInt8(CropSampling.median(hist: hist[$0], count: count)) }
        return RGB(m[0], m[1], m[2])
    }

    /// Share of the pixels in `box` whose summed channel difference from `paper` exceeds `threshold`.
    public static func strongShare(in image: RGBImage, box: NormalizedBox, paper: RGB,
                                   threshold: Int = strongDifference) -> Double {
        guard let b = box.pixels(width: image.width, height: image.height) else { return 0 }
        let w = image.width
        let pr = Int(paper.r), pg = Int(paper.g), pb = Int(paper.b)
        var strong = 0
        image.pixels.withUnsafeBufferPointer { p in
            for y in b.y0 ..< b.y1 {
                for x in b.x0 ..< b.x1 {
                    let o = (y * w + x) * 3
                    if abs(Int(p[o]) - pr) + abs(Int(p[o + 1]) - pg) + abs(Int(p[o + 2]) - pb) > threshold { strong += 1 }
                }
            }
        }
        return Double(strong) / Double(b.width * b.height)
    }

    /// True when the text in `box` is written in strong ink (pen, pencil pressed hard, a stamp).
    public static func isWritten(in image: RGBImage, box: NormalizedBox, paper: RGB) -> Bool {
        strongShare(in: image, box: box, paper: paper) >= minStrongShare
    }
}
