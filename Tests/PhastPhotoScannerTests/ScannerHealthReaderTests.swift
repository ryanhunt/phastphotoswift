import Foundation
import Network
import Testing
@testable import PhastPhotoProtocol
@testable import PhastPhotoScanner

/// An in-memory agent with GetNext semantics over a sorted table, and v1's noSuchName past the end.
private actor FakeAgent: SNMPExchanging {
    let table: [SNMPBinding]
    private(set) var requests = 0
    init(_ bindings: [SNMPBinding]) { table = bindings.sorted { $0.oid < $1.oid } }

    func exchange(_ kind: SNMPPDU.Kind, oids: [SNMPOID]) async throws -> SNMPPDU {
        requests += 1
        let oid = oids[0]
        let hit = kind == .getNextRequest ? table.first { oid < $0.oid } : table.first { $0.oid == oid }
        guard let hit else {
            return SNMPPDU(kind: .getResponse, requestID: 1, errorStatus: SNMPPDU.noSuchName, errorIndex: 1,
                           bindings: [SNMPBinding(oid: oid, value: .null)])
        }
        return SNMPPDU(kind: .getResponse, requestID: 1, errorStatus: 0, errorIndex: 0, bindings: [hit])
    }
}

/// An agent that answers every GetNext with the same OID (a broken walk).
private struct StuckAgent: SNMPExchanging {
    func exchange(_ kind: SNMPPDU.Kind, oids: [SNMPOID]) async throws -> SNMPPDU {
        SNMPPDU(kind: .getResponse, requestID: 1, errorStatus: 0, errorIndex: 0,
                bindings: [SNMPBinding(oid: EpsonMIB.counterTable.appending(4, 1, 1), value: .counter32(1))])
    }
}

/// An agent whose every value is in the subtree: only the limit ends the walk.
private actor EndlessAgent: SNMPExchanging {
    func exchange(_ kind: SNMPPDU.Kind, oids: [SNMPOID]) async throws -> SNMPPDU {
        SNMPPDU(kind: .getResponse, requestID: 1, errorStatus: 0, errorIndex: 0,
                bindings: [SNMPBinding(oid: oids[0].appending(1), value: .integer(0))])
    }
}

@Suite(.timeLimit(.minutes(1))) struct ScannerHealthReaderTests {
    @Test func readsTheSampleScanner() async throws {
        // the sample plus values outside every walked subtree (the last client's host name), which must not be read
        let extra = SNMPBinding(oid: "1.3.6.1.4.1.1248.1.4.2.21.1.1.2.1", value: .octets(Array("someones-mac".utf8)))
        let agent = FakeAgent(SampleWalk.bindings + [extra])
        let health = try await ScannerHealthReader(exchanger: agent).read()
        #expect(health == ScannerHealth(snmp: SampleWalk.bindings))
        #expect(health.rollerKit?.used == 1331)
        // one GetNext per value, plus one that leaves each subtree
        #expect(await agent.requests == SampleWalk.bindings.count + EpsonMIB.walkedSubtrees.count)
    }

    @Test func walkStopsAtTheEndOfTheSubtreeOrMIB() async throws {
        let agent = FakeAgent(SampleWalk.bindings)
        let counters = try await ScannerHealthReader.walk(EpsonMIB.counterTable, using: agent)
        #expect(counters.count == 6)
        #expect(try await ScannerHealthReader.walk("1.3.6.1.9", using: agent).isEmpty)  // past the end: noSuchName
    }

    @Test func brokenWalksEnd() async throws {
        #expect(try await ScannerHealthReader.walk(EpsonMIB.counterTable, using: StuckAgent()).count == 1)
        let endless = try await ScannerHealthReader.walk(EpsonMIB.counterTable, using: EndlessAgent())
        #expect(endless.count == ScannerHealthReader.walkLimit)
    }

    // MARK: the UDP client against a loopback agent

    @Test func clientTalksToALoopbackAgent() async throws {
        let agent = try UDPAgent(table: SampleWalk.bindings)
        let port = try await agent.start()
        defer { agent.stop() }
        let health = try await ScannerHealthReader(host: "127.0.0.1", port: port, timeout: .seconds(2)).read()
        #expect(health.firmware?.package == "18.60.SP14P2.FY17")
        #expect(health.rollerKit?.life == 200_000)
        #expect(health.network?.macAddress == "02:00:00:00:00:01")
    }

    @Test func aLostDatagramIsRetried() async throws {
        let agent = try UDPAgent(table: SampleWalk.bindings, dropFirst: 1)
        let port = try await agent.start()
        defer { agent.stop() }
        // the retry's answer must arrive within the timeout: generous, since a passing run doesn't wait for it
        let client = SNMPClient(host: "127.0.0.1", port: port, community: "public", timeout: .seconds(1))
        let pdu = try await client.exchange(.getNextRequest, oids: [EpsonMIB.counterTable])
        await client.close()
        #expect(pdu.bindings.first?.value == .counter32(1331))
        #expect(agent.received == 2)
    }

    /// The answer to the first send arrives after its timeout: the retry (same request ID) takes it.
    @Test func aLateAnswerCountsForTheRetry() async throws {
        // the agent answers the first send only when the retry arrives, and never answers the retry itself:
        // the client must accept the first send's answer (no timing involved)
        let agent = try UDPAgent(table: SampleWalk.bindings, answerFirstOnRetry: true)
        let port = try await agent.start()
        defer { agent.stop() }
        let client = SNMPClient(host: "127.0.0.1", port: port, community: "public", timeout: .milliseconds(500))
        let pdu = try await client.exchange(.getNextRequest, oids: [EpsonMIB.counterTable])
        await client.close()
        #expect(pdu.bindings.first?.value == .counter32(1331))
    }

    /// Silence, and replies with another request ID or community, all end as a timeout.
    @Test(arguments: [UDPAgent.Mode.silent, .wrongID, .wrongCommunity])
    func noMatchingReplyTimesOut(mode: UDPAgent.Mode) async throws {
        let agent = try UDPAgent(table: SampleWalk.bindings, mode: mode)
        let port = try await agent.start()
        defer { agent.stop() }
        let client = SNMPClient(host: "127.0.0.1", port: port, community: "public", timeout: .milliseconds(200))
        await #expect(throws: ScannerError.self) { try await client.exchange(.getNextRequest, oids: ["1.3.6.1"]) }
        await client.close()
        // The client asked (the agent heard at least once). That the retry goes out is checked by
        // aLostDatagramIsRetried and aLateAnswerCountsForTheRetry: counting both datagrams here was flaky on CI
        // simulators, where the agent's new UDP flow sometimes saw only one of two datagrams 200 ms apart.
        for _ in 0 ..< 200 where agent.received < 1 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(agent.received >= 1)
    }
}

/// A loopback SNMP v1 agent over UDP, answering Get/GetNext from a table (like `ISTestServer` for the session).
final class UDPAgent: @unchecked Sendable {
    enum Mode: Sendable, CustomTestStringConvertible {
        case normal, silent, wrongID, wrongCommunity
        var testDescription: String { "\(self)" }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "UDPAgent")
    private let table: [SNMPBinding]
    private let mode: Mode
    private var dropFirst: Int
    private let answerFirstOnRetry: Bool
    private var heldReply: Data?
    private let lock = NSLock()
    private var _received = 0
    var received: Int { lock.withLock { _received } }

    init(table: [SNMPBinding], mode: Mode = .normal, dropFirst: Int = 0, answerFirstOnRetry: Bool = false) throws {
        self.answerFirstOnRetry = answerFirstOnRetry
        self.table = table.sorted { $0.oid < $1.oid }
        self.mode = mode
        self.dropFirst = dropFirst
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] conn in
            conn.start(queue: queue)
            receive(on: conn)
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

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [self] data, _, _, error in
            if let data, let reply = answer(data) { conn.send(content: reply, completion: .idempotent) }
            if error == nil { receive(on: conn) }
        }
    }

    private func answer(_ data: Data) -> Data? {
        let drop = lock.withLock { () -> Bool in
            _received += 1
            if dropFirst > 0 { dropFirst -= 1; return true }
            return false
        }
        guard !drop, mode != .silent, let request = try? decodeRequest(data) else { return nil }
        if answerFirstOnRetry {
            // hold the first answer; send it (instead of an answer) when the retry comes in
            return lock.withLock {
                if heldReply == nil, _received == 1 { heldReply = reply(to: request); return nil }
                defer { heldReply = nil }
                return heldReply
            }
        }
        return reply(to: request)
    }

    private func reply(to request: (kind: UInt8, id: Int32, oids: [SNMPOID])) -> Data {
        let oid = request.oids[0]
        let hit = request.kind == 0xA1 ? table.first { oid < $0.oid } : table.first { $0.oid == oid }
        let id = mode == .wrongID ? request.id ^ 0x5555 : request.id  // never an ID the client used
        let community = mode == .wrongCommunity ? "private" : "public"
        guard let hit else {
            return snmpResponse(id: id, errorStatus: SNMPPDU.noSuchName, community: community, [(oid, SNMP.tlv(0x05, []))])
        }
        return snmpResponse(id: id, community: community, [(hit.oid, Self.encode(hit.value))])
    }

    /// Requests have the same shape as responses, so the decoder reads them once the PDU tag is swapped.
    private func decodeRequest(_ data: Data) throws -> (kind: UInt8, id: Int32, oids: [SNMPOID]) {
        var bytes = Array(data)
        guard let at = bytes.firstIndex(where: { $0 == 0xA0 || $0 == 0xA1 }) else { throw SNMPError.malformed("no PDU") }
        let kind = bytes[at]
        bytes[at] = 0xA2
        let (_, pdu) = try SNMP.decode(Data(bytes))
        return (kind, pdu.requestID, pdu.bindings.map(\.oid))
    }

    static func encode(_ value: SNMPValue) -> [UInt8] {
        switch value {
        case .integer(let v): BER.int(v)
        case .octets(let b): BER.octets(b)
        case .counter32(let v): BER.counter(v)
        case .timeTicks(let v): BER.ticks(v)
        case .ipAddress(let b): SNMP.tlv(0x40, b)
        default: SNMP.tlv(0x05, [])
        }
    }
}
