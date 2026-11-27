import Foundation

/// Pillow-compatible antialiased resampling of one 8-bit plane.
///
/// Port of the algorithm in Pillow's `Resample.c` (`precompute_coeffs`, `ImagingResampleHorizontal/Vertical_8bpc`):
/// the filter support is widened by the downscale factor, weights are normalised per output pixel, the horizontal
/// pass runs first and its result is rounded to 8 bits before the vertical pass. Weights are kept in `Double`
/// rather than Pillow's 22-bit fixed point, which can differ by one grey level at most.
/// Used instead of Core Graphics so the 9x8 hash thumbnail matches ffscan's `Image.LANCZOS` resize
/// (the duplicate threshold sits in a 2-bit gap).
enum PillowResample {
    enum Filter {
        case bicubic  // Pillow's default for `Image.thumbnail` and `Image.resize`; a = -0.5
        case lanczos  // `Image.LANCZOS`, 3 lobes

        var support: Double { self == .bicubic ? 2 : 3 }

        func weight(_ x: Double) -> Double {
            switch self {
            case .bicubic:
                let a = -0.5, x = abs(x)
                if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
                if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
                return 0
            case .lanczos:
                if x > -3, x < 3 { return Self.sinc(x) * Self.sinc(x / 3) }
                return 0
            }
        }

        private static func sinc(_ x: Double) -> Double {
            if x == 0 { return 1 }
            let p = x * Double.pi
            return sin(p) / p
        }
    }

    /// For each output index: first input index and its normalised weights (Pillow `precompute_coeffs`).
    static func coefficients(inSize: Int, outSize: Int, filter: Filter) -> [(start: Int, weights: [Double])] {
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1)
        let support = filter.support * filterScale
        let inverse = 1 / filterScale
        return (0 ..< outSize).map { out in
            let center = (Double(out) + 0.5) * scale
            let lo = max(0, Int(center - support + 0.5))
            let hi = min(inSize, Int(center + support + 0.5))
            var weights = (0 ..< max(hi - lo, 0)).map { filter.weight((Double($0 + lo) - center + 0.5) * inverse) }
            let total = weights.reduce(0, +)
            if total != 0 { weights = weights.map { $0 / total } }
            return (lo, weights)
        }
    }

    @inline(__always)
    private static func clip8(_ v: Double) -> UInt8 {
        UInt8(max(0, min(255, (v + 0.5).rounded(.down))))
    }

    static func resize(_ plane: [UInt8], width: Int, height: Int, to newWidth: Int, _ newHeight: Int,
                       filter: Filter) -> [UInt8] {
        var current = plane, w = width
        let h = height
        if newWidth != w {
            let coeffs = coefficients(inSize: w, outSize: newWidth, filter: filter)
            var out = [UInt8](repeating: 0, count: newWidth * h)
            current.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0 ..< h {
                        for x in 0 ..< newWidth {
                            let c = coeffs[x]
                            var sum = 0.0
                            for (i, k) in c.weights.enumerated() { sum += k * Double(src[y * w + c.start + i]) }
                            dst[y * newWidth + x] = clip8(sum)
                        }
                    }
                }
            }
            current = out; w = newWidth
        }
        if newHeight != h {
            let coeffs = coefficients(inSize: h, outSize: newHeight, filter: filter)
            var out = [UInt8](repeating: 0, count: w * newHeight)
            current.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0 ..< newHeight {
                        let c = coeffs[y]
                        for x in 0 ..< w {
                            var sum = 0.0
                            for (i, k) in c.weights.enumerated() { sum += k * Double(src[(c.start + i) * w + x]) }
                            dst[y * w + x] = clip8(sum)
                        }
                    }
                }
            }
            current = out
        }
        return current
    }
}
