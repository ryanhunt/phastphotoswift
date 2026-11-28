import Foundation
import Network
import PhastPhotoProtocol

/// One SNMP request and its response. ``SNMPClient`` is the real one; tests inject fakes.
public protocol SNMPExchanging: Sendable {
    func exchange(_ kind: SNMPPDU.Kind, oids: [SNMPOID]) async throws -> SNMPPDU
}

/// Reads the scanner's health over SNMP v1 (docs/PLAN.md 11.3): firmware, roller kit wear, clock, uptime and
/// network details, plus values not yet labelled. Wi-Fi only (there is no SNMP over USB).
///
/// SNMP runs beside the scanner's own protocol: it needs no session and never takes the scanner's lock, so it
/// works while another app holds the scanner. Whether it is harmless during a scan is not established yet, so
/// read health between scans. Only Get and GetNext are sent; the library has no way to change a setting.
///
/// Errors: ``ScannerError/timedOut`` when nothing answers (scanner off or asleep, or SNMP turned off in its
/// Web Config), ``ScannerError/connectionFailed(_:)`` when there is no route to it.
public struct ScannerHealthReader: Sendable {
    /// Most values read per subtree, a guard against a scanner that never ends a walk.
    public static let walkLimit = 400

    private let makeExchanger: @Sendable () async throws -> any SNMPExchanging

    /// - Parameters:
    ///   - host: the scanner's IPv4 address or host name.
    ///   - community: the SNMP community (`public` unless the owner changed it in Web Config).
    ///   - port: the SNMP port (161).
    ///   - timeout: per request; each request is sent twice before giving up.
    public init(host: String, port: UInt16 = SNMP.port, community: String = "public", timeout: Duration = .seconds(2)) {
        makeExchanger = { SNMPClient(host: host, port: port, community: community, timeout: timeout) }
    }

    /// A scanner found with ``ScannerDiscovery``: its host is looked up first (a short TCP connection to the
    /// scanner's port 1865, which reads no more than the hello and takes no lock, like ``SubnetProbe``).
    public init(scanner: DiscoveredScanner, community: String = "public", timeout: Duration = .seconds(2)) {
        makeExchanger = {
            let host = try await Self.resolveHost(of: scanner.endpoint, timeout: max(timeout, .seconds(5)))
            return SNMPClient(host: host, community: community, timeout: timeout)
        }
    }

    init(exchanger: any SNMPExchanging) { makeExchanger = { exchanger } }

    public func read() async throws -> ScannerHealth {
        let exchanger = try await makeExchanger()
        defer { if let client = exchanger as? SNMPClient { Task { await client.close() } } }
        var bindings: [SNMPBinding] = []
        for subtree in EpsonMIB.walkedSubtrees {
            bindings += try await Self.walk(subtree, using: exchanger)
        }
        return ScannerHealth(snmp: bindings)
    }

    /// GetNext from `subtree` until a value falls outside it, the agent reports the end (`noSuchName`), the OIDs
    /// stop increasing, or ``walkLimit`` values were read.
    static func walk(_ subtree: SNMPOID, using exchanger: any SNMPExchanging) async throws -> [SNMPBinding] {
        var out: [SNMPBinding] = []
        var cursor = subtree
        while out.count < walkLimit {
            let pdu = try await exchanger.exchange(.getNextRequest, oids: [cursor])
            guard pdu.errorStatus == 0, let binding = pdu.bindings.first,
                  binding.oid.hasPrefix(subtree), cursor < binding.oid else { break }
            out.append(binding)
            cursor = binding.oid
        }
        return out
    }

    /// The host behind a Bonjour service, from a short TCP connection's remote endpoint (IPv4 preferred).
    static func resolveHost(of endpoint: NWEndpoint, timeout: Duration) async throws -> String {
        if case .hostPort(let host, _) = endpoint { return Self.string(host) }
        let conn = NWConnection(to: endpoint, using: NetworkTransport.parameters(for: endpoint, timeout: timeout))
        let queue = DispatchQueue(label: "PhastPhotoScanner.ScannerHealthReader.resolve")
        defer { conn.cancel() }
        let timer = DispatchWorkItem { conn.cancel() }
        queue.asyncAfter(deadline: .now() + timeout.dispatchInterval, execute: timer)
        defer { timer.cancel() }
        try await NetworkTransport.start(conn, queue: queue)
        guard case .hostPort(let host, _) = conn.currentPath?.remoteEndpoint else {
            throw ScannerError.connectionFailed("couldn't look up the scanner's address")
        }
        return Self.string(host)
    }

    static func string(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): "\(a)"
        case .ipv6(let a): "\(a)"
        case .name(let n, _): n
        @unknown default: "\(host)"
        }
    }
}

/// SNMP v1 over UDP port 161, IPv4 only. One long-lived receive loop hands datagrams to the request waiting for
/// that request ID, so a late reply can't be taken for the next one.
actor SNMPClient: SNMPExchanging {
    private let connection: NWConnection
    private let community: String
    private let timeout: Duration
    private let queue = DispatchQueue(label: "PhastPhotoScanner.SNMPClient")
    private var started = false
    private var nextID = Int32.random(in: 1 ... 0x3FFF_FFFF)
    private var waiters: [Int32: CheckedContinuation<SNMPPDU, Error>] = [:]

    init(host: String, port: UInt16 = SNMP.port, community: String, timeout: Duration) {
        let parameters = NWParameters.udp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: parameters)
        self.community = community
        self.timeout = timeout
    }

    func exchange(_ kind: SNMPPDU.Kind, oids: [SNMPOID]) async throws -> SNMPPDU {
        try await start()
        do {
            return try await attempt(kind, oids: oids)
        } catch ScannerError.timedOut {
            return try await attempt(kind, oids: oids)  // UDP: one retry
        }
    }

    func close() {
        connection.cancel()
        for waiter in waiters.values { waiter.resume(throwing: ScannerError.connectionClosed) }
        waiters = [:]
    }

    private func attempt(_ kind: SNMPPDU.Kind, oids: [SNMPOID]) async throws -> SNMPPDU {
        let id = nextID
        nextID = nextID == Int32.max ? 1 : nextID + 1
        let datagram = SNMP.request(kind, requestID: id, community: community, oids: oids)
        let timer = Task { [timeout] in
            try await Task.sleep(for: timeout)
            self.expire(id)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            connection.send(content: datagram, completion: .contentProcessed { error in
                if let error { Task { await self.fail(id, ScannerError.connectionFailed(error.localizedDescription)) } }
            })
        }
    }

    private func start() async throws {
        guard !started else { return }
        started = true
        let conn = connection
        let timer = DispatchWorkItem { conn.cancel() }
        queue.asyncAfter(deadline: .now() + timeout.dispatchInterval, execute: timer)
        defer { timer.cancel() }
        do {
            try await NetworkTransport.start(conn, queue: queue)
        } catch ScannerError.connectionClosed {
            throw ScannerError.timedOut
        }
        receiveLoop()
    }

    private nonisolated func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { Task { await self.deliver(data) } }
            if error == nil { self.receiveLoop() }
        }
    }

    private func deliver(_ data: Data) {
        // a datagram that isn't a response to a waiting request is dropped
        guard let (community, pdu) = try? SNMP.decode(data), community == self.community,
              pdu.kind == .getResponse, let waiter = waiters.removeValue(forKey: pdu.requestID) else { return }
        waiter.resume(returning: pdu)
    }

    private func expire(_ id: Int32) { waiters.removeValue(forKey: id)?.resume(throwing: ScannerError.timedOut) }

    private func fail(_ id: Int32, _ error: Error) { waiters.removeValue(forKey: id)?.resume(throwing: error) }
}
