import Foundation
import Network

/// A scanner advertising Bonjour `_scanner._tcp` (the FF-680W announces itself as "EPSON FF-680W", port 1865).
public struct DiscoveredScanner: Hashable, Sendable {
    /// The Bonjour instance name.
    public let name: String
    /// Connect to this with ``NetworkTransport/init(endpoint:timeout:pollInterval:)``; it follows the scanner
    /// to a new address after DHCP changes.
    public let endpoint: NWEndpoint
    public let txtRecord: [String: String]

    public init(name: String, endpoint: NWEndpoint, txtRecord: [String: String] = [:]) {
        self.name = name
        self.endpoint = endpoint
        self.txtRecord = txtRecord
    }

    init?(result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata { txt = record.dictionary }
        self.init(name: name, endpoint: result.endpoint, txtRecord: txt)
    }

    /// Model from the TXT record (`mdl`), such as `FF-680W`.
    public var model: String? { txtRecord["mdl"] }
    /// `scannerAvailable` from the TXT record, if present.
    public var isAvailable: Bool? { txtRecord["scannerAvailable"].map { $0 == "1" } }
    public var isEpson: Bool { name.uppercased().contains("EPSON") }
}

public enum ScannerDiscovery {
    public static let serviceType = "_scanner._tcp"

    /// The scanners currently on the network, updated as they come and go. Browsing stops when the
    /// consuming task ends or is cancelled.
    ///
    /// On iOS the first browse shows the local network permission prompt; until it is granted the list stays empty.
    public static func scanners(epsonOnly: Bool = true) -> AsyncThrowingStream<[DiscoveredScanner], Error> {
        AsyncThrowingStream { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: NWParameters())
            browser.browseResultsChangedHandler = { results, _ in
                let found = results
                    .compactMap(DiscoveredScanner.init(result:))
                    .filter { !epsonOnly || $0.isEpson }
                    .sorted { $0.name < $1.name }
                continuation.yield(found)
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: DispatchQueue(label: "PhastPhotoScanner.Discovery"))
        }
    }

    /// The first Epson scanner found, or `nil` if none appears within `timeout`.
    public static func firstScanner(timeout: Duration = .seconds(3)) async throws -> DiscoveredScanner? {
        try await withThrowingTaskGroup(of: DiscoveredScanner?.self) { group in
            group.addTask {
                for try await list in scanners() {
                    if let first = list.first { return first }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
