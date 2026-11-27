import Foundation
import ImageIO

extension RGBImage {
    /// An enhanced copy of a JPEG (`enhance`, `enhance.py:101-107`; `app.py:208-212`): decode in stored
    /// orientation, run the chosen steps, and re-encode at quality 95 with all of the original's metadata (EXIF,
    /// XMP, GPS, Orientation, DPI). Like upstream, the DPI defaults to 300 when the original has none.
    ///
    /// `eyes` are in the stored image's pixels and are used only when `options.redEye` is on.
    public static func enhancedCopy(of original: Data, eyes: [EyePosition] = [], options: EnhancementOptions = .init())
        throws -> (data: Data, steps: [String]) {
        let (image, steps) = try RGBImage.decode(original).enhanced(eyes: eyes, options: options)
        let encoded = try image.jpegData(quality: 0.95, copyingMetadataFrom: original)
        return (try ensuringDPI(encoded, original: original), steps)
    }

    /// Adds 300 DPI to `encoded` (a lossless metadata rewrite) when `original` has no DPI.
    static func ensuringDPI(_ encoded: Data, original: Data) throws -> Data {
        guard let originalSource = CGImageSourceCreateWithData(original as CFData, nil),
              let originalProps = CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [CFString: Any]
        else { throw CodingError.unreadableImage }
        if originalProps[kCGImagePropertyDPIWidth] != nil { return encoded }
        guard let source = CGImageSourceCreateWithData(encoded as CFData, nil),
              let type = CGImageSourceGetType(source) else { throw CodingError.unreadableImage }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else { throw CodingError.encodingFailed }
        let metadata = CGImageMetadataCreateMutable()
        for (path, value) in [("tiff:XResolution", "300/1"), ("tiff:YResolution", "300/1"), ("tiff:ResolutionUnit", "2")] {
            CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString)
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else {
            throw CodingError.encodingFailed
        }
        return out as Data
    }
}
