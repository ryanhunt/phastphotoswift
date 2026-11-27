import Foundation
import Observation
import os
import PhastPhotoImaging
import PhastPhotoPipeline
import PhastPhotoProtocol
import PhastPhotoScanner
import PhastPhotoVision
import UIKit

struct LogLine: Identifiable, Sendable {
    let id = UUID()
    let time: Date
    let text: String
}

struct InfoField: Identifiable, Sendable {
    let id = UUID()
    let key: String
    let value: String
}

/// Everything the harness does, on the main actor. Scanner and pipeline work runs in tasks and reports back
/// here; the views only read state and call these methods.
@MainActor @Observable
final class HarnessModel {
    enum DiscoveryState: Equatable {
        case idle, browsing, stopped
        /// `DiscoveryError.localNetworkDenied`: the user refused the prompt, or turned access off later.
        case denied
        case waiting(String)
        case failed(String)
    }

    // Discovery
    var discovery: DiscoveryState = .idle
    var scanners: [DiscoveredScanner] = []
    var selected: DiscoveredScanner?
    /// Skips Bonjour: an IP address or host name typed by hand.
    var manualHost = ""
    var allModels = false

    // Scanner queries
    var infoFields: [InfoField] = []
    var statusText: String?
    var queryRunning: String?

    // Scan and pipeline settings
    var dpi = 300
    var sideMode: SideMode = .both
    var album = ""
    var enhance = false
    var autoRotate = true

    // Progress
    private(set) var isScanning = false
    private(set) var isProcessing = false
    private(set) var scanProgress: String?
    private(set) var records: [PrintRecord] = []
    private(set) var logLines: [LogLine] = []

    private var browseTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var activeSession: ScannerSession?
    private var sampleSeed = 0
    private let logger = Logger(subsystem: "PhastPhotoHarness", category: "harness")

    static let resolutions = [300, 600] + ScanSettings.supportedResolutions.filter { $0 != 300 && $0 != 600 }

    #if DEBUG
    static let buildConfiguration = "Debug"
    #else
    static let buildConfiguration = "Release"
    #endif

    init() {
        log("launched: \(Self.deviceDescription), \(Self.buildConfiguration) build")
        if Self.buildConfiguration == "Debug" {
            log("note: Debug builds run the imaging loops about 200 times slower; measure with Release")
        }
    }

    /// Hardware model, OS and memory; no device name.
    static var deviceDescription: String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var text = "\(machine), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion), "
            + String(format: "%.0f GB RAM", ram)
        let available = MemoryMeter.available()
        if available > 0 { text += ", \(MemoryMeter.megabytes(available)) available to the app" }
        return text
    }

    var isBusy: Bool { isScanning || isProcessing || queryRunning != nil }

    // MARK: - Log

    func log(_ text: String) {
        let line = LogLine(time: Date(), text: text)
        logLines.append(line)
        if logLines.count > 1000 { logLines.removeFirst(logLines.count - 1000) }
        logger.notice("\(text, privacy: .public)")
        Storage.append("\(line.time.formatted(.iso8601)) \(text)", to: Storage.logFile)
    }

    // MARK: - Discovery

    func startBrowsing() {
        browseTask?.cancel()
        scanners = []
        discovery = .browsing
        let filter: ScannerDiscovery.ModelFilter = allModels ? .all : .ff680w
        log("browsing \(ScannerDiscovery.serviceType) (\(allModels ? "all models" : "FF-680W only"))")
        browseTask = Task {
            do {
                for try await list in ScannerDiscovery.scanners(filter: filter) {
                    scanners = list
                    if let current = selected, list.contains(current) {} else { selected = list.first }
                    log(list.isEmpty ? "no scanners listed" : "found: " + list.map(\.name).joined(separator: ", "))
                }
            } catch DiscoveryError.localNetworkDenied {
                discovery = .denied
                log("discovery: local network access denied (DiscoveryError.localNetworkDenied)")
                return
            } catch let error as DiscoveryError {
                switch error {
                case .waiting(let reason): discovery = .waiting(reason)
                default: discovery = .failed(error.localizedDescription)
                }
                log("discovery: \(error.localizedDescription)")
                return
            } catch {
                discovery = .failed("\(error)")
                log("discovery failed: \(error)")
                return
            }
            if discovery == .browsing { discovery = .stopped }
        }
    }

    func stopBrowsing() {
        browseTask?.cancel()
        browseTask = nil
        if discovery == .browsing { discovery = .stopped }
        log("stopped browsing")
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private struct NoTarget: LocalizedError {
        var errorDescription: String? { "Find a scanner first, or type its address." }
    }

    private func makeTransport() throws -> NetworkTransport {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty { return NetworkTransport(host: host) }
        guard let selected else { throw NoTarget() }
        return NetworkTransport(endpoint: selected.endpoint)
    }

    private var targetName: String {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? (selected?.name ?? "?") : host
    }

    // MARK: - Info and status

    func readInfo() {
        query("info") { session in
            let info = try await session.info()
            self.infoFields = info.displayFields(showSerial: false).map { InfoField(key: $0.key, value: $0.value) }
            self.log("info: \(info.productName ?? "?"), firmware \(info.firmwareVersion ?? "?"), "
                + "optical \(info.opticalResolution.map { "\($0) dpi" } ?? "?")")
        }
    }

    func readStatus() {
        query("status") { session in
            let status = try await session.status()
            self.statusText = "\(status.friendlyMessage) (\(status))"
            self.log("status: \(status.friendlyMessage) (\(status))")
        }
    }

    private func query(_ name: String, _ body: @escaping (ScannerSession) async throws -> Void) {
        guard !isBusy else { return }
        let transport: NetworkTransport
        do { transport = try makeTransport() } catch { log("\(name): \(error.localizedDescription)"); return }
        queryRunning = name
        log("\(name): connecting to \(targetName)")
        Task {
            let clock = ContinuousClock(), start = clock.now
            do {
                try await ScannerSession.withSession(transport: transport) { try await body($0) }
                log("\(name): done in \(Self.seconds(start.duration(to: clock.now)))")
            } catch {
                if name == "status" { statusText = Self.describe(error) }
                log("\(name) failed: \(Self.describe(error))")
            }
            queryRunning = nil
        }
    }

    // MARK: - Scan

    private var pipelineSettings: PrintPipelineSettings {
        var settings = PrintPipelineSettings()
        settings.autoRotate = autoRotate
        if enhance { settings.enhancement = EnhancementOptions() }
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !album.isEmpty { settings.metadata = PhotoMetadata(album: album) }
        return settings
    }

    /// A scan of the loaded stack with ffscan's defaults (deskew, double-feed level 1) at the chosen
    /// resolution and side mode. Each side is written to Documents/Raw/<stamp> inside the scan loop and
    /// processed on another task.
    func startScan() {
        guard !isBusy else { return }
        let transport: NetworkTransport
        do { transport = try makeTransport() } catch { log("scan: \(error.localizedDescription)"); return }
        let mode = sideMode, dpi = dpi
        let settings: ScanSettings = {
            var s = ScanSettings.photoDefaults
            s.resolution = dpi
            return s.with(sideMode: mode)
        }()
        let stamp = Storage.stamp()
        let run = "scan \(stamp), \(dpi) dpi, \(mode.rawValue)"
        let spool = RawSpool(directory: Storage.raw(stamp), mode: mode, stamp: stamp)
        let processor = PrintProcessor(output: Storage.processed, mode: mode, settings: pipelineSettings, stamp: stamp,
                                       label: "scan", run: run, dpi: dpi)
        let queue = ProcessingQueue(processor: processor) { records in await self.received(records) }
        isScanning = true
        isProcessing = true
        scanProgress = "connecting to \(targetName)"
        updateIdleTimer()
        log("\(run): connecting to \(targetName)")

        scanTask = Task {
            let clock = ContinuousClock(), start = clock.now
            let lastPage = OSAllocatedUnfairLock(initialState: start)
            var pages = 0
            do {
                let summary = try await ScannerSession.withSession(transport: transport) { session in
                    self.activeSession = session
                    self.scanProgress = "scanning"
                    return try await session.scan(settings) { page in
                        let spooled = try spool.write(page)
                        queue.add(spooled, side: page.side)
                        let now = clock.now
                        let gap = lastPage.withLock { last in defer { last = now }; return last.duration(to: now) }
                        await self.pageArrived(spooled, gap: gap)
                    }
                }
                pages = summary.pageCount
                log("\(summary.pageCount) sides scanned in \(Self.seconds(start.duration(to: clock.now)))"
                    + (summary.stoppedEarly ? " (stopped after the current print)" : ""))
            } catch {
                log("scan failed: \(Self.describe(error))")
            }
            activeSession = nil
            isScanning = false
            scanProgress = "processing the remaining prints"
            await queue.finish()
            let total = Self.seconds(start.duration(to: clock.now))
            log("\(run): finished in \(total)\(pages > 0 ? ", raw scans in Documents/Raw/\(stamp)" : "")")
            scanProgress = nil
            isProcessing = false
            scanTask = nil
            updateIdleTimer()
        }
    }

    private func pageArrived(_ page: SpooledPage, gap: Duration) {
        scanProgress = "received \(page.name)"
        log(String(format: "page %@ side %@ %d×%d %.1f MB, %@ after the previous; ", page.name, page.side.rawValue,
                   page.width, page.height, Double(page.byteCount) / 1e6, Self.seconds(gap)) + page.stats.summaryLine)
    }

    /// Finishes the print that is feeding, then stops (no jam).
    func stopAfterCurrentPrint() {
        guard let session = activeSession else { return }
        log("stopping after the current print")
        Task { await session.stopAfterCurrentPrint() }
    }

    /// Hard cancel (`CAN `): can jam the scanner mid-page. Here for roadmap 1.1's cancel check.
    func cancelScan() {
        log("cancelling the scan (hard cancel)")
        if let session = activeSession { Task { await session.cancelScan() } } else { scanTask?.cancel() }
    }

    private func received(_ new: [PrintRecord]) {
        for record in new {
            records.insert(record, at: 0)
            log("\(record.label): \(record.summary); \(record.timing)")
            if !record.backText.isEmpty {
                log("\(record.label): back text: \(record.backText.replacingOccurrences(of: "\n", with: " / "))")
            }
            for warning in record.warnings { log("\(record.label): warning: \(warning)") }
            let fields = [Date().formatted(.iso8601), record.label, record.run, "\(record.dpi)", record.scanSize,
                          String(format: "%.3f", record.seconds), String(record.startBytes / 1_048_576),
                          String(record.peakBytes / 1_048_576), String(MemoryMeter.lifetimePeak() / 1_048_576),
                          Self.buildConfiguration, record.summary]
            Storage.append(fields.map(Self.csvField).joined(separator: ","), to: Storage.timingsFile,
                           header: "time,print,run,dpi,scan_size,seconds,start_mb,peak_mb,app_peak_mb,build,result")
        }
    }

    private func updateIdleTimer() {
        // Keep the screen on while the scanner is in use: a locked device suspends the app, and a scan that
        // stops polling mid-page jams the scanner.
        UIApplication.shared.isIdleTimerDisabled = isScanning || isProcessing
    }

    // MARK: - Samples

    /// Runs the pipeline on a synthetic print (picture and back, both mode) at the chosen resolution, through
    /// the same spool and queue as a scan. `again` repeats the previous picture, which should be flagged as a
    /// duplicate.
    func processSample(again: Bool = false) {
        guard !isBusy else { return }
        let repeated = again && sampleSeed > 0
        if !repeated { sampleSeed += 1 }
        let seed = sampleSeed, dpi = dpi
        let stamp = Storage.stamp()
        let run = "sample \(seed)\(repeated ? " again" : ""), \(dpi) dpi, both"
        isProcessing = true
        scanProgress = "drawing sample \(seed) at \(dpi) dpi"
        updateIdleTimer()
        let settings = pipelineSettings
        Task {
            let clock = ContinuousClock(), start = clock.now
            let (picture, back) = await Task.detached(priority: .userInitiated) {
                SampleScans.pair(dpi: dpi, seed: seed)
            }.value
            log("\(run): drawn in \(Self.seconds(start.duration(to: clock.now))) "
                + String(format: "(%.1f + %.1f MB JPEG)", Double(picture.count) / 1e6, Double(back.count) / 1e6))
            scanProgress = "processing sample \(seed)"
            let spool = RawSpool(directory: Storage.raw("sample-\(stamp)"), mode: .both, stamp: stamp)
            let processor = PrintProcessor(output: Storage.samples, mode: .both, settings: settings, stamp: stamp,
                                           label: "sample", run: run, dpi: dpi, firstNumber: seed)
            let queue = ProcessingQueue(processor: processor) { records in await self.received(records) }
            let width = Int(8.5 * Double(dpi)), height = Int(4.8 * Double(dpi))
            do {
                for (side, jpeg) in [(ScanSide.a, back), (ScanSide.b, picture)] {  // the scanner sends A first
                    let page = ScannedPage(index: 0, side: side, width: width, height: height, jpeg: jpeg)
                    queue.add(try spool.write(page), side: side)
                }
            } catch {
                log("sample: couldn't write the raw files: \(error.localizedDescription)")
            }
            await queue.finish()
            scanProgress = nil
            isProcessing = false
            updateIdleTimer()
        }
    }

    /// Times `VisionWarmUp`: the first Vision call after install or reboot.
    func warmUpVision() {
        guard !isBusy else { return }
        isProcessing = true
        scanProgress = "warming up Vision"
        Task {
            let clock = ContinuousClock(), start = clock.now
            await VisionWarmUp.run()
            log("Vision warm-up took \(Self.seconds(start.duration(to: clock.now)))")
            scanProgress = nil
            isProcessing = false
        }
    }

    // MARK: - Files

    func deleteAllFiles() {
        guard !isBusy else { return }
        do {
            try Storage.deleteAll()
            records = []
            logLines = []
            log("deleted everything in Documents")
        } catch {
            log("couldn't delete files: \(error.localizedDescription)")
        }
    }

    // MARK: - Formatting

    static func seconds(_ duration: Duration) -> String {
        String(format: "%.2f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func csvField(_ text: String) -> String {
        text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
            ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }
}
