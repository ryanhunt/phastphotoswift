// The contract between the PhastPhoto USB driver extension (Drivers/PhastPhotoUSBDriver) and the app-side
// client (this target). Plain C so both the DriverKit C++ sources and the client include the same file.

#ifndef PhastPhotoUSBProtocol_h
#define PhastPhotoUSBProtocol_h

/// The driver's C++ class (IOUserClass in its personality); the client finds the service by it.
#define PPUSB_DRIVER_CLASS "PhastPhotoUSBDriver"

/// Largest single transfer: the scanner is told #BSZ 1 MiB.
#define PPUSB_MAX_TRANSFER (1u << 20)

/// ExternalMethod selectors.
enum {
    /// scalar in: [timeoutMs]; struct in: the bytes (one bulk OUT transfer on endpoint 0x01).
    kPPUSBSelectorWrite = 0,
    /// scalar in: [maxLength, timeoutMs]; scalar out: [bytes received]; struct out: the bytes (one bulk IN
    /// transfer on endpoint 0x82). The count is always taken from the scalar: above 4096 bytes the struct
    /// is the caller's buffer, mapped into the driver, and its size is not updated.
    kPPUSBSelectorRead = 1,
    /// Resets the device (like replugging the cable). The driver instance is torn down and matched again,
    /// so the client must close its connection and open a new one.
    kPPUSBSelectorReset = 2,
};

#endif
