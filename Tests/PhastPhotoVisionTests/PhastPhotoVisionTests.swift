import CoreGraphics
import Foundation
import PhastPhotoImaging
import Testing
@testable import PhastPhotoVision

@Suite struct PhastPhotoVisionModuleTests {
    @Test func moduleLoads() { _ = PhastPhotoVision.self }
}

// MARK: pure decisions (3.2 candidate choice, 3.3, 4.2, 4.3, 6.2)

@Suite struct BackReaderDecisionTests {
    @Test func bestOrientationByConfidenceTimesLength() {
        let garbage = [RecognizedLine(text: "x", confidence: 0.9)]  // 0.9
        let real = [RecognizedLine(text: "Summer 1986", confidence: 0.8),  // 8.8
                    RecognizedLine(text: "Anna", confidence: 0.5)]  // 2.0
        let r = BackReader.best(of: [garbage, [], real, garbage])
        #expect(r.rotation == 180)
        #expect(r.lines == ["Summer 1986", "Anna"])
        #expect(r.text == "Summer 1986\nAnna")
    }

    @Test func lowConfidenceLinesDroppedAtFourTenths() {
        let c = [RecognizedLine(text: "kept", confidence: 0.4), RecognizedLine(text: "dropped", confidence: 0.39)]
        #expect(BackReader.best(of: [c]).lines == ["kept"])
    }

    @Test func nothingReadMeansNoRotation() {
        let r = BackReader.best(of: [[], [RecognizedLine(text: "abc", confidence: 0.1)], [], []])
        #expect(r.rotation == nil && r.lines.isEmpty)
    }

    @Test func tieKeepsFirstOrientation() {
        let c = [RecognizedLine(text: "same", confidence: 0.9)]
        #expect(BackReader.best(of: [c, c, c, c]).rotation == 0)
    }
}

@Suite struct BackPolicyTests {
    @Test func readGateAtTwoThousandths() async {
        #expect(BackPolicy.hasWriting(ink: 0.002))
        #expect(!BackPolicy.hasWriting(ink: 0.0019))
        let blank = await BackPolicy.readBack(ink: 0.001) { Issue.record("OCR must not run"); return "x" }
        #expect(blank == "")
        let text = await BackPolicy.readBack(ink: 0.008) { "Summer 1986" }
        #expect(text == "Summer 1986")
    }

    private func skip(_ side: BackPolicy.Side = .a, _ sides: BackPolicy.Sides = .both, blanks: Bool = true,
                      crop: Bool = true, text: String? = nil, ink: Double) -> BackPolicy.Skip? {
        BackPolicy.skip(side: side, sides: sides, skipBlankBacks: blanks, crop: crop, backText: text, ink: ink)
    }

    @Test func blankBackNeedsNoTextAndLowInk() {
        #expect(skip(ink: 0.014) == .blankBack(ink: 0.014))
        #expect(skip(ink: 0.015) == nil)  // threshold is inclusive for keeping
        #expect(skip(text: "Summer 1986", ink: 0.0) == nil)  // never drop a back on ink alone
        #expect(skip(text: "", ink: 0.0) == .blankBack(ink: 0))
        #expect(skip(blanks: false, ink: 0) == nil)
        #expect(skip(.b, ink: 0) == nil)  // only backs (side A)
        #expect(skip(.a, .back, ink: 0) == nil)  // back-only mode keeps blank backs
        #expect(skip(.a, .picture, ink: 0) == .blankBack(ink: 0))
    }

    @Test func fastModeDropsBlankPagesOnlyWithCrop() {
        #expect(skip(.b, .fast, ink: 0.002) == .facedUpInFastMode)
        #expect(skip(.b, .fast, crop: false, ink: 0.002) == nil)
        #expect(skip(.b, .fast, ink: 0.14) == nil)
        #expect(skip(.b, .both, ink: 0.002) == nil)
        // blank-back rule comes first on side A
        #expect(skip(.a, .fast, ink: 0.002) == .blankBack(ink: 0.002))
        #expect(BackPolicy.Skip.blankBack(ink: 0.0016).reason == "blank back (ink 0.002)")
    }
}

@Suite struct AutoRotationDecisionTests {
    private func deg(_ d: Double) -> Double { d * .pi / 180 }

    @Test func snapsMedianRollTo90() {
        #expect(AutoRotation.degrees(faceRolls: [deg(10)]) == 0)
        #expect(AutoRotation.degrees(faceRolls: [deg(80)]) == 90)
        #expect(AutoRotation.degrees(faceRolls: [deg(-85)]) == 270)
        #expect(AutoRotation.degrees(faceRolls: [deg(175)]) == 180)
        #expect(AutoRotation.degrees(faceRolls: [deg(-175)]) == 180)
        #expect(AutoRotation.degrees(faceRolls: [deg(44)]) == 0)
        #expect(AutoRotation.degrees(faceRolls: [deg(46)]) == 90)
    }

    @Test func upperMedian() {
        // two faces: index 1 of the sorted list, i.e. the larger one
        #expect(AutoRotation.degrees(faceRolls: [deg(90), deg(0)]) == 90)
        #expect(AutoRotation.degrees(faceRolls: [deg(0), deg(90), deg(90)]) == 90)
        #expect(AutoRotation.degrees(faceRolls: [deg(0), deg(0), deg(90)]) == 0)
    }

    @Test func anyFaceIsDecidedEvenAtZero() {
        let d = AutoRotation.decide(faceRolls: [0.01]) { Issue.record("scene must not run"); return [] }
        #expect(d == RotationDecision(degrees: 0, decided: true))
    }

    @Test func sceneMarginIsInclusiveOneAndFirstBestWins() {
        func d(_ s: [Double]) -> RotationDecision { AutoRotation.decide(sceneScores: s) }
        #expect(d([1.0, 0.5, 2.0, 0.2]) == RotationDecision(degrees: 180, decided: true))  // exactly 1.0 better
        #expect(d([1.0, 0.5, 1.99, 0.2]) == RotationDecision(degrees: 0, decided: false))
        #expect(d([0.5, 1.5, 1.5, 0.2]) == RotationDecision(degrees: 90, decided: true))  // tie: first
        #expect(d([2.0, 0.1, 0.1, 0.1]) == RotationDecision(degrees: 0, decided: false))  // already upright
        #expect(d([1, 2]) == RotationDecision(degrees: 0, decided: false))  // malformed
    }

    @Test func sceneScoresCompareAtThreeDecimals() {
        // 1.0004 rounds to 1.000 (decided); 0.9996 rounds to 1.000 too, as the "%.3f" round trip upstream
        #expect(AutoRotation.decide(sceneScores: [0.0, 1.0004, 0, 0]).decided)
        #expect(AutoRotation.decide(sceneScores: [0.0, 0.9996, 0, 0]).decided)
        #expect(!AutoRotation.decide(sceneScores: [0.0, 0.9994, 0, 0]).decided)
    }

    @Test func noFacesFallsBackToScene() {
        let d = AutoRotation.decide(faceRolls: []) { [0.2, 0.3, 0.2, 2.5] }
        #expect(d == RotationDecision(degrees: 270, decided: true))
    }
}

@Suite struct EyeFinderMappingTests {
    @Test func contourMapsToImageFractionsWithFlippedY() throws {
        // face box in the lower-left quarter (Vision origin bottom-left); eye spans x 0.2...0.4, y 0.5...0.6 of it
        let box = CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)
        let eye = try #require(EyeFinder.eyeFraction(contour: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.4, y: 0.6)], faceBox: box))
        #expect(abs(eye.x - 0.15) < 1e-9)
        #expect(abs(eye.y - (1 - 0.275)) < 1e-9)
        #expect(abs(eye.radius - 0.05) < 1e-9)
        #expect(EyeFinder.eyeFraction(contour: [], faceBox: box) == nil)
    }

    @Test func fractionsScaleToPixelsRadiusByWidth() {
        let e = EyeFinder.eye(fractionX: 0.5, fractionY: 0.25, fractionRadius: 0.1, width: 200, height: 100)
        #expect(e == Eye(x: 100, y: 25, radius: 20))
    }
}

// MARK: timeout

@Suite struct VisionTimeoutTests {
    @Test func returnsResultWithinTime() async throws {
        let v = try await withVisionTimeout(seconds: 5) { 42 }
        #expect(v == 42)
    }

    /// Stand-in for a Vision call that won't return: it blocks until the test releases it, or `fallback` seconds
    /// pass. The checks below are "the work was still blocked when we got control back", not wall-clock times:
    /// when other tests in the process hold every cooperative thread (CI runners have 3 cores), resuming
    /// after the timeout took 12-14 s on CI although the timer fired on time. The fallback only ends the
    /// work if `withVisionTimeout` regresses to waiting for it (the test then fails rather than hangs), so
    /// it is far longer than any such delay.
    final class StuckWork: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _finished = false
        var finished: Bool { lock.withLock { _finished } }
        static let fallback = 120.0
        func run() -> Int {
            _ = gate.wait(timeout: .now() + Self.fallback)
            lock.withLock { _finished = true }
            return 1
        }
        func release() { gate.signal() }
    }

    @Test func givesUpOnSlowWorkWithoutWaitingForIt() async {
        let work = StuckWork()
        await #expect(throws: VisionError.timedOut(seconds: 0.2)) {
            try await withVisionTimeout(seconds: 0.2) { work.run() }
        }
        #expect(!work.finished, "returned only after the work finished")
        work.release()
    }

    @Test func cancellationThrowsWithoutWaitingForTheWork() async {
        let work = StuckWork()
        // no timer: a starved test may only get to cancel after any timeout would have fired
        let task = Task { try await withVisionTimeout(seconds: nil) { work.run() } }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let r = await task.result
        #expect(!work.finished, "returned only after the work finished")
        work.release()
        if case .failure(let e) = r { #expect(e is CancellationError) } else { Issue.record("should have thrown") }
    }

    @Test func propagatesWorkErrors() async {
        await #expect(throws: VisionError.failed("x")) {
            try await withVisionTimeout(seconds: 5) { () -> Int in throw VisionError.failed("x") }
        }
    }
}

// MARK: real Vision OCR (macOS only: Vision on the iOS simulator is not real)

#if os(macOS)
import CoreText

@Suite struct BackReaderOCRTests {
    /// Black text on white, upright, drawn with CoreText.
    static func renderText(_ string: String, width: Int = 900, height: Int = 300) -> RGBImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 90, nil)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        ctx.textPosition = CGPoint(x: 40, y: 110)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        return RGBImage(cgImage: ctx.makeImage()!)
    }

    /// Rotates the pixels clockwise by 0/90/180/270.
    static func rotated(_ im: RGBImage, clockwise degrees: Int) -> RGBImage {
        let w = im.width, h = im.height
        switch degrees {
        case 90: return RGBImage(width: h, height: w) { x, y in im[y, h - 1 - x] }
        case 180: return RGBImage(width: w, height: h) { x, y in im[w - 1 - x, h - 1 - y] }
        case 270: return RGBImage(width: h, height: w) { x, y in im[w - 1 - y, x] }
        default: return im
        }
    }

    @Test(arguments: [0, 90, 180, 270])
    func readsUprightTextAtEveryRotation(turned: Int) async throws {
        let image = Self.rotated(Self.renderText("HELLO WORLD 1986"), clockwise: turned)
        let reading = try await BackReader.read(image)
        let text = reading.text.uppercased().filter { !$0.isWhitespace }
        #expect(text.contains("HELLOWORLD"), "read \(reading.lines) for a print turned \(turned)")
        // The winning rotation is deliberately not checked: Vision's text recogniser reads rotated text at any
        // orientation with similar confidence, so the four candidates tie and the first (0) wins, as upstream.
    }
}
#endif

@Suite struct EyeBridgeTests {
    @Test func eyeMapsToRedEyeInput() {
        let eye = Eye(x: 10.5, y: 20, radius: 4)
        #expect(eye.position == EyePosition(x: 10.5, y: 20, radius: 4))
    }
}
