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
/// Always ``close()`` (or use ``withSession(transport:requiredModel:isolation:_:)``): a Wi-Fi session left
/// locked keeps other clients out until the scanner is switched off and on.
///
/// **One exchange at a time.** A command and its whole reply body stay together on the wire. While a scan
/// runs it owns the session: ``command(_:parameters:)``, ``status()`` and the other queries throw
/// ``ScannerError/sessionBusy``. ``close()`` cancels a running scan (`CAN `), waits for it to end, and only
/// then sends `FIN `.
///
/// **On iOS a scan needs the app in the foreground.** The scanner is driven by polling over a socket the
/// system suspends in the background; a print stopped mid-page jams the scanner. Keep the screen awake
/// while scanning and use ``stopAfterCurrentPrint()`` rather than a hard cancel when you can.
public actor ScannerSession {
    /// The only model this package drives.
    public static let supportedModel = "FF-680W"

    public nonisolated let transport: any ScannerTransport
    /// How long a running scan may go without any data before it fails.
    public nonisolated let pollTimeout: Duration
    /// The `INFO` `#PRD` the scanner must report after ``open()``; `nil` skips the check.
    public nonisolated let requiredModel: String?
    public private(set) var isOpen = false
    /// Whether a scan owns the session. Other commands throw ``ScannerError/sessionBusy`` meanwhile.
    public private(set) var isScanning = false

    private var cachedInfo: ScannerInfo?
    private var stopRequested = false
    private var abortRequested = false
    private var scanEndWaiters: [CheckedContinuation<Void, Never>] = []
    private var wireBusy = false
    private var wireWaiters: [CheckedContinuation<Void, Never>] = []

    public init(transport: any ScannerTransport, pollTimeout: Duration = .seconds(60),
                requiredModel: String? = ScannerSession.supportedModel) {
        self.transport = transport
        self.pollTimeout = pollTimeout
        self.requiredModel = requiredModel
    }

    /// Open a session, run `body`, and close the session whether or not `body` throws.
    ///
    /// ``close()`` waits for a scan still running (say, after breaking out of ``pages(_:)``), so the scanner
    /// always sees `CAN ` before `FIN `.
    @discardableResult
    public static func withSession<T>(
        transport: any ScannerTransport,
        requiredModel: String? = ScannerSession.supportedModel,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (ScannerSession) async throws -> T
    ) async throws -> T {
        let session = ScannerSession(transport: transport, requiredModel: requiredModel)
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

    /// Connect, claim the scanner, switch it to ESC/I-2, and check that it is an FF-680W (`INFO` `#PRD`;
    /// throws ``ScannerError/unsupportedModel(_:)`` and releases the scanner otherwise).
    public func open() async throws {
        guard !isOpen else { return }
        try await transport.open()
        do {
            let ack = try await transport.transfer([ESCI2.enterCommandMode], replyLength: 1)
            guard ack == Data([ESCI2.acknowledge]) else { throw ScannerError.didNotEnterCommandMode }
            isOpen = true
            if let requiredModel {
                let info = ScannerInfo(fields: ESCI2Fields(parsing: try await exchange(.info).body))
                guard info.productName == requiredModel else { throw ScannerError.unsupportedModel(info.productName) }
                cachedInfo = info
            }
        } catch {
            if isOpen { _ = try? await exchange(.finish) }
            isOpen = false
            await transport.close()
            throw error
        }
    }

    /// Leave ESC/I-2 mode and release the scanner. A running scan is cancelled first (`CAN `) and awaited.
    public func close() async {
        if isScanning {
            abortRequested = true
            await withCheckedContinuation { scanEndWaiters.append($0) }
        }
        if isOpen {
            _ = try? await exchange(.finish)
            isOpen = false
        }
        cachedInfo = nil
        await transport.close()
    }

    // MARK: - Commands

    /// Send a command (and parameter block); returns the reply header and the whole body.
    ///
    /// One exchange (header and whole body) is on the wire at a time: concurrent callers queue. While a scan
    /// is running this throws ``ScannerError/sessionBusy``.
    public func command(_ command: ESCI2Command, parameters: Data = Data()) async throws -> (header: ESCI2ReplyHeader, body: Data) {
        guard !isScanning else { throw ScannerError.sessionBusy }
        return try await exchange(command, parameters: parameters, allowDuringScan: false)
    }

    /// The scanner never sends more than was asked for, so the 64-byte header comes first and the body is
    /// pulled with further reads. Holds the wire until the body is complete: another command in between
    /// would hit a scanner with an unread body (and a real one stops answering).
    private func exchange(
        _ command: ESCI2Command, parameters: Data = Data(), allowDuringScan: Bool = true
    ) async throws -> (header: ESCI2ReplyHeader, body: Data) {
        await acquireWire()
        defer { releaseWire() }
        if !allowDuringScan, isScanning { throw ScannerError.sessionBusy }  // a scan began while this waited
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

    private func acquireWire() async {
        if !wireBusy {
            wireBusy = true
            return
        }
        await withCheckedContinuation { wireWaiters.append($0) }  // the wire passes straight to this waiter
    }

    private func releaseWire() {
        if wireWaiters.isEmpty {
            wireBusy = false
        } else {
            wireWaiters.removeFirst().resume()
        }
    }

    private func query(_ command: ESCI2Command) async throws -> ESCI2Fields {
        guard !isScanning else { throw ScannerError.sessionBusy }
        return ESCI2Fields(parsing: try await exchange(command, allowDuringScan: false).body)
    }

    /// The scanner's `INFO`; read once after ``open()`` when ``requiredModel`` is set.
    public func info() async throws -> ScannerInfo {
        if let cachedInfo { return cachedInfo }
        return ScannerInfo(fields: try await query(.info))
    }

    public func capabilities() async throws -> ESCI2Fields { try await query(.capabilities) }
    public func status() async throws -> ScannerStatus { ScannerStatus(fields: try await query(.status)) }

    // MARK: - Scanning

    /// Feed every print in the tray, calling `onPage` for each side as it finishes.
    ///
    /// `onPage` runs inside the scan loop, and the scanner stalls while it runs: hand slow work (cropping,
    /// writing files, uploads) to another task. If `onPage` throws or the task is cancelled, the scan is
    /// cancelled on the scanner (`CAN `) and the error is rethrown; that is a hard cancel, and quitting
    /// mid-page can jam the scanner. To stop cleanly call ``stopAfterCurrentPrint()``.
    ///
    /// Throws ``ScannerError/sessionBusy`` if a scan is already running on this session.
    @discardableResult
    public func scan(_ settings: ScanSettings, onPage: @Sendable (ScannedPage) async throws -> Void) async throws -> ScanSummary {
        guard isOpen else { throw ScannerError.notConnected }
        guard !isScanning else { throw ScannerError.sessionBusy }
        try settings.validate()
        isScanning = true
        stopRequested = false
        abortRequested = false
        defer { endScan() }

        try checkAbort()
        let status = ScannerStatus(fields: ESCI2Fields(parsing: try await exchange(.status).body))
        guard status.isReady else { throw ScannerError.notReady(status) }

        var reply = try await exchange(.parameters, parameters: settings.parameterBlock(includingBlockSize: true))
        let blockSizeAccepted = settings.blockSize != nil && reply.header.parametersAccepted
        if !reply.header.parametersAccepted, settings.blockSize != nil {
            // firmware that rejects #BSZ: scan with 64 KB blocks
            reply = try await exchange(.parameters, parameters: settings.parameterBlock(includingBlockSize: false))
        }
        guard reply.header.parametersAccepted else { throw ScannerError.settingsRejected(reply.header.fields) }

        try checkAbort()
        _ = try await exchange(.startTransfer)
        do {
            let result = try await receivePages(duplex: settings.duplex, onPage: onPage)
            return ScanSummary(pageCount: result.delivered, blockSizeAccepted: blockSizeAccepted, stoppedEarly: result.stopped)
        } catch {
            _ = try? await exchange(.cancel)
            throw error
        }
    }

    /// Ask the running scan to stop once the print that is feeding has been delivered through the `#pen` of
    /// its last side, then send `CAN `. ``scan(_:onPage:)`` then returns normally with
    /// ``ScanSummary/stoppedEarly`` set. Returns whether a scan was running.
    ///
    /// Prefer this to cancelling the task: a print stopped mid-page jams the scanner (ffscan's own app only
    /// cancels between pages).
    @discardableResult
    public func stopAfterCurrentPrint() -> Bool {
        guard isScanning else { return false }
        stopRequested = true
        return true
    }

    /// Hard cancel: abandon the scan at the next poll and send `CAN ` (the same as cancelling the task).
    public func cancelScan() {
        if isScanning { abortRequested = true }
    }

    /// ``scan(_:onPage:)`` as a stream. Ending the iteration early cancels the scan; ``close()`` (and so
    /// ``withSession(transport:requiredModel:isolation:_:)``) then waits for it to send `CAN ` before `FIN `.
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

    private func checkAbort() throws {
        try Task.checkCancellation()
        if abortRequested { throw CancellationError() }
    }

    private func endScan() {
        isScanning = false
        stopRequested = false
        abortRequested = false
        let waiters = scanEndWaiters
        scanEndWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Poll `IMG ` until the transfer is finished. Never stop while it returns empty replies: stopping early
    /// aborts the page, the print still ejects, and the scanner then reports a jam.
    private func receivePages(
        duplex: Bool, onPage: @Sendable (ScannedPage) async throws -> Void
    ) async throws -> (delivered: Int, stopped: Bool) {
        let clock = ContinuousClock()
        var index = 0
        var delivered = 0
        var parts: [ScannedPage.Side: Data] = [:]
        var stats: [ScannedPage.Side: ScannedPage.TransferStats] = [:]
        var lastData = clock.now

        while true {
            try checkAbort()
            let start = clock.now
            let (header, block) = try await exchange(.image)
            let spent = start.duration(to: clock.now)
            if header.isInvalidCommand { return (delivered, false) }  // INVD: transfer finished

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
                let printComplete = side == .b || !duplex
                if printComplete { index += 1 }
                if fields.first("lft") == [.integer(0)], parts.isEmpty { return (delivered, false) }
                if stopRequested, printComplete, parts.isEmpty {
                    _ = try? await exchange(.cancel)  // between prints: the scanner is not mid-page
                    return (delivered, true)
                }
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
