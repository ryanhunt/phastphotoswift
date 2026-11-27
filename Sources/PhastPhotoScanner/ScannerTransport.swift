import Foundation

/// Carries ESC/I-2 bytes to and from the scanner: Wi-Fi ("IS" packets, ``NetworkTransport``) or USB on macOS
/// (raw bulk transfers, ``USBTransport``; not yet run against a scanner). ``ScannerConnection`` picks one.
/// ``ScannerSession`` serialises exchanges, so a transport needs no locking of its own.
public protocol ScannerTransport: Sendable {
    /// Connect and claim the scanner (Wi-Fi: read the hello and lock). Does not enter ESC/I-2 mode;
    /// ``ScannerSession`` does that.
    func open() async throws

    /// Send `chunks`, then read the reply: at most `replyLength` bytes.
    ///
    /// Wi-Fi sends the chunks together in one `0x2000` packet. USB must send each chunk as its own bulk
    /// transfer: a command header and its parameter block sent together are never answered. An empty
    /// `chunks` (or empty chunk) sends nothing and only reads, which is how reply bodies are pulled.
    func transfer(_ chunks: [Data], replyLength: Int) async throws -> Data

    /// Release the scanner and disconnect. Safe to call more than once.
    func close() async

    /// How long to wait between `IMG ` polls that returned nothing. A Wi-Fi poll is a ~36 ms round trip;
    /// over USB a poll costs ~3 ms and long naps add seconds per side.
    var pollInterval: Duration { get }
}
