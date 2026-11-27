import Foundation

/// Malformed data on the wire.
public enum ProtocolError: Error, Hashable, Sendable, CustomStringConvertible {
    case badPacketHeader(Data)
    case truncatedPacket(expected: Int, actual: Int)
    case malformedReplyHeader(Data)
    case badJPEGMarker(offset: Int)
    case jpegHeightOutOfRange(Int)

    public var description: String {
        switch self {
        case .badPacketHeader(let data):
            "bad IS packet header \(data.map { String(format: "%02X", $0) }.joined(separator: " "))"
        case .truncatedPacket(let expected, let actual):
            "IS packet of \(actual) bytes, expected \(expected)"
        case .malformedReplyHeader(let data):
            "malformed ESC/I-2 reply header \(String(decoding: data.prefix(16), as: UTF8.self).debugDescription)"
        case .badJPEGMarker(let offset):
            "bad JPEG marker at byte \(offset)"
        case .jpegHeightOutOfRange(let height):
            "JPEG height \(height) out of range"
        }
    }
}
