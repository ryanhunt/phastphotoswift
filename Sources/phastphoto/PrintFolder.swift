import Foundation
import ImageIO
import os
import PhastPhotoImaging
import PhastPhotoPipeline
import PhastPhotoProtocol
import PhastPhotoScanner
import PhastPhotoVision

/// Runs ``PrintPipeline`` over pages in scan order and saves what it keeps in one folder:
///
///     OUT/<stamp>_scan_001.jpg          picture
///     OUT/<stamp>_scan_001_back.jpg     back (both and back modes, when not blank)
///     OUT/Enhanced/<stamp>_scan_001.jpg enhanced copy (--enhance)
///     OUT/.phastphoto-duplicates.json   hash cache for the duplicate check
///
/// Pictures already in `OUT` (not its subfolders, not backs) are the duplicate candidates, so prints saved
/// earlier in the same run count. Processing errors are reported per print and never stop the run: the raw
/// scans are still on disk to process again with `phastphoto process`.
actor PrintFolder {
    struct Totals: Equatable, Sendable {
        var prints = 0
        var picturesSaved = 0
        var backsSaved = 0
        var skipped = 0
        var duplicates = 0
        var failed = 0
    }

    let directory: URL
    let mode: SideMode
    let stamp: String
    private let pipeline: PrintPipeline
    private let duplicateIndex: DuplicateIndex
    private let log: @Sendable (String) -> Void
    private var warmUp: Bool
    private var assembler: PrintAssembler
    private var number = 0
    private(set) var totals = Totals()

    static let enhancedFolder = "Enhanced"
    static let duplicateCache = ".phastphoto-duplicates.json"

    /// - Parameters:
    ///   - warmUp: run ``VisionWarmUp`` before the first print (the first Vision call at a new app path can take
    ///     about a minute on Apple silicon). Off in tests, which inject an analyzer.
    init(directory: URL, mode: SideMode, settings: PrintPipelineSettings, analyzer: any PrintAnalyzer = VisionAnalyzer(),
         stamp: String, warmUp: Bool = true, log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.directory = directory
        self.mode = mode
        self.stamp = stamp
        self.warmUp = warmUp
        self.log = log
        assembler = PrintAssembler(mode: mode)
        let index = DuplicateIndex(file: directory.appending(path: Self.duplicateCache))
        duplicateIndex = index
        pipeline = PrintPipeline(settings: settings, analyzer: analyzer, findDuplicate: { jpeg in
            try index.findDuplicate(ofJPEG: jpeg, in: PrintFolder.savedPictures(in: directory))
        })
    }

    /// Pictures saved in `directory` itself: `.jpg`, not a back.
    static func savedPictures(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "jpg" && !$0.lastPathComponent.hasSuffix("_back.jpg") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Add a side as the scanner sent it (side A not yet relabelled). Prints are processed as they complete.
    func add(_ page: ScannedPage) async {
        for item in assembler.add(page) { await process(item) }
    }

    /// The end of a stack (or of the scan): a back still waiting for its picture is processed on its own.
    func endOfStack() async {
        for item in assembler.finish() { await process(item) }
    }

    /// Process everything still pending and save the duplicate cache.
    func finish() async -> Totals {
        await endOfStack()
        if totals.prints > 0 {  // nothing processed (e.g. the scanner wasn't reached): leave no cache file behind
            do { try duplicateIndex.save() } catch { log("note: couldn't save the duplicate cache: \(error)") }
        }
        return totals
    }

    /// A print that never reached the pipeline (its raw file couldn't be read): it still takes a number, so
    /// the outputs keep lining up with the raw scans, and counts as failed.
    func recordFailure(_ reason: String) {
        number += 1
        totals.prints += 1
        totals.failed += 1
        log("print \(number): \(reason)")
    }

    private func process(_ item: AssembledPrint) async {
        if warmUp {
            warmUp = false
            log("warming up Vision (the first run at a new path can take a minute)...")
            await VisionWarmUp.run()
        }
        number += 1
        totals.prints += 1
        let label = "print \(number)"
        do {
            let result = try await pipeline.process(item)
            var parts: [String] = []
            if let back = result.back { parts.append(try save(back, number: number, what: "back")) }
            if let picture = result.picture { parts.append(try save(picture, number: number, what: "picture")) }
            if !result.backText.isEmpty { parts.append("back text: \(result.backText.replacingOccurrences(of: "\n", with: " / "))") }
            if parts.isEmpty { parts.append("nothing to save") }
            log("\(label): " + parts.joined(separator: "; "))
            for warning in result.warnings { log("\(label): warning: \(warning)") }
        } catch {
            totals.failed += 1
            log("\(label): processing failed: \(describe(error))")
        }
    }

    /// Writes a saved side (and its enhanced copy) and describes it; describes a skipped side.
    private func save(_ outcome: SideOutcome, number: Int, what: String) throws -> String {
        switch outcome {
        case .skipped(let reason):
            totals.skipped += 1
            return "\(what) skipped: \(reason.message)"
        case .saved(let side):
            let name = RawSpool.pageName(prefix: "\(stamp)_scan", number: number, side: side.side)
            let url = try write(side.jpeg, to: directory, name: name)
            var text = "\(what) \(url.lastPathComponent)"
            if side.side == .a { totals.backsSaved += 1 } else { totals.picturesSaved += 1 }
            if let enhanced = side.enhanced {
                let copy = try write(enhanced, to: directory.appending(path: Self.enhancedFolder), name: name)
                text += " + \(Self.enhancedFolder)/\(copy.lastPathComponent)"
                if !side.enhancementSteps.isEmpty { text += " (\(side.enhancementSteps.joined(separator: ", ")))" }
            }
            if side.side == .b {
                text += side.rotation.decided ? ", rotation \(side.rotation.degrees)°" : ", rotation not decided"
            }
            if let duplicate = side.duplicateOf {
                totals.duplicates += 1
                text += ", duplicate of \(duplicate.lastPathComponent)"
            }
            return text
        }
    }

    /// Writes `data` as `name` in `folder`, never over an existing file (`-2`, `-3`, ... before the extension).
    private func write(_ data: Data, to folder: URL, name: String) throws -> URL {
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

/// The scan side of `scan --process`: each page is written to the raw spool inside the scan loop (a file write,
/// milliseconds) and handed to a task that runs the pipeline, so the scanner never waits for Vision.
final class ProcessingQueue: Sendable {
    /// A page on disk with the side as the scanner sent it: the spool relabels fast mode's A as B, and the
    /// assembler wants the original.
    private enum Item: Sendable {
        case page(SpooledPage, ScanSide)
        case endOfStack
    }

    let spool: StackedSpool
    private let continuation: AsyncStream<Item>.Continuation
    private let task: Task<PrintFolder.Totals, Never>
    private let queued = OSAllocatedUnfairLock(initialState: 0)

    init(spool: StackedSpool, folder: PrintFolder) {
        self.spool = spool
        let (stream, continuation) = AsyncStream<Item>.makeStream()
        self.continuation = continuation
        task = Task {
            for await item in stream {
                switch item {
                case .page(let spooled, let side):
                    do {
                        let jpeg = try Data(contentsOf: spooled.url)  // read back: memory stays at one page
                        await folder.add(ScannedPage(index: spooled.index, side: side, width: spooled.width,
                                                     height: spooled.height, jpeg: jpeg, stats: spooled.stats,
                                                     hardwareCropped: spooled.hardwareCropped))
                    } catch {
                        await folder.recordFailure(describe(error))
                    }
                case .endOfStack:
                    await folder.endOfStack()
                }
            }
            return await folder.finish()
        }
    }

    /// Call from the scan loop: writes the page and queues it.
    func add(_ page: ScannedPage) throws -> SpooledPage {
        let spooled = try spool.write(page)
        queued.withLock { $0 += 1 }
        continuation.yield(.page(spooled, page.side))
        return spooled
    }

    /// Pages handed to the pipeline so far.
    var queuedPages: Int { queued.withLock { $0 } }

    /// A watch finished a stack: page indexes start again at 0.
    func endOfStack() {
        spool.endOfStack()
        continuation.yield(.endOfStack)
    }

    /// No more pages: waits for the pipeline to catch up.
    func finish() async -> PrintFolder.Totals {
        continuation.finish()
        return await task.value
    }
}

/// A ``RawSpool`` across the stacks of a watch. Each stack's page indexes start again at 0, so each stack's
/// numbers continue after the last print of the stack before: one stamp, and names in scan order (without
/// this, later stacks collide with the first and get `<stamp>-2_` names that sort out of order).
final class StackedSpool: Sendable {
    private struct State {
        var spool: RawSpool
        var highestIndex = -1
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ spool: RawSpool) { state = OSAllocatedUnfairLock(initialState: State(spool: spool)) }

    var stamp: String { state.withLock { $0.spool.stamp } }

    func write(_ page: ScannedPage) throws -> SpooledPage {
        try state.withLockUnchecked { state in
            let spooled = try state.spool.write(page)
            state.highestIndex = max(state.highestIndex, page.index)
            return spooled
        }
    }

    /// The next pages start a new stack, numbered after this one's.
    func endOfStack() {
        state.withLock { state in
            guard state.highestIndex >= 0 else { return }
            let s = state.spool
            state.spool = RawSpool(directory: s.directory, prefix: s.prefix, firstNumber: s.firstNumber + state.highestIndex + 1,
                                   mode: s.mode, stamp: s.stamp)
            state.highestIndex = -1
        }
    }
}

/// An error for people: the description of a Cocoa error ("The file ... couldn't be opened because you don't
/// have permission to view it.") rather than its dump.
func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
}

/// Raw scans saved by ``RawSpool`` (`<stamp>[-n]_<prefix>_<NNN>[_back].jpg`), grouped back into prints for
/// `phastphoto process`. Any other `.jpg` is a print of its own: a picture (a back in back mode).
struct RawScanFiles {
    struct Print: Equatable {
        var picture: URL?
        var back: URL?
    }

    /// Prints in order (raw scans by stamp and number, then other files by name), and files that don't fit
    /// `mode` with the reason.
    static func prints(in urls: [URL], mode: SideMode) -> (prints: [Print], ignored: [(URL, String)]) {
        var grouped: [String: Print] = [:]
        var others: [URL] = []
        var ignored: [(URL, String)] = []
        for url in urls {
            guard let parsed = parse(url.lastPathComponent) else { others.append(url); continue }
            let isBack = parsed.isBack
            if isBack ? mode.backSide == nil : mode.pictureSide == nil {
                ignored.append((url, "\(mode.rawValue) mode has no \(isBack ? "backs" : "pictures")"))
                continue
            }
            var item = grouped[parsed.key] ?? Print()
            if isBack { item.back = url } else { item.picture = url }
            grouped[parsed.key] = item
        }
        let pairs = grouped.sorted { order($0.key) < order($1.key) }.map(\.value)
        let singles = others.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            mode == .back ? Print(picture: nil, back: url) : Print(picture: url, back: nil)
        }
        return (pairs + singles, ignored)
    }

    /// Sort order of a key: stamp, then RawSpool's collision suffix as a number (none = 1, so `-2` follows the
    /// plain stamp and `-10` follows `-9`), then prefix and number. As strings `-` sorts before `_`.
    static func order(_ key: String) -> (stamp: String, attempt: Int, rest: String) {
        let stamp = key.prefix { $0 != "_" }
        let rest = key.dropFirst(stamp.count)
        let parts = stamp.split(separator: "-")
        let attempt = parts.count == 3 ? Int(parts[2]) ?? 1 : 1
        return (parts.prefix(2).joined(separator: "-"), attempt, String(rest))
    }

    /// `20261127-101500_scan_007_back.jpg` → key `20261127-101500_scan_000007`, back. The number is padded
    /// so keys sort numerically past 999.
    static func parse(_ name: String) -> (key: String, isBack: Bool)? {
        guard name.lowercased().hasSuffix(".jpg") else { return nil }
        var stem = String(name.dropLast(4))
        let isBack = stem.hasSuffix("_back")
        if isBack { stem.removeLast(5) }
        guard let underscore = stem.lastIndex(of: "_") else { return nil }
        let digits = stem[stem.index(after: underscore)...]
        let head = stem[..<underscore]
        guard digits.count >= 3, digits.allSatisfy(\.isASCII), let number = Int(digits),
              let stampEnd = head.firstIndex(of: "_"), isStamp(head[..<stampEnd]) else { return nil }
        return ("\(head)_\(String(format: "%06d", number))", isBack)
    }

    /// `yyyyMMdd-HHmmss`, optionally `-n` (``RawSpool`` adds it when a name is taken).
    static func isStamp(_ s: Substring) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        let digits = { (p: Substring, count: Int?) in !p.isEmpty && p.allSatisfy(\.isASCII) && p.allSatisfy(\.isNumber)
            && (count.map { p.count == $0 } ?? true) }
        return digits(parts[0], 8) && digits(parts[1], 6) && (parts.count == 2 || digits(parts[2], nil))
    }

    /// The `.jpg` files of `paths`: files as given, directories listed (not recursively).
    static func jpegs(at paths: [String]) throws -> [URL] {
        var out: [URL] = []
        for path in paths {
            let url = URL(filePath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw UsageError(description: "no such file or folder: \(path)")
            }
            if isDirectory.boolValue {
                out += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                   options: .skipsHiddenFiles)
                    .filter { $0.pathExtension.lowercased() == "jpg" || $0.pathExtension.lowercased() == "jpeg" }
            } else {
                out.append(url)
            }
        }
        return out
    }

    /// The pages ``PrintFolder`` takes for one print, sides as the scanner sends them in `mode`.
    /// - Parameter hardwareCropped: the raws were scanned with hardware crop (the default), so they have no
    ///   backing to crop in software.
    static func pages(of item: Print, index: Int, mode: SideMode, hardwareCropped: Bool = true) throws -> [ScannedPage] {
        var pages: [ScannedPage] = []
        if let back = item.back, let side = mode.backSide { pages.append(try page(back, index: index, side: side, hardwareCropped: hardwareCropped)) }
        if let picture = item.picture, let side = mode.pictureSide { pages.append(try page(picture, index: index, side: side, hardwareCropped: hardwareCropped)) }
        return pages
    }

    private static func page(_ url: URL, index: Int, side: ScanSide, hardwareCropped: Bool) throws -> ScannedPage {
        let data = try Data(contentsOf: url)
        var width = 0, height = 0
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        }
        return ScannedPage(index: index, side: side, width: width, height: height, jpeg: data,
                           hardwareCropped: hardwareCropped)
    }
}
