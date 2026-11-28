import Foundation
import Testing
@testable import PhastPhotoProtocol

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
            ("\(epson).1.4.2.6.1.1.7.1.1", .counter32(1331)),
            ("\(epson).1.4.2.6.1.1.10.1.1", .counter32(4)),
            ("\(epson).1.4.2.6.1.1.11.1.1", .counter32(21)),
            ("\(epson).1.2.2.3.1.1.9.1", .integer(10)),
            ("\(epson).1.2.2.3.1.1.11.1", .octets([0x07, 0xEA, 0x0B, 0x1C, 0x0C, 0x34, 0x16, 0x00, 0x2B, 0x00, 0x00])),
            ("\(epson).1.2.2.3.3.1.3.1", .integer(120)),
            ("\(epson).1.2.2.3.5.1.4.1", .integer(0)),
            ("\(epson).1.2.2.3.5.1.9.1", .octets([0x40, 0x00])),
            ("\(epson).1.2.2.3.6.1.2.1.1", .integer(0)),
            ("\(epson).1.2.2.3.6.1.2.1.2", .integer(30)),
            ("\(epson).1.2.2.3.6.1.2.1.3", .integer(60)),
            ("1.3.6.1.2.1.1.3.0", .timeTicks(399_700)),
            ("1.3.6.1.2.1.4.20.1.1.192.0.2.10", .ipAddress([192, 0, 2, 10])),
            ("1.3.6.1.2.1.4.20.1.2.192.0.2.10", .integer(1)),
            ("1.3.6.1.2.1.4.20.1.3.192.0.2.10", .ipAddress([255, 255, 255, 0])),
            ("1.3.6.1.2.1.2.2.1.6.1", .octets([0x02, 0, 0, 0, 0, 0x01])),
        ]
        return raw.map { SNMPBinding(oid: SNMPOID(parsing: $0.0)!, value: $0.1) }
    }
}

@Suite struct ScannerHealthTests {
    @Test func sampleWalkGivesTheLabelledValues() throws {
        let health = ScannerHealth(snmp: SampleWalk.bindings)
        #expect(health.firmware == .init(main: "SP14P2", network: "18.60", package: "18.60.SP14P2.FY17"))
        #expect(health.serialNumber == "X0AB000000")
        let kit = try #require(health.rollerKit)
        #expect(kit.name == "Roller Assemblly Kit" && kit.used == 1331 && kit.life == 200_000)
        #expect(abs(try #require(kit.remainingFraction) - 0.993345) < 1e-6)
        #expect(!kit.isDue)
        #expect(health.clock == Date(timeIntervalSince1970: 1_795_870_342))  // 2026-11-28 12:52:22 UTC
        #expect(health.uptime == .seconds(3997))
        #expect(health.network == .init(ipv4Address: "192.0.2.10", subnetMask: "255.255.255.0",
                                        macAddress: "02:00:00:00:00:01"))
    }

    /// The counters and timers labelled at the scanner (plan 11.4): matched to Epson Scan 2 Utility and moved by
    /// test scans and setting changes.
    @Test func countersAndTimersAreLabelled() {
        let health = ScannerHealth(snmp: SampleWalk.bindings)
        #expect(health.counts == .init(feederSheets: 1331, singleSided: 4, doubleSided: 1327, paperJams: 18,
                                       doubleFeeds: 21))
        #expect(health.power == .init(sleepMinutes: 10, powerOffMinutes: 0, powerOffChoices: [0, 30, 60]))
    }

    /// Unconfirmed meanings never get a name: they stay keyed by OID.
    @Test func unknownValuesStayUnlabelled() {
        let u = ScannerHealth(snmp: SampleWalk.bindings).unlabelled
        #expect(u["1.3.6.1.4.1.1248.1.4.2.6.1.1.7.1.1"] == 1331)  // equals the feeder count; meaning unknown
        #expect(u["1.3.6.1.4.1.1248.1.2.2.3.3.1.3.1"] == 120)  // not the power-off timer, which didn't move it
        #expect(u["1.3.6.1.4.1.1248.1.4.2.14.1.1.4.1.1"] == 3)  // consumable column 4
        #expect(u["1.3.6.1.4.1.1248.1.4.2.6.1.1.4.1.1"] == nil)  // feeder sheets: labelled
        #expect(u["1.3.6.1.4.1.1248.1.2.2.3.1.1.9.1"] == nil)  // sleep timer: labelled
        #expect(u["1.3.6.1.4.1.1248.1.2.2.3.5.1.4.1"] == nil)  // power-off timer: labelled
        #expect(u["1.3.6.1.4.1.1248.1.4.2.14.1.1.7.1.1"] == nil)  // the kit count is labelled
        #expect(u["1.3.6.1.4.1.1248.1.2.2.3.1.1.11.1"] == nil)  // the clock is labelled
        #expect(u.count == 5)
    }

    @Test func rollerKitStates() {
        func kit(_ used: Int?, _ life: Int?) -> ScannerHealth.Consumable {
            .init(kind: .rollerKit, name: "Roller Assemblly Kit", used: used, life: life)
        }
        #expect(kit(0, 200_000).remainingFraction == 1 && !kit(0, 200_000).isDue)
        #expect(kit(199_999, 200_000).isDue == false)
        #expect(kit(200_000, 200_000).isDue && kit(200_000, 200_000).remainingFraction == 0)
        #expect(kit(250_000, 200_000).isDue && kit(250_000, 200_000).remainingFraction == 0)
        #expect(kit(5, nil).remainingFraction == nil && !kit(5, nil).isDue)
        #expect(kit(5, 0).remainingFraction == nil && !kit(5, 0).isDue)
    }

    @Test func consumablesAreMatchedByName() {
        let other = SampleWalk.bindings.map { b -> SNMPBinding in
            b.oid.description.hasSuffix("14.1.1.3.1.1") ? SNMPBinding(oid: b.oid, value: .octets(Array("Pad".utf8))) : b
        }
        let health = ScannerHealth(snmp: other)
        #expect(health.rollerKit == nil)
        #expect(health.consumables.map(\.kind) == [.other])
    }

    @Test func nothingReadIsAnEmptyReport() {
        #expect(ScannerHealth(snmp: []).isEmpty)
        // only MIB-2 (no Epson tree): no firmware, no consumables, not an error
        let mib2 = ScannerHealth(snmp: SampleWalk.bindings.filter { !$0.oid.description.hasPrefix(SampleWalk.epson) })
        #expect(mib2.firmware == nil && mib2.consumables.isEmpty && mib2.uptime != nil)
        #expect(mib2.counts == nil && mib2.power == nil)
    }

    @Test func dateAndTime() {
        let utc: [UInt8] = [0x07, 0xEA, 0x0B, 0x1C, 0x0C, 0x34, 0x16, 0x05]
        #expect(ScannerHealth.date(fromDateAndTime: .octets(utc)) == Date(timeIntervalSince1970: 1_795_870_342.5))
        // 22:52:22 at UTC+10 is 12:52:22 UTC
        let plusTen: [UInt8] = [0x07, 0xEA, 0x0B, 0x1C, 22, 0x34, 0x16, 0, 0x2B, 10, 0]
        #expect(ScannerHealth.date(fromDateAndTime: .octets(plusTen)) == Date(timeIntervalSince1970: 1_795_870_342))
        for bad: [UInt8] in [[0x07, 0xEA, 13, 1, 0, 0, 0, 0], [0x07, 0xEA, 1, 1, 0, 0, 0, 0, 0x3F, 0, 0], [0x07, 0xEA]] {
            #expect(ScannerHealth.date(fromDateAndTime: .octets(bad)) == nil)
        }
        #expect(ScannerHealth.date(fromDateAndTime: .integer(5)) == nil)
    }

    @Test func identifiersAreRedactedUnlessAsked() {
        let health = ScannerHealth(snmp: SampleWalk.bindings)
        let hidden = Dictionary(uniqueKeysWithValues: health.displayFields().map { ($0.key, $0.value) })
        #expect(hidden["Serial number"] == "[redacted]")
        #expect(hidden["IPv4 address"] == "[redacted]" && hidden["MAC address"] == "[redacted]")
        #expect(hidden["Subnet mask"] == "255.255.255.0")
        #expect(hidden["Roller assembly kit"] == "1331 of 200000 sheets (99% left)")
        #expect(hidden["Firmware package"] == "18.60.SP14P2.FY17")
        #expect(hidden["Uptime"] == "1 h 6 min")
        #expect(hidden["Sheets scanned"] == "1331" && hidden["Double feeds"] == "21" && hidden["Paper jams"] == "18")
        #expect(hidden["Sleep timer"] == "10 min" && hidden["Power-off timer"] == "off")
        let shown = Dictionary(uniqueKeysWithValues: health.displayFields(showIdentifiers: true).map { ($0.key, $0.value) })
        #expect(shown["Serial number"] == "X0AB000000" && shown["MAC address"] == "02:00:00:00:00:01")
        #expect(!health.displayFields().contains { $0.value.contains("X0AB") || $0.value.contains("192.0.2") })
    }

    @Test func walkedSubtreesLeaveOutPersonalOnes() {
        let walked = EpsonMIB.walkedSubtrees
        #expect(!walked.contains { "1.3.6.1.4.1.1248.1.4.2.21.1".hasPrefix($0.description) })  // last client's host name
        #expect(!walked.contains { "1.3.6.1.4.1.1248.1.1.3.1.29".hasPrefix($0.description) })  // Wi-Fi group
    }
}
