//
//  WDCommands.m
//  SMART helpers and all non-encryption commands.
//

#import "WDSmart.h"
#import <sys/disk.h>
#import <fcntl.h>
#import <unistd.h>
#import <readpassphrase.h>

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
/// Returns a pointer to a static buffer (not reentrant).
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

/// Read a password from `arg`, or prompt with echo off when arg is NULL.
const char *WDReadPassword(const char *arg, const char *prompt, char *out, size_t outSize) {
    if (arg) {
        strlcpy(out, arg, outSize);
        return out;
    }
#ifdef TESTING
    (void)prompt;
    return NULL;
#else
    if (!isatty(STDIN_FILENO)) {
        // Non-interactive: read one line from stdin
        if (!fgets(out, (int)outSize, stdin)) return NULL;
        out[strcspn(out, "\r\n")] = '\0';
        return out[0] ? out : NULL;
    }
    if (!readpassphrase(prompt, out, outSize, RPP_ECHO_OFF | RPP_REQUIRE_TTY)) return NULL;
    return out[0] ? out : NULL;
#endif
}

BOOL WDHasConfirmFlag(int argc, const char *argv[]) {
    for (int i = 1; i < argc; i++)
        if (argv[i] && strcmp(argv[i], "--confirm") == 0) return YES;
    return NO;
}
#define hasConfirmFlag WDHasConfirmFlag


#pragma mark - SMART Command

int WDCmdSmart(SCSITaskDeviceInterface **dev) {
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
    } else {
        fprintf(stderr, "Warning: SMART status unavailable — %s\n\n", WDScsiLastErrorString());
    }

    // Read full SMART attribute data (page 0x85)
    WDSmartDataPage dataPage = {0};
    if (WDScsiReceiveDiagnostic(dev, kWDDiagPageSmartData, &dataPage, sizeof(dataPage)) != 0) {
        WDScsiPrintError("Could not read SMART data");
        return kWDExitFailure;
    }

    printf("%-4s %-35s %7s %7s %s\n", "ID#", "ATTRIBUTE_NAME", "VALUE", "WORST", "RAW_VALUE");

    WDSmartAttributeTable *table = (WDSmartAttributeTable *)dataPage.smartData;
    int shown = 0;
    for (int i = 0; i < 30; i++) {
        WDSmartAttribute *a = &table->attrs[i];
        if (a->id == 0) continue;
        printf("%-4d %-35s %7d %7d %s\n",
               a->id, WDSmartAttrName(a->id), a->current, a->worst, WDSmartRawFormatted(a));
        shown++;
    }
    if (shown == 0) {
        fprintf(stderr, "Warning: SMART page returned no attributes\n");
        return kWDExitFailure;
    }
    return kWDExitOK;
}


#pragma mark - Drive Identity

WDDriveIdentityFn g_driveIdentity = WDDriveIdentityFromIOKit;

/// Identity of the disk LUN bound to the opened enclosure (see WDFindDiskLUNService).
/// `targetSerial`, when non-NULL, additionally filters on USB serial / product.
WDDriveIdentity WDDriveIdentityFromIOKit(const char *targetSerial) {
    WDDriveIdentity ident = {0};
    io_service_t service = WDFindDiskLUNService();
    if (service == IO_OBJECT_NULL) return ident;

    // WDRegistryString type-checks (CFString only) and trims; never throws.
    NSString *vendor   = WDRegistryString(service, CFSTR("Vendor Identification"));
    NSString *product  = WDRegistryString(service, CFSTR("Product Identification"));
    NSString *firmware = WDRegistryString(service, CFSTR("Product Revision Level"));
    NSString *sn       = WDRegistryString(service, CFSTR("USB Serial Number"));
    IOObjectRelease(service);

    if (targetSerial) {
        NSString *t = @(targetSerial);
        if (!(sn && [sn containsString:t]) && !(product && [product containsString:t]))
            return ident;
    }

    if (vendor)   strlcpy(ident.vendor,   [vendor UTF8String],   sizeof(ident.vendor));
    if (product)  strlcpy(ident.product,  [product UTF8String],  sizeof(ident.product));
    if (firmware) strlcpy(ident.firmware, [firmware UTF8String], sizeof(ident.firmware));
    ident.found = YES;
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

/// Decode WD encryption security state byte.
static const char *encStateName(UInt8 state) {
    switch (state) {
        case 0:  return "Off";
        case 1:  return "Locked";
        case 2:  return "Unlocked";
        case 6:  return "Max unlocks exceeded";
        case 7:  return "No DEK";
        default: return "Unknown";
    }
}

int WDCmdInfo(SCSITaskDeviceInterface **dev) {
    int failures = 0;

    // Get actual drive model from the disk LUN's IOKit registry properties
    WDPrintDriveIdentity(NULL);

    // VPD page 0x80: Unit serial number
    UInt8 snBuf[40] = {0};
    if (WDScsiInquiryVPD(dev, 0x80, snBuf, sizeof(snBuf)) == 0) {
        UInt8 len = snBuf[3];
        if (len > sizeof(snBuf) - 4) len = sizeof(snBuf) - 4;
        char serial[37] = {0};
        memcpy(serial, &snBuf[4], len);
        // Trim trailing whitespace (bridge pads with spaces)
        for (int i = (int)len - 1; i >= 0 && (serial[i] == ' ' || serial[i] == '\0'); i--) serial[i] = '\0';
        if (serial[0]) printf("Serial:   %s\n", serial);
    }

    // VPD page 0xB1: Block device characteristics (RPM, form factor)
    // Supported on some enclosures (MyBook) but not others (Passport)
    UInt8 bdc[64] = {0};
    if (WDScsiInquiryVPD(dev, 0xB1, bdc, sizeof(bdc)) == 0) {
        UInt16 rpm = ((UInt16)bdc[4] << 8) | bdc[5];
        UInt8 formFactor = bdc[7] & 0x0F;

        if (rpm > 1)   // 0 = not reported, 1 = non-rotating (SSD)
            printf("RPM:      %d\n", rpm);
        else if (rpm == 1)
            printf("Media:    Solid state\n");

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

        if (blocks > 0 && blockSize > 0) {
            double tb = (double)blocks * blockSize / 1e12;
            printf("Capacity: %.2f TB (%llu blocks x %u bytes)\n", tb, blocks, blockSize);
        }

        if (maxDisks > 1)
            printf("Bays:     %d/%d installed\n", installed, maxDisks);
    }

    // VPD page 0xC1: Active interfaces (USB3, USB2, etc.)
    // Layout: 4-byte header + N x 8-byte port descriptors. We display up to 4.
    enum { kMaxPorts = 4 };
    UInt8 ai[4 + kMaxPorts * 8] = {0};
    if (WDScsiInquiryVPD(dev, 0xC1, ai, sizeof(ai)) == 0) {
        UInt16 pageLen = ((UInt16)ai[2] << 8) | ai[3];
        int numPorts = pageLen / 8;
        if (numPorts > kMaxPorts) numPorts = kMaxPorts;
        if (numPorts > 0) {
            printf("Port:     ");
            for (int i = 0; i < numPorts; i++) {
                UInt8 *port = &ai[4 + i * 8];
                BOOL active = port[0] & 0x01;
                char type[8] = {0};
                memcpy(type, &port[1], 7);
                for (int k = 6; k >= 0 && (type[k] == ' ' || type[k] == '\0'); k--) type[k] = '\0';
                printf("%s%s", type, active ? " (active)" : "");
                if (i < numPorts - 1) printf(", ");
            }
            printf("\n");
        }
    }

    // Encryption status: try vendor command 0xC0/0x45 first (full status),
    // fall back to diagnostic page 0x83 (simplified)
    UInt8 encFull[48] = {0};
    SCSICommandDescriptorBlock encCdb = {0};
    encCdb[0] = 0xC0; encCdb[1] = 0x45; encCdb[8] = 0x30;
    if (WDExecSCSITask(dev, encCdb, kSCSICDBSize_10Byte, encFull, 48,
                     kSCSIDataTransfer_FromTargetToInitiator, kTimeoutDefault) == 0 && encFull[0] == 0x45) {
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
            printf("Encrypt:  %s (%s)\n", encStateName(encFull[3]), cipher);
        else
            printf("Encrypt:  %s\n", encStateName(encFull[3]));
    } else {
        char firstErr[256];
        strlcpy(firstErr, WDScsiLastErrorString(), sizeof(firstErr));
        // Fallback to diagnostic page 0x83
        UInt8 enc[8] = {0};
        if (WDScsiReceiveDiagnostic(dev, kWDDiagPageEncryptionStatus, enc, sizeof(enc)) == 0) {
            printf("Encrypt:  %s\n", encStateName(enc[4]));
        } else {
            printf("Encrypt:  unavailable\n");
            fflush(stdout);
            fprintf(stderr, "  (%s)\n", firstErr);
            failures++;
        }
    }

    return failures ? kWDExitFailure : kWDExitOK;
}

/// Start a short self-test (~2 minutes).
int WDCmdShortTest(SCSITaskDeviceInterface **dev) {
    if (WDScsiSendDiagnosticSelfTest(dev, kSelfTestShort) == 0) {
        printf("Short self-test started (~2 minutes).\nRun 'wd_smart status' to check progress.\n");
        return kWDExitOK;
    }
    WDScsiPrintError("Could not start short test");
    return kWDExitFailure;
}

/// Start an extended self-test (full surface scan, hours on large drives).
int WDCmdLongTest(SCSITaskDeviceInterface **dev) {
    if (WDScsiSendDiagnosticSelfTest(dev, kSelfTestExtend) == 0) {
        printf("Extended self-test started (may take many hours on large drives).\n"
               "Run 'wd_smart status' to check progress.\n");
        return kWDExitOK;
    }
    WDScsiPrintError("Could not start extended test");
    return kWDExitFailure;
}

/// Abort a running self-test.
int WDCmdAbortTest(SCSITaskDeviceInterface **dev) {
    if (WDScsiSendDiagnosticSelfTest(dev, kSelfTestAbort) == 0) {
        printf("Self-test aborted.\n");
        return kWDExitOK;
    }
    WDScsiPrintError("Could not abort test");
    return kWDExitFailure;
}

/// Display self-test results log (LOG SENSE page 0x10).
int WDCmdStatus(SCSITaskDeviceInterface **dev) {
    enum { kEntrySize = 20, kMaxEntries = 20 };
    UInt8 buf[4 + kMaxEntries * kEntrySize] = {0};
    if (WDScsiLogSense(dev, 0x10, buf, sizeof(buf)) != 0) {
        WDScsiPrintError("Could not read self-test log");
        return kWDExitFailure;
    }

    UInt16 pageLen = ((UInt16)buf[2] << 8) | buf[3];
    if (pageLen > sizeof(buf) - 4) pageLen = sizeof(buf) - 4;
    if (pageLen < kEntrySize) {
        printf("No self-test results available.\n");
        return kWDExitOK;
    }

    printf("%-6s %-6s %-14s %-8s %s\n", "TEST#", "TYPE", "RESULT", "HOURS", "FIRST_ERROR_LBA");

    int entries = pageLen / kEntrySize;

    for (int i = 0; i < entries; i++) {
        UInt8 *entry = &buf[4 + i * kEntrySize];
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

        char lbaStr[24] = "-";
        if (result >= 3 && result <= 8) snprintf(lbaStr, sizeof(lbaStr), "%llu", lba);

        printf("%-6d %-6s %-14s %-8d %s\n",
               testNum, typeStr, WDSelfTestResultString(result), hours, lbaStr);
    }
    return kWDExitOK;
}

/// Display drive temperature (from SMART attribute 194 and/or diag page 0x86).
int WDCmdTemp(SCSITaskDeviceInterface **dev) {
    BOOL gotSomething = NO;

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
        gotSomething = YES;
    }

    // Get temperature from SMART attribute 194 (most reliable)
    WDSmartDataPage dataPage = {0};
    if (WDScsiReceiveDiagnostic(dev, kWDDiagPageSmartData, &dataPage, sizeof(dataPage)) == 0) {
        WDSmartAttributeTable *table = (WDSmartAttributeTable *)dataPage.smartData;
        for (int i = 0; i < 30; i++) {
            if (table->attrs[i].id == 194 || table->attrs[i].id == 190) {
                printf("Drive:    %llu°C\n", WDSmartRawValue(&table->attrs[i]) & 0xFF);
                return kWDExitOK;
            }
        }
        if (!gotSomething) fprintf(stderr, "Error: No temperature attribute in SMART data\n");
    } else if (!gotSomething) {
        WDScsiPrintError("Could not read temperature");
    }
    return gotSomething ? kWDExitOK : kWDExitFailure;
}

/// Get or set the drive sleep (spindown) timer.
/// When setValue is NULL, displays current setting. Otherwise sets it.
int WDCmdSleep(SCSITaskDeviceInterface **dev, const char *setValue) {
    // Power Condition mode page (0x1A) with DBD.
    // Response layout: [0..3]=header, [4]=pageCode|PS, [5]=pageLen, [6..]=page data
    // WD standby timer is a 4-byte BE value at absolute offset 12-15 (page data byte 6-9)
    UInt8 buf[44] = {0};
    if (WDScsiModeSense(dev, 0x1A, buf, sizeof(buf)) != 0) {
        WDScsiPrintError("Could not read sleep timer");
        return kWDExitFailure;
    }
    if ((buf[4] & 0x3F) != 0x1A) {
        fprintf(stderr, "Error: Unexpected mode page 0x%02X (expected 0x1A)\n", buf[4] & 0x3F);
        return kWDExitFailure;
    }

    if (!setValue) {
        UInt32 timer = ((UInt32)buf[12] << 24) | ((UInt32)buf[13] << 16)
                     | ((UInt32)buf[14] << 8) | buf[15];
        if (timer == 0)
            printf("Sleep timer: disabled (never)\n");
        else
            printf("Sleep timer: ~%u minutes (%u seconds)\n", timer / 600, timer / 10);
        return kWDExitOK;
    }

    char *end = NULL;
    long minutes = strtol(setValue, &end, 10);
    if (!end || *end || minutes < 0 || minutes > 7158) {   // 7158 min ≈ UInt32 max / 600
        fprintf(stderr, "Usage: wd_smart sleep <minutes>   (0 = disable)\n");
        return kWDExitUsage;
    }
    UInt32 timerVal = (UInt32)minutes * 600;

    // Clear mode parameter header and PS bit
    memset(buf, 0, 4);
    buf[4] &= 0x3F;

    // buf[7] bit 0 = Standby_z enable
    if (timerVal > 0)
        buf[7] |= 0x01;
    else
        buf[7] &= ~0x01;

    // Write standby timer (4-byte BE at offset 12-15)
    buf[12] = (timerVal >> 24) & 0xFF;
    buf[13] = (timerVal >> 16) & 0xFF;
    buf[14] = (timerVal >> 8) & 0xFF;
    buf[15] = timerVal & 0xFF;

    // Parameter list length = page length + 6 (4 header + 2 page header), bounded by buffer
    UInt32 paramLen = (UInt32)buf[5] + 6;
    if (paramLen > sizeof(buf)) paramLen = sizeof(buf);
    if (paramLen < 16) paramLen = 16;   // must include the timer bytes

    int rc = WDScsiModeSelect(dev, buf, paramLen, YES);
    // Snapshot the MODE SELECT result now: the read-back below overwrites g_lastSense.
    char selErr[256];
    strlcpy(selErr, WDScsiLastErrorString(), sizeof(selErr));

    // The WD bridge frequently returns a bogus status for MODE SELECT even
    // though the write committed (observed on Passport 0748: status 0x05,
    // sense 02/04/01 and 04/00/00 on writes that all took effect).
    // Trust the read-back, not the status. If we cannot read back, we cannot
    // claim success.
    UInt8 verify[44] = {0};
    if (WDScsiModeSense(dev, 0x1A, verify, sizeof(verify)) == 0 && (verify[4] & 0x3F) == 0x1A) {
        UInt32 got = ((UInt32)verify[12] << 24) | ((UInt32)verify[13] << 16)
                   | ((UInt32)verify[14] << 8) | verify[15];
        if (got == timerVal) {
            if (minutes == 0) printf("Sleep timer disabled.\n");
            else              printf("Sleep timer set to %ld minutes.\n", minutes);
            if (rc != 0 && g_verbose)
                fprintf(stderr, "[note] bridge reported failure (%s) but write committed\n", selErr);
            return kWDExitOK;
        }
        fflush(stdout);
        fprintf(stderr, "Error: Sleep timer not applied (drive still reports %u seconds)\n", got / 10);
        if (rc != 0) fprintf(stderr, "  MODE SELECT: %s\n", selErr);
    } else {
        fflush(stdout);
        fprintf(stderr, "Error: Could not verify sleep timer (read-back failed: %s)\n", WDScsiLastErrorString());
        if (rc != 0) fprintf(stderr, "  MODE SELECT: %s\n", selErr);
    }
    if (minutes == 0)
        fprintf(stderr, "  (Some bridges enforce a minimum and reject 0. Try 'sleep 10'.)\n");
    return kWDExitFailure;
}


#pragma mark - LED Control

int WDCmdLED(SCSITaskDeviceInterface **dev, const char *setValue) {
    UInt8 buf[16] = {0};
    if (WDScsiModeSense(dev, 0x21, buf, sizeof(buf)) != 0) {
        WDScsiPrintError("LED not supported on this drive");
        return kWDExitFailure;
    }
    if ((buf[4] & 0x3F) != 0x21) {
        fprintf(stderr, "Error: LED not supported (got mode page 0x%02X, expected 0x21)\n", buf[4] & 0x3F);
        return kWDExitFailure;
    }

    if (!setValue) {
        printf("LED: %s\n", buf[12] ? "on" : "off");
        return kWDExitOK;
    }

    BOOL on;
    if (strcmp(setValue, "on") == 0) on = YES;
    else if (strcmp(setValue, "off") == 0) on = NO;
    else { fprintf(stderr, "Usage: wd_smart led [on|off]\n"); return kWDExitUsage; }

    memset(buf, 0, 4);
    buf[4] &= 0x7F;
    buf[12] = on ? 0xFF : 0x00;

    int rc = WDScsiModeSelect(dev, buf, 16, YES);
    char selErr[256];
    strlcpy(selErr, WDScsiLastErrorString(), sizeof(selErr));

    // Same bridge quirk as the sleep timer: MODE SELECT often returns a bogus
    // status while the write actually commits. Verify by reading the page back.
    UInt8 verify[16] = {0};
    if (WDScsiModeSense(dev, 0x21, verify, sizeof(verify)) == 0 && (verify[4] & 0x3F) == 0x21) {
        if (!!verify[12] == !!on) {
            printf("LED turned %s.\n", on ? "on" : "off");
            if (rc != 0 && g_verbose)
                fprintf(stderr, "[note] bridge reported failure (%s) but write committed\n", selErr);
            return kWDExitOK;
        }
        fflush(stdout);
        fprintf(stderr, "Error: LED not applied (drive still reports %s)\n", verify[12] ? "on" : "off");
        if (rc != 0) fprintf(stderr, "  MODE SELECT: %s\n", selErr);
    } else {
        fflush(stdout);
        fprintf(stderr, "Error: Could not verify LED (read-back failed: %s)\n", WDScsiLastErrorString());
        if (rc != 0) fprintf(stderr, "  MODE SELECT: %s\n", selErr);
    }
    return kWDExitFailure;
}

#pragma mark - Probe

/// Run one probe command and print a one-line result.
static int probeOne(SCSITaskDeviceInterface **dev, const char *label,
                    const UInt8 *cdbBytes, UInt8 cdbLen, UInt8 *buf, UInt32 size, UInt8 dir) {
    SCSICommandDescriptorBlock cdb = {0};
    memcpy(cdb, cdbBytes, cdbLen);
    if (buf) memset(buf, 0, size);
    int rc = WDExecSCSITask(dev, cdb, cdbLen, buf, size, dir, kTimeoutDefault);
    if (rc == 0) {
        printf("  %-34s OK", label);
        if (buf && g_lastSense.transferred) {
            printf("  [");
            UInt64 n = g_lastSense.transferred < 16 ? g_lastSense.transferred : 16;
            for (UInt64 i = 0; i < n; i++) printf("%02X%s", buf[i], i + 1 < n ? " " : "");
            if (g_lastSense.transferred > 16) printf(" …");
            printf("]");
        }
        printf("\n");
    } else if (g_lastSense.ioReturn != kIOReturnSuccess) {
        printf("  %-34s IOKit error 0x%08x\n", label, g_lastSense.ioReturn);
    } else if (g_lastSense.senseKey == 0 && g_lastSense.asc == 0 && g_lastSense.ascq == 0) {
        printf("  %-34s SCSI status %02X, no sense\n", label, g_lastSense.taskStatus);
    } else {
        // Short form: key/asc/ascq + key name (the summary explains 04/44/81)
        printf("  %-34s sense %02X/%02X/%02X (%s)\n", label,
               g_lastSense.senseKey, g_lastSense.asc, g_lastSense.ascq, WDScsiSenseKeyName(g_lastSense.senseKey));
    }
    return rc;
}

/// Enumerate what this bridge supports. Read-only; safe on any drive.
int WDCmdProbe(SCSITaskDeviceInterface **dev) {
    UInt8 buf[520];
    int ok = 0, total = 0;
    int driveOK = 0;          // successes among commands that must reach the SATA drive
    BOOL sawBridgeFault = NO; // any 04/44/xx
#define PROBE(label, dir, sz, ...) do { \
        static const UInt8 c_[] = {__VA_ARGS__}; \
        total++; \
        if (probeOne(dev, label, c_, sizeof(c_), buf, sz, dir) == 0) { ok++; if (driveSection) driveOK++; } \
        else if (g_lastSense.senseKey == 0x04 && g_lastSense.asc == 0x44) sawBridgeFault = YES; \
    } while (0)
    BOOL driveSection = NO;
    const UInt8 RX = kSCSIDataTransfer_FromTargetToInitiator;
    const UInt8 NONE = kSCSIDataTransfer_NoDataTransfer;

    printf("Standard SCSI:\n");
    PROBE("TEST UNIT READY",          NONE, 0,   0x00,0,0,0,0,0);
    total++;
    memset(buf, 0, sizeof(buf));
    if (WDScsiInquiry(dev, buf, 96) == 0) {
        ok++;
        printf("  %-34s OK  [", "INQUIRY");
        for (int i = 0; i < 16; i++) printf("%02X%s", buf[i], i < 15 ? " " : "");
        printf(" …]\n");
    } else {
        printf("  %-34s %s\n", "INQUIRY", WDScsiLastErrorString());
    }
    PROBE("INQUIRY VPD 0x00 (list)",  RX,   64,  0x12,0x01,0x00,0x00,64,0x00);
    // Decode supported VPD list
    if (buf[0] == 0x0D || buf[0] == 0x00) {
        int n = buf[3];
        if (n > 0 && n < 60) {
            printf("    supported VPD pages:");
            for (int i = 0; i < n; i++) printf(" %02X", buf[4 + i]);
            printf("\n");
        }
    }
    PROBE("INQUIRY VPD 0x80 (serial)", RX,  64,  0x12,0x01,0x80,0x00,64,0x00);
    PROBE("INQUIRY VPD 0xB1 (RPM)",   RX,   64,  0x12,0x01,0xB1,0x00,64,0x00);
    PROBE("INQUIRY VPD 0xC1 (ports)", RX,   36,  0x12,0x01,0xC1,0x00,36,0x00);
    PROBE("INQUIRY VPD 0xC2 (capacity)", RX, 24, 0x12,0x01,0xC2,0x00,24,0x00);
    PROBE("INQUIRY VPD 0xC4 (product)", RX, 255, 0x12,0x01,0xC4,0x00,255,0x00);

    driveSection = YES;
    printf("\nDiagnostic pages (RECEIVE DIAGNOSTIC 0x1C):\n");
    PROBE("0x00 supported pages",      RX,   64,  0x1C,0x01,0x00,0x00,64,0x00);
    if (buf[0] == 0x00) {
        int n = ((int)buf[2] << 8) | buf[3];
        if (n > 0 && n < 60) {
            printf("    supported diag pages:");
            for (int i = 0; i < n; i++) printf(" %02X", buf[4 + i]);
            printf("\n");
        }
    }
    PROBE("0x83 encryption (simple)",  RX,   8,   0x1C,0x01,0x83,0x00,8,0x00);
    PROBE("0x84 SMART status",         RX,   8,   0x1C,0x01,0x84,0x00,8,0x00);
    PROBE("0x85 SMART data",           RX,   520, 0x1C,0x01,0x85,0x02,0x08,0x00);
    PROBE("0x86 temperature/fan",      RX,   16,  0x1C,0x01,0x86,0x00,16,0x00);

    printf("\nLog / mode pages:\n");
    PROBE("LOG SENSE 0x00 (list)",     RX,   64,  0x4D,0x00,0x40,0,0,0,0,0x00,64,0x00);
    PROBE("LOG SENSE 0x10 (self-test)", RX,  404, 0x4D,0x00,0x50,0,0,0,0,0x01,0x94,0x00);
    PROBE("MODE SENSE 0x1A (power)",   RX,   44,  0x1A,0x08,0x1A,0x00,44,0x00);
    PROBE("MODE SENSE 0x21 (LED)",     RX,   16,  0x1A,0x08,0x21,0x00,16,0x00);
    PROBE("MODE SENSE 0x24 (VCD)",     RX,   16,  0x1A,0x08,0x24,0x00,16,0x00);

    printf("\nWD vendor commands:\n");
    PROBE("C0/45 encryption status",   RX,   48,  0xC0,0x45,0,0,0,0,0,0,0x30,0x00);
    PROBE("D8 Handy Store read blk 1", RX,   512, 0xD8,0,0,0,0,1,0,0,0x01,0x00);
    PROBE("A2 Optimus probe",          RX,   16,  0xA2,0,0,0,0,0,0,0,0,16,0,0);
#undef PROBE

    printf("\n%d/%d commands succeeded.\n", ok, total);
    if (driveOK == 0) {
        printf("\nDIAGNOSIS: Only INQUIRY-class commands work. The bridge answers from its own\n"
               "firmware but cannot reach the SATA drive%s.\n"
               "  1. TRY A DIFFERENT PORT AND CABLE FIRST — this has been seen to fix it outright\n"
               "  2. Plug directly into the Mac (no hub/dock); bus-powered drives need a full-power port\n"
               "  3. Unplug, wait 10 s, replug\n"
               "  4. Quit WD Discovery / WD Security / WD Drive Utilities\n"
               "     (killall WDDriveUtilityHelper WDSecurityHelper)\n"
               "  5. Close browser tabs holding WebUSB access to the drive\n"
               "  6. If it persists across several ports and cables, the drive or bridge has failed\n",
               sawBridgeFault ? " (sense 04/44/xx = internal target failure)" : "");
        return kWDExitFailure;
    }
    return kWDExitOK;
}

#pragma mark - Power and Erase

int WDCmdPowerOff(SCSITaskDeviceInterface **dev) {
    // Unmount first so macOS doesn't log "Disk Not Ejected Properly" and no
    // dirty page-cache is lost. Best effort: a drive with no block device
    // (locked / failed enumeration) simply has nothing to unmount.
    NSString *bsd = g_diskBSDName();
    if (bsd) {
        printf("Unmounting /dev/%s...\n", [bsd UTF8String]);
        fflush(stdout);
#ifndef TESTING
        WDUnmountDisk(bsd);
#endif
    }

    // WD power control via diagnostic page 0x80
    UInt8 page[8] = {0};
    page[0] = 0x80;   // page code
    page[3] = 0x04;   // page length
    page[4] = 0x01;   // bit 0 = PowerOff

    if (WDScsiSendDiagnosticPage(dev, page, sizeof(page)) == 0) {
        printf("Drive powered off safely. You can disconnect it now.\n");
        return kWDExitOK;
    }
    WDScsiPrintError("Power off failed");
    fprintf(stderr, "  Try 'diskutil eject /dev/diskN' instead.\n");
    return kWDExitFailure;
}

/// Erase the drive using diskutil (same method as WD Drive Utilities).
/// Repartitions with a single ExFAT volume named after the product.
int WDCmdErase(SCSITaskDeviceInterface **dev, int argc, const char *argv[]) {
    (void)dev;
    if (!hasConfirmFlag(argc, argv)) {
        fprintf(stderr,
            "WARNING: This will PERMANENTLY ERASE ALL DATA on the drive.\n"
            "         This operation is IRREVERSIBLE.\n\n"
            "To proceed, run:\n"
            "  sudo wd_smart erase --confirm\n");
        return kWDExitUsage;
    }

    NSString *bsdName = g_diskBSDName();
    if (!bsdName) {
        fprintf(stderr, "Error: Could not find WD disk device (is the drive locked or not spun up?)\n");
        return kWDExitFailure;
    }

    // Volume label from the product name, e.g. "My Passport" / "My Book"
    WDDriveIdentity ident = g_driveIdentity(NULL);
    NSString *label = @"WD Drive";
    if (ident.found && ident.product[0]) {
        NSString *p = @(ident.product);
        NSRange r = [p rangeOfString:@" " options:NSBackwardsSearch];
        if (r.location != NSNotFound && r.location > 0) p = [p substringToIndex:r.location]; // drop model suffix
        if (p.length) label = p;
    }

    fprintf(stderr, "*** ALL DATA ON /dev/%s WILL BE DESTROYED ***\n", [bsdName UTF8String]);
    fprintf(stderr, "Press Ctrl-C to cancel.\n\n");
#ifdef TESTING
    fprintf(stderr, "[TESTING] would run: diskutil eraseDisk ExFAT \"%s\" GPT /dev/%s\n",
            [label UTF8String], [bsdName UTF8String]);
    return kWDExitOK;
#else
    for (int i = 5; i > 0; i--) {
        fprintf(stderr, "  Erasing in %d...\n", i);
        sleep(1);
    }

    fprintf(stderr, "Erasing /dev/%s...\n", [bsdName UTF8String]);

    // Use NSTask + diskutil eraseDisk (same as WD Drive Utilities)
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/sbin/diskutil"];
    [task setArguments:@[@"eraseDisk", @"ExFAT", label, @"GPT",
                         [NSString stringWithFormat:@"/dev/%@", bsdName]]];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    @try {
        [task launch];
    } @catch (NSException *e) {
        fprintf(stderr, "Error: Could not launch diskutil: %s\n", [[e reason] UTF8String]);
        return kWDExitFailure;
    }
    [task waitUntilExit];

    NSData *output = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *result = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"";

    if ([task terminationStatus] == 0) {
        printf("Erase complete. Drive formatted as ExFAT (\"%s\").\n", [label UTF8String]);
        return kWDExitOK;
    }
    fprintf(stderr, "Error: Erase failed (diskutil exit %d).\n%s\n",
            [task terminationStatus], [result UTF8String]);
    return kWDExitFailure;
#endif
}


#pragma mark - Secure Erase

/// Secure erase: overwrite every sector with zeros.
/// This is a full single-pass zero-fill — every byte on disk becomes 0x00.
/// Requires --confirm and gives a 10-second countdown before starting.
int WDCmdSecureErase(int argc, const char *argv[]) {
    if (!hasConfirmFlag(argc, argv)) {
        fprintf(stderr,
            "WARNING: SECURE ERASE writes zeros to EVERY SECTOR on the drive.\n"
            "         This is IRREVERSIBLE and will take 20+ hours on 18TB.\n\n"
            "To proceed, run:\n"
            "  sudo wd_smart secure-erase --confirm\n");
        return kWDExitUsage;
    }

    if (geteuid() != 0) {
        fprintf(stderr, "Error: secure-erase must run as root (writes to /dev/rdiskN).\n");
        return kWDExitFailure;
    }

    // Find the WD disk's BSD name
    NSString *bsdName = g_diskBSDName();
    if (!bsdName) {
        fprintf(stderr, "Error: Could not find WD disk device\n");
        return kWDExitFailure;
    }

    printf("Target: /dev/%s\n\n", [bsdName UTF8String]);

#ifdef TESTING
    fprintf(stderr, "[TESTING] would zero-fill /dev/r%s\n", [bsdName UTF8String]);
    return kWDExitOK;
#else
    // 10-second countdown (longer due to severity)
    fprintf(stderr, "*** SECURE ERASE: EVERY BYTE WILL BE OVERWRITTEN WITH ZEROS ***\n");
    fprintf(stderr, "*** This will take many hours. Press Ctrl-C to cancel. ***\n\n");
    for (int i = 10; i > 0; i--) {
        fprintf(stderr, "  Starting in %d...\n", i);
        sleep(1);
    }

    // Unmount all volumes using DiskArbitration
    if (!WDUnmountDisk(bsdName))
        fprintf(stderr, "Warning: could not issue unmount; continuing\n");

    // Open raw character device for writing
    NSString *rawPath = [NSString stringWithFormat:@"/dev/r%@", bsdName];
    int fd = open([rawPath UTF8String], O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "Error: Could not open %s: %s\n",
                [rawPath UTF8String], strerror(errno));
        return kWDExitFailure;
    }

    // Get device size via ioctl
    UInt64 blockCount = 0;
    UInt32 blockSize = 512;
    if (ioctl(fd, DKIOCGETBLOCKCOUNT, &blockCount) != 0) blockCount = 0;
    if (ioctl(fd, DKIOCGETBLOCKSIZE, &blockSize) != 0) blockSize = 512;
    UInt64 deviceSize = blockCount * blockSize;

    // Write zeros in 4MB chunks (USB3-friendly) with progress reporting
    const size_t chunkSize = 4 * 1024 * 1024;
    void *zeros = calloc(1, chunkSize);
    if (!zeros) { close(fd); fprintf(stderr, "Error: Out of memory\n"); return kWDExitFailure; }

    UInt64 written = 0;
    time_t startTime = time(NULL);
    time_t lastReport = 0;
    int rc = kWDExitOK;

    printf("\nSecure erase in progress...\n");

    for (;;) {
        size_t want = chunkSize;
        if (deviceSize && deviceSize - written < want) want = (size_t)(deviceSize - written);
        if (want == 0) break;
        ssize_t n = write(fd, zeros, want);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == ENOSPC) break;   // reached end of device
            fprintf(stderr, "\nError: write failed at %llu bytes: %s\n", written, strerror(errno));
            rc = kWDExitFailure;
            break;
        }
        if (n == 0) break;
        written += (UInt64)n;

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
    fsync(fd);
    close(fd);

    double elapsed = difftime(time(NULL), startTime);
    printf("\n\nSecure erase %s.\n", rc == kWDExitOK ? "complete" : "INCOMPLETE");
    printf("  Written: %.2f TB\n", (double)written / 1e12);
    printf("  Time:    %.1f hours\n", elapsed / 3600.0);
    if (elapsed > 0)
        printf("  Speed:   %.1f MB/s average\n", (double)written / elapsed / 1e6);
    return rc;
#endif
}
