#if os(macOS) || os(iOS)
import Foundation
import Testing

@testable import PhastPhotoScanner

/// The iPadOS USB client, without the driver: no test machine has the driver extension loaded, so these
/// cover the status mapping and what happens when the driver isn't there. Transfers through the driver
/// need an M-series iPad with the scanner.
/// `ScannerError` isn't Equatable; its descriptions differ for every case and message.
private func same(_ a: Error, _ b: ScannerError) -> Bool { a.localizedDescription == b.localizedDescription }

/// Expects `body` to throw `expected`.
private func expectThrows(_ expected: ScannerError, sourceLocation: SourceLocation = #_sourceLocation,
                          _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("expected \(expected)", sourceLocation: sourceLocation)
    } catch {
        #expect(same(error, expected), "\(error)", sourceLocation: sourceLocation)
    }
}

@Suite struct DriverKitPipesTests {
    /// A bundle ID no driver uses, so a stray driver on the test machine can't match.
    static let absent = "com.example.phastphoto.tests.no-such-driver"

    @Test(arguments: [
        (Int32(bitPattern: 0xE000_02D6), ScannerError.timedOut),  // kIOReturnTimeout
        (Int32(bitPattern: 0xE000_4051), ScannerError.timedOut),  // kIOUSBTransactionTimeout
        (Int32(bitPattern: 0xE000_02F0), ScannerError.connectionFailed(USBTransport.notPluggedInMessage)),  // not found
        (Int32(bitPattern: 0xE000_02E2), ScannerError.connectionFailed(DriverKitPipes.notPermittedMessage)),
        (Int32(bitPattern: 0xE000_02C1), ScannerError.connectionFailed(DriverKitPipes.notPermittedMessage)),
        (Int32(bitPattern: 0xE000_02C5), ScannerError.connectionFailed(USBTransport.interfaceInUseMessage)),
        (Int32(bitPattern: 0xE000_02D5), ScannerError.connectionFailed(USBTransport.interfaceInUseMessage)),  // busy
        (Int32(bitPattern: 0xE000_02C0), ScannerError.connectionFailed(DriverKitPipes.goneMessage)),  // no device
        (Int32(bitPattern: 0xE000_02D9), ScannerError.connectionFailed(DriverKitPipes.goneMessage)),  // not attached
        (Int32(bitPattern: 0xE000_02EB), ScannerError.connectionFailed(DriverKitPipes.goneMessage)),  // aborted
        (Int32(0x1000_0003), ScannerError.connectionFailed(DriverKitPipes.goneMessage)),  // dead connection
        (Int32(bitPattern: 0xE000_02C2), ScannerError.connectionFailed("USB driver error 0xE00002C2.")),  // other
    ])
    func statusesMapToScannerErrors(status: Int32, expected: ScannerError) {
        #expect(same(DriverKitPipes.error(for: status), expected))
    }

    /// From the pipes, a failure that could have several causes names the call and the raw status.
    @Test func failuresNameTheCallAndStatus() {
        #expect(same(DriverKitPipes.error(for: Int32(bitPattern: 0xE000_02EB), during: "write"),
                     .connectionFailed(DriverKitPipes.goneMessage + " (USB write: 0xE00002EB)")))
        #expect(same(DriverKitPipes.error(for: Int32(bitPattern: 0xE000_02C2), during: "read"),
                     .connectionFailed("USB driver error 0xE00002C2 (USB read: 0xE00002C2).")))
        #expect(same(DriverKitPipes.error(for: Int32(bitPattern: 0xE000_02D6), during: "read"), .timedOut))
    }

    @Test func overrunIsStaleData() {
        #expect(throws: USBStaleData.self) { try DriverKitPipes.check(Int32(bitPattern: 0xE000_02E8), during: "read") }
    }

    @Test func successIsNotAnError() throws {
        try DriverKitPipes.check(0)
        do {
            try DriverKitPipes.check(Int32(bitPattern: 0xE000_02D6))
            Issue.record("no error")
        } catch {
            #expect(same(error, .timedOut))
        }
    }

    @Test func noDriverMeansNotPresent() {
        #expect(!DriverKitPipes.isDriverPresent(serverName: Self.absent))
    }

    /// Opening without a driver fails at once with the "plug in / enable the driver" message.
    @Test func claimWithoutADriverFails() async {
        await expectThrows(.connectionFailed(USBTransport.notPluggedInMessage)) {
            _ = try await DriverKitPipes.claim(serverName: Self.absent, timeout: .seconds(1))
        }
    }

    /// After a reset the driver is matched again: reclaim waits for it, then gives up with the same message.
    @Test func reclaimWaitsForTheDriverThenGivesUp() async {
        let pipes = DriverKitPipes(serverName: Self.absent, timeout: .seconds(1), reappearTimeout: 0.6)
        let start = Date()
        await expectThrows(.connectionFailed(USBTransport.notPluggedInMessage)) {
            try await pipes.reclaim()
        }
        #expect(Date().timeIntervalSince(start) >= 0.5)
        await pipes.release()
    }

    /// Transfers without a connection fail instead of calling into nothing.
    @Test func transfersWithoutAConnectionFail() async {
        let pipes = DriverKitPipes(serverName: Self.absent, timeout: .seconds(1))
        await #expect(throws: ScannerError.self) { try await pipes.write(Data([1])) }
        await #expect(throws: ScannerError.self) { _ = try await pipes.read(maxLength: 64) }
        await expectThrows(.notConnected) { try await pipes.resetDevice() }
    }

    @Test func timeoutIsSentInMilliseconds() {
        #expect(DriverKitPipes(serverName: nil, timeout: .seconds(60)).timeoutMilliseconds == 60_000)
        #expect(DriverKitPipes(serverName: nil, timeout: .milliseconds(1500)).timeoutMilliseconds == 1500)
        #expect(DriverKitPipes(serverName: nil, timeout: .microseconds(10)).timeoutMilliseconds == 1)  // never 0 = wait for ever
    }
}
#endif
