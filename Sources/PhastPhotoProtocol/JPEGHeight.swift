import Foundation

public enum JPEGHeight {
    /// The scanner writes the *requested* height (`#ACQ`) into the JPEG's SOF header; patch in the real one
    /// from the page-end token (`#pen`), or every image gets a long blank bottom.
    ///
    /// Returns the data unchanged if no SOF0–SOF2 segment is found.
    public static func replacing(in jpeg: Data, with height: Int) throws -> Data {
        guard (1 ... Int(UInt16.max)).contains(height) else { throw ProtocolError.jpegHeightOutOfRange(height) }
        var out = Data(jpeg)  // indices from 0
        var i = 2  // after SOI
        while i < out.count - 9 {
            guard out[i] == 0xFF else { throw ProtocolError.badJPEGMarker(offset: i) }
            let marker = out[i + 1]
            let segmentLength = Int(out[i + 2]) << 8 | Int(out[i + 3])
            if (0xC0 ... 0xC2).contains(marker) {
                // SOF: FF Cx length(2) precision(1) height(2) width(2)
                out[i + 5] = UInt8(height >> 8)
                out[i + 6] = UInt8(height & 0xFF)
                return out
            }
            i += 2 + segmentLength
        }
        return out
    }
}
