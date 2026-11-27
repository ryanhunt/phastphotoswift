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
        listener.newConnectionHandler = { [self] conn in
            conn.start(queue: queue)
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
            try await NetworkTransport.send(ISPacket(type: .hello, payload: hello), on: conn)
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
}
