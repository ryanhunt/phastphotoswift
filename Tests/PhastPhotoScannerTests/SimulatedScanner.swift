import Foundation
@testable import PhastPhotoProtocol
@testable import PhastPhotoScanner

/// An in-memory ESC/I-2 scanner that keeps the reply rules in docs/PROTOCOL.md: a 64-byte header per command,
/// bodies pulled with empty requests, never more than was asked for.
actor SimulatedScanner {
    struct Reply: Sendable {
        var fields: String
        var body = Data()
    }

    enum Violation: Error {
        case notInCommandMode
        /// A command asked for more than the 64-byte header: a real scanner never answers and stays locked.
        case wouldHang(replyLength: Int)
        case bodyNotRead
        case malformedRequest
    }

    var infoBody = Data("#ADFTYPEFEED#ADFDPLX1SCN#PRDh007FF-680W".utf8) + Data([0])
    var statusBody = Data()
    var acceptsBlockSize = true
    /// Replies to `IMG `, in order; `INVD` once they run out (unless ``feedsForever``).
    var imageReplies: [Reply] = []
    /// Answer `IMG ` with empty replies forever, like a print stuck feeding.
    var feedsForever = false
    /// Largest body chunk per read, to exercise multi-read bodies.
    var maxChunk = Int.max

    private(set) var commands: [String] = []
    private(set) var parameterBlocks: [Data] = []
    private(set) var closed = false
    private var pendingBody = Data()
    private var inCommandMode = false

    func configure(_ change: @Sendable (isolated SimulatedScanner) -> Void) { change(self) }

    func markClosed() {
        closed = true
        inCommandMode = false
    }

    func handle(_ data: Data, replyLength: Int) throws -> Data {
        if data == ESCI2.enterCommandMode {
            inCommandMode = true
            return Data([ESCI2.acknowledge])
        }
        guard inCommandMode else { throw Violation.notInCommandMode }
        if data.isEmpty {
            let n = min(replyLength, maxChunk, pendingBody.count)
            let chunk = Data(pendingBody.prefix(n))
            pendingBody.removeFirst(n)
            return chunk
        }
        guard replyLength == ESCI2.replyHeaderLength else { throw Violation.wouldHang(replyLength: replyLength) }
        guard pendingBody.isEmpty else { throw Violation.bodyNotRead }
        let bytes = [UInt8](data)
        guard bytes.count >= 12, let length = Int(String(decoding: bytes[5 ..< 12], as: UTF8.self), radix: 16),
              bytes.count == 12 + length else { throw Violation.malformedRequest }
        let command = String(decoding: bytes[0 ..< 4], as: UTF8.self)
        let parameters = Data(bytes[12...])
        commands.append(command)

        var name = command
        let reply: Reply
        switch command {
        case "INFO": reply = Reply(fields: "", body: infoBody)
        case "CAPA": reply = Reply(fields: "", body: Data("#COLC024M008#FMTJPG ".utf8))
        case "STAT": reply = Reply(fields: "", body: statusBody)
        case "PARA":
            parameterBlocks.append(parameters)
            let hasBlockSize = parameters.range(of: Data("#BSZ".utf8)) != nil
            reply = Reply(fields: hasBlockSize && !acceptsBlockSize ? "#parFAIL#BSZ" : "#parOK  ")
        case "TRDT", "CAN ", "FIN ": reply = Reply(fields: "")
        case "IMG ":
            if !imageReplies.isEmpty {
                reply = imageReplies.removeFirst()
            } else if feedsForever {
                reply = Reply(fields: "")
            } else {
                name = "INVD"
                reply = Reply(fields: "")
            }
        default:
            name = "INVD"
            reply = Reply(fields: "")
        }
        pendingBody = reply.body
        return Self.header(name, bodyLength: reply.body.count, fields: reply.fields)
    }

    static func header(_ command: String, bodyLength: Int, fields: String) -> Data {
        var s = command + "x" + ESCI2Parameters.hex(bodyLength, 7) + fields
        while s.utf8.count < ESCI2.replyHeaderLength { s += "#---" }
        precondition(s.utf8.count == ESCI2.replyHeaderLength)
        return Data(s.utf8)
    }
}

/// Talks to a ``SimulatedScanner`` directly, like Wi-Fi does: chunks sent together.
struct SimulatedTransport: ScannerTransport {
    let scanner: SimulatedScanner
    var pollInterval: Duration = .zero

    func open() async throws {}

    func transfer(_ chunks: [Data], replyLength: Int) async throws -> Data {
        try await scanner.handle(chunks.reduce(into: Data()) { $0.append($1) }, replyLength: replyLength)
    }

    func close() async { await scanner.markClosed() }
}

/// A JPEG header with the scanner's requested height in SOF0, followed by `filler` bytes of fake scan data.
func fakeScanJPEG(width: Int = 2550, requestedHeight: Int = 10800, filler: Int = 3000, seed: UInt8 = 0) -> Data {
    var d = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x0B, 0x08])
    d.append(contentsOf: [UInt8(requestedHeight >> 8), UInt8(requestedHeight & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF)])
    d.append(contentsOf: [0x01, 0x01, 0x11, 0x00])
    d.append(contentsOf: (0 ..< filler).map { UInt8(truncatingIfNeeded: $0 &+ Int(seed)) })
    d.append(contentsOf: [0xFF, 0xD9])
    return d
}

func sofHeight(_ jpeg: Data) -> Int {
    let b = [UInt8](jpeg)
    return Int(b[13]) << 8 | Int(b[14])
}
