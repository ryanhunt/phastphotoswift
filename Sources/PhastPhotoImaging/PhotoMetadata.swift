import Foundation
import ImageIO

/// Failures of the metadata and orientation writers.
public enum PhotoMetadataError: Error, Equatable, Sendable {
    /// The data is not an image ImageIO can read.
    case unreadableImage
    /// ImageIO refused to rewrite the file.
    case writeFailed
    /// The date is not `YYYY`, `YYYY-MM` or `YYYY-MM-DD` (with `/` also accepted as separator).
    case invalidDate(String)
    /// The rotation is not a multiple of 90 degrees.
    case unsupportedRotation(Int)
}

/// Latitude and longitude in signed decimal degrees (south and west negative), and altitude in metres above
/// sea level when the photo has one.
public struct GPSLocation: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

/// User-facing photo metadata, written into the JPEG as XMP, EXIF and (through ImageIO's sync) IPTC.
///
/// Ports ffscan's `METADATA_TAGS`, `write_metadata`, `read_metadata` and `gps_of` (`app.py:215-258`). ffscan
/// shells out to exiftool; this writes through ImageIO with `CGImageDestinationCopyImageSource`, which rewrites
/// the metadata segments and copies the compressed scan data untouched (no re-encode).
///
/// Field to tag map (upstream `METADATA_TAGS`):
///
/// | field | XMP | EXIF/TIFF | IPTC |
/// |---|---|---|---|
/// | title | `dc:title` | | ObjectName |
/// | description | `dc:description` | `ImageDescription` | Caption-Abstract |
/// | album | `xmpDM:album` | | |
/// | place | `Iptc4xmpCore:Location` | | Sub-location |
/// | headline | `photoshop:Headline` | | Headline |
/// | people | `Iptc4xmpExt:PersonInImage` | | |
/// | tags | `dc:subject` | | Keywords |
/// | date | `photoshop:DateCreated` | `DateTimeOriginal` | |
///
/// IPTC: ImageIO does not write a legacy IPTC (Photoshop 8BIM) record. It stores XMP and reports the IPTC
/// properties by mapping them back from XMP when reading, so tools that only read the IPTC record (rare, old
/// software) will not see these fields; XMP and EXIF readers will.
public struct PhotoMetadata: Equatable, Sendable {
    public var title: String
    public var description: String
    public var album: String
    public var place: String
    public var headline: String
    /// People in the picture, one per element.
    public var people: [String]
    /// Keywords, one per element.
    public var tags: [String]
    /// `YYYY`, `YYYY-MM` or `YYYY-MM-DD` when written; always `YYYY-MM-DD` when read from the EXIF date.
    public var date: String

    public init(
        title: String = "", description: String = "", album: String = "", place: String = "",
        headline: String = "", people: [String] = [], tags: [String] = [], date: String = ""
    ) {
        self.title = title
        self.description = description
        self.album = album
        self.place = place
        self.headline = headline
        self.people = people
        self.tags = tags
        self.date = date
    }

    /// Splits a comma separated list as ffscan's UI keeps it: trimmed, empty items dropped.
    public static func list(fromCommaSeparated text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The back-text rule of `app.py:470-474`: text written on the back of the print is appended to the
    /// description as `Written on back: ...` (a new line after any existing description), and a date taken from
    /// that text is used only when no date was given. Does nothing for empty back text.
    ///
    /// - Parameters:
    ///   - backText: the transcribed back of the print.
    ///   - dateFromBackText: a date found in it (`date_from_text` upstream), or empty.
    public func merging(backText: String, dateFromBackText: String = "") -> PhotoMetadata {
        guard !backText.isEmpty else { return self }
        var merged = self
        merged.description = [description, "Written on back: " + backText].filter { !$0.isEmpty }.joined(separator: "\n")
        if merged.date.isEmpty { merged.date = dateFromBackText }
        return merged
    }

    // MARK: Writing

    /// Returns `data` with `metadata` written into it, leaving every other tag alone. Empty fields are left
    /// untouched (`write_metadata`). The compressed image data is copied, not re-encoded.
    ///
    /// Lists are added to the ones already in the file: an existing item equal to a new one is dropped first
    /// and the new ones are appended (upstream's `-=` then `+=`), so there are no duplicates and the new
    /// order wins. The input list is de-duplicated too, keeping the first occurrence.
    public static func write(_ metadata: PhotoMetadata, to data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw PhotoMetadataError.unreadableImage
        }
        let existing = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let patch = CGImageMetadataCreateMutable()
        registerNamespaces(patch)

        func set(_ path: String, _ value: String) {
            if !value.isEmpty { CGImageMetadataSetValueWithPath(patch, nil, path as CFString, value as CFString) }
        }
        set("dc:title", metadata.title)
        set("dc:description", metadata.description)
        set("tiff:ImageDescription", metadata.description)
        // ImageIO drops tiff:ImageDescription unless the patch carries another TIFF tag, so restate the
        // Orientation the file already has (or 1).
        if !metadata.description.isEmpty { set("tiff:Orientation", String(currentOrientationTag(source))) }
        set("xmpDM:album", metadata.album)
        set("Iptc4xmpCore:Location", metadata.place)
        set("photoshop:Headline", metadata.headline)

        for (path, ns, prefix, name, items) in [
            ("Iptc4xmpExt:PersonInImage", Namespace.iptcExt, "Iptc4xmpExt", "PersonInImage", metadata.people),
            ("dc:subject", Namespace.dc, "dc", "subject", metadata.tags),
        ] {
            let added = unique(items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            guard !added.isEmpty else { continue }
            let kept = existing.map { stringList($0, path: path) }?.filter { !added.contains($0) } ?? []
            setList(patch, path: path, namespace: ns, prefix: prefix, name: name, items: kept + added)
        }

        if !metadata.date.isEmpty {
            let parts = metadata.date.replacingOccurrences(of: "/", with: "-").split(separator: "-", omittingEmptySubsequences: false)
            let numbers = parts.prefix(3).map { Int($0) }
            guard (1...3).contains(parts.count), parts.count <= 3, !numbers.contains(nil), let year = numbers[0] else {
                throw PhotoMetadataError.invalidDate(metadata.date)
            }
            let month = numbers.count > 1 ? numbers[1]! : 1
            let day = numbers.count > 2 ? numbers[2]! : 1
            let exif = String(format: "%04d:%02d:%02d 00:00:00", year, month, day)
            set("exif:DateTimeOriginal", exif)
            set("photoshop:DateCreated", parts.joined(separator: "-"))  // upstream writes the text as typed; "/" is normalised so ImageIO does not mangle the EXIF date
        }
        return try rewrite(source, merging: patch)
    }

    /// Writes metadata into the file in place (atomically).
    public static func write(_ metadata: PhotoMetadata, toFileAt url: URL) throws {
        try write(metadata, to: Data(contentsOf: url)).write(to: url, options: .atomic)
    }

    // MARK: Reading

    /// Reads the fields `read_metadata` reads. XMP is preferred; EXIF/TIFF/IPTC properties are the fallback for
    /// files written by other software. Missing fields are empty. The date is the EXIF `DateTimeOriginal`
    /// as `YYYY-MM-DD`.
    public static func read(from data: Data) throws -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw PhotoMetadataError.unreadableImage
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]

        var md = PhotoMetadata()
        var xmpPeople: [String] = [], xmpTags: [String] = []
        var xmp = { (_: String) -> String in "" }
        if let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let copy = CGImageMetadataCreateMutableCopy(original) {
            registerNamespaces(copy)
            xmp = { path in (CGImageMetadataCopyStringValueWithPath(copy, nil, path as CFString) as String?) ?? "" }
            xmpPeople = stringList(copy, path: "Iptc4xmpExt:PersonInImage")
            xmpTags = stringList(copy, path: "dc:subject")
        }
        func first(_ values: Any?...) -> String { values.compactMap { $0 as? String }.first { !$0.isEmpty } ?? "" }

        md.title = first(xmp("dc:title"), iptc[kCGImagePropertyIPTCObjectName])
        md.description = first(xmp("dc:description"), tiff[kCGImagePropertyTIFFImageDescription],
                               iptc[kCGImagePropertyIPTCCaptionAbstract])
        md.album = xmp("xmpDM:album")
        md.place = first(xmp("Iptc4xmpCore:Location"), iptc[kCGImagePropertyIPTCSubLocation])
        md.headline = first(xmp("photoshop:Headline"), iptc[kCGImagePropertyIPTCHeadline])
        md.people = xmpPeople
        md.tags = xmpTags.isEmpty ? (iptc[kCGImagePropertyIPTCKeywords] as? [String] ?? []) : xmpTags
        md.date = String(first(exif[kCGImagePropertyExifDateTimeOriginal]).prefix(10)).replacingOccurrences(of: ":", with: "-")
        return md
    }

    public static func read(fromFileAt url: URL) throws -> PhotoMetadata {
        try read(from: Data(contentsOf: url))
    }

    /// The GPS position stored in the photo (e.g. imported from FastFoto), or nil. Like `gps_of`
    /// (`app.py:247-255`) it returns nil when either coordinate is missing or both are exactly 0.
    public static func gps(in data: Data) -> GPSLocation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              var lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              var lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
        if lat == 0 && lon == 0 { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { lat = -abs(lat) }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { lon = -abs(lon) }
        var altitude = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue
        if let a = altitude, (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1 { altitude = -abs(a) }
        return GPSLocation(latitude: lat, longitude: lon, altitude: altitude)
    }

    // MARK: ImageIO plumbing

    enum Namespace {
        static let dc = "http://purl.org/dc/elements/1.1/"
        static let xmpDM = "http://ns.adobe.com/xmp/1.0/DynamicMedia/"
        static let iptcExt = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
    }

    /// Registers the prefixes ImageIO does not know on its own (a no-op for ones it does).
    static func registerNamespaces(_ metadata: CGMutableImageMetadata) {
        CGImageMetadataRegisterNamespaceForPrefix(metadata, Namespace.xmpDM as CFString, "xmpDM" as CFString, nil)
        CGImageMetadataRegisterNamespaceForPrefix(metadata, Namespace.iptcExt as CFString, "Iptc4xmpExt" as CFString, nil)
    }

    static func stringList(_ metadata: CGImageMetadata, path: String) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let tags = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return [] }
        return tags.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    static func setList(_ metadata: CGMutableImageMetadata, path: String, namespace: String, prefix: String,
                        name: String, items: [String]) {
        let elements = items.compactMap {
            CGImageMetadataTagCreate(namespace as CFString, prefix as CFString, "" as CFString, .string, $0 as CFString)
        }
        guard let array = CGImageMetadataTagCreate(namespace as CFString, prefix as CFString, name as CFString,
                                                   .arrayUnordered, elements as CFArray) else { return }
        CGImageMetadataSetTagWithPath(metadata, nil, path as CFString, array)
    }

    static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// The file's EXIF Orientation value, or 1.
    static func currentOrientationTag(_ source: CGImageSource) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    /// Copies the image through ImageIO without decoding it: the compressed data is carried over as is and
    /// `patch` is merged into the existing metadata.
    static func rewrite(_ source: CGImageSource, merging patch: CGImageMetadata) throws -> Data {
        guard let type = CGImageSourceGetType(source) else { throw PhotoMetadataError.unreadableImage }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else {
            throw PhotoMetadataError.writeFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: patch, kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else {
            throw PhotoMetadataError.writeFailed
        }
        return out as Data
    }
}
