import Foundation

/// A side of a print as the scanner labels it: A is sent first.
public enum ScanSide: String, Hashable, Sendable, CaseIterable {
    /// Side A, sent first: the side facing down. With prints loaded face up (the usual way) it is the back
    /// of the print; a single-sided scan reads only this side, so load prints face down for pictures only.
    case a = "A"
    /// Side B, the side facing up: the picture when prints are loaded face up. Duplex scans only.
    case b = "B"
}

/// What a stack is scanned for. Ports ffscan's `sides` setting (`app.py:45`, `:437`, `:630`, `:639-648`).
public enum SideMode: String, Hashable, Sendable, CaseIterable {
    /// Prints face up, duplex; keep only the pictures (side B). Side A is still read for writing on the back.
    case picture
    /// Prints face up, duplex; keep pictures and backs.
    case both
    /// Prints face up, single-sided; keep only the backs (side A).
    case back
    /// Prints face down, single-sided: about half the data. Side A is the picture, relabelled B.
    case fast

    public enum Role: Hashable, Sendable {
        case picture, back
    }

    /// Whether the scanner is asked for both sides (`app.py:630`: picture and both only).
    public var duplex: Bool { self == .picture || self == .both }

    /// The side the scanner sends that holds the picture, before any relabelling: B for face-up duplex,
    /// A for fast mode (face down), none for back mode.
    public var pictureSide: ScanSide? {
        switch self {
        case .picture, .both: .b
        case .fast: .a
        case .back: nil
        }
    }

    /// The side the scanner sends that holds the back of the print, if this mode reads it.
    public var backSide: ScanSide? {
        switch self {
        case .picture, .both, .back: .a
        case .fast: nil
        }
    }

    /// The role of a side as the scanner sends it (`nil`: this mode never receives that side).
    public func role(of side: ScanSide) -> Role? {
        if side == pictureSide { return .picture }
        if side == backSide { return .back }
        return nil
    }

    /// Fast mode relabels A as B (`app.py:639-641`) so the picture pipeline treats it as a picture.
    public func relabelled(_ side: ScanSide) -> ScanSide { self == .fast ? .b : side }

    /// Whether a side is kept after the side filter (`app.py:437`). `side` is the label after ``relabelled(_:)``.
    public func keeps(_ side: ScanSide) -> Bool {
        switch self {
        case .picture: side == .b
        case .back: side == .a
        case .both, .fast: true
        }
    }
}
