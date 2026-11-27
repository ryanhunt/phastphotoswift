#include "CPhastPhotoDriverKit.h"

#include <TargetConditionals.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>

#define PPUSB_NOT_FOUND kIOReturnNotFound

/// IOUserService entries whose IOUserClass is the driver's class (and IOUserServerName, when given).
/// A driver extension's service is registered as an IOUserService carrying its personality's properties.
static CFMutableDictionaryRef matching(const char *serverName) {
    CFMutableDictionaryRef dict = IOServiceMatching("IOUserService");
    if (!dict) return NULL;
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                  &kCFTypeDictionaryValueCallBacks);
    if (!properties) { CFRelease(dict); return NULL; }
    CFStringRef userClass = CFStringCreateWithCString(kCFAllocatorDefault, PPUSB_DRIVER_CLASS, kCFStringEncodingUTF8);
    CFDictionarySetValue(properties, CFSTR("IOUserClass"), userClass);
    CFRelease(userClass);
    if (serverName) {
        CFStringRef server = CFStringCreateWithCString(kCFAllocatorDefault, serverName, kCFStringEncodingUTF8);
        if (server) {
            CFDictionarySetValue(properties, CFSTR("IOUserServerName"), server);
            CFRelease(server);
        }
    }
    CFDictionarySetValue(dict, CFSTR(kIOPropertyMatchKey), properties);
    CFRelease(properties);
    return dict;
}

static io_service_t find_service(const char *serverName) {
    CFMutableDictionaryRef dict = matching(serverName);
    if (!dict) return IO_OBJECT_NULL;
    return IOServiceGetMatchingService(kIOMainPortDefault, dict);  // consumes dict
}

bool ppusb_driver_present(const char *serverName) {
    io_service_t service = find_service(serverName);
    if (service == IO_OBJECT_NULL) return false;
    IOObjectRelease(service);
    return true;
}

ppusb_return_t ppusb_open(const char *serverName, ppusb_connection_t *connection) {
    *connection = 0;
    io_service_t service = find_service(serverName);
    if (service == IO_OBJECT_NULL) return PPUSB_NOT_FOUND;
    io_connect_t connect = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &connect);
    IOObjectRelease(service);
    if (kr == KERN_SUCCESS) *connection = connect;
    return kr;
}

ppusb_return_t ppusb_write(ppusb_connection_t connection, const void *bytes, size_t length, uint32_t timeoutMs) {
    if (length == 0 || length > PPUSB_MAX_TRANSFER) return kIOReturnBadArgument;
    uint64_t input[1] = {timeoutMs};
    return IOConnectCallMethod(connection, kPPUSBSelectorWrite, input, 1, bytes, length, NULL, NULL, NULL, NULL);
}

ppusb_return_t ppusb_read(ppusb_connection_t connection, void *buffer, size_t capacity, uint32_t timeoutMs,
                          size_t *received) {
    *received = 0;
    if (capacity == 0 || capacity > PPUSB_MAX_TRANSFER) return kIOReturnBadArgument;
    uint64_t input[2] = {capacity, timeoutMs};
    uint64_t output[1] = {0};
    uint32_t outputCount = 1;
    size_t structSize = capacity;
    kern_return_t kr = IOConnectCallMethod(connection, kPPUSBSelectorRead, input, 2, NULL, 0, output, &outputCount,
                                           buffer, &structSize);
    if (kr == KERN_SUCCESS) {
        // the scalar is the count (see kPPUSBSelectorRead); never trust it past the buffer
        *received = output[0] > capacity ? capacity : (size_t)output[0];
    }
    return kr;
}

ppusb_return_t ppusb_reset(ppusb_connection_t connection) {
    return IOConnectCallMethod(connection, kPPUSBSelectorReset, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL);
}

void ppusb_close(ppusb_connection_t connection) {
    if (connection != IO_OBJECT_NULL) IOServiceClose(connection);
}
