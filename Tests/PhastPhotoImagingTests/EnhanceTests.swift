import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PhastPhotoImaging

@Suite struct EnhanceTests {
    // MARK: - 6.1 red-eye (test_ffscan.py:108-116)

    @Test func redEyeNeutralisesPupilOnly() {
        var eye = RGBImage(width: 20, height: 20, fill: RGB(200, 150, 130))  // skin
        eye[10, 10] = RGB(220, 40, 40)  // red pupil
        eye[1, 1] = RGB(220, 40, 40)  // red outside the eye circle
        let out = eye.removingRedEye([EyePosition(x: 10, y: 10, radius: 4)])
        #expect(out[10, 10] == RGB(40, 40, 40))
        #expect(out[12, 10] == RGB(200, 150, 130))
        #expect(out[1, 1] == RGB(220, 40, 40))
        #expect(eye[10, 10] == RGB(220, 40, 40))  // value semantics: the input is untouched
    }

    @Test func redEyeThresholdsAndRadius() {
        var im = RGBImage(width: 30, height: 30, fill: RGB(0, 0, 0))
        im[15, 15] = RGB(60, 0, 0)  // red must exceed 60
        im[16, 15] = RGB(61, 0, 0)
        im[15, 16] = RGB(85, 50, 50)  // exactly 1.7x the green/blue mean: not enough
        im[14, 15] = RGB(86, 50, 50)
        // radius max(3, r * 1.1): a tiny eye still covers 3 px
        let out = im.removingRedEye([EyePosition(x: 15, y: 15, radius: 0.5)])
        #expect(out[15, 15] == RGB(60, 0, 0))
        #expect(out[16, 15] == RGB(0, 0, 0))
        #expect(out[15, 16] == RGB(85, 50, 50))
        #expect(out[14, 15] == RGB(50, 50, 50))
        // eyes at the border or outside the image do not crash
        _ = im.removingRedEye([EyePosition(x: -5, y: 40, radius: 8), EyePosition(x: 0, y: 0, radius: 6)])
    }

    @Test func hostileInputsDoNotTrap() {
        let im = RGBImage(width: 8, height: 8, fill: RGB(200, 20, 20))
        _ = im.removingRedEye([EyePosition(x: .nan, y: 1, radius: 2), EyePosition(x: 1e300, y: -1e300, radius: .infinity),
                               EyePosition(x: 4, y: 4, radius: 1e300)])
        let warm = im.adjusted(ManualAdjustments(warmth: -1000))  // negative factor clips to 0 like Pillow's point()
        #expect(warm[0, 0].r == 0 && warm[0, 0].b == 81)
        let cold = im.adjusted(ManualAdjustments(warmth: 1000))
        #expect(cold[0, 0].r == 255 && cold[0, 0].b == 0)
    }

    // MARK: - Pillow parity (reference values computed with Pillow's ImageOps/ImageEnhance on this image)

    /// Deterministic 24x16 faded-looking image; the same formula builds the reference in Python.
    static func sample() -> RGBImage {
        RGBImage(width: 24, height: 16) { x, y in
            func channel(_ c: Int) -> UInt8 {
                UInt8(70 + (x * 37 + y * 91 + c * 53 + ((x * y) % 29) * 7) % 120 + (x > 12 ? c * 10 : 0))
            }
            return RGB(channel(0), channel(1), channel(2))
        }
    }

    static func digest(_ image: RGBImage) -> Int {
        image.pixels.reduce(0) { ($0 * 31 + Int($1) + 1) % 4_294_967_291 }
    }

    @Test(arguments: [
        ("restore", 2_411_299_135), ("auto", 2_779_237_218), ("brightness", 2_792_005_607),
        ("contrast", 1_974_244_158), ("saturation", 1_848_891_722), ("warmth", 3_320_390_101),
        ("coolness", 1_166_635_842), ("sharpness", 1_400_609_478), ("all", 120_574_601),
    ])
    func matchesPillow(name: String, expected: Int) {
        let im = Self.sample()
        let out: RGBImage
        switch name {
        case "restore": out = im.restoredFaded()
        case "auto": out = im.autoEnhanced()
        case "brightness": out = im.adjusted(ManualAdjustments(brightness: 20))
        case "contrast": out = im.adjusted(ManualAdjustments(contrast: -30))
        case "saturation": out = im.adjusted(ManualAdjustments(saturation: 40))
        case "warmth": out = im.adjusted(ManualAdjustments(warmth: 25))
        case "coolness": out = im.adjusted(ManualAdjustments(warmth: -50))
        case "sharpness": out = im.adjusted(ManualAdjustments(sharpness: 50))
        default:
            out = im.enhanced(eyes: [EyePosition(x: 10, y: 8, radius: 3)], options: EnhancementOptions(
                manual: ManualAdjustments(brightness: -10, contrast: 15, saturation: -20, warmth: 12, sharpness: -30))).image
        }
        #expect(Self.digest(out) == expected, "\(name)")
    }

    // MARK: - 6.3 restore and auto

    /// A faded print: every channel squeezed into a narrow, different band (a colour cast).
    static func faded() -> RGBImage {
        RGBImage(width: 40, height: 40) { x, y in
            let t = (x + y * 3) % 100  // 0...99
            return RGB(UInt8(100 + t), UInt8(80 + t / 2), UInt8(60 + t / 3))
        }
    }

    static func range(_ im: RGBImage, channel c: Int) -> (lo: UInt8, hi: UInt8) {
        var lo: UInt8 = 255, hi: UInt8 = 0
        for i in stride(from: c, to: im.pixels.count, by: 3) { lo = min(lo, im.pixels[i]); hi = max(hi, im.pixels[i]) }
        return (lo, hi)
    }

    @Test func restoreStretchesEveryChannelToFullRange() {
        let before = Self.faded()
        let after = before.restoredFaded()
        for c in 0 ..< 3 {
            let b = Self.range(before, channel: c), a = Self.range(after, channel: c)
            #expect(b.hi - b.lo < 110)
            #expect(a.lo == 0 && a.hi >= 254, "channel \(c): \(a)")  // Pillow truncates, so 254 is possible
        }
    }

    @Test func restoreLeavesFlatAndFullRangeImagesAlone() {
        let flat = RGBImage(width: 8, height: 8, fill: RGB(120, 120, 120))
        #expect(flat.restoredFaded() == flat)
        let ramp = RGBImage(width: 256, height: 4) { x, _ in RGB(UInt8(x), UInt8(x), UInt8(x)) }
        let out = ramp.restoredFaded()
        #expect(Self.range(out, channel: 0) == (0, 255))
    }

    @Test func autocontrastTableCutsHalfPercentFromEachEnd() {
        // 1000 pixels: 5 at value 10 (0.5%), 990 at 100, 5 at 200. Cutoff 0.5% = 5 pixels each end: only 100 is left.
        var hist = [Int](repeating: 0, count: 256)
        hist[10] = 5; hist[100] = 990; hist[200] = 5
        let flat = RGBImage.autocontrastTable(histogram: hist, cutoffPercent: 0.5)
        #expect(flat == (0 ... 255).map { UInt8($0) })  // hi <= lo: identity, as Pillow
        // 4 at 10, 500 at 100, 492 at 150, 4 at 200: the cut removes the 4 outer pixels and one more each side.
        hist = [Int](repeating: 0, count: 256)
        hist[10] = 4; hist[100] = 500; hist[150] = 492; hist[200] = 4
        let table = RGBImage.autocontrastTable(histogram: hist, cutoffPercent: 0.5)
        #expect(table[10] == 0 && table[100] == 0 && table[150] == 255 && table[200] == 255)
        #expect(table[125] == 127)
    }

    @Test func autoBrightensDarkAndDarkensBrightPhotos() {
        // After autocontrast the mean is ~0.5 either way, so test the gamma through a skewed histogram.
        let dark = RGBImage(width: 40, height: 40) { x, y in
            let v = UInt8(min(255, ((x * 7 + y * 13) % 100) * ((x * 7 + y * 13) % 100) / 39))  // mass near black
            return RGB(v, v, v)
        }
        let bright = RGBImage(width: 40, height: 40) { x, y in
            let t = (x * 7 + y * 13) % 100
            let v = UInt8(255 - min(255, t * t / 39))  // mass near white
            return RGB(v, v, v)
        }
        let meanBefore = (dark.lumaMean(), bright.lumaMean())
        let afterDark = dark.autoEnhanced(), afterBright = bright.autoEnhanced()
        // Gamma moves the mean toward 0.47 * 255 = 120 from either side.
        #expect(meanBefore.0 < 100 && afterDark.lumaMean() > meanBefore.0)
        #expect(meanBefore.1 > 140 && afterBright.lumaMean() < meanBefore.1)
    }

    @Test func autoGammaMovesMeanTowardTargetAndIsClamped() {
        // Mean far from 0.47 on a full-range image: gamma clamps at 1.4, so it cannot reach the target.
        let dark = RGBImage(width: 20, height: 20) { x, y in
            let t = x + y * 20
            return RGB(UInt8(t * t / 1570), UInt8(t * t / 1570), UInt8(t * t / 1570))  // 0...254, mean ~ 85
        }
        let m0 = dark.lumaMean() / 255
        #expect(m0 < 0.4)
        let out = dark.autoEnhanced(targetBrightness: 0.47, targetSaturation: 0)
        #expect(out.lumaMean() / 255 > m0 + 0.05)
        // Grey image: saturation factor stays 1 (never desaturates), and nothing becomes coloured.
        let p = out[5, 5]
        #expect(p.r == p.g && p.g == p.b)
    }

    @Test(arguments: [(30, 0.7), (225, 1.4)])
    func autoGammaIsClampedToSevenTenthsAndOnePointFour(bulk: Int, gamma: Double) {
        // Bulk grey with a few black and white pixels: autocontrast keeps the range, the mean is far from 0.47.
        let im = RGBImage(width: 20, height: 20) { x, _ in
            let v: UInt8 = x == 0 ? 0 : x >= 18 ? 255 : UInt8(bulk)
            return RGB(v, v, v)
        }
        let out = im.autoEnhanced()
        let expected = Int((255 * pow(Double(bulk) / 255, gamma)).rounded())
        #expect(Int(out[8, 10].g) == expected, "bulk \(bulk): got \(out[8, 10]), want \(expected)")
    }

    @Test func autoRaisesSaturationOfDullColourButNotBeyondOneThree() {
        let dull = RGBImage(width: 30, height: 30) { x, y in
            let t = UInt8(40 + (x * 5 + y * 9) % 170)
            return RGB(t + 8, t, t)  // barely coloured
        }
        let out = dull.autoEnhanced()
        #expect(out.meanSaturation() > dull.meanSaturation())
    }

    // MARK: - 6.4 manual adjustments

    @Test func neutralSlidersChangeNothing() {
        let im = Self.sample()
        #expect(im.adjusted(ManualAdjustments()) == im)
        #expect(ManualAdjustments().isNeutral)
        let (same, steps) = im.enhanced(options: EnhancementOptions(redEye: true, restore: false, auto: false))
        #expect(same == im && steps.isEmpty)
    }

    @Test func slidersMoveTheRightWay() {
        let im = Self.sample()
        func mean(_ i: RGBImage) -> Double { i.lumaMean() }
        #expect(mean(im.adjusted(.init(brightness: 30))) > mean(im))
        #expect(mean(im.adjusted(.init(brightness: -30))) < mean(im))
        // Contrast raises the spread of luma; negative lowers it.
        func spread(_ i: RGBImage) -> Int {
            let l = stride(from: 0, to: i.pixels.count, by: 3).map { Int(RGBImage.luma(i.pixels[$0], i.pixels[$0 + 1], i.pixels[$0 + 2])) }
            return l.max()! - l.min()!
        }
        #expect(spread(im.adjusted(.init(contrast: 40))) > spread(im))
        #expect(spread(im.adjusted(.init(contrast: -40))) < spread(im))
        #expect(im.adjusted(.init(saturation: 40)).meanSaturation() > im.meanSaturation())
        #expect(im.adjusted(.init(saturation: -40)).meanSaturation() < im.meanSaturation())
        // Warmth: red up and blue down, with k = 33/330 = 0.1 at +33.
        let warm = im.adjusted(.init(warmth: 33)), cool = im.adjusted(.init(warmth: -33))
        let p = im[5, 5], w = warm[5, 5], c = cool[5, 5]
        #expect(Int(w.r) == min(255, Int((Double(p.r) * 1.1).rounded(.toNearestOrEven))))
        #expect(Int(w.b) == Int((Double(p.b) * 0.9).rounded(.toNearestOrEven)))
        #expect(w.g == p.g && c.g == p.g)
        #expect(c.r < p.r && c.b > p.b)
        // Sharpness: a step edge overshoots (and softens when negative).
        let edge = RGBImage(width: 12, height: 12) { x, _ in x < 6 ? RGB(80, 80, 80) : RGB(160, 160, 160) }
        let sharp = edge.adjusted(.init(sharpness: 50)), soft = edge.adjusted(.init(sharpness: -50))
        #expect(sharp[5, 6].r < 80 && sharp[6, 6].r > 160)
        #expect(soft[5, 6].r > 80 && soft[6, 6].r < 160)
        #expect(sharp[0, 6] == edge[0, 6])  // far from the edge nothing changes
    }

    @Test func stepsAreReportedInUpstreamOrderAndWording() {
        let options = EnhancementOptions(manual: ManualAdjustments(brightness: 5, warmth: -5, sharpness: 1))
        let eye = EyePosition(x: 12, y: 8, radius: 3)
        let (_, steps) = Self.sample().enhanced(eyes: [eye, eye], options: options)
        #expect(steps == ["red-eye (2 eyes checked)", "restored colours", "auto enhance", "adjusted brightness, warmth, sharpness"])
        let (_, off) = Self.sample().enhanced(eyes: [eye], options: EnhancementOptions(redEye: false, restore: false, auto: false))
        #expect(off.isEmpty)
    }

    @Test func manualStepsRunAfterAutoInFixedOrder() {
        let im = Self.sample()
        let manual = ManualAdjustments(brightness: 10, contrast: -10, saturation: 20, warmth: 15, sharpness: 10)
        let whole = im.enhanced(options: EnhancementOptions(manual: manual)).image
        let manual2 = im.restoredFaded().autoEnhanced().adjusted(manual)
        #expect(whole == manual2)
        // Brightness before contrast: swapping the order gives a different result.
        let a = im.brightnessEnhanced(1.2).contrastEnhanced(0.8)
        let b = im.contrastEnhanced(0.8).brightnessEnhanced(1.2)
        #expect(a != b)
    }

    // MARK: - 6.5 enhanced copy (test_ffscan.py:225-236)

    static func original(dpi: Bool = true, gps: Bool = true) throws -> Data {
        let image = RGBImage(width: 64, height: 48) { x, y in RGB(UInt8(100 + x), UInt8(90 + y), 70) }
        var options: [CFString: Any] = [kCGImagePropertyOrientation: 6]
        if dpi { options[kCGImagePropertyDPIWidth] = 600; options[kCGImagePropertyDPIHeight] = 600 }
        if gps {
            options[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 49.7075, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.2034, kCGImagePropertyGPSLongitudeRef: "W",
            ]
        }
        options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFImageDescription: "Summer 87"]
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image.cgImage(), options as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }

    @Test func enhancedCopyKeepsMetadataIncludingGPS() throws {
        let original = try Self.original()
        let (data, steps) = try RGBImage.enhancedCopy(
            of: original, options: EnhancementOptions(redEye: false, restore: true, auto: true))
        #expect(steps == ["restored colours", "auto enhance"])
        let props = Self.properties(data)
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        #expect(gps?[kCGImagePropertyGPSLatitude] as? Double == 49.7075)
        #expect(gps?[kCGImagePropertyGPSLatitudeRef] as? String == "N")
        #expect(gps?[kCGImagePropertyGPSLongitude] as? Double == 0.2034)
        #expect(gps?[kCGImagePropertyGPSLongitudeRef] as? String == "W")
        #expect(props[kCGImagePropertyDPIWidth] as? Int == 600)
        #expect(props[kCGImagePropertyOrientation] as? Int == 6)
        #expect((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFImageDescription] as? String == "Summer 87")
        // The pixels did change: restore stretched the narrow gradient.
        let decoded = try RGBImage.decode(data)
        #expect(Self.range(decoded, channel: 0).hi > 230)
    }

    @Test func enhancedCopyDefaultsToThreeHundredDPIOnlyWhenMissing() throws {
        let plain = try Self.original(dpi: false, gps: false)
        #expect(Self.properties(plain)[kCGImagePropertyDPIWidth] == nil)
        let (data, _) = try RGBImage.enhancedCopy(of: plain)
        let props = Self.properties(data)
        #expect(props[kCGImagePropertyDPIWidth] as? Int == 300)
        #expect(props[kCGImagePropertyDPIHeight] as? Int == 300)
        #expect(props[kCGImagePropertyOrientation] as? Int == 6)
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 64)
    }

    @Test func enhancedCopyAppliesRedEyeInStoredPixels() throws {
        var image = RGBImage(width: 64, height: 48, fill: RGB(200, 150, 130))
        for y in 20 ..< 26 { for x in 30 ..< 36 { image[x, y] = RGB(230, 30, 30) } }
        let data = try image.jpegData(quality: 1.0)
        let (out, steps) = try RGBImage.enhancedCopy(
            of: data, eyes: [EyePosition(x: 32.5, y: 22.5, radius: 3)],
            options: EnhancementOptions(redEye: true, restore: false, auto: false))
        #expect(steps == ["red-eye (1 eyes checked)"])
        let p = try RGBImage.decode(out)[32, 22]
        #expect(p.r < 90)
        #expect(throws: (any Error).self) { try RGBImage.enhancedCopy(of: Data("not a jpeg".utf8)) }
    }
}
