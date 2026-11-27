import Foundation

/// The type field of an "IS" packet. Requests are `0x2xxx`; replies set the high bit (`0x2000` → `0xA000`).
public struct ISPacketType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Sent by the scanner as soon as a client connects. See ``ScannerHello``.
    public static let hello = ISPacketType(rawValue: 0x8000)
    /// Claim the scanner. Reply `0xA100` with `06` (ACK).
    public static let lock = ISPacketType(rawValue: 0x2100)
    /// Release the scanner. Reply `0xA101`, empty.
    public static let unlock = ISPacketType(rawValue: 0x2101)
    /// ESC/I data. Reply `0xA000`.
    public static let data = ISPacketType(rawValue: 0x2000)

    /// The type the scanner answers this request with.
    public var reply: ISPacketType { ISPacketType(rawValue: rawValue | 0x8000) }

    public var description: String { "0x" + String(rawValue, radix: 16, uppercase: true) }
}

/// A packet of Epson's "IS" network framing on TCP port 1865 (docs/PROTOCOL.md §1).
///
/// ```
/// offset  0  'I' 'S'
///         2  type (u16, big-endian)
///         4  0x00 0x0C
///         6  payload length (u32, big-endian)
///        10  0x00 0x00
///        12  payload
/// ```
public struct ISPacket: Hashable, Sendable {
    public static let headerLength = 12
    /// The scanner's TCP port.
    public static let port: UInt16 = 1865
    /// Lock payload, as sent by Epson's own client.
    public static let lockPayload = Data([0x01, 0xA0, 0x04, 0x00, 0x00, 0x01, 0x2C])

    public var type: ISPacketType
    public var payload: Data

    public init(type: ISPacketType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    public static func lock() -> ISPacket { ISPacket(type: .lock, payload: lockPayload) }
    public static func unlock() -> ISPacket { ISPacket(type: .unlock) }

    /// An ESC/I data packet: `data_len (u32)` + `reply_len (u32)` + data.
    ///
    /// The scanner never sends more than `replyLength` bytes back. Never ask for more than the 64-byte
    /// reply header together with a command: the scanner stops answering and stays locked until it is
    /// switched off and on.
    public static func data(_ escI: Data, replyLength: Int) -> ISPacket {
        var payload = Data(capacity: 8 + escI.count)
        payload.appendBigEndian(UInt32(escI.count))
        payload.appendBigEndian(UInt32(replyLength))
        payload.append(escI)
        return ISPacket(type: .data, payload: payload)
    }

    /// Header and payload, ready to send.
    public var encoded: Data {
        var out = Data(capacity: Self.headerLength + payload.count)
        out.append(contentsOf: [0x49, 0x53])  // "IS"
        out.appendBigEndian(type.rawValue)
        out.append(contentsOf: [0x00, 0x0C])
        out.appendBigEndian(UInt32(payload.count))
        out.append(contentsOf: [0x00, 0x00])
        out.append(payload)
        return out
    }

    /// Type and payload length from a 12-byte header.
    public static func parseHeader(_ header: Data) throws -> (type: ISPacketType, payloadLength: Int) {
        let b = [UInt8](header)
        guard b.count == headerLength, b[0] == 0x49, b[1] == 0x53 else {
            throw ProtocolError.badPacketHeader(header)
        }
        let type = UInt16(b[2]) << 8 | UInt16(b[3])
        let length = Int(b[6]) << 24 | Int(b[7]) << 16 | Int(b[8]) << 8 | Int(b[9])
        return (ISPacketType(rawValue: type), length)
    }

    /// Decode one complete packet (header and payload).
    public init(decoding data: Data) throws {
        let bytes = Data(data)  // indices from 0
        guard bytes.count >= Self.headerLength else { throw ProtocolError.badPacketHeader(bytes) }
        let (type, length) = try Self.parseHeader(bytes.prefix(Self.headerLength))
        guard bytes.count == Self.headerLength + length else {
            throw ProtocolError.truncatedPacket(expected: Self.headerLength + length, actual: bytes.count)
        }
        self.init(type: type, payload: bytes.dropFirst(Self.headerLength))
    }

    /// For a `0x2000` request: the ESC/I bytes and the reply length asked for.
    public var dataRequest: (escI: Data, replyLength: Int)? {
        let b = [UInt8](payload)
        guard type == .data, b.count >= 8 else { return nil }
        let length = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        let reply = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
        guard b.count == 8 + length else { return nil }
        return (Data(b[8...]), reply)
    }
}

/// The scanner's `0x8000` hello. While another client holds the scanner it carries that client's address.
public struct ScannerHello: Hashable, Sendable {
    public var payload: Data
    public init(payload: Data) { self.payload = payload }

    /// Address of the client holding the scanner, or `nil` when it's free.
    ///
    /// Busy payload: `01 04 81 00 01 01 01 <address length> <address bytes>`; a free scanner sends `01 04 00 00 00`.
    public var holderAddress: String? {
        let b = [UInt8](payload)
        guard b.count >= 8 else { return nil }
        let n = Int(b[7])
        guard n == 4 || n == 16, b.count >= 8 + n else { return nil }
        let address = Array(b[8 ..< 8 + n])
        return n == 4 ? address.map(String.init).joined(separator: ".") : Self.ipv6String(address)
    }

    /// RFC 5952 text form (`fe80::abcd`).
    static func ipv6String(_ bytes: [UInt8]) -> String {
        let groups = stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        // longest run of two or more zero groups becomes "::"
        var best: Range<Int>?
        var i = 0
        while i < groups.count {
            guard groups[i] == 0 else { i += 1; continue }
            var j = i
            while j < groups.count, groups[j] == 0 { j += 1 }
            if j - i >= 2, j - i > (best?.count ?? 0) { best = i ..< j }
            i = j
        }
        let hex = groups.map { String($0, radix: 16) }
        guard let best else { return hex.joined(separator: ":") }
        return hex[..<best.lowerBound].joined(separator: ":") + "::" + hex[best.upperBound...].joined(separator: ":")
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
