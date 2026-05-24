//
// wd_smart.m
// wd-smart-reader
//
// A macOS CLI tool for reading SMART data and running diagnostics on
// Western Digital external drives (MyBook, Elements, etc.).
//
// Works by sending SCSI commands through the WD USB bridge's SES
// (SCSI Enclosure Services) interface, bypassing the bridge's normal
// blocking of ATA SMART passthrough.
//
// Requires root privileges for IOKit exclusive SCSI device access.
//
// License: MIT
//

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/scsi/SCSITaskLib.h>
#import <sys/disk.h>
#import <fcntl.h>
#import <unistd.h>
#import <math.h>

// ---------------------------------------------------------------------------
// MARK: - Constants
// ---------------------------------------------------------------------------

/// WD-specific SCSI diagnostic page codes (via RECEIVE DIAGNOSTIC RESULTS)
enum {
    kWDDiagPageEncryptionStatus = 0x83,
    kWDDiagPageSmartStatus      = 0x84,
    kWDDiagPageSmartData        = 0x85,
    kWDDiagPageTemperature      = 0x86,
};

/// SCSI self-test codes (used with SEND DIAGNOSTIC)
enum {
    kSelfTestShort  = 1,
    kSelfTestExtend = 2,
    kSelfTestAbort  = 4,
};

/// SCSI command timeouts (milliseconds)
enum {
    kTimeoutDefault = 10000,
    kTimeoutLong    = 30000,
    kTimeoutShort   = 5000,
};

// ---------------------------------------------------------------------------
// MARK: - Data Structures
// ---------------------------------------------------------------------------

/// SCSI Diagnostic Page 0x84: SMART threshold status
typedef struct __attribute__((packed)) {
    UInt8  pageCode;
    UInt8  reserved;
    UInt8  pageLength[2];
    UInt8  driveID;
    UInt8  statusMSB;
    UInt8  statusLSB;
} WDSmartStatusPage;

/// SCSI Diagnostic Page 0x85: Raw SMART attribute data (512 bytes)
typedef struct __attribute__((packed)) {
    UInt8  pageCode;
    UInt8  reserved1;
    UInt8  pageLength[2];
    UInt8  driveID;
    UInt8  reserved2[3];
    UInt8  smartData[512];
} WDSmartDataPage;

/// Single SMART attribute (12 bytes, ATA spec)
typedef struct __attribute__((packed)) {
    UInt8  id;
    UInt16 flags;
    UInt8  current;
    UInt8  worst;
    UInt8  raw[6];
    UInt8  reserved;
} WDSmartAttribute;

/// SMART attribute table (begins with 2-byte revision, then 30 entries)
typedef struct __attribute__((packed)) {
    UInt16          revision;
    WDSmartAttribute attrs[30];
} WDSmartAttributeTable;

/// SCSI Diagnostic Page 0x86: Temperature and fan status
typedef struct __attribute__((packed)) {
    UInt8   pageCode;
    UInt8   reserved1;
    UInt16  pageLength;
    UInt8   condition;   // lower 2 bits: 0=normal, 1=warm, 2=hot
    UInt8   reserved2;
    UInt16  fanRPM;
    UInt16  fanGoalPWM;
    UInt16  fanCurrentPWM;
} WDTemperaturePage;

// ---------------------------------------------------------------------------
// MARK: - SMART Attribute Name Lookup
// ---------------------------------------------------------------------------

static const char *smartAttrName(UInt8 id) {
    switch (id) {
        case 1:   return "Raw Read Error Rate";
        case 2:   return "Throughput Performance";
        case 3:   return "Spin Up Time";
        case 4:   return "Start/Stop Count";
        case 5:   return "Reallocated Sectors Count";
        case 7:   return "Seek Error Rate";
        case 8:   return "Seek Time Performance";
        case 9:   return "Power-On Hours";
        case 10:  return "Spin Retry Count";
        case 11:  return "Calibration Retry Count";
        case 12:  return "Power Cycle Count";
        case 22:  return "Current Helium Level";
        case 183: return "SATA Downshift Error Count";
        case 184: return "End-to-End Error";
        case 187: return "Reported Uncorrectable Errors";
        case 188: return "Command Timeout";
        case 189: return "High Fly Writes";
        case 190: return "Airflow Temperature";
        case 191: return "G-Sense Error Rate";
        case 192: return "Power-Off Retract Count";
        case 193: return "Load Cycle Count";
        case 194: return "Temperature";
        case 195: return "Hardware ECC Recovered";
        case 196: return "Reallocation Event Count";
        case 197: return "Current Pending Sector Count";
        case 198: return "Offline Uncorrectable";
        case 199: return "UDMA CRC Error Count";
        case 200: return "Multi-Zone Error Rate";
        default:  return "Vendor Specific";
    }
}

// ---------------------------------------------------------------------------
// MARK: - Low-Level SCSI Transport
// ---------------------------------------------------------------------------

/// Execute a SCSI task with the given CDB, returning 0 on success.
/// Handles task creation, scatter-gather setup, execution, and cleanup.
static int execSCSITask(SCSITaskDeviceInterface **dev,
                        SCSICommandDescriptorBlock cdb,
                        UInt8 cdbSize,
                        void *buffer,
                        UInt32 bufferSize,
                        UInt8 direction,
                        UInt32 timeout) {
    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) return -1;

    IOVirtualRange range = { .address = (IOVirtualAddress)buffer, .length = bufferSize };

    (*task)->SetCommandDescriptorBlock(task, cdb, cdbSize);

    if (buffer && bufferSize > 0) {
        (*task)->SetScatterGatherEntries(task, &range, 1, bufferSize, direction);
    } else {
        (*task)->SetScatterGatherEntries(task, NULL, 0, 0, kSCSIDataTransfer_NoDataTransfer);
    }

    (*task)->SetTimeoutDuration(task, timeout);

    SCSI_Sense_Data sense = {0};
    SCSITaskStatus status;
    UInt64 transferred = 0;
    IOReturn result = (*task)->ExecuteTaskSync(task, &sense, &status, &transferred);
    (*task)->Release(task);

    if (result != kIOReturnSuccess) return -2;
    if (status != kSCSITaskStatus_GOOD) return -3;
    return 0;
}

// ---------------------------------------------------------------------------
// MARK: - SCSI Command Wrappers
// ---------------------------------------------------------------------------

/// RECEIVE DIAGNOSTIC RESULTS (opcode 0x1C) — reads a diagnostic page.
static int scsiReceiveDiagnostic(SCSITaskDeviceInterface **dev, UInt8 page, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x1C;                    // RECEIVE DIAGNOSTIC RESULTS
    cdb[1] = 0x01;                    // PCV (page code valid)
    cdb[2] = page;                    // page code
    cdb[3] = (size >> 8) & 0xFF;      // allocation length MSB
    cdb[4] = size & 0xFF;             // allocation length LSB
    return execSCSITask(dev, cdb, kSCSICDBSize_6Byte, buf, size,
                        kSCSIDataTransfer_FromTargetToInitiator, kTimeoutDefault);
}

/// SEND DIAGNOSTIC (opcode 0x1D) — initiates a self-test.
static int scsiSendDiagnosticSelfTest(SCSITaskDeviceInterface **dev, UInt8 testCode) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x1D;                    // SEND DIAGNOSTIC
    cdb[1] = (testCode << 5) | 0x04;  // self-test code in bits 7:5, SelfTest bit
    return execSCSITask(dev, cdb, kSCSICDBSize_6Byte, NULL, 0,
                        kSCSIDataTransfer_NoDataTransfer, kTimeoutLong);
}

/// SEND DIAGNOSTIC (opcode 0x1D) with parameter data — sends a diagnostic page.
static int scsiSendDiagnosticPage(SCSITaskDeviceInterface **dev, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x1D;                    // SEND DIAGNOSTIC
    cdb[1] = 0x10;                    // PF (page format)
    cdb[3] = (size >> 8) & 0xFF;      // parameter list length MSB
    cdb[4] = size & 0xFF;             // parameter list length LSB
    return execSCSITask(dev, cdb, kSCSICDBSize_6Byte, buf, size,
                        kSCSIDataTransfer_FromInitiatorToTarget, kTimeoutDefault);
}

/// LOG SENSE (opcode 0x4D) — reads a log page.
static int scsiLogSense(SCSITaskDeviceInterface **dev, UInt8 page, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x4D;                    // LOG SENSE
    cdb[2] = 0x40 | page;            // PC=01 (current cumulative) | page code
    cdb[7] = (size >> 8) & 0xFF;      // allocation length MSB
    cdb[8] = size & 0xFF;             // allocation length LSB
    return execSCSITask(dev, cdb, kSCSICDBSize_10Byte, buf, size,
                        kSCSIDataTransfer_FromTargetToInitiator, kTimeoutDefault);
}

/// MODE SENSE (6) (opcode 0x1A) — reads a mode page.
static int scsiModeSense(SCSITaskDeviceInterface **dev, UInt8 page, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x1A;                    // MODE SENSE (6)
    cdb[1] = 0x08;                    // DBD (disable block descriptors)
    cdb[2] = page;                    // page code
    cdb[4] = size & 0xFF;             // allocation length
    return execSCSITask(dev, cdb, kSCSICDBSize_6Byte, buf, size,
                        kSCSIDataTransfer_FromTargetToInitiator, kTimeoutDefault);
}

/// MODE SELECT (6) (opcode 0x15) — writes a mode page.
static int scsiModeSelect(SCSITaskDeviceInterface **dev, void *buf, UInt32 size, BOOL save) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x15;                    // MODE SELECT (6)
    cdb[1] = 0x10 | (save ? 0x01 : 0x00); // PF (page format) + SP (save pages)
    cdb[4] = size & 0xFF;             // parameter list length
    return execSCSITask(dev, cdb, kSCSICDBSize_6Byte, buf, size,
                        kSCSIDataTransfer_FromInitiatorToTarget, kTimeoutDefault);
}

/// INQUIRY (opcode 0x12) — standard inquiry data.
static int scsiInquiry(SCSITaskDeviceInterface **dev, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x12;                    // INQUIRY
    cdb[3] = (size >> 8) & 0xFF;      // allocation length MSB
    cdb[4] = size & 0xFF;             // allocation length LSB
    return execSCSITask(dev, cdb, kSCSICDBSize_6Byte, buf, size,
                        kSCSIDataTransfer_FromTargetToInitiator, kTimeoutShort);
}

/// INQUIRY with EVPD (opcode 0x12) — vital product data page.
static int scsiInquiryVPD(SCSITaskDeviceInterface **dev, UInt8 page, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x12;                    // INQUIRY
    cdb[1] = 0x01;                    // EVPD (enable vital product data)
    cdb[2] = page;                    // page code
    cdb[3] = (size >> 8) & 0xFF;      // allocation length MSB
    cdb[4] = size & 0xFF;             // allocation length LSB
    return execSCSITask(dev, cdb, kSCSICDBSize_6Byte, buf, size,
                        kSCSIDataTransfer_FromTargetToInitiator, kTimeoutShort);
}

// ---------------------------------------------------------------------------
// MARK: - Device Discovery
// ---------------------------------------------------------------------------

/// Finds the first WD SES (SCSI Enclosure Services) device via IOKit.
///
/// WD external enclosures expose two SCSI LUNs: the disk itself and an SES
/// management device. The SES device is the one that accepts diagnostic page
/// commands for SMART data retrieval.
///
/// Returns an exclusive-access SCSITaskDeviceInterface, or NULL on failure.
/// Caller must release exclusive access and the interface when done.
static SCSITaskDeviceInterface **openWDDevice(char *nameOut, size_t nameSize) {
    io_iterator_t iter;
    io_service_t service;

    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) return NULL;

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

/// Release device resources. Call when done with all commands.
static void closeWDDevice(SCSITaskDeviceInterface **dev) {
    (*dev)->ReleaseExclusiveAccess(dev);
    (*dev)->Release(dev);
}

// ---------------------------------------------------------------------------
// MARK: - Helpers
// ---------------------------------------------------------------------------

/// Extract a 48-bit raw value from a SMART attribute's 6-byte raw field.
static UInt64 smartRawValue(const WDSmartAttribute *attr) {
    UInt64 val = 0;
    for (int i = 0; i < 6; i++)
        val |= ((UInt64)attr->raw[i]) << (i * 8);
    return val;
}

/// Self-test result code to human-readable string.
static const char *selfTestResultString(UInt8 code) {
    switch (code) {
        case 0:  return "Completed OK";
        case 1:  return "Aborted (self)";
        case 2:  return "Aborted (user)";
        case 3:  return "Unknown error";
        case 4:  return "Unknown element";
        case 5:  return "Electrical fail";
        case 6:  return "Servo fail";
        case 7:  return "Read fail";
        case 8:  return "Handling damage";
        case 15: return "In progress...";
        default: return "Reserved";
    }
}

// ---------------------------------------------------------------------------
// MARK: - Commands
// ---------------------------------------------------------------------------

/// Display SMART attributes table.
static void cmdSmart(SCSITaskDeviceInterface **dev) {
    // Read SMART threshold status (page 0x84)
    WDSmartStatusPage statusPage = {0};
    if (scsiReceiveDiagnostic(dev, kWDDiagPageSmartStatus, &statusPage, sizeof(statusPage)) == 0) {
        UInt16 status = ((UInt16)statusPage.statusMSB << 8) | statusPage.statusLSB;
        printf("SMART Status: %s (0x%04X)\n\n",
               status == 0 ? "PASSED" : "CHECK (see attributes)", status);
    }

    // Read full SMART attribute data (page 0x85)
    WDSmartDataPage dataPage = {0};
    if (scsiReceiveDiagnostic(dev, kWDDiagPageSmartData, &dataPage, sizeof(dataPage)) != 0) {
        fprintf(stderr, "Error: Could not read SMART data\n");
        return;
    }

    printf("%-4s %-35s %7s %7s %s\n", "ID#", "ATTRIBUTE_NAME", "VALUE", "WORST", "RAW_VALUE");

    WDSmartAttributeTable *table = (WDSmartAttributeTable *)dataPage.smartData;
    for (int i = 0; i < 30; i++) {
        WDSmartAttribute *a = &table->attrs[i];
        if (a->id == 0) continue;
        printf("%-4d %-35s %7d %7d %llu\n",
               a->id, smartAttrName(a->id), a->current, a->worst, smartRawValue(a));
    }
}

/// Display drive identity, serial, capacity, RPM, interface, encryption.
static void cmdInfo(SCSITaskDeviceInterface **dev) {
    // Standard INQUIRY: vendor, product, firmware revision
    UInt8 inq[96] = {0};
    if (scsiInquiry(dev, inq, sizeof(inq)) == 0) {
        char vendor[9] = {0}, product[17] = {0}, firmware[5] = {0};
        memcpy(vendor, &inq[8], 8);
        memcpy(product, &inq[16], 16);
        memcpy(firmware, &inq[32], 4);
        printf("Vendor:   %s\n", vendor);
        printf("Product:  %s\n", product);
        printf("Firmware: %s\n", firmware);
    }

    // VPD page 0x80: Unit serial number
    UInt8 snBuf[40] = {0};
    if (scsiInquiryVPD(dev, 0x80, snBuf, sizeof(snBuf)) == 0) {
        UInt8 len = snBuf[3];
        if (len > 32) len = 32;
        char serial[33] = {0};
        memcpy(serial, &snBuf[4], len);
        printf("Serial:   %s\n", serial);
    }

    // VPD page 0xB1: Block device characteristics (RPM, form factor)
    UInt8 bdc[64] = {0};
    if (scsiInquiryVPD(dev, 0xB1, bdc, sizeof(bdc)) == 0) {
        UInt16 rpm = ((UInt16)bdc[4] << 8) | bdc[5];
        UInt8 formFactor = bdc[7] & 0x0F;

        printf("RPM:      %s\n", rpm > 0
            ? [[NSString stringWithFormat:@"%d", rpm] UTF8String]
            : "Non-rotating (SSD)");

        const char *ffStr;
        switch (formFactor) {
            case 1: ffStr = "5.25\""; break;
            case 2: ffStr = "3.5\"";  break;
            case 3: ffStr = "2.5\"";  break;
            case 4: ffStr = "1.8\"";  break;
            default: ffStr = "Unknown"; break;
        }
        printf("Form:     %s\n", ffStr);
    }

    // VPD page 0xC2: WD raw capacity (total blocks, block size, bay count)
    UInt8 cap[24] = {0};
    if (scsiInquiryVPD(dev, 0xC2, cap, sizeof(cap)) == 0) {
        UInt8 maxDisks = cap[6];
        UInt8 installed = cap[7];

        UInt64 blocks = 0;
        for (int i = 0; i < 8; i++) blocks = (blocks << 8) | cap[8 + i];

        UInt32 blockSize = ((UInt32)cap[16] << 24) | ((UInt32)cap[17] << 16)
                         | ((UInt32)cap[18] << 8)  | cap[19];

        double tb = (double)blocks * blockSize / 1e12;
        printf("Capacity: %.2f TB (%llu blocks x %u bytes)\n", tb, blocks, blockSize);

        if (maxDisks > 1)
            printf("Bays:     %d/%d installed\n", installed, maxDisks);
    }

    // VPD page 0xC1: Active interfaces (USB3, USB2, etc.)
    UInt8 ai[24] = {0};
    if (scsiInquiryVPD(dev, 0xC1, ai, sizeof(ai)) == 0) {
        UInt16 pageLen = ((UInt16)ai[2] << 8) | ai[3];
        int numPorts = pageLen / 8;
        printf("Port:     ");
        for (int i = 0; i < numPorts && i < 4; i++) {
            UInt8 *port = &ai[4 + i * 8];
            BOOL active = port[0] & 0x01;
            char type[8] = {0};
            memcpy(type, &port[1], 7);
            printf("%s%s", type, active ? " (active)" : "");
            if (i < numPorts - 1) printf(", ");
        }
        printf("\n");
    }

    // Diagnostic page 0x83: Encryption status
    UInt8 enc[8] = {0};
    if (scsiReceiveDiagnostic(dev, kWDDiagPageEncryptionStatus, enc, sizeof(enc)) == 0) {
        const char *state;
        switch (enc[4]) {
            case 0: state = "Off";                    break;
            case 1: state = "Locked";                 break;
            case 2: state = "Unlocked";               break;
            case 6: state = "Max unlocks exceeded";   break;
            case 7: state = "No DEK";                 break;
            default: state = "Unknown";               break;
        }
        printf("Encrypt:  %s\n", state);
    }
}

/// Start a short self-test (~2 minutes).
static void cmdShortTest(SCSITaskDeviceInterface **dev) {
    if (scsiSendDiagnosticSelfTest(dev, kSelfTestShort) == 0)
        printf("Short self-test started (~2 minutes).\nRun 'wd_smart status' to check progress.\n");
    else
        fprintf(stderr, "Error: Could not start short test\n");
}

/// Start an extended self-test (full surface scan, hours on large drives).
static void cmdLongTest(SCSITaskDeviceInterface **dev) {
    if (scsiSendDiagnosticSelfTest(dev, kSelfTestExtend) == 0)
        printf("Extended self-test started (may take many hours on large drives).\n"
               "Run 'wd_smart status' to check progress.\n");
    else
        fprintf(stderr, "Error: Could not start extended test\n");
}

/// Abort a running self-test.
static void cmdAbortTest(SCSITaskDeviceInterface **dev) {
    if (scsiSendDiagnosticSelfTest(dev, kSelfTestAbort) == 0)
        printf("Self-test aborted.\n");
    else
        fprintf(stderr, "Error: Could not abort test\n");
}

/// Display self-test results log (LOG SENSE page 0x10).
static void cmdStatus(SCSITaskDeviceInterface **dev) {
    UInt8 buf[404] = {0};
    if (scsiLogSense(dev, 0x10, buf, sizeof(buf)) != 0) {
        fprintf(stderr, "Error: Could not read self-test log\n");
        return;
    }

    UInt16 pageLen = ((UInt16)buf[2] << 8) | buf[3];
    if (pageLen < 20) {
        printf("No self-test results available.\n");
        return;
    }

    printf("%-6s %-14s %-8s %s\n", "TEST#", "RESULT", "HOURS", "FIRST_ERROR_LBA");

    int entries = pageLen / 20;
    if (entries > 20) entries = 20;

    for (int i = 0; i < entries; i++) {
        UInt8 *entry = &buf[4 + i * 20];
        UInt8 result  = entry[4] & 0x0F;
        UInt8 testNum = entry[5];
        UInt16 hours  = ((UInt16)entry[6] << 8) | entry[7];

        // Skip empty entries
        if (result == 0 && testNum == 0 && hours == 0) continue;

        UInt64 lba = 0;
        for (int j = 0; j < 8; j++) lba = (lba << 8) | entry[8 + j];

        printf("%-6d %-14s %-8d %s\n",
               testNum, selfTestResultString(result), hours,
               (result >= 3 && result <= 8)
                   ? [[NSString stringWithFormat:@"%llu", lba] UTF8String]
                   : "-");
    }
}

/// Display drive temperature (from SMART attribute 194 and/or diag page 0x86).
static void cmdTemp(SCSITaskDeviceInterface **dev) {
    // Try WD-specific temperature diagnostic page
    WDTemperaturePage tempPage = {0};
    if (scsiReceiveDiagnostic(dev, kWDDiagPageTemperature, &tempPage, sizeof(tempPage)) == 0) {
        UInt8 cond = tempPage.condition & 0x03;
        const char *condStr;
        switch (cond) {
            case 0: condStr = "Normal"; break;
            case 1: condStr = "Warm";   break;
            case 2: condStr = "Hot";    break;
            default: condStr = "Unknown"; break;
        }
        printf("Thermal:  %s\n", condStr);

        UInt16 rpm = ntohs(tempPage.fanRPM);
        if (rpm > 0) printf("Fan RPM:  %d\n", rpm);

        UInt16 pwm = ntohs(tempPage.fanCurrentPWM);
        if (pwm > 0) printf("Fan PWM:  %d / %d (current / goal)\n", pwm, ntohs(tempPage.fanGoalPWM));
    }

    // Get temperature from SMART attribute 194 (most reliable)
    WDSmartDataPage dataPage = {0};
    if (scsiReceiveDiagnostic(dev, kWDDiagPageSmartData, &dataPage, sizeof(dataPage)) == 0) {
        WDSmartAttributeTable *table = (WDSmartAttributeTable *)dataPage.smartData;
        for (int i = 0; i < 30; i++) {
            if (table->attrs[i].id == 194) {
                printf("Drive:    %llu°C\n", smartRawValue(&table->attrs[i]) & 0xFF);
                return;
            }
        }
    }
}

/// Get or set the drive sleep (spindown) timer.
/// When setValue is NULL, displays current setting. Otherwise sets it.
static void cmdSleep(SCSITaskDeviceInterface **dev, const char *setValue) {
    // Power Condition mode page (0x1A)
    UInt8 buf[40] = {0};
    if (scsiModeSense(dev, 0x1A, buf, sizeof(buf)) != 0) {
        fprintf(stderr, "Error: Could not read sleep timer\n");
        return;
    }

    if (!setValue) {
        // Standby timer is a 4-byte value in 100ms units, at page offset 6-9
        // (after 4-byte mode header + 2-byte page header)
        UInt8 pageLen = buf[5];
        UInt32 timer = 0;
        if (pageLen >= 10) {
            timer = ((UInt32)buf[10] << 24) | ((UInt32)buf[11] << 16)
                  | ((UInt32)buf[12] << 8)  | buf[13];
        }
        if (timer == 0)
            printf("Sleep timer: disabled (never)\n");
        else
            printf("Sleep timer: ~%u minutes (%u seconds)\n", timer / 600, timer / 10);
    } else {
        int minutes = atoi(setValue);
        UInt32 timerVal = (minutes <= 0) ? 0 : (UInt32)minutes * 600;

        // Clear mode parameter header (required for MODE SELECT)
        memset(buf, 0, 4);
        buf[4] &= 0x3F;  // clear PS (parameters saveable) bit

        // Write new standby timer value
        buf[10] = (timerVal >> 24) & 0xFF;
        buf[11] = (timerVal >> 16) & 0xFF;
        buf[12] = (timerVal >> 8)  & 0xFF;
        buf[13] = timerVal & 0xFF;

        if (scsiModeSelect(dev, buf, 18, YES) == 0) {
            if (minutes <= 0)
                printf("Sleep timer disabled.\n");
            else
                printf("Sleep timer set to %d minutes.\n", minutes);
        } else {
            fprintf(stderr, "Error: Could not set sleep timer\n");
        }
    }
}

/// Safely power off the drive (spin down + disconnect).
/// After this command, the drive can be physically unplugged.
static void cmdPowerOff(SCSITaskDeviceInterface **dev) {
    // WD power control via diagnostic page 0x80
    UInt8 page[8] = {0};
    page[0] = 0x80;   // page code
    page[3] = 0x04;   // page length
    page[4] = 0x01;   // bit 0 = PowerOff

    if (scsiSendDiagnosticPage(dev, page, sizeof(page)) == 0)
        printf("Drive powered off safely. You can disconnect it now.\n");
    else
        fprintf(stderr, "Error: Power off failed. Try 'diskutil eject /dev/diskN' instead.\n");
}

/// Erase the drive by sending the WD FORMAT DISK vendor command (0xC4).
/// This is IRREVERSIBLE. Requires --confirm flag and shows a countdown.
static void cmdErase(SCSITaskDeviceInterface **dev, int argc, const char *argv[]) {
    // Require explicit --confirm flag
    BOOL confirmed = NO;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--confirm") == 0) confirmed = YES;
    }

    if (!confirmed) {
        fprintf(stderr,
            "WARNING: This will PERMANENTLY ERASE ALL DATA on the drive.\n"
            "         This operation is IRREVERSIBLE.\n\n"
            "To proceed, run:\n"
            "  sudo wd_smart erase --confirm\n");
        return;
    }

    // 5-second countdown giving the user a chance to Ctrl-C
    fprintf(stderr, "*** ALL DATA WILL BE DESTROYED ***\n");
    fprintf(stderr, "Press Ctrl-C to cancel.\n\n");
    for (int i = 5; i > 0; i--) {
        fprintf(stderr, "  Erasing in %d...\n", i);
        sleep(1);
    }

    // WD vendor-specific FORMAT DISK command (opcode 0xC4)
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0xC4;  // FORMAT DISK (WD vendor-specific)

    int r = execSCSITask(dev, cdb, kSCSICDBSize_10Byte, NULL, 0,
                         kSCSIDataTransfer_NoDataTransfer, kTimeoutLong);

    if (r == 0)
        printf("Erase command sent. Drive is formatting.\n"
               "This may take a long time. Do not disconnect the drive.\n");
    else
        fprintf(stderr, "Error: Erase command failed (%d)\n", r);
}

/// Find the BSD name (e.g. "disk12") of the WD disk LUN (not the SES device).
static NSString *findWDDiskBSDName(void) {
    io_iterator_t iter;
    io_service_t service;

    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) return nil;

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

        // Skip the SES device — we want the actual disk LUN
        NSString *tp = product
            ? [product stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
            : @"";
        if ([tp containsString:@"SES"]) { IOObjectRelease(service); continue; }

        // Walk children to find the whole-disk IOMedia node
        io_iterator_t childIter;
        kr = IORegistryEntryCreateIterator(service, kIOServicePlane,
            kIORegistryIterateRecursively, &childIter);
        IOObjectRelease(service);
        if (kr != KERN_SUCCESS) continue;

        io_service_t child;
        while ((child = IOIteratorNext(childIter)) != IO_OBJECT_NULL) {
            io_name_t className;
            IOObjectGetClass(child, className);
            if (strcmp(className, "IOMedia") == 0) {
                CFTypeRef wholeRef = IORegistryEntryCreateCFProperty(
                    child, CFSTR("Whole"), kCFAllocatorDefault, 0);
                if (wholeRef && CFBooleanGetValue(wholeRef)) {
                    CFTypeRef bsdRef = IORegistryEntryCreateCFProperty(
                        child, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
                    if (bsdRef) {
                        NSString *bsd = (__bridge_transfer NSString *)bsdRef;
                        CFRelease(wholeRef);
                        IOObjectRelease(child);
                        IOObjectRelease(childIter);
                        IOObjectRelease(iter);
                        return bsd;
                    }
                }
                if (wholeRef) CFRelease(wholeRef);
            }
            IOObjectRelease(child);
        }
        IOObjectRelease(childIter);
    }
    IOObjectRelease(iter);
    return nil;
}

/// Secure erase: overwrite every sector with zeros.
/// This is a full single-pass zero-fill — every byte on disk becomes 0x00.
/// Requires --confirm and gives a 10-second countdown before starting.
static void cmdSecureErase(int argc, const char *argv[]) {
    BOOL confirmed = NO;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--confirm") == 0) confirmed = YES;
    }

    if (!confirmed) {
        fprintf(stderr,
            "WARNING: SECURE ERASE writes zeros to EVERY SECTOR on the drive.\n"
            "         This is IRREVERSIBLE and will take 20+ hours on 18TB.\n\n"
            "To proceed, run:\n"
            "  sudo wd_smart secure-erase --confirm\n");
        return;
    }

    // Find the WD disk's BSD name
    NSString *bsdName = findWDDiskBSDName();
    if (!bsdName) {
        fprintf(stderr, "Error: Could not find WD disk device\n");
        return;
    }

    printf("Target: /dev/%s\n\n", [bsdName UTF8String]);

    // 10-second countdown (longer due to severity)
    fprintf(stderr, "*** SECURE ERASE: EVERY BYTE WILL BE OVERWRITTEN WITH ZEROS ***\n");
    fprintf(stderr, "*** This will take many hours. Press Ctrl-C to cancel. ***\n\n");
    for (int i = 10; i > 0; i--) {
        fprintf(stderr, "  Starting in %d...\n", i);
        sleep(1);
    }

    // Unmount all volumes
    NSString *unmountCmd = [NSString stringWithFormat:@"diskutil unmountDisk /dev/%@", bsdName];
    if (system([unmountCmd UTF8String]) != 0) {
        fprintf(stderr, "Error: Could not unmount disk. Aborting.\n");
        return;
    }

    // Open raw character device for writing
    NSString *rawPath = [NSString stringWithFormat:@"/dev/r%@", bsdName];
    int fd = open([rawPath UTF8String], O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "Error: Could not open %s: %s\n",
                [rawPath UTF8String], strerror(errno));
        return;
    }

    // Get device size via ioctl
    UInt64 blockCount = 0;
    UInt32 blockSize = 512;
    ioctl(fd, DKIOCGETBLOCKCOUNT, &blockCount);
    ioctl(fd, DKIOCGETBLOCKSIZE, &blockSize);
    UInt64 deviceSize = blockCount * blockSize;

    // Write zeros in 1MB chunks with progress reporting
    const size_t chunkSize = 1024 * 1024;
    void *zeros = calloc(1, chunkSize);
    if (!zeros) { close(fd); fprintf(stderr, "Error: Out of memory\n"); return; }

    UInt64 written = 0;
    time_t startTime = time(NULL);
    time_t lastReport = 0;
    ssize_t n;

    printf("\nSecure erase in progress...\n");

    while ((n = write(fd, zeros, chunkSize)) > 0) {
        written += n;

        time_t now = time(NULL);
        if (now - lastReport >= 5) {
            lastReport = now;
            double elapsed = difftime(now, startTime);
            double speed = (elapsed > 0) ? (double)written / elapsed / 1e6 : 0;

            if (deviceSize > 0) {
                double pct = (double)written / deviceSize * 100.0;
                double etaSec = (speed > 0) ? (double)(deviceSize - written) / (speed * 1e6) : 0;
                printf("\r  %5.1f%%  |  %.1f MB/s  |  ~%.0fh %02.0fm remaining    ",
                       pct, speed, etaSec / 3600, fmod(etaSec, 3600) / 60);
            } else {
                printf("\r  %.2f GB written  |  %.1f MB/s    ",
                       (double)written / 1e9, speed);
            }
            fflush(stdout);
        }
    }

    free(zeros);
    close(fd);

    double elapsed = difftime(time(NULL), startTime);
    printf("\n\nSecure erase complete.\n");
    printf("  Written: %.2f TB\n", (double)written / 1e12);
    printf("  Time:    %.1f hours\n", elapsed / 3600.0);
    if (elapsed > 0)
        printf("  Speed:   %.1f MB/s average\n", (double)written / elapsed / 1e6);
}

// ---------------------------------------------------------------------------
// MARK: - Main
// ---------------------------------------------------------------------------

static void usage(void) {
    fprintf(stderr,
        "Usage: wd_smart <command> [args]\n"
        "\n"
        "Commands:\n"
        "  smart          Read SMART attributes (default)\n"
        "  info           Drive identity, serial, RPM, capacity, encryption\n"
        "  short-test     Start short self-test (~2 min)\n"
        "  long-test      Start extended self-test (hours)\n"
        "  abort-test     Abort running self-test\n"
        "  status         Show self-test results log\n"
        "  temp           Show drive temperature and fan status\n"
        "  sleep [MIN]    Get or set sleep timer (0 = disable)\n"
        "  power-off      Safely spin down and power off drive\n"
        "  erase          Quick format via WD bridge (requires --confirm)\n"
        "  secure-erase   Zero-fill every sector (requires --confirm)\n"
        "\n"
        "Requires: sudo (root access needed for IOKit SCSI commands)\n"
    );
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const char *cmd = (argc > 1) ? argv[1] : "smart";

        if (strcmp(cmd, "-h") == 0 || strcmp(cmd, "--help") == 0 || strcmp(cmd, "help") == 0) {
            usage();
            return 0;
        }

        // Open the WD SES device
        char deviceName[256] = {0};
        SCSITaskDeviceInterface **dev = openWDDevice(deviceName, sizeof(deviceName));
        if (!dev) {
            fprintf(stderr, "Error: No WD device found or could not access it.\n");
            return 1;
        }
        printf("Device: %s\n\n", deviceName);
        fflush(stdout);

        // Dispatch command
        if      (strcmp(cmd, "smart") == 0)      cmdSmart(dev);
        else if (strcmp(cmd, "info") == 0)       cmdInfo(dev);
        else if (strcmp(cmd, "short-test") == 0) cmdShortTest(dev);
        else if (strcmp(cmd, "long-test") == 0)  cmdLongTest(dev);
        else if (strcmp(cmd, "abort-test") == 0) cmdAbortTest(dev);
        else if (strcmp(cmd, "status") == 0)     cmdStatus(dev);
        else if (strcmp(cmd, "temp") == 0)       cmdTemp(dev);
        else if (strcmp(cmd, "sleep") == 0)      cmdSleep(dev, argc > 2 ? argv[2] : NULL);
        else if (strcmp(cmd, "power-off") == 0)  cmdPowerOff(dev);
        else if (strcmp(cmd, "erase") == 0)     cmdErase(dev, argc, argv);
        else if (strcmp(cmd, "secure-erase") == 0) {
            closeWDDevice(dev);  // release SES before accessing disk LUN
            cmdSecureErase(argc, argv);
            return 0;
        }
        else {
            fprintf(stderr, "Unknown command: %s\n\n", cmd);
            usage();
            closeWDDevice(dev);
            return 1;
        }

        closeWDDevice(dev);
    }
    return 0;
}
