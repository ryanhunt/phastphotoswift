// App-side client for the PhastPhoto USB driver extension: finds the driver's service in the I/O Registry
// and calls its user client. The iOS SDK has IOKit's C headers but no Swift module, so this thin C layer
// stands between Swift and IOKitLib. It builds on macOS too (where it can talk to the same driver).

#ifndef CPhastPhotoDriverKit_h
#define CPhastPhotoDriverKit_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "PhastPhotoUSBProtocol.h"

#ifdef __cplusplus
extern "C" {
#endif

/// IOKit's kern_return_t, without pulling IOKit into Swift.
typedef int32_t ppusb_return_t;
/// io_connect_t; 0 = none.
typedef uint32_t ppusb_connection_t;

/// Whether the driver's service is registered (the driver is enabled and the scanner is attached).
/// `serverName` (the driver's bundle identifier, IOUserServerName) narrows the match; NULL matches any
/// driver of class PPUSB_DRIVER_CLASS.
bool ppusb_driver_present(const char *serverName);

/// Opens a connection to the driver's user client. Returns kIOReturnNotFound (0xE00002F0) when no driver
/// service is registered: the scanner isn't plugged in, or the driver isn't enabled.
ppusb_return_t ppusb_open(const char *serverName, ppusb_connection_t *connection);

/// One bulk OUT transfer of `length` bytes.
ppusb_return_t ppusb_write(ppusb_connection_t connection, const void *bytes, size_t length, uint32_t timeoutMs);

/// One bulk IN transfer of up to `capacity` bytes into `buffer`; `received` gets the count.
ppusb_return_t ppusb_read(ppusb_connection_t connection, void *buffer, size_t capacity, uint32_t timeoutMs,
                          size_t *received);

/// Resets the device. The connection is dead afterwards: close it.
ppusb_return_t ppusb_reset(ppusb_connection_t connection);

void ppusb_close(ppusb_connection_t connection);

#ifdef __cplusplus
}
#endif

#endif
