import Foundation
import Network
import os
import PhastPhotoProtocol

/// Wi-Fi transport: Epson's "IS" framing over TCP port 1865 (docs/PROTOCOL.md §1).
///
/// Apps need local network access: on iOS add `NSLocalNetworkUsageDescription` and `_scanner._tcp` under
/// `NSBonjourServices` to the Info.plist; sandboxed Mac apps need the `com.apple.security.network.client`
/// entitlement.
public actor NetworkTransport: ScannerTransport {
    public nonisolated let endpoint: NWEndpoint
    /// Longest wait for a connection or for any one reply.
    public nonisolated let timeout: Duration
    public nonisolated let pollInterval: Duration

    /// The hello from the last ``open()``. While another client holds the scanner it names that client.
    public private(set) var hello: ScannerHello?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "PhastPhotoScanner.NetworkTransport")

    /// - Parameter endpoint: a Bonjour service from ``ScannerDiscovery`` or a host and port.
    public init(endpoint: NWEndpoint, timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(50)) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public init(host: String, port: UInt16 = ISPacket.port, timeout: Duration = .seconds(60)) {
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), timeout: timeout)
    }

    public func open() async throws {
        guard connection == nil else { return }
        let conn = NWConnection(to: endpoint, using: Self.parameters(for: endpoint, timeout: timeout))
        connection = conn
        do {
            try await Self.start(conn, queue: queue)
            let first = try await guarded(conn) { try await Self.receivePacket(conn) }
            guard first.type == .hello else { throw ScannerError.unexpectedPacket(type: first.type.rawValue) }
            let hello = ScannerHello(payload: first.payload)
            self.hello = hello
            // a busy scanner resets the connection instead of answering
            let reply = try? await guarded(conn) {
                try await Self.send(.lock(), on: conn)
                return try await Self.receivePacket(conn)
            }
            guard reply == ISPacket(type: ISPacketType.lock.reply, payload: Data([ESCI2.acknowledge])) else {
                throw ScannerError.busy(holder: hello.holderAddress)
            }
        } catch {
            conn.cancel()
            connection = nil
            // A network error during the hello (a reset, a closed socket) means the scanner couldn't be reached:
            // report it like a failed connect rather than as a raw NWError.
            if error is ScannerError || error is CancellationError { throw error }
            throw ScannerError.connectionFailed(error.localizedDescription)
        }
    }

    public func transfer(_ chunks: [Data], replyLength: Int) async throws -> Data {
        guard let conn = connection else { throw ScannerError.notConnected }
        let escI = chunks.reduce(into: Data()) { $0.append($1) }
        return try await guarded(conn) {
            try await Self.send(.data(escI, replyLength: replyLength), on: conn)
            let reply = try await Self.receivePacket(conn)
            guard reply.type == ISPacketType.data.reply else {
                throw ScannerError.unexpectedPacket(type: reply.type.rawValue)
            }
            return reply.payload
        }
    }

    public func close() async {
        guard let conn = connection else { return }
        connection = nil
        _ = try? await guarded(conn) {
            try await Self.send(.unlock(), on: conn)
            return try await Self.receivePacket(conn)
        }
        conn.cancel()
    }

    // MARK: - Connection plumbing

    /// Runs `operation`, cancelling the connection if it takes longer than ``timeout``. The timer is a
    /// dispatch callback rather than a child task, so cancelling the calling task never leaves an exchange
    /// half done: a session has to stay in step with the scanner to send `CAN ` and `FIN `.
    private func guarded<T>(_ conn: NWConnection, _ operation: () async throws -> T) async throws -> T {
        let fired = OnceFlag()
        let timer = DispatchWorkItem { if fired.claim() { conn.cancel() } }
        queue.asyncAfter(deadline: .now() + timeout.dispatchInterval, execute: timer)
        defer { timer.cancel() }
        do {
            return try await operation()
        } catch {
            if fired.isClaimed {
                if connection === conn { connection = nil }
                throw ScannerError.timedOut
            }
            throw error
        }
    }

    /// TCP with Nagle off (small request/reply exchanges), preferring IPv4: Bonjour names also resolve to IPv6
    /// link-local addresses, and a session over IPv6 once left a lock that couldn't be seen.
    static func parameters(for endpoint: NWEndpoint, timeout: Duration) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(timeout.components.seconds))
        let parameters = NWParameters(tls: nil, tcp: tcp)
        var isIPv6Literal = false
        if case .hostPort(let host, _) = endpoint, case .ipv6 = host { isIPv6Literal = true }
        if !isIPv6Literal, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return parameters
    }

    static func start(_ conn: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .waiting(let error), .failed(let error):
                    if once.claim() { continuation.resume(throwing: ScannerError.connectionFailed(error.localizedDescription)) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: ScannerError.connectionClosed) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    static func send(_ packet: ISPacket, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: packet.encoded, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    static func receivePacket(_ conn: NWConnection) async throws -> ISPacket {
        let header = try await receive(exactly: ISPacket.headerLength, from: conn)
        let (type, length) = try ISPacket.parseHeader(header)
        let payload = length > 0 ? try await receive(exactly: length, from: conn) : Data()
        return ISPacket(type: type, payload: payload)
    }

    static func receive(exactly count: Int, from conn: NWConnection) async throws -> Data {
        var data = Data(capacity: count)  // image blocks can be large
        while data.count < count {
            let wanted = count - data.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                conn.receive(minimumIncompleteLength: 1, maximumLength: wanted) { content, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(throwing: ScannerError.connectionClosed)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            data.append(chunk)
        }
        return data
    }
}

/// A flag that can be claimed once, from any thread.
final class OnceFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        state.withLock { claimed in
            if claimed { return false }
            claimed = true
            return true
        }
    }

    var isClaimed: Bool { state.withLock { $0 } }
}

extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let milliseconds = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        return .milliseconds(Int(max(0, min(milliseconds, Double(Int32.max)))))
    }
}
