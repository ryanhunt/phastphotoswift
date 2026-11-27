# Roadmap

What exists in ffscan (Python, commit a041a3f) and how it maps to this package. Scope: the Epson FastFoto
**FF-680W** only. Apps own the UI, storage, AI and cloud features; this package supplies what talks to the
scanner and what processes its images.

Each packet is sized for one engineer and names what it ports (`file:lines` in ffscan a041a3f), where it
lives, the constants to keep, and the upstream tests to port (`tests/test_ffscan.py`). **[HW]** = needs a
real scanner. **[Device]** = needs a real device or private real photos (the iOS simulator's Vision is fake;
no photos are committed). Port the code, not the docstrings: two upstream docstrings disagree with their code
(`trim_backing` and `photo_quad` thresholds).

## Status

Nothing has run against a real FF-680W yet: every **[HW]** item below is open, and **[Device]** code is written
but checked only with injected inputs (plus Vision OCR of rendered text on macOS).

| Area | Packets | Status |
|---|---|---|
| Protocol, Wi-Fi client, CLI (first port) | — | Done |
| Session safety | 0.1–0.6 | Done: serialised exchanges, `sessionBusy`, graceful stop, FF-680W-only discovery with model check, settings limits and `photoDefaults`, `SideMode`, CLI flags, `RawSpool` |
| Hardware check, raw corpus | 1.1, 1.2 | Open **[HW]** |
| Crop and ink | 2.1–2.5 | Done (`RGBImage`, `PhotoBox`, `PhotoQuad`, `AutoCrop`, `InkFraction`) |
| Crop on real scans | 2.6 | Open **[HW]** |
| Back text, back policy, print assembly | 3.1, 3.3, 3.4 | Done (`BackText`, `BackPolicy`, `PrintAssembler`) |
| Back OCR | 3.2 | Code done (`BackReader`); real handwriting unverified **[Device]** |
| Orientation tag, metadata | 4.1, 4.4 | Done (`PhotoOrientation`, `PhotoMetadata`, lossless) |
| Face roll, scene fallback | 4.2, 4.3 | Code done (`AutoRotation`); real photos unverified **[Device]** |
| Duplicates | 5.1, 5.2 | Done (`Duplicates`, `DuplicateIndex`) |
| Threshold on real rescans | 5.3 | Open **[HW]** |
| Enhancement | 6.1, 6.3–6.5 | Done (`removingRedEye`, `restoredFaded`, `autoEnhanced`, `adjusted`, `enhancedCopy`) |
| Eye finder | 6.2 | Code done (`EyeFinder`); real flash photos unverified **[Device]** |
| Subnet probe, transport choice, watch | 7.1, 7.3, 7.4 | Done (`SubnetProbe`, `ScannerConnection`, `ScannerWatch`) |
| USB on macOS | 7.2 | Code done (`USBTransport`, IOUSBHost); framing tested with fake pipes, never run on a scanner **[HW]** |
| USB on iPadOS | 7.5 | Works on an iPad Pro M1 (iPadOS 27.2.1): `INFO`, `STATUS`, single-sided and duplex scans over USB; 600 dpi, stacks, timeouts and reset not yet tried **[HW]** |
| FastFoto import | 8.1 | Done (`FastFotoImport`) |
| Per-print pipeline | 9.1 | Done (`PrintPipeline` in `PhastPhotoPipeline`); tested with synthetic prints and injected Vision results |
| CLI processing | 9.2 | Done: `scan --process` and `process` run `PrintPipeline` on live and saved raw scans |

## Pipeline the packets add up to

Per scanned side, in this order (`app.py:425-490`); sides are processed strictly in scan order:

1. Side A: read back text (crop a copy → ink ≥ 0.002 → OCR → `human_text`).
2. Side filter (picture / both / back / fast).
3. Crop.
4. Blank back: drop if side A, not "back" mode, no back text, ink < 0.015.
5. Fast mode with crop on: drop if ink < 0.015 (the print was loaded face up).
6. Duplicate check (pictures only, on the cropped image).
7. Enhanced copy (pictures only).
8. Auto-rotation (pictures only): faces, then scene; report whether it was decided.
9. Metadata: back text as "Written on back: …", date from back text if none; orientation tag on every file.

All pixel work is in stored orientation: never apply EXIF orientation before crop or Vision.

## Phase 0: session safety (no scanner needed)

**0.1 Serialise the session.**
- Files: `ScannerSession.swift`, `NetworkTransport.swift`.
- One command exchange at a time; queries during a scan throw `sessionBusy`.
- `close()` waits for a running scan to send `CAN `.
- `pages()` teardown awaits the scan task.
- Tests: break out of `pages()` early → log ends `CAN , FIN `; `status()` during `scan` never reaches the wire
  between an `IMG ` header and its body (`SimulatedScanner.bodyNotRead`).

**0.2 Graceful stop.**
- `stopAfterCurrentPrint()` (finish through the `#pen` of the last side, then `CAN `) beside hard cancel.
  ffscan's app only cancels between pages (`app.py:636-638`); `desktop.py:65-68` notes that quitting mid-page
  jams the scanner.
- Document that a scan needs the app in the foreground on iOS.
- Tests: simulated.

**0.3 Discovery for FF-680W only.**
- Files: `ScannerDiscovery.swift`, `ScannerSession.swift`.
- Filter on TXT `mdl == "FF-680W"`; verify `INFO` `#PRD` after opening.
- Surface `NWBrowser` `.waiting` (local network permission refused) as its own error.

**0.4 Settings.**
- `validate()` rejects `length × dpi > 65535` (`#IMX`, and the SOF height is 16-bit).
- `ScanSettings.photoDefaults` = ffscan app defaults (`app.py:43-52`): 300 dpi, colour, deskew on, DFL1,
  quality 90, width 8.5.
- `SideMode` picture / both / back / fast → `duplex` (`app.py:630`), and which side is the picture.

**0.5 CLI.**
- `--deskew`, `--double-feed 1|3`, `--width`, `--watch`.
- Redact `S/N` unless `--show-serial`.
- Print per-side blocks, largest block, wait and transfer seconds.

**0.6 Raw spool.**
- Ports `save_raw` (`app.py:406-412`).
- File: `PhastPhotoScanner/RawSpool.swift`.
- Writes each page to a caller-supplied directory inside the scan loop and yields URLs; README corrected
  (the stream otherwise buffers whole JPEGs, ~5.8 MB per 600 dpi side).
- Tests: simulated.

## Phase 1: hardware check [HW]

**1.1 Checklist with a real FF-680W**, using 0.5's CLI (with `--process`, 9.2, to see crops and back text).
*Paper end, found 27 Nov 2026 (firmware 18.60.SP14P2):* `PEDT` only works together with `CRP `. Hardware crop is now
on by default, and those pages skip software crop (PROTOCOL.md, "Things that are easy to get wrong"). Still to
check: software straightening of hardware-cropped prints that come through slightly tilted; `--no-hardware-crop`
on newer firmware.
- `status` with feeder empty, loaded, cover open.
- Duplex scans at 300 and 600 dpi with deskew + DFL1.
- Single-sided, face down.
- Throughput: ffscan measured ~8 s per 600 dpi side without `#BSZ`, ~4.5 s with; largest block ≈ 1 MiB.
  (`ScanSummary.blockSizeAccepted` proves nothing: the scanner answers `#parOK` to any `#BSZ`.)
- `emptyReply` never fires on body reads (ffscan retries forever instead).
- `#lft` appears only on the last side.
- Hard cancel mid-page, and graceful stop: jam or lock afterwards?
- Close, then a second client can lock.
- Busy hello names the holder while Epson Scan 2 holds the scanner.
- Does a dropped session's lock expire (the lock payload ends `01 2C` = 300; try 300 s)?
- A Bonjour endpoint connects with IPv4 forced.
- First run on an iOS device (permission prompt, refusal).
- Scanner asleep (ffscan uses a 15 s timeout for status checks after a 5 s one failed on wake).
- Whether raw JPEGs carry ICC, JFIF density or EXIF.

**First hardware results (27 November 2026, firmware 18.60.SP14P2):** `INFO` and `STATUS` work over Wi-Fi and
USB; single-sided and duplex scans complete. Every scan returned pages 36 in long (`#pen` 2550 × 10800 at
300 dpi, the `#ACQ` maximum), one print followed by backing, with `PEDT` set. That happened over USB, over Wi-Fi,
and with ffscan's own code, so it is scanner-side. In a duplex scan of two prints, only the first came back.
Next: try a shorter `#ACQ` length, a stack of prints, and the paper-end flag variants, and compare with Epson's
own software on this firmware.

**1.2 Private raw corpus** (git-ignored `scans/`), for phases 2–6:
- 300 and 600 dpi, deskew on and off;
- small, large, tilted, bordered, pale-sky and dark-edged prints;
- backs that are blank, watermarked, lab-coded, handwritten;
- a face-up stack in fast mode;
- the same stack scanned twice (duplicates).

## Phase 2: crop (`PhastPhotoImaging`, pure, no Vision)

**2.1 Image I/O** (started: `RGBImage.swift`).
- RGB8 buffer in stored orientation; reduced decode like `_thumbnail` (`ff680w.py:326-338`, 600 px).
- Encode at quality 0.95 keeping the source colour space/ICC, DPI, EXIF and XMP (`ff680w.py:365`, `:384`).
- Full-resolution pixels only for the region being cropped (a 600 dpi raw is 5100 px wide).
- Tests: channel order; grey JPEG; tagged-profile JPEG keeps its profile; metadata survives a round trip.

**2.2 Coarse box.**
- Ports `_longest_run` (`:298-310`), `_background` (`:131-138`), `find_photo_box` (`:103-128`).
- File: `PhotoBox.swift`.
- Constants:
  - gap 3;
  - background = per-channel median of columns 1.5–3% in from each side;
  - foreground = (Σ|Δ| > 40 or chroma > backing chroma + 12) and min < 250;
  - rows > 5% of width; columns > 30% of the row span; rows refined > 30% of the column span.
- Tests: `test_ffscan.py:39-42` (longest run), `:54-67` (box with band and white fill = (20,5,80,50)),
  `:69-72` (300 dpi edge strip).

**2.3 Edge fit.**
- Ports `photo_quad` (`:141-242`).
- File: `PhotoQuad.swift`.
- Constants:
  - working copy ≤ 3000 px;
  - max shadow 1.2% of the longer side;
  - shadow = chroma < 14 and 0.65·luma < mean < luma + 10;
  - edge = first run of 3 picture pixels;
  - pad 3%, inside tolerance 1.5%;
  - 3 px strips from 15% to 85% of the span, step 3;
  - skip hits at index ≤ 2;
  - need ≥ 10 points, and ≥ 40% of steps for an own slope;
  - Theil–Sen over pairs half the edge apart;
  - shared tilt = median of own slopes; an edge > 0.02 off takes the shared tilt;
  - median intercept;
  - reject if any corner is more than the pad from the coarse box.
- Tests: synthetic quads with a known tilt; a cut-off edge falls back to the coarse edge.

**2.4 Warp, trim, crop.**
- Ports `autocrop` (`:353-385`), `trim_backing` (`:245-274`), `inside` (`:277-295`).
- File: `AutoCrop.swift`.
- Constants:
  - output size = mean of opposite edge lengths;
  - bilinear-quad mapping (Pillow `Image.QUAD`) with bicubic sampling;
  - margin 0.4% of the longer side;
  - trim step 4; a line is picture if mean stddev ≥ 8, or channel-mean spread ≥ 15, or mean < 0.65·luma;
  - backing if mean < luma + 25 (limit 3% per side), else paper (limit 0.6%); lines sampled over the
    middle 80%;
  - `inside` step 2, worst side first; out-of-scan mask computed from coordinates;
  - fall back to the coarse box when the fit fails.
- Tests: `:77-93` (1° tilt with a 35 px shadow: 1140 < w ≤ 1200, 760 < h ≤ 800, five points with
  r − b > 40), `:95-106` (cool-grey backing and pale sky: 1170 < w ≤ 1200, 770 < h ≤ 800).

**2.5 Ink.**
- Ports `ink_fraction` (`:341-350`).
- File: `InkFraction.swift`.
- Constants: 600 px thumbnail of the *cropped* image; 4% border; every second pixel each way; paper =
  per-channel median; ink = Σ|Δ| > 90.
- Tests: synthetic blank, faint watermark, one line of writing, full picture.

**2.6 Check crop and ink on the corpus [HW data].** Compare against ffscan on the same raws before changing
any constant.

## Phase 3: backs and sides

**3.1 Back-text filter and dates** (pure; `PhastPhotoImaging/BackText.swift`).
- Ports `DATE_PATTERNS`, `date_from_text` (`app.py:144-168`), `WATERMARK_WORDS`, `human_text` (`:172-193`).
- Tests: `test_ffscan.py:186-190`, `:193-197`.

**3.2 Back OCR** (`PhastPhotoVision/BackReader.swift`) **[Device]**.
- Ports `orient.swift:49-67`.
- Constants: 2000 px; four orientations; `.accurate`; automatic language; confidence ≥ 0.4;
  score = Σ confidence × length.
- Tests: rendered text in each rotation, on macOS.

**3.3 Back decisions** (`PhastPhotoVision/BackPolicy.swift`).
- Ports `read_back` (`app.py:196-205`), `back_with_writing` (`:502-512`), the blank-back rule (`:443-448`),
  the fast-mode rule (`:449-455`). One line of handwriting scores ~0.008 ink and lab codes 0.000–0.012, both
  under 0.015: never drop a back on ink alone.
- Constants: read threshold 0.002; blank threshold 0.015.
- Tests: decision table with injected ink and text.

**3.4 Print assembly** (`PhastPhotoScanner/PrintAssembler.swift`).
- Ports pairing and relabelling (`app.py:639-648`).
- Groups A and B by index, exposes picture/back roles per `SideMode`, hands the back to the picture's
  processing.
- Tests: simulated duplex, single-sided, fast.

## Phase 4: orientation and metadata

**4.1 Orientation tag** (`PhastPhotoImaging/Orientation.swift`).
- Ports `ORIENTATION_TAG`, `set_rotation`, `get_rotation` (`app.py:109-120`).
- 0/90/180/270 clockwise ↔ 1/6/3/8, written without re-encoding.
- Tests: round trip; JPEG scan data unchanged.

**4.2 Face roll** (`PhastPhotoVision/AutoRotation.swift`) **[Device]**.
- Ports `orient.swift:91-105`, `app.py:129-136`.
- Constants: 1024 px; confidence > 0.5; upper median; snap to 90°; any face = decided.
- Tests: decision logic with injected rolls. Confirm the roll sign on real photos.

**4.3 Scene fallback** **[Device]**.
- Ports `orient.swift:31-47`, `app.py:123-141`.
- Constants: 512 px; four orientations; sum of top-5 confidences; margin 1.0.
- Tests: decision logic with injected scores. Re-measure the margin on each supported OS.
- Document the Vision warm-up and a per-call timeout.

**4.4 Metadata** (`PhastPhotoImaging/PhotoMetadata.swift`).
- Ports `METADATA_TAGS`, `write_metadata`, `read_metadata`, `gps_of` (`app.py:215-258`).
- Fields: title, description, album, place, headline, people, tags, date (`YYYY`, `YYYY-MM`, `YYYY-MM-DD`
  → `YYYY:MM:DD 00:00:00`); the back-text merge (`:470-474`).
- Tests: write then read; list de-duplication; GPS read (`test_ffscan.py:225-234`); compare tags with
  `exiftool` once by hand.

## Phase 5: duplicates (`PhastPhotoImaging/Duplicates.swift`)

**5.1 Hash.**
- Ports `dhash`, `hashes`, `distance`, `THRESHOLD` (`dupes.py:14-40`).
- Constants: ≤256 px thumbnail; BT.601 grey; 9×8 Pillow-compatible Lanczos; four rotations; duplicate if ≤ 7.
- Tests: `test_ffscan.py:124-136` with a Swift PRNG (re-check the seeds).

**5.2 Index.**
- Ports `Index` (`dupes.py:49-95`): modification-date cache, `findDuplicate`, `groups` (oldest first).
- Pictures only, passed in by the caller (backs and enhanced copies excluded; no file-name rules).
- Tests: temp files.

**5.3 Check the threshold on the corpus's repeated stack [HW data].**

## Phase 6: enhancement

**6.1 Red-eye pixels** (`PhastPhotoImaging/Enhance.swift`).
- Ports `remove_red_eye` (`enhance.py:24-37`).
- Tests: `test_ffscan.py:108-116`.

**6.2 Eye finder** (`PhastPhotoVision/EyeFinder.swift`) **[Device]**.
- Ports `orient.swift:69-89`, `find_eyes` (`enhance.py:14-21`).
- Untested on real flash photos upstream too.

**6.3 Restore and auto.**
- Ports `restore_faded`, `auto_enhance` (`enhance.py:40-55`).
- By hand on 8-bit values, not Core Image. Constants: cutoff 0.5%; brightness target 0.47, gamma 0.7–1.4;
  saturation target 0.38, factor 1.0–1.3; sharpness 1.15.
- Tests: synthetic faded image reaches full range; targets move the right way.

**6.4 Manual adjustments.**
- Ports `adjust`, `enhance_image` (`enhance.py:58-98`).
- Sliders −50…50; warmth k = value/330; fixed step order.

**6.5 Enhanced copy.**
- Ports `enhance` (`enhance.py:101-107`, `app.py:208-212`).
- Quality 95, DPI (default 300), all metadata including GPS copied from the original.
- Tests: `test_ffscan.py:225-236`.

## Phase 7: more ways to reach the scanner

**7.1 Subnet probe** (`PhastPhotoScanner/SubnetProbe.swift`).
- Ports `_scan_subnet`, `_is_epson_scanner` (`ff680w.py:439-472`).
- Constants: /24 only; skip own address; 64 at a time; 0.4 s connect, 1 s read; accept `IS` + `0x8000`,
  then confirm the model.
- Tests: loopback `ISTestServer`.

**7.2 USB on macOS** (`PhastPhotoScanner/USBTransport.swift`, IOUSBHost) **[HW]**.
- Ports `_usb_device`, `_enter_usb`, `_xfer`, `command` (`ff680w.py:504-515`, `:567-630`).
- Constants: VID `0x04B8`, PID `0x016B`; interface 0; OUT `0x01`, IN `0x82`; each chunk its own transfer;
  no lock; reset + 2 s + re-claim on a stuck device; 5 ms poll.
- Sandbox entitlement `com.apple.security.device.usb`.

**7.3 Transport choice.** USB if present, else Wi-Fi (`ff680w.py:530-550`).

**7.4 Watch helper.** New session per stack, poll every 2 s, friendly status text (`ff680w.py:752-766`,
`app.py:716-722`). Tests: simulated.

**7.5 USB on iPadOS** (`Drivers/PhastPhotoUSBDriver`, `PhastPhotoScanner/DriverKitPipes.swift`,
`CPhastPhotoDriverKit`) **[HW]**.
- M-series iPads only (DriverKit); no iPhone, no A-series iPad. A DriverKit extension the app embeds claims
  interface 0 and does the bulk transfers; `USBTransport` on iOS reaches it through its user client (write, read,
  reset selectors in `PhastPhotoUSBProtocol.h`), reusing the macOS framing and its tests.
- *Done, partly checked on hardware:* on an iPad Pro 12.9-inch (M1), iPadOS 27.2.1, the driver loaded, the
  `TestHost` app found it, and `INFO`, `STATUS`, single-sided and duplex 300 dpi scans worked over USB, at
  5.5–6.6 MB/s (Wi-Fi: 1.0–1.2 MB/s).
  Two driver bugs found on the device are fixed: buffer mappings the driver needs to write to are read-only, so
  the write buffer is now `InOut`, and reads go straight into the app's buffer. Not yet tried: 600 dpi, a stack
  of prints, timeouts, reset, unplugging. The driver's README has the details. Distribution needs Apple's DriverKit grant
  for Epson's vendor ID.
- *Not USB:* see 1.1 for the 36 in pages.

## Phase 8: import

**8.1 FastFoto folders** (`PhastPhotoImaging/FastFotoImport.swift`).
- Ports `fastfoto_photos` (`app.py:677-689`) and the import rules (`:692-704`): crop off, `fast` treated as
  `picture`, sources read only.
- Tests: `test_ffscan.py:176-183`.

## Phase 9: wiring

**9.1 Per-print pipeline.** One type (in a module that depends on Imaging and Vision) that takes an
`AssembledPrint` (or two raw files) and runs the order in "Pipeline the packets add up to": back text, side
filter, crop, blank-back and fast-mode checks, duplicate check, enhanced copy, rotation, metadata. It maps
`SideMode`/`ScanSide` onto `BackPolicy`'s own side enums and `Eye` onto `EyePosition` (`Eye.position`).
Tests: synthetic prints through the whole chain with injected Vision results.
*Done:* `PrintPipeline` returns the files to save (nothing is written); Vision is behind `PrintAnalyzer`;
duplicates go through a caller-supplied `findDuplicate` closure (`DuplicateIndex.findDuplicate(ofJPEG:in:)`).
Differences from `process_page`, all deliberate: the back is cropped once and that crop reused for saving;
back text is not read in back mode (upstream reads it but never uses it); a back whose OCR fails is kept and
reported in `warnings` instead of failing the page; a duplicate lookup or eye-finding failure is a warning;
ink and Vision run on the in-memory crop rather than the re-read JPEG file. AI analysis, uploads and file
naming stay with the app.

**9.2 CLI processing.** `phastphoto scan --process` saves raw scans to `OUT/raw` inside the scan loop and runs
the pipeline in a separate task (`ProcessingQueue`, `PrintFolder`); `phastphoto process` reruns it on saved raw
scans, pairing backs and pictures by `RawSpool`'s file names. This is the tool for 1.1, 1.2, 2.6 and 5.3: scan
once, then reprocess the raws with different settings. *Done;* checked end to end on synthetic raw scans with
real Vision on macOS (back text read, blank backs dropped, a repeated print flagged).

## Later (not understood, or needs hardware we don't have)

- **Scan button** (interrupt endpoint `0x83` / `com.epson.EventManager`).
- **TLS network path** (`ESNWInterface`).

## Known limitations

- Subnet probe assumes a /24, and like ffscan accepts any device that sends an `IS` hello (the session's
  `INFO` check then rejects a non-FF-680W).
- Crop re-encodes the JPEG once (quality 95).
- Red-eye is tested on synthetic eyes only.
- The scene margin and the duplicate threshold were measured on ffscan's setup and need re-checking here.
- Resampling is not bit-identical to Pillow everywhere: crop thumbnails use Core Graphics, and duplicate hashes
  of JPEG files use an ImageIO reduced decode rather than Pillow's `draft` + `thumbnail` (the 9×8 Lanczos step
  itself follows Pillow). Hashes may differ from ffscan's by a few bits; 5.3 re-checks the threshold.
- `BackReader`'s winning rotation is not a reliable orientation signal (Vision reads rotated text at any
  orientation); use it for text only.
- Metadata lists with repeated items keep the first occurrence; exiftool's `-=`/`+=` sequence in ffscan may keep
  the last.
- `ScannerDiscovery.scanners()` ends with an error on any `NWBrowser` `.waiting` state, including a brief Wi-Fi
  change; refused local network access is reported as `localNetworkDenied`.
- A USB transfer already in flight is not aborted by task cancellation; it finishes or times out (60 s).
- `photo_quad`'s "skip hits at index ≤ 2" rule is ported but no synthetic test can tell it apart.

## Out of scope

- **AI captions and AI rotation (Claude):** network service and keys; apps can use the `decided` flag from 4.2/4.3.
- **Cloud upload (rclone):** app concern.
- **Web UI, thumbnails, previews, settings storage:** app concerns.
- **Durable job queues:** app concern; the library only requires sides to be processed in order.
- **Album layout and file naming** (`Originals/`, `Enhanced/`, prefixes, numbering): app concern; nothing in
  the library depends on file names.
- **Local face grouping, dust and scratch removal** (ffscan "Next"): not ported.
- **Other ESC/I-2 scanners:** FF-680W only.
