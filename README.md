# phastphotoswift

Open-source Swift packages for the Epson FastFoto FF-680W photo scanner on iOS, iPadOS and macOS: Wi-Fi discovery and
scanning now, with auto-crop, enhancement and duplicate detection to follow. It is a Swift port of
[eg7eg7/ffscan](https://github.com/eg7eg7/ffscan) (Python, MIT), which worked out the scanner's network protocol.

This is a library, not an app: it has no UI. Apps add it as a Swift package and build their own interface on top.

> **Status: early.** The protocol and Wi-Fi client are ported and tested against a simulated scanner and a
> loopback server, but have **not yet been run against real hardware**. The supported scanner is the
> **FastFoto FF-680W**, the model the protocol was established on. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Packages

| Product | What it does |
|---|---|
| `PhastPhotoProtocol` | Wire formats only, no I/O: "IS" packets, ESC/I-2 tokens and commands, `ScanSettings` → `PARA` block, `INFO`/`STAT` parsing, the JPEG height fix. |
| `PhastPhotoScanner` | The client: Bonjour discovery (`ScannerDiscovery`), the Wi-Fi transport (`NetworkTransport`, Network.framework), and `ScannerSession` for queries and scans. |
| `phastphoto` | A small macOS command-line tool for checking the library against a real scanner. |

Requires iOS 16 / macOS 13 or later and Swift 6.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/ryanhunt/phastphotoswift.git", branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "PhastPhotoScanner", package: "phastphotoswift")]),
]
```

### Local network access

- **iOS/iPadOS:** add to the app's Info.plist `NSLocalNetworkUsageDescription` (why you need the scanner) and
  `NSBonjourServices` containing `_scanner._tcp`. The first browse shows the permission prompt.
- **macOS (sandboxed):** enable the `com.apple.security.network.client` entitlement.

## Usage

```swift
import PhastPhotoScanner

guard let scanner = try await ScannerDiscovery.firstScanner() else { return }   // Bonjour, ~3 s
try await ScannerSession.withSession(transport: NetworkTransport(endpoint: scanner.endpoint)) { session in
    print(try await session.info().productName ?? "?")       // "FF-680W"

    let status = try await session.status()
    guard status.isReady else { print(status); return }       // "feeder empty", "paper jam", ...

    let settings = ScanSettings(resolution: 600, duplex: true, jpegQuality: 95)
    for try await page in session.pages(settings) {
        // Prints load face up: side B is the picture, side A the back of the print.
        let name = "\(page.index)\(page.side.rawValue).jpg"
        try page.jpeg.write(to: folder.appending(path: name))
    }
}
```

Things worth knowing (details in [docs/PROTOCOL.md](docs/PROTOCOL.md)):

- **Hand pages off quickly.** The scanner stalls while your page handler runs; do cropping, writing and
  uploads on another task.
- **One session per stack.** `withSession` always sends `FIN` and unlocks. A Wi-Fi session that is never
  released keeps the scanner locked until it is switched off and on.
- **Sides.** Duplex scans send side A (facing down) then side B (facing up) for each print. A single-sided scan
  reads only side A, so load prints face down to get only the pictures, with about half the data.
- **Pages are raw.** Each JPEG still includes the grey backing around the print; software crop is on the roadmap.

### Command-line tool

```bash
swift run phastphoto discover
```

```bash
swift run phastphoto status
```

```bash
swift run phastphoto scan --dpi 600 --picture-only --out scans
```

Pass `--host <address>` (or set `PHASTPHOTO_HOST`) to skip Bonjour.

## Development

```bash
swift build && swift test
```

```bash
xcodebuild -scheme PhastPhoto-Package -destination 'generic/platform=iOS Simulator' build
```

The tests need no scanner: `SimulatedScanner` plays back the FF-680W's replies, and a loopback "IS" server
exercises the Wi-Fi transport. Protocol fixtures are real scanner replies from ffscan with the serial replaced.

## Credits and licence

MIT, see [LICENSE](LICENSE). The protocol work, the scanner facts in [docs/PROTOCOL.md](docs/PROTOCOL.md) and
the logic this port follows come from [ffscan](https://github.com/eg7eg7/ffscan) by the ffscan contributors,
also MIT. Not affiliated with or endorsed by Epson; FastFoto is a trademark of Seiko Epson Corporation.
