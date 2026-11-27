# PhastPhoto USB driver (iPadOS)

A DriverKit driver extension that lets an iPad app use the FF-680W over USB. iPadOS has no USB API for apps:
the app ships this driver, the user turns it on in Settings, and `USBTransport` talks to it.

> **Status: works on one iPad.** On an iPad Pro 12.9-inch (5th generation, M1) with iPadOS 27.2.1, the driver
> loaded for the FF-680W, the test app (`TestHost`) found it, and `INFO`, `STATUS`, a single-sided scan and a
> duplex scan (300 dpi) ran over USB (27 November 2026). Not yet tried: 600 dpi, a stack of prints, timeouts, a
> reset, or unplugging mid-scan. See "Checked on an iPad" below.

## Where it works

- **iPads with an M-series chip** (iPad Pro M1 and later, iPad Air M1 and later), iPadOS 16 or later.
- **Not iPhone**, including USB-C iPhones: Apple doesn't support DriverKit on iPhone. Use Wi-Fi.
- **Not iPads with an A-series chip** (for example iPad Air 3rd generation): DriverKit needs an M-series chip.
- macOS doesn't need it: `USBTransport` uses IOUSBHost there.

## What it does

`PhastPhotoUSBDriver` matches interface 0 of the scanner (VID `0x04B8` = 1208, PID `0x016B` = 363), opens it,
and takes the bulk pipes `0x01` (out) and `0x82` (in). `PhastPhotoUSBUserClient` is the app's connection, with
three calls defined in `Sources/CPhastPhotoDriverKit/include/PhastPhotoUSBProtocol.h`:

| Selector | In | Out |
|---|---|---|
| write | timeout (ms); the bytes | |
| read | max length, timeout (ms) | byte count; the bytes |
| reset | | (the driver is torn down and started again) |

Transfers are at most 1 MiB, the block size the session asks the scanner for. One app connection at a time:
a second app gets "in use". When an app closes its connection, or quits, mid-transfer, the driver aborts that
transfer, and it accepts a new connection only once the transfer has finished.
All ESC/I-2 logic stays in the Swift package: the driver only moves bytes.

## Adding it to an app

1. **Add a DriverKit target.** In Xcode: File > New > Target > DriverKit Driver. Replace its sources with
   `PhastPhotoUSBDriver/*.iig`, `*.cpp`, `Info.plist` and `PhastPhotoUSBDriver.entitlements` from this folder. Set:
   - **Header Search Paths:** the package's `Sources/CPhastPhotoDriverKit/include`;
   - **Other Linker Flags:** `-framework USBDriverKit`;
   - **DriverKit Deployment Target:** 22.0, which is iPadOS 16.

   `project.yml` here (XcodeGen) has the same settings and builds the driver on its own:

   ```bash
   xcodegen generate --spec Drivers/PhastPhotoUSBDriver/project.yml
   xcodebuild -project Drivers/PhastPhotoUSBDriver/PhastPhotoUSBDriver.xcodeproj -target PhastPhotoUSBDriver -sdk driverkit build CODE_SIGNING_ALLOWED=NO
   ```
2. **Embed it in the app.** Make the app target depend on the driver target and add it to the app's
   System Extensions embed phase. On iPadOS it ends up in `YourApp.app/SystemExtensions/`.
3. **Bundle identifier.** Give the driver an identifier under the app's, for example
   `com.yourcompany.YourApp.USBDriver`, and pass it to the transport so the app matches only its own driver:

   ```swift
   let transport = USBTransport(driverBundleID: "com.yourcompany.YourApp.USBDriver")
   ```
4. **Entitlements.**
   - **Driver:** `com.apple.developer.driverkit`, and `com.apple.developer.driverkit.transport.usb` with `idVendor`
     1208, both already in `PhastPhotoUSBDriver.entitlements`.
   - **App:** `com.apple.developer.driverkit.communicates-with-drivers`. The app and the driver must be signed by
     the same team.
5. **Settings bundle.** Add one to the app (it can be empty). iPadOS shows the app's Drivers switch under
   Settings > *App name* only when the app has a Settings bundle.
6. **Tell the user** to turn the driver on: Settings > General > Drivers (or Settings > *App name* > Drivers).
   Until then the driver doesn't run, and `USBTransport.isScannerPresent()` is false, exactly as if the scanner
   were unplugged. The error message names both causes.

**Build number.** Keep the driver's `CFBundleVersion` a plain version (`1`, `1.0.0`). Xcode's App Store export
can rewrite build numbers, and a driver with a build number like `3433099.287482533` doesn't load. Set
`manageAppVersionAndBuildNumber` to `false` in the export options.

**Signing.** Development signing with a team works on a registered iPad: development profiles include the
DriverKit entitlements. "Sign to Run Locally" does not work for drivers. Distribution (TestFlight, App Store) needs
Apple's DriverKit USB Transport grant for vendor ID `0x04B8`. That vendor ID is Epson's, so expect Apple to ask
for Epson's authorisation.

## Checked on an iPad

iPad Pro 12.9-inch (5th generation, M1), iPadOS 27.2.1, development-signed, scanner on the iPad's USB-C port.

**Worked:**
- **Loading.** The personality (`IOClass` `IOUserService` on `IOUSBHostInterface`, matching `idVendor`,
  `idProduct`, `bConfigurationValue` 1 and `bInterfaceNumber` 0) loaded, and no system driver held interface 0.
- **Finding it.** `client.c` finds the service by `IOUserClass` plus `IOUserServerName`.
- **Commands.** `INFO` and `STATUS`: the whole session took 37 ms.
- **Scanning.**
  - Single-sided, 300 dpi: one side, 2.7 MB, 90 blocks of up to 99 KiB, 5.9 MB/s while data moved, 4.9 s for
    the side.
  - Duplex, 300 dpi: side A then side B, 5.5–6.6 MB/s, 6.8 s for both. The scanner accepted `#BSZ`.
  - Over Wi-Fi the same scan moved 1.0–1.2 MB/s in blocks of up to 256 KiB, so USB was about five times faster
    while transferring.
- **Updates.** Raising `CFBundleVersion` and reinstalling the app replaced the running driver within seconds.

**What it took (both bugs crashed the driver with SIGBUS; the app saw `0xFFFFFECC`, `MIG_SERVER_DIED`):**
- **Write buffer.** A transfer buffer from `CreateIOBuffer(kIOMemoryDirectionOut)` is mapped read-only into the
  driver, so copying a command into it crashed. It is now `kIOMemoryDirectionInOut`.
- **Large reads.** For reads over 4096 bytes, the app's buffer arrives as a memory descriptor, and the driver's
  mapping of it is read-only, even through a `kIOMemoryDirectionIn` sub-descriptor. Copying scan data into it
  crashed. The driver now passes that descriptor straight to `IOUSBHostPipe::IO`, so the controller writes into
  the app's memory.
- **Stuck scanner.** A crash mid-page left the scanner stuck (power light flashing) until it was switched off
  and on. The next session's first read then got `kIOReturnOverrun`. The transport now resets and retries on an
  overrun on the first transfer, as it does on a timeout.
- **Crash reports.** `PhastPhotoUSBDriver-<date>.ips` in
  `xcrun devicectl device info files --domain-type systemCrashLogs`.

**Not yet tried:** 600 dpi scans, a stack of prints, which status a transfer timeout returns
(`kIOReturnTimeout` and `kIOUSBTransactionTimeout` are both treated as one), a USB reset (the app should
reconnect within 10 s), unplugging mid-scan, and whether a 60 s blocking transfer upsets DriverKit.

**The scanner, not USB:** every scan of this scanner so far came back 36 inches long (2550 × 10800 px, the
`#ACQ` maximum), one print followed by backing, although `PEDT` (stop at the end of the paper) is set. This
happened over USB and over Wi-Fi, and also with ffscan's own Python code, which got `#pen` 2550 × 10800 too.
So it is how this scanner (firmware 18.60.SP14P2) handles these settings, not this driver or the library.
Roadmap 1.1 tracks it.

## Test app

`TestHost` is a minimal iPad app that embeds the driver. Its buttons check whether the driver is running, run
`INFO` and `STATUS`, and scan one stack single-sided. It logs to the screen, to `Documents/usb-log.txt`, and to
the unified log at notice level. Pass `--autorun presence|info|scan` to run a check at launch.

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored) and set a **paid** team and a
   bundle ID prefix. A free Personal Team can't sign DriverKit.
2. Run `xcodegen generate --spec Drivers/PhastPhotoUSBDriver/project.yml`. Open the project in Xcode once, choose
   the `PhastPhotoUSBHost` scheme and your iPad, and build (⌘B). Command-line `xcodebuild` can't create the
   DriverKit profiles ("No Account for Team"); after one build in Xcode, it can reuse them.
3. Install and run it:

   ```bash
   xcrun devicectl device install app --device <udid> "<DerivedData>/Build/Products/Debug-iphoneos/PhastPhoto USB.app"
   ```

   ```bash
   xcrun devicectl device process launch --device <udid> --terminate-existing <prefix>.USBHost -- --autorun info
   ```

   ```bash
   xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier <prefix>.USBHost --source Documents/usb-log.txt --destination usb-log.txt
   ```
4. Turn the driver on (Settings > General > Drivers) and connect the scanner.
