import CoreGraphics
import Foundation

/// The four corners of a print, in pixels: upper-left, lower-left, lower-right, upper-right.
public struct PhotoQuad: Hashable, Sendable {
    public var ul: CGPoint
    public var ll: CGPoint
    public var lr: CGPoint
    public var ur: CGPoint

    public init(ul: CGPoint, ll: CGPoint, lr: CGPoint, ur: CGPoint) {
        self.ul = ul; self.ll = ll; self.lr = lr; self.ur = ur
    }

    var corners: [CGPoint] { [ul, ll, lr, ur] }

    /// Mean length of opposite edges: the size of the upright rectangle the quad is mapped onto.
    public var size: (width: Int, height: Int) {
        func dist(_ a: CGPoint, _ b: CGPoint) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
        return (Int(((dist(ul, ur) + dist(ll, lr)) / 2).rounded(.toNearestOrEven)),
                Int(((dist(ul, ll) + dist(ur, lr)) / 2).rounded(.toNearestOrEven)))
    }

    /// Corners of the print in `image` pixels, or `nil` when the fit fails (the caller falls back to the coarse box).
    ///
    /// Port of ffscan `photo_quad` (`ff680w.py:141-242`; upstream commit a041a3f). Each edge is fitted as its own
    /// line, so a print that is tilted, not cut quite square, or turned slightly while feeding still gets every edge
    /// exactly. Each edge is traced along short lines walked from the backing inward: skip the backing (as in
    /// ``PhotoBox/find(in:threshold:)``), then the print's shadow (a colourless grey a little darker than the
    /// backing); the edge is the first run of 3 picture pixels. A grey run longer than any shadow is picture (a grey
    /// wall at the photo's edge), so the edge is where it starts. The line is a Theil-Sen fit (median slope over
    /// pairs half the edge apart, median intercept), so a stretch of sky the colour of the backing does not bend it.
    /// Where the scan cut the print off, the edge is extrapolated from the part that was scanned.
    ///
    /// - Parameters:
    ///   - image: the full-resolution scan. The fit runs on a copy of at most `size` pixels.
    ///   - thumbnail: the 600 px thumbnail the coarse box comes from (see ``AutoCrop``).
    ///   - background: the backing colour from ``PhotoBox/background(of:)``.
    public static func fit(image: RGBImage, thumbnail: RGBImage, background: RGB,
                           threshold: Int = 40, size: Int = 3000) -> PhotoQuad? {
        let working = image.thumbnail(maxPixelSize: size)
        let scale = Double(working.width) / Double(thumbnail.width)
        let box = PhotoBox.find(in: thumbnail, threshold: threshold)
        let coarse = (x0: Double(box.x0) * scale, y0: Double(box.y0) * scale,
                      x1: Double(box.x1) * scale, y1: Double(box.y1) * scale)
        guard let corners = fit(working: working, coarse: coarse, background: background, threshold: threshold) else { return nil }
        let k = Double(image.width) / Double(working.width)
        return PhotoQuad(ul: CGPoint(x: corners[0].x * k, y: corners[0].y * k),
                         ll: CGPoint(x: corners[1].x * k, y: corners[1].y * k),
                         lr: CGPoint(x: corners[2].x * k, y: corners[2].y * k),
                         ur: CGPoint(x: corners[3].x * k, y: corners[3].y * k))
    }

    private enum Kind: UInt8 { case backing, shadow, picture }

    /// The fit on the working copy, with the coarse box in working pixels. Corners come back in working pixels.
    static func fit(working: RGBImage, coarse: (x0: Double, y0: Double, x1: Double, y1: Double),
                    background bg: RGB, threshold: Int = 40) -> [(x: Double, y: Double)]? {
        let w = working.width, h = working.height
        let luma = Double(Int(bg.r) + Int(bg.g) + Int(bg.b)) / 3
        let maxShadow = Int(0.012 * Double(max(w, h)))
        let tint = bg.chroma
        let (bx0, by0, bx1, by1) = coarse
        let pad = 0.03 * Double(max(w, h))
        let insideTol = 0.015 * Double(max(w, h))  // a shadow is ~1%: an edge further inside is picture

        func kind(_ r: Int, _ g: Int, _ b: Int) -> Kind {
            let lo = min(r, g, b), hi = max(r, g, b)
            let dist = abs(r - Int(bg.r)) + abs(g - Int(bg.g)) + abs(b - Int(bg.b))
            if lo >= 250 || (dist <= threshold && hi - lo <= tint + 12) { return .backing }  // deskew fill, or backing
            let mean = Double(r + g + b) / 3
            if hi - lo < 14 && 0.65 * luma < mean && mean < luma + 10 { return .shadow }
            return .picture
        }

        /// Index of the print's edge along `line` (pixels from outside inward), or nil.
        func edgeAt(_ cls: [Kind]) -> Int? {
            var i = 0
            while i < cls.count, cls[i] == .backing { i += 1 }
            var j = i
            while j < cls.count, cls[j] == .shadow { j += 1 }
            if j - i > maxShadow { return i }
            var k = i
            while k + 2 < cls.count {
                if cls[k] == .picture, cls[k + 1] == .picture, cls[k + 2] == .picture { return k }
                k += 1
            }
            return nil
        }

        typealias EdgeFit = (slope: Double?, c0: Double, pts: [(t: Double, c: Double)])

        /// Line c = a*t + b along the edge (vertical: x along y, else y along x).
        func edge(vertical: Bool, far: Bool) -> EdgeFit {
            let lo = vertical ? by0 : bx0, hi = vertical ? by1 : bx1
            let c0 = vertical ? (far ? bx1 : bx0) : (far ? by1 : by0)
            let limit = Double(vertical ? w : h)
            let outer = far ? Int(min(limit, c0 + pad)) : Int(max(0, c0 - pad))
            let inner = far ? Int(max(0, c0 - pad)) : Int(min(limit, c0 + pad))
            let a = min(outer, inner), b = max(outer, inner)
            let span = hi - lo
            let first = Int(lo + 0.15 * span), last = Int(hi - 0.15 * span)
            let stepCount = last > first ? (last - first + 2) / 3 : 0
            var pts: [(t: Double, c: Double)] = []
            guard b > a else { return (nil, c0, pts) }
            var cls = [Kind](repeating: .backing, count: b - a)
            working.pixels.withUnsafeBufferPointer { px in
                for n in 0 ..< stepCount {
                    let t = first + 3 * n
                    for idx in 0 ..< b - a {
                        // strip is 3 pixels wide across the edge's direction; BOX-resized to one pixel
                        var sr = 0, sg = 0, sb = 0
                        for d in 0 ..< 3 {
                            let x = vertical ? a + idx : min(max(t + d, 0), w - 1)
                            let y = vertical ? min(max(t + d, 0), h - 1) : a + idx
                            let o = (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 3
                            sr += Int(px[o]); sg += Int(px[o + 1]); sb += Int(px[o + 2])
                        }
                        let slot = far ? (b - a - 1 - idx) : idx  // far edges walk inward from the outer end
                        cls[slot] = kind((sr + 1) / 3, (sg + 1) / 3, (sb + 1) / 3)
                    }
                    guard let i = edgeAt(cls), i > 2 else { continue }  // i <= 2: the print runs past the scan's edge
                    let c = far ? Double(outer - i) : Double(outer + i)
                    // far inside the coarse box: picture that looks like backing (pale sky, snow), which the coarse
                    // box (whole columns/rows) already counted as photo
                    if (far ? c0 - c : c - c0) <= insideTol { pts.append((Double(t), c)) }
                }
            }
            if pts.count < 10 { return (nil, c0, pts) }  // cut off along its whole length: the coarse box edge
            let half = pts.count / 2
            let slopes = (0 ..< half).map { (pts[$0 + half].c - pts[$0].c) / (pts[$0 + half].t - pts[$0].t) }.sorted()
            // an edge mostly cut off by the scan has only a few points near a corner: too few for its own slope
            return (Double(pts.count) >= 0.4 * Double(stepCount) ? slopes[slopes.count / 2] : nil, c0, pts)
        }

        let edges = [edge(vertical: true, far: false), edge(vertical: true, far: true),
                     edge(vertical: false, far: false), edge(vertical: false, far: true)]  // left right top bottom
        // prints are near-rectangles: a rotation turns vertical edges by `tilt` (x per y) and horizontal ones by
        // -tilt. An edge without its own slope, or one far from the others (> 0.02, ~1 deg), takes the shared tilt
        // instead; smaller differences are kept.
        var own: [Double] = []
        for (i, e) in edges.enumerated() { if let a = e.slope { own.append(i < 2 ? a : -a) } }
        own.sort()
        guard !own.isEmpty else { return nil }
        let tilt = own[own.count / 2]
        var fitted: [(a: Double, b: Double)] = []
        for (i, e) in edges.enumerated() {
            let expected = i < 2 ? tilt : -tilt
            var a = e.slope ?? expected
            if abs(a - expected) > 0.02 { a = expected }
            let icepts = e.pts.map { $0.c - a * $0.t }.sorted()
            fitted.append((a, icepts.isEmpty ? e.c0 : icepts[icepts.count / 2]))
        }
        let (left, right, top, bottom) = (fitted[0], fitted[1], fitted[2], fitted[3])

        func corner(_ v: (a: Double, b: Double), _ hz: (a: Double, b: Double)) -> (x: Double, y: Double) {  // x = a*y + b meets y = c*x + d
            let x = (v.a * hz.b + v.b) / (1 - v.a * hz.a)
            return (x, hz.a * x + hz.b)
        }
        let corners = [corner(left, top), corner(left, bottom), corner(right, bottom), corner(right, top)]
        let coarseCorners = [(bx0, by0), (bx0, by1), (bx1, by1), (bx1, by0)]
        for (c, cc) in zip(corners, coarseCorners) where !(abs(c.x - cc.0) <= pad && abs(c.y - cc.1) <= pad) {
            return nil  // a fit went wrong: fall back to the coarse box
        }
        return corners
    }
}
