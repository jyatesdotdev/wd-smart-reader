//
//  WDDevice.m
//  IOKit device discovery and management.
//
//  WD enclosures expose two SCSI LUNs under one IOUSBMassStorageDriver:
//    LUN 0 — the disk (Peripheral Device Type 0), claimed by the kernel
//    LUN 1 — SES management device (Peripheral Device Type 13), user-accessible
//
//  Everything that needs the *disk* LUN (model name, BSD name for erase) must
//  resolve it via the SAME parent driver as the SES LUN we opened, otherwise
//  `--disk 1 erase` could target drive 0. g_selectedEnclosureID carries that
//  binding.
//

#import "WDSmart.h"
#import <DiskArbitration/DiskArbitration.h>

uint64_t g_selectedEnclosureID = 0;
UInt8 g_selectedLUN = 0;

#pragma mark - Registry Helpers

/// Read a string property (searching parents), trimmed of whitespace. nil if absent.
NSString *WDRegistryString(io_service_t s, CFStringRef key) {
    CFTypeRef ref = IORegistryEntrySearchCFProperty(
        s, kIOServicePlane, key, kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (!ref) return nil;
    if (CFGetTypeID(ref) != CFStringGetTypeID()) { CFRelease(ref); return nil; }
    NSString *str = (__bridge_transfer NSString *)ref;
    return [str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}
#define regString WDRegistryString

/// Read an integer property from the entry itself. -1 if absent.
static int regInt(io_service_t s, CFStringRef key) {
    CFTypeRef ref = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    if (!ref) return -1;
    int v = -1;
    if (CFGetTypeID(ref) == CFNumberGetTypeID()) CFNumberGetValue(ref, kCFNumberIntType, &v);
    CFRelease(ref);
    return v;
}

static BOOL isWDVendor(NSString *vendor) {
    return [vendor isEqualToString:@"WD"] || [vendor isEqualToString:@"WDC"];
}

/// WD encodes the USB serial as hex ASCII ("5758..." == "WX..."). Decode when
/// the whole string is even-length hex and decodes to printable ASCII.
NSString *WDDecodeSerial(NSString *hex) {
    if (!hex || hex.length < 2 || (hex.length & 1)) return hex;
    NSMutableString *out = [NSMutableString stringWithCapacity:hex.length / 2];
    for (NSUInteger i = 0; i < hex.length; i += 2) {
        unsigned v = 0;
        NSScanner *sc = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]];
        if (![sc scanHexInt:&v] || !sc.isAtEnd || v < 0x20 || v > 0x7E) return hex;
        [out appendFormat:@"%c", (char)v];
    }
    return out;
}
#define decodeWDSerial WDDecodeSerial

/// Registry entry ID of the entry's parent in the service plane (the mass
/// storage driver that owns both LUNs). 0 on failure.
static uint64_t parentEntryID(io_service_t s) {
    io_registry_entry_t parent = IO_OBJECT_NULL;
    if (IORegistryEntryGetParentEntry(s, kIOServicePlane, &parent) != KERN_SUCCESS) return 0;
    uint64_t id = 0;
    IORegistryEntryGetRegistryEntryID(parent, &id);
    IOObjectRelease(parent);
    return id;
}

/// If another process already holds a SCSITaskUserClient on this nub, return
/// its "IOUserClientCreator" string (e.g. "pid 1112, WDDriveUtilityHe").
static NSString *existingUserClientHolder(io_service_t nub) {
    io_iterator_t it;
    if (IORegistryEntryGetChildIterator(nub, kIOServicePlane, &it) != KERN_SUCCESS) return nil;
    NSString *holder = nil;
    io_service_t child;
    while (!holder && (child = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        if (IOObjectConformsTo(child, "SCSITaskUserClient")) {
            CFTypeRef ref = IORegistryEntryCreateCFProperty(child, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0);
            if (ref && CFGetTypeID(ref) == CFStringGetTypeID()) holder = (__bridge_transfer NSString *)ref;
            else if (ref) CFRelease(ref);
        }
        IOObjectRelease(child);
    }
    IOObjectRelease(it);
    return holder;
}

typedef enum { kLUNOther, kLUNDisk, kLUNSES } LUNKind;

/// Classify a nub: WD disk LUN, WD SES LUN, or something we don't care about.
static LUNKind classifyNub(io_service_t s, NSString **productOut) {
    NSString *vendor = regString(s, CFSTR("Vendor Identification"));
    if (!vendor || !isWDVendor(vendor)) return kLUNOther;
    NSString *product = regString(s, CFSTR("Product Identification")) ?: @"";
    if (productOut) *productOut = product;
    int type = regInt(s, CFSTR("Peripheral Device Type"));
    if (type == 13 || [product containsString:@"SES"]) return kLUNSES;
    if (type == 0) return kLUNDisk;
    return kLUNOther;
}

/// Walk children of a disk nub to find the whole-disk IOMedia BSD name.
static NSString *bsdNameUnder(io_service_t diskNub) {
    io_iterator_t childIter;
    if (IORegistryEntryCreateIterator(diskNub, kIOServicePlane,
                                      kIORegistryIterateRecursively, &childIter) != KERN_SUCCESS)
        return nil;
    NSString *result = nil;
    io_service_t child;
    while (!result && (child = IOIteratorNext(childIter)) != IO_OBJECT_NULL) {
        if (IOObjectConformsTo(child, "IOMedia")) {
            CFTypeRef wholeRef = IORegistryEntryCreateCFProperty(child, CFSTR("Whole"), kCFAllocatorDefault, 0);
            BOOL whole = wholeRef && CFGetTypeID(wholeRef) == CFBooleanGetTypeID() && CFBooleanGetValue(wholeRef);
            if (wholeRef) CFRelease(wholeRef);
            if (whole) {
                CFTypeRef bsdRef = IORegistryEntryCreateCFProperty(child, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
                if (bsdRef) {
                    if (CFGetTypeID(bsdRef) == CFStringGetTypeID())
                        result = (__bridge_transfer NSString *)bsdRef;
                    else
                        CFRelease(bsdRef);
                }
            }
        }
        IOObjectRelease(child);
    }
    IOObjectRelease(childIter);
    return result;
}

#pragma mark - Device Discovery

/// Finds the Nth WD SES device (0-based; <0 = first) via IOKit and opens it
/// with exclusive access. Records the parent enclosure ID so later disk-LUN
/// lookups resolve to the same physical drive.
///
/// Returns an exclusive-access SCSITaskDeviceInterface, or NULL on failure.
/// Caller must WDCloseDevice() when done.
SCSITaskDeviceInterface **WDOpenDevice(char *nameOut, size_t nameSize, int deviceIndex) {
    io_iterator_t iter;
    io_service_t service;

    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) return NULL;

    int found = 0;
    while ((service = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        NSString *product = nil;
        if (classifyNub(service, &product) != kLUNSES) { IOObjectRelease(service); continue; }

        // Skip until we reach the requested device index
        if (deviceIndex >= 0 && found < deviceIndex) {
            found++;
            IOObjectRelease(service);
            continue;
        }

        if (nameOut) {
            NSString *vendor = regString(service, CFSTR("Vendor Identification")) ?: @"WD";
            snprintf(nameOut, nameSize, "%s %s", [vendor UTF8String], [product UTF8String]);
        }

        uint64_t enclosureID = parentEntryID(service);
        int lun = regInt(service, CFSTR("SCSI Logical Unit Number"));
        NSString *holder = existingUserClientHolder(service);

        // Create the IOKit plugin interface for SCSI task submission
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        kr = IOCreatePlugInInterfaceForService(
            service, kIOSCSITaskDeviceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(service);

        if (kr != kIOReturnSuccess || !plugin) {
            fprintf(stderr, "Error: Cannot open SES device (IOKit 0x%08x).\n", kr);
            if (holder)
                fprintf(stderr, "  Another process already holds it: %s\n"
                                "  Quit that app, or: killall WDDriveUtilityHelper WDSecurityHelper\n",
                        [holder UTF8String]);
            else
                fprintf(stderr, "  Retry with sudo, or quit WD Discovery / WD Drive Utilities / WD Security.\n");
            IOObjectRelease(iter);
            return NULL;
        }

        // Query for the SCSI task device interface
        SCSITaskDeviceInterface **dev = NULL;
        (*plugin)->QueryInterface(plugin,
            CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID), (LPVOID *)&dev);
        (*plugin)->Release(plugin);

        if (!dev) {
            // Never fall through to the NEXT enclosure when a specific one was
            // requested — that would silently rebind a destructive command.
            if (deviceIndex >= 0) {
                fprintf(stderr, "Error: Could not query SCSI interface for --disk %d\n", deviceIndex);
                IOObjectRelease(iter);
                return NULL;
            }
            continue;
        }

        // Obtain exclusive access (required for sending SCSI commands)
        kr = (*dev)->ObtainExclusiveAccess(dev);
        if (kr != kIOReturnSuccess) {
            fprintf(stderr,
                "Error: Cannot get exclusive access (IOKit 0x%08x).\n"
                "  - Quit WD Discovery / WD Drive Utilities / WD Security if running\n"
                "    (or: killall WDDriveUtilityHelper WDSecurityHelper)\n"
                "  - Retry with sudo\n", kr);
            (*dev)->Release(dev);
            IOObjectRelease(iter);
            return NULL;
        }

        g_selectedEnclosureID = enclosureID;
        g_selectedLUN = (lun >= 0) ? (UInt8)lun : 1;   // SES is LUN 1 when the property is missing
        IOObjectRelease(iter);
        return dev;
    }

    IOObjectRelease(iter);
    if (deviceIndex > 0 && found <= deviceIndex && found > 0)
        fprintf(stderr, "Error: --disk %d requested but only %d WD device(s) found.\n", deviceIndex, found);
    return NULL;
}

/// Locate the WD disk LUN nub. If an SES device has been opened, only the
/// sibling under the same parent driver is accepted.
io_service_t WDFindDiskLUNService(void) {
    io_iterator_t iter;
    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS)
        return IO_OBJECT_NULL;

    io_service_t service, result = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        if (classifyNub(service, NULL) != kLUNDisk) { IOObjectRelease(service); continue; }
        if (g_selectedEnclosureID && parentEntryID(service) != g_selectedEnclosureID) {
            IOObjectRelease(service); continue;
        }
        result = service;   // transfer ownership to caller
        break;
    }
    IOObjectRelease(iter);
    return result;
}

/// List all connected WD enclosures. Index order matches --disk N.
int WDListDevices(void) {
    io_iterator_t iter;
    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) return 0;

    // Collect SES nubs (in enumeration order) and disk info keyed by parent ID
    NSMutableArray<NSNumber *> *sesParents = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSString *> *diskProduct = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSString *> *diskBSD = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSString *> *diskSerial = [NSMutableDictionary dictionary];

    io_service_t service;
    while ((service = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        NSString *product = nil;
        LUNKind kind = classifyNub(service, &product);
        NSNumber *pid = @(parentEntryID(service));
        if (kind == kLUNSES) {
            [sesParents addObject:pid];
        } else if (kind == kLUNDisk) {
            diskProduct[pid] = product;
            NSString *bsd = bsdNameUnder(service);
            if (bsd) diskBSD[pid] = bsd;
            NSString *sn = regString(service, CFSTR("USB Serial Number"));
            if (sn) diskSerial[pid] = decodeWDSerial(sn);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);

    for (NSUInteger i = 0; i < sesParents.count; i++) {
        NSNumber *pid = sesParents[i];
        NSString *name = diskProduct[pid] ?: @"Unknown";
        NSString *bsd = diskBSD[pid];
        NSString *sn = diskSerial[pid];
        printf("  [%lu] %-24s %-12s %s\n", (unsigned long)i, [name UTF8String],
               bsd ? [[@"/dev/" stringByAppendingString:bsd] UTF8String] : "(no disk)",
               sn ? [sn UTF8String] : "");
    }
    return (int)sesParents.count;
}

/// Release device resources. Call when done with all commands.
void WDCloseDevice(SCSITaskDeviceInterface **dev) {
    (*dev)->ReleaseExclusiveAccess(dev);
    (*dev)->Release(dev);
}

#pragma mark - Disk LUN BSD Name

#pragma mark - Unmount

BOOL WDUnmountDisk(NSString *bsdName) {
    if (!bsdName) return NO;
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) return NO;
    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    NSString *path = [NSString stringWithFormat:@"/dev/%@", bsdName];
    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, [path UTF8String]);
    BOOL issued = NO;
    if (disk) {
        DADiskUnmount(disk, kDADiskUnmountOptionWhole | kDADiskUnmountOptionForce, NULL, NULL);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.0, false);
        CFRelease(disk);
        issued = YES;
    }
    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(session);
    return issued;
}

/// Find the BSD name (e.g. "disk12") of the bound WD disk LUN.
NSString *WDFindDiskBSDNameFromIOKit(void) {
    io_service_t disk = WDFindDiskLUNService();
    if (disk == IO_OBJECT_NULL) return nil;
    NSString *bsd = bsdNameUnder(disk);
    IOObjectRelease(disk);
    return bsd;
}

WDDiskBSDNameFn g_diskBSDName = WDFindDiskBSDNameFromIOKit;
