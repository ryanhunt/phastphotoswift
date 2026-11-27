import Foundation
import PhastPhotoProtocol

/// A page written to disk by a ``RawSpool``; the JPEG is no longer held in memory.
public struct SpooledPage: Hashable, Sendable {
    public let index: Int
    /// The side after the mode's relabelling (fast mode: A is B).
    public let side: ScannedPage.Side
    public let width: Int
    public let height: Int
    public let stats: ScannedPage.TransferStats
    public let byteCount: Int
    /// The untouched scan on disk.
    public let url: URL
    /// The photo's name: ``RawSpool/pageName(prefix:number:side:)``.
    public let name: String
    /// See ``ScannedPage/hardwareCropped``.
    public var hardwareCropped: Bool = false
}

/// Writes each scanned side to a directory as it arrives, untouched, so the scan loop does nothing slower
/// than a file write (ports `save_raw`, `app.py:406-412`). Untouched scans also let crop and rotation bugs
/// be reprocessed later. Without it a page stream buffers whole JPEGs (about 5.8 MB per 600 dpi side).
///
/// File names are `<stamp>_<prefix>_<number>.jpg` (side B or the picture) or `..._<number>_back.jpg`
/// (side A). The stamp makes names unique even with a fixed prefix.
public struct RawSpool: Sendable {
    public let directory: URL
    public let prefix: String
    /// Added to a page's index; page numbers start at `firstNumber`.
    public let firstNumber: Int
    public let mode: SideMode
    public let stamp: String

    /// - Parameters:
    ///   - stamp: file name prefix; defaults to the current time as `yyyyMMdd-HHmmss`.
    ///   - mode: the side mode; fast mode relabels A as B before naming (`app.py:639-641`).
    public init(directory: URL, prefix: String = "scan", firstNumber: Int = 1, mode: SideMode = .picture, stamp: String? = nil) {
        self.directory = directory
        self.prefix = prefix
        self.firstNumber = firstNumber
        self.mode = mode
        self.stamp = stamp ?? Self.timestamp()
    }

    /// `app.py:page_name`: `prefix_007.jpg`, `prefix_007_back.jpg`.
    public static func pageName(prefix: String, number: Int, side: ScannedPage.Side) -> String {
        "\(prefix)_\(String(format: "%03d", number))\(side == .b ? "" : "_back").jpg"
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Write one page. Creates the directory; never overwrites an existing file.
    public func write(_ page: ScannedPage) throws -> SpooledPage {
        let side = mode.relabelled(page.side)
        let name = Self.pageName(prefix: prefix, number: firstNumber + page.index, side: side)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appending(path: "\(stamp)_\(name)")
        var attempt = 1
        while FileManager.default.fileExists(atPath: url.path) {
            attempt += 1
            url = directory.appending(path: "\(stamp)-\(attempt)_\(name)")
        }
        try page.jpeg.write(to: url, options: .atomic)
        return SpooledPage(index: page.index, side: side, width: page.width, height: page.height, stats: page.stats,
                           byteCount: page.jpeg.count, url: url, name: name, hardwareCropped: page.hardwareCropped)
    }
}

extension ScannerSession {
    /// ``scan(_:onPage:)`` with every page written to `spool` inside the scan loop, yielding the files.
    /// Memory use stays at one page. Ending the iteration early cancels the scan like ``pages(_:)``.
    public nonisolated func spooledPages(_ settings: ScanSettings, to spool: RawSpool) -> AsyncThrowingStream<SpooledPage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.scan(settings) { page in
                        let spooled = try spool.write(page)
                        if case .terminated = continuation.yield(spooled) { throw CancellationError() }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
