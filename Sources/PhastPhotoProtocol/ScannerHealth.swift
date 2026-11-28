import Foundation

/// The scanner's health and identity values from SNMP (docs/PLAN.md, phase 11): firmware, roller kit wear, clock,
/// uptime and network details. Every field is optional, so an app shows what the scanner gave.
///
/// Only values whose meaning is established get a named field: the counters and timers were matched against Epson
/// Scan 2 Utility and moved by test scans and setting changes on a real FF-680W (plan 11.4, 29 Nov 2026). The rest
/// are kept in ``unlabelled``.
public struct ScannerHealth: Hashable, Sendable {
    public struct Firmware: Hashable, Sendable {
        /// `Main FW`, such as `SP14P2`.
        public var main: String?
        /// `Network FW`, such as `18.60`.
        public var network: String?
        /// `FW Package`, such as `18.60.SP14P2.FY17`.
        public var package: String?
    }

    /// A part that wears out, with the scanner's own count and life for it.
    public struct Consumable: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case rollerKit, other }
        public var kind: Kind
        /// The scanner's name for the part, as it spells it ("Roller Assemblly Kit" on firmware 18.60).
        public var name: String
        /// Sheets fed since the part was fitted (Epson Scan 2 Utility's "Number of Scans"). A duplex print counts
        /// once, and so does a sheet stopped by a double feed.
        public var used: Int?
        /// The scanner's life limit, in the same unit (200,000 for the FF-680W roller kit, as Epson publishes).
        public var life: Int?

        /// Share of the life left, 0...1; nil without both numbers.
        public var remainingFraction: Double? {
            guard let used, let life, life > 0 else { return nil }
            return max(0, 1 - Double(used) / Double(life))
        }

        /// True once the count reaches the life: time to replace the part.
        public var isDue: Bool {
            guard let used, let life, life > 0 else { return false }
            return used >= life
        }
    }

    /// The scanner's lifetime counts, as Epson Scan 2 Utility's Counter tab shows them. Counts are of sheets:
    /// a duplex print adds one to ``feederSheets`` and one to ``doubleSided``.
    public struct ScanCounts: Hashable, Sendable {
        /// Every sheet the feeder took ("ADF"): single-sided plus double-sided, including sheets stopped by a
        /// double feed.
        public var feederSheets: Int?
        public var singleSided: Int?
        public var doubleSided: Int?
        /// Paper jams. Matched by value only (no jam was caused on purpose).
        public var paperJams: Int?
        /// Double feeds the scanner detected (only while double-feed detection is on).
        public var doubleFeeds: Int?
    }

    /// The power-save settings, in minutes.
    public struct PowerTimers: Hashable, Sendable {
        /// Minutes idle before the scanner sleeps.
        public var sleepMinutes: Int?
        /// Minutes idle before it switches off; 0 means never ("Off").
        public var powerOffMinutes: Int?
        /// The power-off choices the scanner offers (0 = Off), in its order.
        public var powerOffChoices: [Int] = []
    }

    public struct NetworkDetails: Hashable, Sendable {
        /// The scanner's IPv4 address. Identifies the network: hidden by default in ``displayFields(showIdentifiers:)``.
        public var ipv4Address: String?
        public var subnetMask: String?
        /// The Wi-Fi interface's MAC address, `aa:bb:cc:dd:ee:ff`. An identifier: hidden by default.
        public var macAddress: String?
    }

    public var firmware: Firmware?
    /// Serial number. Personal data: don't log or publish it.
    public var serialNumber: String?
    public var consumables: [Consumable] = []
    /// The scanner's clock (it kept UTC on the scanner checked).
    public var clock: Date?
    /// Time since the network interface started: not since power-on (it restarted when settings were changed).
    public var uptime: Duration?
    public var network: NetworkDetails?
    public var counts: ScanCounts?
    public var power: PowerTimers?
    /// Integer values whose meaning is not established yet, keyed by OID: counter columns 7 and 8 (always equal to
    /// ``ScanCounts/feederSheets`` so far), the tables' index and flag columns, and other power settings.
    public var unlabelled: [String: Int] = [:]

    public init() {}

    /// The roller assembly kit, the FF-680W's one consumable.
    public var rollerKit: Consumable? { consumables.first { $0.kind == .rollerKit } }

    /// True when nothing at all was read.
    public var isEmpty: Bool { self == ScannerHealth() }
}

// MARK: - From SNMP

extension ScannerHealth {
    /// Builds the report from the bindings of walks over ``EpsonMIB/walkedSubtrees``. Values that don't fit their
    /// expected type are ignored; a missing subtree leaves its fields nil.
    public init(snmp bindings: [SNMPBinding]) {
        self.init()
        var labels: [UInt32: String] = [:], values: [UInt32: String] = [:]
        var consumableColumns: [UInt32: [UInt32: SNMPValue]] = [:]  // row -> column -> value
        var addresses: [String: (address: String?, mask: String?)] = [:]
        var mac: String?

        for b in bindings {
            if let s = b.oid.suffix(after: EpsonMIB.firmwareValue), s.count == 1 {
                values[s[0]] = b.value.stringValue
            } else if let s = b.oid.suffix(after: EpsonMIB.firmwareLabel), s.count == 1 {
                labels[s[0]] = b.value.stringValue
            } else if let s = b.oid.suffix(after: EpsonMIB.consumableTable), s.count == 3 {
                // column . 1 . row
                consumableColumns[s[2], default: [:]][s[0]] = b.value
            } else if let s = b.oid.suffix(after: EpsonMIB.counterTable), s.count == 3, let v = b.value.integerValue {
                // column . 1 . 1
                var c = counts ?? ScanCounts()
                switch s[0] {
                case EpsonMIB.CounterColumn.feederSheets: c.feederSheets = v
                case EpsonMIB.CounterColumn.singleSided: c.singleSided = v
                case EpsonMIB.CounterColumn.doubleSided: c.doubleSided = v
                case EpsonMIB.CounterColumn.paperJams: c.paperJams = v
                case EpsonMIB.CounterColumn.doubleFeeds: c.doubleFeeds = v
                default: unlabelled[b.oid.description] = v
                }
                if c != ScanCounts() { counts = c }
            } else if b.oid.hasPrefix(EpsonMIB.powerSettings) {
                if b.oid == EpsonMIB.clock {
                    clock = Self.date(fromDateAndTime: b.value)
                } else if let v = b.value.integerValue {
                    var p = power ?? PowerTimers()
                    if b.oid == EpsonMIB.sleepTimer {
                        p.sleepMinutes = v
                    } else if b.oid == EpsonMIB.powerOffTimer {
                        p.powerOffMinutes = v
                    } else if let s = b.oid.suffix(after: EpsonMIB.powerOffChoices), s.count == 1 {
                        p.powerOffChoices.append(v)  // a walk returns them in index order
                    } else {
                        unlabelled[b.oid.description] = v
                    }
                    if p != PowerTimers() { power = p }
                }
            } else if b.oid == EpsonMIB.sysUpTime, case .timeTicks(let ticks) = b.value {
                uptime = .milliseconds(Int64(ticks) * 10)
            } else if let s = b.oid.suffix(after: EpsonMIB.ipAddressEntry), s.count == 5 {
                let key = s.dropFirst().map(String.init).joined(separator: ".")
                if s[0] == 1 { addresses[key, default: (nil, nil)].address = b.value.ipv4String }
                if s[0] == 3 { addresses[key, default: (nil, nil)].mask = b.value.ipv4String }
            } else if b.oid.hasPrefix(EpsonMIB.ifPhysAddress), mac == nil,
                      case .octets(let bytes) = b.value, bytes.count == 6 {
                mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            }
        }

        if !values.isEmpty {
            func value(labelled label: String) -> String? {
                labels.first { $0.value == label }.flatMap { values[$0.key] }
            }
            let fw = Firmware(main: value(labelled: "Main FW"), network: value(labelled: "Network FW"),
                              package: value(labelled: "FW Package"))
            if fw != Firmware() { firmware = fw }
            serialNumber = value(labelled: "Serial No.")
        }

        for row in consumableColumns.keys.sorted() {
            let columns = consumableColumns[row]!
            guard let name = columns[EpsonMIB.ConsumableColumn.name]?.stringValue else { continue }
            let kind: Consumable.Kind = name.lowercased().hasPrefix("roller ass") ? .rollerKit : .other
            consumables.append(Consumable(kind: kind, name: name,
                                          used: columns[EpsonMIB.ConsumableColumn.used]?.integerValue,
                                          life: columns[EpsonMIB.ConsumableColumn.life]?.integerValue))
            for (column, value) in columns where !EpsonMIB.ConsumableColumn.labelled.contains(column) {
                if let v = value.integerValue {
                    unlabelled[EpsonMIB.consumableTable.appending(column, 1, row).description] = v
                }
            }
        }

        // the scanner's own address (not loopback) from the address table
        if let entry = addresses.values.first(where: { $0.address != nil && $0.address != "127.0.0.1" }) {
            network = NetworkDetails(ipv4Address: entry.address, subnetMask: entry.mask, macAddress: mac)
        } else if mac != nil {
            network = NetworkDetails(ipv4Address: nil, subnetMask: nil, macAddress: mac)
        }
    }

    /// SNMPv2-TC `DateAndTime`: year (2 bytes), month, day, hour, minute, second, deci-second, then optionally
    /// direction (`+`/`-`), hours and minutes from UTC. Without the offset the time is taken as UTC.
    public static func date(fromDateAndTime value: SNMPValue) -> Date? {
        guard case .octets(let b) = value, b.count == 8 || b.count == 11 else { return nil }
        var c = DateComponents()
        c.year = Int(b[0]) << 8 | Int(b[1])
        c.month = Int(b[2]); c.day = Int(b[3]); c.hour = Int(b[4]); c.minute = Int(b[5]); c.second = Int(b[6])
        c.nanosecond = Int(b[7]) * 100_000_000
        var offset = 0
        if b.count == 11 {
            guard b[8] == UInt8(ascii: "+") || b[8] == UInt8(ascii: "-"), b[9] <= 14, b[10] <= 59 else { return nil }
            offset = (Int(b[9]) * 3600 + Int(b[10]) * 60) * (b[8] == UInt8(ascii: "-") ? -1 : 1)
        }
        guard (1 ... 12).contains(c.month!), (1 ... 31).contains(c.day!), c.hour! < 24, c.minute! < 60,
              c.second! < 61, b[7] < 10, let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: c)
    }
}

// MARK: - Display

extension ScannerHealth {
    /// Printable fields. The serial number, IPv4 address and MAC address are `[redacted]` unless
    /// `showIdentifiers`.
    public func displayFields(showIdentifiers: Bool = false) -> [(key: String, value: String)] {
        func shown(_ v: String) -> String { showIdentifiers ? v : "[redacted]" }
        var out: [(key: String, value: String)] = []
        if let main = firmware?.main { out.append(("Firmware (main)", main)) }
        if let network = firmware?.network { out.append(("Firmware (network)", network)) }
        if let package = firmware?.package { out.append(("Firmware package", package)) }
        if let serialNumber { out.append(("Serial number", shown(serialNumber))) }
        for part in consumables {
            let name = part.kind == .rollerKit ? "Roller assembly kit" : part.name
            var text = "\(part.used.map(String.init) ?? "?") of \(part.life.map(String.init) ?? "?") sheets"
            if let left = part.remainingFraction { text += String(format: " (%.0f%% left)", left * 100) }
            if part.isDue { text += ", due for replacement" }
            out.append((name, text))
        }
        if let clock { out.append(("Scanner clock", ISO8601DateFormatter().string(from: clock))) }
        if let uptime {
            let s = uptime.components.seconds
            out.append(("Uptime", s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) min" : "\(s / 60) min \(s % 60) s"))
        }
        if let address = network?.ipv4Address { out.append(("IPv4 address", shown(address))) }
        if let mask = network?.subnetMask { out.append(("Subnet mask", mask)) }
        if let mac = network?.macAddress { out.append(("MAC address", shown(mac))) }
        if let c = counts {
            if let v = c.feederSheets { out.append(("Sheets scanned", String(v))) }
            if let v = c.singleSided { out.append(("Single-sided", String(v))) }
            if let v = c.doubleSided { out.append(("Double-sided", String(v))) }
            if let v = c.paperJams { out.append(("Paper jams", String(v))) }
            if let v = c.doubleFeeds { out.append(("Double feeds", String(v))) }
        }
        if let p = power {
            if let v = p.sleepMinutes { out.append(("Sleep timer", "\(v) min")) }
            if let v = p.powerOffMinutes { out.append(("Power-off timer", v == 0 ? "off" : "\(v) min")) }
        }
        for key in unlabelled.keys.sorted(by: { (SNMPOID(parsing: $0) ?? "0.0") < (SNMPOID(parsing: $1) ?? "0.0") }) {
            out.append(("Unlabelled \(key)", String(unlabelled[key]!)))
        }
        return out
    }
}

/// The OIDs the health report reads: Epson's enterprise tree (1248), as found on an FF-680W with firmware 18.60
/// (28 Nov 2026, read-only walks), and standard MIB-2.
public enum EpsonMIB {
    static let epson: SNMPOID = "1.3.6.1.4.1.1248"

    /// Firmware table: values at `.n`, labels (`Main FW`, `Serial No.`, `Network FW`, `FW Package`) at the same `.n`
    /// in ``firmwareLabel``. Rows are matched by label, not number.
    public static let firmwareValue: SNMPOID = "1.3.6.1.4.1.1248.1.2.2.2.1.1.2.1"
    public static let firmwareLabel: SNMPOID = "1.3.6.1.4.1.1248.1.2.2.2.1.1.3.1"
    static let firmwareTable: SNMPOID = "1.3.6.1.4.1.1248.1.2.2.2.1.1"

    /// Consumable table, `column.1.row`. Column 3 is the name, 6 the life (200000 for the roller kit, Epson's
    /// published figure), 7 the count. Columns 2, 4 and 5 are not understood.
    public static let consumableTable: SNMPOID = "1.3.6.1.4.1.1248.1.4.2.14.1.1"
    enum ConsumableColumn {
        static let name: UInt32 = 3
        static let life: UInt32 = 6
        static let used: UInt32 = 7
        static let labelled: Set<UInt32> = [name, life, used]
    }

    /// Counter table, `column.1.1`. Matched to Epson Scan 2 Utility's Counter tab and moved by one single-sided
    /// scan, one duplex scan and one detected double feed (29 Nov 2026): column 4 = ADF sheets, 10 = single-sided,
    /// 5 = double-sided, 11 = double feeds; 6 = paper jams by value only. Columns 7 and 8 equalled column 4
    /// throughout; their difference is unknown.
    public static let counterTable: SNMPOID = "1.3.6.1.4.1.1248.1.4.2.6.1.1"
    enum CounterColumn {
        static let feederSheets: UInt32 = 4
        static let doubleSided: UInt32 = 5
        static let paperJams: UInt32 = 6
        static let singleSided: UInt32 = 10
        static let doubleFeeds: UInt32 = 11
    }

    /// Power and clock settings. Changing the timers in Epson Scan 2 Utility moved exactly ``sleepTimer`` and
    /// ``powerOffTimer`` (29 Nov 2026). `…3.3.1.3.1` (120) is not the power-off timer; it and the other small values
    /// here are unlabelled. Glass-dirt detection is not in SNMP at all.
    public static let powerSettings: SNMPOID = "1.3.6.1.4.1.1248.1.2.2.3"
    public static let sleepTimer: SNMPOID = "1.3.6.1.4.1.1248.1.2.2.3.1.1.9.1"
    public static let powerOffTimer: SNMPOID = "1.3.6.1.4.1.1248.1.2.2.3.5.1.4.1"
    /// `.n`: 0 (Off), 30, 60, 120, 240, 480, 720 on the FF-680W, as the Utility's menu.
    public static let powerOffChoices: SNMPOID = "1.3.6.1.4.1.1248.1.2.2.3.6.1.2.1"
    /// The scanner's clock, a `DateAndTime`.
    public static let clock: SNMPOID = "1.3.6.1.4.1.1248.1.2.2.3.1.1.11.1"

    public static let sysUpTime: SNMPOID = "1.3.6.1.2.1.1.3.0"
    /// `ipAddrEntry`: `.1.<ip>` address, `.3.<ip>` mask.
    public static let ipAddressEntry: SNMPOID = "1.3.6.1.2.1.4.20.1"
    public static let ifPhysAddress: SNMPOID = "1.3.6.1.2.1.2.2.1.6"

    /// What ``ScannerHealth/init(snmp:)`` expects to have been walked. Not walked on purpose: the subtree with the
    /// last client's host name (`1248.1.4.2.21`) and the Wi-Fi group (network name, access point address).
    public static let walkedSubtrees: [SNMPOID] = [
        firmwareTable, consumableTable, counterTable, powerSettings,
        "1.3.6.1.2.1.1.3", ipAddressEntry, ifPhysAddress,
    ]
}
