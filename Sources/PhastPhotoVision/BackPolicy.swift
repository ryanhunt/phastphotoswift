import Foundation

/// What to do with a scanned back, as a pure decision table. Ports `read_back` (`app.py:196-205`),
/// `back_with_writing` (`:502-512`), the blank-back rule (`:443-448`) and the fast-mode rule (`:449-455`).
///
/// Ink fractions come from the imaging module (on the cropped side), back text from its human-text filter.
/// One line of handwriting scores about 0.008 ink and printed lab codes 0.000-0.012, both under
/// `blankThreshold`: never drop a back on ink alone, only when it also has no text.
public enum BackPolicy {
    /// `back_with_writing(threshold=0.002)` in `read_back`: any back with marks is read.
    public static let readThreshold = 0.002
    /// Default `blank_threshold` (`app.py:47`).
    public static let blankThreshold = 0.015

    /// Upstream `sides` setting.
    public enum Sides: String, Hashable, Sendable { case picture, both, back, fast }
    public enum Side: String, Hashable, Sendable { case a = "A", b = "B" }

    public enum Skip: Hashable, Sendable {
        case blankBack(ink: Double)
        /// Fast mode reads only the face-down side; a blank one means the prints were loaded face up.
        case facedUpInFastMode
        public var reason: String {
            switch self {
            case .blankBack(let ink): return "blank back (ink \(String(format: "%.3f", ink)))"
            case .facedUpInFastMode:
                return "was the back of the print: Fast mode reads only the side facing down, so load photos face DOWN"
            }
        }
    }

    /// `back_with_writing`: true when the back has marks (ink >= threshold) and so is worth reading.
    public static func hasWriting(ink: Double, threshold: Double = readThreshold) -> Bool { ink >= threshold }

    /// `read_back`: "" without marks, otherwise whatever `ocr` returns. `ocr` should read the back and apply
    /// the human-text filter, returning "" when nothing counts as writing.
    public static func readBack(ink: Double, ocr: () async throws -> String) async rethrows -> String {
        guard hasWriting(ink: ink) else { return "" }
        return try await ocr()
    }

    /// Decides whether a saved page is dropped (`app.py:443-455`), in upstream's order: the blank-back rule
    /// first, then the fast-mode rule.
    /// - Parameters:
    ///   - backText: the filtered back text, or nil/"" for none (only used for side A).
    ///   - ink: ink fraction of the cropped page (the fast rule needs the crop to be on).
    public static func skip(side: Side, sides: Sides, skipBlankBacks: Bool, crop: Bool, backText: String?,
                            ink: Double, blankThreshold: Double = blankThreshold) -> Skip? {
        if side == .a, skipBlankBacks, sides != .back, (backText ?? "").isEmpty, ink < blankThreshold {
            return .blankBack(ink: ink)
        }
        if sides == .fast, crop, ink < blankThreshold { return .facedUpInFastMode }
        return nil
    }
}
