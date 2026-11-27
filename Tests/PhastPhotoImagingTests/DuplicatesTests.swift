import Foundation
import Testing
@testable import PhastPhotoImaging

/// Small deterministic generator (SplitMix64) standing in for Python's seeded `random.Random`.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `test_ffscan.py:118-136`: 12x8 random grey blocks of 10 px (120x80) stand in for a photo.
func blocks(seed: UInt64) -> RGBImage {
    var rng = SplitMix64(seed: seed)
    let grey = (0 ..< 96).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
    return RGBImage(width: 120, height: 80) { x, y in
        let v = grey[(x / 10) * 8 + y / 10]
        return RGB(v, v, v)
    }
}

/// 90 degrees counter-clockwise, like Pillow `rotate(90, expand=True)`.
func rotatedCCW(_ im: RGBImage) -> RGBImage {
    RGBImage(width: im.height, height: im.width) { x, y in im[im.width - 1 - y, x] }
}

@Suite struct DuplicateHashTests {
    @Test func samePrintRotatedResizedIsDuplicateDifferentPrintIsNot() {
        for seed in [UInt64(1), 3, 4, 5, 6, 7] {  // seed 1 mirrors upstream; others check the margin
            let grad = blocks(seed: seed), other = blocks(seed: seed + 100)
            let variant = rotatedCCW(grad).resized(width: 60, height: 90)  // Core Graphics: independent of the hasher
            #expect(Duplicates.distance(Duplicates.hashes(variant), Duplicates.hashes(grad)) <= Duplicates.threshold,
                    "seed \(seed)")
            #expect(Duplicates.distance(Duplicates.hashes(other), Duplicates.hashes(grad)) > Duplicates.threshold,
                    "seed \(seed)")
        }
    }

    @Test func upstreamSeeds() {
        let grad = blocks(seed: 1), other = blocks(seed: 2)
        let variant = rotatedCCW(grad).resized(width: 60, height: 90)
        #expect(Duplicates.distance(Duplicates.hashes(variant), Duplicates.hashes(grad)) <= Duplicates.threshold)
        #expect(Duplicates.distance(Duplicates.hashes(other), Duplicates.hashes(grad)) > Duplicates.threshold)
    }

    @Test func rotationsAreFourDistinctOrientations() {
        let im = blocks(seed: 9)
        let h = Duplicates.hashes(im)
        #expect(h.count == 4 && h[0] == Duplicates.dhash(im))
        // photo b is photo a turned 180: some rotation of b matches a exactly
        let turned = RGBImage(width: im.width, height: im.height) { x, y in im[im.width - 1 - x, im.height - 1 - y] }
        #expect(Duplicates.distance(Duplicates.hashes(im), Duplicates.hashes(turned)) == 0)
    }

    @Test func dhashBitOrderAndComparison() {
        // brightness falls left to right: every pixel is brighter than its right neighbour -> all ones
        let falling = RGBImage(width: 90, height: 80) { x, _ in let v = UInt8(250 - x * 2); return RGB(v, v, v) }
        #expect(Duplicates.dhash(falling) == UInt64.max)
        let rising = RGBImage(width: 90, height: 80) { x, _ in let v = UInt8(x * 2); return RGB(v, v, v) }
        #expect(Duplicates.dhash(rising) == 0)
        // first column bright, rest dark: only the first bit of each row (the top bit of each byte) is set
        let edge = RGBImage(width: 9, height: 8) { x, _ in x == 0 ? RGB(255, 255, 255) : RGB(0, 0, 0) }
        #expect(Duplicates.dhash(edge) == 0x8080_8080_8080_8080)
    }

    @Test func lumaUsesBT601Weights() {
        let plane = Duplicates.Plane(RGBImage(width: 3, height: 1) { x, _ in
            [RGB(255, 0, 0), RGB(0, 255, 0), RGB(0, 0, 255)][x]
        })
        #expect(plane.pixels == [76, 150, 29])  // Pillow convert("L")
    }

    @Test func lanczosCoefficientsFollowPillow() {
        // a constant plane stays constant; support is widened by the downscale factor
        let flat = PillowResample.resize([UInt8](repeating: 77, count: 36 * 36), width: 36, height: 36,
                                         to: 9, 8, filter: .lanczos)
        #expect(flat.allSatisfy { $0 == 77 })
        let coeffs = PillowResample.coefficients(inSize: 36, outSize: 9, filter: .lanczos)
        #expect(coeffs[4].weights.count == 24)  // support 3 x scale 4, both sides
        #expect(abs(coeffs[4].weights.reduce(0, +) - 1) < 1e-9)
    }

    @Test func largeImageIsThumbnailedBeforeHashing() {
        let big = RGBImage(width: 600, height: 400) { x, y in
            let v = UInt8(((x / 60) * 37 + (y / 50) * 91) % 256); return RGB(v, v, v)
        }
        let small = big.resized(width: 240, height: 160)
        #expect(Duplicates.distance(Duplicates.hashes(small), Duplicates.hashes(big)) <= Duplicates.threshold)
    }
}

@Suite struct DuplicateIndexTests {
    func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dupes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func write(_ image: RGBImage, _ name: String, in dir: URL, age: TimeInterval) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try image.jpegData(quality: 0.9).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 - age)],
                                              ofItemAtPath: url.path)
        return url
    }

    @Test func groupsAreOldestFirstAndSingletonsLeftOut() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = blocks(seed: 1), b = blocks(seed: 2), c = blocks(seed: 3)
        let newest = try write(a, "scan3.jpg", in: dir, age: 0)
        let single = try write(b, "scan2.jpg", in: dir, age: 100)
        let middle = try write(rotatedCCW(a).resized(width: 60, height: 90), "scan1.jpg", in: dir, age: 200)
        let oldest = try write(a.resized(width: 240, height: 160), "scan0.jpg", in: dir, age: 300)
        let other = try write(c, "scan4.jpg", in: dir, age: 50)
        let index = DuplicateIndex(file: dir.appendingPathComponent("cache/dupes.json"))
        let groups = try index.groups([newest, single, middle, oldest, other])
        #expect(groups == [[oldest, middle, newest]])
        // findDuplicate returns the first candidate matching, never the file itself
        #expect(try index.findDuplicate(of: newest, in: [newest, single, middle, oldest]) == middle)
        #expect(try index.findDuplicate(of: single, in: [newest, middle, oldest, other]) == nil)
    }

    @Test func cacheIsReusedUntilTheModificationDateChanges() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write(blocks(seed: 1), "a.jpg", in: dir, age: 10)
        let gone = try write(blocks(seed: 2), "b.jpg", in: dir, age: 20)
        let cacheFile = dir.appendingPathComponent("sub/index.json")
        let index = DuplicateIndex(file: cacheFile)
        let first = try index.hashes(for: url)
        _ = try index.hashes(for: gone)
        #expect(index.computed == 2)
        #expect(try index.hashes(for: url) == first && index.computed == 2)
        try index.save()

        // a new index reads the cache file: no recomputation
        let reloaded = DuplicateIndex(file: cacheFile)
        #expect(try reloaded.hashes(for: url) == first && reloaded.computed == 0)

        // the file changes (new picture, new date): hashes are recomputed
        try write(blocks(seed: 5), "a.jpg", in: dir, age: 5)
        let changed = try reloaded.hashes(for: url)
        #expect(reloaded.computed == 1 && changed != first)

        // saving drops entries of deleted files
        try FileManager.default.removeItem(at: gone)
        try reloaded.save()
        let text = try String(contentsOf: cacheFile, encoding: .utf8)
        #expect(text.contains("a.jpg") && !text.contains("b.jpg"))
    }
}
