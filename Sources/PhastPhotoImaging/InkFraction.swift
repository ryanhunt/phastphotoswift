import Foundation

/// Share of a print's pixels that are clearly darker or different than the paper: blank photo backs (including faint
/// maker watermarks) score about 0; handwriting or stamps score higher.
public enum InkFraction {
    /// Ink fraction of the *cropped* image, measured on a 600 px thumbnail.
    public static func of(_ image: RGBImage, threshold: Int = 90, border: Double = 0.04) -> Double {
        of(thumbnail: image.thumbnail(maxPixelSize: 600), threshold: threshold, border: border)
    }

    /// Port of ffscan `ink_fraction` (`ff680w.py:341-350`; upstream commit a041a3f). Ignores a 4% border, looks at
    /// every second pixel each way, takes the per-channel median as the paper and counts pixels whose summed channel
    /// difference from it exceeds `threshold`.
    public static func of(thumbnail image: RGBImage, threshold: Int = 90, border: Double = 0.04) -> Double {
        let w = image.width, h = image.height
        let bx = Int(Double(w) * border), by = Int(Double(h) * border)
        guard h - by > by, w - bx > bx else { return 0 }
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var count = 0
        image.pixels.withUnsafeBufferPointer { p in
            for y in stride(from: by, to: h - by, by: 2) {
                for x in stride(from: bx, to: w - bx, by: 2) {
                    let o = (y * w + x) * 3
                    hist[0][Int(p[o])] += 1; hist[1][Int(p[o + 1])] += 1; hist[2][Int(p[o + 2])] += 1
                    count += 1
                }
            }
        }
        guard count > 0 else { return 0 }
        let paper = (0 ..< 3).map { CropSampling.median(hist: hist[$0], count: count) }
        var ink = 0
        image.pixels.withUnsafeBufferPointer { p in
            for y in stride(from: by, to: h - by, by: 2) {
                for x in stride(from: bx, to: w - bx, by: 2) {
                    let o = (y * w + x) * 3
                    let d = abs(Int(p[o]) - paper[0]) + abs(Int(p[o + 1]) - paper[1]) + abs(Int(p[o + 2]) - paper[2])
                    if d > threshold { ink += 1 }
                }
            }
        }
        return Double(ink) / Double(max(1, count))
    }
}
