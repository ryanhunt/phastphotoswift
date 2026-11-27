#include <os/log.h>
#include <DriverKit/DriverKit.h>
#include <DriverKit/OSData.h>

#include "PhastPhotoUSBUserClient.h"
#include "PhastPhotoUSBDriver.h"
#include "PhastPhotoUSBProtocol.h"

struct PhastPhotoUSBUserClient_IVars {
    PhastPhotoUSBDriver *driver = nullptr;
};

bool PhastPhotoUSBUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(PhastPhotoUSBUserClient_IVars, 1);
    return ivars != nullptr;
}

void PhastPhotoUSBUserClient::free()
{
    if (ivars) OSSafeReleaseNULL(ivars->driver);
    IOSafeDeleteNULL(ivars, PhastPhotoUSBUserClient_IVars, 1);
    super::free();
}

kern_return_t IMPL(PhastPhotoUSBUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    ivars->driver = OSDynamicCast(PhastPhotoUSBDriver, provider);
    if (!ivars->driver) return kIOReturnBadArgument;
    ivars->driver->retain();
    // transfers block (up to the app's timeout): run them on their own queue, so Stop and termination on the
    // default queue are never stuck behind one
    IODispatchQueue *queue = nullptr;
    ret = IODispatchQueue::Create(kIOUserClientQueueNameExternalMethod, 0, 0, &queue);
    if (ret != kIOReturnSuccess) return ret;
    ret = SetDispatchQueue(kIOUserClientQueueNameExternalMethod, queue);
    queue->release();
    return ret;
}

kern_return_t IMPL(PhastPhotoUSBUserClient, Stop)
{
    if (ivars->driver) ivars->driver->UserClientClosed();  // the driver itself is released in free()
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t PhastPhotoUSBUserClient::ExternalMethod(uint64_t selector, IOUserClientMethodArguments *args,
                                                      const IOUserClientMethodDispatch *, OSObject *, void *)
{
    if (!ivars || !ivars->driver || !args) return kIOReturnNotReady;
    PhastPhotoUSBDriver *driver = ivars->driver;

    switch (selector) {
    case kPPUSBSelectorWrite: {
        if (args->scalarInputCount < 1 || !args->scalarInput) return kIOReturnBadArgument;
        uint32_t timeoutMs = static_cast<uint32_t>(args->scalarInput[0]);
        // up to 4096 bytes arrive inline as OSData, larger ones as the caller's memory
        if (args->structureInput) {
            return driver->BulkWrite(args->structureInput->getBytesNoCopy(),
                                     static_cast<uint32_t>(args->structureInput->getLength()), timeoutMs);
        }
        if (args->structureInputDescriptor) {
            uint64_t length = 0;
            kern_return_t ret = args->structureInputDescriptor->GetLength(&length);
            if (ret != kIOReturnSuccess) return ret;
            if (length == 0 || length > PPUSB_MAX_TRANSFER) return kIOReturnBadArgument;
            IOMemoryMap *map = nullptr;
            ret = args->structureInputDescriptor->CreateMapping(kIOMemoryMapReadOnly, 0, 0, 0, 0, &map);
            if (ret != kIOReturnSuccess) return ret;
            ret = driver->BulkWrite(reinterpret_cast<const void *>(map->GetAddress()), static_cast<uint32_t>(length),
                                    timeoutMs);
            map->release();
            return ret;
        }
        return kIOReturnBadArgument;
    }

    case kPPUSBSelectorRead: {
        if (args->scalarInputCount < 2 || !args->scalarInput || args->scalarOutputCount < 1 || !args->scalarOutput) {
            return kIOReturnBadArgument;
        }
        uint64_t requested = args->scalarInput[0];
        uint32_t timeoutMs = static_cast<uint32_t>(args->scalarInput[1]);
        if (requested == 0 || requested > PPUSB_MAX_TRANSFER) return kIOReturnBadArgument;
        uint32_t maxLength = static_cast<uint32_t>(requested);
        uint32_t got = 0;
        kern_return_t ret;
        if (args->structureOutputDescriptor) {
            // more than 4096 bytes: the caller's buffer, mapped in; never write past it
            uint64_t capacity = 0;
            ret = args->structureOutputDescriptor->GetLength(&capacity);
            if (ret != kIOReturnSuccess) return ret;
            if (capacity < maxLength) maxLength = static_cast<uint32_t>(capacity);
            if (maxLength == 0) return kIOReturnBadArgument;
            ret = driver->BulkRead(args->structureOutputDescriptor, maxLength, timeoutMs, &got);
        } else {
            // up to 4096 bytes: returned inline as OSData
            if (args->structureOutputMaximumSize < maxLength) maxLength = static_cast<uint32_t>(args->structureOutputMaximumSize);
            if (maxLength == 0) return kIOReturnBadArgument;
            IOBufferMemoryDescriptor *buffer = nullptr;
            ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, maxLength, 0, &buffer);
            if (ret != kIOReturnSuccess) return ret;
            buffer->SetLength(maxLength);
            ret = driver->BulkRead(buffer, maxLength, timeoutMs, &got);
            if (ret == kIOReturnSuccess) {
                IOAddressSegment segment = {};
                ret = buffer->GetAddressRange(&segment);
                if (ret == kIOReturnSuccess) {
                    OSData *data = OSData::withBytes(reinterpret_cast<const void *>(segment.address), got);
                    if (data) args->structureOutput = data;  // released by the framework
                    else ret = kIOReturnNoMemory;
                }
            }
            buffer->release();
        }
        args->scalarOutput[0] = got;
        args->scalarOutputCount = 1;
        return ret;
    }

    case kPPUSBSelectorReset:
        return driver->ResetDevice();

    default:
        return kIOReturnUnsupported;
    }
}
