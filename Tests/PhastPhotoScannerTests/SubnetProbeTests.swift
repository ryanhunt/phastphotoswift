import Foundation
import Network
import Testing

@testable import PhastPhotoScanner

/// A loopback TCP server that sends `greeting` (possibly nothing) to each client and keeps the connection open.
final class GreetingServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "GreetingServer")
    let greeting: Data

    init(greeting: Data) throws {
        self.greeting = greeting
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [greeting, queue] conn in
            conn.start(queue: queue)
            if !greeting.isEmpty { conn.send(content: greeting, completion: .idempotent) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: listener.port!.rawValue) }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}

/// A port nothing listens on.
private func closedPort() async throws -> UInt16 {
    let server = try GreetingServer(greeting: Data())
    let port = try await server.start()
    server.stop()
    try await Task.sleep(for: .milliseconds(100))
    return port
}

/// Short timeouts: loopback answers at once, and the silent server must not hold the test for a second.
private let quick = (connect: Duration.milliseconds(400), read: Duration.milliseconds(300))

@Suite(.timeLimit(.minutes(1))) struct SubnetProbeTests {
    // MARK: hello check

    @Test func helloHeaderIsISThen0x8000() {
        #expect(SubnetProbe.isHello([0x49, 0x53, 0x80, 0x00, 0x00, 0x00, 0x00, 0x05]))
        #expect(!SubnetProbe.isHello([0x49, 0x53, 0x80, 0x01]))  // wrong type
        #expect(!SubnetProbe.isHello([0x49, 0x54, 0x80, 0x00]))  // not "IS"
        #expect(!SubnetProbe.isHello([0x49, 0x53, 0x80]))  // too short
    }

    // MARK: candidate list

    @Test func subnetIsTheSlash24WithoutOwnAddress() throws {
        let hosts = try #require(SubnetProbe.subnetHosts(localAddress: "192.0.2.77"))
        #expect(hosts.count == 253)
        #expect(hosts.first == "192.0.2.1")
        #expect(hosts.last == "192.0.2.254")
        #expect(!hosts.contains("192.0.2.77"))
        #expect(!hosts.contains("192.0.2.0") && !hosts.contains("192.0.2.255"))
    }

    @Test func loopbackOrMissingAddressGivesNoCandidates() {
        #expect(SubnetProbe.subnetHosts(localAddress: "127.0.0.1") == nil)
        #expect(SubnetProbe.subnetHosts(localAddress: nil) == nil)
    }

    @Test func prefixOverrideReplacesTheLocalSubnet() throws {
        // upstream FFSCAN_SUBNET: a trailing dot is tolerated; the own address is only skipped if it's in range
        let hosts = try #require(SubnetProbe.subnetHosts(localAddress: "10.9.9.9", prefixOverride: "198.51.100."))
        #expect(hosts.count == 254)
        #expect(hosts.first == "198.51.100.1")
        #expect(SubnetProbe.subnetHosts(localAddress: "10.9.9.9", prefixOverride: "127.0.0") == nil)
    }

    @Test func localAddressLooksLikeIPv4WhenThereIsARoute() {
        guard let address = SubnetProbe.localIPv4() else { return }  // no network in some sandboxes
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        #expect(parts.count == 4)
    }

    // MARK: probing over loopback

    @Test func acceptsAScannerHello() async throws {
        let server = try ISTestServer(scanner: SimulatedScanner())
        let port = try await server.start()
        defer { server.stop() }
        let ok = await SubnetProbe.isEpsonScanner(ProbeCandidate(host: "127.0.0.1", port: port), connectTimeout: quick.connect, readTimeout: quick.read)
        #expect(ok)
        // the probe never locks the scanner: it only reads the hello
        #expect(server.packetTypes.isEmpty)
    }

    @Test func rejectsClosedPortGarbageAndSilence() async throws {
        let garbage = try GreetingServer(greeting: Data("HTTP/1.1 400 Bad Request\r\n".utf8))
        let garbagePort = try await garbage.start()
        let silent = try GreetingServer(greeting: Data())
        let silentPort = try await silent.start()
        let closed = try await closedPort()
        defer { garbage.stop(); silent.stop() }

        for port in [garbagePort, silentPort, closed] {
            let ok = await SubnetProbe.isEpsonScanner(ProbeCandidate(host: "127.0.0.1", port: port), connectTimeout: quick.connect, readTimeout: quick.read)
            #expect(!ok, "port \(port)")
        }
        // an unparsable host is a miss, not a crash
        #expect(await SubnetProbe.isEpsonScanner(ProbeCandidate(host: "not an address")) == false)
    }

    @Test func scanReturnsTheFirstScannerInListOrder() async throws {
        let first = try ISTestServer(scanner: SimulatedScanner())
        let second = try ISTestServer(scanner: SimulatedScanner())
        let garbage = try GreetingServer(greeting: Data("SSH-2.0-test\r\n".utf8))
        let firstPort = try await first.start()
        let secondPort = try await second.start()
        let garbagePort = try await garbage.start()
        let closed = try await closedPort()
        defer { first.stop(); second.stop(); garbage.stop() }

        let list = [closed, garbagePort, firstPort, secondPort].map { ProbeCandidate(host: "127.0.0.1", port: $0) }
        // concurrency 2 < list size: the window has to slide
        let hit = await SubnetProbe.scan(list, concurrency: 2, connectTimeout: quick.connect, readTimeout: quick.read)
        #expect(hit == list[2])
        let reversed = await SubnetProbe.scan(Array(list.reversed()), concurrency: 2, connectTimeout: quick.connect, readTimeout: quick.read)
        #expect(reversed == list[3])
    }

    @Test func scanFindsNothingAmongMisses() async throws {
        let garbage = try GreetingServer(greeting: Data("nope".utf8))
        let garbagePort = try await garbage.start()
        let closed = try await closedPort()
        defer { garbage.stop() }
        let list = [garbagePort, closed].map { ProbeCandidate(host: "127.0.0.1", port: $0) }
        #expect(await SubnetProbe.scan(list, connectTimeout: quick.connect, readTimeout: quick.read) == nil)
        #expect(await SubnetProbe.scan([]) == nil)
    }
}

// MARK: - Transport choice (7.3)

@Suite struct TransportChoiceTests {
    private static let bonjour = DiscoveredScanner(
        name: "EPSON FF-680W",
        endpoint: .hostPort(host: "192.0.2.9", port: 1865)
    )

    /// Records which probes ran, in order.
    private final class Calls: Sendable {
        private let log = OSAllocatedLog()
        func note(_ s: String) { log.add(s) }
        var all: [String] { log.all }
    }

    private func probes(usb: Bool = false, bonjour: DiscoveredScanner? = nil, bonjourFails: Bool = false, subnet: String? = nil, calls: Calls = Calls()) -> ScannerConnection.Probes {
        .init(
            usbPresent: { calls.note("usb"); return usb },
            bonjour: {
                calls.note("bonjour")
                if bonjourFails { throw ScannerError.connectionFailed("no permission") }
                return bonjour
            },
            subnet: { calls.note("subnet"); return subnet }
        )
    }

    @Test func automaticPrefersUSBAndSkipsTheNetwork() async throws {
        let calls = Calls()
        let route = try await ScannerConnection.route(for: .automatic, probes: probes(usb: true, bonjour: Self.bonjour, subnet: "192.0.2.5", calls: calls))
        #expect(route == .usb)
        #expect(calls.all == ["usb"])
    }

    @Test func automaticFallsBackToBonjourThenTheSubnet() async throws {
        let calls = Calls()
        let viaBonjour = try await ScannerConnection.route(for: .automatic, probes: probes(bonjour: Self.bonjour, subnet: "192.0.2.5", calls: calls))
        #expect(viaBonjour == .bonjour(Self.bonjour))
        #expect(calls.all == ["usb", "bonjour"])

        let viaSubnet = try await ScannerConnection.route(for: .automatic, probes: probes(subnet: "192.0.2.5"))
        #expect(viaSubnet == .wifi(host: "192.0.2.5"))
        // a failing Bonjour browse (no local network permission) does not stop the probe
        let afterFailure = try await ScannerConnection.route(for: .automatic, probes: probes(bonjourFails: true, subnet: "192.0.2.6"))
        #expect(afterFailure == .wifi(host: "192.0.2.6"))
    }

    @Test func automaticWithNothingFoundSaysSo() async {
        await #expect {
            try await ScannerConnection.route(for: .automatic, probes: probes())
        } throws: { error in
            guard case ScannerError.connectionFailed(let message) = error else { return false }
            return message == ScannerConnection.noScannerMessage
        }
    }

    @Test func explicitUSBNeedsADevice() async throws {
        #expect(try await ScannerConnection.route(for: .usb, probes: probes(usb: true)) == .usb)
        await #expect {
            try await ScannerConnection.route(for: .usb, probes: probes(usb: false, bonjour: Self.bonjour, subnet: "192.0.2.5"))
        } throws: { error in
            guard case ScannerError.connectionFailed(let message) = error else { return false }
            return message == ScannerConnection.noUSBMessage
        }
    }

    @Test func explicitWiFiSkipsEveryProbe() async throws {
        let calls = Calls()
        let route = try await ScannerConnection.route(for: .wifi(host: "192.0.2.77"), probes: probes(usb: true, bonjour: Self.bonjour, calls: calls))
        #expect(route == .wifi(host: "192.0.2.77"))
        #expect(calls.all.isEmpty)
    }

    @Test func buildsTheMatchingTransport() async throws {
        #expect(try ScannerConnection.make(.wifi(host: "192.0.2.5")) is NetworkTransport)
        #expect(try ScannerConnection.make(.bonjour(Self.bonjour)) is NetworkTransport)
        #if os(macOS)
        #expect(try ScannerConnection.make(.usb) is USBTransport)
        #endif
    }
}

/// A tiny thread-safe string log for the probe closures.
private final class OSAllocatedLog: Sendable {
    private let lines = NSLockedBox()
    func add(_ s: String) { lines.append(s) }
    var all: [String] { lines.values }
}

private final class NSLockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
