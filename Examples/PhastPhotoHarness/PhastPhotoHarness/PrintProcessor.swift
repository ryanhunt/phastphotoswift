import Foundation
import PhastPhotoImaging
import PhastPhotoPipeline
import PhastPhotoProtocol
import PhastPhotoScanner
import PhastPhotoVision

/// One side of a processed print, for the results list.
struct SideRecord: Identifiable, Sendable {
    let id = UUID()
    /// "picture" or "back".
    let role: String
    /// The saved file, or nil when the side was skipped.
    let url: URL?
    let enhancedURL: URL?
    let enhancementSteps: [String]
    let skipReason: String?
    /// Pictures only: "rotation 90°" or "rotation not decided".
    let rotation: String?
    let duplicateOf: String?
    let ink: Double?
}

/// One print after the pipeline, with how long it took and how much memory it needed.
struct PrintRecord: Identifiable, Sendable {
    let id = UUID()
    /// "print 3", "sample 2".
    let label: String
    /// "scan 20261127-101500, 600 dpi, both".
    let run: String
    let dpi: Int
    /// Size of the picture side as scanned (or of the back when there is no picture).
    let scanSize: String
    var sides: [SideRecord] = []
    var backText = ""
    var warnings: [String] = []
    /// Set when the pipeline threw: nothing was saved.
    var failure: String?
    /// Reading the raw files, the pipeline and saving.
    var seconds: Double = 0
    var startBytes: UInt64 = 0
    var peakBytes: UInt64 = 0

    var summary: String {
        if let failure { return "failed: \(failure)" }
        var parts = sides.map { side -> String in
            if let reason = side.skipReason { return "\(side.role) skipped (\(reason))" }
            var text = "\(side.role) saved"
            if let rotation = side.rotation { text += ", \(rotation)" }
            if let duplicate = side.duplicateOf { text += ", duplicate of \(duplicate)" }
            return text
        }
        if parts.isEmpty { parts.append("nothing to save") }
        return parts.joined(separator: "; ")
    }

    var timing: String {
        String(format: "%.2f s, peak %@ (+%@)", seconds, MemoryMeter.megabytes(peakBytes),
               MemoryMeter.megabytes(peakBytes > startBytes ? peakBytes - startBytes : 0))
    }
}

/// Runs PrintPipeline over pages in scan order and saves what it keeps in `output`, like the CLI's
/// `PrintFolder`: `<stamp>_scan_001.jpg` (picture), `..._back.jpg`, `Enhanced/...`. Pictures already in
/// `output` are the duplicate candidates, so a stack scanned twice is flagged. Errors are per print.
actor PrintProcessor {
    let output: URL
    let mode: SideMode
    let stamp: String
    let label: String
    let run: String
    let dpi: Int
    private let pipeline: PrintPipeline
    private let duplicateIndex: DuplicateIndex
    private var assembler: PrintAssembler
    private var number: Int
    private var processedAny = false

    static let enhancedFolder = "Enhanced"
    static let duplicateCache = ".phastphoto-duplicates.json"

    init(output: URL, mode: SideMode, settings: PrintPipelineSettings, stamp: String, label: String, run: String,
         dpi: Int, firstNumber: Int = 1, analyzer: any PrintAnalyzer = VisionAnalyzer()) {
        self.output = output
        self.mode = mode
        self.stamp = stamp
        self.label = label
        self.run = run
        self.dpi = dpi
        number = firstNumber - 1
        assembler = PrintAssembler(mode: mode)
        let index = DuplicateIndex(file: output.appending(path: Self.duplicateCache))
        duplicateIndex = index
        pipeline = PrintPipeline(settings: settings, analyzer: analyzer, findDuplicate: { jpeg in
            try index.findDuplicate(ofJPEG: jpeg, in: PrintProcessor.savedPictures(in: output))
        })
    }

    /// Pictures saved in `directory` itself: `.jpg`, not a back.
    static func savedPictures(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "jpg" && !$0.lastPathComponent.hasSuffix("_back.jpg") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A side as the scanner sent it (fast mode's side A not yet relabelled), already on disk. Returns the
    /// prints this side completed. The JPEG is read back here, so memory holds one print at a time.
    func add(_ spooled: SpooledPage, side: ScanSide) async -> [PrintRecord] {
        let page: ScannedPage
        do {
            let jpeg = try Data(contentsOf: spooled.url)
            page = ScannedPage(index: spooled.index, side: side, width: spooled.width, height: spooled.height,
                               jpeg: jpeg, stats: spooled.stats)
        } catch {
            number += 1
            var record = PrintRecord(label: "\(label) \(number)", run: run, dpi: dpi, scanSize: "?")
            record.failure = "couldn't read \(spooled.url.lastPathComponent): \(error.localizedDescription)"
            return [record]
        }
        var records: [PrintRecord] = []
        for item in assembler.add(page) { records.append(await process(item)) }
        return records
    }

    /// End of the scan: a back still waiting for its picture is processed alone, and the duplicate cache saved.
    func finish() async -> [PrintRecord] {
        var records: [PrintRecord] = []
        for item in assembler.finish() { records.append(await process(item)) }
        if processedAny { try? duplicateIndex.save() }
        return records
    }

    private func process(_ item: AssembledPrint) async -> PrintRecord {
        number += 1
        processedAny = true
        let size = (item.picture ?? item.back).map { "\($0.width)×\($0.height)" } ?? "?"
        var record = PrintRecord(label: "\(label) \(number)", run: run, dpi: dpi, scanSize: size)
        let sampler = PeakSampler()
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let result = try await pipeline.process(item)
            record.backText = result.backText
            record.warnings = result.warnings
            if let back = result.back { record.sides.append(try save(back, role: "back")) }
            if let picture = result.picture { record.sides.append(try save(picture, role: "picture")) }
        } catch {
            record.failure = "\(error)"
        }
        let elapsed = started.duration(to: clock.now)
        record.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        record.peakBytes = sampler.stop()
        record.startBytes = sampler.start
        return record
    }

    private func save(_ outcome: SideOutcome, role: String) throws -> SideRecord {
        switch outcome {
        case .skipped(let reason):
            return SideRecord(role: role, url: nil, enhancedURL: nil, enhancementSteps: [], skipReason: reason.message,
                              rotation: nil, duplicateOf: nil, ink: nil)
        case .saved(let side):
            let name = RawSpool.pageName(prefix: "\(stamp)_\(label)", number: number, side: side.side)
            let url = try Self.write(side.jpeg, to: output, name: name)
            let enhanced = try side.enhanced.map {
                try Self.write($0, to: output.appending(path: Self.enhancedFolder), name: name)
            }
            let rotation = side.side == .b
                ? (side.rotation.decided ? "rotation \(side.rotation.degrees)°" : "rotation not decided") : nil
            return SideRecord(role: role, url: url, enhancedURL: enhanced, enhancementSteps: side.enhancementSteps,
                              skipReason: nil, rotation: rotation, duplicateOf: side.duplicateOf?.lastPathComponent,
                              ink: side.ink)
        }
    }

    /// Writes `data` as `name` in `folder`, never over an existing file (`-2`, `-3`, ... before the extension).
    private static func write(_ data: Data, to folder: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = folder.appending(path: name)
        var attempt = 1
        while FileManager.default.fileExists(atPath: url.path) {
            attempt += 1
            url = folder.appending(path: "\(base)-\(attempt).\(ext)")
        }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}

/// The scan loop's hand-off: each page is written to the raw spool inside the loop (a file write) and queued
/// here; one task runs the pipeline over the queue in order, so the scanner never waits for Vision.
final class ProcessingQueue: Sendable {
    private let continuation: AsyncStream<(SpooledPage, ScanSide)>.Continuation
    private let task: Task<Void, Never>

    init(processor: PrintProcessor, onRecords: @escaping @Sendable ([PrintRecord]) async -> Void) {
        let (stream, continuation) = AsyncStream<(SpooledPage, ScanSide)>.makeStream()
        self.continuation = continuation
        task = Task {
            for await (page, side) in stream {
                let records = await processor.add(page, side: side)
                if !records.isEmpty { await onRecords(records) }
            }
            let records = await processor.finish()
            if !records.isEmpty { await onRecords(records) }
        }
    }

    func add(_ page: SpooledPage, side: ScanSide) { continuation.yield((page, side)) }

    /// No more pages: waits for the pipeline to catch up.
    func finish() async {
        continuation.finish()
        await task.value
    }
}
