// phastphoto: a developer CLI for checking PhastPhotoScanner against a real scanner.
//
//   phastphoto [--host HOST] discover [--all] | info [--show-serial] | capa | status
//   phastphoto [--host HOST] scan [--dpi N] [--gray] [--quality N] [--deskew] [--double-feed 1|3] [--width IN]
//                                [--sides picture|both|back|fast] [--watch] [--out DIR]
//
// Without --host the scanner is found with Bonjour (FF-680W only). PHASTPHOTO_HOST sets a default host.
// The serial number is hidden unless --show-serial is given.

import Foundation
import PhastPhotoProtocol
import PhastPhotoScanner

let usage = """
    usage: phastphoto [--host HOST] discover [--all] | info [--show-serial] | capa | status
           phastphoto [--host HOST] scan [--dpi N] [--gray] [--quality N] [--deskew] [--double-feed 1|3]
                                         [--width INCHES] [--sides picture|both|back|fast] [--watch] [--out DIR]
           (--single-sided = --sides fast, --picture-only = --sides picture; default --sides both)
    """

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

var arguments = Array(CommandLine.arguments.dropFirst())

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
        if let feed = try option("--double-feed") {
            switch feed {
            case "1": settings.doubleFeedDetection = .level1
            case "3": settings.doubleFeedDetection = .level3
            default: throw UsageError(description: "--double-feed takes 1 or 3")
            }
        }
        if flag("--gray") { settings.colorMode = .gray }
        if flag("--deskew") { settings.hardwareDeskew = true }
        var mode = SideMode.both
        if flag("--single-sided") { mode = .fast }
        if flag("--picture-only") { mode = .picture }
        if let sides = try option("--sides") {
            guard let parsed = SideMode(rawValue: sides) else { throw UsageError(description: "--sides takes picture, both, back or fast") }
            mode = parsed
        }
        settings = settings.with(sideMode: mode)
        let watch = flag("--watch")
        let out = URL(filePath: try option("--out") ?? "scans", directoryHint: .isDirectory)
        try settings.validate()

        let target = try await resolve(host: host)
        let spool = RawSpool(directory: out, mode: mode)
        let finalSettings = settings
        let finalMode = mode

        @Sendable func handle(_ page: ScannedPage) throws {
            guard finalMode.keeps(finalMode.relabelled(page.side)) else { return }
            print(describe(try spool.write(page)))
        }

        if watch {
            let task = Task {
                try await ScannerWatch(settings: finalSettings, makeTransport: { target.makeTransport() }).run { event in
                    switch event {
                    case .waiting(let message): print("waiting for photos... (\(message))")
                    case .unreachable(let message): print("scanner not reachable: \(message)")
                    case .stackStarted: print("scanning a stack")
                    case .page(let page): try handle(page)
                    case .stackFinished(let summary): print("\(summary.pageCount) sides scanned")
                    }
                }
            }
            signal(SIGINT, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            interrupt.setEventHandler { task.cancel() }  // hard cancel: sends CAN, then FIN
            interrupt.resume()
            try await task.value
            print("stopped")
        } else {
            let summary = try await ScannerSession.withSession(transport: target.makeTransport()) { session in
                try await session.scan(finalSettings) { try handle($0) }
            }
            if !summary.blockSizeAccepted { print("note: the scanner rejected #BSZ; scanned with 64 KB blocks") }
            print("\(summary.pageCount) sides scanned")
        }

    default:
        throw UsageError(description: usage)
    }
    if !arguments.isEmpty { print("ignored: \(arguments.joined(separator: " "))") }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))\n".utf8))
    exit(1)
}
