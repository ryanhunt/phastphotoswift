import Foundation
import PhastPhotoProtocol
import Testing
@testable import PhastPhotoScanner

func page(_ index: Int, _ side: ScannedPage.Side, seed: UInt8 = 0) -> ScannedPage {
    ScannedPage(index: index, side: side, width: 2550, height: 1200, jpeg: fakeScanJPEG(filler: 100, seed: seed))
}

@Suite struct PrintAssemblerTests {
    @Test func duplexPairsAWithBByIndex() {
        var assembler = PrintAssembler(mode: .both)
        #expect(assembler.add(page(0, .a)).isEmpty)  // A waits for its B
        let first = assembler.add(page(0, .b))
        #expect(first.count == 1)
        #expect(first[0].picture?.side == .b && first[0].back?.side == .a && first[0].index == 0)
        #expect(first[0].kept.map(\.side) == [.a, .b])  // scan order, both kept

        #expect(assembler.add(page(1, .a)).isEmpty)
        let second = assembler.add(page(1, .b))
        #expect(second.map(\.index) == [1])
        #expect(assembler.finish().isEmpty)
    }

    @Test func pictureModeKeepsTheBackOnlyForReading() {
        var assembler = PrintAssembler(mode: .picture)
        _ = assembler.add(page(0, .a, seed: 1))
        let prints = assembler.add(page(0, .b, seed: 2))
        #expect(prints[0].back?.jpeg == page(0, .a, seed: 1).jpeg)  // handed to the picture's processing
        #expect(prints[0].kept.map(\.side) == [.b])  // but not saved
    }

    @Test func backModeIsSingleSidedA() {
        var assembler = PrintAssembler(mode: .back)
        let prints = assembler.add(page(0, .a))
        #expect(prints.count == 1 && prints[0].picture == nil && prints[0].back?.side == .a)
        #expect(prints[0].kept.map(\.side) == [.a])
        #expect(assembler.add(page(1, .a)).map(\.index) == [1])
    }

    @Test func fastModeRelabelsAasB() {
        var assembler = PrintAssembler(mode: .fast)
        let prints = assembler.add(page(0, .a, seed: 7))
        #expect(prints.count == 1)
        #expect(prints[0].picture?.side == .b)  // relabelled
        #expect(prints[0].picture?.jpeg == page(0, .a, seed: 7).jpeg)
        #expect(prints[0].back == nil)
        #expect(prints[0].kept.map(\.side) == [.b])
    }

    @Test func aBackWithoutItsPictureIsFlushed() {
        var assembler = PrintAssembler(mode: .both)
        _ = assembler.add(page(0, .a))
        let next = assembler.add(page(1, .a))  // print 0's B never came
        #expect(next.count == 1 && next[0].index == 0 && next[0].picture == nil && next[0].back != nil)
        let rest = assembler.finish()
        #expect(rest.map(\.index) == [1])
        #expect(assembler.finish().isEmpty)
    }

    @Test func assemblesAScanFromTheSimulator() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure {
            $0.imageReplies = GracefulStopTests.twoPrints()
        }
        let log = PageLog()
        try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session in
            try await session.scan(ScanSettings()) { log.append($0) }
        }
        var assembler = PrintAssembler(mode: .picture)
        let prints = log.all.flatMap { assembler.add($0) }
        #expect(prints.map(\.index) == [0, 1])
        #expect(prints.allSatisfy { $0.picture?.side == .b && $0.back?.side == .a })
    }
}

@Suite struct RawSpoolTests {
    static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "phastphoto-spool-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func namesFollowFfscan() {
        #expect(RawSpool.pageName(prefix: "p", number: 7, side: .b) == "p_007.jpg")
        #expect(RawSpool.pageName(prefix: "p", number: 7, side: .a) == "p_007_back.jpg")
        #expect(RawSpool.pageName(prefix: "p", number: 1234, side: .b) == "p_1234.jpg")
    }

    @Test func writesBytesUntouchedAndNeverOverwrites() throws {
        let dir = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = RawSpool(directory: dir, prefix: "stack", firstNumber: 5, stamp: "20260101-120000")
        let a = try spool.write(page(0, .a, seed: 1))
        let b = try spool.write(page(0, .b, seed: 2))
        let again = try spool.write(page(0, .b, seed: 3))  // same name: must not replace
        #expect(a.name == "stack_005_back.jpg" && b.name == "stack_005.jpg")
        #expect(a.url.lastPathComponent == "20260101-120000_stack_005_back.jpg")
        #expect(try Data(contentsOf: a.url) == page(0, .a, seed: 1).jpeg)
        #expect(try Data(contentsOf: b.url) == page(0, .b, seed: 2).jpeg)
        #expect(again.url != b.url)
        #expect(try Data(contentsOf: b.url) == page(0, .b, seed: 2).jpeg)
        #expect(b.byteCount == page(0, .b, seed: 2).jpeg.count)
    }

    @Test func fastModeNamesTheSideAsB() throws {
        let dir = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spooled = try RawSpool(directory: dir, mode: .fast, stamp: "s").write(page(0, .a))
        #expect(spooled.side == .b && spooled.name == "scan_001.jpg")
    }

    @Test func eachPageIsOnDiskWhenItIsYielded() async throws {
        let dir = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scanner = SimulatedScanner()
        await scanner.configure { $0.imageReplies = GracefulStopTests.twoPrints() }
        let spool = RawSpool(directory: dir, stamp: "t")
        var seen: [String] = []
        try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner)) { session async throws in
            for try await spooled in session.spooledPages(ScanSettings(), to: spool) {
                #expect(FileManager.default.fileExists(atPath: spooled.url.path))
                seen.append(spooled.name)
            }
        }
        #expect(seen == ["scan_001_back.jpg", "scan_001.jpg", "scan_002_back.jpg", "scan_002.jpg"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 4)
    }

    @Test func breakingOutOfTheSpoolStreamStillEndsWithCANThenFIN() async throws {
        let dir = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scanner = SimulatedScanner()
        await scanner.configure {
            $0.imageReplies = SessionSerialisationTests.stuckAfterFirstPage()
            $0.feedsForever = true
        }
        try await ScannerSession.withSession(transport: SimulatedTransport(scanner: scanner, pollInterval: .milliseconds(1))) { session in
            for try await _ in session.spooledPages(ScanSettings(), to: RawSpool(directory: dir)) { break }
        }
        #expect(await scanner.commands.suffix(2) == ["CAN ", "FIN "])
    }
}

@Suite(.timeLimit(.minutes(1))) struct ScannerWatchTests {
    @Test func waitsOncePerStatusThenScansTheStackWithNewSessions() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.statusBody = Data("#ERRADF PE  ".utf8) }
        let events = EventLog<String>()
        let watch = ScannerWatch(settings: ScanSettings(), pollInterval: .milliseconds(3)) {
            SimulatedTransport(scanner: scanner)
        }
        let loader = Task {  // someone loads photos after a while
            try await Task.sleep(for: .milliseconds(80))
            await scanner.configure {
                $0.statusBody = Data()
                $0.imageReplies = GracefulStopTests.twoPrints()
            }
        }
        try await watch.run { event in
            switch event {
            case .waiting(let text): events.append("waiting: \(text)")
            case .unreachable(let text): events.append("unreachable: \(text)")
            case .stackStarted: events.append("started")
            case .page(let page): events.append("page \(page.index)\(page.side.rawValue)")
            case .stackFinished(let summary):
                events.append("finished \(summary.pageCount)")
                throw CancellationError()  // end the watch
            }
        }
        _ = try await loader.value

        #expect(events.all == [
            "waiting: Feeder is empty: load photos face up.",  // once, however many polls
            "started", "page 0A", "page 0B", "page 1A", "page 1B", "finished 4",
        ])
        let log = await scanner.commands
        #expect(log.filter { $0 == "STAT" }.count >= 3)  // it polled
        #expect(log.filter { $0 == "INFO" }.count == log.filter { $0 == "FIN " }.count)  // a new session each time
        #expect(log.filter { $0 == "FIN " }.count >= 4)
        #expect(await scanner.closed)
    }

    @Test func reportsUnreachableOnceAndKeepsTrying() async throws {
        let events = EventLog<String>()
        let watch = ScannerWatch(settings: ScanSettings(), pollInterval: .milliseconds(2)) { UnreachableTransport() }
        let task = Task {
            try await watch.run { event in
                if case .unreachable(let text) = event { events.append(text) } else { events.append("other") }
            }
        }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        try await task.value  // cancelling ends the watch normally
        #expect(events.all.count == 1)
        #expect(events.all.first?.contains("unreachable (test)") == true)
    }

    @Test func aFailedScanEndsTheWatchAfterCancelling() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure {
            $0.imageReplies = [.init(fields: "#psti0002550d000i0010800#typIMGA"), .init(fields: "#errADF PJ  #typIMGA")]
        }
        let watch = ScannerWatch(settings: ScanSettings(), pollInterval: .milliseconds(2)) { SimulatedTransport(scanner: scanner) }
        await #expect(throws: ScannerError.self) { try await watch.run { _ in } }
        #expect(await scanner.commands.suffix(2) == ["CAN ", "FIN "])
    }

    struct CallbackFailure: Error {}

    @Test func anErrorFromTheCallbackEndsTheWatchInsteadOfBeingRetried() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.statusBody = Data("#ERRADF PE  ".utf8) }
        let calls = EventLog<Int>()
        let watch = ScannerWatch(settings: ScanSettings(), pollInterval: .milliseconds(2)) { SimulatedTransport(scanner: scanner) }
        await #expect(throws: CallbackFailure.self) {
            try await watch.run { _ in
                calls.append(1)
                throw CallbackFailure()
            }
        }
        #expect(calls.all.count == 1)
        #expect(await scanner.commands.suffix(1) == ["FIN "])
        #expect(await scanner.closed)
    }

    @Test func friendlyTextForJam() async throws {
        let scanner = SimulatedScanner()
        await scanner.configure { $0.statusBody = Data("#ERRADF PJ  ".utf8) }
        let events = EventLog<String>()
        let watch = ScannerWatch(settings: ScanSettings(), pollInterval: .milliseconds(2)) { SimulatedTransport(scanner: scanner) }
        try await watch.run { event in
            if case .waiting(let text) = event {
                events.append(text)
                throw CancellationError()
            }
        }
        #expect(events.all == ["Paper jam: open the cover, remove the photo, close the cover."])
    }
}
