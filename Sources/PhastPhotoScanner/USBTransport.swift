#if os(macOS)
import Foundation
import IOKit
import IOUSBHost

/// What ``USBTransport`` needs from the USB stack: bulk writes and reads on the scanner's interface. The
/// IOUSBHost implementation is ``IOUSBHostPipes``; tests supply a fake, because the real one needs the scanner.
protocol USBPipes: Sendable {
    /// One bulk OUT transfer of exactly `data` (endpoint `0x01`). Throws ``ScannerError/timedOut`` on timeout.
    func write(_ data: Data) async throws
    /// One bulk IN transfer asking for up to `maxLength` bytes (endpoint `0x82`). Throws
    /// ``ScannerError/timedOut`` on timeout.
    func read(maxLength: Int) async throws -> Data
    /// Reset the device (the same as replugging the cable). The interface must be re-claimed afterwards.
    func resetDevice() async throws
    /// Claim interface 0 again after ``resetDevice()``.
    func reclaim() async throws
    /// Release the interface.
    func release() async
}

/// USB transport for the FF-680W on macOS: ESC/I-2 as raw bulk transfers, no "IS" framing and no lock.
///
/// Ports `_usb_device`, `_enter_usb`, `_xfer` and `command` (upstream ff680w.py:504-515, 567-630, commit a041a3f).
/// Epson's driver and Epson Scan claim the interface too; while one of them holds it, ``open()`` fails with
/// ``interfaceInUseMessage``.
///
/// **Entitlement.** A sandboxed Mac app needs `com.apple.security.device.usb` set to `true` (Xcode: App Sandbox,
/// Hardware, USB). Without it the device can be seen but not opened, which looks like "in use by another app".
///
/// **Unverified.** The framing (``transfer(_:replyLength:)``) is unit tested with a fake; the IOUSBHost layer
/// (``IOUSBHostPipes``) has only been compiled, never run against a scanner.
public actor USBTransport: ScannerTransport {
    public static let vendorID = 0x04B8
    public static let productID = 0x016B
    public static let interfaceNumber = 0
    /// Bulk OUT endpoint address. (`0x83` is an interrupt endpoint, the scan button; not used.)
    public static let bulkOut: UInt8 = 0x01
    /// Bulk IN endpoint address.
    public static let bulkIn: UInt8 = 0x82

    public static let notPluggedInMessage = "No scanner on USB: is the cable plugged in and the scanner switched on?"
    public static let interfaceInUseMessage =
        "The scanner's USB connection is in use by another app (Epson Scan?). Quit it and try again."

    /// Over USB a poll costs about 3 ms; long naps add seconds per side.
    public nonisolated let pollInterval: Duration = .milliseconds(5)
    /// Longest wait for any one transfer.
    public nonisolated let timeout: Duration
    /// How long to wait after a device reset before claiming the interface again (upstream `time.sleep(2)`).
    nonisolated let settleDelay: Duration

    private let makePipes: @Sendable () async throws -> any USBPipes
    private var pipes: (any USBPipes)?
    /// True until the first transfer after ``open()`` succeeds. A timeout there means the scanner was left
    /// mid-command by an interrupted session, and a reset clears it.
    private var awaitingFirstTransfer = false

    /// The scanner on USB (VID `0x04B8`, PID `0x016B`).
    public init(timeout: Duration = .seconds(60)) {
        self.init(timeout: timeout, settleDelay: .seconds(2)) { try await IOUSBHostPipes.claim(timeout: timeout) }
    }

    init(timeout: Duration, settleDelay: Duration, makePipes: @escaping @Sendable () async throws -> any USBPipes) {
        self.timeout = timeout
        self.settleDelay = settleDelay
        self.makePipes = makePipes
    }

    /// Whether a scanner is plugged in (without claiming it).
    public static func isScannerPresent() -> Bool {
        IOUSBHostPipes.findService(IOUSBHostPipes.deviceMatching()) != nil
    }

    public func open() async throws {
        guard pipes == nil else { return }
        pipes = try await makePipes()
        awaitingFirstTransfer = true
    }

    /// Each non-empty chunk is its own bulk transfer (a header and its parameter block sent together are never
    /// answered); empty chunks send nothing; then one read of up to `replyLength` bytes.
    public func transfer(_ chunks: [Data], replyLength: Int) async throws -> Data {
        guard let pipes else { throw ScannerError.notConnected }
        do {
            let reply = try await Self.exchange(chunks, replyLength: replyLength, on: pipes)
            awaitingFirstTransfer = false
            return reply
        } catch ScannerError.timedOut where awaitingFirstTransfer {
            // upstream `_enter_usb`: the scanner was left mid-command; reset, wait, claim again, retry once
            awaitingFirstTransfer = false
            try await reset()
            return try await Self.exchange(chunks, replyLength: replyLength, on: pipes)
        }
    }

    /// Reset the device, wait for it to come back (2 s) and claim the interface again.
    public func reset() async throws {
        guard let pipes else { throw ScannerError.notConnected }
        try await pipes.resetDevice()
        try await Task.sleep(for: settleDelay)
        try await pipes.reclaim()
    }

    public func close() async {
        guard let pipes else { return }
        self.pipes = nil
        awaitingFirstTransfer = false
        await pipes.release()
    }

    static func exchange(_ chunks: [Data], replyLength: Int, on pipes: any USBPipes) async throws -> Data {
        for chunk in chunks where !chunk.isEmpty {
            try await pipes.write(chunk)
        }
        guard replyLength > 0 else { return Data() }
        let reply = try await pipes.read(maxLength: replyLength)
        return reply.count > replyLength ? reply.prefix(replyLength) : reply
    }
}

// MARK: - IOUSBHost

/// The real pipes: IOUSBHost on interface 0, blocking calls kept off the cooperative pool.
final class IOUSBHostPipes: USBPipes, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhastPhotoScanner.USB")
    private let timeoutSeconds: TimeInterval
    // touched only on `queue`
    private var interface: IOUSBHostInterface?
    private var outPipe: IOUSBHostPipe?
    private var inPipe: IOUSBHostPipe?

    private init(timeout: Duration) {
        timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    }

    static func claim(timeout: Duration) async throws -> IOUSBHostPipes {
        let pipes = IOUSBHostPipes(timeout: timeout)
        try await pipes.reclaim()
        return pipes
    }

    static func deviceMatching() -> CFDictionary {
        matching("IOUSBHostDevice", interface: nil)
    }

    private static func matching(_ className: String, interface: Int?) -> CFDictionary {
        let dict = IOServiceMatching(className) as NSMutableDictionary
        dict["idVendor"] = USBTransport.vendorID
        dict["idProduct"] = USBTransport.productID
        if let interface { dict["bInterfaceNumber"] = interface }
        return dict
    }

    /// The first registry entry matching `dictionary` (consumes it); the caller releases the result.
    static func findService(_ dictionary: CFDictionary) -> io_service_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, dictionary)
        return service == IO_OBJECT_NULL ? nil : service
    }

    func reclaim() async throws {
        try await onQueue { try self.claimBlocking() }
    }

    func write(_ data: Data) async throws {
        try await onQueue {
            guard let pipe = self.outPipe, let interface = self.interface else { throw ScannerError.notConnected }
            guard let buffer = try? interface.ioData(withCapacity: data.count) else {
                throw ScannerError.connectionFailed("Couldn't allocate a USB buffer.")
            }
            buffer.replaceBytes(in: NSRange(location: 0, length: data.count), withBytes: [UInt8](data))
            var sent = 0
            try Self.perform { try pipe.__sendIORequest(with: buffer, bytesTransferred: &sent, completionTimeout: self.timeoutSeconds) }
        }
    }

    func read(maxLength: Int) async throws -> Data {
        try await onQueue {
            guard let pipe = self.inPipe, let interface = self.interface else { throw ScannerError.notConnected }
            guard let buffer = try? interface.ioData(withCapacity: maxLength) else {
                throw ScannerError.connectionFailed("Couldn't allocate a USB buffer.")
            }
            var received = 0
            try Self.perform { try pipe.__sendIORequest(with: buffer, bytesTransferred: &received, completionTimeout: self.timeoutSeconds) }
            return Data(bytes: buffer.bytes, count: min(received, maxLength))
        }
    }

    func resetDevice() async throws {
        try await onQueue {
            self.releaseBlocking()
            guard let service = Self.findService(Self.deviceMatching()) else {
                throw ScannerError.connectionFailed(USBTransport.notPluggedInMessage)
            }
            defer { IOObjectRelease(service) }
            // a plain (not captured) device object is enough to send the port reset
            let device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            defer { device.destroy() }
            try device.reset()
        }
    }

    func release() async {
        await onQueue { self.releaseBlocking() }
    }

    // MARK: private

    private func claimBlocking() throws {
        releaseBlocking()
        guard let device = Self.findService(Self.deviceMatching()) else {
            throw ScannerError.connectionFailed(USBTransport.notPluggedInMessage)
        }
        IOObjectRelease(device)
        guard let service = Self.findService(Self.matching("IOUSBHostInterface", interface: USBTransport.interfaceNumber)) else {
            throw ScannerError.connectionFailed(USBTransport.interfaceInUseMessage)
        }
        defer { IOObjectRelease(service) }
        let interface: IOUSBHostInterface
        do {
            // exclusive ownership: fails while Epson's driver or Epson Scan holds the interface
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            throw ScannerError.connectionFailed("\(USBTransport.interfaceInUseMessage) (\(error.localizedDescription))")
        }
        do {
            outPipe = try interface.copyPipe(withAddress: Int(USBTransport.bulkOut))
            inPipe = try interface.copyPipe(withAddress: Int(USBTransport.bulkIn))
        } catch {
            interface.destroy()
            throw ScannerError.connectionFailed("The scanner's USB endpoints are missing: \(error.localizedDescription)")
        }
        self.interface = interface
    }

    private func releaseBlocking() {
        outPipe = nil
        inPipe = nil
        interface?.destroy()
        interface = nil
    }

    /// Maps IOUSBHost's timeout error to ``ScannerError/timedOut``.
    private static func perform(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as NSError where error.domain == NSMachErrorDomain && error.code == Int(Int32(truncatingIfNeeded: kIOReturnTimeout)) {
            throw ScannerError.timedOut
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func onQueue(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                work()
                continuation.resume()
            }
        }
    }
}
#endif
