# Roadmap

What exists in ffscan (Python) and how it maps to this package. Apps own the UI, storage, AI and cloud
features; this package supplies what talks to the scanner and what processes its images.

## Done

- **Protocol** (`PhastPhotoProtocol`): "IS" packets, hello/holder parsing, ESC/I-2 token parser and parameter
  encoder, commands and reply headers, `ScanSettings` → `PARA` (with `#BSZ` and the fallback without it),
  `INFO`/`STAT` models, the JPEG SOF height fix. Ported from `ff680w.py` with its tests.
- **Wi-Fi client** (`PhastPhotoScanner`): Bonjour discovery (`NWBrowser`), `NetworkTransport` (`NWConnection`,
  IPv4 preferred, Nagle off, per-reply timeout), `ScannerSession` with `info`/`capabilities`/`status`/`scan`
  and a page stream; cancels on the scanner (`CAN `) on errors and task cancellation.
- **CLI** `phastphoto`: discover, info, capa, status, scan.

## Next

1. **Hardware check.** Run `phastphoto status` and `phastphoto scan` against a real FF-680W; check
   throughput (`MB/s` per side) matches ffscan (~0.7 MB/s before `#BSZ`, better after).
2. **Auto-crop and straighten** (`ff680w.py`: `find_photo_box`, `photo_quad`, `trim_backing`, `inside`,
   `autocrop`). Port to a new `PhastPhotoImaging` target on Core Graphics/vImage/Core Image. The heuristics
   are measured: keep thresholds and port ffscan's synthetic crop tests (tilted print with shadow, pale sky
   against a cool-grey backing, 300 dpi edge strip) before tuning anything.
3. **Blank-back detection** (`ink_fraction`), so apps can skip backs without writing.
4. **USB transport.** Same ESC/I-2 as raw bulk transfers (OUT `0x01`, IN `0x82`; FF-680W VID `0x04B8`,
   PID `0x016B`); header and parameter block as separate transfers; USB reset to clear a stuck session.
   macOS via IOUSBHost; iPadOS (M-series, USB-C) would need DriverKit. About 15x faster per side than Wi-Fi.
5. **Subnet probe fallback** for networks that block multicast: connect to TCP 1865 across the /24 and keep the
   host that greets with an `IS` `0x8000` hello.

## Later

- **Enhancement** (`enhance.py`): red-eye via Vision face landmarks, faded-colour restoration, auto tone.
- **Duplicates** (`dupes.py`): perceptual hash, threshold 7 bits (measured in ffscan).
- **Orientation**: Vision face roll, then scene classification with a margin; back-of-print OCR with a filter
  for lab codes and watermarks.
- **Metadata**: write EXIF orientation, dates and descriptions with ImageIO (lossless rotation).
- **Import** of Epson FastFoto output (`X.jpg`, back `X_b.jpg`, enhanced `X_a.jpg`).
- **Scan button** (push-scan via the interrupt endpoint / `com.epson.EventManager`), not understood yet.

## Out of scope

AI captions (Claude), cloud upload (rclone), the web UI, job queues and album layout are app concerns in
ffscan. Apps using this package can build them on top.
