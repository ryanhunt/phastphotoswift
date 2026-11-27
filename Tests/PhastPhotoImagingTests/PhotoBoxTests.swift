import Testing
@testable import PhastPhotoImaging

@Suite struct PhotoBoxTests {
    // test_ffscan.py:39-42
    @Test func longestRun() {
        let F = false, T = true
        // edge specks lose, a 1-gap is bridged
        #expect(PhotoBox.longestRun([T, F, F, F, F, F, T, T, T, F, T, T, F, F, F, F, F, T]) == 6 ..< 12)
        #expect(PhotoBox.longestRun([F, F]) == nil)
    }

    // test_ffscan.py:54-67: band, white fill corner
    @Test func boxIgnoresBandAndWhiteFill() {
        let image = RGBImage(width: 100, height: 80, CropTestScans.boxScan)
        #expect(PhotoBox.find(in: image) == PhotoBox(x0: 20, y0: 5, x1: 80, y1: 50))
    }

    // test_ffscan.py:69-72: 300 dpi raw scans: the outermost columns differ from the backing
    @Test func outerStripIsNotTheBackground() {
        let strip = RGB(40, 40, 45)
        let image = RGBImage(width: 100, height: 80) { x, y in x < 1 || x > 98 ? strip : CropTestScans.boxScan(x, y) }
        #expect(PhotoBox.find(in: image) == PhotoBox(x0: 20, y0: 5, x1: 80, y1: 50))
        #expect(PhotoBox.background(of: image) == CropTestScans.grey)
    }

    /// Pure white (>= 250) is the scanner's deskew fill, never photo: a full-width fill band touching the photo must
    /// not stretch the box.
    @Test func whiteFillBandTouchingThePhotoIsIgnored() {
        let image = RGBImage(width: 100, height: 80) { x, y in
            if y < 20 { return RGB(255, 255, 255) }
            return x >= 20 && x < 80 && y < 60 ? RGB(200, 60, 40) : CropTestScans.grey
        }
        #expect(PhotoBox.find(in: image) == PhotoBox(x0: 20, y0: 20, x1: 80, y1: 60))
    }

    @Test func blankScanFallsBackToWholeImage() {
        let image = RGBImage(width: 50, height: 40, fill: CropTestScans.grey)
        #expect(PhotoBox.find(in: image) == PhotoBox(x0: 0, y0: 0, x1: 50, y1: 40))
    }

    /// Pale sky is as bright as the backing but clearly more colourful: it counts as photo.
    @Test func paleSkyCountsAsPhoto() {
        let cool = RGB(164, 172, 177), sky = RGB(150, 178, 190)
        let image = RGBImage(width: 100, height: 80) { x, y in
            x >= 20 && x < 80 && y >= 10 && y < 60 ? sky : cool
        }
        #expect(PhotoBox.find(in: image) == PhotoBox(x0: 20, y0: 10, x1: 80, y1: 60))
    }
}
