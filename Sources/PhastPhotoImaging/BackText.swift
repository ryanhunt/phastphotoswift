import Foundation

/// A date read from handwriting on a print's back: a year, optionally with a month, optionally with a day.
/// ``description`` is the ISO-like form ffscan stores: `YYYY`, `YYYY-MM` or `YYYY-MM-DD`.
public struct BackDate: Sendable, Hashable, CustomStringConvertible {
    public var year: Int
    public var month: Int?
    public var day: Int?

    public init(year: Int, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
    }

    public var description: String {
        func pad(_ value: Int, _ width: Int) -> String {
            let s = String(value)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        var out = pad(year, 4)
        if let month {
            out += "-" + pad(month, 2)
            if let day { out += "-" + pad(day, 2) }
        }
        return out
    }
}

/// Reading what a person wrote on the back of a print: dates, and a filter that drops paper watermarks and
/// machine-printed lab codes from OCR output.
public enum BackText {
    // Python `re` and ICU agree on `\b`, `\d` and `\w` being Unicode-aware, so the upstream patterns are used verbatim.
    private static func regex(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) } catch { fatalError("bad pattern \(pattern)") }
    }

    private enum Kind { case dayMonthYear, monthYear, year }

    /// Upstream `DATE_PATTERNS` (`app.py:144-148`): 14.7.1986, 14/07/86, 7.1986, 1986.
    private static let datePatterns: [(NSRegularExpression, Kind)] = [
        (regex(#"\b(\d{1,2})[./-](\d{1,2})[./-](\d{4}|\d{2})\b"#), .dayMonthYear),
        (regex(#"\b(\d{1,2})[./-](\d{4})\b"#), .monthYear),
        (regex(#"\b(19[0-9]{2}|20[0-9]{2})\b"#), .year),
    ]

    /// Upstream `WATERMARK_WORDS` (`app.py:172-175`): paper-maker watermarks and their OCR fragments.
    public static let watermarkWords: Set<String> = [
        "kodak", "koda", "kod", "dak", "odak", "fuji", "fujicolor", "fujifilm", "agfa", "konica", "ilford",
        "dnp", "quality", "paper", "made", "germany", "japan", "usa", "royal", "premium", "digital",
        "crystal", "archive", "professional", "photo", "print", "lustre", "glossy", "matte",
    ]

    // Python `\s` also matches \x0b, \x1c-\x1f and \x85; ICU `\s` does not, so they are added explicitly.
    private static let tokenSeparator = regex(#"[\s\x{0B}\x{1C}-\x{1F}\x{85},;:()\[\]•'"!?]+"#)
    private static let realWord = regex(#"\A[^\W\d_]{3,}\z"#)
    private static let standaloneYear = regex(#"(?<![\w.])(19[0-9]{2}|20[0-9]{2})(?![\w.])"#)

    private static func range(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }

    /// Integer value of a run of Unicode decimal digits (Python's `int()` accepts them, `Int()` does not).
    private static func number(_ s: Substring) -> Int? {
        var value = 0
        for ch in s {
            guard let d = ch.wholeNumberValue else { return nil }
            value = value * 10 + d
        }
        return value
    }

    /// The date written on a back, or nil. Port of `date_from_text` (`app.py:151-168`; the code, not the docstring).
    ///
    /// Patterns are tried in order and the first match of each is used. Day/month order is day first unless
    /// that is impossible (`a <= 12 < b` swaps them, so `7/14/86` is 14 July). A month-year match that is out of
    /// range ends the search with nil, whereas an invalid day-month-year falls through to the next pattern.
    public static func date(from text: String) -> BackDate? {
        for (pattern, kind) in datePatterns {
            guard let m = pattern.firstMatch(in: text, range: range(text)) else { continue }
            func group(_ i: Int) -> Substring {
                Range(m.range(at: i), in: text).map { text[$0] } ?? ""
            }
            switch kind {
            case .year:
                guard let year = number(group(1)) else { continue }
                return BackDate(year: year)
            case .monthYear:
                guard let month = number(group(1)), let year = number(group(2)) else { return nil }
                return (1...12).contains(month) && (1900...2099).contains(year)
                    ? BackDate(year: year, month: month) : nil
            case .dayMonthYear:
                guard let a = number(group(1)), let b = number(group(2)), var year = number(group(3)) else { continue }
                if year < 100 { year += 1900 }
                let (day, month) = (a <= 12 && 12 < b) ? (b, a) : (a, b)
                if (1...12).contains(month), (1...31).contains(day), (1900...2099).contains(year) {
                    return BackDate(year: year, month: month, day: day)
                }
            }
        }
        return nil
    }

    /// Python `str.splitlines()` line boundaries.
    private static func lines(of text: String) -> [String] {
        let breaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{0B}", "\u{0C}", "\u{1C}", "\u{1D}", "\u{1E}",
                                           "\u{85}", "\u{2028}", "\u{2029}"]
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n", previousWasCR { previousWasCR = false; continue }  // the LF of a CRLF
            previousWasCR = scalar == "\r"
            if breaks.contains(scalar) {
                out.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// Keep only the lines that look written by a person, dropping paper watermarks and machine-printed lab
    /// codes. Port of `human_text` (`app.py:178-193`).
    ///
    /// A line is kept if it holds a date with separators (14.7.1986, 08/1992), at least two real words (three or
    /// more letters, no digits or underscores, not a watermark word), or one word plus a standalone year
    /// ("Mom 1986"). Letters glued to digits ("L3145CAXCNO") belong to a lab code and are not words.
    /// Kept lines are stripped of surrounding whitespace and joined with newlines.
    public static func humanText(_ text: String) -> String {
        humanText([BackLine(text: text)])
    }

    /// ``humanText(_:)-(String)`` over recognised lines, where a line known to be in pen (``PenInk``) is also kept
    /// when it is a single real word and nothing else ("Mum", a name; not "0001 NNNN"). Not in ffscan, which drops a lone word: the paper maker's pattern
    /// reads as lone words too ("rchive", "FILMI"), but in faint ink.
    public static func humanText(_ backLines: [BackLine]) -> String {
        var kept: [String] = []
        for backLine in backLines {
            for line in lines(of: backLine.text) {
                let tokens = split(line, by: tokenSeparator)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-")) }
                let words = tokens.filter {
                    realWord.firstMatch(in: $0, range: range($0)) != nil && !watermarkWords.contains($0.lowercased())
                }
                let separatedDate = datePatterns.contains { pattern, kind in
                    kind != .year && pattern.firstMatch(in: line, range: range(line)) != nil
                }
                let hasYear = standaloneYear.firstMatch(in: line, range: range(line)) != nil
                // a pen line must be the word alone: dark lab codes mix words with numbers ("0001 NNNN")
                let loneWord = words.count == 1 && tokens.filter { !$0.isEmpty }.count == 1
                if separatedDate || words.count >= 2 || (!words.isEmpty && hasYear) || (backLine.penInk && loneWord) {
                    kept.append(line.trimmingCharacters(in: pythonWhitespace))
                }
            }
        }
        return kept.joined(separator: "\n")
    }

    /// Python `str.strip()` strips Unicode whitespace plus the separators `\x1c`-`\x1f`.
    private static let pythonWhitespace: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{1C}\u{1D}\u{1E}\u{1F}")
        return set
    }()

    /// `re.split`: the pieces between matches (empty pieces kept, as Python does).
    private static func split(_ s: String, by regex: NSRegularExpression) -> [String] {
        var pieces: [String] = []
        var start = s.startIndex
        for m in regex.matches(in: s, range: range(s)) {
            guard let r = Range(m.range, in: s) else { continue }
            pieces.append(String(s[start..<r.lowerBound]))
            start = r.upperBound
        }
        pieces.append(String(s[start...]))
        return pieces
    }
}

/// One recognised line on a print's back, and whether it is written in strong ink (``PenInk/isWritten(in:box:paper:)``).
public struct BackLine: Hashable, Sendable {
    public var text: String
    public var penInk: Bool

    public init(text: String, penInk: Bool = false) {
        self.text = text
        self.penInk = penInk
    }
}
