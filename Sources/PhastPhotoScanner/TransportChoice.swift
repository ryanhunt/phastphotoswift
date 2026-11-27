import Foundation
import Network
import PhastPhotoProtocol

/// How to reach the scanner.
public enum TransportChoice: Sendable, Hashable {
    /// USB if a scanner is plugged in (macOS, or an M-series iPad with the driver enabled), else Bonjour, else a
    /// probe of the local /24.
    case automatic
    /// USB only (macOS, or iPadOS through the driver extension). Fails with a clear message if nothing is plugged in.
    case usb
    /// Wi-Fi to this address (or Bonjour host name), skipping discovery.
    case wifi(host: String)
}

/// Picks and builds a ``ScannerTransport`` (upstream `FF680W.__enter__`, ff680w.py:530-550).
///
/// ```swift
/// let session = ScannerSession(transport: try await ScannerConnection.automatic())
/// ```
public enum ScannerConnection {
    /// Where a choice ended up.
    public enum Route: Sendable, Equatable {
        case usb
        case bonjour(DiscoveredScanner)
        case wifi(host: String)
    }

    /// The outside world, injectable so the decision logic can be tested without a scanner.
    public struct Probes: Sendable {
        public var usbPresent: @Sendable () -> Bool
        public var bonjour: @Sendable () async throws -> DiscoveredScanner?
        public var subnet: @Sendable () async -> String?

        public init(
            usbPresent: @escaping @Sendable () -> Bool,
            bonjour: @escaping @Sendable () async throws -> DiscoveredScanner?,
            subnet: @escaping @Sendable () async -> String?
        ) {
            self.usbPresent = usbPresent
            self.bonjour = bonjour
            self.subnet = subnet
        }

        /// The real USB bus, Bonjour (3 s) and the local /24.
        public static let live = Probes(
            usbPresent: {
                #if os(macOS) || os(iOS)
                USBTransport.isScannerPresent()
                #else
                false
                #endif
            },
            bonjour: { try await ScannerDiscovery.firstScanner() },
            subnet: { await SubnetProbe.scanLocalSubnet() }
        )
    }

    public static let noUSBMessage = "No scanner on USB: is the cable plugged in? (USB needs a Mac, or an iPad with an "
        + "M-series chip and the scanner driver enabled in Settings > General > Drivers.)"
    public static let noScannerMessage = "No Epson scanner found on the network; is it on and on the same Wi-Fi?"

    /// Decide how to reach the scanner. Nothing is connected yet.
    public static func route(for choice: TransportChoice = .automatic, probes: Probes = .live) async throws -> Route {
        switch choice {
        case .usb:
            guard probes.usbPresent() else { throw ScannerError.connectionFailed(noUSBMessage) }
            return .usb
        case .wifi(let host):
            return .wifi(host: host)
        case .automatic:
            if probes.usbPresent() { return .usb }
            // a Bonjour failure (e.g. no local network permission) falls through to the probe
            if let found = try? await probes.bonjour() { return .bonjour(found) }
            if let host = await probes.subnet() { return .wifi(host: host) }
            throw ScannerError.connectionFailed(noScannerMessage)
        }
    }

    /// The transport for `choice`, not yet opened (``ScannerSession`` opens it).
    public static func transport(for choice: TransportChoice = .automatic, probes: Probes = .live) async throws -> any ScannerTransport {
        try make(try await route(for: choice, probes: probes))
    }

    /// `transport(for: .automatic)`: USB if plugged in, else Bonjour, else the subnet probe.
    public static func automatic() async throws -> any ScannerTransport {
        try await transport(for: .automatic)
    }

    static func make(_ route: Route) throws -> any ScannerTransport {
        switch route {
        case .usb:
            #if os(macOS) || os(iOS)
            return USBTransport()
            #else
            throw ScannerError.connectionFailed(noUSBMessage)
            #endif
        case .bonjour(let scanner):
            return NetworkTransport(endpoint: scanner.endpoint)
        case .wifi(let host):
            return NetworkTransport(host: host)
        }
    }
}
