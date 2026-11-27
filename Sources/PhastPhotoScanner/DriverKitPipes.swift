#if os(macOS) || os(iOS)
import CPhastPhotoDriverKit
import Foundation

/// ``USBPipes`` through the PhastPhoto USB driver extension (`Drivers/PhastPhotoUSBDriver`): each call goes to
/// the driver's user client, which does the bulk transfer on the scanner's interface. This is how USB works on
/// iPadOS, where apps can't open USB devices themselves.
///
/// IOKit calls block, so they run on a serial queue, off the cooperative pool. Builds on macOS too, so the
/// error mapping and "no driver" path are tested there; ``USBTransport`` uses it on iOS only.
///
/// **Unverified on hardware:** which status a transfer timeout returns (both IOKit's and USB's timeout codes
/// are treated as ``ScannerError/timedOut``), how long the driver takes to come back after a reset, and how the
/// driver's service is found (by its `IOUserClass`, see `PhastPhotoUSBProtocol.h`).
final class DriverKitPipes: USBPipes, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhastPhotoScanner.DriverKitUSB")
    private let serverName: String?
    /// The per-transfer timeout sent to the driver; at least 1 (0 would mean no timeout).
    let timeoutMilliseconds: UInt32
    /// How long ``reclaim()`` waits for the driver to come back after a reset (it is torn down and matched again).
    private let reappearTimeout: TimeInterval
    // touched only on `queue`
    private var connection: ppusb_connection_t = 0

    init(serverName: String?, timeout: Duration, reappearTimeout: TimeInterval = 10) {
        self.serverName = serverName
        let ms = Double(timeout.components.seconds) * 1000 + Double(timeout.components.attoseconds) / 1e15
        timeoutMilliseconds = max(1, UInt32(clamping: Int(ms.rounded(.up))))
        self.reappearTimeout = reappearTimeout
    }

    static func claim(serverName: String?, timeout: Duration) async throws -> DriverKitPipes {
        let pipes = DriverKitPipes(serverName: serverName, timeout: timeout)
        try await pipes.onQueue { try pipes.openBlocking(waiting: 0) }
        return pipes
    }

    static func isDriverPresent(serverName: String?) -> Bool {
        withServerName(serverName) { ppusb_driver_present($0) }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await onQueue {
            let status = data.withUnsafeBytes { bytes in
                ppusb_write(self.connection, bytes.baseAddress, bytes.count, self.timeoutMilliseconds)
            }
            try Self.check(status, during: "write")
        }
    }

    func read(maxLength: Int) async throws -> Data {
        try await onQueue {
            var buffer = [UInt8](repeating: 0, count: maxLength)
            var received = 0
            let status = buffer.withUnsafeMutableBytes { bytes in
                ppusb_read(self.connection, bytes.baseAddress, bytes.count, self.timeoutMilliseconds, &received)
            }
            try Self.check(status, during: "read")
            return Data(buffer.prefix(received))
        }
    }

    /// Sends the reset and drops the connection: the driver instance is terminated with the device, whatever
    /// the call itself returns.
    func resetDevice() async throws {
        try await onQueue {
            guard self.connection != 0 else { throw ScannerError.notConnected }
            _ = ppusb_reset(self.connection)
            self.closeBlocking()
        }
    }

    /// Opens a new connection, waiting for the driver to be matched again after a reset.
    func reclaim() async throws {
        try await onQueue { try self.openBlocking(waiting: self.reappearTimeout) }
    }

    func release() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.closeBlocking()
                continuation.resume()
            }
        }
    }

    // MARK: private, on `queue`

    private func openBlocking(waiting: TimeInterval) throws {
        closeBlocking()
        let deadline = Date().addingTimeInterval(waiting)
        while true {
            var connection: ppusb_connection_t = 0
            let status = Self.withServerName(serverName) { ppusb_open($0, &connection) }
            if status == 0 {
                self.connection = connection
                return
            }
            // only "not there yet" is worth waiting for; anything else (no permission, in use) won't change
            guard status == Status.notFound, Date() < deadline else { throw Self.error(for: status, during: "open") }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func closeBlocking() {
        ppusb_close(connection)
        connection = 0
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private static func withServerName<T>(_ name: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let name else { return body(nil) }
        return name.withCString { body($0) }
    }

    // MARK: errors

    /// IOKit statuses (`kern_return_t`), from the iOS SDK's `IOReturn.h` and `mach/message.h`.
    enum Status {
        static let timeout = Int32(bitPattern: 0xE000_02D6)  // kIOReturnTimeout
        static let usbTransactionTimeout = Int32(bitPattern: 0xE000_4051)  // kIOUSBTransactionTimeout
        static let notFound = Int32(bitPattern: 0xE000_02F0)  // kIOReturnNotFound (no driver service)
        static let notPermitted = Int32(bitPattern: 0xE000_02E2)  // kIOReturnNotPermitted
        static let notPrivileged = Int32(bitPattern: 0xE000_02C1)  // kIOReturnNotPrivileged
        static let exclusiveAccess = Int32(bitPattern: 0xE000_02C5)  // kIOReturnExclusiveAccess
        /// kIOReturnOverrun: the scanner sent more than the read asked for (seen on an iPad Pro after a scan
        /// was interrupted).
        static let overrun = Int32(bitPattern: 0xE000_02E8)
        /// kIOReturnBusy: the driver is still finishing a transfer an earlier connection started.
        static let busy = Int32(bitPattern: 0xE000_02D5)
        static let gone: Set<Int32> = [
            Int32(bitPattern: 0xE000_02C0),  // kIOReturnNoDevice
            Int32(bitPattern: 0xE000_02D9),  // kIOReturnNotAttached
            Int32(bitPattern: 0xE000_02D7),  // kIOReturnOffline
            Int32(bitPattern: 0xE000_02EB),  // kIOReturnAborted (the driver stopped mid-transfer)
            Int32(bitPattern: 0xE000_02ED),  // kIOReturnNotResponding
            0x1000_0003,  // MACH_SEND_INVALID_DEST: the connection died with the driver
            -308,  // MIG_SERVER_DIED
        ]
    }

    static let goneMessage = "The scanner was unplugged, or its USB driver stopped."
    static let notPermittedMessage = "This app isn't allowed to talk to the scanner's USB driver: it needs the "
        + "com.apple.developer.driverkit.communicates-with-drivers entitlement, signed by the driver's team."

    static func check(_ status: Int32, during operation: String? = nil) throws {
        if status == Status.overrun { throw USBStaleData() }
        if status != 0 { throw error(for: status, during: operation) }
    }

    /// `0xE00002EB`
    static func hex(_ status: Int32) -> String {
        "0x" + String(UInt32(bitPattern: status), radix: 16, uppercase: true)
    }

    /// The ``ScannerError`` for a failed call. With `operation` ("open", "write", "read"), a failure that isn't
    /// self-explanatory also names the call and the raw status, which is what tells the causes apart.
    static func error(for status: Int32, during operation: String? = nil) -> ScannerError {
        let detail = operation.map { " (USB \($0): \(hex(status)))" } ?? ""
        return switch status {
        case Status.timeout, Status.usbTransactionTimeout: .timedOut
        case Status.notFound: .connectionFailed(USBTransport.notPluggedInMessage)
        case Status.notPermitted, Status.notPrivileged: .connectionFailed(notPermittedMessage)
        case Status.exclusiveAccess, Status.busy: .connectionFailed(USBTransport.interfaceInUseMessage + detail)
        case _ where Status.gone.contains(status): .connectionFailed(goneMessage + detail)
        default: .connectionFailed("USB driver error \(hex(status))\(detail).")
        }
    }
}
#endif
