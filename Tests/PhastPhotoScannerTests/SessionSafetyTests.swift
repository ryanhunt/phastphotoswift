import Foundation
import Network
import os
import PhastPhotoProtocol
import Testing
@testable import PhastPhotoScanner

/// Collects values from `@Sendable` callbacks.
final class EventLog<T: Sendable>: Sendable {
    private let items = OSAllocatedUnfairLock<[T]>(initialState: [])
    func append(_ item: T) { items.withLock { $0.append(item) } }
    var all: [T] { items.withLock { $0 } }
}

/// A transport whose `open` always fails, like a scanner that is switched off.
struct UnreachableTransport: ScannerTransport {
    var pollInterval: Duration { .zero }
    func open() async throws { throw ScannerError.connectionFailed("unreachable (test)") }
    func transfer(_ chunks: [Data], replyLength: Int) async throws -> Data { throw ScannerError.notConnected }
    func close() async {}
}

/// Exchanges must never interleave, and a scan must end with `CAN ` before `FIN `
/// (a reviewer proved both failures against the first version of `ScannerSession`).
@Suite(.timeLimit(.minutes(2))) struct SessionSerialisationTests {
    /// Feeds one A side's first blocks, then keeps polling: a print that never finishes.
    static func stuckAfterFirstPage() -> [SimulatedScanner.Reply] {
        Array(ScannerSessionTests.onePrintDuplex(fakeScanJPEG(), fakeScanJPEG()).prefix(4))
    }

    @Test func breakingOutOfPagesEndsWithCANThenFIN() async throws {
        for _ in 0 ..< 50 {  // a race: run it many times
            let scanner = SimulatedScanner()
            await scanner.configure {
                $0.imageReplies = Self.stuckAfterFirstPage()
                $0.feedsForever = true
                $0.maxChunk = 256
            }
            try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner, pollInterval: .milliseconds(1))) { session in
                for try await _ in session.pages(ScanSettings()) { break }
            }
            let log = await scanner.commands
            #expect(log.suffix(2) == ["CAN ", "FIN "])
            #expect(log.filter { $0 == "FIN " }.count == 1)
            #expect(log.filter { $0 == "CAN " }.count == 1)
            if let lastIMG = log.lastIndex(of: "IMG "), let can = log.firstIndex(of: "CAN ") {
                #expect(lastIMG < can, "IMG polls after CAN/FIN")
            }
        }
    }

    @Test func statusDuringScanNeverReachesTheWireMidBody() async throws {
        for _ in 0 ..< 50 {
            let scanner = SimulatedScanner()
            await scanner.configure {
                // a 2 KB body read 16 bytes at a time: many awaits between the IMG header and the end of its body
                $0.imageReplies = [.init(fields: "#psti0002550d000i0010800#typIMGA", body: fakeScanJPEG(filler: 2000))]
                $0.feedsForever = true
                $0.maxChunk = 16
            }
            let session = ScannerSession(transport: SimulatedTransport(scanner: scanner, pollInterval: .milliseconds(1)))
            try await session.open()
            let scan = Task { try await session.scan(ScanSettings()) { _ in } }
            let outcomes = await withTaskGroup(of: String.self) { group in
                for _ in 0 ..< 30 {
                    group.addTask {
                        do {
                            _ = try await session.status()
                            return "ok"
                        } catch ScannerError.sessionBusy {
                            return "busy"
                        } catch {
                            return "unexpected: \(error)"
                        }
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            #expect(outcomes.allSatisfy { $0 == "ok" || $0 == "busy" }, "\(outcomes)")
            scan.cancel()
            _ = try? await scan.value
            await session.close()
            let log = await scanner.commands
            // CAN only if the transfer had been started when the scan was cancelled
            #expect(log.last == "FIN ")
            if log.contains("TRDT") { #expect(log.suffix(2) == ["CAN ", "FIN "]) }
        }
    }

    @Test func queriesDuringScanThrowSessionBusy() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.feedsForever = true }
        let session = ScannerSession(transport: SimulatedTransport(scanner: scanner, pollInterval: .milliseconds(1)))
        try await session.open()
        let scan = Task { try await session.scan(ScanSettings()) { _ in } }
        while !(await session.isScanning) { try await Task.sleep(for: .milliseconds(1)) }
        await #expect(throws: ScannerError.self) { _ = try await session.status() }
        await #expect(throws: ScannerError.self) { _ = try await session.capabilities() }
        await #expect(throws: ScannerError.self) { _ = try await session.command(.status) }
        await #expect(throws: ScannerError.self) { try await session.scan(ScanSettings()) { _ in } }
        do {
            _ = try await session.status()
        } catch ScannerError.sessionBusy {}
        scan.cancel()
        _ = try? await scan.value
        await session.close()
    }

    @Test func concurrentQueriesAreSerialised() async throws {
        for _ in 0 ..< 50 {
            let scanner = SimulatedScanner()
            await scanner.configure {
                $0.statusBody = Data("#ERRADF PE  ".utf8)
                $0.maxChunk = 3
            }
            try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session async throws in
                let results = try await withThrowingTaskGroup(of: Bool.self) { group in
                    for i in 0 ..< 20 {
                        group.addTask {
                            if i.isMultiple(of: 2) { return try await session.status().isFeederEmpty }
                            return try await session.capabilities()["COL"].count == 1
                        }
                    }
                    return try await group.reduce(into: []) { $0.append($1) }
                }
                #expect(results.count == 20 && results.allSatisfy { $0 })
            }
        }
    }

    @Test func closeCancelsAndAwaitsARunningScan() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.feedsForever = true }
        let session = ScannerSession(transport: SimulatedTransport(scanner: scanner, pollInterval: .milliseconds(1)))
        try await session.open()
        let scan = Task { try await session.scan(ScanSettings()) { _ in } }
        while !(await session.isScanning) { try await Task.sleep(for: .milliseconds(1)) }
        await session.close()
        #expect(!(await session.isScanning))
        await #expect(throws: CancellationError.self) { try await scan.value }
        #expect(await scanner.commands.suffix(2) == ["CAN ", "FIN "])
        #expect(await scanner.closed)
    }
}

@Suite struct GracefulStopTests {
    /// Two prints: A then B each, as the scanner sends them; only the last B carries `#lft`.
    static func twoPrints() -> [SimulatedScanner.Reply] {
        func side(_ typ: String, last: Bool = false) -> [SimulatedScanner.Reply] {
            [.init(fields: "#psti0002550d000i0010800#typIMG\(typ)", body: fakeScanJPEG()),
             .init(fields: "#peni0002550i0001200\(last ? "#lftd000" : "")#typIMG\(typ)")]
        }
        return side("A") + side("B") + side("A") + side("B", last: true)
    }

    @Test func stopsAfterTheCurrentPrintAndCancels() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.imageReplies = Self.twoPrints() }
        let log = PageLog()
        let session = ScannerSession(transport: SimulatedTransport(scanner: scanner))
        try await session.open()
        let summary = try await session.scan(ScanSettings()) { page in
            log.append(page)
            if page.index == 0, page.side == .a { await session.stopAfterCurrentPrint() }  // during the first print
        }
        await session.close()
        #expect(log.all.map(\.side) == [.a, .b])  // print 0 finished through its last #pen, print 1 never started
        #expect(summary.stoppedEarly && summary.pageCount == 2)
        let commands = await scanner.commands
        #expect(commands.filter { $0 == "IMG " }.count == 4)
        #expect(commands.suffix(2) == ["CAN ", "FIN "])
    }

    @Test func stopRequestedOnTheLastSideStopsRightThere() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.imageReplies = Self.twoPrints() }
        let log = PageLog()
        let session = ScannerSession(transport: SimulatedTransport(scanner: scanner))
        try await session.open()
        let summary = try await session.scan(ScanSettings()) { page in
            log.append(page)
            if page.index == 0, page.side == .b { await session.stopAfterCurrentPrint() }
        }
        await session.close()
        #expect(log.all.count == 2 && summary.stoppedEarly)
    }

    @Test func withoutAStopRequestEverythingScans() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.imageReplies = Self.twoPrints() }
        let log = PageLog()
        let summary = try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session async throws in
            try await session.scan(ScanSettings()) { log.append($0) }
        }
        #expect(log.all.count == 4 && !summary.stoppedEarly)
        #expect(await scanner.commands.contains("CAN ") == false)
    }

    @Test func nothingToStopWhenIdle() async throws {
        let scanner = SimulatedScanner()
        let session = ScannerSession(transport: SimulatedTransport(scanner: scanner))
        try await session.open()
        #expect(await session.stopAfterCurrentPrint() == false)
        await session.close()
    }

    @Test func hardCancelSendsCANBeforeFIN() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.feedsForever = true }
        let session = ScannerSession(transport: SimulatedTransport(scanner: scanner, pollInterval: .milliseconds(1)))
        try await session.open()
        let scan = Task { try await session.scan(ScanSettings()) { _ in } }
        while !(await session.isScanning) { try await Task.sleep(for: .milliseconds(1)) }
        await session.cancelScan()
        await #expect(throws: CancellationError.self) { try await scan.value }
        await session.close()
        #expect(await scanner.commands.suffix(2) == ["CAN ", "FIN "])
    }
}

@Suite struct ModelCheckTests {
    @Test func rejectsAnotherModelAndReleasesTheScanner() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.infoBody = Data("#PRDh007DS-780N".utf8) + Data([0]) }
        await #expect {
            try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { _ in }
        } throws: { error in
            guard case ScannerError.unsupportedModel(let model) = error else { return false }
            return model == "DS-780N" && (error as? LocalizedError)?.errorDescription?.contains("FF-680W") == true
        }
        #expect(await scanner.commands == ["INFO", "FIN "])
        #expect(await scanner.closed)
    }

    @Test func rejectsAnAnswerWithoutAModel() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.infoBody = Data("#ADFTYPEFEED".utf8) }
        await #expect(throws: ScannerError.self) {
            try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { _ in }
        }
    }

    @Test func checkCanBeSwitchedOff() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.infoBody = Data("#PRDh007DS-780N".utf8) + Data([0]) }
        try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner), requiredModel: nil) { session async throws in
            #expect(try await session.info().productName == "DS-780N")  // asks the scanner: nothing cached
        }
        #expect(await scanner.commands == ["INFO", "FIN "])
    }

    @Test func infoIsReadOnceWhenChecked() async throws {
        let scanner = SimulatedScanner()
        try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session async throws in
            #expect(try await session.info().productName == "FF-680W")
            #expect(try await session.info().productName == "FF-680W")
        }
        #expect(await scanner.commands == ["INFO", "FIN "])
    }
}

@Suite struct DiscoveryFilterTests {
    func scanner(_ name: String, model: String?) -> DiscoveredScanner {
        DiscoveredScanner(name: name, endpoint: .hostPort(host: "192.0.2.10", port: 1865),
                          txtRecord: model.map { ["mdl": $0] } ?? [:])
    }

    @Test func listsOnlyTheFF680WByDefault() {
        let ff = scanner("EPSON FF-680W", model: "FF-680W")
        let other = scanner("EPSON ES-400", model: "ES-400")
        let noTXT = scanner("EPSON FF-680W", model: nil)
        let notEpson = scanner("Brother", model: "DCP")
        let all = [ff, other, noTXT, notEpson]
        #expect(all.filter(ScannerDiscovery.ModelFilter.ff680w.matches) == [ff])
        #expect(all.filter(ScannerDiscovery.ModelFilter.epson.matches) == [ff, other, noTXT])
        #expect(all.filter(ScannerDiscovery.ModelFilter.all.matches) == all)
    }

    @Test func localNetworkRefusalIsItsOwnError() {
        // NWBrowser reports a refused permission as .waiting(.dns(kDNSServiceErr_PolicyDenied))
        let denied = DiscoveryError.make(from: .dns(-65570), waiting: true)
        guard case .localNetworkDenied = denied else {
            Issue.record("expected localNetworkDenied, got \(denied)")
            return
        }
        #expect(denied.errorDescription?.contains("Local Network") == true)
        guard case .waiting = DiscoveryError.make(from: .posix(.ENETDOWN), waiting: true) else {
            Issue.record("expected a plain waiting error")
            return
        }
        guard case .failed = DiscoveryError.make(from: .dns(-65570 + 1), waiting: false) else {
            Issue.record("expected failed")
            return
        }
    }
}
