import Foundation
import os
import PhastPhotoProtocol
import PhastPhotoScanner

/// Runs the checks and logs each step to the screen, to Documents/usb-log.txt (fetch it with
/// `devicectl device copy from --domain-type appDataContainer`) and to the unified log at notice level.
@MainActor
final class USBCheck: ObservableObject {
    enum Check: String { case presence, info, scan, duplex }

    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false

    /// The driver embedded in this app: its bundle ID is the app's plus ".Driver".
    let driverBundleID = (Bundle.main.bundleIdentifier ?? "app") + ".Driver"
    private let logger = Logger(subsystem: "PhastPhotoUSBHost", category: "check")
    private let logFile = URL.documentsDirectory.appending(path: "usb-log.txt")

    /// `--autorun presence|info|scan` runs a check at launch, for driving the app with devicectl.
    func autorun() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "--autorun"), i + 1 < arguments.count,
              let check = Check(rawValue: arguments[i + 1]) else { return }
        run(check)
    }

    func run(_ check: Check) {
        guard !running else { return }
        running = true
        Task {
            log("== \(check.rawValue) (\(Date().formatted(date: .omitted, time: .standard)))")
            do {
                switch check {
                case .presence: presence()
                case .info: try await info()
                case .scan: try await scan(mode: .fast)
                case .duplex: try await scan(mode: .both)
                }
            } catch {
                log("failed: \(error.localizedDescription) [\(error)]")
            }
            log("== done")
            running = false
        }
    }

    private func presence() {
        log("driver \(driverBundleID): \(USBTransport.isScannerPresent(driverBundleID: driverBundleID) ? "running" : "not found")")
        log("any PhastPhoto driver: \(USBTransport.isScannerPresent() ? "running" : "not found")")
    }

    private func info() async throws {
        let start = ContinuousClock.now
        try await ScannerSession.withSession(transport: USBTransport(driverBundleID: driverBundleID)) { session in
            let info = try await session.info()
            // displayFields hides the serial number
            for (key, value) in info.displayFields() { self.log("INFO \(key): \(value)") }
            let status = try await session.status()
            self.log("STATUS: \(status) (\(status.friendlyMessage))")
        }
        log("session took \(ContinuousClock.now - start)")
    }

    /// `.fast`: single-sided, prints face down. `.both`: duplex, prints face up, both sides kept.
    private func scan(mode: SideMode) async throws {
        let folder = URL.documentsDirectory.appending(path: "raw")
        let spool = RawSpool(directory: folder, mode: mode)
        let start = ContinuousClock.now
        let summary = try await ScannerSession.withSession(transport: USBTransport(driverBundleID: driverBundleID)) { session in
            let status = try await session.status()
            self.log("STATUS: \(status) (\(status.friendlyMessage))")
            return try await session.scan(ScanSettings.photoDefaults.with(sideMode: mode)) { page in
                let saved = try spool.write(page)
                let inches = Double(saved.height) / 300
                await self.log("page \(saved.index) side \(page.side.rawValue) \(saved.name): \(saved.width)x\(saved.height) "
                    + "(\(String(format: "%.1f", inches)) in), \(saved.byteCount) bytes; \(saved.stats.summaryLine)")
            }
        }
        log("\(summary.pageCount) sides in \(ContinuousClock.now - start); #BSZ accepted: \(summary.blockSizeAccepted)")
    }

    private func log(_ line: String) {
        lines.append(line)
        logger.notice("\(line, privacy: .public)")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logFile)
        }
    }
}
