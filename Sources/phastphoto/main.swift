// phastphoto: a developer CLI for checking PhastPhotoScanner against a real scanner.
//
//   phastphoto [--host HOST] discover [--all] | info [--show-serial] | capa | status
//   phastphoto [--host HOST] health [--show-identifiers] [--community NAME]
//   phastphoto [--host HOST] scan [--dpi N] [--gray] [--quality N] [--deskew] [--double-feed 1|3] [--width IN]
//                                [--sides picture|both|back|fast] [--watch] [--out DIR] [--process PIPELINE...]
//   phastphoto process [--sides MODE] [--out DIR] [PIPELINE...] RAW...
//
// Without --host the scanner is found with Bonjour (FF-680W only). PHASTPHOTO_HOST sets a default host.
// The serial number is hidden unless --show-serial is given. `health` reads firmware, roller kit wear and
// other values over SNMP (Wi-Fi only), hiding the serial, address and MAC unless --show-identifiers. `scan --process` saves the untouched scans in
// OUT/raw and runs each print through PrintPipeline while the scan goes on; `process` does the same for raw
// scans saved earlier.

import Foundation
import PhastPhotoImaging
import PhastPhotoPipeline
import PhastPhotoProtocol
import PhastPhotoScanner

let usage = """
    usage: phastphoto [--host HOST] discover [--all] | info [--show-serial] | capa | status
           phastphoto [--host HOST] health [--show-identifiers] [--community NAME]
           phastphoto [--host HOST] scan [--dpi N] [--gray] [--quality N] [--deskew] [--double-feed 1|3]
                                         [--width INCHES] [--length INCHES] [--no-hardware-crop]
                                         [--sides picture|both|back|fast] [--watch] [--out DIR]
                                         [--process [PIPELINE OPTIONS]]
           phastphoto process [--sides picture|both|back|fast] [--out DIR] [--software-crop] [PIPELINE OPTIONS]
                              RAW-FILE-OR-FOLDER...
           (--single-sided = --sides fast, --picture-only = --sides picture; default --sides both)

    pipeline options: [--no-crop] [--keep-blank-backs] [--duplicates flag|skip|off] [--enhance] [--no-rotate]
                      [--album TEXT] [--title TEXT] [--description TEXT] [--place TEXT] [--date YYYY[-MM[-DD]]]
                      [--people "A, B"] [--tags "X, Y"]
    """

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

var arguments = Array(CommandLine.arguments.dropFirst())
/// Set when a print failed to process: the run still finishes, but exits with status 1.
var processingFailed = false

@MainActor func option(_ name: String) throws -> String? {
    guard let i = arguments.firstIndex(of: name) else { return nil }
    guard i + 1 < arguments.count else { throw UsageError(description: "\(name) needs a value") }
    defer { arguments.removeSubrange(i ... i + 1) }
    return arguments[i + 1]
}

@MainActor func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}

/// Where to connect: resolved once, then a fresh transport per session (a watch opens one per stack).
struct Target: Sendable {
    let host: String?
    let scanner: DiscoveredScanner?

    func makeTransport() -> NetworkTransport {
        if let host { return NetworkTransport(host: host) }
        return NetworkTransport(endpoint: scanner!.endpoint)
    }
}

func resolve(host: String?) async throws -> Target {
    if let host { return Target(host: host, scanner: nil) }
    guard let scanner = try await ScannerDiscovery.firstScanner() else {
        // a scanner that just woke up can take a while to advertise again: try the local /24 directly
        print("not found with Bonjour; probing the local network...")
        if let host = await SubnetProbe.scanLocalSubnet() {
            print("found a scanner by probing")
            return Target(host: host, scanner: nil)
        }
        throw UsageError(description: "no FF-680W found on the network; is it on and on the same Wi-Fi? (or pass --host)")
    }
    print("found \(scanner.name)")
    return Target(host: nil, scanner: scanner)
}

func printFields(_ fields: ESCI2Fields) {
    for key in fields.keys {
        print("\(key): " + fields[key].map { "[" + $0.map(\.description).joined(separator: ", ") + "]" }.joined(separator: " "))
    }
}

/// Pipeline settings from the command line (ffscan's defaults otherwise). The metadata is checked here, so a
/// bad `--date` fails before scanning rather than on every print.
@MainActor func pipelineSettings() throws -> PrintPipelineSettings {
    var settings = PrintPipelineSettings()
    if flag("--no-crop") { settings.crop = false }
    if flag("--keep-blank-backs") { settings.skipBlankBacks = false }
    if flag("--enhance") { settings.enhancement = EnhancementOptions() }
    if flag("--no-rotate") { settings.autoRotate = false }
    if let duplicates = try option("--duplicates") {
        guard let parsed = DuplicateMode(rawValue: duplicates) else {
            throw UsageError(description: "--duplicates takes flag, skip or off")
        }
        settings.duplicates = parsed
    }
    var md = PhotoMetadata()
    if let v = try option("--album") { md.album = v }
    if let v = try option("--title") { md.title = v }
    if let v = try option("--description") { md.description = v }
    if let v = try option("--place") { md.place = v }
    if let v = try option("--date") { md.date = v }
    if let v = try option("--people") { md.people = PhotoMetadata.list(fromCommaSeparated: v) }
    if let v = try option("--tags") { md.tags = PhotoMetadata.list(fromCommaSeparated: v) }
    do {
        _ = try PhotoMetadata.write(md, to: RGBImage(width: 1, height: 1, fill: RGB(0, 0, 0)).jpegData())
    } catch PhotoMetadataError.invalidDate(let date) {
        throw UsageError(description: "--date takes YYYY, YYYY-MM or YYYY-MM-DD, not \(date)")
    }
    settings.metadata = md
    return settings
}

@MainActor func sideMode(default mode: SideMode) throws -> SideMode {
    var mode = mode
    if flag("--single-sided") { mode = .fast }
    if flag("--picture-only") { mode = .picture }
    if let sides = try option("--sides") {
        guard let parsed = SideMode(rawValue: sides) else { throw UsageError(description: "--sides takes picture, both, back or fast") }
        mode = parsed
    }
    return mode
}

/// "1 print", "2 prints".
func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

func summary(_ totals: PrintFolder.Totals) -> String {
    var line = "\(count(totals.prints, "print")): \(count(totals.picturesSaved, "picture")) and "
        + "\(count(totals.backsSaved, "back")) saved, \(count(totals.skipped, "side")) skipped"
    if totals.duplicates > 0 { line += ", \(count(totals.duplicates, "duplicate")) flagged" }
    if totals.failed > 0 { line += ", \(totals.failed) failed" }
    return line
}

func describe(_ page: SpooledPage) -> String {
    String(format: "saved %@  side %@ %dx%d  %.1f MB  ", page.name, page.side.rawValue, page.width, page.height,
           Double(page.byteCount) / 1e6) + page.stats.summaryLine
}

@MainActor func run() async throws {
    let host = try option("--host") ?? ProcessInfo.processInfo.environment["PHASTPHOTO_HOST"]
    guard let command = arguments.first else { throw UsageError(description: usage) }
    arguments.removeFirst()

    switch command {
    case "discover":
        let all = flag("--all")
        print("browsing \(ScannerDiscovery.serviceType) for 3 s\(all ? " (all models)" : " (FF-680W only)")...")
        let found = try await withThrowingTaskGroup(of: [DiscoveredScanner].self) { group in
            group.addTask {
                var latest: [DiscoveredScanner] = []
                for try await list in ScannerDiscovery.scanners(filter: all ? .all : .ff680w) { latest = list }
                return latest
            }
            group.addTask { try await Task.sleep(for: .seconds(3)); return [] }
            _ = try await group.next()
            group.cancelAll()
            return try await group.next() ?? []
        }
        if found.isEmpty { print("none found") }
        for scanner in found {
            print("\(scanner.name)  model=\(scanner.model ?? "?")  available=\(scanner.isAvailable.map(String.init) ?? "?")")
        }

    case "health":
        let showIdentifiers = flag("--show-identifiers")
        let community = try option("--community") ?? "public"
        let target = try await resolve(host: host)
        let reader = if let host = target.host {
            ScannerHealthReader(host: host, community: community)
        } else {
            ScannerHealthReader(scanner: target.scanner!, community: community)
        }
        let health: ScannerHealth
        do {
            health = try await reader.read()
        } catch ScannerError.timedOut {
            throw UsageError(description: "the scanner didn't answer SNMP: is it awake, and is SNMP on in its Web Config?")
        }
        if health.isEmpty { print("the scanner answered SNMP but reported nothing this tool reads") }
        for (key, value) in health.displayFields(showIdentifiers: showIdentifiers) { print("\(key): \(value)") }

    case "info", "capa", "status":
        let showSerial = flag("--show-serial")
        let target = try await resolve(host: host)
        try await ScannerSession.withSession(transport: target.makeTransport()) { session in
            switch command {
            case "info":
                for (key, value) in try await session.info().displayFields(showSerial: showSerial) { print("\(key): \(value)") }
            case "capa": printFields(try await session.capabilities())
            default:
                let status = try await session.status()
                print("\(status): \(status.friendlyMessage)")
            }
        }

    case "scan":
        var settings = ScanSettings()
        if let dpi = try option("--dpi") { settings.resolution = Int(dpi) ?? -1 }
        if let quality = try option("--quality") { settings.jpegQuality = Int(quality) ?? -1 }
        if let width = try option("--width") {
            guard let inches = Double(width) else { throw UsageError(description: "--width needs a number of inches") }
            settings.widthInches = inches
        }
        if let length = try option("--length") {
            guard let inches = Double(length) else { throw UsageError(description: "--length needs a number of inches") }
            settings.maximumLengthInches = inches
        }
        if let feed = try option("--double-feed") {
            switch feed {
            case "1": settings.doubleFeedDetection = .level1
            case "3": settings.doubleFeedDetection = .level3
            default: throw UsageError(description: "--double-feed takes 1 or 3")
            }
        }
        if flag("--gray") { settings.colorMode = .gray }
        if flag("--deskew") { settings.hardwareDeskew = true }
        if flag("--no-hardware-crop") { settings.hardwareCrop = false }
        let mode = try sideMode(default: .both)
        settings = settings.with(sideMode: mode)
        let watch = flag("--watch")
        let out = URL(filePath: try option("--out") ?? "scans", directoryHint: .isDirectory)
        let process = flag("--process")
        let pipelineOptions = try pipelineSettings()
        guard process || pipelineOptions == PrintPipelineSettings() else {
            throw UsageError(description: "pipeline options need --process")
        }
        let processing = process ? pipelineOptions : nil
        try settings.validate()

        let target = try await resolve(host: host)
        let spool = StackedSpool(RawSpool(directory: processing == nil ? out : out.appending(path: "raw"), mode: mode))
        let finalSettings = settings
        let finalMode = mode

        // With --process, every side goes to OUT/raw (picture mode's backs too: their writing is read) and a
        // separate task runs the pipeline, so the scan loop only ever writes a file.
        let queue = processing.map { pipelineSettings in
            ProcessingQueue(spool: spool, folder: PrintFolder(directory: out, mode: mode, settings: pipelineSettings,
                                                              stamp: spool.stamp))
        }

        @Sendable func handle(_ page: ScannedPage) throws {
            if let queue {
                print(describe(try queue.add(page)))
            } else {
                guard finalMode.keeps(finalMode.relabelled(page.side)) else { return }
                print(describe(try spool.write(page)))
            }
        }

        /// Waits for the pipeline to catch up after the scan (or watch) ends, however it ended.
        func finishProcessing() async {
            guard let queue else { return }
            if queue.queuedPages > 0 { print("processing the remaining prints...") }
            let totals = await queue.finish()
            guard totals.prints > 0 else { return }
            print(summary(totals))
            if totals.failed > 0 {
                print("\(count(totals.failed, "print")) failed; the raw scans are in \(out.appending(path: "raw").path)")
                processingFailed = true
            }
        }

        if watch {
            let task = Task {
                try await ScannerWatch(settings: finalSettings, makeTransport: { target.makeTransport() }).run { event in
                    switch event {
                    case .waiting(let message): print("waiting for photos... (\(message))")
                    case .unreachable(let message): print("scanner not reachable: \(message)")
                    case .stackStarted: print("scanning a stack")
                    case .page(let page): try handle(page)
                    case .stackFinished(let summary):
                        print("\(summary.pageCount) sides scanned")
                        if let queue { queue.endOfStack() } else { spool.endOfStack() }
                    }
                }
            }
            signal(SIGINT, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            interrupt.setEventHandler { task.cancel() }  // hard cancel: sends CAN, then FIN
            interrupt.resume()
            let result = await task.result
            interrupt.cancel()
            signal(SIGINT, SIG_DFL)  // a second Ctrl-C while the pipeline catches up quits at once
            print("stopped")
            await finishProcessing()
            try result.get()
        } else {
            let summary: ScanSummary
            do {
                summary = try await ScannerSession.withSession(transport: target.makeTransport()) { session in
                    try await session.scan(finalSettings) { try handle($0) }
                }
            } catch {
                await finishProcessing()  // the sides scanned before the error are still processed
                throw error
            }
            if !summary.blockSizeAccepted { print("note: the scanner rejected #BSZ; scanned with 64 KB blocks") }
            print("\(summary.pageCount) sides scanned")
            await finishProcessing()
        }

    case "process":
        let mode = try sideMode(default: .both)
        // Raws from scans with hardware crop (the default) are already cut to the paper. Older raws, or scans with
        // --no-hardware-crop, still have the backing: crop those in software.
        let softwareCrop = flag("--software-crop")
        let out = URL(filePath: try option("--out") ?? "processed", directoryHint: .isDirectory)
        let settings = try pipelineSettings()
        if let unknown = arguments.first(where: { $0.hasPrefix("--") }) {
            throw UsageError(description: "unknown option \(unknown)\n\(usage)")
        }
        guard !arguments.isEmpty else { throw UsageError(description: "process needs raw scans (files or folders)\n\(usage)") }
        let (prints, ignored) = RawScanFiles.prints(in: try RawScanFiles.jpegs(at: arguments), mode: mode)
        arguments.removeAll()
        for (url, reason) in ignored { print("ignored \(url.lastPathComponent): \(reason)") }
        guard !prints.isEmpty else { throw UsageError(description: "no raw scans to process") }
        print("processing \(count(prints.count, "print")) (\(mode.rawValue) mode) into \(out.path)")
        let folder = PrintFolder(directory: out, mode: mode, settings: settings, stamp: RawSpool(directory: out).stamp)
        for (index, item) in prints.enumerated() {
            do {
                for page in try RawScanFiles.pages(of: item, index: index, mode: mode, hardwareCropped: !softwareCrop) {
                    await folder.add(page)
                }
            } catch {
                await folder.recordFailure(describe(error))
            }
            await folder.endOfStack()
        }
        let totals = await folder.finish()
        print(summary(totals))
        if totals.failed > 0 { processingFailed = true }

    default:
        throw UsageError(description: usage)
    }
    if !arguments.isEmpty { print("ignored: \(arguments.joined(separator: " "))") }
}

do {
    try await run()
    if processingFailed { exit(1) }
} catch {
    FileHandle.standardError.write(Data("error: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))\n".utf8))
    exit(1)
}
