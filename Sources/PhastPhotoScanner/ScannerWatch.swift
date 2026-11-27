import Foundation
import PhastPhotoProtocol

/// What a ``ScannerWatch`` reports.
public enum WatchEvent: Sendable {
    /// The scanner is not ready (feeder empty, jam, ...); `message` is for people. Sent once per change,
    /// not on every poll.
    case waiting(String)
    /// The scanner could not be reached or opened (asleep, busy, wrong model). Sent once per change.
    case unreachable(String)
    /// Photos were loaded: a scan begins.
    case stackStarted
    /// A side finished, inside the scan loop (see ``ScannerSession/scan(_:onPage:)``).
    case page(ScannedPage)
    case stackFinished(ScanSummary)
}

/// Keeps scanning whenever photos are loaded (ports ffscan's `--watch`, `ff680w.py:752-766`, `app.py:716-722`):
/// every pass opens a **new session**, so the scanner is free for other clients between stacks; checks the
/// status; scans a ready stack; closes; sleeps ``pollInterval`` (2 s upstream); repeats until cancelled.
///
/// ```swift
/// let watch = ScannerWatch(settings: .photoDefaults) { NetworkTransport(endpoint: scanner.endpoint) }
/// try await watch.run { event in
///     if case .page(let page) = event { try spool.write(page) }
/// }
/// ```
///
/// On iOS the app must stay in the foreground; cancel the task (or use the session's
/// ``ScannerSession/stopAfterCurrentPrint()``) to end the watch.
public struct ScannerWatch: Sendable {
    public let settings: ScanSettings
    public let pollInterval: Duration
    public let makeTransport: @Sendable () -> any ScannerTransport

    public init(settings: ScanSettings, pollInterval: Duration = .seconds(2),
                makeTransport: @escaping @Sendable () -> any ScannerTransport) {
        self.settings = settings
        self.pollInterval = pollInterval
        self.makeTransport = makeTransport
    }

    /// Run until the task is cancelled (returns normally) or a scan fails (throws). Errors from opening the
    /// scanner or reading its status are reported as ``WatchEvent/unreachable(_:)`` and retried.
    public func run(onEvent: @Sendable (WatchEvent) async throws -> Void) async throws {
        var lastNotice: String?
        do {
            while true {
                try Task.checkCancellation()
                let session = ScannerSession(transport: makeTransport())
                var status: ScannerStatus?
                do {
                    try await session.open()
                    status = try await session.status()
                } catch is CancellationError {
                    await session.close()
                    throw CancellationError()
                } catch {
                    await session.close()
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    if lastNotice != message {
                        lastNotice = message
                        try await onEvent(.unreachable(message))
                    }
                    try await Task.sleep(for: pollInterval)
                    continue
                }

                // Reported outside the `do` above: an error thrown by `onEvent` is the caller's, not an
                // unreachable scanner, and must end the watch rather than be retried.
                var ready = false
                if let status {
                    if status.isReady {
                        ready = true
                        lastNotice = nil
                    } else if lastNotice != status.friendlyMessage {
                        lastNotice = status.friendlyMessage
                        do { try await onEvent(.waiting(status.friendlyMessage)) } catch {
                            await session.close()
                            throw error
                        }
                    }
                }

                if ready {
                    do {
                        try await onEvent(.stackStarted)
                        let summary = try await session.scan(settings) { try await onEvent(.page($0)) }
                        try await onEvent(.stackFinished(summary))
                    } catch {
                        await session.close()
                        throw error
                    }
                }
                await session.close()
                try await Task.sleep(for: pollInterval)
            }
        } catch is CancellationError {
            return
        }
    }
}
