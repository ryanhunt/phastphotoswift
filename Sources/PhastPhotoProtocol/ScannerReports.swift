import Foundation

/// The scanner's `INFO` reply.
public struct ScannerInfo: Hashable, Sendable {
    public let fields: ESCI2Fields
    public init(fields: ESCI2Fields) { self.fields = fields }

    /// Model name, such as `FF-680W` (`#PRD`).
    public var productName: String? { fields.string("PRD") }
    /// Firmware version (`#PRV`).
    public var firmwareVersion: String? { fields.string("PRV") }
    /// Serial number (`#S/N`). Treat it as personal data: don't log or publish it.
    public var serialNumber: String? { fields.string("S/N") }
    /// Optical resolution of the feeder (`#ADF RESO`).
    public var opticalResolution: Int? { fields.values("ADF", named: "RESO")?.first?.integerValue }
    /// Whether the feeder scans both sides in one pass (`#ADF DPLX 1SCN`).
    public var supportsSinglePassDuplex: Bool { fields.values("ADF", named: "DPLX") == [.word("1SCN")] }
}

/// The scanner's `STAT` reply.
public struct ScannerStatus: Hashable, Sendable, CustomStringConvertible {
    public let fields: ESCI2Fields
    public init(fields: ESCI2Fields) { self.fields = fields }

    /// Every `#ERR` entry, such as `[ADF , PE  ]`.
    public var errors: [[ESCI2Value]] { fields["ERR"] }
    /// No `#ERR`: photos are loaded and the scanner can start.
    public var isReady: Bool { errors.isEmpty }
    /// `#ERRADF PE  `: nothing in the feeder.
    public var isFeederEmpty: Bool { errors.contains([.word("ADF "), .word("PE  ")]) }
    /// `#ERRADF PJ  `: paper jam.
    public var isPaperJammed: Bool { errors.contains([.word("ADF "), .word("PJ  ")]) }

    public var description: String {
        if isReady { return "ready" }
        if isFeederEmpty { return "feeder empty" }
        if isPaperJammed { return "paper jam" }
        return "error " + fields.description
    }
}
