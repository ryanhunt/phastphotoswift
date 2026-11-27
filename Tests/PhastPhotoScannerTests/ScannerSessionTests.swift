import Foundation
import os
import PhastPhotoProtocol
import Testing
@testable import PhastPhotoScanner

/// Collects pages from a `@Sendable` callback.
final class PageLog: Sendable {
    private let pages = OSAllocatedUnfairLock<[ScannedPage]>(initialState: [])
    func append(_ page: ScannedPage) { pages.withLock { $0.append(page) } }
    var all: [ScannedPage] { pages.withLock { $0 } }
}

struct TestFailure: Error {}

@Suite struct ScannerSessionTests {
    /// One print, both sides, the way the FF-680W sends it (docs/PROTOCOL.md §3).
    static func onePrintDuplex(_ a: Data, _ b: Data) -> [SimulatedScanner.Reply] {
        [
            .init(fields: ""),  // still feeding
            .init(fields: "#psti0002550d000i0010800#typIMGA", body: a.prefix(1000)),
            .init(fields: "#typIMGA", body: a.dropFirst(1000)),
            .init(fields: "#peni0002550i0001263#typIMGA"),
            .init(fields: "#psti0002550d000i0010800#typIMGB", body: b),
            .init(fields: "#peni0002550i0001200#lftd000#typIMGB"),
        ]
    }

    @Test func queriesInfoAndStatus() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.statusBody = Data("#ERRADF PE  ".utf8) }
        try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session async throws in
            #expect(try await session.info().productName == "FF-680W")
            #expect(try await session.status().isFeederEmpty)
            #expect(try await session.capabilities()["COL"] == [[.word("C024"), .word("M008")]])
        }
        #expect(await scanner.commands == ["INFO", "STAT", "CAPA", "FIN "])
        #expect(await scanner.closed)
    }

    @Test func duplexScan() async throws {
        let a = fakeScanJPEG(seed: 1), b = fakeScanJPEG(seed: 2)
        let scanner = SimulatedScanner()
        await scanner.configure {
            $0.imageReplies = Self.onePrintDuplex(a, b)
            $0.maxChunk = 256  // bodies arrive over several reads
        }
        let log = PageLog()
        let summary = try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session in
            try await session.scan(ScanSettings()) { log.append($0) }
        }

        let pages = log.all
        #expect(summary == ScanSummary(pageCount: 2, blockSizeAccepted: true))
        #expect(pages.map(\.side) == [.a, .b])
        #expect(pages.map(\.index) == [0, 0])
        #expect(pages.map(\.height) == [1263, 1200])
        #expect(pages.map(\.width) == [2550, 2550])
        #expect(pages.map { sofHeight($0.jpeg) } == [1263, 1200])
        #expect(pages[0].jpeg.count == a.count && pages[0].jpeg.suffix(100) == a.suffix(100))
        #expect(pages[1].jpeg.suffix(100) == b.suffix(100))
        #expect(pages[0].stats.blocks == 2 && pages[0].stats.bytes == a.count)

        #expect(await scanner.commands == ["INFO", "STAT", "PARA", "TRDT"] + Array(repeating: "IMG ", count: 6) + ["FIN "])
        #expect(await scanner.parameterBlocks == [ScanSettings().parameterBlock()])
    }

    @Test func pagesStream() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.imageReplies = Self.onePrintDuplex(fakeScanJPEG(), fakeScanJPEG()) }
        var sides: [ScannedPage.Side] = []
        try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session in
            for try await page in session.pages(ScanSettings()) { sides.append(page.side) }
        }
        #expect(sides == [.a, .b])
    }

    @Test func singleSidedCountsEveryPage() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure {
            $0.imageReplies = [
                .init(fields: "#psti0002550d000i0010800#typIMGA", body: fakeScanJPEG()),
                .init(fields: "#peni0002550i0001000#typIMGA"),
                .init(fields: "#psti0002550d000i0010800#typIMGA", body: fakeScanJPEG()),
                .init(fields: "#peni0002550i0001100#typIMGA"),
            ]  // then INVD: transfer finished
        }
        let log = PageLog()
        try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session in
            try await session.scan(ScanSettings(duplex: false)) { log.append($0) }
        }
        #expect(log.all.map(\.index) == [0, 1])
        #expect(log.all.map(\.side) == [.a, .a])
        #expect(await scanner.commands.suffix(2) == ["IMG ", "FIN "])  // the INVD poll, then FIN
    }

    @Test func retriesWithoutBlockSize() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure {
            $0.acceptsBlockSize = false
            $0.imageReplies = Self.onePrintDuplex(fakeScanJPEG(), fakeScanJPEG())
        }
        let summary = try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session in
            try await session.scan(ScanSettings()) { _ in }
        }
        #expect(!summary.blockSizeAccepted)
        let blocks = await scanner.parameterBlocks
        #expect(blocks == [ScanSettings().parameterBlock(), ScanSettings().parameterBlock(includingBlockSize: false)])
    }

    @Test func refusesToStartWhenFeederEmpty() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.statusBody = Data("#ERRADF PE  ".utf8) }
        await #expect {
            try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session in
                try await session.scan(ScanSettings()) { _ in }
            }
        } throws: { error in
            guard case ScannerError.notReady(let status) = error else { return false }
            return status.isFeederEmpty
        }
        #expect(await scanner.commands == ["INFO", "STAT", "FIN "])
    }

    @Test func scanErrorCancels() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure {
            $0.imageReplies = [.init(fields: "#psti0002550d000i0010800#typIMGA"), .init(fields: "#errADF PJ  #typIMGA")]
        }
        await #expect {
            try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session in
                try await session.scan(ScanSettings()) { _ in }
            }
        } throws: { error in
            guard case ScannerError.scanFailed = error else { return false }
            return true
        }
        #expect(await scanner.commands.suffix(2) == ["CAN ", "FIN "])
    }

    @Test func throwingHandlerCancels() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.imageReplies = Self.onePrintDuplex(fakeScanJPEG(), fakeScanJPEG()) }
        await #expect(throws: TestFailure.self) {
            try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session in
                try await session.scan(ScanSettings()) { _ in throw TestFailure() }
            }
        }
        #expect(await scanner.commands.suffix(2) == ["CAN ", "FIN "])
    }

    @Test func noDataTimesOut() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.feedsForever = true }
        let session = ScannerSession(transport: SimulatedTransport(scanner: scanner, pollInterval: .milliseconds(2)),
                                     pollTimeout: .milliseconds(30))
        try await session.open()
        await #expect {
            try await session.scan(ScanSettings()) { _ in }
        } throws: { error in
            guard case ScannerError.noData = error else { return false }
            return true
        }
        await session.close()
        #expect(await scanner.commands.suffix(2) == ["CAN ", "FIN "])
    }

    @Test func taskCancellationCancelsScan() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.feedsForever = true }
        let task = Task {
            try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner, pollInterval: .milliseconds(2))) {
                try await $0.scan(ScanSettings()) { _ in }
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await scanner.commands.suffix(2) == ["CAN ", "FIN "])
    }
}
