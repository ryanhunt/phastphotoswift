import Testing
@testable import PhastPhotoImaging

/// Synthetic backs in the colours measured on real ones (28 Nov 2026): off-white paper, the paper maker's pattern and
/// a lab code in pale grey, a handwritten word in blue ballpoint.
@Suite struct PenInkTests {
    static let paper = RGB(239, 238, 240)
    static let paleGrey = RGB(215, 214, 218)  // about 70 from the paper: the watermark and lab code
    static let ballpoint = RGB(60, 90, 190)  // about 370 from the paper

    /// A 300 x 200 back with a "word" of vertical strokes (every third column of a band) in `ink` at
    /// x 30..<150, y 120..<150.
    static func back(word ink: RGB) -> RGBImage {
        RGBImage(width: 300, height: 200) { x, y in
            (30 ..< 150).contains(x) && (120 ..< 150).contains(y) && x % 3 == 0 ? ink : paper
        }
    }

    static let wordBox = NormalizedBox(x0: 0.1, y0: 0.6, x1: 0.5, y1: 0.75)

    @Test func paperIsTheMedianColour() {
        #expect(PenInk.paper(of: Self.back(word: Self.ballpoint)) == Self.paper)
    }

    @Test func penWordIsWrittenAndPaleWordIsNot() {
        let pen = Self.back(word: Self.ballpoint)
        let pale = Self.back(word: Self.paleGrey)
        #expect(PenInk.strongShare(in: pen, box: Self.wordBox, paper: Self.paper) > 0.3)
        #expect(PenInk.strongShare(in: pale, box: Self.wordBox, paper: Self.paper) == 0)
        #expect(PenInk.isWritten(in: pen, box: Self.wordBox, paper: Self.paper))
        #expect(!PenInk.isWritten(in: pale, box: Self.wordBox, paper: Self.paper))
        // the box matters: blank paper elsewhere on the same back is not pen
        #expect(!PenInk.isWritten(in: pen, box: NormalizedBox(x0: 0.6, y0: 0.1, x1: 0.9, y1: 0.3), paper: Self.paper))
    }

    /// A speck of dust or a full stop in a pale line is not enough.
    @Test func aFewStrongPixelsAreNotPen() {
        let image = RGBImage(width: 300, height: 200) { x, y in
            x == 60 && y == 130 ? RGB(0, 0, 0) : (x % 3 == 0 && (120 ..< 150).contains(y) ? Self.paleGrey : Self.paper)
        }
        #expect(!PenInk.isWritten(in: image, box: Self.wordBox, paper: Self.paper))
    }

    @Test func boxesAreClampedToTheImage() {
        #expect(NormalizedBox(x0: -0.5, y0: 0.5, x1: 0.5, y1: 1.5).pixels(width: 100, height: 50)
            == PhotoBox(x0: 0, y0: 25, x1: 50, y1: 50))
        #expect(NormalizedBox(x0: 0.5, y0: 0.5, x1: 0.2, y1: 0.1).pixels(width: 100, height: 100)
            == PhotoBox(x0: 20, y0: 10, x1: 50, y1: 50))  // corners in either order
        #expect(NormalizedBox(x0: 1.2, y0: 0, x1: 1.5, y1: 1).pixels(width: 100, height: 100) == nil)
        #expect(PenInk.strongShare(in: Self.back(word: Self.ballpoint), box: NormalizedBox(x0: 2, y0: 2, x1: 3, y1: 3),
                                   paper: Self.paper) == 0)
    }
}

@Suite struct PenLineTests {
    /// ffscan drops a lone word; one written in pen is kept.
    @Test func loneWordInPenIsKept() {
        #expect(BackText.humanText([BackLine(text: "Harbour,", penInk: true)]) == "Harbour,")
        #expect(BackText.humanText([BackLine(text: "Harbour,", penInk: false)]) == "")
        #expect(BackText.humanText("Harbour,") == "")
    }

    /// Pen doesn't rescue what isn't a word: watermark words, lab codes, two-letter fragments.
    @Test func penKeepsOnlyRealWords() {
        // "0001 NNNN": a dark lab code has a word-like run of letters, but not alone on its line
        for text in ["FUJIFILM", "archive", "B12345", "(IMG_9.JPG)", "Jo", "0001 NNNN", "KIMG 12"] {
            #expect(BackText.humanText([BackLine(text: text, penInk: true)]) == "", Comment(rawValue: text))
        }
    }

    @Test func eachLineIsJudgedOnItsOwnInk() {
        let lines = [BackLine(text: "rchive"), BackLine(text: "Mum", penInk: true), BackLine(text: "FILMI"),
                     BackLine(text: "Dana and Yoni")]
        #expect(BackText.humanText(lines) == "Mum\nDana and Yoni")
    }
}
