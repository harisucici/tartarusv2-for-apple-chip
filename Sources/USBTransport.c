#include "USBTransport.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <string.h>
#include <unistd.h>

static uint32_t property(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service,key,kCFAllocatorDefault,0);
    int64_t result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value,kCFNumberSInt64Type,&result);
    if (value) CFRelease(value);
    return (uint32_t)result;
}
// Deliberately restricted to the three lighting effects. No interface grabs, reset,
// configuration changes, interrupt reads, input report requests, or detach calls.
int32_t tartarusLightTransfer(uint32_t location, const uint8_t *request, uint8_t *response, uint32_t *actualLength) {
    if (!location || !request || !response || !actualLength) return kIOReturnBadArgument;
    *actualLength = 0;
    uint8_t crc = 0;
    for (int i=2;i<88;i++) crc ^= request[i];
    if (request[0] || request[1] != 0x1f || request[6] != 15 || request[7] != 2 || request[8] > 1 || request[9] != 5 || request[88] != crc) return kIOReturnBadArgument;
    if (!((request[10] == 1 && request[5] == 9) || ((request[10] == 0 || request[10] == 3) && request[5] == 6))) return kIOReturnBadArgument;
    io_iterator_t iterator = 0;
    IOReturn result = IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostDevice"),&iterator);
    if (result != kIOReturnSuccess) return result;
    result = kIOReturnNoDevice;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (property(service,CFSTR("idVendor")) != 0x1532 || property(service,CFSTR("idProduct")) != 0x022b || property(service,CFSTR("locationID")) != location) { IOObjectRelease(service); continue; }
        IOCFPlugInInterface **plugin = NULL;
        IOUSBDeviceInterface320 **device = NULL;
        SInt32 score = 0;
        result = IOCreatePlugInInterfaceForService(service,kIOUSBDeviceUserClientTypeID,kIOCFPlugInInterfaceID,&plugin,&score);
        IOObjectRelease(service);
        if (result != kIOReturnSuccess || !plugin) break;
        HRESULT queried = (*plugin)->QueryInterface(plugin,CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320),(LPVOID *)&device);
        IODestroyPlugInInterface(plugin);
        if (queried || !device) { result = kIOReturnUnsupported; break; }
        IOReturn opened = (*device)->USBDeviceOpen(device);
        if (opened != kIOReturnSuccess && opened != kIOReturnExclusiveAccess) { result = opened; (*device)->Release(device); break; }
        uint8_t payload[90]; memcpy(payload,request,90);
        IOUSBDevRequestTO transfer = {0};
        transfer.bmRequestType = 0x21; transfer.bRequest = 9;
        transfer.wValue = 0x0300; transfer.wIndex = 2;
        transfer.wLength = 90; transfer.pData = payload;
        transfer.noDataTimeout = 500; transfer.completionTimeout = 1000;
        result = (*device)->DeviceRequestTO(device,&transfer);
        if (result == kIOReturnSuccess) {
            for (int attempt=0;attempt<3;attempt++) {
                usleep(15000); memset(response,0,90);
                transfer.bmRequestType = 0xa1; transfer.bRequest = 1;
                transfer.pData = response; transfer.wLenDone = 0;
                result = (*device)->DeviceRequestTO(device,&transfer);
                *actualLength = transfer.wLenDone;
                if (result != kIOReturnSuccess || response[0] != 1) break;
            }
        }
        if (opened == kIOReturnSuccess) (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        break;
    }
    IOObjectRelease(iterator);
    return result;
}
