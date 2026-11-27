import Foundation
import ImageIO
import Testing
@testable import PhastPhotoImaging

/// The bytes from the first start-of-scan marker on: the compressed image data. Header segments (EXIF, XMP,
/// ICC, ...) come before it, so these bytes only match if nothing was re-encoded.
func scanData(of jpeg: Data) -> Data? {
    let bytes = [UInt8](jpeg)
    var i = 2
    while i + 4 <= bytes.count {
        guard bytes[i] == 0xFF else { return nil }
        let marker = bytes[i + 1]
        if marker == 0xDA { return Data(bytes[i...]) }
        i += 2 + Int(bytes[i + 2]) << 8 + Int(bytes[i + 3])
    }
    return nil
}

/// A small gradient JPEG (so the scan data is not trivially uniform).
func syntheticJPEG(width: Int = 48, height: Int = 32, properties: [CFString: Any] = [:]) throws -> Data {
    let image = RGBImage(width: width, height: height) { x, y in
        RGB(UInt8(x * 255 / width), UInt8(y * 255 / height), UInt8((x + y) * 3 % 256))
    }
    return try image.jpegData(quality: 0.9, properties: properties)
}

@Suite struct OrientationTests {
    @Test func tagTableMatchesUpstream() {
        #expect(PhotoOrientation.tagForRotation == [0: 1, 90: 6, 180: 3, 270: 8])
        #expect(PhotoOrientation.rotationForTag == [1: 0, 6: 90, 3: 180, 8: 270])
    }

    @Test func roundTripAndLossless() throws {
        let original = try syntheticJPEG()
        #expect(PhotoOrientation.rotation(of: original) == 0)
        for degrees in [90, 180, 270, 0, -90, 450] {
            let rotated = try PhotoOrientation.setRotation(degrees, in: original)
            #expect(PhotoOrientation.rotation(of: rotated) == ((degrees % 360) + 360) % 360)
            #expect(scanData(of: original) != nil)
            #expect(scanData(of: rotated) == scanData(of: original))
        }
        // The tag itself: 90 clockwise is Orientation 6.
        let rotated = try PhotoOrientation.setRotation(90, in: original)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(rotated as CFData, nil)!, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyOrientation] as? Int == 6)
        // Pixels are stored unrotated: size is unchanged.
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 48)
    }

    @Test func setReplacesEarlierRotation() throws {
        let start = try syntheticJPEG(properties: [kCGImagePropertyOrientation: 6])
        #expect(PhotoOrientation.rotation(of: start) == 90)
        #expect(PhotoOrientation.rotation(of: try PhotoOrientation.setRotation(180, in: start)) == 180)
        #expect(PhotoOrientation.rotation(of: try PhotoOrientation.setRotation(0, in: start)) == 0)
    }

    @Test func manualRotationAddsToCurrent() throws {
        let start = try syntheticJPEG(properties: [kCGImagePropertyOrientation: 6])  // 90
        let (turned, total) = try PhotoOrientation.rotate(by: 270, in: start)
        #expect(total == 0)
        #expect(PhotoOrientation.rotation(of: turned) == 0)
        let (back, total2) = try PhotoOrientation.rotate(by: -90, in: start)
        #expect(total2 == 0 && PhotoOrientation.rotation(of: back) == 0)
        let (again, total3) = try PhotoOrientation.rotate(by: 180, in: start)
        #expect(total3 == 270 && PhotoOrientation.rotation(of: again) == 270)
        #expect(scanData(of: again) == scanData(of: start))
    }

    @Test func mirroredAndMissingReadAsZero() throws {
        #expect(PhotoOrientation.rotation(of: try syntheticJPEG(properties: [kCGImagePropertyOrientation: 2])) == 0)
        #expect(PhotoOrientation.rotation(of: Data([1, 2, 3])) == 0)
    }

    @Test func rejectsOddAngles() throws {
        #expect(throws: PhotoMetadataError.unsupportedRotation(45)) {
            try PhotoOrientation.setRotation(45, in: try syntheticJPEG())
        }
        #expect(throws: PhotoMetadataError.unreadableImage) {
            try PhotoOrientation.setRotation(90, in: Data([1, 2, 3]))
        }
    }

    @Test func fileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orientation-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try syntheticJPEG().write(to: url)
        try PhotoOrientation.setRotation(270, inFileAt: url)
        #expect(try PhotoOrientation.rotation(ofFileAt: url) == 270)
    }
}
