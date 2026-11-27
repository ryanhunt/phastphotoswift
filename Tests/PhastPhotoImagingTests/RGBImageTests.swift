import CoreGraphics
import Foundation
import Testing
@testable import PhastPhotoImaging

@Suite struct RGBImageTests {
    @Test func keepsChannelOrder() throws {
        let image = RGBImage(width: 4, height: 3) { x, y in x == 0 && y == 0 ? RGB(200, 20, 10) : RGB(10, 20, 200) }
        #expect(image[0, 0] == RGB(200, 20, 10))
        #expect(image[3, 2] == RGB(10, 20, 200))
        let roundTrip = RGBImage(cgImage: image.cgImage())
        #expect(roundTrip == image)
    }

    @Test func jpegRoundTripAndThumbnail() throws {
        let image = RGBImage(width: 64, height: 32) { x, _ in x < 32 ? RGB(220, 40, 40) : RGB(40, 40, 220) }
        let jpeg = try image.jpegData(quality: 0.95)
        let decoded = try RGBImage.decode(jpeg)
        #expect(decoded.width == 64 && decoded.height == 32)
        #expect(decoded[8, 16].r > 180 && decoded[56, 16].b > 180)
        let small = try RGBImage.decode(jpeg, maxPixelSize: 16)
        #expect(small.width == 16 && small.height == 8)
        #expect(image.thumbnail(maxPixelSize: 16).width == 16)
    }

    @Test func crop() {
        let image = RGBImage(width: 10, height: 10) { x, y in RGB(UInt8(x), UInt8(y), 0) }
        let c = image.cropped(x0: 2, y0: 3, x1: 5, y1: 7)
        #expect(c.width == 3 && c.height == 4)
        #expect(c[0, 0] == RGB(2, 3, 0) && c[2, 3] == RGB(4, 6, 0))
    }
}

@Suite struct ColorProfileTests {
    /// A Display P3 JPEG keeps its values and its profile through decode and encode (no conversion to sRGB).
    @Test func taggedProfileSurvivesRoundTrip() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        var image = RGBImage(width: 16, height: 16, fill: RGB(150, 178, 190))
        image.iccProfile = p3.copyICCData() as Data?
        let decoded = try RGBImage.decode(try image.jpegData(quality: 1.0))
        #expect(decoded.iccProfile != nil)
        let p = decoded[8, 8]
        #expect(abs(Int(p.r) - 150) <= 2 && abs(Int(p.g) - 178) <= 2 && abs(Int(p.b) - 190) <= 2, "\(p)")
        let again = try RGBImage.decode(try decoded.jpegData(quality: 1.0))
        #expect(again.iccProfile != nil)
    }

    @Test func untaggedStaysUntagged() throws {
        let decoded = try RGBImage.decode(try RGBImage(width: 8, height: 8, fill: RGB(176, 172, 165)).jpegData(quality: 1.0))
        let p = decoded[4, 4]
        #expect(abs(Int(p.r) - 176) <= 2 && abs(Int(p.g) - 172) <= 2 && abs(Int(p.b) - 165) <= 2, "\(p)")
    }
}
