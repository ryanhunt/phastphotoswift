import ImageIO
import PhastPhotoImaging
import SwiftUI

/// One print: each side's cropped image (shown with its orientation tag applied), why a side was skipped,
/// back text, rotation, duplicates, and the metadata read back from the saved file.
struct PrintDetailView: View {
    let record: PrintRecord

    var body: some View {
        List {
            Section("Print") {
                LabeledContent("Run", value: record.run)
                LabeledContent("Scan size", value: record.scanSize)
                LabeledContent("Time and memory", value: record.timing)
                if let failure = record.failure { Text(failure).foregroundStyle(.red) }
                if !record.backText.isEmpty { LabeledContent("Back text", value: record.backText) }
                ForEach(record.warnings, id: \.self) { Text("Warning: \($0)").foregroundStyle(.orange) }
            }
            ForEach(record.sides) { side in
                Section(side.role.capitalized) { SideDetail(side: side) }
            }
        }
        .navigationTitle(record.label)
    }
}

private struct SideDetail: View {
    let side: SideRecord

    var body: some View {
        if let reason = side.skipReason {
            Text("Skipped: \(reason)")
        }
        if let url = side.url {
            Thumbnail(url: url, maxPixelSize: 1600)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 420)
            LabeledContent("File", value: url.lastPathComponent)
            if let rotation = side.rotation { LabeledContent("Rotation", value: rotation) }
            if let duplicate = side.duplicateOf { LabeledContent("Duplicate of", value: duplicate) }
            if let ink = side.ink { LabeledContent("Ink", value: String(format: "%.4f", ink)) }
            MetadataCheck(url: url)
        }
        if let enhanced = side.enhancedURL {
            Text("Enhanced copy" + (side.enhancementSteps.isEmpty ? "" : ": " + side.enhancementSteps.joined(separator: ", ")))
            Thumbnail(url: enhanced, maxPixelSize: 1600)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 420)
        }
    }
}

/// What a saved file carries: `PhotoMetadata.read` (XMP first) beside ImageIO's raw IPTC dictionary, to check
/// that the IPTC copies are written in sync on iOS.
private struct MetadataCheck: View {
    let url: URL
    @State private var lines: [(String, String)] = []

    var body: some View {
        DisclosureGroup("Metadata read back") {
            if lines.isEmpty { Text("none").foregroundStyle(.secondary) }
            ForEach(lines, id: \.0) { key, value in
                LabeledContent(key, value: value).font(.footnote)
            }
        }
        .task(id: url) { lines = Self.read(url) }
    }

    static func read(_ url: URL) -> [(String, String)] {
        var out: [(String, String)] = []
        if let md = try? PhotoMetadata.read(fromFileAt: url) {
            let fields = [("title", md.title), ("description", md.description), ("album", md.album),
                          ("place", md.place), ("headline", md.headline), ("date", md.date),
                          ("people", md.people.joined(separator: ", ")), ("tags", md.tags.joined(separator: ", "))]
            out += fields.filter { !$0.1.isEmpty }.map { ("PhotoMetadata.\($0.0)", $0.1) }
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
                out += iptc.map { ("IPTC \($0.key)", "\($0.value)") }.sorted { $0.0 < $1.0 }
            }
            if let orientation = props[kCGImagePropertyOrientation] { out.append(("Orientation tag", "\(orientation)")) }
        }
        return out
    }
}

/// A downsampled image from a file, with its EXIF orientation applied (so auto-rotation shows).
struct Thumbnail: View {
    let url: URL
    let maxPixelSize: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.secondary.opacity(0.1)
            }
        }
        .task(id: url) {
            let url = url, size = maxPixelSize
            image = await Task.detached(priority: .userInitiated) { Self.load(url, maxPixelSize: size) }.value
        }
    }

    nonisolated static func load(_ url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }
}
