import Foundation

extension ScannerStatus {
    /// Text for people, after ffscan's `describe_error` (`app.py:716-722`). The upstream test is a substring
    /// match on the flattened error ("PE" also matches "OPEN"); this matches the `ADF` error words exactly.
    public var friendlyMessage: String {
        if isReady { return "Ready." }
        if isFeederEmpty { return "Feeder is empty: load photos face up." }
        if isPaperJammed { return "Paper jam: open the cover, remove the photo, close the cover." }
        let flat = errors.map { $0.map(\.description).joined(separator: " ") }.joined(separator: " ")
        return "Scanner reports: \(flat)"
    }
}

extension ScannerInfo {
    /// Printable fields with the serial number (`#S/N`) replaced by `[redacted]` unless `showSerial`.
    /// A serial number is personal data: keep it out of logs and screenshots by default.
    public func displayFields(showSerial: Bool = false) -> [(key: String, value: String)] {
        fields.keys.map { key in
            let value = fields[key].map { "[" + $0.map(\.description).joined(separator: ", ") + "]" }.joined(separator: " ")
            return (key, !showSerial && key == "S/N" ? "[redacted]" : value)
        }
    }
}
