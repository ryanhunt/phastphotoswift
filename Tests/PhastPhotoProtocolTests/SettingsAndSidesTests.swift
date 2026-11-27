import Foundation
import Testing
@testable import PhastPhotoProtocol

@Suite struct SettingsValidationTests {
    @Test func rejectsLengthTimesDpiOver65535() {
        // 240 in is the longest allowed length; 240 x 300 = 72000 lines does not fit in 16 bits
        let tooLong = ScanSettings(resolution: 300, maximumLengthInches: 240)
        #expect(throws: ScanSettings.ValidationError.scanTooLong(inches: 240, resolution: 300)) { try tooLong.validate() }
        // 109 in x 600 dpi = 65400 passes, 110 in x 600 = 66000 does not
        #expect(throws: Never.self) { try ScanSettings(resolution: 600, maximumLengthInches: 109).validate() }
        #expect(throws: ScanSettings.ValidationError.self) { try ScanSettings(resolution: 600, maximumLengthInches: 110).validate() }
    }

    @Test func defaultsStayValid() throws {
        try ScanSettings().validate()
        try ScanSettings(resolution: 600).validate()  // 36 in x 600 dpi
    }

    @Test func photoDefaultsMatchFfscan() throws {
        let d = ScanSettings.photoDefaults
        #expect(d.resolution == 300 && d.colorMode == .color)
        #expect(d.hardwareDeskew && d.doubleFeedDetection == .level1)
        #expect(d.jpegQuality == 90 && d.widthInches == 8.5 && d.duplex)
        try d.validate()
        #expect(d.feederFlags == "DPLXSKEWCRP PEDTDFL1")  // ffscan's flags plus hardware crop
    }

    @Test func sideModeSetsDuplex() {
        #expect(ScanSettings.photoDefaults.with(sideMode: .fast).duplex == false)
        #expect(ScanSettings.photoDefaults.with(sideMode: .back).duplex == false)
        #expect(ScanSettings.photoDefaults.with(sideMode: .both).duplex)
        #expect(ScanSettings.photoDefaults.with(sideMode: .picture).duplex)
    }
}

@Suite struct SideModeTests {
    @Test func duplexMapping() {
        #expect(SideMode.allCases.map(\.duplex) == [true, true, false, false])  // picture both back fast
    }

    @Test func whichSideIsThePicture() {
        #expect(SideMode.picture.pictureSide == .b && SideMode.picture.backSide == .a)
        #expect(SideMode.both.pictureSide == .b && SideMode.both.backSide == .a)
        #expect(SideMode.back.pictureSide == nil && SideMode.back.backSide == .a)
        #expect(SideMode.fast.pictureSide == .a && SideMode.fast.backSide == nil)  // face down: A is the picture
        #expect(SideMode.fast.role(of: .a) == .picture && SideMode.fast.role(of: .b) == nil)
        #expect(SideMode.back.role(of: .b) == nil)
    }

    @Test func relabelAndFilter() {
        #expect(SideMode.fast.relabelled(.a) == .b)
        #expect(SideMode.picture.relabelled(.a) == .a)
        #expect(SideMode.picture.keeps(.b) && !SideMode.picture.keeps(.a))
        #expect(SideMode.back.keeps(.a) && !SideMode.back.keeps(.b))
        #expect(SideMode.both.keeps(.a) && SideMode.both.keeps(.b))
        #expect(SideMode.fast.keeps(.b))
    }
}

@Suite struct MessageTests {
    @Test func friendlyStatus() {
        func status(_ s: String) -> ScannerStatus { ScannerStatus(fields: ESCI2Fields(parsing: Data(s.utf8))) }
        #expect(status("").friendlyMessage == "Ready.")
        #expect(status("#ERRADF PE  ").friendlyMessage == "Feeder is empty: load photos face up.")
        #expect(status("#ERRADF PJ  ").friendlyMessage.hasPrefix("Paper jam"))
        #expect(status("#ERRCOVROPEN").friendlyMessage.hasPrefix("Scanner reports:"))
    }

    @Test func serialNumberIsRedactedByDefault() {
        let info = ScannerInfo(fields: ESCI2Fields(parsing: TokenParsingTests.info))
        let hidden = info.displayFields().map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        #expect(!hidden.contains("X0AB000000"))
        #expect(hidden.contains("S/N=[redacted]"))
        #expect(info.displayFields(showSerial: true).contains { $0.key == "S/N" && $0.value.contains("X0AB000000") })
    }
}
