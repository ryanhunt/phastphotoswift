import Foundation
import Testing
@testable import PhastPhotoImaging

/// Port of `test_ffscan.py:176-183`, with synthetic bytes in a temporary folder.
@Suite struct FastFotoImportTests {
    static func makeFolder(_ names: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fastfoto-\(UUID().uuidString)")
        for name in names {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic \(name)".utf8).write(to: url)
        }
        return root
    }

    static func relative(_ root: URL, _ url: URL?) -> String? {
        guard let url else { return nil }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        return String(url.resolvingSymlinksInPath().path.dropFirst(prefix.count))
    }

    static func found(_ root: URL) throws -> [[String?]] {
        try FastFotoImport.photos(in: root).map { [relative(root, $0.picture), relative(root, $0.back)] }
    }

    @Test func originalsWithBacksAndLoneEnhancedCopies() throws {
        let root = try Self.makeFolder(["F_0001.jpg", "F_0001_a.jpg", "F_0002.jpg", "F_0002_b.jpg",
                                        "Al/F_0001.jpg", "Al/F_0001_a.jpg", "G_0003_a.jpg"])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try Self.found(root)
        #expect(found == [["Al/F_0001.jpg", nil], ["F_0001.jpg", nil], ["F_0002.jpg", "F_0002_b.jpg"],
                          ["G_0003_a.jpg", nil]])
    }

    @Test func extensionsAnyCaseAndOtherFilesIgnored() throws {
        let root = try Self.makeFolder(["A_1.JPG", "A_1_b.JPEG", "B_2.jpeg", "C_3.png", "notes.txt", "D_4_b.jpg"])
        defer { try? FileManager.default.removeItem(at: root) }
        // a back alone is not a photo
        #expect(try Self.found(root) == [["A_1.JPG", "A_1_b.JPEG"], ["B_2.jpeg", nil]])
    }

    @Test func orderedByLowercasedPath() throws {
        let root = try Self.makeFolder(["b_1.jpg", "A_2.jpg", "c_0.jpg"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try Self.found(root).map { $0[0] } == ["A_2.jpg", "b_1.jpg", "c_0.jpg"])
    }

    @Test func enhancedCopyWithBackUsesTheBack() throws {
        let root = try Self.makeFolder(["X_a.jpg", "X_b.jpg"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try Self.found(root) == [["X_a.jpg", "X_b.jpg"]])
    }

    @Test func sourcesAreNeverModified() throws {
        let root = try Self.makeFolder(["F_1.jpg", "F_1_b.jpg"])
        defer { try? FileManager.default.removeItem(at: root) }
        func snapshot() throws -> [String: Data] {
            Dictionary(uniqueKeysWithValues: try FileManager.default.contentsOfDirectory(atPath: root.path).map {
                ($0, try Data(contentsOf: root.appendingPathComponent($0)))
            })
        }
        let before = try snapshot()
        _ = try FastFotoImport.photos(in: root)
        #expect(try snapshot() == before)
    }

    @Test func importPolicy() {
        #expect(FastFotoImportPolicy.standard.crop == false)
        #expect(FastFotoImportPolicy.standard.fastTreatedAsPicture)
    }

    @Test func missingFolderThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try FastFotoImport.photos(in: missing) }
    }
}
