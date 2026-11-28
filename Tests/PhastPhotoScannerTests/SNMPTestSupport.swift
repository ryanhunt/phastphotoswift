import Foundation
@testable import PhastPhotoProtocol

// Copies of PhastPhotoProtocolTests' SNMP helpers (test targets can't share files).

/// A v1 GetResponse built from encoded pieces, for decoder and parser tests.
func snmpResponse(id: Int32, errorStatus: Int = 0, community: String = "public",
                  _ bindings: [(SNMPOID, [UInt8])]) -> Data {
    let list = bindings.flatMap { SNMP.tlv(0x30, SNMP.encodeOID($0.0) + $0.1) }
    let pdu = SNMP.tlv(0xA2, SNMP.encodeInteger(Int64(id)) + SNMP.encodeInteger(Int64(errorStatus))
        + SNMP.encodeInteger(0) + SNMP.tlv(0x30, list))
    return Data(SNMP.tlv(0x30, SNMP.encodeInteger(0) + SNMP.tlv(0x04, Array(community.utf8)) + pdu))
}

/// Encoded values for ``snmpResponse(id:errorStatus:community:_:)``.
enum BER {
    static func int(_ v: Int64) -> [UInt8] { SNMP.encodeInteger(v) }
    static func string(_ s: String) -> [UInt8] { SNMP.tlv(0x04, Array(s.utf8)) }
    static func octets(_ b: [UInt8]) -> [UInt8] { SNMP.tlv(0x04, b) }
    static func counter(_ v: UInt32) -> [UInt8] { SNMP.tlv(0x41, unsigned(UInt64(v))) }
    static func ticks(_ v: UInt32) -> [UInt8] { SNMP.tlv(0x43, unsigned(UInt64(v))) }
    static func ip(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] { SNMP.tlv(0x40, [a, b, c, d]) }
    /// Unsigned content with a leading zero when the top bit is set, as agents send it.
    static func unsigned(_ v: UInt64) -> [UInt8] {
        var b = withUnsafeBytes(of: v.bigEndian, Array.init)
        while b.count > 1, b[0] == 0 { b.removeFirst() }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return b
    }
}

/// A walk shaped like an FF-680W's (firmware 18.60, 28 Nov 2026), with the identifiers replaced: serial
/// X0AB000000, address 192.0.2.10, MAC 02:00:00:00:00:01.
enum SampleWalk {
    static let epson = "1.3.6.1.4.1.1248"
    static var bindings: [SNMPBinding] {
        let raw: [(String, SNMPValue)] = [
            ("\(epson).1.2.2.2.1.1.2.1.1", .octets(Array("SP14P2".utf8))),
            ("\(epson).1.2.2.2.1.1.2.1.2", .octets(Array("X0AB000000".utf8))),
            ("\(epson).1.2.2.2.1.1.2.1.3", .octets(Array("18.60".utf8))),
            ("\(epson).1.2.2.2.1.1.2.1.4", .octets(Array("18.60.SP14P2.FY17".utf8))),
            ("\(epson).1.2.2.2.1.1.3.1.1", .octets(Array("Main FW".utf8))),
            ("\(epson).1.2.2.2.1.1.3.1.2", .octets(Array("Serial No.".utf8))),
            ("\(epson).1.2.2.2.1.1.3.1.3", .octets(Array("Network FW".utf8))),
            ("\(epson).1.2.2.2.1.1.3.1.4", .octets(Array("FW Package".utf8))),
            ("\(epson).1.2.2.2.1.1.5.1.1", .octets([0x86])),
            ("\(epson).1.4.2.14.1.1.2.1.1", .integer(4)),
            ("\(epson).1.4.2.14.1.1.3.1.1", .octets(Array("Roller Assemblly Kit".utf8))),
            ("\(epson).1.4.2.14.1.1.4.1.1", .integer(3)),
            ("\(epson).1.4.2.14.1.1.5.1.1", .integer(5)),
            ("\(epson).1.4.2.14.1.1.6.1.1", .integer(200_000)),
            ("\(epson).1.4.2.14.1.1.7.1.1", .integer(1331)),
            ("\(epson).1.4.2.6.1.1.4.1.1", .counter32(1331)),
            ("\(epson).1.4.2.6.1.1.5.1.1", .counter32(1327)),
            ("\(epson).1.4.2.6.1.1.6.1.1", .counter32(18)),
            ("\(epson).1.2.2.3.1.1.9.1", .integer(10)),
            ("\(epson).1.2.2.3.1.1.11.1", .octets([0x07, 0xEA, 0x0B, 0x1C, 0x0C, 0x34, 0x16, 0x00, 0x2B, 0x00, 0x00])),
            ("\(epson).1.2.2.3.3.1.3.1", .integer(120)),
            ("\(epson).1.2.2.3.5.1.9.1", .octets([0x40, 0x00])),
            ("1.3.6.1.2.1.1.3.0", .timeTicks(399_700)),
            ("1.3.6.1.2.1.4.20.1.1.192.0.2.10", .ipAddress([192, 0, 2, 10])),
            ("1.3.6.1.2.1.4.20.1.2.192.0.2.10", .integer(1)),
            ("1.3.6.1.2.1.4.20.1.3.192.0.2.10", .ipAddress([255, 255, 255, 0])),
            ("1.3.6.1.2.1.2.2.1.6.1", .octets([0x02, 0, 0, 0, 0, 0x01])),
        ]
        return raw.map { SNMPBinding(oid: SNMPOID(parsing: $0.0)!, value: $0.1) }
    }
}

