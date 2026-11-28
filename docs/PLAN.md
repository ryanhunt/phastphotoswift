# Plan after 0.2.0

> **Progress.** 0.3.0 (29 November 2026) has 11.1–11.3: `SNMP`, `ScannerHealth`, `ScannerHealthReader` and
> `phastphoto health`, read on a real FF-680W. `status --raw` from 11.3 moved to 12.1. 11.4 (labelling) was done
> at the scanner on 29 November 2026 and shipped in 0.4.0 (`ScannerHealth.counts`, `.power`): see its results below. Next: the rest of row 4's visit (10.1, 12.1 captures).

What is left to build and check, in packets sized for one engineer, in the style of [ROADMAP.md](ROADMAP.md).
Packet numbers below 10 are ROADMAP's; this plan starts at 10 and does not repeat what ROADMAP already says.
**[HW]** = needs a real scanner, with its owner present. **[Device]** = needs a real device or private photos.

> Identifiers are left out or replaced: addresses use `192.0.2.x`, serial numbers `X0AB000000`, MAC addresses
> `02:00:00:00:00:01`. Counter values and firmware versions quoted below are from one scanner and identify nobody.

## What was verified, and what is guesswork

Probed on 28 November 2026 against one FF-680W on Wi-Fi (firmware 18.60.SP14P2), read-only: the existing
`discover`, `info`, `capa` and `status` commands, HTTP(S) GETs, Bonjour browsing, and SNMP v1 walks with the
`public` community. No new ESC/I-2 command was sent, nothing was scanned, no form was submitted.

**Verified on the scanner**

- **SNMP answers** on UDP 161 with community `public`, without the scanner's lock and without a session. The
  Epson enterprise tree (`1.3.6.1.4.1.1248`) returned about 295 values; MIB-2 about 300. The Printer MIB
  (`1.3.6.1.2.1.43`) is absent.
- **Firmware over SNMP**, with the scanner's own labels: `Main FW` = `SP14P2`, `Network FW` = `18.60`,
  `FW Package` = `18.60.SP14P2.FY17` (`1248.1.2.2.2.1.1.2.1.n`, labels in `…1.1.3.1.n`). `INFO` gives `#PRV`
  `18.60.SP14P2` and `#VER` `ADF 14P2`.
- **A consumable row over SNMP** (`1248.1.4.2.14.1.1.c.1.1`): name `Roller Assemblly Kit` (the firmware's
  spelling), `200000` in column 6, `1331` in column 7. Epson's FAQ for this model gives the kit a life of
  200,000 scans, so column 6 is the life and column 7 the scans on the current kit.
- **A counter row over SNMP** (`1248.1.4.2.6.1.1.c.1.1`): columns 4, 7 and 8 all read `1331`; column 5 `1327`;
  column 6 `18`; column 10 `4`; column 11 `21`. The scanner does not label them.
- **Power-off choices over SNMP** (`1248.1.2.2.3.6.1.2.1.1…7`): `0, 30, 60, 120, 240, 480, 720`, with `120` at
  `1248.1.2.2.3.3.1.3.1` and `10` at `1248.1.2.2.3.1.1.9.1`.
- **The scanner's clock over SNMP** (`1248.1.2.2.3.1.1.11.1`, an 11-byte DateAndTime): it matched UTC to the
  minute.
- **Network details over SNMP**: system name, uptime, interface MAC, IPv4 address, mask and gateway, and a
  wireless group (`1248.1.1.3.1.29`) holding the network name and access point address. Also the serial number
  (twice) and the host name of the last computer that used the scanner (`1248.1.4.2.21.1.1.2.1`).
- **Web Config is closed until someone sets a password.** Port 80 redirects (307) to HTTPS with a self-signed
  certificate, and every `/PRESENTATION/...` page then redirects to a "Change Administrator Password" form. No
  status, maintenance or network page can be read without submitting that form, so nothing was read.
- **No eSCL or IPP.** Bonjour advertises `_scanner._tcp` and `_http._tcp` only (no `_uscan._tcp`, `_uscans._tcp`,
  `_ipp._tcp`); `/eSCL/ScannerCapabilities` and `/eSCL/ScannerStatus` return 500.
- **`INFO` tokens the package does not read yet:** `#ADF` `FORD PF1N`, `PREF`, `ASCN`, `RCVR`, `OVSN 0 0`, `CRST`,
  `CARD`; `#IMX 65535 65535`; `#VER`; `#DSZ 1536`; `#AFM`; `#DFM 100`; `#EXI`. **`CAPA`:** `#ADF` `LDF `, `EJCT`,
  `RSMS LIST 300 600`; `#CMX`; `#GMT`; `#LAM ON/OFF`.
- **ffscan has not moved**: upstream `HEAD` is still `a041a3f`. Nothing in it reads counters, consumables or
  timers; its scanner endpoint reports model, serial and firmware from `INFO` only (`app.py:767-781`).

**Verified in sources only (not on this scanner)**

- Epson's own Linux driver source (epsonscan2, LGPL 2.1; facts taken, no code) has a third ESC/I-2 mode beside
  the one this package uses. `1C 58` (FS X) enters *control* mode; `1C 59` (FS Y) *inquiry*; `1C 5A` (FS Z)
  **maintenance**. In maintenance mode the same `INFO`, `CAPA`, `STAT` and `RESA` commands return counters,
  consumable limits and timers (token tables in phase 11). The driver reads a 64-byte header and then the body,
  the same shape as `ScannerSession.exchange`.
- SANE's `epsonds` backend (GPL; facts only) never enters maintenance mode and reads no counters. Its `STAT`
  handler knows `#ERR` `ADF PE` and `ADF OPN` only.
- A public FF-680W project ([welbow/epsonscan2-docker](https://github.com/welbow/epsonscan2-docker)) reports the
  scan button as 8-byte packets on USB interrupt endpoint `0x83`, and a 10-minute default sleep timer.

**Guesswork**

- Which SNMP counter column is which (jams, double feeds, single-sided against duplex). Only the roller kit
  life and count are pinned down, by Epson's published 200,000.
- That `120` is the power-off timer in minutes and `10` the sleep timer in minutes.
- Whether SNMP answers while the scanner sleeps, wakes it, or keeps answering during a scan.
- Whether this firmware accepts maintenance mode at all, over Wi-Fi or USB, and which of the tokens it returns.
- `STAT` beyond "feeder empty": the CLI prints a summary, not the tokens, so no other live `STAT` token was seen.
- Cleaning reminders, glass-dirt warnings and jam counts were not found in SNMP under any label.

## Device information: where each item lives

Confidence: **high** = seen on the scanner and cross-checked; **medium** = seen but the meaning is inferred, or
documented in Epson's source but not tried; **low** = a candidate only.

| Item | Where | Confidence | Evidence | Open question |
|---|---|---|---|---|
| Firmware version | `INFO` `#PRV` (already parsed), `#VER`; SNMP firmware table | High | Both read live and agree | None. `#VER` is the feeder unit's version (`ADF …`) |
| Network firmware, package | SNMP firmware table only | High | Labelled by the scanner | Not available over USB |
| Scans on the roller kit | SNMP consumable row, column 7; ESC/I-2 maintenance `RESA` `#ADF RKIT` | High (SNMP), medium (ESC/I-2) | 1331 against life 200000 | Does it count sheets or sides? One duplex scan, then re-read (11.4) |
| Roller kit life | SNMP consumable row, column 6; maintenance `INFO` `#ADF RKIT` (limit) and `rkit` (near end) | High (SNMP) | 200000 = Epson's published life | Columns 4 (`3`) and 5 (`5`) unknown: state? near-end percentage? |
| Pickup roller, separation pad, retard roller separately | Maintenance `INFO`/`RESA` `#ADF PURL`, `SPAD`, `RTRL` | Low for this model | Tokens exist in Epson's source; the scanner's SNMP table has one row, the kit | Probably not reported by the FF-680W: the kit is one part (B12B819031) |
| Total scans (lifetime) | SNMP counter row columns 4, 7, 8; maintenance `RESA` `#ADF SCNT` (single-sided) and `DCNT` (duplex) | Medium | Three columns read 1331, equal to the kit count on a scanner whose kit was never changed | Which column survives a roller reset |
| Replacement due | Derived: count ≥ life; near-end from `rkit` if the scanner gives one | Medium | Arithmetic on the two values above | Whether the scanner raises its own flag (`#WRN`?) |
| Cleaning reminder | Maintenance `RESA` `#ADF CLN ` (count since cleaning), `THCL` (threshold), `CLNF` (on/off); `STAT` `#WRN CLN ` | Medium, source only | Epson's source | Does the FF-680W support it? Not in normal `CAPA`. SNMP candidate: none |
| Glass dirt | `STAT` `#GLS DIRT`; sensitivity in maintenance `RESA` `#GLS` (`OFF`/`LOW`/`NORM`) | Medium, source only | Epson's source | Same |
| Jam and double-feed counts | Maintenance `RESA` `#ADF JAM `, `DFUS` (ultrasonic), `DFLN` (length), `DFSW`, `PPRT`; SNMP counter columns 6, 10, 11 | Low | Tokens in source; three unlabelled SNMP numbers | Labels (11.4) |
| Error or jam *history* (a log with times) | Nowhere found | — | Not in SNMP; no such token in Epson's source | Possibly only in Web Config, which is closed |
| Current error | `STAT` `#ERR` (parsed for `PE`, `PJ`); also `OPN`, `DFED`, `ERR ` and others; `#ERC` error code | High for `PE`; medium for the rest | Source lists; `PE` seen live | Capture each on hardware (12.1) |
| Wi-Fi and network | SNMP MIB-2 and `1248.1.1.3.1` | High that it is there; medium for field meanings | Read live | Signal strength not identified. Not available over USB |
| Sleep timer | SNMP `1248.1.2.2.3.1.1.9.1`; maintenance `RESA` `#SAV` | Low (SNMP), medium (ESC/I-2) | `10`, and a public report of a 10-minute default | Change it in Epson Scan 2 Utility, re-read (11.4) |
| Power-off timer | SNMP `1248.1.2.2.3.3.1.3.1`, choices in `…3.6.1.2.1.n`; maintenance `RESA` `#POF`, `#PO2`, `#PNC` (power off when not connected) | Medium | `120` is in the list of choices, which matches Epson's menu | Same |
| Scanner clock | SNMP DateAndTime; maintenance `RESA` `#D&T` | High (SNMP) | Matched UTC | None |
| Uptime | SNMP `sysUpTime` | High | Read live | Resets on wake from sleep? |
| Who holds the scanner | "IS" hello (already parsed) | High | ROADMAP 1.1 | Unchanged |
| Last client's host name | SNMP `1248.1.4.2.21` | High | Read live | Personal data: do not surface (11.2) |
| Battery | `STAT` `#BAT` | — | No battery in this model | Ignore |

**Sources ruled out.** Web Config (closed behind a mandatory password change, then a login: the library should
neither set a password nor scrape pages); eSCL/AirScan and IPP (not offered); the Printer MIB (absent). Epson Scan 2
Utility reads its Counter tab through the driver's maintenance mode, by the look of the source; that is 11.5.

**Two routes, then.** SNMP is the first one to build: verified, read-only by construction, needs no lock, and
cannot hang the scanner. It only works over Wi-Fi, and most of its columns need labelling. ESC/I-2 maintenance
mode is the labelled route and the only one over USB, but every step of it is a new command on a scanner that
locks up when a reply length is wrong, so it is designed here and run later with the owner present.

## API sketch

One value type that either route fills in, every field optional, so an app's health screen shows what it got.

```swift
// PhastPhotoProtocol (pure, no I/O)
public struct ScannerHealth: Sendable, Hashable {
    public var firmware: Firmware?                 // main, network, package
    public var totalScans: Int?
    public var consumables: [Consumable]           // FF-680W: one, the roller assembly kit
    public var cleaning: Cleaning?                 // count, threshold, reminderOn, isDue
    public var feedFaults: FeedFaults?             // jams, doubleFeeds
    public var power: PowerTimers?                 // sleepMinutes, powerOffMinutes, powerOffChoices
    public var clock: Date?
    public var uptime: Duration?
    public var network: NetworkDetails?            // personal: see 11.2
    public var source: Source                      // .snmp, .maintenanceMode
    public var unlabelled: [String: Int]           // raw values not yet understood, keyed by OID or token
}
public struct Consumable: Sendable, Hashable {
    public enum Kind: Sendable { case rollerKit, pickupRoller, separationPad, retardRoller }
    public var kind: Kind; public var name: String?
    public var used: Int; public var life: Int?; public var nearEnd: Int?
    public var remainingFraction: Double? { get }   // pure
    public var state: State { get }                 // .ok, .nearEnd, .due: pure, from the scanner's own limits
}

// PhastPhotoScanner
public struct ScannerHealthReader: Sendable {      // SNMP route; no session, no lock
    public init(host: String, community: String = "public", timeout: Duration = .seconds(2))
    public func read() async throws -> ScannerHealth
}
extension ScannerSession {                         // ESC/I-2 route (11.5), also over USB
    public func maintenanceReport() async throws -> ScannerHealth
}
```

- **Modules.** BER coding, OID constants and both parsers (SNMP variable bindings → `ScannerHealth`; ESC/I-2
  fields → `ScannerHealth`) go in `PhastPhotoProtocol`. The UDP client and `ScannerHealthReader` go in
  `PhastPhotoScanner`, behind a small `SNMPExchanging` protocol so tests can fake it. Mode switching goes in
  `ScannerSession`; nothing changes in the transports.
- **Lock and one-exchange rule.** The SNMP reader uses its own UDP socket and never touches the session or the
  lock, so it may run while a session is open. It must not run during a scan until 11.4 shows that is harmless;
  until then `ScannerWatch` and apps call it between stacks. `maintenanceReport()` throws `sessionBusy` during a
  scan and holds the session's wire gate for the *whole* sequence (leave control mode, enter maintenance, read,
  leave, re-enter control), not per exchange, so no `status()` can land while the scanner is in the wrong mode.
- **Read-only.** No reset or setter in this plan's first version (see 11.6).
- **iOS and macOS.** SNMP is plain unicast UDP through Network.framework on both; iOS needs only the local
  network permission the package already requires. Force IPv4, as for the session. Over USB (Mac, M-series iPad)
  there is no SNMP: `ScannerConnection` gives the app a route, and the app calls `ScannerHealthReader` for
  Wi-Fi or `maintenanceReport()` for USB. An iPhone is Wi-Fi only, so SNMP only.
- **Privacy.** Serial number, MAC address, network name, access point address and the last client's host name are
  personal. `ScannerHealth` leaves the last client's host name out entirely, and `NetworkDetails` gets a
  `displayFields(showIdentifiers:)` that redacts by default, like `ScannerInfo.displayFields`.

## Phase 10: finish the hardware and device checks (ROADMAP 1.1, 1.2, 2.6, 5.3, 7.2, 7.5)

No new code is planned here; each session may produce small fixes. ROADMAP lists the items.

**10.1 Wi-Fi checklist, second session [HW].**
- Goal: the open items of ROADMAP 1.1: 600 dpi duplex, a stack of 30 or more, cover open, hard cancel mid-page,
  graceful stop, a second client after close, the busy hello while Epson Scan 2 holds the scanner, lock expiry
  (300 s), a sleeping scanner, raw JPEG metadata, `--no-hardware-crop`.
- Files: none planned; findings go into ROADMAP 1.1 and PROTOCOL.md's local notes.
- Risk: a hard cancel may jam or lock the scanner; do it last.
- Open question from 1.1: does a hardware-cropped print that comes through tilted need software straightening?
  If so that is a new Imaging packet (rotate only, no crop), to be specified from the corpus.

**10.2 Raw corpus [HW].** ROADMAP 1.2 as written. Add: one stack scanned with and without hardware crop, so 2.6
has backing to crop.

**10.3 Crop, ink and duplicates on the corpus [HW data].** ROADMAP 2.6 and 5.3. Change no constant without a
before-and-after table from the corpus.

**10.4 Vision on real prints [Device].** ROADMAP 3.2, 3.5, 4.2, 4.3, 6.2: more handwriting and pencil backs, the
roll sign checked by eye, the scene margin on each supported OS, red-eye on real flash photos. Run on an iPhone
or iPad as well as the Mac (the simulator's Vision is fake).

**10.5 USB from a Mac [HW].** ROADMAP 7.2: first run of `USBTransport` on IOUSBHost; reset after an interrupted
session. *Started 29 Nov 2026:* CLI `--usb`; `INFO`, `STATUS` and `CAPA` work once the interface match includes
`bConfigurationValue` (without it nothing matched and the old code called the interface "in use"). No Epson
driver held the interface. Still to do: single-sided and duplex scans, 600 dpi, a stack, a reset.
*Open question:* after 11.5 minutes idle with USB plugged in (sleep timer 10 minutes), the scanner had left the USB
bus (no `idVendor` 1208 in `ioreg`) and answered neither ping, SNMP nor a Wi-Fi `status`, although Bonjour still
listed it (cached). Earlier, asleep on Wi-Fi alone, it kept answering SNMP. Either it sleeps deeper with USB
attached, dropping off USB and Wi-Fi, or it was switched off; check the power light, wake it with the button, and
repeat. If sleep drops it from USB, a USB app must expect the device to vanish and come back on wake, or keep the
scanner awake (sleep timer up to its maximum).

**10.6 USB on iPad, the rest [HW].** ROADMAP 7.5: 600 dpi, a stack, timeouts, reset, unplugging mid-scan.

**10.7 First run on an iPhone [Device][HW].** Harness app over Wi-Fi: permission prompt, refusal, time and peak
memory per print at 300 and 600 dpi.

## Phase 11: scanner health

**11.1 SNMP wire format** (pure).
- Goal: encode SNMP v1 `GetRequest` and `GetNextRequest`, decode `GetResponse`. No dependency, about 250 lines.
- Files: `Sources/PhastPhotoProtocol/SNMP.swift` (`SNMPOID`, `SNMPValue`, `SNMPMessage`).
- References: RFC 1157 (SNMP v1), X.690 (BER). Nothing from net-snmp.
- Constants to keep: version `0` (v1); community `public`; types INTEGER `0x02`, OCTET STRING `0x04`, NULL
  `0x05`, OID `0x06`, IpAddress `0x40`, Counter32 `0x41`, Gauge32 `0x42`, TimeTicks `0x43`; PDU tags `0xA0`,
  `0xA1`, `0xA2`; error status `2` = noSuchName.
- Tests (Swift Testing, hand-built byte vectors): a request for `1.3.6.1.2.1.1.1.0` matches known bytes;
  sub-identifier 1248 encodes as `89 60`; lengths over 127 bytes (long form); negative INTEGER (`-1` was seen
  live); Counter32 above 2³¹; a truncated datagram throws; a reply with another request ID is rejected;
  noSuchName maps to "absent", not an error. Break each decoder branch once.
- Risk: none on hardware.

**11.2 Health parser for SNMP** (pure).
- Goal: variable bindings → `ScannerHealth`; the `Consumable` and `Cleaning` state functions.
- Files: `Sources/PhastPhotoProtocol/ScannerHealth.swift`, `EpsonMIB.swift` (OID constants with a comment on how
  each was established).
- References: this plan's table; Epson's published 200,000-scan kit life.
- Constants to keep: the OIDs in "What was verified"; firmware rows matched by the scanner's label text
  (`Main FW`, `Network FW`, `FW Package`), not by row number; consumable matched by name prefix `Roller Ass`
  (the firmware misspells it); DateAndTime is 11 bytes, year big-endian.
- Rule: a value whose meaning is not confirmed goes to `unlabelled`, never into a named field. After 11.4, move
  them.
- Tests: a synthetic walk shaped like the real one (identifiers replaced as in the note at the top) gives
  firmware, kit 1331 of 200000, power-off 120 with seven choices, the clock; a walk with no enterprise tree
  gives an empty report, not an error; `state` at 0, at near-end, at life, past life, and with no life.
- Open question: sides or sheets (11.4).

**11.3 SNMP client and reader.**
- Goal: `ScannerHealthReader.read()` over UDP; CLI `phastphoto health` (identifiers hidden unless
  `--show-identifiers`) and `phastphoto status --raw` (prints the `STAT` tokens the existing command already
  receives; no new command on the wire).
- Files: `Sources/PhastPhotoScanner/SNMPClient.swift`, `ScannerHealthReader.swift`; `Sources/phastphoto/main.swift`;
  README section "Scanner health".
- Constants: UDP 161; IPv4 forced; 2 s timeout, one retry; at most 10 OIDs per request (keeps replies under one
  datagram); `GetNext` walk capped at 400 values per subtree.
- Tests: a loopback UDP responder in the test target, like `ISTestServer`: answers, a dropped first datagram
  (retry), silence (`timedOut`), a wrong request ID, a short datagram (throws). A switched-off device puts a UDP `NWConnection` into `.waiting` at once: map it to "unreachable".
- **[HW]** read-only run on Mac and on an iPhone or iPad.
- Risks: an owner may have turned SNMP off or changed the community in Web Config: report "not available",
  never guess. SNMP v1 is unauthenticated and the scanner offers nothing better without Web Config; the reader
  sends only Get and GetNext, and no `SetRequest` encoder is written.

**11.4 Label the SNMP values [HW].** With the owner present; Epson Scan 2 Utility on a Mac or PC beside it.
- Goal: turn guesses into constants. Method: read, change one thing, read again, diff.
  1. Compare every counter with Epson Scan 2 Utility's Counter tab.
  2. One single-sided sheet; one duplex sheet: which columns move, and by one or two.
  3. A deliberate double feed, and a jam cleared by opening the cover: which of columns 6, 10, 11 move.
  4. Change the sleep timer and the power-off timer in the Utility: confirm the two OIDs and the unit.
  5. Read during a scan, and 30 minutes after the last use (asleep): does it answer, does it wake the scanner?
  6. If the Utility offers a regular-cleaning alert on this model: switch it on, look for the new value.
- Files: `EpsonMIB.swift`, the table above, ROADMAP status.
- Tests: each confirmed label gets a line in 11.2's synthetic walk.
- Do **not** reset the roller counter as an experiment: it cannot be put back to 1331 by anything in this plan.
- **Results (29 Nov 2026), now in `ScannerHealth.counts` and `.power`:**
  1. The Utility's Counter tab matched by value: ADF = columns 4, 7, 8; double-sided = 5; single-sided = 10;
     paper jam = 6; double feed = 11. It also shows carrier sheet (0) and the roller kit; scanner glass, passport
     sheet, card slot and paper protection say "No Information".
  2. A single-sided sheet moved 4, 7, 8, 10 and the kit by one; a duplex sheet moved 4, 7, 8, 5 and the kit by one:
     **counts are sheets, not sides.**
  3. A folded A4 sheet fed as one tripped double-feed detection (`#err ADF DFED`): column 11 +1, column 10 and the
     kit +1 (a stopped sheet still counts), column 6 unchanged. No jam was caused, so column 6 is labelled by value.
  4. Sleep 10 → 15 moved `…3.1.1.9.1`; power-off Off → 30 moved `…3.5.1.4.1` from 0 to 30. Both minutes.
     `…3.3.1.3.1` (120) did not move and stays unlabelled.
  5. SNMP answered every read during a duplex scan (11 reads, within 0.11 s) and the scan finished normally.
     After 11.5 minutes idle (past the 10-minute sleep timer) three reads answered in 0.1–0.2 s, and the scanner
     stayed asleep (its owner watched): reading health doesn't wake it. `sysUpTime`
     restarted during the session, around when the Utility set the timers: it is not time since power-on.
  6. The Utility has no cleaning alert on this model. Its "Detect Glass Dirt" setting is not in SNMP (a full walk
     with it on and off differed only in the clock).

**11.5 ESC/I-2 maintenance mode.** Needed for USB, and for cleaning and jam counts if SNMP never yields them.
- Goal: `ScannerSession.maintenanceReport()`.
- References (facts from epsonscan2's `ESCI2Defs.h`, `ESCI2Command.cpp`, `ESCI2Accessor.cpp`; LGPL, no code
  copied): on opening a scanner Epson's driver sends FS Y, `INFO`, `EXI `, `CAPA`, `FIN `, then FS Z, `INFO`,
  `CAPA`, `RESA` with no parameter block (which returns everything), `FIN `. It always leaves one mode with
  `FIN ` before entering another, and waits an interface-dependent time after `FIN ` (0 ms over USB in the Linux
  source; the network value is not in it).
- Tokens to parse:
  - maintenance `INFO`: `#ADF` with `LIFE`, `RKIT`/`rkit`, `PURL`/`purl`, `SPAD`/`spad`, `RTRL`/`rtrl` (upper
    case = life limit, lower case = near end); `#psv`; `#PRD`, `#S/N`, `#VER`;
  - maintenance `RESA`: `#ADF` with `SCNT`, `DCNT`, `SCRD`, `DCRD`, `JAM `, `DFUS`, `DFLN`, `DFSW`, `PPRT`,
    `RKIT`, `PURL`, `SPAD`, `RTRL`, `CLN `, `THCL`, `CLNF`; `#SAV`, `#POF`, `#PO2`, `#D&T`, `#GLS`, `#DPO`, `#PNC`;
  - maintenance `STAT`: `#ERR`, `#GLS` (`DIRT`), `#WRN` (`CLN `).
- Files: `ESCI2.swift` (`ESCI2.enterMaintenanceMode` = `1C 5A`, `ESCI2Command.results` = `RESA`),
  `MaintenanceReport.swift` in Protocol; `ScannerSession.swift` (a `mode`, one gated sequence, recovery: on any
  error send `FIN `, re-enter control mode, and if that fails mark the session closed).
- Simulator first: `SimulatedScanner` gets modes (`FS X`/`FS Z` acknowledged only from no mode, so a missing
  `FIN ` fails the test), per-mode `INFO`/`CAPA`/`STAT`/`RESA` bodies, `INVD` for `PARA`/`TRDT`/`IMG ` outside
  control mode, and a `wrongMode` violation. `wouldHang` stays as it is.
- Tests: the wire log is exactly `FIN , FS Z, INFO, CAPA, RESA, FIN , FS X`; `status()` issued meanwhile waits
  and then runs in control mode; `sessionBusy` during a scan; a failure after FS Z still ends `FIN , FS X`; the
  parser on synthetic replies, including a reply with only `RKIT` (what the FF-680W probably sends) and one with
  unknown tokens kept in `unlabelled`.
- **[HW]**, owner present, **USB first** (no lock, and a USB reset recovers a stuck scanner; over Wi-Fi the
  scanner must be power-cycled). One new thing per step, each with reply length 64, stopping at the first
  surprise:
  1. `FIN `, then `1C 5A` with reply length 1: is the answer `06`?
  2. `INFO` in maintenance mode: header, then body by empty requests.
  3. `CAPA`, then `RESA` with no parameter block.
  4. `FIN `, `1C 58`, then an ordinary `STAT` to prove the session still works. Then a normal scan.
  5. Only then the same over Wi-Fi.
- Risks and open questions: the firmware may refuse FS Z (expect `15` NAK or silence: use a short timeout and
  treat it as "not supported"); the wait after `FIN ` over the network is unknown (start at 500 ms); whether
  counters agree with SNMP's; whether inquiry mode (FS Y) would let `STAT` run without the lock is a separate
  question, not needed here.

**11.6 Writes: reset the roller counter, set the timers.** *Not planned; needs a decision.* Epson's source sets
these with `PARA` in maintenance mode, and has an administrator lock (`#als`) with a password hash. A library
that can zero a counter by mistake is a liability; if an app needs "I replaced the rollers", specify it after
11.5 works, with a typed, single-purpose call and its own **[HW]** session.

## Phase 12: protocol gaps (not in ffscan)

**12.1 Status in full.**
- Goal: `ScannerStatus` names every condition an FF-680W can report, with friendly text; mid-scan `#err`
  (`ScannerError.scanFailed`) gets the same decoding; CLI `status --raw` prints the `STAT` tokens (from 11.3).
- Files: `ScannerReports.swift`, `StatusMessages.swift`.
- References: error words from epsonscan2's `ESCI2Defs.h`: `OPN ` cover open, `PJ  ` jam, `PE  ` empty, `DFED`
  double feed, `ERR ` fatal, `DTCL` tray closed, `PPRT` paper protection, `PSKW` skew; `STAT` tokens `#GLS`
  (`DIRT`), `#WRN` (`CLN `), `#ERC` (error code), `#PB ` (button). SANE's `epsonds` treats `ADF OPN` as cover open.
- Tests: one case per word, on synthetic `STAT` bodies; unknown words still fall through to "Scanner reports: …".
- **[HW]**: `status --raw` with the cover open, a jam, a double feed. No new command.

**12.2 The rest of `INFO`.** Accessors for `#VER`, `#DSZ`, `#IMX`, `#DFM`, `#ADF` area, minimum and maximum
(1/100 in), feed order (`FORD PF1N` = first sheet first; ROADMAP 1.1 saw the bottom of the stack feed first).
`ScanSettings.validate()` should use `#IMX` instead of the constant 65535 when an `INFO` is at hand. Tests: the
real reply, serial replaced. Half a day.

**12.3 Scan options the scanner lists but the package does not send** [HW]. `#LAM` (laminated prints) and `LDF `
(length-based double-feed detection) from `CAPA`. Each is a new `PARA` token: simulator test first, then one
scan each with the owner present. `EJCT`, `#CMX` and `#GMT` are not worth a packet. Low priority.

**12.4 `EXI ` extended information** [HW]. `INFO` carries `#EXI`, and Epson's driver sends an `EXI ` command and
parses the body as JSON. Unknown contents; one read-only command, same 64-byte header rule. Try it in 11.5's
USB session; write a parser only if it holds something 11.x lacks.

## Phase 13: later (ROADMAP "Later")

**13.1 Scan button over USB** [HW]. New evidence makes this tractable: a public project reports 8-byte packets
on interrupt endpoint `0x83`, `01 01 00 00 00 00 00 00` for Start and `02 00 …` for Stop, and that the first press
after sleep only wakes the scanner. Files: `USBTransport.swift` (an `AsyncStream` of button events from the
interrupt pipe on macOS), a new selector in `PhastPhotoUSBProtocol.h` and the driver for iPadOS, `ScannerWatch`
(start on Start). Tests: fake pipes. Over Wi-Fi the button's route is unknown (`#PB ` in `STAT`, or Epson's
Event Manager channel): capture `status --raw` while pressing it before designing anything.

**13.2 TLS network path.** Still not understood and nothing needs it while port 1865 answers. Leave.

## Phase 14: release

**14.1 0.3.0.** After 11.1–11.3: README "Scanner health", PROTOCOL.md local note on SNMP and the three modes,
ROADMAP status rows for phases 10–12, CI unchanged (all new tests run without a scanner).

**14.2 DriverKit distribution.** ROADMAP 7.5: request Apple's DriverKit USB transport entitlement for vendor ID
`0x04B8`. Paperwork, started early because the wait is Apple's.

## Recommended order

| # | Packet | Priority | Effort | Needs |
|---|---|---|---|---|
| 1 | 11.1 SNMP wire format | High | Done (0.3.0) | — |
| 2 | 11.2 Health parser | High | Done (0.3.0) | — |
| 3 | 11.3 Client, reader, `health` | High | Done (0.3.0); `status --raw` moved to 12.1 | [HW] read-only: done |
| 4 | 10.1 Wi-Fi checklist + 12.1 captures (11.4 labelling: done) | High | 1 day at the scanner | [HW], owner |
| 5 | 12.1 Status in full | High | 0.5 day | captures from 4 |
| 6 | 10.2, 10.3 Corpus; crop, ink, duplicates | High | 2–3 days | [HW data] |
| 7 | 10.4, 10.7 Vision on real prints; iPhone run | Medium | 1–2 days | [Device] |
| 8 | 14.1 Release 0.3.0 | Medium | Done (after 1–3) | — |
| 9 | 11.5 Maintenance mode (simulator, then USB, then Wi-Fi) | Medium | 2 days + 1 session | [HW], owner; 10.5 or 10.6 first |
| 10 | 10.5, 10.6 USB from a Mac; iPad rest | Medium | 1 day | [HW] |
| 11 | 12.2 Rest of `INFO` | Low | 0.5 day | — |
| 12 | 13.1 Scan button over USB | Low | 2 days | [HW] |
| 13 | 12.3, 12.4 `LAM`, `LDF`, `EXI ` | Low | 1 day | [HW], owner |
| 14 | 14.2 DriverKit entitlement | Low, start early | paperwork | — |
| — | 11.6 Writes; 13.2 TLS | Not planned | — | decision |

Items 1–3 need no scanner beyond a final read-only check, and give an app firmware, kit wear, total scans,
timers, clock and network details over Wi-Fi. Item 4 packs every "owner present" Wi-Fi experiment into one visit.

## Out of scope

UI, cloud upload, AI captions, storage and the rest of ROADMAP's "Out of scope" list stay app concerns. Added
here: Web Config scraping or password setup, firmware updates, and changing network settings.
