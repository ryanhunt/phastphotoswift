import Foundation
import PhastPhotoProtocol

/// An ESC/I-2 session with a scanner: query it, and scan everything in the feeder.
///
/// ```swift
/// guard let scanner = try await ScannerDiscovery.firstScanner() else { return }
/// try await ScannerSession.withSession(transport: NetworkTransport(endpoint: scanner.endpoint)) { session in
///     print(try await session.info().productName ?? "?", try await session.status())
///     for try await page in session.pages(ScanSettings(resolution: 600)) {
///         try page.jpeg.write(to: folder.appending(path: "\(page.index)\(page.side.rawValue).jpg"))
///     }
/// }
/// ```
///
/// Open a new session for each stack of prints, so the scanner is free for other clients in between.
/// Always ``close()`` (or use ``withSession(transport:isolation:_:)``): a Wi-Fi session left locked keeps
/// other clients out until the scanner is switched off and on.
public actor ScannerSession {
    public nonisolated let transport: any ScannerTransport
    /// How long a running scan may go without any data before it fails.
    public nonisolated let pollTimeout: Duration
    public private(set) var isOpen = false

    public init(transport: any ScannerTransport, pollTimeout: Duration = .seconds(60)) {
        self.transport = transport
        self.pollTimeout = pollTimeout
    }

    /// Open a session, run `body`, and close the session whether or not `body` throws.
    @discardableResult
    public static func withSession<T>(
        transport: any ScannerTransport,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (ScannerSession) async throws -> T
    ) async throws -> T {
        let session = ScannerSession(transport: transport)
        try await session.open()
        do {
            let result = try await body(session)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }

    /// Connect, claim the scanner and switch it to ESC/I-2.
    public func open() async throws {
        guard !isOpen else { return }
        try await transport.open()
        do {
            let ack = try await transport.transfer([ESCI2.enterCommandMode], replyLength: 1)
            guard ack == Data([ESCI2.acknowledge]) else { throw ScannerError.didNotEnterCommandMode }
        } catch {
            await transport.close()
            throw error
        }
        isOpen = true
    }

    /// Leave ESC/I-2 mode and release the scanner.
    public func close() async {
        if isOpen {
            _ = try? await command(.finish)
            isOpen = false
        }
        await transport.close()
    }

    // MARK: - Commands

    /// Send a command (and parameter block); returns the reply header and the whole body.
    ///
    /// The scanner never sends more than was asked for, so the 64-byte header comes first and the body is
    /// pulled with further reads.
    public func command(_ command: ESCI2Command, parameters: Data = Data()) async throws -> (header: ESCI2ReplyHeader, body: Data) {
        guard isOpen else { throw ScannerError.notConnected }
        let request = command.requestHeader(parameterLength: parameters.count)
        let raw = try await transport.transfer(parameters.isEmpty ? [request] : [request, parameters],
                                               replyLength: ESCI2.replyHeaderLength)
        let header = try ESCI2ReplyHeader(raw)
        var body = Data(capacity: header.bodyLength)
        while body.count < header.bodyLength {
            let chunk = try await transport.transfer([], replyLength: header.bodyLength - body.count)
            guard !chunk.isEmpty else { throw ScannerError.emptyReply }
            body.append(chunk)
        }
        return (header, body)
    }

    private func query(_ command: ESCI2Command) async throws -> ESCI2Fields {
        ESCI2Fields(parsing: try await self.command(command).body)
    }

    public func info() async throws -> ScannerInfo { ScannerInfo(fields: try await query(.info)) }
    public func capabilities() async throws -> ESCI2Fields { try await query(.capabilities) }
    public func status() async throws -> ScannerStatus { ScannerStatus(fields: try await query(.status)) }

    // MARK: - Scanning

    /// Feed every print in the tray, calling `onPage` for each side as it finishes.
    ///
    /// `onPage` runs inside the scan loop, and the scanner stalls while it runs: hand slow work (cropping,
    /// writing files, uploads) to another task. If `onPage` throws or the task is cancelled, the scan is
    /// cancelled on the scanner (`CAN `) and the error is rethrown.
    @discardableResult
    public func scan(_ settings: ScanSettings, onPage: @Sendable (ScannedPage) async throws -> Void) async throws -> ScanSummary {
        try settings.validate()
        let status = try await status()
        guard status.isReady else { throw ScannerError.notReady(status) }

        var reply = try await command(.parameters, parameters: settings.parameterBlock(includingBlockSize: true))
        let blockSizeAccepted = settings.blockSize != nil && reply.header.parametersAccepted
        if !reply.header.parametersAccepted, settings.blockSize != nil {
            // firmware that rejects #BSZ: scan with 64 KB blocks
            reply = try await command(.parameters, parameters: settings.parameterBlock(includingBlockSize: false))
        }
        guard reply.header.parametersAccepted else { throw ScannerError.settingsRejected(reply.header.fields) }

        _ = try await command(.startTransfer)
        do {
            let pages = try await receivePages(duplex: settings.duplex, onPage: onPage)
            return ScanSummary(pageCount: pages, blockSizeAccepted: blockSizeAccepted)
        } catch {
            _ = try? await command(.cancel)
            throw error
        }
    }

    /// ``scan(_:onPage:)`` as a stream. Ending the iteration early cancels the scan.
    public nonisolated func pages(_ settings: ScanSettings) -> AsyncThrowingStream<ScannedPage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.scan(settings) { page in
                        if case .terminated = continuation.yield(page) { throw CancellationError() }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Poll `IMG ` until the transfer is finished. Never stop while it returns empty replies: stopping early
    /// aborts the page, the print still ejects, and the scanner then reports a jam.
    private func receivePages(duplex: Bool, onPage: @Sendable (ScannedPage) async throws -> Void) async throws -> Int {
        let clock = ContinuousClock()
        var index = 0
        var delivered = 0
        var parts: [ScannedPage.Side: Data] = [:]
        var stats: [ScannedPage.Side: ScannedPage.TransferStats] = [:]
        var lastData = clock.now

        while true {
            try Task.checkCancellation()
            let start = clock.now
            let (header, block) = try await command(.image)
            let spent = start.duration(to: clock.now)
            if header.isInvalidCommand { return delivered }  // INVD: transfer finished

            let fields = header.fields
            let side: ScannedPage.Side = fields["typ"].contains([.word("IMGB")]) ? .b : .a
            parts[side, default: Data()].append(block)
            if block.isEmpty {
                stats[side, default: .init()].waiting += spent
            } else {
                stats[side, default: .init()].blocks += 1
                stats[side, default: .init()].bytes += block.count
                stats[side, default: .init()].largestBlock = max(stats[side]?.largestBlock ?? 0, block.count)
                stats[side, default: .init()].transferring += spent
            }
            if fields.contains("err") { throw ScannerError.scanFailed(fields) }

            if let end = fields.first("pen"), end.count >= 2,
               let width = end[0].integerValue, let height = end[1].integerValue {
                let jpeg = try JPEGHeight.replacing(in: parts.removeValue(forKey: side) ?? Data(), with: height)
                let page = ScannedPage(index: index, side: side, width: width, height: height, jpeg: jpeg,
                                       stats: stats.removeValue(forKey: side) ?? .init())
                try await onPage(page)
                delivered += 1
                if side == .b || !duplex { index += 1 }
                if fields.first("lft") == [.integer(0)], parts.isEmpty { return delivered }
            }

            if !block.isEmpty || fields.contains("pst") || fields.contains("pen") {
                lastData = clock.now
            } else if lastData.duration(to: clock.now) > pollTimeout {
                throw ScannerError.noData(pollTimeout)
            } else {
                try await Task.sleep(for: transport.pollInterval)  // print still feeding, or block not encoded yet
            }
        }
    }
}
