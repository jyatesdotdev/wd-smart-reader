//
//  WDDevice.m
//  IOKit device discovery and management.
//

#import "WDSmart.h"

#pragma mark - Device Discovery

/// Finds the first WD SES (SCSI Enclosure Services) device via IOKit.
///
/// WD external enclosures expose two SCSI LUNs: the disk itself and an SES
/// management device. The SES device is the one that accepts diagnostic page
/// commands for SMART data retrieval.
///
/// When deviceIndex >= 0, opens the Nth device (0-based).
/// When deviceIndex < 0, opens the first available device.
///
/// Returns an exclusive-access SCSITaskDeviceInterface, or NULL on failure.
/// Caller must release exclusive access and the interface when done.
SCSITaskDeviceInterface **WDOpenDevice(char *nameOut, size_t nameSize, int deviceIndex) {
    io_iterator_t iter;
    io_service_t service;

    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) return NULL;

    int found = 0;
    while ((service = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        // Read vendor/product identification from the IOKit registry
        CFTypeRef vendorRef = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, CFSTR("Vendor Identification"),
            kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
        CFTypeRef productRef = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, CFSTR("Product Identification"),
            kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);

        NSString *vendor = vendorRef ? (__bridge_transfer NSString *)vendorRef : nil;
        NSString *product = productRef ? (__bridge_transfer NSString *)productRef : nil;

        if (!vendor) { IOObjectRelease(service); continue; }

        // Filter to WD devices only
        NSString *trimmedVendor = [vendor stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (![trimmedVendor isEqualToString:@"WD"] && ![trimmedVendor isEqualToString:@"WDC"]) {
            IOObjectRelease(service); continue;
        }

        // We specifically need the SES device (not the disk LUN)
        NSString *trimmedProduct = product
            ? [product stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
            : @"";
        if (![trimmedProduct containsString:@"SES"]) {
            IOObjectRelease(service); continue;
        }

        // Skip until we reach the requested device index
        if (deviceIndex >= 0 && found < deviceIndex) {
            found++;
            IOObjectRelease(service);
            continue;
        }

        if (nameOut && product) {
            snprintf(nameOut, nameSize, "%s %s",
                     [vendor UTF8String], [product UTF8String]);
        }

        // Create the IOKit plugin interface for SCSI task submission
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        kr = IOCreatePlugInInterfaceForService(
            service, kIOSCSITaskDeviceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(service);

        if (kr != kIOReturnSuccess || !plugin) continue;

        // Query for the SCSI task device interface
        SCSITaskDeviceInterface **dev = NULL;
        (*plugin)->QueryInterface(plugin,
            CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID), (LPVOID *)&dev);
        (*plugin)->Release(plugin);

        if (!dev) continue;

        // Obtain exclusive access (required for sending SCSI commands)
        kr = (*dev)->ObtainExclusiveAccess(dev);
        if (kr != kIOReturnSuccess) {
            fprintf(stderr,
                "Error: Cannot get exclusive access (0x%x).\n"
                "  - Quit WD Drive Utilities if running\n"
                "  - Try: diskutil unmountDisk /dev/diskN\n", kr);
            (*dev)->Release(dev);
            IOObjectRelease(iter);
            return NULL;
        }

        IOObjectRelease(iter);
        return dev;
    }

    IOObjectRelease(iter);
    return NULL;
}

/// List all connected WD SES devices with their disk LUN product names.
int WDListDevices(void) {
    io_iterator_t iter;
    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) return 0;

    // First pass: collect disk LUN names and SES device count
    io_service_t service;
    NSMutableArray *diskNames = [NSMutableArray array];
    int sesCount = 0;

    while ((service = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        CFTypeRef vendorRef = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, CFSTR("Vendor Identification"),
            kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
        CFTypeRef productRef = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, CFSTR("Product Identification"),
            kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);

        NSString *vendor = vendorRef ? (__bridge_transfer NSString *)vendorRef : nil;
        NSString *product = productRef ? (__bridge_transfer NSString *)productRef : nil;
        if (!vendor) { IOObjectRelease(service); continue; }

        NSString *tv = [vendor stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![tv isEqualToString:@"WD"] && ![tv isEqualToString:@"WDC"]) {
            IOObjectRelease(service); continue;
        }
        NSString *tp = product ? [product stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";

        if ([tp containsString:@"SES"]) {
            sesCount++;
        } else {
            [diskNames addObject:tp];
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);

    // Print paired results
    for (int i = 0; i < sesCount; i++) {
        NSString *name = (i < (int)diskNames.count) ? diskNames[i] : @"Unknown";
        printf("  [%d] %s\n", i, [name UTF8String]);
    }
    return sesCount;
}

/// Release device resources. Call when done with all commands.
void WDCloseDevice(SCSITaskDeviceInterface **dev) {
    (*dev)->ReleaseExclusiveAccess(dev);
    (*dev)->Release(dev);
}

