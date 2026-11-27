import CoreGraphics
import Foundation
import Testing
@testable import PhastPhotoImaging

@Suite struct PhotoQuadTests {
    private func fit(_ image: RGBImage) -> PhotoQuad? {
        let thumb = image.thumbnail(maxPixelSize: 600)
        return PhotoQuad.fit(image: image, thumbnail: thumb, background: PhotoBox.background(of: thumb))
    }

    /// The fitted corners of a 1 degree tilted print (with a shadow on one side) sit on the true corners. The shadow (18 px) is longer than the 1.2% limit (10 px at this size), so, as upstream with its 35 px, the edge is the shadow's outer one and trimming removes the shadow.
    @Test func tiltedPrintCornersAreExact() throws {
        let quad = try #require(fit(CropTestScans.tiltedPrintWithShadow()))
        let truth = [(0.0, 0.0), (0.0, 400.0), (618.0, 400.0), (618.0, 0.0)].map { CropTestScans.tiltedPoint(u: $0.0, v: $0.1) }
        for (got, want) in zip(quad.corners, truth) {
            #expect(abs(got.x - want.x) < 2 && abs(got.y - want.y) < 2, "corner \(got) vs \(want)")
        }
    }

    /// A print cut off along its whole top edge takes the coarse box's edge there; the other edges stay exact.
    @Test func cutOffEdgeFallsBackToCoarseEdge() throws {
        let image = RGBImage(width: 600, height: 400) { x, y in
            x >= 100 && x < 500 && y < 300 ? RGB(UInt8(150 + (x / 20) % 3 * 30), 60, 40) : CropTestScans.grey
        }
        let quad = try #require(fit(image))
        #expect(abs(quad.ul.x - 100) < 2 && abs(quad.ur.x - 500) < 2)
        #expect(abs(quad.ll.y - 300) < 2 && abs(quad.lr.y - 300) < 2)
        #expect(abs(quad.ul.y) < 2 && abs(quad.ur.y) < 2)
    }

    @Test func plainBackingHasNoQuad() {
        #expect(fit(RGBImage(width: 200, height: 150, fill: CropTestScans.grey)) == nil)
    }
}

@Suite struct AutoCropTests {
    // test_ffscan.py:74-93: skewed print with a shadow along one edge: straightened, no backing grey left
    @Test func tiltedPrintWithShadowIsStraightened() throws {
        let result = AutoCrop.crop(CropTestScans.tiltedPrintWithShadow())
        let (w, h) = (result.width, result.height)
        #expect(570 < w && w <= 600 && 380 < h && h <= 400, "\(w)x\(h)")
        guard case .quad = result.source else { Issue.record("expected a fitted quad"); return }
        for (x, y) in [(3, 3), (w - 4, 3), (3, h - 4), (w - 4, h - 4), (w - 4, h / 2)] {
            let p = result.image[x, y]
            #expect(Int(p.r) - Int(p.b) > 40, "(\(x), \(y)) is \(p): photo red, not neutral backing or shadow")
        }
    }

    // test_ffscan.py:95-106: cool-grey backing and pale sky at the photo's edge: the sky is photo, the crop keeps it
    @Test func coolBackingKeepsPaleSky() {
        let result = AutoCrop.crop(CropTestScans.coolBackingPaleSky())
        #expect(585 < result.width && result.width <= 600 && 385 < result.height && result.height <= 400,
                "\(result.width)x\(result.height)")
        // the sky band is at the left of the crop, still blue (R < B), not cropped away
        let p = result.image[10, result.height / 2]
        #expect(p.b > p.r + 20, "\(p)")
    }

    /// Nothing traceable: the coarse box (here the whole scan) is used.
    @Test func fallsBackToCoarseBox() {
        let image = RGBImage(width: 200, height: 120) { x, y in RGB(UInt8(100 + x % 7), UInt8(80 + y % 5), 60) }
        let result = AutoCrop.crop(image)
        guard case .box = result.source else { Issue.record("expected the coarse box"); return }
        #expect(result.width > 190 && result.height > 110)
    }

    @Test func cropJPEGReencodesOnce() throws {
        let jpeg = try CropTestScans.tiltedPrintWithShadow().jpegData(quality: 0.95)
        let out = try AutoCrop.cropJPEG(jpeg)
        let decoded = try RGBImage.decode(out.jpeg)
        #expect(decoded.width == out.width && decoded.height == out.height)
        // JPEG ringing at the stripe edge can leave a few shadow pixels the 4 px trim step cannot take
        #expect(570 < out.width && out.width <= 606 && 380 < out.height && out.height <= 400, "\(out.width)x\(out.height)")
    }

    // MARK: pieces

    /// An identity quad reproduces the image, and the mask marks what lies past the scan's edge.
    @Test func quadWarpIdentityAndMask() {
        let image = RGBImage(width: 20, height: 10) { x, y in RGB(UInt8(x * 10), UInt8(y * 20), 77) }
        let same = CropSampling.quadWarp(image, corners: [(0, 0), (0, 10), (20, 10), (20, 0)], width: 20, height: 10)
        #expect(same.image == image)
        #expect(same.valid.allSatisfy { $0 == 255 })
        // shifted left by 5 px: the first 5 columns come from outside the scan
        let shifted = CropSampling.quadWarp(image, corners: [(-5, 0), (-5, 10), (15, 10), (15, 0)], width: 20, height: 10)
        #expect(shifted.valid[0] == 0 && shifted.valid[4] == 0 && shifted.valid[5] == 255 && shifted.valid[19] == 255)
        #expect(shifted.image[10, 3] == image[5, 3])
    }

    @Test func trimBackingRemovesBackingAndThinShadowButKeepsPicture() {
        let bg = CropTestScans.grey
        // 12 px backing (3% of the width), then picture (noisy red)
        let image = RGBImage(width: 400, height: 80) { x, y in
            x < 12 ? bg : RGB(UInt8(120 + (x * 7 + y * 13) % 100), 60, 40)
        }
        let box = AutoCrop.trimBacking(image, box: PhotoBox(x0: 0, y0: 0, x1: 400, y1: 80), background: bg)
        #expect(box.x0 == 12 && box.x1 == 400 && box.y0 == 0 && box.y1 == 80, "\(box)")
    }

    @Test func insideShrinksPastInvalidSideFirst() {
        // 30x20 mask, the top 3 rows invalid
        let valid = (0 ..< 600).map { $0 / 30 < 3 ? UInt8(0) : UInt8(255) }
        let box = AutoCrop.inside(valid: valid, stride: 30, height: 20, box: PhotoBox(x0: 0, y0: 0, x1: 30, y1: 20))
        #expect(box == PhotoBox(x0: 0, y0: 4, x1: 30, y1: 20))
    }
}
