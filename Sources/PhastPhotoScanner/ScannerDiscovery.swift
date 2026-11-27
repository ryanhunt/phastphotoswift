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

/// Why browsing could not start or continue.
public enum DiscoveryError: Error, Sendable, LocalizedError {
    /// The user refused (or the system blocks) local network access: browsing sits in `NWBrowser`'s
    /// `.waiting` state with a "policy denied" DNS error. On iOS: Settings > the app > Local Network. Needs
    /// `NSLocalNetworkUsageDescription` and `_scanner._tcp` under `NSBonjourServices` in Info.plist.
    case localNetworkDenied
    /// Browsing is waiting for something else, such as Wi-Fi being off.
    case waiting(String)
    case failed(String)

    /// `kDNSServiceErr_PolicyDenied`
    static let policyDeniedCode: Int32 = -65570

    /// The error for a `.waiting` or `.failed` browser state.
    static func make(from error: NWError, waiting: Bool) -> DiscoveryError {
        if case .dns(let code) = error, code == policyDeniedCode { return .localNetworkDenied }
        return waiting ? .waiting(String(describing: error)) : .failed(String(describing: error))
    }

    public var errorDescription: String? {
        switch self {
        case .localNetworkDenied:
            "Local network access is turned off for this app, so scanners can't be found. Allow it in Settings > Privacy & Security > Local Network."
        case .waiting(let reason): "Can't browse for scanners yet (is Wi-Fi on?): \(reason)."
        case .failed(let reason): "Browsing for scanners failed: \(reason)."
        }
    }
}

public enum ScannerDiscovery {
    public static let serviceType = "_scanner._tcp"
    /// The TXT `mdl` value of the FF-680W.
    public static let supportedModel = "FF-680W"

    /// Which advertised scanners to list.
    public enum ModelFilter: Hashable, Sendable {
        /// TXT `mdl == "FF-680W"` (the default): the only model this package drives.
        case ff680w
        /// Any Epson scanner.
        case epson
        /// Every `_scanner._tcp` service.
        case all

        public func matches(_ scanner: DiscoveredScanner) -> Bool {
            switch self {
            case .ff680w: scanner.model == ScannerDiscovery.supportedModel
            case .epson: scanner.isEpson
            case .all: true
            }
        }
    }

    /// The scanners currently on the network, updated as they come and go. Browsing stops when the
    /// consuming task ends or is cancelled. Only FF-680W scanners are listed unless `filter` says otherwise.
    ///
    /// On iOS the first browse shows the local network permission prompt. If it is refused the stream
    /// throws ``DiscoveryError/localNetworkDenied`` (other `.waiting` states throw ``DiscoveryError/waiting(_:)``).
    public static func scanners(filter: ModelFilter = .ff680w) -> AsyncThrowingStream<[DiscoveredScanner], Error> {
        AsyncThrowingStream { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: NWParameters())
            browser.browseResultsChangedHandler = { results, _ in
                let found = results
                    .compactMap(DiscoveredScanner.init(result:))
                    .filter(filter.matches)
                    .sorted { $0.name < $1.name }
                continuation.yield(found)
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error): continuation.finish(throwing: DiscoveryError.make(from: error, waiting: false))
                case .waiting(let error): continuation.finish(throwing: DiscoveryError.make(from: error, waiting: true))
                default: break
                }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: DispatchQueue(label: "PhastPhotoScanner.Discovery"))
        }
    }

    /// Epson-only or everything, like the first version of this API. Prefer ``scanners(filter:)``.
    public static func scanners(epsonOnly: Bool) -> AsyncThrowingStream<[DiscoveredScanner], Error> {
        scanners(filter: epsonOnly ? .epson : .all)
    }

    /// The first scanner found (an FF-680W unless `filter` says otherwise), or `nil` if none appears within `timeout`.
    public static func firstScanner(timeout: Duration = .seconds(3), filter: ModelFilter = .ff680w) async throws -> DiscoveredScanner? {
        try await withThrowingTaskGroup(of: DiscoveredScanner?.self) { group in
            group.addTask {
                for try await list in scanners(filter: filter) {
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
