import Foundation
import PhastPhotoProtocol

public enum ScannerError: Error, Sendable, LocalizedError {
    /// Another client holds the scanner. If nothing else is scanning, a previous session didn't release it:
    /// switch the scanner off and on.
    case busy(holder: String?)
    case connectionFailed(String)
    case connectionClosed
    case notConnected
    case timedOut
    case unexpectedPacket(type: UInt16)
    case didNotEnterCommandMode
    /// `STAT` reported an error before the scan: feeder empty, jam, ...
    case notReady(ScannerStatus)
    case settingsRejected(ESCI2Fields)
    /// An `#err` token during the scan.
    case scanFailed(ESCI2Fields)
    /// The scanner sent nothing for this long while a scan was running.
    case noData(Duration)
    /// A body read returned no bytes before the body was complete.
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .busy(let holder):
            "The scanner is in use by \(holder ?? "another client"). If nothing else is scanning, a previous "
                + "session didn't release it: switch the scanner off and on."
        case .connectionFailed(let reason): "Couldn't connect to the scanner: \(reason)."
        case .connectionClosed: "The scanner closed the connection."
        case .notConnected: "The scanner isn't connected."
        case .timedOut: "The scanner stopped answering."
        case .unexpectedPacket(let type): "Unexpected packet type 0x\(String(type, radix: 16, uppercase: true))."
        case .didNotEnterCommandMode: "The scanner did not enter ESC/I-2 mode."
        case .notReady(let status): "The scanner isn't ready: \(status)."
        case .settingsRejected(let fields): "The scanner rejected the settings: \(fields)."
        case .scanFailed(let fields): "Scan error: \(fields)."
        case .noData(let duration): "No data from the scanner for \(duration)."
        case .emptyReply: "The scanner sent an empty reply."
        }
    }
}
