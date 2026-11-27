import Foundation

/// Perceptual duplicate detection. Port of ffscan `dupes.py`: a 64-bit difference hash (dHash) of the image in all
/// four rotations, so the same print is recognised whatever way round it was fed, at any resolution, crop or
/// JPEG quality.
public enum Duplicates {
    /// Maximum differing bits (of 64) to call two scans the same print (`dupes.py:16`). Measured by ffscan on
    /// rescans of an 18-print stack: same print 0-6, different prints >= 9. Needs re-checking on this port.
    public static let threshold = 7

    /// Longest side of the image the hash is computed from (`dupes.py:39-42`).
    static let thumbnailSize = 256

    // MARK: Hash

    /// An 8-bit grey plane, top row first.
    struct Plane {
        var width: Int
        var height: Int
        var pixels: [UInt8]

        /// Pillow `convert("L")`: `L = (R*19595 + G*38470 + B*7471 + 0x8000) >> 16`, the BT.601 weights.
        init(_ image: RGBImage) {
            width = image.width; height = image.height
            var out = [UInt8](repeating: 0, count: width * height)
            image.pixels.withUnsafeBufferPointer { s in
                out.withUnsafeMutableBufferPointer { d in
                    for i in 0 ..< d.count {
                        let v = Int(s[i * 3]) * 19595 + Int(s[i * 3 + 1]) * 38470 + Int(s[i * 3 + 2]) * 7471
                        d[i] = UInt8((v + 0x8000) >> 16)
                    }
                }
            }
            pixels = out
        }

        init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width; self.height = height; self.pixels = pixels
        }

        /// Pillow `Image.thumbnail((n, n))`: fit within n x n keeping the aspect ratio, never enlarged.
        /// (Pillow's extra `reducing_gap` box-reduction step is not reproduced.)
        func thumbnail(_ n: Int) -> Plane {
            guard max(width, height) > n else { return self }
            let scale = Double(n) / Double(max(width, height))
            let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
            return Plane(width: w, height: h,
                         pixels: PillowResample.resize(pixels, width: width, height: height, to: w, h, filter: .bicubic))
        }

        /// Pillow `rotate(angle, expand=True)` for a multiple of 90 degrees, counter-clockwise.
        func rotated(_ angle: Int) -> Plane {
            let w = width, h = height
            switch ((angle % 360) + 360) % 360 {
            case 90:
                return Plane(width: h, height: w, pixels: (0 ..< w * h).map { i in
                    let x = i % h, y = i / h
                    return pixels[x * w + (w - 1 - y)]
                })
            case 180:
                return Plane(width: w, height: h, pixels: pixels.reversed())
            case 270:
                return Plane(width: h, height: w, pixels: (0 ..< w * h).map { i in
                    let x = i % h, y = i / h
                    return pixels[(h - 1 - x) * w + y]
                })
            default:
                return self
            }
        }

        /// `dupes.py:dhash`: is each pixel brighter than its right neighbour, on a 9x8 Lanczos thumbnail.
        func dhash() -> UInt64 {
            let g = PillowResample.resize(pixels, width: width, height: height, to: 9, 8, filter: .lanczos)
            var bits: UInt64 = 0
            for row in 0 ..< 8 {
                for col in 0 ..< 8 {
                    bits = bits << 1 | (g[row * 9 + col] > g[row * 9 + col + 1] ? 1 : 0)
                }
            }
            return bits
        }
    }

    /// 64-bit difference hash of one image as stored (`dupes.py:dhash`).
    public static func dhash(_ image: RGBImage) -> UInt64 {
        Plane(image).dhash()
    }

    /// dHash of the image in all 4 rotations, 0, 90, 180, 270 degrees counter-clockwise (`dupes.py:hashes`).
    /// Images over 256 px are thumbnailed first.
    public static func hashes(_ image: RGBImage) -> [UInt64] {
        let plane = Plane(image).thumbnail(thumbnailSize)
        return [0, 90, 180, 270].map { plane.rotated($0).dhash() }
    }

    /// Hashes of the picture file at `url`. JPEGs are decoded at reduced size (ImageIO), like Pillow's `draft`.
    public static func hashes(contentsOf url: URL) throws -> [UInt64] {
        let data = try Data(contentsOf: url)
        return hashes(try RGBImage.decode(data, maxPixelSize: thumbnailSize))
    }

    /// Smallest Hamming distance between photo `a` (as stored, its first hash) and any rotation of photo `b`.
    public static func distance(_ a: [UInt64], _ b: [UInt64]) -> Int {
        b.map { (a[0] ^ $0).nonzeroBitCount }.min() ?? 64
    }
}

/// Cache of picture hashes in a JSON file, recomputed when a file's modification date changes (`dupes.py:Index`).
/// The caller supplies the picture URLs: unlike ffscan there is no file-name filtering (`is_picture`).
/// The cache file uses ffscan's format: `{path: {"mtime": seconds, "h": [4 hashes]}}`.
public final class DuplicateIndex: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        var mtime: Double
        var h: [UInt64]
    }

    public let file: URL
    private let lock = NSLock()
    private var data: [String: Entry]
    private var computedCount = 0

    /// Number of files hashed (cache misses) since creation; for tests.
    var computed: Int {
        lock.lock()
        defer { lock.unlock() }
        return computedCount
    }

    public init(file: URL) {
        self.file = file
        data = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))) ?? [:]
    }

    static func modificationDate(_ url: URL) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? .distantPast
    }

    /// The four hashes of `url`, from the cache when its modification date is unchanged.
    public func hashes(for url: URL) throws -> [UInt64] {
        let mtime = try Self.modificationDate(url).timeIntervalSince1970
        lock.lock()
        let cached = data[url.path]
        lock.unlock()
        if let cached, cached.mtime == mtime { return cached.h }
        let entry = Entry(mtime: mtime, h: try Duplicates.hashes(contentsOf: url))
        lock.lock()
        data[url.path] = entry
        computedCount += 1
        lock.unlock()
        return entry.h
    }

    /// Writes the cache, dropping entries whose file no longer exists.
    public func save() throws {
        lock.lock()
        defer { lock.unlock() }
        data = data.filter { FileManager.default.fileExists(atPath: $0.key) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(data).write(to: file, options: .atomic)
    }

    /// The first of `candidates` that shows the same print as `url`, or `nil`.
    public func findDuplicate(of url: URL, in candidates: [URL]) throws -> URL? {
        let h = try hashes(for: url)
        for other in candidates where other.path != url.path {
            if Duplicates.distance(h, try hashes(for: other)) <= Duplicates.threshold { return other }
        }
        return nil
    }

    /// Duplicate groups among `urls`, oldest first in each group; singletons are left out.
    public func groups(_ urls: [URL]) throws -> [[URL]] {
        let dated = try urls.enumerated().map { ($0.offset, $0.element, try Self.modificationDate($0.element)) }
        let sorted = dated.sorted { ($0.2, $0.0) < ($1.2, $1.0) }.map(\.1)  // stable: ties keep input order
        var seen = Set<String>(), out: [[URL]] = []
        for (i, p) in sorted.enumerated() where !seen.contains(p.path) {
            let hp = try hashes(for: p)
            var group = [p]
            for q in sorted[(i + 1)...] where !seen.contains(q.path) {
                if Duplicates.distance(hp, try hashes(for: q)) <= Duplicates.threshold { group.append(q) }
            }
            if group.count > 1 {
                seen.formUnion(group.map(\.path))
                out.append(group)
            }
        }
        return out
    }
}
