#if os(macOS) || os(iOS)
import Foundation
import Testing

@testable import PhastPhotoScanner

/// A scripted stand-in for the USB bulk endpoints. Reads pop queued replies; a queued `nil` is a timeout and
/// ``stale`` is an overrun (leftover data).
private actor FakePipes: USBPipes {
    enum Event: Equatable {
        case write(Data)
        case read(Int)
        case reset
        case reclaim
        case release
    }

    private(set) var events: [Event] = []
    private var replies: [Data?]

    init(replies: [Data?] = []) { self.replies = replies }

    static let stale = Data("stale data marker".utf8)

    func write(_ data: Data) async throws { events.append(.write(data)) }

    func read(maxLength: Int) async throws -> Data {
        events.append(.read(maxLength))
        guard !replies.isEmpty, let reply = replies.removeFirst() else { throw ScannerError.timedOut }
        if reply == Self.stale { throw USBStaleData() }
        return reply
    }

    func resetDevice() async throws { events.append(.reset) }
    func reclaim() async throws { events.append(.reclaim) }
    func release() async { events.append(.release) }
}

private func transport(over pipes: FakePipes) -> USBTransport {
    USBTransport(timeout: .seconds(1), settleDelay: .zero) { pipes }
}

@Suite(.timeLimit(.minutes(1))) struct USBTransportTests {
    private let header = Data("INFOx0000000".utf8)  // 12 bytes of command header
    private let params = Data([0x01, 0x02, 0x03])

    @Test func constantsMatchUpstream() {
        #expect(USBTransport.vendorID == 0x04B8)
        #expect(USBTransport.productID == 0x016B)
        #expect(USBTransport.interfaceNumber == 0)
        #expect(USBTransport.bulkOut == 0x01)
        #expect(USBTransport.bulkIn == 0x82)
        #expect(transport(over: FakePipes()).pollInterval == .milliseconds(5))
    }

    @Test func eachChunkIsItsOwnBulkWrite() async throws {
        let pipes = FakePipes(replies: [Data([0x06]), Data(count: 64)])
        let t = transport(over: pipes)
        try await t.open()
        _ = try await t.transfer([Data([0x1C, 0x58])], replyLength: 1)
        let reply = try await t.transfer([header, params], replyLength: 64)
        #expect(reply.count == 64)
        // header and parameter block are separate transfers, then one read
        #expect(await pipes.events == [
            .write(Data([0x1C, 0x58])), .read(1),
            .write(header), .write(params), .read(64),
        ])
    }

    @Test func emptyChunksSendNothingAndOnlyRead() async throws {
        let body = Data(repeating: 7, count: 100)
        let pipes = FakePipes(replies: [Data([0x06]), body, body])
        let t = transport(over: pipes)
        try await t.open()
        _ = try await t.transfer([Data([0x1C, 0x58])], replyLength: 1)
        #expect(try await t.transfer([], replyLength: 100) == body)
        #expect(try await t.transfer([Data(), Data()], replyLength: 100) == body)
        #expect(await pipes.events.dropFirst(2) == [.read(100), .read(100)])
    }

    @Test func replyIsNeverLongerThanAsked() async throws {
        let pipes = FakePipes(replies: [Data([0x06]), Data(repeating: 1, count: 10)])
        let t = transport(over: pipes)
        try await t.open()
        _ = try await t.transfer([Data([0x1C, 0x58])], replyLength: 1)
        #expect(try await t.transfer([header], replyLength: 4).count == 4)
    }

    @Test func shortRepliesPassThrough() async throws {
        let pipes = FakePipes(replies: [Data([0x06]), Data(repeating: 1, count: 10)])
        let t = transport(over: pipes)
        try await t.open()
        _ = try await t.transfer([Data([0x1C, 0x58])], replyLength: 1)
        #expect(try await t.transfer([], replyLength: 64).count == 10)
    }

    @Test func transferBeforeOpenFails() async {
        let t = transport(over: FakePipes())
        await #expect(throws: ScannerError.self) { try await t.transfer([Data([1])], replyLength: 1) }
    }

    @Test func timeoutEnteringCommandModeResetsAndRetriesOnce() async throws {
        // first read times out (scanner left mid-command), then answers after the reset
        let pipes = FakePipes(replies: [nil, Data([0x06])])
        let t = transport(over: pipes)
        try await t.open()
        let ack = try await t.transfer([Data([0x1C, 0x58])], replyLength: 1)
        #expect(ack == Data([0x06]))
        #expect(await pipes.events == [
            .write(Data([0x1C, 0x58])), .read(1),
            .reset, .reclaim,
            .write(Data([0x1C, 0x58])), .read(1),
        ])
    }

    /// Leftovers of an interrupted scan (an overrun) on the first transfer: reset and retry, like a timeout.
    @Test func staleDataEnteringCommandModeResetsAndRetriesOnce() async throws {
        let pipes = FakePipes(replies: [FakePipes.stale, Data([0x06])])
        let t = transport(over: pipes)
        try await t.open()
        #expect(try await t.transfer([Data([0x1C, 0x58])], replyLength: 1) == Data([0x06]))
        #expect(await pipes.events.filter { $0 == .reset }.count == 1)
    }

    /// Later in a session, or again after the reset, an overrun is a clear error and no reset.
    @Test func laterStaleDataIsAnErrorWithoutReset() async throws {
        for replies in [[Data([0x06]), FakePipes.stale], [FakePipes.stale, FakePipes.stale]] {
            let pipes = FakePipes(replies: replies)
            let t = transport(over: pipes)
            try await t.open()
            do {
                _ = try await t.transfer([Data([0x1C, 0x58])], replyLength: 1)
                _ = try await t.transfer([Data([0x1C, 0x58])], replyLength: 1)
                Issue.record("no error")
            } catch {
                guard case ScannerError.connectionFailed(let message) = error else {
                    Issue.record("\(error)")
                    continue
                }
                #expect(message == USBTransport.staleDataMessage)
            }
            #expect(await pipes.events.filter { $0 == .reset }.count == (replies[0] == FakePipes.stale ? 1 : 0))
        }
    }

    @Test func secondTimeoutAfterResetIsReported() async throws {
        let pipes = FakePipes(replies: [nil, nil])
        let t = transport(over: pipes)
        try await t.open()
        await #expect(throws: ScannerError.self) { try await t.transfer([Data([0x1C, 0x58])], replyLength: 1) }
        #expect(await pipes.events.filter { $0 == .reset }.count == 1)
    }

    @Test func laterTimeoutsDoNotReset() async throws {
        let pipes = FakePipes(replies: [Data([0x06]), nil])
        let t = transport(over: pipes)
        try await t.open()
        _ = try await t.transfer([Data([0x1C, 0x58])], replyLength: 1)
        await #expect(throws: ScannerError.self) { try await t.transfer([header], replyLength: 64) }
        #expect(await !pipes.events.contains(.reset))
    }

    @Test func explicitResetWaitsThenReclaims() async throws {
        let pipes = FakePipes()
        let t = transport(over: pipes)
        try await t.open()
        try await t.reset()
        #expect(await pipes.events == [.reset, .reclaim])
        #expect(USBTransport(timeout: .seconds(1)).settleDelay == .seconds(2))
    }

    @Test func closeReleasesOnceAndOpenIsRepeatable() async throws {
        let pipes = FakePipes()
        let t = transport(over: pipes)
        try await t.open()
        try await t.open()  // already open: no second claim
        await t.close()
        await t.close()
        #expect(await pipes.events == [.release])
        await #expect(throws: ScannerError.self) { try await t.reset() }
    }

    @Test func openFailureNamesTheCause() async {
        let t = USBTransport(timeout: .seconds(1), settleDelay: .zero) {
            throw ScannerError.connectionFailed(USBTransport.interfaceInUseMessage)
        }
        await #expect {
            try await t.open()
        } throws: { error in
            guard case ScannerError.connectionFailed(let message) = error else { return false }
            return message.contains("Epson Scan")
        }
        #expect(USBTransport.notPluggedInMessage.contains("plugged in"))
    }

    @Test func drivesAScannerSessionOverFakePipes() async throws {
        // ScannerSession enters command mode through the transport: the ack comes back through the fake.
        // The model check (INFO) is off: this test is only about entering command mode.
        let pipes = FakePipes(replies: [Data([0x06])])
        let session = ScannerSession(transport: transport(over: pipes), requiredModel: nil)
        try await session.open()
        #expect(await pipes.events == [.write(Data([0x1C, 0x58])), .read(1)])
    }
}
#endif
