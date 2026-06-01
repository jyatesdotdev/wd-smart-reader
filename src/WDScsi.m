//
//  WDScsi.m
//  SCSI abstraction layer and command wrappers.
//

#import "WDSmart.h"



#pragma mark - Transport

int WDExecSCSITaskReal(void *ctx,
                            SCSICommandDescriptorBlock cdb,
                            UInt8 cdbSize,
                            void *buffer,
                            UInt32 bufferSize,
                            UInt8 direction,
                            UInt32 timeout) {
    SCSITaskDeviceInterface **dev = (SCSITaskDeviceInterface **)ctx;
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
    return g_scsiExec(ctx, cdb, cdbSize, buffer, bufferSize, direction, timeout);
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

/// Cook a password: ensure Handy Store has valid security params, then hash.
