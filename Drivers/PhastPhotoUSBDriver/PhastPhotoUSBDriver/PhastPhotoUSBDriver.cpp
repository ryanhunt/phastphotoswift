#include <os/log.h>
#include <DriverKit/DriverKit.h>
#include <USBDriverKit/USBDriverKit.h>

#include "PhastPhotoUSBDriver.h"
#include "PhastPhotoUSBProtocol.h"

static constexpr uint8_t kBulkOut = 0x01;
static constexpr uint8_t kBulkIn = 0x82;

struct PhastPhotoUSBDriver_IVars {
    IOUSBHostInterface *interface = nullptr;
    IOUSBHostPipe *outPipe = nullptr;
    IOUSBHostPipe *inPipe = nullptr;
    // the write buffer from the interface (not bounced for DMA); shared, hence one user client at a time
    IOBufferMemoryDescriptor *outBuffer = nullptr;
    bool opened = false;
    // set by Stop, read by transfers running on the user client's queue
    bool stopping = false;
    // An app is connected. Only one at a time: the pipes and buffers are shared.
    bool clientOpen = false;
    // A transfer is using the pipes and buffers. It can outlive its client (the app closes or dies mid-
    // transfer), so a new client is refused until it has finished, not just until the old client is gone.
    bool inFlight = false;
};

/// Marks a transfer as running for the scope; refuses to start a second one.
class TransferGuard {
public:
    explicit TransferGuard(bool *flag) : flag_(flag), acquired_(!__atomic_exchange_n(flag, true, __ATOMIC_ACQ_REL)) {}
    ~TransferGuard() { if (acquired_) __atomic_store_n(flag_, false, __ATOMIC_RELEASE); }
    bool acquired() const { return acquired_; }
private:
    bool *flag_;
    bool acquired_;
};

static bool isStopping(PhastPhotoUSBDriver_IVars *ivars) {
    return __atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE);
}

bool PhastPhotoUSBDriver::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(PhastPhotoUSBDriver_IVars, 1);
    return ivars != nullptr;
}

// Resources are released here, not in Stop: a transfer on the user client's queue may still be finishing
// when Stop runs, and it must not find freed pipes or buffers.
void PhastPhotoUSBDriver::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->outBuffer);
        OSSafeReleaseNULL(ivars->inPipe);
        OSSafeReleaseNULL(ivars->outPipe);
        OSSafeReleaseNULL(ivars->interface);
    }
    IOSafeDeleteNULL(ivars, PhastPhotoUSBDriver_IVars, 1);
    super::free();
}

kern_return_t IMPL(PhastPhotoUSBDriver, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;

    ivars->interface = OSDynamicCast(IOUSBHostInterface, provider);
    if (!ivars->interface) return kIOReturnBadArgument;
    ivars->interface->retain();

    // exclusive: fails while another driver holds the interface
    ret = ivars->interface->Open(this, 0, nullptr);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "PhastPhotoUSBDriver: Open failed 0x%x", ret);
        return ret;
    }
    ivars->opened = true;
    if ((ret = ivars->interface->CopyPipe(kBulkOut, &ivars->outPipe)) != kIOReturnSuccess ||
        (ret = ivars->interface->CopyPipe(kBulkIn, &ivars->inPipe)) != kIOReturnSuccess ||
        // InOut, not Out: the driver fills this buffer itself. On iPadOS an Out buffer is mapped read-only into
        // the driver, and the first copy into it crashed (SIGBUS, iPad Pro M1). Reads need no buffer here: the
        // controller writes into the caller's memory.
        (ret = ivars->interface->CreateIOBuffer(kIOMemoryDirectionInOut, PPUSB_MAX_TRANSFER, &ivars->outBuffer)) != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "PhastPhotoUSBDriver: setup failed 0x%x", ret);
        ivars->interface->Close(this, 0);
        ivars->opened = false;
        return ret;
    }

    ret = RegisterService();  // makes the service visible to the app
    if (ret != kIOReturnSuccess) {
        ivars->interface->Close(this, 0);
        ivars->opened = false;
        return ret;
    }
    os_log(OS_LOG_DEFAULT, "PhastPhotoUSBDriver: started");
    return kIOReturnSuccess;
}

kern_return_t IMPL(PhastPhotoUSBDriver, Stop)
{
    __atomic_store_n(&ivars->stopping, true, __ATOMIC_RELEASE);
    // a transfer blocked in IO returns kIOReturnAborted
    if (ivars->outPipe) ivars->outPipe->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
    if (ivars->inPipe) ivars->inPipe->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
    if (ivars->opened) {
        ivars->interface->Close(this, 0);
        ivars->opened = false;
    }
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(PhastPhotoUSBDriver, NewUserClient)
{
    // one client at a time, and not while a closed client's transfer is still finishing
    if (__atomic_exchange_n(&ivars->clientOpen, true, __ATOMIC_ACQ_REL)) return kIOReturnExclusiveAccess;
    if (__atomic_load_n(&ivars->inFlight, __ATOMIC_ACQUIRE)) {
        __atomic_store_n(&ivars->clientOpen, false, __ATOMIC_RELEASE);
        return kIOReturnExclusiveAccess;
    }
    IOService *client = nullptr;
    kern_return_t ret = Create(this, "UserClientProperties", &client);
    if (ret != kIOReturnSuccess) {
        __atomic_store_n(&ivars->clientOpen, false, __ATOMIC_RELEASE);
        return ret;
    }
    *userClient = OSDynamicCast(IOUserClient, client);
    if (!*userClient) {
        client->release();
        __atomic_store_n(&ivars->clientOpen, false, __ATOMIC_RELEASE);
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

// The app closed its connection (or died). A transfer it started may still be blocked in IO on the user
// client's queue: abort it so it returns now. Its TransferGuard keeps new clients out until it has.
void PhastPhotoUSBDriver::UserClientClosed()
{
    if (!isStopping(ivars)) {
        if (ivars->outPipe) ivars->outPipe->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
        if (ivars->inPipe) ivars->inPipe->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
    }
    __atomic_store_n(&ivars->clientOpen, false, __ATOMIC_RELEASE);
}

kern_return_t PhastPhotoUSBDriver::BulkWrite(const void *bytes, uint32_t length, uint32_t timeoutMs)
{
    if (isStopping(ivars) || !ivars->outPipe) return kIOReturnNotAttached;
    if (length == 0 || length > PPUSB_MAX_TRANSFER) return kIOReturnBadArgument;
    TransferGuard transfer(&ivars->inFlight);
    if (!transfer.acquired()) return kIOReturnBusy;
    IOAddressSegment segment = {};
    kern_return_t ret = ivars->outBuffer->GetAddressRange(&segment);
    if (ret != kIOReturnSuccess) return ret;
    memcpy(reinterpret_cast<void *>(segment.address), bytes, length);
    ivars->outBuffer->SetLength(length);
    uint32_t sent = 0;
    ret = ivars->outPipe->IO(ivars->outBuffer, length, &sent, timeoutMs);
    if (ret == kIOReturnSuccess && sent != length) ret = kIOReturnUnderrun;
    // any error but a timeout halts a bulk endpoint (IOUSBHostPipe.iig); an abort is ours, not a stall
    if (ret != kIOReturnSuccess && ret != kIOReturnTimeout && ret != kIOReturnAborted && !isStopping(ivars)) {
        ivars->outPipe->ClearStall(true);
    }
    return ret;
}

kern_return_t PhastPhotoUSBDriver::BulkRead(IOMemoryDescriptor *into, uint32_t maxLength, uint32_t timeoutMs,
                                            uint32_t *received)
{
    *received = 0;
    if (isStopping(ivars) || !ivars->inPipe) return kIOReturnNotAttached;
    if (!into || maxLength == 0 || maxLength > PPUSB_MAX_TRANSFER) return kIOReturnBadArgument;
    TransferGuard transfer(&ivars->inFlight);
    if (!transfer.acquired()) return kIOReturnBusy;
    // The controller writes straight into `into` (the caller's buffer, or the user client's small buffer).
    // Copying into a CPU mapping of the caller's buffer instead crashed: on iPadOS that mapping is read-only,
    // even through a kIOMemoryDirectionIn sub-descriptor (SIGBUS, iPad Pro M1, iPadOS 27).
    uint32_t got = 0;
    kern_return_t ret = ivars->inPipe->IO(into, maxLength, &got, timeoutMs);
    if (ret != kIOReturnSuccess) {
        if (ret != kIOReturnTimeout && ret != kIOReturnAborted && !isStopping(ivars)) ivars->inPipe->ClearStall(true);
        return ret;
    }
    *received = got > maxLength ? maxLength : got;
    return kIOReturnSuccess;
}

// Terminates the device and everything above it, this driver included; a new instance is started when the
// device comes back. The app must close its connection and open a new one.
kern_return_t PhastPhotoUSBDriver::ResetDevice()
{
    if (isStopping(ivars) || !ivars->interface) return kIOReturnNotAttached;
    IOUSBHostDevice *device = nullptr;
    kern_return_t ret = ivars->interface->CopyDevice(&device);
    if (ret != kIOReturnSuccess) return ret;
    ret = device->Reset();
    device->release();
    return ret;
}
