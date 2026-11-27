import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PhastPhotoImaging

@Suite struct JPEGWritingTests {
    /// A JPEG with a description, an Orientation tag, 300 DPI and an XMP title, like a scan after metadata.
    static func original() throws -> Data {
        let image = RGBImage(width: 40, height: 30, fill: RGB(120, 90, 60))
        let xmp = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(xmp, nil, "dc:title" as CFString, "Beach 1974" as CFString)
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        let options: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300, kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "Written on back: Mum"],
        ]
        CGImageDestinationAddImageAndMetadata(destination, image.cgImage(), xmp, options as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    @Test func derivedJPEGKeepsMetadata() throws {
        let cropped = RGBImage(width: 20, height: 10, fill: RGB(200, 10, 10))
        let data = try cropped.jpegData(quality: 0.95, copyingMetadataFrom: try Self.original())

        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 20)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 10)
        #expect(props[kCGImagePropertyOrientation] as? Int == 6)
        #expect(props[kCGImagePropertyDPIWidth] as? Int == 300)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFImageDescription] as? String == "Written on back: Mum")
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let title = metadata.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "dc:title" as CFString) }
        #expect(title as String? == "Beach 1974")
        let decoded = try RGBImage.decode(data)
        #expect(decoded[10, 5].r > 180)
    }
}
