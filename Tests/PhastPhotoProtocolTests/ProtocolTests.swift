import Foundation
import Testing
@testable import PhastPhotoProtocol

// Fixtures are real FF-680W replies from ffscan's tests, with the serial number replaced.

@Suite struct TokenParsingTests {
    static let info = Data("#ADFTYPEFEED#ADFDPLX1SCN#ADFAREAd850i0001550#IMXi0065535i0065535#PRDh007FF-680W".utf8)
        + Data([0]) + Data("#PRVh00C18.61.SP18P4#S/Nh00AX0AB000000".utf8) + Data([0, 0]) + Data("#AFM#DFMd100#EXI".utf8)

    @Test func infoReply() {
        let fields = ESCI2Fields(parsing: Self.info)
        #expect(fields["ADF"] == [
            [.word("TYPE"), .word("FEED")],
            [.word("DPLX"), .word("1SCN")],
            [.word("AREA"), .integer(850), .integer(1550)],
        ])
        #expect(fields["PRD"] == [[.bytes(Data("FF-680W".utf8))]])
        #expect(fields["S/N"] == [[.bytes(Data("X0AB000000".utf8))]])
        #expect(fields["PRV"] == [[.bytes(Data("18.61.SP18P4".utf8))]])
        #expect(fields["DFM"] == [[.integer(100)]])
        #expect(fields["AFM"] == [[]])
        #expect(fields["EXI"] == [[]])

        let info = ScannerInfo(fields: fields)
        #expect(info.productName == "FF-680W")
        #expect(info.firmwareVersion == "18.61.SP18P4")
        #expect(info.serialNumber == "X0AB000000")
        #expect(info.supportsSinglePassDuplex)
    }

    @Test func pageEndHeader() {
        let fields = ESCI2Fields(parsing: Data("#peni0002550i0001263#lftd000#typIMGB#---#---".utf8))
        #expect(fields.keys == ["pen", "lft", "typ"])
        #expect(fields["pen"] == [[.integer(2550), .integer(1263)]])
        #expect(fields["lft"] == [[.integer(0)]])
        #expect(fields["typ"] == [[.word("IMGB")]])
    }

    @Test func negativeInteger() {
        let fields = ESCI2Fields(parsing: Data("#CRPRANGi-000020d020".utf8))
        #expect(fields["CRP"] == [[.word("RANG"), .integer(-20), .integer(20)]])
    }

    @Test func statusErrors() {
        let empty = ScannerStatus(fields: ESCI2Fields(parsing: Data("#ERRADF PE  ".utf8)))
        #expect(empty.errors == [[.word("ADF "), .word("PE  ")]])
        #expect(empty.isFeederEmpty && !empty.isReady && !empty.isPaperJammed)

        let jam = ScannerStatus(fields: ESCI2Fields(parsing: Data("#ERRADF PJ  ".utf8)))
        #expect(jam.isPaperJammed)
        #expect(ScannerStatus(fields: ESCI2Fields()).isReady)
    }

    @Test func truncatedInputDoesNotCrash() {
        for text in ["#", "#AD", "#ADFd1", "#ADFh00F", "#ADFi-", "#ADFx12"] {
            _ = ESCI2.parseTokens(Data(text.utf8))
        }
        #expect(ESCI2Fields(parsing: Data("#ADFd12".utf8))["ADF"] == [[.integer(12)]])
    }
}

@Suite struct ParameterTests {
    @Test func encodesEveryValueKind() {
        var p = ESCI2Parameters()
        p.append("JPG", .decimal(90))
        p.append("CRP", .word("RANG"), .integer(-20), .integer(20))
        p.append("BSZ", .hex(0x100000))
        p.append("PRD", .string(Data("FF-680W".utf8)))
        p.append("FMT", .word("JPG"))
        #expect(p.data == Data("#JPGd090#CRPRANGi-000020i0000020#BSZx0100000#PRDh007FF-680W".utf8) + Data([0])
            + Data("#FMTJPG ".utf8))

        let parsed = ESCI2Fields(parsing: p.data)
        #expect(parsed["CRP"] == [[.word("RANG"), .integer(-20), .integer(20)]])
        #expect(parsed.string("PRD") == "FF-680W")
        #expect(parsed["BSZ"] == [[.integer(0x100000)]])
    }

    @Test func documentedScanParameters() {
        // docs/PROTOCOL.md §3, without SKEW and DFL1, and without hardware crop (ffscan's flags)
        let expected = "#ADFDPLXPEDT#COLC024#FMTJPG #JPGd090#GMMUG18"
            + "#RSMi0000300#RSSi0000300#ACQi0000000i0000000i0002550i0010800#BSZi1048576"
        #expect(String(decoding: ScanSettings(hardwareCrop: false).parameterBlock(), as: UTF8.self) == expected)

        var settings = ScanSettings(hardwareDeskew: true, doubleFeedDetection: .level1, hardwareCrop: false)
        #expect(String(decoding: settings.parameterBlock(), as: UTF8.self).hasPrefix("#ADFDPLXPEDTSKEWDFL1#COL"))
        settings.blockSize = nil
        #expect(!String(decoding: settings.parameterBlock(), as: UTF8.self).contains("#BSZ"))
        #expect(!String(decoding: ScanSettings().parameterBlock(includingBlockSize: false), as: UTF8.self).contains("#BSZ"))
    }

    @Test func narrowScanIsCentred() {
        let settings = ScanSettings(resolution: 600, duplex: false, widthInches: 6.5)
        let acq = ESCI2Fields(parsing: settings.parameterBlock())["ACQ"]
        #expect(acq == [[.integer(600), .integer(0), .integer(3900), .integer(21600)]])
        #expect(settings.feederFlags == "CRP PEDT")
    }

    /// Hardware crop is on by default, in SANE epsonds' order (sane-backends MR 919): on FF-680W firmware 18.60
    /// paper-end detection works only with it (27 Nov 2026: 36 in pages without it, the paper's size with it).
    @Test func hardwareCropGoesWithPaperEnd() {
        #expect(ScanSettings().hardwareCrop)
        #expect(String(decoding: ScanSettings().parameterBlock(), as: UTF8.self).hasPrefix("#ADFDPLXCRP PEDT#COLC024"))
        let all = ScanSettings(hardwareDeskew: true, doubleFeedDetection: .level3)
        #expect(all.feederFlags == "DPLXSKEWCRP PEDTDFL3")
        #expect(ScanSettings(duplex: false, hardwareCrop: false).feederFlags == "PEDT")
    }

    @Test func acquisitionWidthIsClamped() {
        #expect(ScanSettings.acquisitionWidth(widthInches: 8.5, resolution: 600) == 5100)
        #expect(ScanSettings.acquisitionWidth(widthInches: 8.5, resolution: 300) == 2550)
        #expect(ScanSettings.acquisitionWidth(widthInches: 6.5, resolution: 600) == 3900)
        #expect(ScanSettings.acquisitionWidth(widthInches: 20, resolution: 600) == 5100)
        #expect(ScanSettings.acquisitionWidth(widthInches: 1, resolution: 300) == 600)
    }

    @Test func validation() throws {
        try ScanSettings().validate()
        #expect(throws: ScanSettings.ValidationError.unsupportedResolution(500)) { try ScanSettings(resolution: 500).validate() }
        #expect(throws: ScanSettings.ValidationError.jpegQualityOutOfRange(0)) { try ScanSettings(jpegQuality: 0).validate() }
    }
}

@Suite struct CommandTests {
    @Test func requestHeader() {
        #expect(ESCI2Command.info.requestHeader(parameterLength: 0) == Data("INFOx0000000".utf8))
        #expect(ESCI2Command.parameters.requestHeader(parameterLength: 0x6A) == Data("PARAx000006A".utf8))
        #expect(ESCI2Command.image.requestHeader(parameterLength: 0) == Data("IMG x0000000".utf8))
    }

    static func padded(_ text: String) -> Data {
        var s = text
        while s.utf8.count < 64 { s += "#---" }
        return Data(s.utf8.prefix(64))
    }

    @Test func replyHeader() throws {
        let image = try ESCI2ReplyHeader(Self.padded("IMG x0000265#psti0002550d000i0010800#typIMGA"))
        #expect(image.command == "IMG ")
        #expect(image.bodyLength == 0x265)
        #expect(image.fields["pst"] == [[.integer(2550), .integer(0), .integer(10800)]])
        #expect(!image.isInvalidCommand)

        #expect(try ESCI2ReplyHeader(Self.padded("PARAx0000000#parOK  ")).parametersAccepted)
        #expect(try !ESCI2ReplyHeader(Self.padded("PARAx0000000#parFAIL#BSZ")).parametersAccepted)
        #expect(try ESCI2ReplyHeader(Self.padded("INVDx0000000")).isInvalidCommand)
        #expect(throws: ProtocolError.self) { try ESCI2ReplyHeader(Data("INFO".utf8)) }
        #expect(throws: ProtocolError.self) { try ESCI2ReplyHeader(Data("INFOxZZZZZZZ".utf8)) }
    }
}

@Suite struct PacketTests {
    @Test func lockPacket() {
        #expect(ISPacket.lock().encoded == Data([0x49, 0x53, 0x21, 0x00, 0x00, 0x0C, 0, 0, 0, 7, 0, 0,
                                                 0x01, 0xA0, 0x04, 0x00, 0x00, 0x01, 0x2C]))
    }

    @Test func dataPacketRoundTrip() throws {
        let packet = ISPacket.data(Data("INFOx0000000".utf8), replyLength: 64)
        let decoded = try ISPacket(decoding: packet.encoded)
        #expect(decoded == packet)
        #expect(decoded.type == .data)
        #expect(decoded.type.reply.rawValue == 0xA000)
        #expect(decoded.dataRequest?.escI == Data("INFOx0000000".utf8))
        #expect(decoded.dataRequest?.replyLength == 64)
        #expect(Array(packet.payload.prefix(8)) == [0, 0, 0, 12, 0, 0, 0, 64])
    }

    @Test func badHeaders() {
        #expect(throws: ProtocolError.self) { try ISPacket.parseHeader(Data("XS".utf8) + Data(count: 10)) }
        #expect(throws: ProtocolError.self) { try ISPacket(decoding: ISPacket.lock().encoded.dropLast()) }
    }

    @Test func helloHolder() {
        #expect(ScannerHello(payload: Data([0x01, 0x04, 0x00, 0x00, 0x00])).holderAddress == nil)  // free
        #expect(ScannerHello(payload: hex("01048100010101040a000002")).holderAddress == "10.0.0.2")
        #expect(ScannerHello(payload: hex("0104810001010110fe80000000000000000000000000abcd")).holderAddress == "fe80::abcd")
        #expect(ScannerHello(payload: hex("01048100010101040a00")).holderAddress == nil)  // truncated
    }

    @Test func ipv6Formatting() {
        #expect(ScannerHello.ipv6String([UInt8](repeating: 0, count: 16)) == "::")
        #expect(ScannerHello.ipv6String([0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]) == "2001:db8::1")
        #expect(ScannerHello.ipv6String([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]) == "2001:db8:0:1:0:1:0:1")
    }

    func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map {
            let start = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[start ..< s.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}

@Suite struct JPEGHeightTests {
    // minimal JPEG: SOI, APP0 (length 4), SOF0 with height 3600
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x0E, 0x10,
                            0x09, 0xF6, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xD9])

    @Test func patchesSOFHeight() throws {
        let out = try JPEGHeight.replacing(in: Self.jpeg, with: 1263)
        #expect(out.count == Self.jpeg.count)
        #expect(Array(out[13 ..< 15]) == [0x04, 0xEF])  // SOF at 8, height at +5
        #expect(out.prefix(13) == Self.jpeg.prefix(13))
        #expect(out.suffix(from: 15) == Self.jpeg.suffix(from: 15))
    }

    @Test func worksOnSlices() throws {
        let sliced = (Data([0xAA]) + Self.jpeg).dropFirst()
        #expect(try JPEGHeight.replacing(in: sliced, with: 1263) == JPEGHeight.replacing(in: Self.jpeg, with: 1263))
    }

    @Test func rejectsGarbage() {
        #expect(throws: ProtocolError.badJPEGMarker(offset: 2)) {
            try JPEGHeight.replacing(in: Data([0xFF, 0xD8, 0x00, 0x00] + [UInt8](repeating: 0, count: 10)), with: 10)
        }
        #expect(throws: ProtocolError.jpegHeightOutOfRange(70000)) { try JPEGHeight.replacing(in: Self.jpeg, with: 70000) }
    }
}
