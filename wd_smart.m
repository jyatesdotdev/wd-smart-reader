#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/storage/ata/ATASMARTLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/scsi/SCSITaskLib.h>

#define SMART_STATUS_PAGE 0x84
#define SMART_DATA_PAGE   0x85

#pragma mark - Structs

typedef struct __attribute__((packed)){
    UInt8 PageCode;
    UInt8 reserved1;
    UInt8 PageLength[2];
    UInt8 DiagnosticDriveID;
    UInt8 SmartStatusMSB;
    UInt8 SmartStatusLSB;
} SmartStatusPage;

typedef struct __attribute__((packed)){
    UInt8 PageCode;
    UInt8 reserved1;
    UInt8 PageLength[2];
    UInt8 DiagnosticDriveID;
    UInt8 reserved2[3];
    UInt8 SmartData[512];
} SmartDataPage;

typedef struct __attribute__((packed)) {
    UInt8 attributeID;
    UInt16 flags;
    UInt8 current;
    UInt8 worst;
    UInt8 rawValue[6];
    UInt8 reserved;
} SMARTAttribute;

typedef struct __attribute__((packed)) {
    UInt16 revisionNumber;
    SMARTAttribute attributes[30];
} SMARTAttributeData;

typedef struct __attribute__((packed)){
    uint8_t pageCode;
    uint8_t reserved1;
    uint16_t pageLength;
    uint8_t temperatureCondition;
    uint8_t reserved3;
    uint16_t fanRPM;
    uint16_t fanGoalPWM;
    uint16_t currentFanPWM;
} TemperatureConditionData;

#pragma mark - SMART Attribute Names

static const char* smartAttributeName(UInt8 id) {
    switch(id) {
        case 1: return "Raw Read Error Rate";
        case 2: return "Throughput Performance";
        case 3: return "Spin Up Time";
        case 4: return "Start/Stop Count";
        case 5: return "Reallocated Sectors Count";
        case 7: return "Seek Error Rate";
        case 8: return "Seek Time Performance";
        case 9: return "Power-On Hours";
        case 10: return "Spin Retry Count";
        case 11: return "Calibration Retry Count";
        case 12: return "Power Cycle Count";
        case 22: return "Current Helium Level";
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
        default: return "Vendor Specific";
    }
}

#pragma mark - SCSI Helpers

static int sendReceiveDiagnostic(SCSITaskDeviceInterface **dev, UInt8 pageCode, void *buf, UInt32 bufSize) {
    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) return -1;

    IOVirtualRange range = { .address = (IOVirtualAddress)buf, .length = bufSize };
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x1C; // RECEIVE DIAGNOSTIC RESULTS
    cdb[1] = 0x01; // PCV
    cdb[2] = pageCode;
    cdb[3] = (bufSize >> 8) & 0xFF;
    cdb[4] = bufSize & 0xFF;

    (*task)->SetCommandDescriptorBlock(task, cdb, kSCSICDBSize_6Byte);
    (*task)->SetScatterGatherEntries(task, &range, 1, bufSize, kSCSIDataTransfer_FromTargetToInitiator);
    (*task)->SetTimeoutDuration(task, 10000);

    SCSI_Sense_Data sense = {0};
    SCSITaskStatus status;
    UInt64 xfer = 0;
    IOReturn r = (*task)->ExecuteTaskSync(task, &sense, &status, &xfer);
    (*task)->Release(task);

    if (r != kIOReturnSuccess) return -2;
    if (status != kSCSITaskStatus_GOOD) return -3;
    return 0;
}

static int sendDiagnostic(SCSITaskDeviceInterface **dev, UInt8 selfTestCode) {
    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) return -1;

    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x1D; // SEND DIAGNOSTIC
    cdb[1] = (selfTestCode << 5) | 0x04; // SelfTest bit + code
    cdb[2] = 0;
    cdb[3] = 0;
    cdb[4] = 0;
    cdb[5] = 0;

    (*task)->SetCommandDescriptorBlock(task, cdb, kSCSICDBSize_6Byte);
    (*task)->SetScatterGatherEntries(task, NULL, 0, 0, kSCSIDataTransfer_NoDataTransfer);
    (*task)->SetTimeoutDuration(task, 30000);

    SCSI_Sense_Data sense = {0};
    SCSITaskStatus status;
    UInt64 xfer = 0;
    IOReturn r = (*task)->ExecuteTaskSync(task, &sense, &status, &xfer);
    (*task)->Release(task);

    if (r != kIOReturnSuccess) return -2;
    if (status != kSCSITaskStatus_GOOD) return -3;
    return 0;
}

static int logSense(SCSITaskDeviceInterface **dev, UInt8 pageCode, void *buf, UInt32 bufSize) {
    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) return -1;

    IOVirtualRange range = { .address = (IOVirtualAddress)buf, .length = bufSize };
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x4D; // LOG SENSE
    cdb[1] = 0x00;
    cdb[2] = 0x40 | pageCode; // PC=01 (current cumulative), page code
    cdb[3] = 0x00;
    cdb[4] = 0x00;
    cdb[5] = 0x00;
    cdb[6] = 0x00;
    cdb[7] = (bufSize >> 8) & 0xFF;
    cdb[8] = bufSize & 0xFF;
    cdb[9] = 0x00;

    (*task)->SetCommandDescriptorBlock(task, cdb, kSCSICDBSize_10Byte);
    (*task)->SetScatterGatherEntries(task, &range, 1, bufSize, kSCSIDataTransfer_FromTargetToInitiator);
    (*task)->SetTimeoutDuration(task, 10000);

    SCSI_Sense_Data sense = {0};
    SCSITaskStatus status;
    UInt64 xfer = 0;
    IOReturn r = (*task)->ExecuteTaskSync(task, &sense, &status, &xfer);
    (*task)->Release(task);

    if (r != kIOReturnSuccess) return -2;
    if (status != kSCSITaskStatus_GOOD) return -3;
    return 0;
}

static int modeSense(SCSITaskDeviceInterface **dev, UInt8 pageCode, void *buf, UInt32 bufSize) {
    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) return -1;

    IOVirtualRange range = { .address = (IOVirtualAddress)buf, .length = bufSize };
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x1A; // MODE SENSE (6)
    cdb[1] = 0x08; // DBD
    cdb[2] = pageCode;
    cdb[3] = 0x00;
    cdb[4] = bufSize & 0xFF;
    cdb[5] = 0x00;

    (*task)->SetCommandDescriptorBlock(task, cdb, kSCSICDBSize_6Byte);
    (*task)->SetScatterGatherEntries(task, &range, 1, bufSize, kSCSIDataTransfer_FromTargetToInitiator);
    (*task)->SetTimeoutDuration(task, 10000);

    SCSI_Sense_Data sense = {0};
    SCSITaskStatus status;
    UInt64 xfer = 0;
    IOReturn r = (*task)->ExecuteTaskSync(task, &sense, &status, &xfer);
    (*task)->Release(task);

    if (r != kIOReturnSuccess) return -2;
    if (status != kSCSITaskStatus_GOOD) return -3;
    return 0;
}

static int modeSelect(SCSITaskDeviceInterface **dev, void *buf, UInt32 bufSize, BOOL save) {
    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) return -1;

    IOVirtualRange range = { .address = (IOVirtualAddress)buf, .length = bufSize };
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x15; // MODE SELECT (6)
    cdb[1] = 0x10 | (save ? 0x01 : 0x00); // PF + SP
    cdb[2] = 0x00;
    cdb[3] = 0x00;
    cdb[4] = bufSize & 0xFF;
    cdb[5] = 0x00;

    (*task)->SetCommandDescriptorBlock(task, cdb, kSCSICDBSize_6Byte);
    (*task)->SetScatterGatherEntries(task, &range, 1, bufSize, kSCSIDataTransfer_FromInitiatorToTarget);
    (*task)->SetTimeoutDuration(task, 10000);

    SCSI_Sense_Data sense = {0};
    SCSITaskStatus status;
    UInt64 xfer = 0;
    IOReturn r = (*task)->ExecuteTaskSync(task, &sense, &status, &xfer);
    (*task)->Release(task);

    if (r != kIOReturnSuccess) return -2;
    if (status != kSCSITaskStatus_GOOD) return -3;
    return 0;
}

#pragma mark - Device Discovery

static SCSITaskDeviceInterface** findWDSESDevice(char *nameBuf, size_t nameBufSize) {
    io_iterator_t iter;
    io_service_t svc;
    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) return NULL;

    while ((svc = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        CFTypeRef vRef = IORegistryEntrySearchCFProperty(svc, kIOServicePlane,
            CFSTR("Vendor Identification"), kCFAllocatorDefault,
            kIORegistryIterateRecursively | kIORegistryIterateParents);
        CFTypeRef pRef = IORegistryEntrySearchCFProperty(svc, kIOServicePlane,
            CFSTR("Product Identification"), kCFAllocatorDefault,
            kIORegistryIterateRecursively | kIORegistryIterateParents);

        NSString *vendor = vRef ? (__bridge_transfer NSString *)vRef : nil;
        NSString *product = pRef ? (__bridge_transfer NSString *)pRef : nil;
        if (!vendor) { IOObjectRelease(svc); continue; }

        NSString *tv = [vendor stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!([tv isEqualToString:@"WD"] || [tv isEqualToString:@"WDC"])) {
            IOObjectRelease(svc); continue;
        }

        // Prefer SES device for diagnostic commands
        NSString *tp = product ? [product stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
        if (![tp containsString:@"SES"]) { IOObjectRelease(svc); continue; }

        if (nameBuf && product) {
            snprintf(nameBuf, nameBufSize, "%s %s", [vendor UTF8String], [product UTF8String]);
        }

        IOCFPlugInInterface **plug = NULL;
        SInt32 score = 0;
        kr = IOCreatePlugInInterfaceForService(svc, kIOSCSITaskDeviceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plug, &score);
        IOObjectRelease(svc);

        if (kr != kIOReturnSuccess || !plug) continue;

        SCSITaskDeviceInterface **dev = NULL;
        (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID), (LPVOID *)&dev);
        (*plug)->Release(plug);

        if (!dev) continue;

        kr = (*dev)->ObtainExclusiveAccess(dev);
        if (kr != kIOReturnSuccess) {
            fprintf(stderr, "Error: Cannot get exclusive access (0x%x). Unmount drive or quit WD apps.\n", kr);
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

#pragma mark - Commands

static void cmdSmart(SCSITaskDeviceInterface **dev) {
    // Status
    SmartStatusPage sp = {0};
    if (sendReceiveDiagnostic(dev, SMART_STATUS_PAGE, &sp, sizeof(sp)) == 0) {
        UInt16 st = (sp.SmartStatusMSB << 8) | sp.SmartStatusLSB;
        printf("SMART Status: %s (0x%04X)\n\n", st == 0 ? "PASSED" : "CHECK (see attributes)", st);
    }

    // Attributes
    SmartDataPage dp = {0};
    if (sendReceiveDiagnostic(dev, SMART_DATA_PAGE, &dp, sizeof(dp)) != 0) {
        fprintf(stderr, "Error: Could not read SMART data\n"); return;
    }

    printf("%-4s %-35s %7s %7s %s\n", "ID#", "ATTRIBUTE_NAME", "VALUE", "WORST", "RAW_VALUE");
    SMARTAttributeData *sd = (SMARTAttributeData *)dp.SmartData;
    for (int i = 0; i < 30; i++) {
        SMARTAttribute *a = &sd->attributes[i];
        if (a->attributeID == 0) continue;
        UInt64 raw = 0;
        for (int j = 0; j < 6; j++) raw |= ((UInt64)a->rawValue[j]) << (j * 8);
        printf("%-4d %-35s %7d %7d %llu\n", a->attributeID, smartAttributeName(a->attributeID), a->current, a->worst, raw);
    }
}

static void cmdShortTest(SCSITaskDeviceInterface **dev) {
    // Self-test code 1 = short test
    int r = sendDiagnostic(dev, 1);
    if (r == 0) printf("Short self-test started. Takes ~2 minutes.\nRun 'wd_smart status' to check progress.\n");
    else fprintf(stderr, "Error: Could not start short test (%d)\n", r);
}

static void cmdExtendedTest(SCSITaskDeviceInterface **dev) {
    // Self-test code 2 = extended test
    int r = sendDiagnostic(dev, 2);
    if (r == 0) printf("Extended self-test started. May take several hours on 18TB.\nRun 'wd_smart status' to check progress.\n");
    else fprintf(stderr, "Error: Could not start extended test (%d)\n", r);
}

static void cmdAbortTest(SCSITaskDeviceInterface **dev) {
    int r = sendDiagnostic(dev, 4); // code 4 = abort
    if (r == 0) printf("Self-test aborted.\n");
    else fprintf(stderr, "Error: Could not abort test (%d)\n", r);
}

static void cmdTestStatus(SCSITaskDeviceInterface **dev) {
    // Log Sense page 0x10 = Self-Test Results
    UInt8 buf[404] = {0};
    int r = logSense(dev, 0x10, buf, sizeof(buf));
    if (r != 0) {
        fprintf(stderr, "Error: Could not read self-test log (%d)\n", r);
        return;
    }

    // Parse log page header
    UInt16 pageLen = (buf[2] << 8) | buf[3];
    if (pageLen < 20) { printf("No self-test results available.\n"); return; }

    printf("%-6s %-12s %-8s %s\n", "TEST#", "RESULT", "HOURS", "LBA_OF_FIRST_ERROR");
    int entries = (pageLen) / 20;
    if (entries > 20) entries = 20;

    for (int i = 0; i < entries; i++) {
        UInt8 *p = &buf[4 + i * 20];
        UInt8 testCode = (p[4] >> 5) & 0x07;
        UInt8 result = p[4] & 0x0F;
        UInt8 testNum = p[5];
        UInt16 hours = (p[6] << 8) | p[7];
        UInt64 lba = 0;
        for (int j = 0; j < 8; j++) lba = (lba << 8) | p[8 + j];

        if (result == 0 && testNum == 0 && hours == 0) continue;

        const char *resStr;
        switch(result) {
            case 0: resStr = "Completed OK"; break;
            case 1: resStr = "Aborted (self)"; break;
            case 2: resStr = "Aborted (user)"; break;
            case 3: resStr = "Unknown error"; break;
            case 4: resStr = "Unknown element"; break;
            case 5: resStr = "Electrical fail"; break;
            case 6: resStr = "Servo fail"; break;
            case 7: resStr = "Read fail"; break;
            case 8: resStr = "Handling damage"; break;
            case 15: resStr = "In progress..."; break;
            default: resStr = "Reserved"; break;
        }
        printf("%-6d %-12s %-8d %s\n", testNum, resStr, hours,
            (result >= 3 && result <= 8) ? [[NSString stringWithFormat:@"%llu", lba] UTF8String] : "-");
    }
}

static void cmdSleepTimer(SCSITaskDeviceInterface **dev, const char *setValue) {
    // Power Condition page 0x1A
    UInt8 buf[40] = {0};
    int r = modeSense(dev, 0x1A, buf, sizeof(buf));
    if (r != 0) {
        fprintf(stderr, "Error: Could not read sleep timer (%d)\n", r);
        return;
    }

    if (!setValue) {
        // Read current value - standby timer is at offset 8-11 in the page data
        // Mode param header is 4 bytes, page header is 2 bytes
        UInt8 pageLen = buf[5]; // page length
        UInt32 standbyTimer = 0;
        if (pageLen >= 10) {
            standbyTimer = ((UInt32)buf[10] << 24) | ((UInt32)buf[11] << 16) |
                           ((UInt32)buf[12] << 8) | buf[13];
        }
        if (standbyTimer == 0)
            printf("Sleep timer: disabled (never)\n");
        else
            printf("Sleep timer: %u seconds (~%u minutes)\n", standbyTimer / 10, standbyTimer / 600);
    } else {
        int minutes = atoi(setValue);
        UInt32 timerVal;
        if (minutes <= 0) timerVal = 0; // disable
        else timerVal = minutes * 600; // convert to 100ms units

        // Set standby timer
        buf[0] = 0; buf[1] = 0; buf[2] = 0; buf[3] = 0; // clear header for select
        buf[10] = (timerVal >> 24) & 0xFF;
        buf[11] = (timerVal >> 16) & 0xFF;
        buf[12] = (timerVal >> 8) & 0xFF;
        buf[13] = timerVal & 0xFF;
        buf[4] &= 0x3F; // clear PS bit

        r = modeSelect(dev, buf, 14 + 4, YES);
        if (r == 0) printf("Sleep timer set to %d minutes.\n", minutes);
        else fprintf(stderr, "Error: Could not set sleep timer (%d)\n", r);
    }
}

static void cmdTemperature(SCSITaskDeviceInterface **dev) {
    // Try diagnostic page for temperature (WD-specific)
    TemperatureConditionData td = {0};
    int r = sendReceiveDiagnostic(dev, 0x86, &td, sizeof(td));
    if (r == 0) {
        printf("Temperature condition: %d\n", td.temperatureCondition & 0x03);
        if (td.fanRPM > 0) printf("Fan RPM: %d\n", ntohs(td.fanRPM));
        if (td.currentFanPWM > 0) printf("Fan PWM: %d / %d (current/goal)\n", ntohs(td.currentFanPWM), ntohs(td.fanGoalPWM));
    }

    // Also get temperature from SMART attribute 194
    SmartDataPage dp = {0};
    if (sendReceiveDiagnostic(dev, SMART_DATA_PAGE, &dp, sizeof(dp)) == 0) {
        SMARTAttributeData *sd = (SMARTAttributeData *)dp.SmartData;
        for (int i = 0; i < 30; i++) {
            if (sd->attributes[i].attributeID == 194) {
                UInt64 raw = 0;
                for (int j = 0; j < 6; j++) raw |= ((UInt64)sd->attributes[i].rawValue[j]) << (j * 8);
                printf("Drive temperature: %llu°C (from SMART)\n", raw & 0xFF);
                break;
            }
        }
    }
}

static int inquiryVPD(SCSITaskDeviceInterface **dev, UInt8 pageCode, void *buf, UInt32 bufSize) {
    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) return -1;

    IOVirtualRange range = { .address = (IOVirtualAddress)buf, .length = bufSize };
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x12; // INQUIRY
    cdb[1] = 0x01; // EVPD
    cdb[2] = pageCode;
    cdb[3] = (bufSize >> 8) & 0xFF;
    cdb[4] = bufSize & 0xFF;

    (*task)->SetCommandDescriptorBlock(task, cdb, kSCSICDBSize_6Byte);
    (*task)->SetScatterGatherEntries(task, &range, 1, bufSize, kSCSIDataTransfer_FromTargetToInitiator);
    (*task)->SetTimeoutDuration(task, 5000);

    SCSI_Sense_Data sense = {0};
    SCSITaskStatus status;
    UInt64 xfer = 0;
    IOReturn r = (*task)->ExecuteTaskSync(task, &sense, &status, &xfer);
    (*task)->Release(task);

    if (r != kIOReturnSuccess) return -2;
    if (status != kSCSITaskStatus_GOOD) return -3;
    return 0;
}

static int standardInquiry(SCSITaskDeviceInterface **dev, void *buf, UInt32 bufSize) {
    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) return -1;

    IOVirtualRange range = { .address = (IOVirtualAddress)buf, .length = bufSize };
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x12; // INQUIRY
    cdb[3] = (bufSize >> 8) & 0xFF;
    cdb[4] = bufSize & 0xFF;

    (*task)->SetCommandDescriptorBlock(task, cdb, kSCSICDBSize_6Byte);
    (*task)->SetScatterGatherEntries(task, &range, 1, bufSize, kSCSIDataTransfer_FromTargetToInitiator);
    (*task)->SetTimeoutDuration(task, 5000);

    SCSI_Sense_Data sense = {0};
    SCSITaskStatus status;
    UInt64 xfer = 0;
    IOReturn r = (*task)->ExecuteTaskSync(task, &sense, &status, &xfer);
    (*task)->Release(task);

    if (r != kIOReturnSuccess) return -2;
    if (status != kSCSITaskStatus_GOOD) return -3;
    return 0;
}

static void cmdInfo(SCSITaskDeviceInterface **dev) {
    // Standard Inquiry
    UInt8 inq[96] = {0};
    if (standardInquiry(dev, inq, sizeof(inq)) == 0) {
        char vendor[9] = {0}, product[17] = {0}, revision[5] = {0};
        memcpy(vendor, &inq[8], 8);
        memcpy(product, &inq[16], 16);
        memcpy(revision, &inq[32], 4);
        printf("Vendor:   %s\n", vendor);
        printf("Product:  %s\n", product);
        printf("Firmware: %s\n", revision);
    }

    // Serial Number (VPD 0x80)
    UInt8 sn[40] = {0};
    if (inquiryVPD(dev, 0x80, sn, sizeof(sn)) == 0) {
        UInt8 len = sn[3];
        if (len > 32) len = 32;
        char serial[33] = {0};
        memcpy(serial, &sn[4], len);
        printf("Serial:   %s\n", serial);
    }

    // Block Device Characteristics (VPD 0xB1) - RPM, form factor
    UInt8 bdc[64] = {0};
    if (inquiryVPD(dev, 0xB1, bdc, sizeof(bdc)) == 0) {
        UInt16 rpm = (bdc[4] << 8) | bdc[5];
        UInt8 ff = bdc[7] & 0x0F;
        if (rpm > 0) printf("RPM:      %d\n", rpm);
        else printf("RPM:      Non-rotating (SSD)\n");
        const char *formFactor;
        switch(ff) {
            case 1: formFactor = "5.25\""; break;
            case 2: formFactor = "3.5\""; break;
            case 3: formFactor = "2.5\""; break;
            case 4: formFactor = "1.8\""; break;
            default: formFactor = "Unknown"; break;
        }
        printf("Form:     %s\n", formFactor);
    }

    // Raw Capacity (VPD 0xC2) - WD-specific
    UInt8 cap[24] = {0};
    if (inquiryVPD(dev, 0xC2, cap, sizeof(cap)) == 0) {
        UInt8 maxDisks = cap[6];
        UInt8 disksInstalled = cap[7];
        UInt64 totalBlocks = 0;
        for (int i = 0; i < 8; i++) totalBlocks = (totalBlocks << 8) | cap[8 + i];
        UInt32 blockLen = ((UInt32)cap[16] << 24) | ((UInt32)cap[17] << 16) | ((UInt32)cap[18] << 8) | cap[19];
        double capacityTB = (double)totalBlocks * blockLen / 1e12;
        printf("Capacity: %.2f TB (%llu blocks × %u bytes)\n", capacityTB, totalBlocks, blockLen);
        if (maxDisks > 1) printf("Bays:     %d/%d installed\n", disksInstalled, maxDisks);
    }

    // Active Interfaces (VPD 0xC1)
    UInt8 ai[24] = {0};
    if (inquiryVPD(dev, 0xC1, ai, sizeof(ai)) == 0) {
        UInt16 pageLen = (ai[2] << 8) | ai[3];
        int numPorts = pageLen / 8;
        printf("Ports:    ");
        for (int i = 0; i < numPorts && i < 4; i++) {
            UInt8 *port = &ai[4 + i * 8];
            BOOL active = port[0] & 0x01;
            char portType[8] = {0};
            memcpy(portType, &port[1], 7);
            if (active) printf("%s (active) ", portType);
            else printf("%s ", portType);
        }
        printf("\n");
    }

    // Encryption status (Diag 0x83)
    UInt8 enc[8] = {0};
    if (sendReceiveDiagnostic(dev, 0x83, enc, sizeof(enc)) == 0) {
        UInt8 secState = enc[4];
        const char *encStr;
        switch(secState) {
            case 0: encStr = "Off"; break;
            case 1: encStr = "Locked"; break;
            case 2: encStr = "Unlocked"; break;
            case 6: encStr = "Max unlocks exceeded"; break;
            case 7: encStr = "No DEK"; break;
            default: encStr = "Unknown"; break;
        }
        printf("Encrypt:  %s\n", encStr);
    }
}

static void cmdPowerOff(SCSITaskDeviceInterface **dev) {
    // Send Diagnostic page 0x80 with PowerOff bit set
    UInt8 buf[8] = {0};
    buf[0] = 0x80; // page code
    buf[1] = 0x00;
    buf[2] = 0x00; // page length MSB
    buf[3] = 0x04; // page length LSB
    buf[4] = 0x01; // PowerOff bit

    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) { fprintf(stderr, "Error: Could not create task\n"); return; }

    IOVirtualRange range = { .address = (IOVirtualAddress)buf, .length = 8 };
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x1D; // SEND DIAGNOSTIC
    cdb[1] = 0x10; // PF bit
    cdb[3] = 0x00;
    cdb[4] = 0x08; // param length

    (*task)->SetCommandDescriptorBlock(task, cdb, kSCSICDBSize_6Byte);
    (*task)->SetScatterGatherEntries(task, &range, 1, 8, kSCSIDataTransfer_FromInitiatorToTarget);
    (*task)->SetTimeoutDuration(task, 10000);

    SCSI_Sense_Data sense = {0};
    SCSITaskStatus status;
    UInt64 xfer = 0;
    IOReturn r = (*task)->ExecuteTaskSync(task, &sense, &status, &xfer);
    (*task)->Release(task);

    if (r == kIOReturnSuccess && status == kSCSITaskStatus_GOOD)
        printf("Drive powered off safely. You can disconnect it now.\n");
    else
        fprintf(stderr, "Error: Power off failed. Try 'diskutil eject /dev/disk12' instead.\n");
}

#pragma mark - Usage

static void usage(void) {
    printf("Usage: wd_smart <command> [args]\n\n");
    printf("Commands:\n");
    printf("  smart          Read SMART attributes (default if no command given)\n");
    printf("  info           Drive identity, capacity, RPM, encryption status\n");
    printf("  short-test     Start short self-test (~2 min)\n");
    printf("  long-test      Start extended self-test (hours)\n");
    printf("  abort-test     Abort running self-test\n");
    printf("  status         Show self-test results log\n");
    printf("  temp           Show drive temperature\n");
    printf("  sleep [MIN]    Get or set sleep timer (0 = disable)\n");
    printf("  power-off      Safely spin down and power off drive\n");
    printf("\nRequires: sudo\n");
}

#pragma mark - Main

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        const char *cmd = (argc > 1) ? argv[1] : "smart";

        if (strcmp(cmd, "-h") == 0 || strcmp(cmd, "--help") == 0 || strcmp(cmd, "help") == 0) {
            usage(); return 0;
        }

        char devName[256] = {0};
        SCSITaskDeviceInterface **dev = findWDSESDevice(devName, sizeof(devName));
        if (!dev) {
            fprintf(stderr, "Error: No WD device found or could not access it.\n");
            fprintf(stderr, "Make sure drive is connected and try: diskutil unmountDisk /dev/disk12\n");
            return 1;
        }
        printf("Device: %s\n\n", devName);

        if (strcmp(cmd, "smart") == 0)           cmdSmart(dev);
        else if (strcmp(cmd, "info") == 0)       cmdInfo(dev);
        else if (strcmp(cmd, "short-test") == 0) cmdShortTest(dev);
        else if (strcmp(cmd, "long-test") == 0)  cmdExtendedTest(dev);
        else if (strcmp(cmd, "abort-test") == 0) cmdAbortTest(dev);
        else if (strcmp(cmd, "status") == 0)     cmdTestStatus(dev);
        else if (strcmp(cmd, "temp") == 0)       cmdTemperature(dev);
        else if (strcmp(cmd, "sleep") == 0)      cmdSleepTimer(dev, argc > 2 ? argv[2] : NULL);
        else if (strcmp(cmd, "power-off") == 0)  cmdPowerOff(dev);
        else { fprintf(stderr, "Unknown command: %s\n", cmd); usage(); }

        (*dev)->ReleaseExclusiveAccess(dev);
        (*dev)->Release(dev);
    }
    return 0;
}
