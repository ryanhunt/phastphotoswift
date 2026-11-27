import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension RGBImage {
    /// JPEG data for these pixels carrying the original file's metadata: EXIF, IPTC, XMP, GPS, DPI and the
    /// Orientation tag (pixels stay in stored orientation, so the tag still applies). Pixel-dimension tags are
    /// dropped so they can't contradict the new size. The colour profile is this image's ``iccProfile``.
    ///
    /// Use it for every derived JPEG (a crop, an enhanced copy): ffscan re-encodes once at quality 95 and keeps
    /// EXIF, XMP, ICC and DPI (`ff680w.py:365`, `:384`; `app.py:208-212`).
    public func jpegData(quality: Double = 0.95, copyingMetadataFrom original: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw CodingError.unreadableImage }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

        var metadata: CGImageMetadata?
        if let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let mutable = CGImageMetadataCreateMutableCopy(original) {
            for path in ["exif:PixelXDimension", "exif:PixelYDimension", "tiff:ImageWidth", "tiff:ImageLength"] {
                CGImageMetadataRemoveTagWithPath(mutable, nil, path as CFString)
            }
            metadata = mutable
        }

        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight, kCGImagePropertyOrientation] {
            if let value = properties[key] { options[key] = value }
        }

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CodingError.encodingFailed
        }
        CGImageDestinationAddImageAndMetadata(destination, cgImage(), metadata, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CodingError.encodingFailed }
        return out as Data
    }
}
