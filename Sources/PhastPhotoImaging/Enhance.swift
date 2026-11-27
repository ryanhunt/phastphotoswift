import Foundation

// Photo enhancement for scanned prints, ported from ffscan's enhance.py (upstream commit a041a3f).
// Everything works by hand on 8-bit gamma-encoded values and copies Pillow's arithmetic (ImageOps.autocontrast,
// ImageEnhance, Image.blend, ImageFilter.SMOOTH, L and HSV conversion) so results match the Python tool.

/// An eye in pixels of the image it is applied to: centre and radius of the eye contour
/// (`find_eyes` in `enhance.py:14-21`; the Vision-based finder lives in `PhastPhotoVision`).
public struct EyePosition: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var radius: Double

    public init(x: Double, y: Double, radius: Double) {
        self.x = x
        self.y = y
        self.radius = radius
    }
}

/// The manual sliders (`MANUAL`, `adjust`, `enhance.py:56-76`). Each is -50...50; 0 leaves the photo unchanged.
public struct ManualAdjustments: Hashable, Sendable {
    public var brightness: Int
    public var contrast: Int
    public var saturation: Int
    public var warmth: Int
    public var sharpness: Int

    public init(brightness: Int = 0, contrast: Int = 0, saturation: Int = 0, warmth: Int = 0, sharpness: Int = 0) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.sharpness = sharpness
    }

    public var isNeutral: Bool { self == ManualAdjustments() }

    /// Names of the sliders that are not 0, in upstream's `MANUAL` order.
    var activeNames: [String] {
        [("brightness", brightness), ("contrast", contrast), ("saturation", saturation),
         ("warmth", warmth), ("sharpness", sharpness)].filter { $0.1 != 0 }.map(\.0)
    }
}

/// Which steps ``RGBImage/enhanced(eyes:options:)`` runs (`enhance_image`, `enhance.py:79-98`).
public struct EnhancementOptions: Hashable, Sendable {
    public var redEye: Bool
    public var restore: Bool
    public var auto: Bool
    public var manual: ManualAdjustments

    public init(redEye: Bool = true, restore: Bool = true, auto: Bool = true, manual: ManualAdjustments = .init()) {
        self.redEye = redEye
        self.restore = restore
        self.auto = auto
        self.manual = manual
    }
}

// MARK: - Steps

extension RGBImage {
    /// Neutralise strongly red pixels within each eye: red becomes the mean of green and blue.
    ///
    /// Ports `remove_red_eye` (`enhance.py:24-37`): radius is `max(3, r * 1.1)`, a pixel qualifies when
    /// `red > 60 && red > 1.7 * (g + b) / 2`, and the new red is `int((g + b) / 2)` (truncated).
    public func removingRedEye(_ eyes: [EyePosition]) -> RGBImage {
        var out = self
        let w = width, h = height
        out.pixels.withUnsafeMutableBufferPointer { p in
            for eye in eyes {
                // Python cannot overflow here; Swift traps on Int(NaN or huge), so skip bad eyes and bound the values.
                guard eye.x.isFinite, eye.y.isFinite, eye.radius.isFinite else { continue }
                let r = min(1e9, max(3, eye.radius * 1.1))
                func bound(_ v: Double) -> Int { Int(max(-1e9, min(1e9, v))) }
                let y0 = max(0, bound(eye.y - r)), y1 = min(h, bound(eye.y + r) + 1)
                let x0 = max(0, bound(eye.x - r)), x1 = min(w, bound(eye.x + r) + 1)
                guard y0 < y1, x0 < x1 else { continue }
                for y in y0 ..< y1 {
                    for x in x0 ..< x1 {
                        let dx = Double(x) - eye.x, dy = Double(y) - eye.y
                        if dx * dx + dy * dy > r * r { continue }
                        let o = (y * w + x) * 3
                        let red = Int(p[o]), green = Int(p[o + 1]), blue = Int(p[o + 2])
                        let gb = Double(green + blue) / 2
                        if red > 60, Double(red) > 1.7 * gb { p[o] = UInt8(gb) }
                    }
                }
            }
        }
        return out
    }

    /// Stretch each channel to the full range, dropping 0.5% of pixels at each end of its histogram
    /// (`restore_faded`, `enhance.py:40-43`, which is Pillow `ImageOps.autocontrast(c, cutoff=0.5)` per channel).
    public func restoredFaded() -> RGBImage {
        var out = self
        let count = width * height
        var luts = [[UInt8]]()
        for c in 0 ..< 3 {
            var hist = [Int](repeating: 0, count: 256)
            pixels.withUnsafeBufferPointer { p in
                for i in 0 ..< count { hist[Int(p[i * 3 + c])] += 1 }
            }
            luts.append(Self.autocontrastTable(histogram: hist, cutoffPercent: 0.5))
        }
        out.pixels.withUnsafeMutableBufferPointer { p in
            for i in 0 ..< count {
                for c in 0 ..< 3 { p[i * 3 + c] = luts[c][Int(p[i * 3 + c])] }
            }
        }
        return out
    }

    /// Brightness, contrast and saturation, each measured and nudged toward a target (`auto_enhance`,
    /// `enhance.py:46-55`): tone-preserving autocontrast (cutoff 0.5%), gamma toward `targetBrightness` clamped to
    /// 0.7...1.4 (only when the mean is in 0.02...0.98), saturation factor `clamp(target / max(S, 0.05), 1, 1.3)`,
    /// then sharpness 1.15.
    public func autoEnhanced(targetBrightness: Double = 0.47, targetSaturation: Double = 0.38) -> RGBImage {
        var im = self
        // ImageOps.autocontrast(im, cutoff=0.5, preserve_tone=True): table from the L histogram, same for all channels.
        var lHist = [Int](repeating: 0, count: 256)
        let count = width * height
        pixels.withUnsafeBufferPointer { p in
            for i in 0 ..< count { lHist[Int(Self.luma(p[i * 3], p[i * 3 + 1], p[i * 3 + 2]))] += 1 }
        }
        im.applyTable(Self.autocontrastTable(histogram: lHist, cutoffPercent: 0.5))

        let mean = im.lumaMean() / 255
        if mean > 0.02, mean < 0.98 {
            let gamma = max(0.7, min(1.4, log(targetBrightness) / log(mean)))
            // Python round() is half to even.
            let table = (0 ..< 256).map { UInt8((255 * pow(Double($0) / 255, gamma)).rounded(.toNearestOrEven)) }
            im.applyTable(table)
        }
        let saturation = im.meanSaturation()
        let factor = max(1, min(1.3, targetSaturation / max(saturation, 0.05)))
        return im.colorEnhanced(factor).sharpnessEnhanced(1.15)
    }

    /// Manual adjustments applied after the automatic fixes in a fixed order: brightness, contrast, saturation,
    /// warmth, sharpness (`adjust`, `enhance.py:58-76`). Sliders are -50...50 and 0 skips the step.
    public func adjusted(_ m: ManualAdjustments) -> RGBImage {
        var im = self
        if m.brightness != 0 { im = im.brightnessEnhanced(1 + Double(m.brightness) / 100) }
        if m.contrast != 0 { im = im.contrastEnhanced(1 + Double(m.contrast) / 100) }
        if m.saturation != 0 { im = im.colorEnhanced(1 + Double(m.saturation) / 100) }
        if m.warmth != 0 {  // warmer = more red, less blue, up to about 15% at the ends
            let k = Double(m.warmth) / 330
            let count = width * height
            im.pixels.withUnsafeMutableBufferPointer { p in
                for i in 0 ..< count {
                    // Sliders beyond -50...50 (upstream does not clamp) would make a negative factor; clip instead of trapping.
                    p[i * 3] = UInt8(max(0, min(255, (Double(p[i * 3]) * (1 + k)).rounded(.toNearestOrEven))))
                    p[i * 3 + 2] = UInt8(max(0, min(255, (Double(p[i * 3 + 2]) * (1 - k)).rounded(.toNearestOrEven))))
                }
            }
        }
        if m.sharpness != 0 { im = im.sharpnessEnhanced(1 + Double(m.sharpness) / 50) }
        return im
    }

    /// The whole enhancement (`enhance_image`, `enhance.py:79-98`), shared by saved copies and a live preview:
    /// red-eye (when `eyes` is not empty), restore, auto, then the manual sliders. Returns the new image and the
    /// steps taken, worded as upstream words them.
    public func enhanced(eyes: [EyePosition] = [], options: EnhancementOptions = .init())
        -> (image: RGBImage, steps: [String]) {
        var im = self
        var done = [String]()
        if options.redEye, !eyes.isEmpty {
            im = im.removingRedEye(eyes)
            done.append("red-eye (\(eyes.count) eyes checked)")
        }
        if options.restore {
            im = im.restoredFaded()
            done.append("restored colours")
        }
        if options.auto {
            im = im.autoEnhanced()
            done.append("auto enhance")
        }
        if !options.manual.isNeutral {
            im = im.adjusted(options.manual)
            done.append("adjusted " + options.manual.activeNames.joined(separator: ", "))
        }
        return (im, done)
    }
}

// MARK: - Pillow semantics

extension RGBImage {
    /// Pillow's RGB to L: `(19595 R + 38470 G + 7471 B + 0x8000) >> 16`.
    @inline(__always)
    static func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
        UInt8((Int(r) * 19595 + Int(g) * 38470 + Int(b) * 7471 + 0x8000) >> 16)
    }

    /// Lookup table of Pillow's `ImageOps.autocontrast` for one 256-bin histogram: `cutoffPercent` of the
    /// pixels are dropped from each end, then the remaining range is stretched to 0...255 (values truncated).
    static func autocontrastTable(histogram: [Int], cutoffPercent: Double) -> [UInt8] {
        var h = histogram
        let n = h.reduce(0, +)
        // Pillow: int(n * cutoff // 100). n * 0.5 is exact in floating point.
        let cut0 = Int((Double(n) * cutoffPercent).rounded(.down) / 100)
        var cut = cut0
        for lo in 0 ..< 256 {
            if cut > h[lo] { cut -= h[lo]; h[lo] = 0 } else { h[lo] -= cut; cut = 0 }
            if cut <= 0 { break }
        }
        cut = cut0
        for hi in stride(from: 255, through: 0, by: -1) {
            if cut > h[hi] { cut -= h[hi]; h[hi] = 0 } else { h[hi] -= cut; cut = 0 }
            if cut <= 0 { break }
        }
        var lo = 0
        while lo < 256, h[lo] == 0 { lo += 1 }
        var hi = 255
        while hi >= 0, h[hi] == 0 { hi -= 1 }
        // All pixels cut away (lo == 256, hi == -1) or a single value left: identity, as Pillow.
        if hi <= lo { return (0 ... 255).map { UInt8($0) } }
        let scale = 255.0 / Double(hi - lo)
        let offset = -Double(lo) * scale
        return (0 ..< 256).map { UInt8(max(0, min(255, Int(Double($0) * scale + offset)))) }
    }

    /// Apply the same 256-entry table to every channel.
    mutating func applyTable(_ table: [UInt8]) {
        pixels.withUnsafeMutableBufferPointer { p in
            for i in 0 ..< p.count { p[i] = table[Int(p[i])] }
        }
    }

    /// Mean of the L image (`ImageStat.Stat(im.convert("L")).mean[0]`), 0...255.
    func lumaMean() -> Double {
        let count = width * height
        var sum = 0
        pixels.withUnsafeBufferPointer { p in
            for i in 0 ..< count { sum += Int(Self.luma(p[i * 3], p[i * 3 + 1], p[i * 3 + 2])) }
        }
        return Double(sum) / Double(count)
    }

    /// Mean of the S channel of Pillow's HSV conversion, 0...1. Pillow: `S = int(255 * (max - min) / max)`.
    func meanSaturation() -> Double {
        let count = width * height
        var sum = 0
        pixels.withUnsafeBufferPointer { p in
            for i in 0 ..< count {
                let mx = max(p[i * 3], p[i * 3 + 1], p[i * 3 + 2]), mn = min(p[i * 3], p[i * 3 + 1], p[i * 3 + 2])
                if mx != mn { sum += Int(255 * (Float(mx - mn) / Float(mx))) }
            }
        }
        return Double(sum) / Double(count) / 255
    }

    /// Pillow `Image.blend(degenerate, self, alpha)`: `degenerate + alpha * (self - degenerate)` in float,
    /// truncated and clipped to 0...255. Pillow's C code is compiled with fused multiply-add on arm64, which
    /// changes truncation of exact results (0.8 * 60 gives 47.99999), so this fuses too; x86 builds of Pillow may differ by 1.
    private func blended(from degenerate: [UInt8], factor: Double) -> RGBImage {
        var out = self
        let alpha = Float(factor)
        pixels.withUnsafeBufferPointer { src in
            degenerate.withUnsafeBufferPointer { base in
                out.pixels.withUnsafeMutableBufferPointer { dst in
                    for i in 0 ..< src.count {
                        let a = Float(base[i])
                        let v = a.addingProduct(alpha, Float(src[i]) - a)  // fused, like Pillow on arm64
                        dst[i] = v <= 0 ? 0 : v >= 255 ? 255 : UInt8(v)
                    }
                }
            }
        }
        return out
    }

    /// `ImageEnhance.Brightness`: blend with black.
    func brightnessEnhanced(_ factor: Double) -> RGBImage {
        blended(from: [UInt8](repeating: 0, count: pixels.count), factor: factor)
    }

    /// `ImageEnhance.Contrast`: blend with a flat grey of `int(mean L + 0.5)`.
    func contrastEnhanced(_ factor: Double) -> RGBImage {
        let grey = UInt8(Int(lumaMean() + 0.5))
        return blended(from: [UInt8](repeating: grey, count: pixels.count), factor: factor)
    }

    /// `ImageEnhance.Color`: blend with the L image.
    func colorEnhanced(_ factor: Double) -> RGBImage {
        var grey = pixels
        grey.withUnsafeMutableBufferPointer { p in
            for i in 0 ..< width * height {
                let l = Self.luma(p[i * 3], p[i * 3 + 1], p[i * 3 + 2])
                p[i * 3] = l; p[i * 3 + 1] = l; p[i * 3 + 2] = l
            }
        }
        return blended(from: grey, factor: factor)
    }

    /// `ImageEnhance.Sharpness`: blend with Pillow's SMOOTH filter (3x3, weights 1 1 1 / 1 5 1 / 1 1 1 over 13;
    /// the one-pixel border is copied unchanged), so factors above 1 sharpen edges.
    func sharpnessEnhanced(_ factor: Double) -> RGBImage {
        blended(from: smoothed(), factor: factor)
    }

    func smoothed() -> [UInt8] {
        var out = pixels
        let w = width, h = height
        guard w >= 3, h >= 3 else { return out }
        pixels.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                for y in 1 ..< h - 1 {
                    for x in 1 ..< w - 1 {
                        for c in 0 ..< 3 {
                            let o = (y * w + x) * 3 + c, up = o - w * 3, down = o + w * 3
                            let sum = Int(s[up - 3]) + Int(s[up]) + Int(s[up + 3])
                                + Int(s[o - 3]) + 5 * Int(s[o]) + Int(s[o + 3])
                                + Int(s[down - 3]) + Int(s[down]) + Int(s[down + 3])
                            d[o] = UInt8(max(0, min(255, Int(Float(sum) / 13 + 0.5))))
                        }
                    }
                }
            }
        }
        return out
    }
}
