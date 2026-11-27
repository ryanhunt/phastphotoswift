import Foundation
@testable import PhastPhotoImaging

/// Synthetic scans for the crop tests, built in code. Geometry is ffscan's test geometry (tests/test_ffscan.py)
/// scaled down by two to keep Debug builds quick.
enum CropTestScans {
    static let grey = RGB(176, 172, 165)

    /// Vertical stripes `(150 + 2i mod 80, 60, 40)` every 20 px from `from` to `to`; `base` elsewhere.
    static func stripes(_ x: Int, from: Int, to: Int, base: RGB) -> RGB {
        guard x >= from, x < to else { return base }
        let i = (x / 20) * 20
        return RGB(UInt8(150 + (2 * i) % 80), 60, 40)
    }

    /// A 618x400 print (600 px of stripes, 18 px grey shadow on the right) rotated by `degrees` about its centre and
    /// pasted at (125, 70) of a 900x550 grey scan: ffscan's tilted print with a shadow. Edges are anti-aliased with
    /// 3x3 coverage.
    static func tiltedPrintWithShadow(degrees: Double = 1.0) -> RGBImage {
        let pw = 618, ph = 400
        let theta = degrees * .pi / 180, c = cos(theta), s = sin(theta)
        let ox = 125.0, oy = 70.0
        // bounding box of the rotated print is larger than the print: centre of the print in the scan
        let cx = ox + Double(pw) / 2 + 3, cy = oy + Double(ph) / 2 + 3
        let shadow = RGB(120, 118, 114)
        return RGBImage(width: 900, height: 550) { x, y in
            var r = 0, g = 0, b = 0, covered = 0
            for sy in 0 ..< 3 {
                for sx in 0 ..< 3 {
                    let dx = Double(x) + (Double(sx) + 0.5) / 3 - cx, dy = Double(y) + (Double(sy) + 0.5) / 3 - cy
                    // inverse rotation into print coordinates
                    let u = c * dx + s * dy + Double(pw) / 2, v = -s * dx + c * dy + Double(ph) / 2
                    let p: RGB
                    if u >= 0, u < Double(pw), v >= 0, v < Double(ph) {
                        p = stripes(Int(u), from: 0, to: 600, base: shadow)
                        covered += 1
                    } else {
                        p = grey
                    }
                    r += Int(p.r); g += Int(p.g); b += Int(p.b)
                }
            }
            _ = covered
            return RGB(UInt8((r + 4) / 9), UInt8((g + 4) / 9), UInt8((b + 4) / 9))
        }
    }

    /// Scan position of the print point (u, v) in ``tiltedPrintWithShadow(degrees:)``.
    static func tiltedPoint(u: Double, v: Double, degrees: Double = 1.0) -> (x: Double, y: Double) {
        let theta = degrees * .pi / 180, c = cos(theta), s = sin(theta)
        let cx = 125.0 + 618.0 / 2 + 3, cy = 70.0 + 400.0 / 2 + 3
        let a = u - 618.0 / 2, b = v - 400.0 / 2
        return (cx + c * a - s * b, cy + s * a + c * b)
    }

    /// Cool-grey backing (not symmetric in R and B: catches a blue-green-red mix-up) and a 150 px band of pale sky at
    /// the left edge of a 600x400 print, about as bright as the backing but clearly blue.
    static func coolBackingPaleSky() -> RGBImage {
        let cool = RGB(164, 172, 177), sky = RGB(150, 178, 190)
        return RGBImage(width: 900, height: 550) { x, y in
            guard x >= 150, x < 750, y >= 75, y < 475 else { return cool }
            return stripes(x - 150, from: 150, to: 600, base: sky)
        }
    }

    /// 100x80 thumbnail: photo at x 20..<80, y 5..<50; dark full-width band at y 60..<75; white fill in a corner.
    static func boxScan(_ x: Int, _ y: Int) -> RGB {
        if x >= 20, x < 80, y >= 5, y < 50 { return RGB(240, 240, 240) }
        if y >= 60, y < 75 { return RGB(90, 80, 60) }
        if x > 90, y < 10 { return RGB(255, 255, 255) }
        return grey
    }
}
