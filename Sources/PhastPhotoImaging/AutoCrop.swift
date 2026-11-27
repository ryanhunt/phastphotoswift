import Foundation

/// Crops a scan to the print: finds its four corners, maps them onto an upright rectangle (which straightens a
/// tilted print and squares one that was not cut quite square), then trims leftover backing.
///
/// Port of ffscan `autocrop` (`ff680w.py:353-385`), `trim_backing` (`:245-274`) and `inside` (`:277-295`);
/// upstream commit a041a3f. Analysis runs on thumbnails (600 px for the coarse box, at most 3000 px for the edge
/// fit); only the final warp touches full-resolution pixels.
public enum AutoCrop {
    /// What the crop was based on.
    public enum Source: Hashable, Sendable {
        /// The four fitted corners, in full-resolution pixels of the input.
        case quad(PhotoQuad)
        /// The fit failed; the coarse box in full-resolution pixels of the input.
        case box(PhotoBox)
    }

    public struct Result: Sendable {
        /// The cropped (and, for a quad, straightened) image.
        public var image: RGBImage
        public var source: Source
        public var width: Int { image.width }
        public var height: Int { image.height }
    }

    /// Crop `image` to the photo. `margin` (share of the print's longer side) drops the soft edge.
    public static func crop(_ image: RGBImage, margin: Double = 0.004) -> Result {
        let thumb = image.thumbnail(maxPixelSize: 600)
        let bg = PhotoBox.background(of: thumb)
        let source: Source
        var work: RGBImage
        var box: PhotoBox
        var scanned: [UInt8]?
        if let quad = PhotoQuad.fit(image: image, thumbnail: thumb, background: bg) {
            let (w, h) = quad.size
            let warped = CropSampling.quadWarp(image, corners: quad.corners.map { ($0.x, $0.y) },
                                               width: max(1, w), height: max(1, h))
            work = warped.image
            scanned = warped.valid
            box = PhotoBox(x0: 0, y0: 0, x1: work.width, y1: work.height)
            source = .quad(quad)
        } else {
            let scale = Double(image.width) / Double(thumb.width)
            let coarse = PhotoBox.find(in: thumb)
            box = PhotoBox(x0: Int(Double(coarse.x0) * scale), y0: Int(Double(coarse.y0) * scale),
                           x1: Int(Double(coarse.x1) * scale), y1: Int(Double(coarse.y1) * scale))
            work = image
            source = .box(box)
        }
        let m = Int((margin * Double(max(box.width, box.height))).rounded(.toNearestOrEven))
        box = PhotoBox(x0: box.x0 + m, y0: box.y0 + m, x1: box.x1 - m, y1: box.y1 - m)
        box = trimBacking(work, box: box, background: bg)
        if let scanned { box = inside(valid: scanned, stride: work.width, height: work.height, box: box) }
        return Result(image: work.cropped(x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1), source: source)
    }

    /// Decode, crop and re-encode a scan once at quality 0.95, keeping the original's EXIF, XMP, ICC profile and DPI.
    public static func cropJPEG(_ data: Data, margin: Double = 0.004) throws -> (jpeg: Data, width: Int, height: Int) {
        let result = crop(try RGBImage.decode(data), margin: margin)
        let jpeg = try result.image.jpegData(quality: 0.95, copyingMetadataFrom: data)
        return (jpeg, result.width, result.height)
    }

    /// Move each side of `box` inward past lines that are flat: the backing or the shadow along the print's edge
    /// (std <= 5, near-neutral, 75-100% of the backing's brightness; picture lines vary 30-70), at most 3% per
    /// side; or a thin flat bright line, the paper showing at the print's cut edge, at most 0.6% (a real white print
    /// border is wider and stays). Port of ffscan `trim_backing`.
    static func trimBacking(_ im: RGBImage, box: PhotoBox, background bg: RGB, step: Int = 4,
                            maxShare: Double = 0.03, edgeShare: Double = 0.006) -> PhotoBox {
        let luma = Double(Int(bg.r) + Int(bg.g) + Int(bg.b)) / 3

        enum Line { case backing, paper }
        func kind(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Line? {
            let st = CropSampling.stats(im, x0: x0, y0: y0, x1: x1, y1: y1)
            let mean = (st.mean[0] + st.mean[1] + st.mean[2]) / 3
            if (st.std[0] + st.std[1] + st.std[2]) / 3 >= 8 || st.mean.max()! - st.mean.min()! >= 15 || mean < 0.65 * luma {
                return nil  // picture (a flat dark area of the photo is darker than any shadow)
            }
            return mean < luma + 25 ? .backing : .paper
        }

        let (x0, y0, x1, y1) = (box.x0, box.y0, box.x1, box.y1)
        let iy0 = y0 + (y1 - y0) / 10, iy1 = y1 - (y1 - y0) / 10
        let ix0 = x0 + (x1 - x0) / 10, ix1 = x1 - (x1 - x0) / 10

        func trim(_ start: Int, inward: Int, size: Int, line: (Int) -> Line?) -> Int {
            var pos = start
            while let k = line(pos) {
                let limit = Double(size) * (k == .backing ? maxShare : edgeShare)
                guard Double(abs(pos - start)) < limit else { break }
                pos += inward * step
            }
            return pos
        }

        // like upstream, each later side measures the box with the sides already moved
        let nx0 = trim(x0, inward: 1, size: x1 - x0) { kind($0, iy0, $0 + step, iy1) }
        let nx1 = trim(x1, inward: -1, size: x1 - nx0) { kind($0 - step, iy0, $0, iy1) }
        let ny0 = trim(y0, inward: 1, size: y1 - y0) { kind(ix0, $0, ix1, $0 + step) }
        let ny1 = trim(y1, inward: -1, size: y1 - ny0) { kind(ix0, $0 - step, ix1, $0) }
        return PhotoBox(x0: nx0, y0: ny0, x1: nx1, y1: ny1)
    }

    /// Shrink `box` until every edge line lies on pixels where `valid` (a `stride` x `height` mask) is 255. The side
    /// with the most invalid pixels moves first: a wedge along the top should not also eat into the left side.
    /// Port of ffscan `inside`.
    static func inside(valid: [UInt8], stride: Int, height: Int, box: PhotoBox, step: Int = 2) -> PhotoBox {
        var (x0, y0, x1, y1) = (box.x0, box.y0, box.x1, box.y1)
        func bad(_ ax0: Int, _ ay0: Int, _ ax1: Int, _ ay1: Int) -> Int {
            var n = 0
            for y in max(0, ay0) ..< min(height, ay1) {
                for x in max(0, ax0) ..< min(stride, ax1) where valid[y * stride + x] == 0 { n += 1 }
            }
            return n
        }
        while x1 - x0 > 2 * step, y1 - y0 > 2 * step {
            let sides = [bad(x0, y0, x0 + 1, y1), bad(x1 - 1, y0, x1, y1), bad(x0, y0, x1, y0 + 1), bad(x0, y1 - 1, x1, y1)]
            var worst = 0
            for i in 1 ..< 4 where sides[i] > sides[worst] { worst = i }  // first maximum, like Python's max()
            if sides[worst] == 0 { break }
            switch worst {
            case 0: x0 += step
            case 1: x1 -= step
            case 2: y0 += step
            default: y1 -= step
            }
        }
        return PhotoBox(x0: x0, y0: y0, x1: x1, y1: y1)
    }
}
