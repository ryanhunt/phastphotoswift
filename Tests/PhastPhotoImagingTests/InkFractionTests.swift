import Testing
@testable import PhastPhotoImaging

@Suite struct InkFractionTests {
    private let paper = RGB(236, 232, 222)

    @Test func blankBackIsZero() {
        #expect(InkFraction.of(RGBImage(width: 120, height: 80, fill: paper)) == 0)
    }

    /// A faint maker watermark differs from the paper by far less than the threshold.
    @Test func faintWatermarkIsZero() {
        let image = RGBImage(width: 120, height: 80) { x, y in
            (x / 8 + y / 8) % 2 == 0 ? paper : RGB(paper.r - 12, paper.g - 12, paper.b - 12)
        }
        #expect(InkFraction.of(image) == 0)
    }

    @Test func oneLineOfWritingScoresLow() {
        let image = RGBImage(width: 120, height: 80) { x, y in
            x >= 20 && x < 100 && y >= 38 && y < 42 ? RGB(40, 40, 90) : paper
        }
        let f = InkFraction.of(image)
        #expect(f > 0.02 && f < 0.2, "\(f)")
    }

    @Test func fullPictureScoresHigh() {
        let image = RGBImage(width: 120, height: 80) { x, _ in
            x < 40 ? RGB(20, 20, 20) : (x < 80 ? RGB(240, 230, 220) : RGB(30, 120, 230))
        }
        #expect(InkFraction.of(image) > 0.5)
    }

    /// Measured on a 600 px thumbnail: a large blank image is still zero, writing still shows.
    @Test func largeImagesAreThumbnailed() {
        let big = RGBImage(width: 1500, height: 1000) { x, y in
            x >= 300 && x < 1200 && y >= 480 && y < 520 ? RGB(30, 30, 30) : paper
        }
        let f = InkFraction.of(big)
        #expect(f > 0.02 && f < 0.2, "\(f)")
    }
}
