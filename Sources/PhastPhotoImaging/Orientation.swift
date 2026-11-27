import Foundation
import ImageIO

/// Lossless rotation through the EXIF Orientation tag (browsers, Photos and Google Photos honour it).
///
/// Ports `ORIENTATION_TAG`, `set_rotation` and `get_rotation` (`app.py:109-120`). Rotations are degrees
/// clockwise: 0/90/180/270 map to Orientation 1/6/3/8. The JPEG data is not re-encoded.
public enum PhotoOrientation {
    /// `ORIENTATION_TAG`: degrees clockwise to EXIF Orientation.
    public static let tagForRotation: [Int: Int] = [0: 1, 90: 6, 180: 3, 270: 8]
    /// `TAG_ORIENTATION`: the inverse.
    public static let rotationForTag: [Int: Int] = Dictionary(uniqueKeysWithValues: tagForRotation.map { ($1, $0) })

    /// Reduces any multiple of 90 to 0, 90, 180 or 270 (upstream's `degrees % 360`, with Python's sign rule).
    public static func normalized(_ degrees: Int) throws -> Int {
        guard degrees % 90 == 0 else { throw PhotoMetadataError.unsupportedRotation(degrees) }
        return ((degrees % 360) + 360) % 360
    }

    /// The current rotation in degrees clockwise (`get_rotation`). Missing, mirrored (2, 4, 5, 7) and unknown
    /// Orientation values read as 0, as upstream.
    public static func rotation(of data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let tag = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue else { return 0 }
        return rotationForTag[tag] ?? 0
    }

    /// `data` with its Orientation tag set to `degrees` clockwise from upright (`set_rotation`). Absolute,
    /// not relative: 0 clears an earlier rotation.
    public static func setRotation(_ degrees: Int, in data: Data) throws -> Data {
        let tag = tagForRotation[try normalized(degrees)]!
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw PhotoMetadataError.unreadableImage
        }
        let patch = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(patch, nil, "tiff:Orientation" as CFString, String(tag) as CFString)
        return try PhotoMetadata.rewrite(source, merging: patch)
    }

    /// Adds a manual rotation (clockwise degrees, may be negative) to the photo's current one, for a person
    /// turning a picture the automatic orientation got wrong. Returns the data and the new total.
    public static func rotate(by degrees: Int, in data: Data) throws -> (data: Data, rotation: Int) {
        let total = try normalized(rotation(of: data) + normalized(degrees))
        return (try setRotation(total, in: data), total)
    }

    /// Sets the rotation of a file in place (atomically).
    public static func setRotation(_ degrees: Int, inFileAt url: URL) throws {
        try setRotation(degrees, in: Data(contentsOf: url)).write(to: url, options: .atomic)
    }

    public static func rotation(ofFileAt url: URL) throws -> Int {
        rotation(of: try Data(contentsOf: url))
    }
}
