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
    /// Hardware crop (`CRP `), sent next to `PEDT` as SANE's epsonds backend does (sane-backends MR 919). On
    /// by default: on FF-680W firmware 18.60 paper-end detection only takes effect with it, and without it every
    /// page runs to ``maximumLengthInches`` (36 in of backing below the print) and a stack stops after the first
    /// print. With it, each page is cut to the paper (an A4 print came back 8.3 x 11.75 in, an 80 mm receipt
    /// 3.1 in wide). The pages then have no backing around them, so don't crop them in software again
    /// (``ScannedPage/hardwareCropped`` tells the pipeline).
    public var hardwareCrop: Bool
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
        blockSize: Int? = ScanSettings.defaultBlockSize,
        hardwareCrop: Bool = true
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
        self.hardwareCrop = hardwareCrop
    }

    public enum ValidationError: Error, Hashable, Sendable, CustomStringConvertible {
        case unsupportedResolution(Int)
        case jpegQualityOutOfRange(Int)
        case lengthOutOfRange(Double)
        /// `length × dpi` exceeds 65535 lines: `#IMX` and the JPEG SOF height are 16-bit.
        case scanTooLong(inches: Double, resolution: Int)

        public var description: String {
            switch self {
            case .unsupportedResolution(let dpi): "unsupported resolution \(dpi) dpi"
            case .jpegQualityOutOfRange(let q): "JPEG quality \(q) is outside 1–100"
            case .lengthOutOfRange(let l): "maximum length \(l) in is outside 2–240"
            case .scanTooLong(let inches, let dpi):
                "\(inches) in at \(dpi) dpi is \(Int(inches * Double(dpi))) lines; the most one page can have is \(ScanSettings.maximumLines)"
            }
        }
    }

    public func validate() throws {
        guard Self.supportedResolutions.contains(resolution) else { throw ValidationError.unsupportedResolution(resolution) }
        guard (1 ... 100).contains(jpegQuality) else { throw ValidationError.jpegQualityOutOfRange(jpegQuality) }
        guard (2 ... 240).contains(maximumLengthInches) else { throw ValidationError.lengthOutOfRange(maximumLengthInches) }
        guard Int(maximumLengthInches * Double(resolution)) <= Self.maximumLines else {
            throw ValidationError.scanTooLong(inches: maximumLengthInches, resolution: resolution)
        }
    }

    /// The most lines one page can have: `#IMX` and the JPEG SOF height are 16-bit.
    public static let maximumLines = 65535

    /// ffscan's app defaults (`app.py:43-52`): 300 dpi, colour, hardware deskew on, double-feed level 1,
    /// JPEG quality 90, full 8.5 in width. Duplex, like ``SideMode/picture``.
    public static var photoDefaults: ScanSettings {
        ScanSettings(resolution: 300, colorMode: .color, duplex: true, hardwareDeskew: true,
                     doubleFeedDetection: .level1, jpegQuality: 90, widthInches: 8.5)
    }

    /// These settings with `duplex` set for `mode` (`app.py:630`).
    public func with(sideMode mode: SideMode) -> ScanSettings {
        var copy = self
        copy.duplex = mode.duplex
        return copy
    }

    /// Scan width in pixels, clamped to the feeder's 2–8.5 in.
    public static func acquisitionWidth(widthInches: Double, resolution: Int) -> Int {
        Int(max(minimumWidthInches, min(feederWidthInches, widthInches)) * Double(resolution))
    }

    /// The `#ADF` flags: `DPLX`, `PEDT` (stop at the end of the paper), `SKEW`, `DFL1`/`DFL3`, and `CRP ` with
    /// ``hardwareCrop``, in SANE's order (`DPLX`, `SKEW`, `CRP `, `PEDT`).
    public var feederFlags: String {
        if hardwareCrop {
            var flags = (duplex ? "DPLX" : "") + (hardwareDeskew ? "SKEW" : "") + "CRP PEDT"
            switch doubleFeedDetection {
            case .off: break
            case .level1: flags += "DFL1"
            case .level3: flags += "DFL3"
            }
            return flags
        }
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
