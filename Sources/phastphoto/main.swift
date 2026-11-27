// phastphoto: a developer CLI for checking PhastPhotoScanner against a real scanner.
//
//   phastphoto [--host HOST] discover | info | capa | status
//   phastphoto [--host HOST] scan [--dpi N] [--gray] [--single-sided] [--quality N] [--picture-only] [--out DIR]
//
// Without --host the scanner is found with Bonjour. PHASTPHOTO_HOST sets a default host.

import Foundation
import PhastPhotoProtocol
import PhastPhotoScanner

let usage = """
    usage: phastphoto [--host HOST] discover | info | capa | status
           phastphoto [--host HOST] scan [--dpi N] [--gray] [--single-sided] [--quality N]
                                         [--picture-only] [--out DIR]
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

func transport(host: String?) async throws -> NetworkTransport {
    if let host { return NetworkTransport(host: host) }
    guard let scanner = try await ScannerDiscovery.firstScanner() else {
        throw UsageError(description: "no Epson scanner found on the network; is it on and on the same Wi-Fi? (or pass --host)")
    }
    print("found \(scanner.name)")
    return NetworkTransport(endpoint: scanner.endpoint)
}

func printFields(_ fields: ESCI2Fields) {
    for key in fields.keys {
        print("\(key): " + fields[key].map { "[" + $0.map(\.description).joined(separator: ", ") + "]" }.joined(separator: " "))
    }
}

@MainActor func run() async throws {
    let host = try option("--host") ?? ProcessInfo.processInfo.environment["PHASTPHOTO_HOST"]
    guard let command = arguments.first else { throw UsageError(description: usage) }
    arguments.removeFirst()

    switch command {
    case "discover":
        print("browsing \(ScannerDiscovery.serviceType) for 3 s...")
        let found = try await withThrowingTaskGroup(of: [DiscoveredScanner].self) { group in
            group.addTask {
                var latest: [DiscoveredScanner] = []
                for try await list in ScannerDiscovery.scanners(epsonOnly: false) { latest = list }
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
        try await ScannerSession.withSession(transport: transport(host: host)) { session in
            switch command {
            case "info": printFields(try await session.info().fields)
            case "capa": printFields(try await session.capabilities())
            default: print(try await session.status())
            }
        }

    case "scan":
        var settings = ScanSettings()
        if let dpi = try option("--dpi") { settings.resolution = Int(dpi) ?? -1 }
        if let quality = try option("--quality") { settings.jpegQuality = Int(quality) ?? -1 }
        if flag("--gray") { settings.colorMode = .gray }
        if flag("--single-sided") { settings.duplex = false }
        let pictureOnly = flag("--picture-only")
        let out = URL(filePath: try option("--out") ?? "scans", directoryHint: .isDirectory)
        try settings.validate()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // face-up duplex: B is the picture; single-sided (prints face down): A is
        let pictureSide: ScannedPage.Side = settings.duplex ? .b : .a
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let summary = try await ScannerSession.withSession(transport: transport(host: host)) { session in
            try await session.scan(settings) { page in
                if pictureOnly, page.side != pictureSide { return }
                let name = String(format: "%@_%02d%@.jpg", stamp, page.index, page.side.rawValue)
                try page.jpeg.write(to: out.appending(path: name))
                let speed = page.stats.bytesPerSecond.map { String(format: "  %.1f MB/s", $0 / 1e6) } ?? ""
                print("saved \(name)  \(page.width)x\(page.height)\(speed)")
            }
        }
        if !summary.blockSizeAccepted { print("note: the scanner rejected #BSZ; scanned with 64 KB blocks") }
        print("\(summary.pageCount) sides scanned")

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
