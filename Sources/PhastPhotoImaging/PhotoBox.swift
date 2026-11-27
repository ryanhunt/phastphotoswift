import Foundation

/// Axis-aligned box in pixels, `x0 ..< x1` by `y0 ..< y1`.
public struct PhotoBox: Hashable, Sendable {
    public var x0: Int
    public var y0: Int
    public var x1: Int
    public var y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }

    public var width: Int { x1 - x0 }
    public var height: Int { y1 - y0 }

    /// Bounding box of the photo in a scan thumbnail, against the scanner's flat backing.
    ///
    /// Port of ffscan `find_photo_box` (`ff680w.py:103-128`; upstream commit a041a3f). The background colour is
    /// sampled just inside the left and right edges. A pixel is picture when it differs from the background by more
    /// than `threshold` (sum of channel deltas) or is clearly more colourful than it (pale sky is as bright as the
    /// backing), and is not pure white (>= 250, the scanner's deskew corner fill). Rows are decided first, then
    /// columns only inside those rows, then rows again inside the columns, so a full-width dark band above or below
    /// the photo cannot mark every column. Returns the whole image when nothing is found.
    public static func find(in image: RGBImage, threshold: Int = 40) -> PhotoBox {
        let w = image.width, h = image.height
        let bg = background(of: image)
        let tint = bg.chroma
        var fg = [Bool](repeating: false, count: w * h)
        image.pixels.withUnsafeBufferPointer { px in
            fg.withUnsafeMutableBufferPointer { out in
                for i in 0 ..< w * h {
                    let r = Int(px[i * 3]), g = Int(px[i * 3 + 1]), b = Int(px[i * 3 + 2])
                    let lo = min(r, g, b), hi = max(r, g, b)
                    let dist = abs(r - Int(bg.r)) + abs(g - Int(bg.g)) + abs(b - Int(bg.b))
                    out[i] = (dist > threshold || hi - lo > tint + 12) && lo < 250
                }
            }
        }
        let whole = PhotoBox(x0: 0, y0: 0, x1: w, y1: h)
        // rows first
        var rowFlags = [Bool](repeating: false, count: h)
        for y in 0 ..< h {
            var n = 0
            for x in 0 ..< w where fg[y * w + x] { n += 1 }
            rowFlags[y] = Double(n) > Double(w) * 0.05
        }
        guard let rows = longestRun(rowFlags) else { return whole }
        // columns, counted only inside those rows
        var colCount = [Int](repeating: 0, count: w)
        for y in rows { for x in 0 ..< w where fg[y * w + x] { colCount[x] += 1 } }
        let rowSpan = Double(rows.upperBound - rows.lowerBound)
        guard let cols = longestRun(colCount.map { Double($0) > rowSpan * 0.3 }) else { return whole }
        // rows again, inside the columns
        let colSpan = Double(cols.upperBound - cols.lowerBound)
        var refined = [Bool](repeating: false, count: h)
        for y in 0 ..< h {
            var n = 0
            for x in cols where fg[y * w + x] { n += 1 }
            refined[y] = Double(n) > colSpan * 0.3
        }
        let finalRows = longestRun(refined) ?? rows
        return PhotoBox(x0: cols.lowerBound, y0: finalRows.lowerBound, x1: cols.upperBound, y1: finalRows.upperBound)
    }

    /// Median colour of the scanner backing, sampled 1.5-3% in from the left and right edges: the outermost columns
    /// of 300 dpi scans are a different colour than the backing, and even an 8" photo leaves this band clear.
    /// Port of ffscan `_background` (`ff680w.py:131-138`), in R, G, B order.
    public static func background(of image: RGBImage) -> RGB {
        let w = image.width, h = image.height
        let first = Int(Double(w) * 0.015)
        let band = first ..< max(Int(Double(w) * 0.03), first + 1)
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var count = 0
        for y in 0 ..< h {
            for bx in band {
                for x in [bx, w - 1 - bx] where x >= 0 && x < w {
                    let o = (y * w + x) * 3
                    for c in 0 ..< 3 { hist[c][Int(image.pixels[o + c])] += 1 }
                    count += 1
                }
            }
        }
        guard count > 0 else { return RGB(0, 0, 0) }
        let m = (0 ..< 3).map { CropSampling.median(hist: hist[$0], count: count) }
        return RGB(UInt8(m[0]), UInt8(m[1]), UInt8(m[2]))
    }

    /// Range of the longest run of `true`, bridging gaps of up to `gap`; thin edge artefacts lose to the photo.
    /// Port of ffscan `_longest_run` (`ff680w.py:298-310`).
    public static func longestRun(_ flags: [Bool], gap: Int = 3) -> Range<Int>? {
        var best: Range<Int>?
        var start: Int?
        var last = 0
        let padded = flags + [Bool](repeating: false, count: gap + 1)
        for (i, f) in padded.enumerated() {
            if f {
                if start == nil || i - last > gap + 1 { start = i }
                last = i
            } else if let s = start, i - last > gap {
                if best == nil || last + 1 - s > best!.count { best = s ..< last + 1 }
                start = nil
            }
        }
        return best
    }
}
