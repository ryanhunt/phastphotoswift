import Foundation
import Testing
@testable import phastphoto
import PhastPhotoImaging
import PhastPhotoPipeline
import PhastPhotoProtocol
import PhastPhotoScanner
import PhastPhotoVision

/// Synthetic scans: a 280x180 print on grey backing, as JPEG.
private enum Scans {
    static func scan(_ printPixel: (Int, Int) -> RGB) throws -> Data {
        try RGBImage(width: 360, height: 240) { x, y in
            x >= 40 && x < 320 && y >= 30 && y < 210 ? printPixel(x - 40, y - 30) : RGB(176, 172, 165)
        }.jpegData(quality: 0.95)
    }

    static func picture(seed: Int = 0) throws -> Data {
        try scan { x, y in
            [RGB(200, 40, 40), RGB(40, 150, 60), RGB(30, 60, 190), RGB(240, 210, 60)][((x + seed * 37) / 35 + y / 45) % 4]
        }
    }

    static func blankBack() throws -> Data { try scan { _, _ in RGB(236, 232, 222) } }

    static func stampedBack() throws -> Data {
        try scan { x, y in x >= 100 && x < 170 && y >= 60 && y < 110 ? RGB(60, 60, 150) : RGB(236, 232, 222) }
    }
}

private struct FakeAnalyzer: PrintAnalyzer {
    var backText = ""
    var rotation = RotationDecision(degrees: 90, decided: true)
    func readBack(_ back: RGBImage) async throws -> String { backText }
    func rotation(of picture: RGBImage) async -> RotationDecision { rotation }
    func eyes(in picture: RGBImage) async throws -> [EyePosition] { [] }
}

/// Collects log lines from a ``PrintFolder``.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func append(_ line: String) { lock.withLock { _lines.append(line) } }
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "phastphoto-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func names(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

@Suite struct RawScanFilesTests {
    @Test func parsesSpoolNames() {
        #expect(RawScanFiles.parse("20261127-101500_scan_007.jpg")! == ("20261127-101500_scan_000007", false))
        #expect(RawScanFiles.parse("20261127-101500_scan_007_back.jpg")! == ("20261127-101500_scan_000007", true))
        #expect(RawScanFiles.parse("20261127-101500-2_scan_007_back.jpg")! == ("20261127-101500-2_scan_000007", true))
        #expect(RawScanFiles.parse("20261127-101500_my_album_1234.jpg")! == ("20261127-101500_my_album_001234", false))
        #expect(RawScanFiles.parse("IMG_0001.jpg") == nil)
        #expect(RawScanFiles.parse("scan_001.jpg") == nil)
        #expect(RawScanFiles.parse("20261127-101500_scan_7.jpg") == nil)
        #expect(RawScanFiles.parse("20261127-101500_scan_007.png") == nil)
        #expect(RawScanFiles.parse("2026112-101500_scan_007.jpg") == nil)
    }

    /// Numbers sort as numbers (1000 after 999), backs pair with their pictures, other files come last.
    @Test func groupsPrintsInScanOrder() {
        let urls = ["20261127-101500_scan_1000.jpg", "20261127-101500_scan_999_back.jpg", "IMG_0002.jpg",
                    "20261127-101500_scan_999.jpg", "IMG_0001.jpg"].map { URL(filePath: "/x/\($0)") }
        let (prints, ignored) = RawScanFiles.prints(in: urls, mode: .both)
        #expect(ignored.isEmpty)
        #expect(prints.map { [$0.back?.lastPathComponent, $0.picture?.lastPathComponent] } == [
            ["20261127-101500_scan_999_back.jpg", "20261127-101500_scan_999.jpg"],
            [nil, "20261127-101500_scan_1000.jpg"],
            [nil, "IMG_0001.jpg"],
            [nil, "IMG_0002.jpg"],
        ])
    }

    /// RawSpool's collision suffix sorts as a number after the plain stamp (as text, "-" sorts before "_").
    @Test func collisionSuffixesSortAfterThePlainStamp() {
        let urls = ["S-10_scan_001.jpg", "S-2_scan_001.jpg", "S_scan_002.jpg", "S_scan_001.jpg"]
            .map { URL(filePath: "/x/20261127-101500\($0.dropFirst())") }
        let order = RawScanFiles.prints(in: urls, mode: .fast).prints.map { $0.picture!.lastPathComponent }
        #expect(order == ["20261127-101500_scan_001.jpg", "20261127-101500_scan_002.jpg",
                          "20261127-101500-2_scan_001.jpg", "20261127-101500-10_scan_001.jpg"])
    }

    @Test func ignoresSidesTheModeDoesNotRead() {
        let urls = ["20261127-101500_scan_001_back.jpg", "20261127-101500_scan_001.jpg"].map { URL(filePath: "/x/\($0)") }
        let fast = RawScanFiles.prints(in: urls, mode: .fast)
        #expect(fast.prints == [RawScanFiles.Print(picture: urls[1], back: nil)])
        #expect(fast.ignored.map(\.0) == [urls[0]])
        let back = RawScanFiles.prints(in: urls, mode: .back)
        #expect(back.prints == [RawScanFiles.Print(picture: nil, back: urls[0])])
        #expect(back.ignored.map(\.0) == [urls[1]])
    }
}

@Suite struct PrintFolderTests {
    /// Two prints in both mode: a blank back is skipped, a stamped one kept; the second picture repeats the
    /// first and is flagged; files get the folder's names; the enhanced copies go to Enhanced/.
    @Test func savesKeptSidesAndFlagsDuplicates() async throws {
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let log = Log()
        var settings = PrintPipelineSettings(enhancement: EnhancementOptions())
        settings.metadata.album = "Test"
        let folder = PrintFolder(directory: out, mode: .both, settings: settings, analyzer: FakeAnalyzer(), stamp: "S",
                                 warmUp: false, log: log.append)
        await folder.add(ScannedPage(index: 0, side: .a, width: 0, height: 0, jpeg: try Scans.blankBack()))
        await folder.add(ScannedPage(index: 0, side: .b, width: 0, height: 0, jpeg: try Scans.picture()))
        await folder.add(ScannedPage(index: 1, side: .a, width: 0, height: 0, jpeg: try Scans.stampedBack()))
        await folder.add(ScannedPage(index: 1, side: .b, width: 0, height: 0, jpeg: try Scans.picture()))
        let totals = await folder.finish()

        #expect(totals == PrintFolder.Totals(prints: 2, picturesSaved: 2, backsSaved: 1, skipped: 1, duplicates: 1, failed: 0))
        #expect(names(in: out) == ["Enhanced", "S_scan_001.jpg", "S_scan_002.jpg", "S_scan_002_back.jpg"])
        #expect(names(in: out.appending(path: "Enhanced")) == ["S_scan_001.jpg", "S_scan_002.jpg"])
        #expect(FileManager.default.fileExists(atPath: out.appending(path: PrintFolder.duplicateCache).path))
        let picture = try Data(contentsOf: out.appending(path: "S_scan_001.jpg"))
        #expect(PhotoOrientation.rotation(of: picture) == 90)
        #expect(try PhotoMetadata.read(from: picture).album == "Test")
        #expect(log.lines.contains { $0.hasPrefix("print 1: back skipped: blank back") })
        #expect(log.lines.contains { $0.hasPrefix("print 2:") && $0.contains("duplicate of S_scan_001.jpg") })
    }

    /// A print that can't be processed is reported and counted; the next one still is processed. Nothing is
    /// ever written over an existing file.
    @Test func failuresDoNotStopTheRunAndFilesAreNotOverwritten() async throws {
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let existing = out.appending(path: "S_scan_002.jpg")
        try Data("keep me".utf8).write(to: existing)
        let log = Log()
        let folder = PrintFolder(directory: out, mode: .fast, settings: PrintPipelineSettings(duplicates: .off),
                                 analyzer: FakeAnalyzer(), stamp: "S", warmUp: false, log: log.append)
        await folder.add(ScannedPage(index: 0, side: .a, width: 0, height: 0, jpeg: Data("not a jpeg".utf8)))
        await folder.add(ScannedPage(index: 1, side: .a, width: 0, height: 0, jpeg: try Scans.picture()))
        let totals = await folder.finish()
        #expect(totals.failed == 1)
        #expect(totals.picturesSaved == 1)
        #expect(log.lines.first?.hasPrefix("print 1: processing failed") == true)
        #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
        #expect(names(in: out) == ["S_scan_002-2.jpg", "S_scan_002.jpg"])
    }

    /// `scan --process`: pages go through the raw spool (fast mode relabels A as B in the file name) and still
    /// reach the pipeline with the side the scanner sent. A back waiting at the end of a stack is processed then.
    @Test(arguments: [SideMode.fast, .picture, .both])
    func processingQueueKeepsTheScannersSides(mode: SideMode) async throws {
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let spool = RawSpool(directory: out.appending(path: "raw"), mode: mode, stamp: "S")
        let folder = PrintFolder(directory: out, mode: mode, settings: PrintPipelineSettings(duplicates: .off),
                                 analyzer: FakeAnalyzer(backText: "Mom 1986"), stamp: "S", warmUp: false, log: { _ in })
        let queue = ProcessingQueue(spool: StackedSpool(spool), folder: folder)
        if let backSide = mode.backSide { _ = try queue.add(ScannedPage(index: 0, side: backSide, width: 0, height: 0, jpeg: try Scans.stampedBack())) }
        _ = try queue.add(ScannedPage(index: 0, side: mode.pictureSide!, width: 0, height: 0, jpeg: try Scans.picture()))
        if mode.duplex { _ = try queue.add(ScannedPage(index: 1, side: .a, width: 0, height: 0, jpeg: try Scans.stampedBack())) }
        queue.endOfStack()
        let totals = await queue.finish()

        #expect(totals.picturesSaved == 1)
        #expect(totals.failed == 0)
        let raw = names(in: out.appending(path: "raw"))
        switch mode {
        case .fast:
            #expect(raw == ["S_scan_001.jpg"])
            #expect(totals.prints == 1)
        case .picture:
            // the backs are spooled for reading but not saved; the lone back of print 2 is a print of its own
            #expect(raw == ["S_scan_001.jpg", "S_scan_001_back.jpg", "S_scan_002_back.jpg"])
            #expect(totals == PrintFolder.Totals(prints: 2, picturesSaved: 1, backsSaved: 0, skipped: 0, duplicates: 0, failed: 0))
            let md = try PhotoMetadata.read(from: Data(contentsOf: out.appending(path: "S_scan_001.jpg")))
            #expect(md.description == "Written on back: Mom 1986")
        default:
            #expect(totals.backsSaved == 2)
        }
    }

    /// Raws from a default scan are hardware-cropped: `process` passes that on unless told to crop in software.
    @Test func rawPagesAreHardwareCroppedByDefault() throws {
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let url = out.appending(path: "20261127-101500_scan_001.jpg")
        try Scans.picture().write(to: url)
        let item = RawScanFiles.Print(picture: url, back: nil)
        #expect(try RawScanFiles.pages(of: item, index: 0, mode: .fast).map(\.hardwareCropped) == [true])
        #expect(try RawScanFiles.pages(of: item, index: 0, mode: .fast, hardwareCropped: false).map(\.hardwareCropped) == [false])
        let spooled = try RawSpool(directory: out, mode: .fast, stamp: "S")
            .write(ScannedPage(index: 0, side: .a, width: 0, height: 0, jpeg: Data("x".utf8), hardwareCropped: true))
        #expect(spooled.hardwareCropped)
    }

    /// Fast mode's raw picture (relabelled B in its name) goes back to the pipeline as side A, as the scanner sent it.
    @Test func fastRawPicturesAreSideA() throws {
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let url = out.appending(path: "20261127-101500_scan_001.jpg")
        try Scans.picture().write(to: url)
        let pages = try RawScanFiles.pages(of: RawScanFiles.Print(picture: url, back: nil), index: 0, mode: .fast)
        #expect(pages.map(\.side) == [.a])
    }

    /// A watch's stacks each start at page index 0: their raw names continue the numbering instead of
    /// colliding, so they stay in scan order for `process`.
    @Test func stacksContinueTheRawNumbering() throws {
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let spool = StackedSpool(RawSpool(directory: out, mode: .picture, stamp: "S"))
        let jpeg = Data("x".utf8)
        for _ in 0 ..< 2 {
            for index in 0 ..< 2 {
                _ = try spool.write(ScannedPage(index: index, side: .a, width: 0, height: 0, jpeg: jpeg))
                _ = try spool.write(ScannedPage(index: index, side: .b, width: 0, height: 0, jpeg: jpeg))
            }
            spool.endOfStack()
        }
        spool.endOfStack()  // an empty stack doesn't skip numbers
        _ = try spool.write(ScannedPage(index: 0, side: .b, width: 0, height: 0, jpeg: jpeg))
        #expect(names(in: out) == ["S_scan_001.jpg", "S_scan_001_back.jpg", "S_scan_002.jpg", "S_scan_002_back.jpg",
                                   "S_scan_003.jpg", "S_scan_003_back.jpg", "S_scan_004.jpg", "S_scan_004_back.jpg",
                                   "S_scan_005.jpg"])
    }

    /// A raw file that can't be read still takes its print number and counts as failed; a run that processed
    /// nothing leaves no duplicate cache.
    @Test func unreadablePrintsKeepTheNumbering() async throws {
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let log = Log()
        let folder = PrintFolder(directory: out, mode: .fast, settings: PrintPipelineSettings(),
                                 analyzer: FakeAnalyzer(), stamp: "S", warmUp: false, log: log.append)
        await folder.recordFailure("couldn't read x")
        await folder.add(ScannedPage(index: 1, side: .a, width: 0, height: 0, jpeg: try Scans.picture()))
        let totals = await folder.finish()
        #expect(totals == PrintFolder.Totals(prints: 2, picturesSaved: 1, backsSaved: 0, skipped: 0, duplicates: 0, failed: 1))
        #expect(names(in: out) == ["S_scan_002.jpg"])
        #expect(log.lines.first == "print 1: couldn't read x")

        let empty = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: empty) }
        let idle = PrintFolder(directory: empty, mode: .fast, settings: PrintPipelineSettings(), analyzer: FakeAnalyzer(),
                               stamp: "S", warmUp: false, log: { _ in })
        #expect(await idle.finish() == PrintFolder.Totals())
        #expect(!FileManager.default.fileExists(atPath: empty.appending(path: PrintFolder.duplicateCache).path))
    }

    /// `process`: raw files written by the spool are paired again and processed like the live scan.
    @Test func rawFilesRoundTripThroughTheSpoolNames() async throws {
        let out = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let rawFolder = out.appending(path: "raw")
        let spool = RawSpool(directory: rawFolder, mode: .picture, stamp: "20261127-101500")
        for index in 0 ..< 2 {
            _ = try spool.write(ScannedPage(index: index, side: .a, width: 0, height: 0, jpeg: try Scans.stampedBack()))
            _ = try spool.write(ScannedPage(index: index, side: .b, width: 0, height: 0, jpeg: try Scans.picture(seed: index)))
        }
        let (prints, ignored) = RawScanFiles.prints(in: try RawScanFiles.jpegs(at: [rawFolder.path]), mode: .picture)
        #expect(ignored.isEmpty)
        #expect(prints.count == 2)
        let pages = try RawScanFiles.pages(of: prints[0], index: 0, mode: .picture)
        #expect(pages.map(\.side) == [.a, .b])
        #expect(pages.map(\.width) == [360, 360])

        let folder = PrintFolder(directory: out, mode: .picture, settings: PrintPipelineSettings(),
                                 analyzer: FakeAnalyzer(backText: "Grandma 1975"), stamp: "P", warmUp: false, log: { _ in })
        for (index, item) in prints.enumerated() {
            for page in try RawScanFiles.pages(of: item, index: index, mode: .picture) { await folder.add(page) }
            await folder.endOfStack()
        }
        let totals = await folder.finish()
        #expect(totals == PrintFolder.Totals(prints: 2, picturesSaved: 2, backsSaved: 0, skipped: 0, duplicates: 0, failed: 0))
        #expect(names(in: out) == ["P_scan_001.jpg", "P_scan_002.jpg", "raw"])
        #expect(try PhotoMetadata.read(from: Data(contentsOf: out.appending(path: "P_scan_002.jpg"))).date == "1975-01-01")
    }
}
