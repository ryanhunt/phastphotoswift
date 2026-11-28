import Foundation
import Testing
@testable import PhastPhotoProtocol

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

@Suite struct SNMPTests {
    @Test func getRequestMatchesKnownBytes() {
        // sysDescr.0, community "public", request ID 1: the bytes net-snmp's snmpget sends
        let bytes = SNMP.request(.getRequest, requestID: 1, oids: ["1.3.6.1.2.1.1.1.0"])
        #expect(Array(bytes) == [
            0x30, 0x26, 0x02, 0x01, 0x00, 0x04, 0x06, 0x70, 0x75, 0x62, 0x6C, 0x69, 0x63,
            0xA0, 0x19, 0x02, 0x01, 0x01, 0x02, 0x01, 0x00, 0x02, 0x01, 0x00,
            0x30, 0x0E, 0x30, 0x0C, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00, 0x05, 0x00,
        ])
        #expect(SNMP.request(.getNextRequest, requestID: 1, oids: ["1.3.6.1.2.1.1.1.0"])[13] == 0xA1)
    }

    @Test func epsonsEnterpriseNumberIsTwoBytes() throws {
        #expect(SNMP.base128(1248) == [0x89, 0x60])
        #expect(SNMP.base128(127) == [0x7F])
        #expect(SNMP.base128(128) == [0x81, 0x00])
        #expect(try SNMP.decodeOID([0x2B, 0x06, 0x01, 0x04, 0x01, 0x89, 0x60]) == "1.3.6.1.4.1.1248")
    }

    @Test func integersAreMinimalTwosComplement() throws {
        #expect(SNMP.encodeInteger(0) == [0x02, 0x01, 0x00])
        #expect(SNMP.encodeInteger(-1) == [0x02, 0x01, 0xFF])
        #expect(SNMP.encodeInteger(128) == [0x02, 0x02, 0x00, 0x80])
        #expect(SNMP.encodeInteger(-129) == [0x02, 0x02, 0xFF, 0x7F])
        #expect(try SNMP.signed([0xFF]) == -1)  // seen live in Epson's tree
        #expect(try SNMP.signed([0x00, 0x80]) == 128)
    }

    @Test func decodesAResponseWithEveryValueType() throws {
        let data = snmpResponse(id: 42, [
            ("1.3.6.1.2.1.1.1.0", BER.string("EPSON Built-in")),
            ("1.3.6.1.4.1.1248.1", BER.int(-1)),
            ("1.3.6.1.4.1.1248.2", BER.counter(4_294_967_295)),  // above 2^31: content 00 FF FF FF FF
            ("1.3.6.1.2.1.1.3.0", BER.ticks(399_700)),
            ("1.3.6.1.2.1.4.20.1.1.192.0.2.10", BER.ip(192, 0, 2, 10)),
            ("1.3.6.1.4.1.1248.3", SNMP.tlv(0x05, [])),
        ])
        let (community, pdu) = try SNMP.decode(data)
        #expect(community == "public")
        #expect(pdu.kind == .getResponse && pdu.requestID == 42 && pdu.errorStatus == 0)
        #expect(pdu.bindings.map(\.value) == [
            .octets(Array("EPSON Built-in".utf8)), .integer(-1), .counter32(4_294_967_295), .timeTicks(399_700),
            .ipAddress([192, 0, 2, 10]), .null,
        ])
        #expect(pdu.bindings[0].value.stringValue == "EPSON Built-in")
        #expect(pdu.bindings[2].value.integerValue == 4_294_967_295)
        #expect(pdu.bindings[4].value.ipv4String == "192.0.2.10")
        #expect(pdu.bindings[4].oid.suffix(after: "1.3.6.1.2.1.4.20.1") == [1, 192, 0, 2, 10])
    }

    @Test func longFormLengths() throws {
        let long = String(repeating: "x", count: 300)
        let (_, pdu) = try SNMP.decode(snmpResponse(id: 1, [("1.3.6.1.4.1.1248.1", BER.string(long))]))
        #expect(pdu.bindings.first?.value.stringValue == long)
        #expect(SNMP.encodeLength(300) == [0x82, 0x01, 0x2C])
    }

    @Test func noSuchNameIsAnErrorStatusNotAThrow() throws {
        let (_, pdu) = try SNMP.decode(snmpResponse(id: 7, errorStatus: 2, [("1.3.6.1.4.1.1248.9", SNMP.tlv(0x05, []))]))
        #expect(pdu.errorStatus == SNMPPDU.noSuchName)
    }

    @Test func malformedDatagramsThrow() {
        let good = Array(snmpResponse(id: 1, [("1.3.6.1.2.1.1.3.0", BER.ticks(5))]))
        let cases: [[UInt8]] = [Array(good.dropLast(3)), [0x30, 0x80] + Array(good.dropFirst(2)), good + [0x00], [], [0x02, 0x01, 0x00]]
        for bad in cases {
            #expect(throws: SNMPError.self) { try SNMP.decode(Data(bad)) }
        }
        var v2 = good
        v2[4] = 0x01  // version 1 = SNMPv2c
        #expect(throws: SNMPError.self) { try SNMP.decode(Data(v2)) }
    }

    @Test func oidsParseCompareAndExtend() {
        #expect(SNMPOID(parsing: ".1.3.6.1") == SNMPOID(parsing: "1.3.6.1"))
        #expect(SNMPOID(parsing: "1.3.x") == nil && SNMPOID(parsing: "1") == nil && SNMPOID(parsing: "1..3") == nil)
        let base: SNMPOID = "1.3.6.1.4.1.1248"
        #expect(base < base.appending(1) && base.appending(1) < "1.3.6.1.4.1.1249")
        #expect(base.appending(1, 2).hasPrefix(base) && !base.hasPrefix(base.appending(1)))
        #expect(base.appending(1, 2).description == "1.3.6.1.4.1.1248.1.2")
        #expect(base.suffix(after: "1.3.6.2") == nil)
    }
}
