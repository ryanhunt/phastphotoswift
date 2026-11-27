import Foundation
import ImageIO
import Testing
@testable import PhastPhotoImaging

@Suite struct PhotoMetadataTests {
    static let full = PhotoMetadata(
        title: "Beach", description: "Kids at the beach.", album: "Summer 1986", place: "Seaside",
        headline: "Two kids and a dog", people: ["Anna", "Ben"], tags: ["beach", "dog"], date: "1986-07")

    @Test func writeThenRead() throws {
        let original = try syntheticJPEG()
        let written = try PhotoMetadata.write(Self.full, to: original)
        var expected = Self.full
        expected.date = "1986-07-01"  // missing parts default to 01; read gives the EXIF date
        #expect(try PhotoMetadata.read(from: written) == expected)
        #expect(scanData(of: written) == scanData(of: original))  // no re-encode
        #expect(scanData(of: original) != nil)
        // Pixels still decode.
        #expect(try RGBImage.decode(written).width == 48)
    }

    @Test func tagsLandWhereUpstreamPutThem() throws {
        let written = try PhotoMetadata.write(Self.full, to: try syntheticJPEG())
        let source = CGImageSourceCreateWithData(written as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as! [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as! [CFString: Any]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "1986:07:01 00:00:00")
        #expect(tiff[kCGImagePropertyTIFFImageDescription] as? String == "Kids at the beach.")
        // IPTC properties are reported (mapped from XMP by ImageIO).
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCObjectName] as? String == "Beach")
        #expect(iptc?[kCGImagePropertyIPTCKeywords] as? [String] == ["beach", "dog"])
        // XMP namespaces and the date.
        let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil)!
        func value(_ path: String) -> String? { CGImageMetadataCopyStringValueWithPath(xmp, nil, path as CFString) as String? }
        #expect(value("photoshop:DateCreated")?.hasPrefix("1986-07") == true)  // ImageIO completes it from EXIF
        #expect(value("photoshop:Headline") == "Two kids and a dog")
        #expect(value("Iptc4xmpCore:Location") == "Seaside")
        #expect(value("dc:description") == "Kids at the beach.")
        // The XMP packet carries the people and album under their namespaces.
        let packet = String(decoding: written, as: UTF8.self)
        #expect(packet.contains("PersonInImage"))
        #expect(packet.contains("http://ns.adobe.com/xmp/1.0/DynamicMedia/"))
    }

    /// ImageIO writes a legacy IPTC record (Photoshop 8BIM resource) next to the XMP, not only IPTC properties.
    @Test func legacyIPTCRecordIsWritten() throws {
        let written = try PhotoMetadata.write(Self.full, to: try syntheticJPEG())
        let marker = try #require("Photoshop 3.0".data(using: .ascii))
        let range = try #require(written.range(of: marker))
        let record = written[range.lowerBound...].prefix(800)
        for word in ["Beach", "Seaside", "Two kids and a dog", "dog"] {
            #expect(record.range(of: Data(word.utf8)) != nil, "\(word) missing from the IPTC record")
        }
    }

    @Test func listsAreDeduplicatedAndAppended() throws {
        var md = PhotoMetadata(people: ["Anna", "Ben", "Anna"], tags: ["a", "b", "a", " b "])
        let once = try PhotoMetadata.write(md, to: try syntheticJPEG())
        #expect(try PhotoMetadata.read(from: once).people == ["Anna", "Ben"])
        #expect(try PhotoMetadata.read(from: once).tags == ["a", "b"])
        // Writing again: an existing item is moved to the end (-= then +=), new ones follow, no duplicates.
        md = PhotoMetadata(people: ["Cleo", "Anna"], tags: ["c", "a"])
        let twice = try PhotoMetadata.write(md, to: once)
        #expect(try PhotoMetadata.read(from: twice).people == ["Ben", "Cleo", "Anna"])
        #expect(try PhotoMetadata.read(from: twice).tags == ["b", "c", "a"])
    }

    @Test func emptyFieldsLeaveExistingValuesAlone() throws {
        let first = try PhotoMetadata.write(Self.full, to: try syntheticJPEG())
        let second = try PhotoMetadata.write(PhotoMetadata(title: "New title"), to: first)
        var expected = Self.full
        expected.date = "1986-07-01"
        expected.title = "New title"
        #expect(try PhotoMetadata.read(from: second) == expected)
        #expect(try PhotoMetadata.read(from: try syntheticJPEG()) == PhotoMetadata())
    }

    @Test func dateForms() throws {
        func exifDate(_ date: String) throws -> String {
            let data = try PhotoMetadata.write(PhotoMetadata(date: date), to: try syntheticJPEG())
            return try PhotoMetadata.read(from: data).date
        }
        #expect(try exifDate("1974") == "1974-01-01")
        #expect(try exifDate("1974-03") == "1974-03-01")
        #expect(try exifDate("1974-03-09") == "1974-03-09")
        #expect(try exifDate("1974/03/09") == "1974-03-09")
        #expect(throws: PhotoMetadataError.invalidDate("last summer")) {
            try PhotoMetadata.write(PhotoMetadata(date: "last summer"), to: try syntheticJPEG())
        }
        #expect(try exifDate(" 1974 / 03 / 09 ") == "1974-03-09")
        for bad in ["1974-13", "1974-03-32", "0000", "1974-00-10"] {
            #expect(throws: PhotoMetadataError.invalidDate(bad)) {
                try PhotoMetadata.write(PhotoMetadata(date: bad), to: try syntheticJPEG())
            }
        }
        #expect(throws: PhotoMetadataError.invalidDate("1974-03-09-1")) {
            try PhotoMetadata.write(PhotoMetadata(date: "1974-03-09-1"), to: try syntheticJPEG())
        }
    }

    @Test func unicodeSurvives() throws {
        let md = PhotoMetadata(title: "Noël à la plage 🏖", description: "Zoë\nsecond line", people: ["Zoë"])
        let data = try PhotoMetadata.write(md, to: try syntheticJPEG())
        #expect(try PhotoMetadata.read(from: data) == md)
    }

    @Test func keepsRotationAndOtherMetadata() throws {
        let start = try syntheticJPEG(properties: [kCGImagePropertyOrientation: 6, kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300])
        let written = try PhotoMetadata.write(Self.full, to: start)
        #expect(PhotoOrientation.rotation(of: written) == 90)
        let rotated = try PhotoOrientation.setRotation(180, in: written)
        #expect(try PhotoMetadata.read(from: rotated).title == "Beach")  // rotation keeps the metadata
        #expect(scanData(of: rotated) == scanData(of: start))
    }

    @Test func backTextMerge() {
        let md = PhotoMetadata(description: "Kids at the beach.", tags: ["beach"])
        let merged = md.merging(backText: "Seaside 1986", dateFromBackText: "1986")
        #expect(merged.description == "Kids at the beach.\nWritten on back: Seaside 1986")
        #expect(merged.date == "1986")
        #expect(merged.tags == ["beach"])
        // A given date wins over the one on the back.
        #expect(PhotoMetadata(date: "1990").merging(backText: "x", dateFromBackText: "1986").date == "1990")
        // No existing description: no leading newline.
        #expect(PhotoMetadata().merging(backText: "x").description == "Written on back: x")
        // No back text: nothing changes, not even the date.
        #expect(md.merging(backText: "", dateFromBackText: "1986") == md)
    }

    @Test func commaLists() {
        #expect(PhotoMetadata.list(fromCommaSeparated: " a, b ,, c ") == ["a", "b", "c"])
        #expect(PhotoMetadata.list(fromCommaSeparated: "").isEmpty)
    }

    // test_ffscan.py:225-234, with a file written by code instead of exiftool.
    @Test func gpsRead() throws {
        #expect(PhotoMetadata.gps(in: try syntheticJPEG()) == nil)
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 49.7075, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.2034, kCGImagePropertyGPSLongitudeRef: "W",
            kCGImagePropertyGPSAltitude: 12.5, kCGImagePropertyGPSAltitudeRef: 0,
        ]
        let data = try syntheticJPEG(properties: [kCGImagePropertyGPSDictionary: gps])
        let location = try #require(PhotoMetadata.gps(in: data))
        #expect(abs(location.latitude - 49.7075) < 1e-6)
        #expect(abs(location.longitude + 0.2034) < 1e-6)
        #expect(location.altitude == 12.5)
        // Writing metadata keeps the GPS block.
        let written = try PhotoMetadata.write(Self.full, to: data)
        #expect(PhotoMetadata.gps(in: written) == location)
    }

    @Test func gpsSouthAndZeroZero() throws {
        let south: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 33.9, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 151.2, kCGImagePropertyGPSLongitudeRef: "E",
            kCGImagePropertyGPSAltitude: 3.0, kCGImagePropertyGPSAltitudeRef: 1,
        ]
        let loc = try #require(PhotoMetadata.gps(in: try syntheticJPEG(properties: [kCGImagePropertyGPSDictionary: south])))
        #expect(loc.latitude == -33.9 && loc.longitude == 151.2 && loc.altitude == -3.0)
        let zero: [CFString: Any] = [kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLatitudeRef: "N",
                                     kCGImagePropertyGPSLongitude: 0.0, kCGImagePropertyGPSLongitudeRef: "E"]
        #expect(PhotoMetadata.gps(in: try syntheticJPEG(properties: [kCGImagePropertyGPSDictionary: zero])) == nil)
    }

    @Test func fileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try syntheticJPEG().write(to: url)
        try PhotoMetadata.write(Self.full, toFileAt: url)
        #expect(try PhotoMetadata.read(fromFileAt: url).title == "Beach")
    }

    @Test func rejectsNonImages() {
        #expect(throws: PhotoMetadataError.unreadableImage) { try PhotoMetadata.write(Self.full, to: Data([1, 2, 3])) }
        #expect(throws: PhotoMetadataError.unreadableImage) { try PhotoMetadata.read(from: Data()) }
    }
}
