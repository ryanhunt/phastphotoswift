import Foundation

/// One photo found in an Epson FastFoto output folder: the picture file and, when FastFoto saved one, its back.
public struct FastFotoPhoto: Sendable, Hashable {
    /// The scan (`Name_0001.jpg`), or the enhanced copy (`Name_0001_a.jpg`) when the original is missing.
    public var picture: URL
    /// The back of the print (`Name_0001_b.jpg`), if present.
    public var back: URL?

    public init(picture: URL, back: URL? = nil) {
        self.picture = picture
        self.back = back
    }
}

/// How imported FastFoto files go through the normal pipeline. Port of the overrides in `import_job`
/// (`app.py:692-704`): FastFoto has already cropped and straightened the pictures, and fast mode's face-down
/// check only makes sense for real scans.
public struct FastFotoImportPolicy: Sendable, Hashable {
    /// Do not crop: FastFoto already did.
    public var crop: Bool = false
    /// Fast side mode becomes "picture" (the other side modes are unchanged).
    public var fastTreatedAsPicture: Bool = true

    public init() {}
    public static let standard = FastFotoImportPolicy()
}

/// Reading an Epson FastFoto folder. Sources are only ever read, never modified.
public enum FastFotoImport {
    /// Photos in a FastFoto folder in name order, subfolders included. Port of `fastfoto_photos`
    /// (`app.py:677-689`).
    ///
    /// FastFoto saves `Name_0001.jpg` (the scan), `Name_0001_a.jpg` (its enhanced copy) and `Name_0001_b.jpg`
    /// (the back). Enhanced copies are skipped when the original exists (the pipeline makes its own), and kept
    /// when it does not. Files are matched by path without extension, `.jpg`/`.jpeg` in any case; ordering is by
    /// the lowercased extensionless relative path, comparing code points. If two files share a stem (`a.jpg`
    /// and `a.JPEG`) the later one in sorted name order wins, deterministically (upstream's depends on
    /// directory order). Symlinked directories are not followed and directories named like pictures are ignored.
    public static func photos(in folder: URL) throws -> [FastFotoPhoto] {
        var files: [String: URL] = [:]  // relative path without extension -> file
        try collect(folder, relative: "", into: &files)

        let keys = files.keys.sorted { codePoints($0.lowercased()).lexicographicallyPrecedes(codePoints($1.lowercased())) }
        var out: [FastFotoPhoto] = []
        for key in keys {
            let (dir, name) = split(key)
            let baseName = name.hasSuffix("_a") || name.hasSuffix("_b") ? String(name.dropLast(2)) : name
            let base = dir + baseName
            let isOriginal = key == base
            let isLoneEnhanced = name.hasSuffix("_a") && files[base] == nil
            if isOriginal || isLoneEnhanced, let picture = files[key] {
                out.append(FastFotoPhoto(picture: picture, back: files[base + "_b"]))
            }
        }
        return out
    }

    private static func codePoints(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }

    private static func split(_ key: String) -> (dir: String, name: String) {
        guard let slash = key.lastIndex(of: "/") else { return ("", key) }
        return (String(key[...slash]), String(key[key.index(after: slash)...]))
    }

    private static func collect(_ dir: URL, relative: String, into files: inout [String: URL]) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if values?.isSymbolicLink != true {
                    try collect(url, relative: relative + name + "/", into: &files)
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard ext == "jpg" || ext == "jpeg", name.count > ext.count + 1 else { continue }
            files[relative + String(name.dropLast(ext.count + 1))] = url
        }
    }
}
