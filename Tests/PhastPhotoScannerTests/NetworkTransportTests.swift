import Foundation
import Network
import os
import PhastPhotoProtocol
import Testing
@testable import PhastPhotoScanner

/// A loopback "IS" server in front of a ``SimulatedScanner``: hello, lock, `0x2000` data, unlock.
final class ISTestServer: Sendable {
    let scanner: SimulatedScanner
    /// Hello payload; a busy scanner names its holder here and resets the connection on lock.
    let hello: Data
    let refusesLock: Bool
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ISTestServer")
    private let received = OSAllocatedUnfairLock<[ISPacketType]>(initialState: [])

    init(scanner: SimulatedScanner, hello: Data = Data([0x01, 0x04, 0x00, 0x00, 0x00]), refusesLock: Bool = false) throws {
        self.scanner = scanner
        self.hello = hello
        self.refusesLock = refusesLock
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Packet types received from clients, in order.
    var packetTypes: [ISPacketType] { received.withLock { $0 } }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self, hello] conn in
            conn.start(queue: queue)
            // The hello goes out from the listener's queue, as a scanner sends it at once: a Task would wait for
            // a free cooperative thread, which on a busy CI runner took longer than the probe's 300 ms read window.
            conn.send(content: ISPacket(type: .hello, payload: hello).encoded, completion: .idempotent)
            Task { await self.serve(conn) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: listener.port!.rawValue) }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ conn: NWConnection) async {
        defer { conn.cancel() }
        do {
            while true {
                let packet = try await NetworkTransport.receivePacket(conn)
                received.withLock { $0.append(packet.type) }
                switch packet.type {
                case .lock:
                    if refusesLock { return }
                    try await NetworkTransport.send(ISPacket(type: ISPacketType.lock.reply, payload: Data([0x06])), on: conn)
                case .unlock:
                    await scanner.markClosed()
                    try await NetworkTransport.send(ISPacket(type: ISPacketType.unlock.reply), on: conn)
                case .data:
                    guard let request = packet.dataRequest else { return }
                    let reply = try await scanner.handle(request.escI, replyLength: request.replyLength)
                    try await NetworkTransport.send(ISPacket(type: ISPacketType.data.reply, payload: reply), on: conn)
                default:
                    return
                }
            }
        } catch {
            return
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct NetworkTransportTests {
    @Test func sessionOverLoopback() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure {
            $0.imageReplies = ScannerSessionTests.onePrintDuplex(fakeScanJPEG(filler: 200_000), fakeScanJPEG())
        }
        let server = try ISTestServer(scanner: scanner)
        let port = try await server.start()
        defer { server.stop() }

        let transport = NetworkTransport(host: "127.0.0.1", port: port, timeout: .seconds(10))
        let log = PageLog()
        try await ScannerSession.withSession(transport: transport) { session async throws in
            #expect(try await session.info().productName == "FF-680W")
            try await session.scan(ScanSettings()) { log.append($0) }
        }
        #expect(log.all.map(\.height) == [1263, 1200])
        #expect(log.all.first?.jpeg.count == fakeScanJPEG(filler: 200_000).count)
        #expect(await transport.hello?.holderAddress == nil)
        #expect(server.packetTypes.first == .lock)
        #expect(server.packetTypes.last == .unlock)
        #expect(await scanner.closed)
    }

    @Test func busyScannerNamesHolder() async throws {
        // busy hello: 01 04 81 00 01 01 01, address length 4, 192.0.2.7
        let busy = Data([0x01, 0x04, 0x81, 0x00, 0x01, 0x01, 0x01, 0x04, 192, 0, 2, 7])
        let server = try ISTestServer(scanner: SimulatedScanner(), hello: busy, refusesLock: true)
        let port = try await server.start()
        defer { server.stop() }

        let session = ScannerSession(transport: NetworkTransport(host: "127.0.0.1", port: port, timeout: .seconds(10)))
        await #expect {
            try await session.open()
        } throws: { error in
            guard case ScannerError.busy(let holder) = error else { return false }
            return holder == "192.0.2.7"
        }
    }

    @Test func connectionRefused() async throws {
        // bind and release a port so nothing listens on it
        let server = try ISTestServer(scanner: SimulatedScanner())
        let port = try await server.start()
        server.stop()
        try await Task.sleep(for: .milliseconds(100))

        let transport = NetworkTransport(host: "127.0.0.1", port: port, timeout: .seconds(5))
        await #expect(throws: ScannerError.self) { try await transport.open() }
    }

    /// A connection reset before the hello is a failed connection, not a raw `NWError`. (The iOS 26 simulator on
    /// a CI runner turned the refused connect above into exactly this: connected, then reset.)
    @Test func resetBeforeTheHelloIsAConnectionFailure() async throws {
        let server = try ResettingServer()
        let transport = NetworkTransport(host: "127.0.0.1", port: server.port, timeout: .seconds(5))
        await #expect {
            try await transport.open()
        } throws: { error in
            guard case ScannerError.connectionFailed = error else { return false }
            return true
        }
        server.close()
    }

    /// The test server's hello must not wait for a cooperative thread. Under
    /// `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (one cooperative thread, which this test blocks) a hello that waits
    /// for one never arrives, so this fails. The 30 s limit is only a backstop (a passing run returns at once):
    /// 300 ms and then 5 s were too short for the iOS Simulator on a busy CI runner.
    @Test func testServerSendsTheHelloWithoutACooperativeThread() async throws {
        let server = try ISTestServer(scanner: SimulatedScanner())
        let port = try await server.start()
        defer { server.stop() }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var address = loopback(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(connected == 0)
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var header = [UInt8](repeating: 0, count: ISPacket.headerLength)
        let n = recv(fd, &header, header.count, MSG_WAITALL)  // blocks this cooperative thread
        #expect(n == header.count && SubnetProbe.isHello(header), "no hello within 30 s (got \(n) bytes)")
    }
}

private func loopback(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    return address
}

/// Accepts one connection on a loopback port and resets it at once (`SO_LINGER` 0, then close).
private final class ResettingServer: Sendable {
    let port: UInt16
    private let fd: Int32

    init() throws {
        let listening = socket(AF_INET, SOCK_STREAM, 0)
        var address = loopback(port: 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listening, $0, size) } }
        guard bound == 0, listen(listening, 4) == 0 else { Darwin.close(listening); throw POSIXError(.EADDRINUSE) }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listening, $0, &size) } }
        fd = listening
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread {
            let client = accept(listening, nil, nil)
            guard client >= 0 else { return }
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(client, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
            Darwin.close(client)
        }
    }

    func close() { Darwin.close(fd) }
}
