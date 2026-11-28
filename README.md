# phastphotoswift

Open-source Swift packages for the Epson FastFoto FF-680W photo scanner on iOS, iPadOS and macOS: discovery and
scanning over Wi-Fi (and USB on the Mac or an M-series iPad), then on-device processing of the scans: auto-crop and straighten,
blank-back detection, reading the backs of prints, auto-rotation, duplicate detection, enhancement and photo
metadata. It is a Swift port of [eg7eg7/ffscan](https://github.com/eg7eg7/ffscan) (Python, MIT), which worked
out the scanner's network protocol.

This is a library, not an app: it has no UI. Apps add it as a Swift package and build their own interface on top.

> **Status: early, first hardware results in.** On a real FF-680W (firmware 18.60, November 2026): single-sided
> and duplex scans over Wi-Fi from a Mac and over USB from an M1 iPad Pro, each print cut to its paper by the
> scanner (A4, receipts, 6×4 prints), and a first run of the processing on four 6×4 prints: blank backs skipped, a
> handwritten word read from a back, upside-down and sideways prints turned. Not yet tried: 600 dpi, large stacks,
> an iPhone, USB from a Mac, and duplicate detection or enhancement judged on real scans. Everything is also tested
> against a simulated scanner, a loopback server and synthetic images. The supported scanner is the **FastFoto
> FF-680W**, the model the protocol was established on. See [docs/ROADMAP.md](docs/ROADMAP.md) for what is
> verified.

## Packages

| Product | What it does |
|---|---|
| `PhastPhotoProtocol` | Wire formats only, no I/O: "IS" packets, ESC/I-2 tokens and commands, `ScanSettings` → `PARA` block, `INFO`/`STAT` parsing, the JPEG height fix. |
| `PhastPhotoScanner` | The client: discovery (`ScannerDiscovery` over Bonjour, `SubnetProbe` fallback), transports (`NetworkTransport` for Wi-Fi, `USBTransport` on macOS and, through a driver extension the app ships, on M-series iPads; `ScannerConnection.automatic()` to pick one), `ScannerSession` for queries and scans, `RawSpool` to write pages to disk as they arrive, `PrintAssembler` to pair each picture with its back, `ScannerWatch` to scan each stack as it is loaded. |
| `PhastPhotoImaging` | Image processing, no Vision: `AutoCrop` (find, straighten and crop the print), `InkFraction` (blank backs), `BackText` (keep handwriting, drop lab codes; dates), `PenInk` (a lone word written in pen is kept), `Duplicates`/`DuplicateIndex`, enhancement (`removingRedEye`, `restoredFaded`, `autoEnhanced`, `adjusted`, `RGBImage.enhancedCopy`), `PhotoMetadata` and `PhotoOrientation` (lossless), `FastFotoImport`. |
| `PhastPhotoVision` | Apple Vision: `BackReader` (OCR of print backs), `BackPolicy` (which backs to keep), `AutoRotation` (faces, then scene), `EyeFinder` (for red-eye), `VisionWarmUp`. |
| `PhastPhotoPipeline` | `PrintPipeline`: runs each print through ffscan's order (back text, crop, blank-back and fast-mode checks, duplicates, enhanced copy, rotation, metadata) and returns the files to save. Vision sits behind `PrintAnalyzer`, so tests and apps can inject results. |
| `phastphoto` | A small macOS command-line tool for checking the library against a real scanner. |

Requires iOS 16 / macOS 13 or later and Swift 6.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/ryanhunt/phastphotoswift.git", from: "0.2.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "PhastPhotoScanner", package: "phastphotoswift")]),
]
```

### Local network access

- **iOS/iPadOS:** add to the app's Info.plist `NSLocalNetworkUsageDescription` (why you need the scanner) and
  `NSBonjourServices` containing `_scanner._tcp`. The first browse shows the permission prompt.
- **macOS (sandboxed):** enable the `com.apple.security.network.client` entitlement, and
  `com.apple.security.device.usb` for USB.
- **USB on iPadOS** (M-series iPads only; not iPhone): the app ships the driver extension in
  [Drivers/PhastPhotoUSBDriver](Drivers/PhastPhotoUSBDriver/README.md), with the
  `com.apple.developer.driverkit.communicates-with-drivers` entitlement, and the user turns the driver on in
  Settings > General > Drivers. Checked on an iPad Pro (M1): scans at about five times the Wi-Fi speed.

## Usage

```swift
import PhastPhotoScanner

guard let scanner = try await ScannerDiscovery.firstScanner() else { return }   // Bonjour, ~3 s
try await ScannerSession.withSession(transport: NetworkTransport(endpoint: scanner.endpoint)) { session in
    print(try await session.info().productName ?? "?")       // "FF-680W"

    let status = try await session.status()
    guard status.isReady else { print(status); return }       // "feeder empty", "paper jam", ...

    // ffscan's defaults (300 dpi, deskew, double-feed detection), both sides of each print
    let settings = ScanSettings.photoDefaults.with(sideMode: .both)
    // Each page is written to disk inside the scan loop, so whole JPEGs never pile up in memory.
    for try await page in session.spooledPages(settings, to: RawSpool(directory: folder, mode: .both)) {
        print(page.name, page.width, page.height)   // side B is the picture when prints load face up
    }
}
```

Processing each print as it arrives, the way ffscan does:

```swift
import PhastPhotoImaging
import PhastPhotoPipeline
import PhastPhotoScanner

let pipeline = PrintPipeline(settings: PrintPipelineSettings(
    enhancement: EnhancementOptions(),                    // also make an enhanced copy
    metadata: PhotoMetadata(album: "Summer 1974")))
var assembler = PrintAssembler(mode: .picture)            // pairs each picture with its back
for try await page in session.pages(ScanSettings.photoDefaults.with(sideMode: .picture)) {
    for item in assembler.add(page) {
        let result = try await pipeline.process(item)     // back text, crop, rotation, metadata, ...
        for side in result.saved {                        // skipped sides: result.picture?.skipReason
            let name = "print_\(item.index + 1)\(side.side == .a ? "_back" : "").jpg"
            try side.jpeg.write(to: folder.appendingPathComponent(name))
        }
    }
}
```

Give `PrintPipeline` a `findDuplicate` closure (for example `DuplicateIndex.findDuplicate(ofJPEG:in:)` over the
pictures already saved) to flag or skip prints scanned before. Nothing is written to disk by the pipeline.

Or use the parts directly (no scanner needed):

```swift
import PhastPhotoImaging
import PhastPhotoVision

let raw = try Data(contentsOf: url)
let cropped = try AutoCrop.cropJPEG(raw)          // a scan with backing (no hardware crop): straightened, cropped
let picture = try RGBImage.decode(cropped.jpeg)
let rotation = await AutoRotation.rotation(of: picture)               // faces, then scene; .decided
let eyes = try await EyeFinder.findEyes(in: picture).map(\.position)
let enhanced = try RGBImage.enhancedCopy(of: cropped.jpeg, eyes: eyes)
let metadata = PhotoMetadata(title: "Beach", date: "1974")
let tagged = try PhotoMetadata.write(metadata, to: enhanced.data)     // lossless: no re-encode
try PhotoOrientation.setRotation(rotation.degrees, in: tagged).write(to: outputURL)
```

Things worth knowing (details in [docs/PROTOCOL.md](docs/PROTOCOL.md)):

- **Hand pages off quickly.** The scanner stalls while a `scan(_:onPage:)` handler runs; do cropping and
  uploads on another task. `pages(_:)` doesn't stall the scanner but keeps every page in memory until you read it
  (~5.8 MB per 600 dpi side), so prefer `spooledPages(_:to:)`.
- **One thing at a time.** A session runs one exchange at a time: queries during a scan throw `sessionBusy`.
  `stopAfterCurrentPrint()` stops cleanly after the print that is feeding; `close()` cancels a running scan
  (`CAN `) before `FIN `.
- **Stay in the foreground on iOS.** A scan that stops polling mid-page jams the scanner, and an unreleased
  session keeps it locked: keep the app active while scanning.
- **One session per stack.** `withSession` always sends `FIN` and unlocks. A Wi-Fi session that is never
  released keeps the scanner locked until it is switched off and on.
- **Sides.** Duplex scans send side A (facing down) then side B (facing up) for each print. A single-sided scan
  reads only side A, so load prints face down to get only the pictures, with about half the data.
- **Pages are cut to the paper.** With hardware crop (`ScanSettings.hardwareCrop`, on by default) the scanner
  stops at the end of each print and trims each side to it; such pages have `hardwareCropped` set, and
  `PrintPipeline` does not crop them again. Without it, firmware 18.60 returns 36 in pages with the grey backing
  (and a stack stops after one print); crop those with `AutoCrop`.
- **FF-680W only.** Discovery lists only FF-680W scanners by default, and `open()` checks the model in `INFO`.

### Command-line tool

```bash
swift run phastphoto discover
```

```bash
swift run phastphoto status
```

```bash
swift run phastphoto scan --dpi 600 --deskew --double-feed 1 --sides picture --out scans
```

```bash
swift run phastphoto scan --watch --out scans
```

Add `--process` to run each print through `PrintPipeline` while the scan goes on: the untouched scans go to
`scans/raw`, the kept pictures and backs to `scans`, enhanced copies to `scans/Enhanced`. Processing runs in its
own task, so the scanner never waits for it:

```bash
swift run phastphoto scan --sides picture --process --enhance --album "Summer 1974" --out scans
```

`process` does the same for raw scans saved earlier, for example to try different settings without scanning
again:

```bash
swift run phastphoto process --sides picture --no-rotate --out reprocessed scans/raw
```

Scans use hardware crop by default: the scanner stops at the end of each print and cuts each side to the paper
(on firmware 18.60 it otherwise ignores the end of the paper and returns 36 in pages). `scan --no-hardware-crop`
turns it off, and `scan --length INCHES` sets the longest print (default 36). `process` assumes raws from such
scans; give it `--software-crop` for raws that still have the grey backing around the print.

Pipeline options: `--no-crop`, `--keep-blank-backs`, `--duplicates flag|skip|off` (default `flag`), `--enhance`,
`--no-rotate`, and metadata `--album`, `--title`, `--description`, `--place`, `--date YYYY[-MM[-DD]]`,
`--people "A, B"`, `--tags "X, Y"`. Raw scans keep `RawSpool`'s names (`<stamp>_scan_007_back.jpg`), which is
how `process` pairs a back with its picture; any other JPEG is processed as a picture of its own. Each print's
result is printed (saved files, skipped sides and why, back text, rotation, duplicates); a print that fails is
reported, the run carries on, and the exit status is 1. The first Vision call at a new path can take about a
minute while models load (`VisionWarmUp`). Release builds (`swift run -c release`) process prints many times
faster than Debug.

Pass `--host <address>` (or set `PHASTPHOTO_HOST`) to skip Bonjour. `info` hides the serial number unless you
pass `--show-serial`; `discover --all` lists every Bonjour scanner, not only FF-680Ws.

### iOS test app

[`Examples/PhastPhotoHarness`](Examples/PhastPhotoHarness) is a minimal SwiftUI app for running roadmap 1.1's
device checks on a real iPhone or iPad, where the CLI can't go. It depends on this package by path and shows,
with no polish: discovery and the local network permission outcome (including
`DiscoveryError.localNetworkDenied`), `info` and `status`, a scan of the loaded stack (`RawSpool` →
`PrintAssembler` → `PrintPipeline` with the real `VisionAnalyzer`), and each print's result: saved files, skip
reasons, back text, rotation, duplicates, the cropped image, and the metadata read back from the file (IPTC
beside XMP). The screen stays on while it scans or processes.

1. Copy `Examples/PhastPhotoHarness/Config/Local.xcconfig.example` to `Local.xcconfig` (git-ignored) and set
   your team and a throwaway bundle ID there. The committed project leaves the team unset: don't pick one in
   Xcode's Signing pane, which edits the project.
2. Open `Examples/PhastPhotoHarness/PhastPhotoHarness.xcodeproj` and run it on the device. The scheme runs a
   **Release** build, because the imaging loops are about 200 times slower in Debug; the app shows which build it
   is.
3. Tap **Find scanners**: the first browse shows the local network prompt. Try allowing and refusing it (refusal
   should show "local network access denied"; Settings > Privacy & Security > Local Network turns it back on).
4. **Info**, **Status** (feeder empty, loaded, cover open), then **Scan the loaded stack** at 300 and 600 dpi.
   **Stop after this print** stops cleanly; **Cancel now** is the hard cancel, to see whether it jams.
5. Each print logs its time and peak memory (`phys_footprint`, sampled every 5 ms) to the screen and to
   `timings.csv`. Raw scans, results, `timings.csv` and `harness-log.txt` are in the app's Documents folder:
   open it in Files or copy it to a Mac from the device's Files tab in Finder, and reprocess raw scans there with
   `phastphoto process` to compare Mac and device Vision results.

**Process sample** runs the same spool-and-pipeline path on a synthetic print and back at the chosen resolution
(two lines of "handwriting" for OCR, a slight tilt for the crop); **Same sample again** should be flagged as a
duplicate. Use it in the simulator, where discovery finds nothing and Vision's face and scene results are fake
(its OCR did read the sample's back on iOS 26.0), and on a device to measure processing without a scanner. After changing `project.yml` or adding a source file, run `xcodegen generate`
there.

## Development

```bash
swift build && swift test
```

```bash
xcodebuild -scheme PhastPhoto-Package -destination 'generic/platform=iOS Simulator' build
```

CI runs the macOS tests, the tests on an iPhone simulator, an iOS device build and the DriverKit driver build.
The tests need no scanner: `SimulatedScanner` plays back the FF-680W's replies, a loopback "IS" server
exercises the Wi-Fi transport and subnet probe, and fake pipes exercise USB framing. Imaging tests use synthetic
images built in code (ffscan's own test scans, ported). Protocol fixtures are real scanner replies from ffscan
with the serial replaced.

## Credits and licence

MIT, see [LICENSE](LICENSE). The protocol work, the scanner facts in [docs/PROTOCOL.md](docs/PROTOCOL.md) and
the logic this port follows come from [ffscan](https://github.com/eg7eg7/ffscan) by the ffscan contributors,
also MIT. Not affiliated with or endorsed by Epson; FastFoto is a trademark of Seiko Epson Corporation.
