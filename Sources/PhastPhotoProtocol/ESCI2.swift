import Foundation

/// Epson's ESC/I-2 command set, carried in `0x2000` "IS" packets over Wi-Fi or raw over USB (docs/PROTOCOL.md §2).
public enum ESCI2 {
    /// `FS X`: switch to ESC/I-2. The scanner answers ``acknowledge``.
    public static let enterCommandMode = Data([0x1C, 0x58])
    public static let acknowledge: UInt8 = 0x06
    /// Every reply starts with a header of this size; the body is read separately.
    public static let replyHeaderLength = 64

    /// Parse a sequence of `#KEY` tokens and their values. `#---` padding is dropped.
    ///
    /// Values: `d` + 3 digits, `i` + 7 digits (may be negative) and `x` + 7 hex digits are integers;
    /// `h` + 3 hex digits + bytes (padded to a multiple of 4) is a byte string; anything else is a 4-character word.
    public static func parseTokens(_ data: Data) -> [ESCI2Token] {
        let b = [UInt8](data)
        let n = b.count
        func slice(_ from: Int, _ length: Int) -> ArraySlice<UInt8> {
            let lo = min(from, n)
            return b[lo ..< min(from + length, n)]
        }
        var out: [ESCI2Token] = []
        var i = 0
        while i < n {
            guard b[i] == hash else { i += 1; continue }
            let key = latin1(slice(i + 1, 3))
            i += 4
            var values: [ESCI2Value] = []
            while i < n, b[i] != hash {
                let t = b[i]
                if t == ascii("d"), let v = decimal(slice(i + 1, 3)) {
                    values.append(.integer(v)); i += 4
                } else if t == ascii("i"), let v = signedDecimal(slice(i + 1, 7)) {
                    values.append(.integer(v)); i += 8
                } else if t == ascii("x"), let v = upperHex(slice(i + 1, 7), digits: 7) {
                    values.append(.integer(v)); i += 8
                } else if t == ascii("h"), let length = upperHex(slice(i + 1, 3), digits: 3) {
                    values.append(.bytes(Data(slice(i + 4, length))))
                    i += 4 + length + (4 - length % 4) % 4
                } else {
                    values.append(.word(latin1(slice(i, 4)))); i += 4
                }
            }
            if key != "---" {
                out.append(ESCI2Token(key: key, values: values))
            }
        }
        return out
    }

    // MARK: - Lexing helpers

    static let hash = ascii("#")

    static func ascii(_ c: Unicode.Scalar) -> UInt8 { UInt8(ascii: c) }

    static func latin1<S: Sequence<UInt8>>(_ bytes: S) -> String {
        var s = ""
        s.unicodeScalars.append(contentsOf: bytes.map { Unicode.Scalar($0) })
        return s
    }

    static func isDigit(_ c: UInt8) -> Bool { c >= ascii("0") && c <= ascii("9") }

    static func decimal(_ s: ArraySlice<UInt8>) -> Int? {
        guard !s.isEmpty, s.allSatisfy(isDigit) else { return nil }
        return Int(latin1(s))
    }

    static func signedDecimal(_ s: ArraySlice<UInt8>) -> Int? {
        let digits = s.first == ascii("-") ? s.dropFirst() : s
        guard !digits.isEmpty, digits.allSatisfy(isDigit) else { return nil }
        return Int(latin1(s))
    }

    static func upperHex(_ s: ArraySlice<UInt8>, digits: Int) -> Int? {
        guard s.count == digits,
              s.allSatisfy({ isDigit($0) || ($0 >= ascii("A") && $0 <= ascii("F")) }) else { return nil }
        return Int(latin1(s), radix: 16)
    }
}

/// One value of an ESC/I-2 token.
public enum ESCI2Value: Hashable, Sendable, CustomStringConvertible {
    /// `d`, `i` or `x` on the wire.
    case integer(Int)
    /// `h` on the wire: a counted byte string, padding removed.
    case bytes(Data)
    /// A 4-character word such as `FEED` or `JPG ` (spaces kept).
    case word(String)

    public var integerValue: Int? { if case .integer(let v) = self { v } else { nil } }
    public var wordValue: String? { if case .word(let v) = self { v } else { nil } }
    public var bytesValue: Data? { if case .bytes(let v) = self { v } else { nil } }

    public var description: String {
        switch self {
        case .integer(let v): String(v)
        case .word(let w): w.debugDescription
        case .bytes(let d):
            if d.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
                String(decoding: d, as: UTF8.self).debugDescription
            } else {
                "<" + d.map { String(format: "%02X", $0) }.joined() + ">"
            }
        }
    }
}

/// `#KEY` followed by its values. One key can appear several times (`#ADFTYPEFEED#ADFDPLX1SCN`).
public struct ESCI2Token: Hashable, Sendable, CustomStringConvertible {
    public var key: String
    public var values: [ESCI2Value]

    public init(key: String, values: [ESCI2Value]) {
        self.key = key
        self.values = values
    }

    public var description: String { "#\(key) " + values.map(\.description).joined(separator: " ") }
}

/// Parsed tokens of a reply header or body, in wire order, with lookup by key.
public struct ESCI2Fields: Hashable, Sendable, CustomStringConvertible {
    public var tokens: [ESCI2Token]

    public init(_ tokens: [ESCI2Token] = []) { self.tokens = tokens }
    public init(parsing data: Data) { self.init(ESCI2.parseTokens(data)) }

    /// The values of every occurrence of `key`, in order; empty if absent.
    public subscript(key: String) -> [[ESCI2Value]] {
        tokens.filter { $0.key == key }.map(\.values)
    }

    /// The values of the first occurrence of `key`.
    public func first(_ key: String) -> [ESCI2Value]? {
        tokens.first { $0.key == key }?.values
    }

    public func contains(_ key: String) -> Bool { tokens.contains { $0.key == key } }

    /// Keys in first-seen order, without repeats.
    public var keys: [String] {
        var seen = Set<String>()
        return tokens.map(\.key).filter { seen.insert($0).inserted }
    }

    /// The first `key`'s byte-string value as text, without NUL padding.
    public func string(_ key: String) -> String? {
        guard let data = first(key)?.first?.bytesValue else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
    }

    /// For a key whose occurrences start with a sub-name (`#ADFAREAd850i0001550`): the values after `name`.
    public func values(_ key: String, named name: String) -> [ESCI2Value]? {
        self[key].first { $0.first == .word(name) }.map { Array($0.dropFirst()) }
    }

    public var description: String { tokens.map(\.description).joined(separator: " ") }
}

/// Builds an ESC/I-2 parameter block such as `#COLC024#JPGd090#RSMi0000300`.
public struct ESCI2Parameters: Hashable, Sendable {
    public enum Item: Hashable, Sendable {
        /// `d` + 3 decimal digits (0–999).
        case decimal(Int)
        /// `i` + 7 characters (−999999 to 9999999).
        case integer(Int)
        /// `x` + 7 hex digits.
        case hex(Int)
        /// `h` + 3 hex digits of length + bytes, NUL-padded to a multiple of 4.
        case string(Data)
        /// A word of up to 4 ASCII characters, space-padded (`JPG `).
        case word(String)
    }

    public private(set) var data = Data()

    public init() {}

    public mutating func append(_ key: String, _ items: [Item]) {
        precondition(key.utf8.count == 3, "ESC/I-2 keys are 3 characters: \(key)")
        data.append(ESCI2.hash)
        data.append(contentsOf: key.utf8)
        for item in items {
            switch item {
            case .decimal(let v):
                precondition((0 ... 999).contains(v), "d value out of range: \(v)")
                data.append(contentsOf: ("d" + Self.zeroPadded(v, 3)).utf8)
            case .integer(let v):
                precondition((-999_999 ... 9_999_999).contains(v), "i value out of range: \(v)")
                data.append(contentsOf: ("i" + (v < 0 ? "-" + Self.zeroPadded(-v, 6) : Self.zeroPadded(v, 7))).utf8)
            case .hex(let v):
                precondition((0 ... 0xFFF_FFFF).contains(v), "x value out of range: \(v)")
                data.append(contentsOf: ("x" + Self.hex(v, 7)).utf8)
            case .string(let bytes):
                precondition(bytes.count <= 0xFFF, "h value too long: \(bytes.count) bytes")
                data.append(contentsOf: ("h" + Self.hex(bytes.count, 3)).utf8)
                data.append(bytes)
                data.append(contentsOf: [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4))
            case .word(let w):
                precondition(w.utf8.count <= 4 && w.utf8.allSatisfy { $0 < 0x80 }, "words are up to 4 ASCII characters: \(w)")
                data.append(contentsOf: w.padding(toLength: 4, withPad: " ", startingAt: 0).utf8)
            }
        }
    }

    public mutating func append(_ key: String, _ items: Item...) { append(key, items) }

    static func zeroPadded(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    static func hex(_ v: Int, _ width: Int) -> String {
        let s = String(v, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}

/// A 4-character ESC/I-2 command.
public struct ESCI2Command: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(rawValue.utf8.count == 4, "ESC/I-2 commands are 4 characters: \(rawValue)")
        self.rawValue = rawValue
    }

    /// Model, firmware, serial number, feeder geometry.
    public static let info = ESCI2Command(rawValue: "INFO")
    /// Capabilities.
    public static let capabilities = ESCI2Command(rawValue: "CAPA")
    /// Back-side capabilities (empty on the FF-680W).
    public static let backCapabilities = ESCI2Command(rawValue: "CAPB")
    /// Status: no `#ERR` means ready.
    public static let status = ESCI2Command(rawValue: "STAT")
    /// Scan settings.
    public static let parameters = ESCI2Command(rawValue: "PARA")
    /// Start the scan: the scanner starts feeding.
    public static let startTransfer = ESCI2Command(rawValue: "TRDT")
    /// Pull image data. Keep polling while it returns empty replies.
    public static let image = ESCI2Command(rawValue: "IMG ")
    /// Cancel a running scan.
    public static let cancel = ESCI2Command(rawValue: "CAN ")
    /// Leave ESC/I-2 mode.
    public static let finish = ESCI2Command(rawValue: "FIN ")

    /// The 12-byte request header: `<command> 'x' <7 hex digits: parameter block length>`.
    public func requestHeader(parameterLength: Int) -> Data {
        Data((rawValue + "x" + ESCI2Parameters.hex(parameterLength, 7)).utf8)
    }

    public var description: String { rawValue }
}

/// The 64-byte header every reply starts with: `<command>x<7 hex digits: body length>` followed by tokens.
public struct ESCI2ReplyHeader: Hashable, Sendable {
    public let raw: Data
    /// The command echoed back, or `INVD` when the command isn't valid in the current state.
    public let command: String
    public let bodyLength: Int
    public let fields: ESCI2Fields

    public init(_ raw: Data) throws {
        let b = [UInt8](raw)
        guard b.count >= 12, b[4] == ESCI2.ascii("x"),
              let length = Int(ESCI2.latin1(b[5 ..< 12]), radix: 16), length >= 0 else {
            throw ProtocolError.malformedReplyHeader(raw)
        }
        self.raw = Data(b)
        command = ESCI2.latin1(b[0 ..< 4])
        bodyLength = length
        fields = ESCI2Fields(parsing: Data(b[12...]))
    }

    /// `INVD`: the command wasn't valid in the current state (after a scan: the transfer is finished).
    public var isInvalidCommand: Bool { command == "INVD" }

    /// A `PARA` reply that accepted every setting.
    public var parametersAccepted: Bool { raw.range(of: Data("#parOK".utf8)) != nil }
}
