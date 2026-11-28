import Foundation
import Testing
@testable import PhastPhotoImaging
@testable import PhastPhotoPipeline
import PhastPhotoProtocol
import PhastPhotoScanner
import PhastPhotoVision

/// Synthetic scans: a 280x180 print on the scanner's grey backing, as JPEG like the scanner sends.
enum Scans {
    static let backing = RGB(176, 172, 165)
    static let paper = RGB(236, 232, 222)
    static let print = (x0: 40, y0: 30, x1: 320, y1: 210)

    static func scan(_ printPixel: (Int, Int) -> RGB) throws -> Data {
        try RGBImage(width: 360, height: 240) { x, y in
            x >= print.x0 && x < print.x1 && y >= print.y0 && y < print.y1 ? printPixel(x - print.x0, y - print.y0) : backing
        }.jpegData(quality: 0.95)
    }

    /// A colourful picture.
    static func picture(seed: Int = 0) throws -> Data {
        try scan { x, y in
            switch ((x + seed * 37) / 35 + y / 45) % 4 {
            case 0: RGB(200, 40, 40)
            case 1: RGB(40, 150, 60)
            case 2: RGB(30, 60, 190)
            default: RGB(240, 210, 60)
            }
        }
    }

    static func blankBack() throws -> Data { try scan { _, _ in paper } }

    /// One short line of handwriting: marks enough to be read, too little ink to count as written on.
    static func backWithOneLine() throws -> Data {
        try scan { x, y in x >= 90 && x < 190 && y >= 88 && y < 91 ? RGB(40, 40, 90) : paper }
    }

    /// A big stamp: ink well over the blank threshold.
    static func backWithStamp() throws -> Data {
        try scan { x, y in x >= 100 && x < 170 && y >= 60 && y < 110 ? RGB(60, 60, 150) : paper }
    }
}

/// Injected Vision results, recording what was asked.
final class FakeAnalyzer: PrintAnalyzer, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _calls: [String] = []
    let backText: String
    let backFails: Bool
    let rotation: RotationDecision
    let eyes: [EyePosition]

    init(backText: String = "", backFails: Bool = false, rotation: RotationDecision = .init(degrees: 0, decided: false),
         eyes: [EyePosition] = []) {
        self.backText = backText
        self.backFails = backFails
        self.rotation = rotation
        self.eyes = eyes
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    private func record(_ call: String) {
        lock.lock()
        _calls.append(call)
        lock.unlock()
    }

    func readBack(_ back: RGBImage) async throws -> String {
        record("readBack \(back.width)x\(back.height)")
        if backFails { throw Failure() }
        return backText
    }

    func rotation(of picture: RGBImage) async -> RotationDecision {
        record("rotation")
        return rotation
    }

    func eyes(in picture: RGBImage) async throws -> [EyePosition] {
        record("eyes")
        return eyes
    }
}

/// An analyzer whose own human-text step keeps a lone word, as ``VisionAnalyzer`` does for one written in pen.
struct LoneWordAnalyzer: PrintAnalyzer {
    func readBack(_ back: RGBImage) async throws -> String { "Mum" }
    func humanBackText(_ back: RGBImage) async throws -> String { "Mum" }
    func rotation(of picture: RGBImage) async -> RotationDecision { .init(degrees: 0, decided: false) }
    func eyes(in picture: RGBImage) async throws -> [EyePosition] { [] }
}

@Suite struct PrintPipelineTests {
    /// The scans themselves are what the back rules assume: check their cropped ink first.
    @Test func syntheticBacksHaveTheIntendedInk() throws {
        func ink(_ data: Data) throws -> Double { InkFraction.of(AutoCrop.crop(try RGBImage.decode(data)).image) }
        #expect(try ink(Scans.blankBack()) < BackPolicy.readThreshold)
        let line = try ink(Scans.backWithOneLine())
        #expect(line >= BackPolicy.readThreshold && line < BackPolicy.blankThreshold, "\(line)")
        #expect(try ink(Scans.backWithStamp()) >= BackPolicy.blankThreshold)
        #expect(try ink(Scans.picture()) >= BackPolicy.blankThreshold)
    }

    @Test func sideModesMapOntoBackPolicy() {
        #expect(SideMode.allCases.map { BackPolicy.Sides($0).rawValue } == SideMode.allCases.map(\.rawValue))
        #expect(ScanSide.allCases.map { BackPolicy.Side($0).rawValue } == ScanSide.allCases.map(\.rawValue))
    }

    /// Picture mode: the back is read but not kept; its writing and date go into the picture, which is cropped
    /// and tagged with the decided rotation.
    @Test func pictureModeCarriesBackTextAndRotation() async throws {
        let analyzer = FakeAnalyzer(backText: "Mom and Dad 14.7.1986\nKodak paper",
                                    rotation: RotationDecision(degrees: 90, decided: true))
        let pipeline = PrintPipeline(settings: .init(metadata: PhotoMetadata(album: "Holidays")), analyzer: analyzer)
        let result = try await pipeline.process(index: 0, mode: .picture, picture: Scans.picture(),
                                                back: Scans.backWithOneLine())

        #expect(result.backText == "Mom and Dad 14.7.1986")
        #expect(result.back == nil)
        let picture = try #require(result.picture?.saved)
        #expect(picture.side == .b)
        #expect(picture.rotation == RotationDecision(degrees: 90, decided: true))
        #expect(PhotoOrientation.rotation(of: picture.jpeg) == 90)
        let md = try PhotoMetadata.read(from: picture.jpeg)
        #expect(md.description == "Written on back: Mom and Dad 14.7.1986")
        #expect(md.date == "1986-07-14")
        #expect(md.album == "Holidays")
        let image = try RGBImage.decode(picture.jpeg)
        #expect(image.width < 290 && image.width > 260 && image.height < 190 && image.height > 160,
                "\(image.width)x\(image.height)")
        #expect(analyzer.calls.first?.hasPrefix("readBack") == true)
        #expect(analyzer.calls.contains("rotation"))
        #expect(!analyzer.calls.contains("eyes"))
    }

    /// A date given by the user wins over one written on the back.
    @Test func givenDateIsKept() async throws {
        let pipeline = PrintPipeline(settings: .init(metadata: PhotoMetadata(date: "1990")),
                                     analyzer: FakeAnalyzer(backText: "Mom and Dad 14.7.1986"))
        let result = try await pipeline.process(index: 0, mode: .picture, picture: Scans.picture(),
                                                back: Scans.backWithOneLine())
        let md = try PhotoMetadata.read(from: try #require(result.picture?.saved).jpeg)
        #expect(md.date == "1990-01-01")
        #expect(md.description == "Written on back: Mom and Dad 14.7.1986")
    }

    /// Both mode, blank back: ink is under the read threshold, so it isn't even read, and it is dropped.
    @Test func blankBackIsDroppedUnread() async throws {
        let analyzer = FakeAnalyzer(backText: "should not be asked")
        let result = try await PrintPipeline(analyzer: analyzer)
            .process(index: 3, mode: .both, picture: Scans.picture(), back: Scans.blankBack())
        guard case .blankBack(let ink)? = result.back?.skipReason else {
            Issue.record("back not skipped as blank: \(String(describing: result.back))")
            return
        }
        #expect(ink < BackPolicy.blankThreshold)
        #expect(result.picture?.saved != nil)
        #expect(result.index == 3)
        #expect(!analyzer.calls.contains { $0.hasPrefix("readBack") })
    }

    /// One line of writing scores under the blank threshold: whether it is kept depends on the text alone.
    @Test(arguments: [("Mom 1986", true), ("Kodak paper\nL3145CAXCNO.4A 2009", false)])
    func lowInkBackIsKeptOnlyWithWriting(text: String, kept: Bool) async throws {
        let result = try await PrintPipeline(analyzer: FakeAnalyzer(backText: text))
            .process(index: 0, mode: .both, picture: Scans.picture(), back: Scans.backWithOneLine())
        #expect((result.back?.saved != nil) == kept)
        if kept {
            let back = try #require(result.back?.saved)
            #expect(back.side == .a)
            #expect(back.rotation.decided == false)
            // the back keeps the settings' metadata only; its writing goes with the picture
            #expect(try PhotoMetadata.read(from: back.jpeg).description == "")
            #expect(try PhotoMetadata.read(from: try #require(result.picture?.saved).jpeg).description == "Written on back: Mom 1986")
        }
    }

    /// A stamped back has enough ink to be kept without readable text.
    @Test func inkyBackIsKeptWithoutText() async throws {
        let result = try await PrintPipeline(analyzer: FakeAnalyzer())
            .process(index: 0, mode: .both, picture: Scans.picture(), back: Scans.backWithStamp())
        #expect(result.back?.saved != nil)
        #expect(result.backText == "")
    }

    /// The pipeline asks the analyzer for the human text: by default a lone word is filtered out and the
    /// faint back dropped; an analyzer that keeps it (pen ink) keeps the back too.
    @Test func analyzerDecidesTheHumanText() async throws {
        let filtered = try await PrintPipeline(analyzer: FakeAnalyzer(backText: "Mum"))
            .process(index: 0, mode: .both, picture: Scans.picture(), back: Scans.backWithOneLine())
        #expect(filtered.backText == "")
        #expect(filtered.back?.saved == nil)
        let kept = try await PrintPipeline(analyzer: LoneWordAnalyzer())
            .process(index: 0, mode: .both, picture: Scans.picture(), back: Scans.backWithOneLine())
        #expect(kept.backText == "Mum")
        #expect(kept.back?.saved != nil)
    }

    /// A back that couldn't be read is kept (it may have writing) and the failure is reported.
    @Test func unreadableBackIsKept() async throws {
        let result = try await PrintPipeline(analyzer: FakeAnalyzer(backFails: true))
            .process(index: 0, mode: .both, picture: Scans.picture(), back: Scans.backWithOneLine())
        #expect(result.back?.saved != nil)
        #expect(result.warnings.count == 1)
        #expect(result.picture?.saved != nil)
    }

    /// Back mode keeps every back (the blank rule doesn't apply) and reads none.
    @Test func backModeKeepsBlankBacks() async throws {
        let analyzer = FakeAnalyzer(backText: "x")
        let result = try await PrintPipeline(analyzer: analyzer)
            .process(index: 0, mode: .back, picture: nil, back: Scans.blankBack())
        #expect(result.back?.saved != nil)
        #expect(result.picture == nil)
        #expect(analyzer.calls.isEmpty)
    }

    /// Fast mode: a blank face-down side means the print was loaded face up; with crop off the rule is off.
    @Test func fastModeDropsBlankPicturesOnlyWithCrop() async throws {
        let dropped = try await PrintPipeline(analyzer: FakeAnalyzer())
            .process(index: 0, mode: .fast, picture: Scans.blankBack(), back: nil)
        #expect(dropped.picture?.skipReason == .facedUpInFastMode)

        let kept = try await PrintPipeline(settings: .init(crop: false), analyzer: FakeAnalyzer())
            .process(index: 0, mode: .fast, picture: Scans.blankBack(), back: nil)
        #expect(kept.picture?.saved != nil)

        let picture = try await PrintPipeline(analyzer: FakeAnalyzer())
            .process(index: 0, mode: .fast, picture: Scans.picture(), back: nil)
        #expect(try #require(picture.picture?.saved).ink ?? 0 >= BackPolicy.blankThreshold)
    }

    /// With crop, rotation and metadata off, the saved picture is the scan, byte for byte.
    @Test func everythingOffSavesTheScanAsSent() async throws {
        let raw = try Scans.picture()
        let analyzer = FakeAnalyzer(rotation: RotationDecision(degrees: 180, decided: true))
        let result = try await PrintPipeline(settings: .init(crop: false, duplicates: .off, autoRotate: false),
                                             analyzer: analyzer)
            .process(index: 0, mode: .fast, picture: raw, back: nil)
        #expect(try #require(result.picture?.saved).jpeg == raw)
        #expect(analyzer.calls.isEmpty)
    }

    /// The enhanced copy gets the eyes, the same metadata and the same orientation tag as the picture.
    @Test func enhancedCopyMatchesThePicture() async throws {
        let analyzer = FakeAnalyzer(backText: "Mom 1986", rotation: RotationDecision(degrees: 270, decided: true),
                                    eyes: [EyePosition(x: 50, y: 50, radius: 5)])
        let result = try await PrintPipeline(settings: .init(enhancement: EnhancementOptions()), analyzer: analyzer)
            .process(index: 0, mode: .picture, picture: Scans.picture(), back: Scans.backWithOneLine())
        let picture = try #require(result.picture?.saved)
        let enhanced = try #require(picture.enhanced)
        #expect(enhanced != picture.jpeg)
        #expect(picture.enhancementSteps.first == "red-eye (1 eyes checked)")
        #expect(PhotoOrientation.rotation(of: enhanced) == 270)
        #expect(try PhotoMetadata.read(from: enhanced) == PhotoMetadata.read(from: picture.jpeg))
        #expect(try PhotoMetadata.read(from: enhanced).description == "Written on back: Mom 1986")
        #expect(analyzer.calls.contains("eyes"))
    }

    /// Duplicates against pictures already saved, through ``DuplicateIndex``: flag keeps and reports, skip drops,
    /// off doesn't look. A different picture is not a duplicate.
    @Test func duplicatesAreFoundAmongSavedPictures() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-dupes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = DuplicateIndex(file: folder.appendingPathComponent("index.json"))
        let finder: PrintPipeline.DuplicateFinder = { jpeg in
            let saved = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jpg" }
            return try index.findDuplicate(ofJPEG: jpeg, in: saved)
        }

        let first = try await PrintPipeline(analyzer: FakeAnalyzer(), findDuplicate: finder)
            .process(index: 0, mode: .fast, picture: Scans.picture(), back: nil)
        let firstSide = try #require(first.picture?.saved)
        #expect(firstSide.duplicateOf == nil)
        let savedURL = folder.appendingPathComponent("scan_001.jpg")
        try firstSide.jpeg.write(to: savedURL)

        let flagged = try await PrintPipeline(analyzer: FakeAnalyzer(), findDuplicate: finder)
            .process(index: 1, mode: .fast, picture: Scans.picture(), back: nil)
        #expect(flagged.picture?.saved?.duplicateOf?.lastPathComponent == savedURL.lastPathComponent)

        let skipped = try await PrintPipeline(settings: .init(duplicates: .skip), analyzer: FakeAnalyzer(), findDuplicate: finder)
            .process(index: 1, mode: .fast, picture: Scans.picture(), back: nil)
        #expect(skipped.picture?.skipReason?.message == "already scanned: scan_001.jpg")

        let off = try await PrintPipeline(settings: .init(duplicates: .off), analyzer: FakeAnalyzer(),
                                          findDuplicate: { _ in Issue.record("looked for duplicates"); return nil })
            .process(index: 1, mode: .fast, picture: Scans.picture(), back: nil)
        #expect(off.picture?.saved?.duplicateOf == nil)

        let other = try await PrintPipeline(analyzer: FakeAnalyzer(), findDuplicate: finder)
            .process(index: 2, mode: .fast, picture: Scans.picture(seed: 1), back: nil)
        #expect(other.picture?.saved?.duplicateOf == nil)
    }

    /// The scanner already cut these sides to the paper (hardware crop): no software crop, neither of the saved
    /// sides nor of the back read for writing, and the scans are saved as sent.
    @Test func hardwareCroppedSidesAreNotCroppedAgain() async throws {
        // "paper" filling the whole image, as a hardware-cropped scan arrives
        let picture = try RGBImage(width: 200, height: 140) { x, y in
            [RGB(200, 40, 40), RGB(40, 150, 60), RGB(30, 60, 190)][(x / 30 + y / 40) % 3]
        }.jpegData(quality: 0.95)
        let back = try RGBImage(width: 200, height: 140) { x, y in
            x >= 40 && x < 160 && y >= 60 && y < 63 ? RGB(40, 40, 90) : Scans.paper
        }.jpegData(quality: 0.95)
        let analyzer = FakeAnalyzer(backText: "Mom 1986")
        let result = try await PrintPipeline(settings: .init(duplicates: .off, autoRotate: false, metadata: PhotoMetadata()),
                                             analyzer: analyzer)
            .process(index: 0, mode: .both, picture: picture, back: back, hardwareCropped: true)
        #expect(analyzer.calls.first == "readBack 200x140")
        #expect(result.backText == "Mom 1986")
        let savedPicture = try #require(result.picture?.saved)
        let image = try RGBImage.decode(savedPicture.jpeg)
        #expect(image.width == 200 && image.height == 140)
        #expect(try #require(result.back?.saved).jpeg == back)  // no metadata, no crop: as sent

        // the same scan without the flag is cropped (the box comes out smaller)
        let cropped = try await PrintPipeline(settings: .init(duplicates: .off, autoRotate: false), analyzer: FakeAnalyzer())
            .process(index: 0, mode: .fast, picture: Scans.picture(), back: nil)
        let croppedImage = try RGBImage.decode(try #require(cropped.picture?.saved).jpeg)
        #expect(croppedImage.width < 360)
    }

    /// From scanner pages the flag comes from the pages themselves.
    @Test func assembledPrintsPassHardwareCropOn() async throws {
        let analyzer = FakeAnalyzer()
        var assembler = PrintAssembler(mode: .fast)
        let page = ScannedPage(index: 0, side: .a, width: 360, height: 240, jpeg: try Scans.picture(), hardwareCropped: true)
        let print = try #require(assembler.add(page).first)
        let result = try await PrintPipeline(settings: .init(duplicates: .off, autoRotate: false), analyzer: analyzer).process(print)
        let image = try RGBImage.decode(try #require(result.picture?.saved).jpeg)
        #expect(image.width == 360 && image.height == 240)
    }

    /// End to end from scanner pages: the assembler pairs A and B, the pipeline processes the print.
    @Test func assembledPrintsGoThroughThePipeline() async throws {
        var assembler = PrintAssembler(mode: .both)
        let a = ScannedPage(index: 0, side: .a, width: 360, height: 240, jpeg: try Scans.backWithStamp())
        let b = ScannedPage(index: 0, side: .b, width: 360, height: 240, jpeg: try Scans.picture())
        #expect(assembler.add(a).isEmpty)
        let print = try #require(assembler.add(b).first)
        let result = try await PrintPipeline(analyzer: FakeAnalyzer(backText: "Grandma 1975")).process(print)
        #expect(result.saved.map(\.side) == [.a, .b])
        #expect(try PhotoMetadata.read(from: result.saved[1].jpeg).date == "1975-01-01")
    }
}
