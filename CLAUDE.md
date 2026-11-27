# CLAUDE.md

Guidance for AI coding agents (and humans) working on phastphotoswift: Swift packages for the Epson FastFoto
FF-680W scanner, ported from the Python project [ffscan](https://github.com/eg7eg7/ffscan). It is a
library for iOS, iPadOS and macOS apps, with no UI. Read README.md for the API and docs/PROTOCOL.md before
touching scanner code; docs/ROADMAP.md lists what is ported and what is next.

## Ground rules

- **This repository is public. Never commit anything personal:** scanner serial numbers or hostnames
  (`EPSONxxxxxx.local`), real IP addresses (use `192.0.2.x`), Bonjour names of other devices, emails, names or
  text from people's photos, or home paths.
- **Never commit photos or scanner output.** `.gitignore` blocks `*.jpg` and `scans/`. Test images are
  synthetic, built in code.
- Keep upstream attribution: LICENSE carries ffscan's copyright line, docs/PROTOCOL.md says which upstream
  commit it was copied from. When porting more of ffscan, note the upstream commit in the change.

## Commands

```bash
swift build && swift test                       # macOS; no scanner needed
xcodebuild -scheme PhastPhoto-Package -destination 'generic/platform=iOS Simulator' build
swift run phastphoto discover|info|capa|status  # against a real scanner on the network
swift run phastphoto scan --dpi 300 --out scans
```

## Layout

| Path | Role |
|---|---|
| `Sources/PhastPhotoProtocol` | Pure wire formats, no I/O: `ISPacket`, `ScannerHello`, `ESCI2` tokens/parameters/commands/reply header, `ScanSettings`, `ScannerInfo`/`ScannerStatus`, `JPEGHeight` |
| `Sources/PhastPhotoScanner` | `ScannerTransport` protocol, `NetworkTransport` (Network.framework), `ScannerDiscovery` (Bonjour), `ScannerSession` (actor: commands, scan loop) |
| `Sources/phastphoto` | Developer CLI |
| `Tests/PhastPhotoScannerTests/SimulatedScanner.swift` | In-memory ESC/I-2 scanner that enforces the reply rules; `ISTestServer` (loopback "IS" server) is in `NetworkTransportTests.swift` |

## Scanner facts that cost time to learn (from ffscan)

- Photos load face up: **side B is the picture**, side A the back of the print. A is sent first. Single-sided
  scans read only side A (face down). `PARB` always answers `#parFAIL`: no per-side settings.
- Keep polling `IMG ` while it returns empty. Stopping early aborts the page and the scanner reports a jam.
- The JPEG SOF carries the *requested* height; `JPEGHeight.replacing` patches in the `#pen` height.
- The scanner sends at most `reply_len` bytes; pull bodies with empty requests. **Never ask for header and
  body in one reply** (`replyLength` > 64 on a command): the scanner stops answering and stays locked even after
  the connection drops, until it is switched off and on. `SimulatedScanner` throws `wouldHang` for this.
- Send `#BSZ` (1 MiB): without it every 64 KB block costs two Wi-Fi round trips.
- Prefer IPv4: Bonjour names also resolve to IPv6 link-local, and an IPv6 session once left an invisible lock.
- USB: same commands as raw bulk transfers, no lock; header and parameter block must be **separate** writes.
- Hardware crop (`CRP `) is a no-op; crop in software.

## Conventions

- Swift 6 language mode, strict concurrency, no warnings. No third-party dependencies.
- Tests use Swift Testing. Add a check for any new parser, threshold or image heuristic, and break the code
  once to see the test fail.
- Session-level logic lives in `ScannerSession`, transport-specific framing in the transport. A USB transport
  must send each chunk passed to `transfer` as its own bulk transfer.
