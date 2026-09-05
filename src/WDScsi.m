//
//  WDScsi.m
//  SCSI abstraction layer and command wrappers.
//

#import "WDSmart.h"

#pragma mark - Globals

WDScsiSense g_lastSense = {0};
int g_verbose = 0;

#pragma mark - Sense Decoding

static const char *senseKeyName(UInt8 key) {
    switch (key) {
        case 0x0: return "No Sense";
        case 0x1: return "Recovered Error";
        case 0x2: return "Not Ready";
        case 0x3: return "Medium Error";
        case 0x4: return "Hardware Error";
        case 0x5: return "Illegal Request";
        case 0x6: return "Unit Attention";
        case 0x7: return "Data Protect";
        case 0x8: return "Blank Check";
        case 0xB: return "Aborted Command";
        default:  return "Reserved";
    }
}

static const char *taskStatusName(UInt8 st) {
    switch (st) {
        case 0x00: return "GOOD";
        case 0x02: return "CHECK CONDITION";
        case 0x04: return "CONDITION MET";
        case 0x08: return "BUSY";
        case 0x10: return "INTERMEDIATE";
        case 0x14: return "INTERMEDIATE CONDITION MET";
        case 0x18: return "RESERVATION CONFLICT";
        case 0x22: return "COMMAND TERMINATED";
        case 0x28: return "QUEUE FULL";
        case 0x30: return "ACA ACTIVE";
        case 0x40: return "TASK ABORTED";
        default:   return "unknown";
    }
}

/// Decode common ASC/ASCQ pairs, including WD-bridge-specific meanings
/// learned from hardware testing (see AGENTS.md).
static const char *ascName(UInt8 asc, UInt8 ascq) {
    switch ((asc << 8) | ascq) {
        case 0x0000: return "No additional sense";
        case 0x0400: return "LUN not ready, cause not reportable";
        case 0x0401: return "LUN is in process of becoming ready";
        case 0x0402: return "LUN not ready, initializing command required";
        case 0x1A00: return "Parameter list length error";
        case 0x2000: return "Invalid command operation code (unsupported)";
        case 0x2400: return "Invalid field in CDB";
        case 0x2500: return "Logical unit not supported";
        case 0x2600: return "Invalid field in parameter list";
        case 0x2900: return "Power on, reset, or bus device reset occurred";
        case 0x3A00: return "Medium not present";
        case 0x4400: return "Internal target failure";
        case 0x4481: return "Internal target failure: bridge cannot reach the SATA drive "
                            "(drive not spinning / locked / SATA link down — try power-cycling the enclosure)";
        case 0x7440: return "Invalid data in page (WD: wrong password or wrong page layout)";
        default:     return NULL;
    }
}

const char *WDScsiLastErrorString(void) {
    static char buf[256];
    const WDScsiSense *s = &g_lastSense;
    if (!s->valid) {
        snprintf(buf, sizeof(buf), "no command executed");
    } else if (s->ioReturn != kIOReturnSuccess) {
        snprintf(buf, sizeof(buf), "IOKit error 0x%08x", s->ioReturn);
    } else if (s->taskStatus != kSCSITaskStatus_GOOD) {
        const char *desc = ascName(s->asc, s->ascq);
        const char *st = taskStatusName(s->taskStatus);
        if (s->senseKey == 0 && s->asc == 0 && s->ascq == 0)
            snprintf(buf, sizeof(buf), "SCSI status %02X (%s), no sense data", s->taskStatus, st);
        else if (desc)
            snprintf(buf, sizeof(buf), "sense %02X/%02X/%02X (%s: %s)",
                     s->senseKey, s->asc, s->ascq, senseKeyName(s->senseKey), desc);
        else
            snprintf(buf, sizeof(buf), "sense %02X/%02X/%02X (%s, status %02X)",
                     s->senseKey, s->asc, s->ascq, senseKeyName(s->senseKey), s->taskStatus);
    } else {
        snprintf(buf, sizeof(buf), "OK (%llu bytes)", s->transferred);
    }
    return buf;
}

void WDScsiPrintError(const char *msg) {
    fflush(stdout);   // keep ordering sane when stdout is piped/buffered
    fprintf(stderr, "Error: %s — %s\n", msg, WDScsiLastErrorString());
}

#pragma mark - Transport

int WDExecSCSITaskReal(void *ctx,
                            SCSICommandDescriptorBlock cdb,
                            UInt8 cdbSize,
                            void *buffer,
                            UInt32 bufferSize,
                            UInt8 direction,
                            UInt32 timeout) {
    SCSITaskDeviceInterface **dev = (SCSITaskDeviceInterface **)ctx;

    memset(&g_lastSense, 0, sizeof(g_lastSense));
    g_lastSense.valid = YES;

    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
    if (!task) {
        g_lastSense.ioReturn = kIOReturnNoResources;
        return kWDScsiErrNoTask;
    }

    IOVirtualRange range = { .address = (IOVirtualAddress)buffer, .length = bufferSize };

    (*task)->SetCommandDescriptorBlock(task, cdb, cdbSize);

    if (buffer && bufferSize > 0) {
        (*task)->SetScatterGatherEntries(task, &range, 1, bufferSize, direction);
    } else {
        (*task)->SetScatterGatherEntries(task, NULL, 0, 0, kSCSIDataTransfer_NoDataTransfer);
    }

    (*task)->SetTimeoutDuration(task, timeout);

    SCSI_Sense_Data sense = {0};
    SCSITaskStatus status = 0;
    UInt64 transferred = 0;
    IOReturn result = (*task)->ExecuteTaskSync(task, &sense, &status, &transferred);
    (*task)->Release(task);

    g_lastSense.ioReturn    = result;
    g_lastSense.taskStatus  = (UInt8)status;
    g_lastSense.senseKey    = sense.SENSE_KEY & 0x0F;
    g_lastSense.asc         = sense.ADDITIONAL_SENSE_CODE;
    g_lastSense.ascq        = sense.ADDITIONAL_SENSE_CODE_QUALIFIER;
    g_lastSense.transferred = transferred;

    if (result != kIOReturnSuccess) return kWDScsiErrTransport;
    if (status != kSCSITaskStatus_GOOD) return kWDScsiErrCheck;
    return kWDScsiOK;
}

/// Global SCSI execution function — points to real hardware by default.
/// Tests override this to inject mock behavior.
WDScsiExecFn g_scsiExec = WDExecSCSITaskReal;
void *g_scsiCtx = NULL;

/// Execute a SCSI task through the abstraction layer.
int WDExecSCSITask(SCSITaskDeviceInterface **dev,
                        SCSICommandDescriptorBlock cdb,
                        UInt8 cdbSize,
                        void *buffer,
                        UInt32 bufferSize,
                        UInt8 direction,
                        UInt32 timeout) {
    void *ctx = g_scsiCtx ? g_scsiCtx : (void *)dev;
    int rc = g_scsiExec(ctx, cdb, cdbSize, buffer, bufferSize, direction, timeout);

    if (g_verbose) {
        fprintf(stderr, "[scsi] CDB:");
        for (int i = 0; i < cdbSize; i++) fprintf(stderr, " %02X", cdb[i]);
        fprintf(stderr, "  len=%u dir=%s  -> %s\n", bufferSize,
                direction == kSCSIDataTransfer_FromTargetToInitiator ? "in" :
                direction == kSCSIDataTransfer_FromInitiatorToTarget ? "out" : "none",
                WDScsiLastErrorString());
    }
    return rc;
}

#pragma mark - Command Wrappers

int WDScsiReceiveDiagnostic(SCSITaskDeviceInterface **dev, UInt8 page, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x1C;                    // RECEIVE DIAGNOSTIC RESULTS
    cdb[1] = 0x01;                    // PCV (page code valid)
    cdb[2] = page;                    // page code
    cdb[3] = (size >> 8) & 0xFF;      // allocation length MSB
    cdb[4] = size & 0xFF;             // allocation length LSB
    return WDExecSCSITask(dev, cdb, kSCSICDBSize_6Byte, buf, size,
                        kSCSIDataTransfer_FromTargetToInitiator, kTimeoutDefault);
}

/// SEND DIAGNOSTIC (opcode 0x1D) — initiates a self-test.
/// Note: WD SES devices require the self-test code in bits 7:5 but reject
/// the standard SelfTest bit (bit 2). This is non-standard but matches the
/// behavior of WD Drive Utilities.
int WDScsiSendDiagnosticSelfTest(SCSITaskDeviceInterface **dev, UInt8 testCode) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x1D;                    // SEND DIAGNOSTIC
    cdb[1] = (testCode << 5);         // self-test code in bits 7:5, NO SelfTest bit
    return WDExecSCSITask(dev, cdb, kSCSICDBSize_6Byte, NULL, 0,
                        kSCSIDataTransfer_NoDataTransfer, kTimeoutLong);
}

/// SEND DIAGNOSTIC (opcode 0x1D) with parameter data — sends a diagnostic page.
int WDScsiSendDiagnosticPage(SCSITaskDeviceInterface **dev, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x1D;                    // SEND DIAGNOSTIC
    cdb[1] = 0x10;                    // PF (page format)
    cdb[3] = (size >> 8) & 0xFF;      // parameter list length MSB
    cdb[4] = size & 0xFF;             // parameter list length LSB
    return WDExecSCSITask(dev, cdb, kSCSICDBSize_6Byte, buf, size,
                        kSCSIDataTransfer_FromInitiatorToTarget, kTimeoutDefault);
}

/// LOG SENSE (opcode 0x4D) — reads a log page.
int WDScsiLogSense(SCSITaskDeviceInterface **dev, UInt8 page, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x4D;                    // LOG SENSE
    cdb[2] = 0x40 | page;            // PC=01 (current cumulative) | page code
    cdb[7] = (size >> 8) & 0xFF;      // allocation length MSB
    cdb[8] = size & 0xFF;             // allocation length LSB
    return WDExecSCSITask(dev, cdb, kSCSICDBSize_10Byte, buf, size,
                        kSCSIDataTransfer_FromTargetToInitiator, kTimeoutDefault);
}

/// MODE SENSE (6) (opcode 0x1A) — reads a mode page.
int WDScsiModeSense(SCSITaskDeviceInterface **dev, UInt8 page, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x1A;                    // MODE SENSE (6)
    cdb[1] = 0x08;                    // DBD (disable block descriptors)
    cdb[2] = page;                    // page code
    cdb[4] = size & 0xFF;             // allocation length
    return WDExecSCSITask(dev, cdb, kSCSICDBSize_6Byte, buf, size,
                        kSCSIDataTransfer_FromTargetToInitiator, kTimeoutDefault);
}

/// MODE SELECT (6) (opcode 0x15) — writes a mode page.
int WDScsiModeSelect(SCSITaskDeviceInterface **dev, void *buf, UInt32 size, BOOL save) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x15;                    // MODE SELECT (6)
    cdb[1] = 0x10 | (save ? 0x01 : 0x00); // PF (page format) + SP (save pages)
    cdb[4] = size & 0xFF;             // parameter list length
    return WDExecSCSITask(dev, cdb, kSCSICDBSize_6Byte, buf, size,
                        kSCSIDataTransfer_FromInitiatorToTarget, kTimeoutDefault);
}

/// INQUIRY (opcode 0x12) — standard inquiry data.
int WDScsiInquiry(SCSITaskDeviceInterface **dev, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x12;                    // INQUIRY
    cdb[3] = (size >> 8) & 0xFF;      // allocation length MSB
    cdb[4] = size & 0xFF;             // allocation length LSB
    return WDExecSCSITask(dev, cdb, kSCSICDBSize_6Byte, buf, size,
                        kSCSIDataTransfer_FromTargetToInitiator, kTimeoutShort);
}

/// INQUIRY with EVPD (opcode 0x12) — vital product data page.
int WDScsiInquiryVPD(SCSITaskDeviceInterface **dev, UInt8 page, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0x12;                    // INQUIRY
    cdb[1] = 0x01;                    // EVPD (enable vital product data)
    cdb[2] = page;                    // page code
    cdb[3] = (size >> 8) & 0xFF;      // allocation length MSB
    cdb[4] = size & 0xFF;             // allocation length LSB
    return WDExecSCSITask(dev, cdb, kSCSICDBSize_6Byte, buf, size,
                        kSCSIDataTransfer_FromTargetToInitiator, kTimeoutShort);
}


#pragma mark - Handy Store

int WDScsiReadHandyStore(SCSITaskDeviceInterface **dev, UInt32 block, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0xD8;
    cdb[2] = (block >> 24) & 0xFF;
    cdb[3] = (block >> 16) & 0xFF;
    cdb[4] = (block >> 8) & 0xFF;
    cdb[5] = block & 0xFF;
    cdb[6] = 0x00;  // LUN 0
    cdb[8] = 0x01;  // 1 block
    return WDExecSCSITask(dev, cdb, kSCSICDBSize_10Byte, buf, size,
                        kSCSIDataTransfer_FromTargetToInitiator, 15000);
}

/// Write a Handy Store block (WD vendor command 0xDA).
int WDScsiWriteHandyStore(SCSITaskDeviceInterface **dev, UInt32 block, void *buf, UInt32 size) {
    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0xDA;
    cdb[2] = (block >> 24) & 0xFF;
    cdb[3] = (block >> 16) & 0xFF;
    cdb[4] = (block >> 8) & 0xFF;
    cdb[5] = block & 0xFF;
    cdb[6] = 0x00;
    cdb[8] = 0x01;
    return WDExecSCSITask(dev, cdb, kSCSICDBSize_10Byte, buf, size,
                        kSCSIDataTransfer_FromInitiatorToTarget, 15000);
}
