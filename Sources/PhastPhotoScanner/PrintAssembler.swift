import Foundation
import PhastPhotoProtocol

/// One print as the scan delivered it: the picture and, if the mode read it, the back.
public struct AssembledPrint: Sendable {
    public let index: Int
    public let mode: SideMode
    /// The picture side, labelled B (fast mode's side A is relabelled). `nil` in back mode.
    public let picture: ScannedPage?
    /// The back of the print (side A). Present in picture, both and back modes. In picture mode it is only
    /// for reading writing on the back: hand it to the picture's processing, don't save it.
    public let back: ScannedPage?

    /// The sides to process and save after the side filter (`app.py:437`), in scan order (A first).
    public var kept: [ScannedPage] {
        [back, picture].compactMap { $0 }.filter { mode.keeps($0.side) }
    }
}

/// Pairs sides A and B by index and applies the mode's roles. Ports `app.py:639-648`: in fast mode the
/// single side A is relabelled B; in duplex modes side A (sent first) waits for its side B.
///
/// Feed pages in scan order; each ``add(_:)`` returns the prints that are now complete. Call ``finish()``
/// at the end of the scan for a back whose picture never came.
public struct PrintAssembler: Sendable {
    public let mode: SideMode
    private var pendingBack: ScannedPage?

    public init(mode: SideMode) { self.mode = mode }

    public mutating func add(_ page: ScannedPage) -> [AssembledPrint] {
        var done: [AssembledPrint] = []
        if let stale = pendingBack, stale.index != page.index {
            done.append(AssembledPrint(index: stale.index, mode: mode, picture: nil, back: stale))
            pendingBack = nil
        }
        switch mode.role(of: page.side) {
        case .back:
            if mode.duplex {
                pendingBack = page
            } else {
                done.append(AssembledPrint(index: page.index, mode: mode, picture: nil, back: page))
            }
        case .picture:
            let picture = mode.relabelled(page.side) == page.side ? page : page.relabelled(as: mode.relabelled(page.side))
            let back = pendingBack?.index == page.index ? pendingBack : nil
            pendingBack = nil
            done.append(AssembledPrint(index: page.index, mode: mode, picture: picture, back: back))
        case nil:
            break
        }
        return done
    }

    /// The back still waiting for a picture, if any.
    public mutating func finish() -> [AssembledPrint] {
        defer { pendingBack = nil }
        return pendingBack.map { [AssembledPrint(index: $0.index, mode: mode, picture: nil, back: $0)] } ?? []
    }
}
