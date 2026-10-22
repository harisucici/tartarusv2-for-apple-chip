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
// Only validated lighting reports; never grabs or resets input interfaces.
int32_t tartarusLightRequestValid(const uint8_t *request) {
    if (!request) return 0;
    uint8_t crc = 0;
    for (int i=2;i<88;i++) crc ^= request[i];
    if (request[0] || request[1] != 0x1f || request[6] != 15 || request[88] != crc) return 0;
    if (request[7] == 4) {
        if (request[5] != 3 || request[8] != 1 || request[9] != 0) return 0;
        for (int i=11;i<88;i++) if (request[i]) return 0;
        return 1;
    }
    if (request[7] == 3) {
        if (request[5] != 0x47 || request[8] || request[9] || request[10] > 3 || request[11] != 0 || request[12] != 5) return 0;
        for (int i=31;i<88;i++) if (request[i]) return 0;
        return 1;
    }
    if (request[7] != 2) return 0;
    if (request[10] == 8 && request[5] == 12) {
        if (request[8] || request[9]) return 0;
        for (int i=11;i<88;i++) if (request[i]) return 0;
        return 1;
    }
    if (request[8] > 1 || request[9] != 5) return 0;
    int size = request[5];
    for (int i=8+size;i<88;i++) if (request[i]) return 0;
    switch (request[10]) {
    case 0: case 3: return size == 6 && !request[11] && !request[12] && !request[13];
    case 1: return size == 9 && !request[11] && !request[12] && request[13] == 1;
    case 4: return size == 6 && request[11] >= 1 && request[11] <= 2 && request[12] == 0x70 && !request[13];
    case 2: // Breathing: random, one color, or two colors.
        return (size == 6 && !request[11] && !request[12] && !request[13]) ||
               (size == 9 && request[11] == 1 && !request[12] && request[13] == 1) ||
               (size == 12 && request[11] == 2 && !request[12] && request[13] == 2);
    case 5: return size == 9 && !request[11] && request[12] >= 1 && request[12] <= 4 && request[13] == 1;
    case 7: // Starlight: random, one color, or two colors.
        return !request[11] && request[12] >= 1 && request[12] <= 3 &&
               ((size == 6 && !request[13]) || (size == 9 && request[13] == 1) || (size == 12 && request[13] == 2));
    default: return 0;
    }
}
int32_t tartarusLightTransferBatch(uint32_t location, const uint8_t *requests, uint32_t count, uint8_t *response, uint32_t *actualLength) {
    if (!location || !requests || !response || !actualLength || count < 1 || count > 6) return kIOReturnBadArgument;
    *actualLength = 0;
    for (uint32_t i=0;i<count;i++) if (!tartarusLightRequestValid(requests+90*i)) return kIOReturnBadArgument;
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
        IOUSBDevRequestTO transfer = {0};
        transfer.bmRequestType = 0x21; transfer.bRequest = 9;
        transfer.wValue = 0x0300; transfer.wIndex = 2;
        transfer.wLength = 90;
        transfer.noDataTimeout = 1000; transfer.completionTimeout = 2000;
        for (uint32_t i=0;i<count;i++) {
            const uint8_t *request = requests+90*i;
            uint8_t payload[90]; memcpy(payload,request,90);
            transfer.bmRequestType = 0x21; transfer.bRequest = 9;
            transfer.pData = payload; transfer.wLenDone = 0;
            result = (*device)->DeviceRequestTO(device,&transfer);
            if (result != kIOReturnSuccess) break;
            for (int attempt=0;attempt<3;attempt++) {
                usleep(15000); memset(response,0,90);
                transfer.bmRequestType = 0xa1; transfer.bRequest = 1;
                transfer.pData = response; transfer.wLenDone = 0;
                result = (*device)->DeviceRequestTO(device,&transfer);
                *actualLength = transfer.wLenDone;
                if (result != kIOReturnSuccess || response[0] != 1) break;
            }
            if (result != kIOReturnSuccess) break;
            uint8_t crc = 0;
            for (int j=2;j<88;j++) crc ^= response[j];
            if (*actualLength != 90 || response[0] != 2 || response[1] != request[1] ||
                response[6] != request[6] || response[7] != request[7] || response[88] != crc) {
                result = kIOReturnError;
                break;
            }
        }
        if (opened == kIOReturnSuccess) (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        break;
    }
    IOObjectRelease(iterator);
    return result;
}
int32_t tartarusLightTransfer(uint32_t location, const uint8_t *request, uint8_t *response, uint32_t *actualLength) {
    return tartarusLightTransferBatch(location,request,1,response,actualLength);
}
