import Foundation

// SNMP v1 (RFC 1157) messages in BER (ITU-T X.690), enough to read a scanner's health values: GetRequest and
// GetNextRequest out, GetResponse in. No SetRequest is encoded: the library only reads.

/// An SNMP object identifier, such as `1.3.6.1.2.1.1.3.0`.
public struct SNMPOID: Hashable, Sendable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var components: [UInt32]

    public init(_ components: [UInt32]) { self.components = components }

    /// Parses dotted decimal, with or without a leading dot. Nil for anything else.
    public init?(parsing string: String) {
        let trimmed = string.hasPrefix(".") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { UInt32($0) }
        guard numbers.count >= 2, numbers.count == parts.count else { return nil }
        components = numbers
    }

    public init(stringLiteral value: String) {
        guard let oid = SNMPOID(parsing: value) else { fatalError("not an OID: \(value)") }
        self = oid
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public func hasPrefix(_ prefix: SNMPOID) -> Bool { components.starts(with: prefix.components) }

    public func appending(_ more: UInt32...) -> SNMPOID { SNMPOID(components + more) }

    /// The components after `prefix`, or nil when `prefix` isn't one.
    public func suffix(after prefix: SNMPOID) -> [UInt32]? {
        hasPrefix(prefix) ? Array(components.dropFirst(prefix.components.count)) : nil
    }

    /// Lexicographic order, the order of a MIB walk.
    public static func < (a: SNMPOID, b: SNMPOID) -> Bool { a.components.lexicographicallyPrecedes(b.components) }
}

/// A value in a variable binding.
public enum SNMPValue: Hashable, Sendable {
    case integer(Int64)
    case octets([UInt8])
    case null
    case oid(SNMPOID)
    case ipAddress([UInt8])
    case counter32(UInt32)
    case gauge32(UInt32)
    /// Hundredths of a second.
    case timeTicks(UInt32)
    case counter64(UInt64)
    /// Any other type, kept as its tag and content.
    case other(tag: UInt8, bytes: [UInt8])

    /// The value of any integer type, when it fits an `Int`.
    public var integerValue: Int? {
        switch self {
        case .integer(let v): Int(exactly: v)
        case .counter32(let v), .gauge32(let v), .timeTicks(let v): Int(v)
        case .counter64(let v): Int(exactly: v)
        default: nil
        }
    }

    /// An octet string as UTF-8 (Latin-1 if it isn't valid UTF-8), with trailing NULs dropped.
    public var stringValue: String? {
        guard case .octets(var bytes) = self else { return nil }
        while bytes.last == 0 { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
    }

    /// Dotted IPv4 for an `IpAddress`.
    public var ipv4String: String? {
        guard case .ipAddress(let b) = self, b.count == 4 else { return nil }
        return b.map(String.init).joined(separator: ".")
    }
}

public struct SNMPBinding: Hashable, Sendable {
    public var oid: SNMPOID
    public var value: SNMPValue
    public init(oid: SNMPOID, value: SNMPValue) {
        self.oid = oid
        self.value = value
    }
}

public struct SNMPPDU: Hashable, Sendable {
    public enum Kind: UInt8, Sendable {
        case getRequest = 0xA0
        case getNextRequest = 0xA1
        case getResponse = 0xA2
    }

    public var kind: Kind
    public var requestID: Int32
    /// 0 = no error, 2 = noSuchName (v1's answer for a missing object, and for the end of a walk).
    public var errorStatus: Int
    public var errorIndex: Int
    public var bindings: [SNMPBinding]

    public static let noSuchName = 2
}

public enum SNMPError: Error, Equatable, Sendable {
    case malformed(String)
}

public enum SNMP {
    public static let port: UInt16 = 161
    public static let version1 = 0

    /// A v1 GetRequest or GetNextRequest for `oids` (values NULL).
    public static func request(_ kind: SNMPPDU.Kind, requestID: Int32, community: String = "public",
                               oids: [SNMPOID]) -> Data {
        let bindings = oids.map { tlv(0x30, encodeOID($0) + tlv(0x05, [])) }.flatMap { $0 }
        let pdu = tlv(kind.rawValue, encodeInteger(Int64(requestID)) + encodeInteger(0) + encodeInteger(0)
            + tlv(0x30, bindings))
        return Data(tlv(0x30, encodeInteger(Int64(version1)) + tlv(0x04, Array(community.utf8)) + pdu))
    }

    /// Decodes a v1 message. Throws ``SNMPError/malformed(_:)`` for anything that isn't one.
    public static func decode(_ data: Data) throws -> (community: String, pdu: SNMPPDU) {
        var top = Reader(Array(data))
        var message = try top.contents(of: 0x30, "message")
        guard top.atEnd else { throw SNMPError.malformed("bytes after the message") }
        let version = try message.integer("version")
        guard version == Int64(version1) else { throw SNMPError.malformed("SNMP version \(version)") }
        let community = try message.contents(of: 0x04, "community").rest
        let (tag, body) = try message.element("PDU")
        guard let kind = SNMPPDU.Kind(rawValue: tag) else { throw SNMPError.malformed("PDU type \(tag)") }
        var pdu = Reader(body)
        let requestID = try pdu.integer("request ID")
        let status = try pdu.integer("error status")
        let index = try pdu.integer("error index")
        var list = try pdu.contents(of: 0x30, "bindings")
        var bindings: [SNMPBinding] = []
        while !list.atEnd {
            var binding = try list.contents(of: 0x30, "binding")
            let oid = try decodeOID(try binding.contents(of: 0x06, "name").rest)
            let (valueTag, valueBytes) = try binding.element("value")
            bindings.append(SNMPBinding(oid: oid, value: try decodeValue(tag: valueTag, valueBytes)))
        }
        guard let id = Int32(exactly: requestID), let s = Int(exactly: status), let i = Int(exactly: index) else {
            throw SNMPError.malformed("header out of range")
        }
        return (String(decoding: community, as: UTF8.self),
                SNMPPDU(kind: kind, requestID: id, errorStatus: s, errorIndex: i, bindings: bindings))
    }

    // MARK: - BER

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + encodeLength(content.count) + content }

    static func encodeLength(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    /// Minimal two's complement.
    static func encodeInteger(_ value: Int64) -> [UInt8] {
        var bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        while bytes.count > 1, (bytes[0] == 0 && bytes[1] & 0x80 == 0) || (bytes[0] == 0xFF && bytes[1] & 0x80 != 0) {
            bytes.removeFirst()
        }
        return tlv(0x02, bytes)
    }

    static func encodeOID(_ oid: SNMPOID) -> [UInt8] {
        let c = oid.components
        let first = min(c.first ?? 0, 2), second = c.count > 1 ? c[1] : 0
        var out = base128(first * 40 + second)
        for v in c.dropFirst(2) { out += base128(v) }
        return tlv(0x06, out)
    }

    static func base128(_ value: UInt32) -> [UInt8] {
        var out = [UInt8(value & 0x7F)]
        var v = value >> 7
        while v > 0 { out.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
        return out
    }

    static func decodeOID(_ bytes: [UInt8]) throws -> SNMPOID {
        guard !bytes.isEmpty else { throw SNMPError.malformed("empty OID") }
        var values: [UInt32] = []
        var current: UInt64 = 0
        for (i, b) in bytes.enumerated() {
            current = current << 7 | UInt64(b & 0x7F)
            guard current <= UInt64(UInt32.max) else { throw SNMPError.malformed("OID component too large") }
            if b & 0x80 == 0 {
                values.append(UInt32(current))
                current = 0
            } else if i == bytes.count - 1 {
                throw SNMPError.malformed("OID ends mid-component")
            }
        }
        let first = values.removeFirst()
        let head: [UInt32] = first < 80 ? [first / 40, first % 40] : [2, first - 80]
        return SNMPOID(head + values)
    }

    static func decodeValue(tag: UInt8, _ b: [UInt8]) throws -> SNMPValue {
        switch tag {
        case 0x02: return .integer(try signed(b))
        case 0x04: return .octets(b)
        case 0x05: return .null
        case 0x06: return .oid(try decodeOID(b))
        case 0x40:
            guard b.count == 4 else { throw SNMPError.malformed("IpAddress of \(b.count) bytes") }
            return .ipAddress(b)
        case 0x41, 0x42, 0x43:
            let v = try unsigned(b)
            guard let v32 = UInt32(exactly: v) else { throw SNMPError.malformed("32-bit value too large") }
            return tag == 0x41 ? .counter32(v32) : tag == 0x42 ? .gauge32(v32) : .timeTicks(v32)
        case 0x46: return .counter64(try unsigned(b))
        default: return .other(tag: tag, bytes: b)
        }
    }

    static func signed(_ b: [UInt8]) throws -> Int64 {
        guard !b.isEmpty, b.count <= 8 else { throw SNMPError.malformed("INTEGER of \(b.count) bytes") }
        var v: Int64 = b[0] & 0x80 != 0 ? -1 : 0
        for byte in b { v = v << 8 | Int64(byte) }
        return v
    }

    static func unsigned(_ b: [UInt8]) throws -> UInt64 {
        var bytes = b[...]
        while bytes.count > 1, bytes.first == 0 { bytes = bytes.dropFirst() }
        guard !bytes.isEmpty, bytes.count <= 8 else { throw SNMPError.malformed("unsigned value of \(b.count) bytes") }
        return bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// Reads BER elements from a byte array.
    struct Reader {
        private let bytes: [UInt8]
        private var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index >= bytes.count }
        var rest: [UInt8] { Array(bytes[min(index, bytes.count)...]) }

        mutating func element(_ what: String) throws -> (tag: UInt8, content: [UInt8]) {
            guard index < bytes.count else { throw SNMPError.malformed("missing \(what)") }
            let tag = bytes[index]
            index += 1
            guard index < bytes.count else { throw SNMPError.malformed("\(what) has no length") }
            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count >= 1, count <= 4 else { throw SNMPError.malformed("\(what) length form") }
                guard index + count <= bytes.count else { throw SNMPError.malformed("\(what) length cut short") }
                length = bytes[index ..< index + count].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            guard length <= bytes.count - index else { throw SNMPError.malformed("\(what) cut short") }
            defer { index += length }
            return (tag, Array(bytes[index ..< index + length]))
        }

        mutating func contents(of tag: UInt8, _ what: String) throws -> Reader {
            let (t, content) = try element(what)
            guard t == tag else { throw SNMPError.malformed("\(what): tag \(t), expected \(tag)") }
            return Reader(content)
        }

        mutating func integer(_ what: String) throws -> Int64 {
            let (t, content) = try element(what)
            guard t == 0x02 else { throw SNMPError.malformed("\(what): tag \(t), expected an INTEGER") }
            return try SNMP.signed(content)
        }
    }
}
