import Foundation

/// Settings for one scan of the feeder, encoded as a `PARA` parameter block.
///
/// Both sides of a duplex scan always share these settings: `PARB` answers `#parFAIL` to everything.
public struct ScanSettings: Hashable, Sendable {
    public enum ColorMode: String, Hashable, Sendable, CaseIterable {
        /// 24-bit colour (`C024`).
        case color = "C024"
        /// 8-bit greyscale (`M008`).
        case gray = "M008"
    }

    public enum Gamma: String, Hashable, Sendable, CaseIterable {
        /// Gamma 1.0 (`UG10`).
        case linear = "UG10"
        /// Gamma 1.8 (`UG18`), the default.
        case standard = "UG18"
    }

    public enum DoubleFeedDetection: Hashable, Sendable, CaseIterable {
        case off
        /// `DFL1`
        case level1
        /// `DFL3`
        case level3
    }

    /// Main and sub-scan resolutions the FF-680W reports in `CAPA`. 600 dpi is the optical maximum.
    public static let supportedResolutions = [50, 75, 100, 150, 200, 240, 300, 360, 400, 600]
    /// The feeder's width; prints are centred in it.
    public static let feederWidthInches = 8.5
    /// The feeder's minimum document width.
    public static let minimumWidthInches = 2.0
    /// Image block size Epson's own engine sends (1 MiB).
    public static let defaultBlockSize = 1 << 20

    /// Dots per inch, one of ``supportedResolutions``.
    public var resolution: Int
    public var colorMode: ColorMode
    /// Scan both sides in one pass. Photos load face up, so side B is the picture and side A the back of the print.
    /// A single-sided scan reads only side A, the side facing down: load prints face down to get just the pictures.
    public var duplex: Bool
    /// Hardware deskew (`SKEW`). Prints still come through slightly tilted; straighten in software too.
    public var hardwareDeskew: Bool
    public var doubleFeedDetection: DoubleFeedDetection
    /// JPEG quality, 1–100.
    public var jpegQuality: Int
    public var gamma: Gamma
    /// Height of the area requested, in inches: the longest print you expect. Real heights come back per page.
    public var maximumLengthInches: Double
    /// Width of the strip read, centred like the feeder; clamped to 2–8.5 in. Narrower sends less data.
    public var widthInches: Double
    /// Image block size (`#BSZ`). Without it the scanner sends 64 KB blocks, each costing two round trips,
    /// which caps Wi-Fi throughput. `nil` leaves it out.
    public var blockSize: Int?

    public init(
        resolution: Int = 300,
        colorMode: ColorMode = .color,
        duplex: Bool = true,
        hardwareDeskew: Bool = false,
        doubleFeedDetection: DoubleFeedDetection = .off,
        jpegQuality: Int = 90,
        gamma: Gamma = .standard,
        maximumLengthInches: Double = 36,
        widthInches: Double = 8.5,
        blockSize: Int? = ScanSettings.defaultBlockSize
    ) {
        self.resolution = resolution
        self.colorMode = colorMode
        self.duplex = duplex
        self.hardwareDeskew = hardwareDeskew
        self.doubleFeedDetection = doubleFeedDetection
        self.jpegQuality = jpegQuality
        self.gamma = gamma
        self.maximumLengthInches = maximumLengthInches
        self.widthInches = widthInches
        self.blockSize = blockSize
    }

    public enum ValidationError: Error, Hashable, Sendable, CustomStringConvertible {
        case unsupportedResolution(Int)
        case jpegQualityOutOfRange(Int)
        case lengthOutOfRange(Double)

        public var description: String {
            switch self {
            case .unsupportedResolution(let dpi): "unsupported resolution \(dpi) dpi"
            case .jpegQualityOutOfRange(let q): "JPEG quality \(q) is outside 1–100"
            case .lengthOutOfRange(let l): "maximum length \(l) in is outside 2–240"
            }
        }
    }

    public func validate() throws {
        guard Self.supportedResolutions.contains(resolution) else { throw ValidationError.unsupportedResolution(resolution) }
        guard (1 ... 100).contains(jpegQuality) else { throw ValidationError.jpegQualityOutOfRange(jpegQuality) }
        guard (2 ... 240).contains(maximumLengthInches) else { throw ValidationError.lengthOutOfRange(maximumLengthInches) }
    }

    /// Scan width in pixels, clamped to the feeder's 2–8.5 in.
    public static func acquisitionWidth(widthInches: Double, resolution: Int) -> Int {
        Int(max(minimumWidthInches, min(feederWidthInches, widthInches)) * Double(resolution))
    }

    /// The `#ADF` flags: `DPLX`, `PEDT` (stop at the end of the paper), `SKEW`, `DFL1`/`DFL3`.
    /// `CRP ` (hardware crop) is accepted but has no visible effect, so it is never sent.
    public var feederFlags: String {
        var flags = (duplex ? "DPLX" : "") + "PEDT" + (hardwareDeskew ? "SKEW" : "")
        switch doubleFeedDetection {
        case .off: break
        case .level1: flags += "DFL1"
        case .level3: flags += "DFL3"
        }
        return flags
    }

    /// The `PARA` parameter block. `#BSZ` is included when ``blockSize`` is set and `includingBlockSize` is true.
    public func parameterBlock(includingBlockSize: Bool = true) -> Data {
        let width = Self.acquisitionWidth(widthInches: widthInches, resolution: resolution)
        let length = Int(maximumLengthInches * Double(resolution))
        let left = (Int(Self.feederWidthInches * Double(resolution)) - width) / 2  // prints are centred

        var p = ESCI2Parameters()
        // #ADF takes its 4-character flags concatenated as one run of bytes
        var data = Data("#ADF\(feederFlags)".utf8)
        p.append("COL", .word(colorMode.rawValue))
        p.append("FMT", .word("JPG"))
        p.append("JPG", .decimal(jpegQuality))
        p.append("GMM", .word(gamma.rawValue))
        p.append("RSM", .integer(resolution))
        p.append("RSS", .integer(resolution))
        p.append("ACQ", .integer(left), .integer(0), .integer(width), .integer(length))
        if includingBlockSize, let blockSize {
            p.append("BSZ", .integer(blockSize))
        }
        data.append(p.data)
        return data
    }
}
