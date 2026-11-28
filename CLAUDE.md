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
swift run phastphoto scan --dpi 300 --out scans [--process]
swift run phastphoto process --sides picture --out reprocessed scans/raw   # no scanner needed
xcodebuild -project Examples/PhastPhotoHarness/PhastPhotoHarness.xcodeproj -scheme PhastPhotoHarness \
  -destination 'generic/platform=iOS Simulator' build   # iOS test app; `xcodegen generate` there after adding files
```

## Layout

| Path | Role |
|---|---|
| `Sources/PhastPhotoProtocol` | Pure wire formats, no I/O: `ISPacket`, `ScannerHello`, `ESCI2` tokens/parameters/commands/reply header, `ScanSettings` (+ `photoDefaults`, length limit), `SideMode`/`ScanSide`, `ScannerInfo`/`ScannerStatus` (+ friendly text), `JPEGHeight`; `SNMP` (v1 Get/GetNext in BER), `ScannerHealth` + `EpsonMIB` (OIDs) |
| `Sources/PhastPhotoScanner` | `ScannerTransport` protocol; `NetworkTransport` (Network.framework), `USBTransport` (macOS: IOUSBHost; iPadOS: `DriverKitPipes` through the driver extension; both behind a fakeable pipes protocol), `ScannerConnection` (pick a transport); `ScannerDiscovery` (Bonjour, FF-680W filter), `SubnetProbe`; `ScannerSession` (actor: serialised exchanges, model check, scan loop, graceful stop); `RawSpool`, `PrintAssembler`, `ScannerWatch`; `ScannerHealthReader` (SNMP over UDP, `SNMPClient`, no lock) |
| `Sources/PhastPhotoImaging` | No Vision. `RGBImage` (R,G,B bytes, stored orientation, ICC kept) and `JPEGWriting` (derived JPEGs keep metadata); crop: `PhotoBox` → `PhotoQuad` → `AutoCrop` (+ `CropSampling`); `InkFraction`; `BackText`, `PenInk` (lone words in pen, not in ffscan); `Duplicates`/`DuplicateIndex` (Pillow-compatible Lanczos in `DuplicatesResample`); `Enhance`/`EnhancedCopy` (Pillow arithmetic by hand); `PhotoMetadata`, `PhotoOrientation` (lossless); `FastFotoImport` |
| `Sources/PhastPhotoVision` | Apple Vision, depends on Imaging: `BackReader`, `BackPolicy`, `AutoRotation`, `EyeFinder`, `VisionSupport` (timeouts, `VisionWarmUp`). Pure decision functions are separate from Vision calls so they can be unit tested |
| `Sources/PhastPhotoPipeline` | `PrintPipeline` (ffscan's `process_page` order over one print, returns data, writes nothing), `PrintAnalyzer` (Vision behind a protocol; `VisionAnalyzer` is the real one), `SideMode` → `BackPolicy` mapping |
| `Sources/CPhastPhotoDriverKit` | C client for the iPadOS USB driver (IOKit has no Swift module on iOS) and `PhastPhotoUSBProtocol.h`, the selectors shared with the driver |
| `Drivers/PhastPhotoUSBDriver` | DriverKit driver extension (C++, `.iig`) apps embed for USB on M-series iPads, and `TestHost`, an iPad app that embeds it for on-device checks; `project.yml` (XcodeGen). Signing in a git-ignored `Config/Local.xcconfig` (paid team). Worked on an iPad Pro M1 |
| `Sources/phastphoto` | Developer CLI: `main.swift` (arguments, commands), `PrintFolder.swift` (`PrintFolder` saves pipeline results, `ProcessingQueue` for `scan --process`, `RawScanFiles` pairs saved raw scans); tested by `Tests/phastphotoTests` |
| `Examples/PhastPhotoHarness` | SwiftUI iOS/iPadOS app for roadmap 1.1's device checks (discovery and permission, info/status, scan → pipeline, time and peak memory per print, synthetic sample). XcodeGen `project.yml`; the generated project is committed; team unset (`Config/Local.xcconfig`, git-ignored) |
| `Tests/PhastPhotoScannerTests/SimulatedScanner.swift` | In-memory ESC/I-2 scanner that enforces the reply rules; `ISTestServer` (loopback "IS" server) is in `NetworkTransportTests.swift` |

Imaging code works on synthetic images in tests; per-pixel loops are ~200x slower in Debug, so keep test images
small and hot loops on unsafe buffers. Do not tune crop, ink or duplicate thresholds without real scans
(roadmap 1.2): they were measured upstream.

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
- Paper-end detection (`PEDT`) needs hardware crop (`CRP `) on firmware 18.60: without it every page is the full
  `#ACQ` height (36 in) and a stack stops after one print. `ScanSettings.hardwareCrop` is on by default; its pages
  (`ScannedPage.hardwareCropped`) have no backing, so the pipeline must not crop them in software. (ffscan, on
  newer firmware, found `CRP ` a no-op and never sends it.)

## Conventions

- Swift 6 language mode, strict concurrency, no warnings. No third-party dependencies.
- Tests use Swift Testing. Add a check for any new parser, threshold or image heuristic, and break the code
  once to see the test fail.
- Session-level logic lives in `ScannerSession`, transport-specific framing in the transport. A USB transport
  must send each chunk passed to `transfer` as its own bulk transfer.
