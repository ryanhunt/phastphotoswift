import Foundation

/// Shared pixel helpers for the crop pipeline.
enum CropSampling {
    /// `sorted(values)[count // 2]` from a 256-bin histogram.
    static func median(hist: [Int], count: Int) -> Int {
        let target = count / 2
        var seen = 0
        for (v, n) in hist.enumerated() {
            seen += n
            if seen > target { return v }
        }
        return 255
    }

    /// Per-channel mean and population standard deviation of the pixels in `x0 ..< x1`, `y0 ..< y1` (clamped), like
    /// Pillow's `ImageStat.Stat` on a crop.
    static func stats(_ image: RGBImage, x0: Int, y0: Int, x1: Int, y1: Int) -> (mean: [Double], std: [Double]) {
        let x0 = max(0, x0), y0 = max(0, y0), x1 = min(image.width, x1), y1 = min(image.height, y1)
        guard x1 > x0, y1 > y0 else { return ([0, 0, 0], [0, 0, 0]) }
        var s = [Double](repeating: 0, count: 3), q = [Double](repeating: 0, count: 3)
        let w = image.width
        image.pixels.withUnsafeBufferPointer { p in
            var s0 = 0, s1 = 0, s2 = 0, q0 = 0, q1 = 0, q2 = 0
            for y in y0 ..< y1 {
                var o = (y * w + x0) * 3
                for _ in x0 ..< x1 {
                    let a = Int(p[o]), b = Int(p[o + 1]), c = Int(p[o + 2])
                    s0 += a; s1 += b; s2 += c
                    q0 += a * a; q1 += b * b; q2 += c * c
                    o += 3
                }
            }
            s = [Double(s0), Double(s1), Double(s2)]
            q = [Double(q0), Double(q1), Double(q2)]
        }
        let n = Double((x1 - x0) * (y1 - y0))
        let mean = s.map { $0 / n }
        let std = (0 ..< 3).map { c in max(0, q[c] / n - mean[c] * mean[c]).squareRoot() }
        return (mean, std)
    }

    /// Lets row bands write disjoint parts of one buffer from several threads.
    private struct Shared<T>: @unchecked Sendable {
        let base: UnsafeMutablePointer<T>
    }

    private struct SharedSource: @unchecked Sendable {
        let base: UnsafePointer<UInt8>
    }

    /// Pillow's `Image.transform((w, h), Image.QUAD, data, Image.BICUBIC)` plus the mask Pillow gives for the same
    /// transform on an all-255 "L" image with the default filter: 255 where the sampling position lies inside the
    /// source, 0 past the scan's edge (computed from the mapped coordinates).
    ///
    /// `corners` are the source positions of the output's upper-left, lower-left, lower-right and upper-right
    /// corners in pixel-edge coordinates. Each output pixel centre maps through a bilinear corner mapping; samples
    /// use the 4x4 bicubic kernel (a = -0.5) with clamped neighbours, as Pillow does.
    static func quadWarp(_ src: RGBImage, corners: [(x: Double, y: Double)], width w: Int, height h: Int)
        -> (image: RGBImage, valid: [UInt8])
    {
        let (nw, sw, se, ne) = (corners[0], corners[1], corners[2], corners[3])
        let sx = 1.0 / Double(w), sy = 1.0 / Double(h)
        let ax = SIMD4<Double>(nw.x, (ne.x - nw.x) * sx, (sw.x - nw.x) * sy, (se.x - sw.x - ne.x + nw.x) * sx * sy)
        let ay = SIMD4<Double>(nw.y, (ne.y - nw.y) * sx, (sw.y - nw.y) * sy, (se.y - sw.y - ne.y + nw.y) * sx * sy)
        var out = [UInt8](repeating: 0, count: w * h * 3)
        var valid = [UInt8](repeating: 0, count: w * h)
        let srcW = src.width, srcH = src.height
        let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 2))
        src.pixels.withUnsafeBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { op in
                valid.withUnsafeMutableBufferPointer { vp in
                    let s = SharedSource(base: sp.baseAddress!)
                    let o = Shared(base: op.baseAddress!), v = Shared(base: vp.baseAddress!)
                    DispatchQueue.concurrentPerform(iterations: bands) { band in
                        let ys = band * h / bands, ye = (band + 1) * h / bands
                        for y in ys ..< ye {
                            let yy = Double(y) + 0.5
                            for x in 0 ..< w {
                                let xx = Double(x) + 0.5
                                let xin = ax[0] + ax[1] * xx + ax[2] * yy + ax[3] * xx * yy
                                let yin = ay[0] + ay[1] * xx + ay[2] * yy + ay[3] * xx * yy
                                guard xin >= 0, xin < Double(srcW), yin >= 0, yin < Double(srcH) else { continue }
                                v.base[y * w + x] = 255
                                let fx = xin - 0.5, fy = yin - 0.5
                                let ix = Int(fx.rounded(.down)), iy = Int(fy.rounded(.down))
                                let wx = cubicWeights(fx - Double(ix)), wy = cubicWeights(fy - Double(iy))
                                var acc = SIMD3<Double>(repeating: 0)
                                for j in 0 ..< 4 {
                                    let py = min(max(iy - 1 + j, 0), srcH - 1)
                                    var row = SIMD3<Double>(repeating: 0)
                                    for i in 0 ..< 4 {
                                        let px = min(max(ix - 1 + i, 0), srcW - 1)
                                        let p = (py * srcW + px) * 3
                                        row += wx[i] * SIMD3<Double>(Double(s.base[p]), Double(s.base[p + 1]), Double(s.base[p + 2]))
                                    }
                                    acc += wy[j] * row
                                }
                                let d = (y * w + x) * 3
                                o.base[d] = clamp8(acc[0]); o.base[d + 1] = clamp8(acc[1]); o.base[d + 2] = clamp8(acc[2])
                            }
                        }
                    }
                }
            }
        }
        return (RGBImage(width: w, height: h, pixels: out, iccProfile: src.iccProfile), valid)
    }

    @inline(__always) private static func clamp8(_ v: Double) -> UInt8 {
        v <= 0 ? 0 : (v >= 255 ? 255 : UInt8(v + 0.5))
    }

    /// Pillow's bicubic kernel (a = -0.5) at distances 1+d, d, 1-d, 2-d.
    @inline(__always) private static func cubicWeights(_ d: Double) -> SIMD4<Double> {
        let a = -0.5
        @inline(__always) func k(_ x: Double) -> Double {
            x < 1 ? ((a + 2) * x - (a + 3)) * x * x + 1 : (x < 2 ? (((x - 5) * x + 8) * x - 4) * a : 0)
        }
        return SIMD4(k(1 + d), k(d), k(1 - d), k(2 - d))
    }
}
