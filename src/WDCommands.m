//
//  WDCommands.m
//  SMART helpers and all non-encryption commands.
//

#import "WDSmart.h"
#import <sys/disk.h>
#import <fcntl.h>
#import <unistd.h>

#pragma mark - SMART Attribute Name Lookup

const char *WDSmartAttrName(UInt8 id) {
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


#pragma mark - Helpers

/// Extract a 48-bit raw value from a SMART attribute's 6-byte raw field.
UInt64 WDSmartRawValue(const WDSmartAttribute *attr) {
    UInt64 val = 0;
    for (int i = 0; i < 6; i++)
        val |= ((UInt64)attr->raw[i]) << (i * 8);
    return val;
}

/// Format a SMART attribute's raw value for display.
/// Some attributes have packed fields that need special decoding.
const char *WDSmartRawFormatted(const WDSmartAttribute *attr) {
    static char buf[64];
    UInt64 raw = WDSmartRawValue(attr);

    switch (attr->id) {
        case 9: { // Power-On Hours
            UInt32 hours = (UInt32)(raw & 0xFFFFFFFF);
            if (hours >= 24)
                snprintf(buf, sizeof(buf), "%u (%ud %uh)", hours, hours / 24, hours % 24);
            else
                snprintf(buf, sizeof(buf), "%u", hours);
            return buf;
        }
        case 190: // Airflow Temperature
        case 194: { // Temperature — raw packs current (low byte), min, max
            UInt8 current = raw & 0xFF;
            UInt8 worst   = (raw >> 8) & 0xFF;  // or min
            UInt8 limit   = (raw >> 32) & 0xFF;  // or max/limit
            if (limit > 0 && limit != 0xFF && worst > 0 && worst != current)
                snprintf(buf, sizeof(buf), "%u (min=%u, max=%u)", current, worst, limit);
            else
                snprintf(buf, sizeof(buf), "%u", current);
            return buf;
        }
        case 3: { // Spin Up Time — lower 16 bits = current ms, upper may be average
            UInt16 current = raw & 0xFFFF;
            UInt16 average = (raw >> 16) & 0xFFFF;
            if (average > 0 && average != current)
                snprintf(buf, sizeof(buf), "%u (avg %u ms)", current, average);
            else
                snprintf(buf, sizeof(buf), "%u", current);
            return buf;
        }
        default:
            snprintf(buf, sizeof(buf), "%llu", raw);
            return buf;
    }
}

/// Self-test result code to human-readable string.
const char *WDSelfTestResultString(UInt8 code) {
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


#pragma mark - SMART Command

void WDCmdSmart(SCSITaskDeviceInterface **dev) {
    // Read SMART threshold status (page 0x84)
    // The WD SES bridge returns the ATA SMART RETURN STATUS signature bytes:
    //   Pass: LBA High=0xC2, LBA Mid=0x4F
    //   Fail: LBA High=0x2C, LBA Mid=0xF4
    WDSmartStatusPage statusPage = {0};
    if (WDScsiReceiveDiagnostic(dev, kWDDiagPageSmartStatus, &statusPage, sizeof(statusPage)) == 0) {
        BOOL passed = (statusPage.statusMSB == 0xC2 && statusPage.statusLSB == 0x4F);
        BOOL failed = (statusPage.statusMSB == 0x2C && statusPage.statusLSB == 0xF4);
        const char *statusStr = passed ? "PASSED" : (failed ? "FAILED" : "UNKNOWN");
        printf("SMART Status: %s\n\n", statusStr);
    }

    // Read full SMART attribute data (page 0x85)
    WDSmartDataPage dataPage = {0};
    if (WDScsiReceiveDiagnostic(dev, kWDDiagPageSmartData, &dataPage, sizeof(dataPage)) != 0) {
        fprintf(stderr, "Error: Could not read SMART data\n");
        return;
    }

    printf("%-4s %-35s %7s %7s %s\n", "ID#", "ATTRIBUTE_NAME", "VALUE", "WORST", "RAW_VALUE");

    WDSmartAttributeTable *table = (WDSmartAttributeTable *)dataPage.smartData;
    for (int i = 0; i < 30; i++) {
        WDSmartAttribute *a = &table->attrs[i];
        if (a->id == 0) continue;
        printf("%-4d %-35s %7d %7d %s\n",
               a->id, WDSmartAttrName(a->id), a->current, a->worst, WDSmartRawFormatted(a));
    }
}




#pragma mark - Drive Identity

WDDriveIdentityFn g_driveIdentity = WDDriveIdentityFromIOKit;

WDDriveIdentity WDDriveIdentityFromIOKit(const char *targetSerial) {
    WDDriveIdentity ident = {0};
    io_iterator_t iter;
    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) return ident;

    io_service_t service;
    while ((service = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        CFTypeRef vendorRef = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, CFSTR("Vendor Identification"),
            kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
        CFTypeRef productRef = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, CFSTR("Product Identification"),
            kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
        CFTypeRef devTypeRef = IORegistryEntryCreateCFProperty(
            service, CFSTR("Peripheral Device Type"), kCFAllocatorDefault, 0);

        NSString *vendor = vendorRef ? (__bridge_transfer NSString *)vendorRef : nil;
        NSString *product = productRef ? (__bridge_transfer NSString *)productRef : nil;
        NSNumber *devType = devTypeRef ? (__bridge_transfer NSNumber *)devTypeRef : nil;

        if (!vendor || !devType) { IOObjectRelease(service); continue; }

        NSString *tv = [vendor stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![tv isEqualToString:@"WD"] && ![tv isEqualToString:@"WDC"]) {
            IOObjectRelease(service); continue;
        }

        if ([devType intValue] != 0) { IOObjectRelease(service); continue; }

        if (targetSerial) {
            CFTypeRef snRef = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, CFSTR("USB Serial Number"),
                kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
            NSString *sn = snRef ? (__bridge_transfer NSString *)snRef : nil;
            NSString *tp = product ? [product stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
            if (sn && ![sn containsString:@(targetSerial)] && ![tp containsString:@(targetSerial)]) {
                IOObjectRelease(service); continue;
            }
        }

        CFTypeRef revRef = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, CFSTR("Product Revision Level"),
            kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
        NSString *firmware = revRef ? (__bridge_transfer NSString *)revRef : nil;

        strlcpy(ident.vendor, [tv UTF8String], sizeof(ident.vendor));
        if (product)
            strlcpy(ident.product, [[product stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] UTF8String], sizeof(ident.product));
        if (firmware)
            strlcpy(ident.firmware, [[firmware stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] UTF8String], sizeof(ident.firmware));
        ident.found = YES;

        IOObjectRelease(service);
        IOObjectRelease(iter);
        return ident;
    }
    IOObjectRelease(iter);
    return ident;
}


/// Display drive identity using the provider.
void WDPrintDriveIdentity(const char *targetSerial) {
    WDDriveIdentity ident = g_driveIdentity(targetSerial);
    if (!ident.found) return;
    printf("Vendor:   %s\n", ident.vendor);
    printf("Product:  %s\n", ident.product[0] ? ident.product : "Unknown");
    if (ident.firmware[0])
        printf("Firmware: %s\n", ident.firmware);
}


#pragma mark - Info and Diagnostics

void WDCmdInfo(SCSITaskDeviceInterface **dev) {
    // Get actual drive model from the disk LUN's IOKit registry properties
    WDPrintDriveIdentity(NULL);

    // VPD page 0x80: Unit serial number
    UInt8 snBuf[40] = {0};
    if (WDScsiInquiryVPD(dev, 0x80, snBuf, sizeof(snBuf)) == 0) {
        UInt8 len = snBuf[3];
        if (len > 32) len = 32;
        char serial[33] = {0};
        memcpy(serial, &snBuf[4], len);
        printf("Serial:   %s\n", serial);
    }

    // VPD page 0xB1: Block device characteristics (RPM, form factor)
    // Supported on some enclosures (MyBook) but not others (Passport)
    UInt8 bdc[64] = {0};
    if (WDScsiInquiryVPD(dev, 0xB1, bdc, sizeof(bdc)) == 0) {
        UInt16 rpm = ((UInt16)bdc[4] << 8) | bdc[5];
        UInt8 formFactor = bdc[7] & 0x0F;

        if (rpm > 0)
            printf("RPM:      %d\n", rpm);

        const char *ffStr = NULL;
        switch (formFactor) {
            case 1: ffStr = "5.25\""; break;
            case 2: ffStr = "3.5\"";  break;
            case 3: ffStr = "2.5\"";  break;
            case 4: ffStr = "1.8\"";  break;
        }
        if (ffStr) printf("Form:     %s\n", ffStr);
    }

    // VPD page 0xC2: WD raw capacity (total blocks, block size, bay count)
    UInt8 cap[24] = {0};
    if (WDScsiInquiryVPD(dev, 0xC2, cap, sizeof(cap)) == 0) {
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
    if (WDScsiInquiryVPD(dev, 0xC1, ai, sizeof(ai)) == 0) {
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

    // Encryption status: try vendor command 0xC0/0x45 first (full status),
    // fall back to diagnostic page 0x83 (simplified)
    UInt8 encFull[48] = {0};
    SCSICommandDescriptorBlock encCdb = {0};
    encCdb[0] = 0xC0; encCdb[1] = 0x45; encCdb[8] = 0x30;
    if (WDExecSCSITask(dev, encCdb, kSCSICDBSize_10Byte, encFull, 48,
                     kSCSIDataTransfer_FromTargetToInitiator, kTimeoutDefault) == 0 && encFull[0] == 0x45) {
        const char *state;
        switch (encFull[3]) {
            case 0: state = "Off";                    break;
            case 1: state = "Locked";                 break;
            case 2: state = "Unlocked";               break;
            case 6: state = "Max unlocks exceeded";   break;
            case 7: state = "No DEK";                 break;
            default: state = "Unknown";               break;
        }
        const char *cipher;
        switch (encFull[4]) {
            case 0x10: cipher = "AES-128-ECB"; break;
            case 0x18: cipher = "AES-128-XTS"; break;
            case 0x20: cipher = "AES-256-ECB"; break;
            case 0x28: cipher = "AES-256-XTS"; break;
            case 0x30: cipher = "Full Disk";   break;
            default:   cipher = NULL;          break;
        }
        if (cipher)
            printf("Encrypt:  %s (%s)\n", state, cipher);
        else
            printf("Encrypt:  %s\n", state);
    } else {
        // Fallback to diagnostic page 0x83
        UInt8 enc[8] = {0};
        if (WDScsiReceiveDiagnostic(dev, kWDDiagPageEncryptionStatus, enc, sizeof(enc)) == 0) {
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
}

/// Start a short self-test (~2 minutes).
void WDCmdShortTest(SCSITaskDeviceInterface **dev) {
    if (WDScsiSendDiagnosticSelfTest(dev, kSelfTestShort) == 0)
        printf("Short self-test started (~2 minutes).\nRun 'wd_smart status' to check progress.\n");
    else
        fprintf(stderr, "Error: Could not start short test\n");
}

/// Start an extended self-test (full surface scan, hours on large drives).
void WDCmdLongTest(SCSITaskDeviceInterface **dev) {
    if (WDScsiSendDiagnosticSelfTest(dev, kSelfTestExtend) == 0)
        printf("Extended self-test started (may take many hours on large drives).\n"
               "Run 'wd_smart status' to check progress.\n");
    else
        fprintf(stderr, "Error: Could not start extended test\n");
}

/// Abort a running self-test.
void WDCmdAbortTest(SCSITaskDeviceInterface **dev) {
    if (WDScsiSendDiagnosticSelfTest(dev, kSelfTestAbort) == 0)
        printf("Self-test aborted.\n");
    else
        fprintf(stderr, "Error: Could not abort test\n");
}

/// Display self-test results log (LOG SENSE page 0x10).
void WDCmdStatus(SCSITaskDeviceInterface **dev) {
    UInt8 buf[404] = {0};
    if (WDScsiLogSense(dev, 0x10, buf, sizeof(buf)) != 0) {
        fprintf(stderr, "Error: Could not read self-test log\n");
        return;
    }

    UInt16 pageLen = ((UInt16)buf[2] << 8) | buf[3];
    if (pageLen < 20) {
        printf("No self-test results available.\n");
        return;
    }

    printf("%-6s %-6s %-14s %-8s %s\n", "TEST#", "TYPE", "RESULT", "HOURS", "FIRST_ERROR_LBA");

    int entries = pageLen / 20;
    if (entries > 20) entries = 20;

    for (int i = 0; i < entries; i++) {
        UInt8 *entry = &buf[4 + i * 20];
        UInt8 testCode = (entry[4] >> 5) & 0x07;
        UInt8 result   = entry[4] & 0x0F;
        UInt8 testNum  = entry[5];
        UInt16 hours   = ((UInt16)entry[6] << 8) | entry[7];

        // Skip truly empty entries (all parameter data is zero)
        if (testCode == 0 && result == 0 && testNum == 0 && hours == 0) continue;

        UInt64 lba = 0;
        for (int j = 0; j < 8; j++) lba = (lba << 8) | entry[8 + j];

        const char *typeStr;
        switch (testCode) {
            case 1: typeStr = "Short";    break;
            case 2: typeStr = "Extended"; break;
            default: typeStr = "Other";   break;
        }

        printf("%-6d %-6s %-14s %-8d %s\n",
               testNum, typeStr, WDSelfTestResultString(result), hours,
               (result >= 3 && result <= 8)
                   ? [[NSString stringWithFormat:@"%llu", lba] UTF8String]
                   : "-");
    }
}

/// Display drive temperature (from SMART attribute 194 and/or diag page 0x86).
void WDCmdTemp(SCSITaskDeviceInterface **dev) {
    // Try WD-specific temperature diagnostic page
    WDTemperaturePage tempPage = {0};
    if (WDScsiReceiveDiagnostic(dev, kWDDiagPageTemperature, &tempPage, sizeof(tempPage)) == 0) {
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
    if (WDScsiReceiveDiagnostic(dev, kWDDiagPageSmartData, &dataPage, sizeof(dataPage)) == 0) {
        WDSmartAttributeTable *table = (WDSmartAttributeTable *)dataPage.smartData;
        for (int i = 0; i < 30; i++) {
            if (table->attrs[i].id == 194) {
                printf("Drive:    %llu°C\n", WDSmartRawValue(&table->attrs[i]) & 0xFF);
                return;
            }
        }
    }
}

/// Get or set the drive sleep (spindown) timer.
/// When setValue is NULL, displays current setting. Otherwise sets it.
void WDCmdSleep(SCSITaskDeviceInterface **dev, const char *setValue) {
    // Power Condition mode page (0x1A) with DBD.
    // Response layout: [0..3]=header, [4]=pageCode|PS, [5]=pageLen, [6..]=page data
    // WD standby timer is a 2-byte BE value at absolute offset 14-15 (page data byte 8-9)
    UInt8 buf[44] = {0};
    if (WDScsiModeSense(dev, 0x1A, buf, sizeof(buf)) != 0) {
        fprintf(stderr, "Error: Could not read sleep timer\n");
        return;
    }

    if (!setValue) {
        UInt16 timer = ((UInt16)buf[14] << 8) | buf[15];
        if (timer == 0)
            printf("Sleep timer: disabled (never)\n");
        else
            printf("Sleep timer: ~%u minutes (%u seconds)\n", timer / 600, timer / 10);
    } else {
        int minutes = atoi(setValue);
        UInt16 timerVal = (minutes <= 0) ? 0 : (UInt16)(minutes * 600);

        // Clear mode parameter header and PS bit
        memset(buf, 0, 4);
        buf[4] &= 0x3F;

        // buf[7] bit 0 = Standby_z enable
        if (timerVal > 0)
            buf[7] |= 0x01;
        else
            buf[7] &= ~0x01;

        // Write standby timer
        buf[14] = (timerVal >> 8) & 0xFF;
        buf[15] = timerVal & 0xFF;

        // Parameter list length = page length + 6 (4 header + 2 page header)
        UInt8 paramLen = buf[5] + 6;
        if (WDScsiModeSelect(dev, buf, paramLen, YES) == 0) {
            if (minutes <= 0)
                printf("Sleep timer disabled.\n");
            else
                printf("Sleep timer set to %d minutes.\n", minutes);
        } else {
            fprintf(stderr, "Error: Could not set sleep timer\n");
        }
    }
}


#pragma mark - Power and Erase

void WDCmdPowerOff(SCSITaskDeviceInterface **dev) {
    // WD power control via diagnostic page 0x80
    UInt8 page[8] = {0};
    page[0] = 0x80;   // page code
    page[3] = 0x04;   // page length
    page[4] = 0x01;   // bit 0 = PowerOff

    if (WDScsiSendDiagnosticPage(dev, page, sizeof(page)) == 0)
        printf("Drive powered off safely. You can disconnect it now.\n");
    else
        fprintf(stderr, "Error: Power off failed. Try 'diskutil eject /dev/diskN' instead.\n");
}

/// Erase the drive by sending the WD FORMAT DISK vendor command (0xC4).
/// This is IRREVERSIBLE. Requires --confirm flag and shows a countdown.
void WDCmdErase(SCSITaskDeviceInterface **dev, int argc, const char *argv[]) {
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
#ifndef TESTING
    for (int i = 5; i > 0; i--) {
        fprintf(stderr, "  Erasing in %d...\n", i);
        sleep(1);
    }
#endif

    // WD vendor-specific FORMAT DISK command (opcode 0xC4)
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0xC4;  // FORMAT DISK (WD vendor-specific)

    int r = WDExecSCSITask(dev, cdb, kSCSICDBSize_10Byte, NULL, 0,
                         kSCSIDataTransfer_NoDataTransfer, kTimeoutLong);

    if (r == 0)
        printf("Erase command sent. Drive is formatting.\n"
               "This may take a long time. Do not disconnect the drive.\n");
    else
        fprintf(stderr, "Error: Erase command failed (%d)\n", r);
}

/// Find the BSD name (e.g. "disk12") of the WD disk LUN (not the SES device).

#pragma mark - Secure Erase

NSString *WDFindDiskBSDName(void) {
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
void WDCmdSecureErase(int argc, const char *argv[]) {
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
    NSString *bsdName = WDFindDiskBSDName();
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

