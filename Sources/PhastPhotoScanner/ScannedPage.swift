import Foundation

/// One side of one print, as it came off the scanner.
public struct ScannedPage: Hashable, Sendable {
    public enum Side: String, Hashable, Sendable, CaseIterable {
        /// Side A, sent first: the side facing down. With prints loaded face up (the usual way) it is the back
        /// of the print; a single-sided scan reads only this side, so load prints face down for pictures only.
        case a = "A"
        /// Side B, the side facing up: the picture when prints are loaded face up. Duplex scans only.
        case b = "B"
    }

    /// Transfer timings for one side.
    public struct TransferStats: Hashable, Sendable {
        /// `IMG ` replies that carried data.
        public var blocks = 0
        public var largestBlock = 0
        public var bytes = 0
        /// Time spent on empty polls: the print still feeding or the next block not encoded yet.
        public var waiting: Duration = .zero
        /// Time spent on replies that carried data.
        public var transferring: Duration = .zero

        public init() {}

        /// Throughput while data was moving, in bytes per second.
        public var bytesPerSecond: Double? {
            let seconds = Double(transferring.components.seconds) + Double(transferring.components.attoseconds) / 1e18
            return seconds > 0 ? Double(bytes) / seconds : nil
        }
    }

    /// The print's position in this scan, from 0. Both sides of a print share it.
    public let index: Int
    public let side: Side
    /// Pixel size from the page-end token (`#pen`).
    public let width: Int
    public let height: Int
    /// The JPEG, its SOF height already corrected. It still includes the scanner's grey backing; crop in software.
    public let jpeg: Data
    public let stats: TransferStats

    public init(index: Int, side: Side, width: Int, height: Int, jpeg: Data, stats: TransferStats = TransferStats()) {
        self.index = index
        self.side = side
        self.width = width
        self.height = height
        self.jpeg = jpeg
        self.stats = stats
    }
}

/// What a finished scan reports.
public struct ScanSummary: Hashable, Sendable {
    /// Pages (sides) delivered.
    public var pageCount: Int
    /// Whether the scanner accepted `#BSZ`; if not, the scan ran with 64 KB blocks.
    public var blockSizeAccepted: Bool
}
