import Foundation
import PhastPhotoProtocol

/// One side of one print, as it came off the scanner.
public struct ScannedPage: Hashable, Sendable {
    /// A or B; see ``ScanSide``.
    public typealias Side = ScanSide

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

        /// One line for logs: blocks, largest block, wait and transfer seconds, speed.
        public var summaryLine: String {
            func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
            var line = "\(blocks) blocks, largest \(largestBlock / 1024) KiB, wait \(String(format: "%.1f", seconds(waiting))) s, "
                + "transfer \(String(format: "%.1f", seconds(transferring))) s"
            if let speed = bytesPerSecond { line += String(format: ", %.1f MB/s", speed / 1e6) }
            return line
        }

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

extension ScannedPage {
    /// The same page under another side label (fast mode relabels A as B: ``SideMode/relabelled(_:)``).
    public func relabelled(as side: Side) -> ScannedPage {
        ScannedPage(index: index, side: side, width: width, height: height, jpeg: jpeg, stats: stats)
    }
}

/// What a finished scan reports.
public struct ScanSummary: Hashable, Sendable {
    /// Pages (sides) delivered.
    public var pageCount: Int
    /// Whether the scanner accepted `#BSZ`; if not, the scan ran with 64 KB blocks.
    public var blockSizeAccepted: Bool
    /// The scan ended early because ``ScannerSession/stopAfterCurrentPrint()`` was called; the print that was
    /// feeding finished first.
    public var stoppedEarly = false

    public init(pageCount: Int, blockSizeAccepted: Bool, stoppedEarly: Bool = false) {
        self.pageCount = pageCount
        self.blockSizeAccepted = blockSizeAccepted
        self.stoppedEarly = stoppedEarly
    }
}
