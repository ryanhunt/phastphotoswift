import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One address and port to knock on.
public struct ProbeCandidate: Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public init(host: String, port: UInt16 = 1865) {
        self.host = host
        self.port = port
    }
}

/// Finds the scanner without Bonjour by trying every address of the local /24.
///
/// Ports `_scan_subnet`, `_is_epson_scanner` and `_local_ipv4` (upstream ff680w.py:439-472, commit a041a3f).
/// The scanner speaks first: an Epson scanner sends an "IS" packet of type `0x8000` (the hello) as soon as the
/// TCP connection opens, so a probe only connects and reads, and never writes (nothing is locked).
///
/// On iOS the probe needs the local network permission; sandboxed Mac apps need
/// `com.apple.security.network.client`.
public enum SubnetProbe {
    /// Upstream `_is_epson_scanner` defaults.
    public static let defaultPort: UInt16 = 1865
    public static let connectTimeout: Duration = .milliseconds(400)
    public static let readTimeout: Duration = .seconds(1)
    /// Upstream `ThreadPoolExecutor(64)`.
    public static let concurrency = 64

    /// This device's LAN IPv4 address. No packet is sent: a UDP `connect` to a documentation address only
    /// makes the kernel pick the outgoing interface (upstream `_local_ipv4`). `nil` when there is no route.
    public static func localIPv4() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, "192.0.2.1", &remote.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Hosts `.1` to `.254` of the /24 containing `localAddress`, without `localAddress` itself. `nil` when
    /// there is no address or it is loopback (upstream: `/24 only`, `startswith("127")`).
    ///
    /// - Parameter prefixOverride: the first three octets to search instead, such as `192.0.2` (upstream
    ///   `FFSCAN_SUBNET`), for when this process cannot see the LAN.
    public static func subnetHosts(localAddress: String?, prefixOverride: String? = nil) -> [String]? {
        let override = prefixOverride.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? ""
        let prefix: String
        if !override.isEmpty {
            prefix = override
        } else if let localAddress, let dot = localAddress.lastIndex(of: ".") {
            prefix = String(localAddress[..<dot])
        } else {
            return nil
        }
        guard !prefix.isEmpty, !prefix.hasPrefix("127") else { return nil }
        return (1 ... 254).map { "\(prefix).\($0)" }.filter { $0 != localAddress }
    }

    /// The first address (lowest first) of this device's /24 that answers like an Epson scanner, or `nil`.
    public static func scanLocalSubnet(prefixOverride: String? = nil, port: UInt16 = defaultPort) async -> String? {
        guard let hosts = subnetHosts(localAddress: localIPv4(), prefixOverride: prefixOverride) else { return nil }
        return await scan(hosts.map { ProbeCandidate(host: $0, port: port) })?.host
    }

    /// Probes `candidates` with up to ``concurrency`` connections at a time and returns the first one, in list
    /// order, that answers like an Epson scanner (upstream `_scan_subnet`).
    public static func scan(
        _ candidates: [ProbeCandidate],
        concurrency: Int = SubnetProbe.concurrency,
        connectTimeout: Duration = SubnetProbe.connectTimeout,
        readTimeout: Duration = SubnetProbe.readTimeout
    ) async -> ProbeCandidate? {
        var hits = Set<Int>()
        await withTaskGroup(of: (Int, Bool).self) { group in
            var next = 0
            func addNext() {
                guard next < candidates.count, !Task.isCancelled else { return }
                let index = next, candidate = candidates[next]
                next += 1
                group.addTask {
                    (index, await isEpsonScanner(candidate, connectTimeout: connectTimeout, readTimeout: readTimeout))
                }
            }
            for _ in 0 ..< max(1, concurrency) { addNext() }
            while let (index, ok) = await group.next() {
                if ok { hits.insert(index) }
                addNext()
            }
        }
        return hits.min().map { candidates[$0] }
    }

    /// Connects, waits for the first bytes and checks them (upstream `_is_epson_scanner`): `"IS"` then `0x80 0x00`.
    public static func isEpsonScanner(
        _ candidate: ProbeCandidate,
        connectTimeout: Duration = SubnetProbe.connectTimeout,
        readTimeout: Duration = SubnetProbe.readTimeout
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: probeBlocking(candidate, connectTimeout: connectTimeout, readTimeout: readTimeout))
            }
        }
    }

    /// True if `bytes` start with the scanner's hello header: `"IS"`, `0x80`, `0x00`.
    static func isHello(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0] == 0x49 && bytes[1] == 0x53 && bytes[2] == 0x80 && bytes[3] == 0x00
    }

    private static func milliseconds(_ d: Duration) -> Int32 {
        Int32(max(0, min(Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000), Int(Int32.max))))
    }

    private static func probeBlocking(_ candidate: ProbeCandidate, connectTimeout: Duration, readTimeout: Duration) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = candidate.port.bigEndian
        guard inet_pton(AF_INET, candidate.host, &address.sin_addr) == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { return false }
            guard wait(fd, events: Int16(POLLOUT), timeout: milliseconds(connectTimeout)) else { return false }
            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length) == 0, soError == 0 else { return false }
        }

        // the hello is 12 bytes; keep reading until the 4 header bytes are in, or the deadline passes
        let deadline = ContinuousClock.now + readTimeout
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 12)
        while received.count < 4 {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, wait(fd, events: Int16(POLLIN), timeout: max(1, milliseconds(remaining))) else { return false }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                received.append(contentsOf: buffer[0 ..< n])
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                return false
            }
        }
        return isHello(received)
    }

    private static func wait(_ fd: Int32, events: Int16, timeout: Int32) -> Bool {
        var p = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let r = poll(&p, 1, timeout)
            if r < 0 && errno == EINTR { continue }
            return r > 0
        }
    }
}
