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
    /// A scan is running (or another exchange holds the wire): the session handles one exchange at a time,
    /// and a scan owns it until it ends.
    case sessionBusy
    /// The device answered `INFO` with another model (or none): this package drives the FF-680W only.
    case unsupportedModel(String?)

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
        case .sessionBusy: "A scan is running on this session; wait for it to finish (or stop it) first."
        case .unsupportedModel(let model):
            "This is \(model.map { "a \($0)" } ?? "an unknown scanner"), not an FF-680W: only the Epson FastFoto FF-680W is supported."
        }
    }
}
