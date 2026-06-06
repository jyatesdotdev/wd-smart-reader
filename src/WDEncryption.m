//
//  WDEncryption.m
//  Password cooking and encryption commands.
//

#import "WDSmart.h"

#pragma mark - Password Cooking

int WDCookPassword(SCSITaskDeviceInterface **dev, const char *password, UInt8 *cookedOut) {
    // Read Handy Store block 1
    UInt8 hsBlock[512] = {0};
    if (WDScsiReadHandyStore(dev, 1, hsBlock, sizeof(hsBlock)) != 0) {
        fprintf(stderr, "Error: Could not read security parameters\n");
        return -1;
    }

    // Verify security block signature (bytes 0-3 should be 00 01 44 57)
    if (hsBlock[2] != 0x44 || hsBlock[3] != 0x57) {
        // Initialize the security block
        memset(hsBlock, 0, 512);
        hsBlock[0] = 0x00; hsBlock[1] = 0x01; hsBlock[2] = 0x44; hsBlock[3] = 0x57;
        // Default salt "WDC." in UTF-16LE at offset 0x0C
        UInt8 defaultSalt[] = {0x57, 0x00, 0x44, 0x00, 0x43, 0x00, 0x2E, 0x00};
        memcpy(&hsBlock[0x0C], defaultSalt, 8);
    }

    // Ensure iterations are set (offset 0x08, 32-bit LE)
    UInt32 iterations = ((UInt32)hsBlock[8]) | ((UInt32)hsBlock[9] << 8)
                      | ((UInt32)hsBlock[10] << 16) | ((UInt32)hsBlock[11] << 24);
    if (iterations == 0) {
        iterations = 1000;
        hsBlock[8] = iterations & 0xFF;
        hsBlock[9] = (iterations >> 8) & 0xFF;
        hsBlock[10] = (iterations >> 16) & 0xFF;
        hsBlock[11] = (iterations >> 24) & 0xFF;

        // Recalculate checksum: sum bytes 0-510, negate, store at 511
        UInt8 sum = 0;
        for (int i = 0; i < 511; i++) sum += hsBlock[i];
        hsBlock[511] = (UInt8)(-(int8_t)sum);

        // Write back
        if (WDScsiWriteHandyStore(dev, 1, hsBlock, sizeof(hsBlock)) != 0) {
            fprintf(stderr, "Error: Could not write security parameters\n");
            return -1;
        }
    }

    // Extract salt (UTF-16LE at offset 0x0C)
    int saltLen = 0;
    for (int i = 0x0C; i < 0x1C; i += 2) {
        if (hsBlock[i] == 0 && hsBlock[i+1] == 0) break;
        saltLen += 2;
    }

    // Build combined UTF-16LE: salt + password
    NSString *passwordStr = [NSString stringWithUTF8String:password];
    NSData *passwordUTF16 = [passwordStr dataUsingEncoding:NSUTF16LittleEndianStringEncoding];

    NSMutableData *combined = [NSMutableData dataWithBytes:&hsBlock[0x0C] length:saltLen];
    [combined appendData:passwordUTF16];

    // SHA-256
    CC_SHA256([combined bytes], (CC_LONG)[combined length], cookedOut);
    return 0;
}

/// Send a WD encryption command. Tries Optimus protocol (0xB5/0xEF) first,
/// falls back to legacy (0xC1) if Optimus fails.
/// Send an encryption command using the legacy 0xC1 protocol.
/// Page format: 0x48 bytes, signature 0x45 at byte 0.
///   Arm:    CDB=C1 E2, page[3]=0x01, password at offset 0x28
///   Disarm: CDB=C1 E2, page[3]=0x10, password at offset 0x08
///   Unlock: CDB=C1 E1, page[3]=0x01, password at offset 0x08

#pragma mark - Encryption Commands

int WDScsiEncryptLegacy(SCSITaskDeviceInterface **dev, UInt8 subCmd, UInt8 flag, UInt8 *cooked, int pwOffset) {
    // Unlock uses 0x28-byte page; arm/disarm use 0x48
    UInt8 pageSize = (subCmd == 0xE1) ? 0x28 : 0x48;
    UInt8 page[0x48] = {0};
    page[0] = 0x45;
    page[3] = flag;
    page[7] = 32;
    memcpy(&page[pwOffset], cooked, 32);

    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0xC1;
    cdb[1] = subCmd;
    cdb[8] = pageSize;
    return WDExecSCSITask(dev, cdb, kSCSICDBSize_10Byte, page, pageSize,
                        kSCSIDataTransfer_FromInitiatorToTarget, 60000);
}

/// Set a password (arm encryption). Drive locks on next power cycle.
void WDCmdSetPassword(SCSITaskDeviceInterface **dev, int argc, const char *argv[], int argOffset) {
    if (argc <= argOffset + 1) {
        fprintf(stderr, "Usage: wd_smart set-password <password>\n");
        return;
    }
    const char *password = argv[argOffset + 1];
    if (strlen(password) < 1 || strlen(password) > 32) {
        fprintf(stderr, "Error: Password must be 1-32 characters\n");
        return;
    }

    UInt8 cooked[32] = {0};
    if (WDCookPassword(dev, password, cooked) != 0) return;

    if (WDScsiEncryptLegacy(dev, 0xE2, 0x01, cooked, 0x28) == 0)
        printf("Password set. Drive will lock on next power cycle.\n"
               "Use 'unlock' to access after reconnecting.\n");
    else
        fprintf(stderr, "Error: Could not set password (drive may not support user encryption)\n");
}

/// Unlock a locked drive with password.
void WDCmdUnlock(SCSITaskDeviceInterface **dev, int argc, const char *argv[], int argOffset) {
    if (argc <= argOffset + 1) {
        fprintf(stderr, "Usage: wd_smart unlock <password>\n");
        return;
    }
    const char *password = argv[argOffset + 1];

    UInt8 cooked[32] = {0};
    if (WDCookPassword(dev, password, cooked) != 0) return;

    if (WDScsiEncryptLegacy(dev, 0xE1, 0x00, cooked, 0x08) == 0)
        printf("Drive unlocked.\n");
    else
        fprintf(stderr, "Error: Unlock failed (wrong password?)\n");
}

/// Remove password (disarm encryption). Requires current password.
void WDCmdRemovePassword(SCSITaskDeviceInterface **dev, int argc, const char *argv[], int argOffset) {
    if (argc <= argOffset + 1) {
        fprintf(stderr, "Usage: wd_smart remove-password <current-password>\n");
        return;
    }
    const char *password = argv[argOffset + 1];

    UInt8 cooked[32] = {0};
    if (WDCookPassword(dev, password, cooked) != 0) return;

    if (WDScsiEncryptLegacy(dev, 0xE2, 0x10, cooked, 0x08) == 0)
        printf("Password removed. Encryption disabled.\n");
    else
        fprintf(stderr, "Error: Could not remove password (wrong password?)\n");
}

/// Reset the Data Encryption Key. DESTROYS ALL DATA. Requires --confirm.
void WDCmdResetDEK(SCSITaskDeviceInterface **dev, int argc, const char *argv[]) {
    BOOL confirmed = NO;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--confirm") == 0) confirmed = YES;
    }
    if (!confirmed) {
        fprintf(stderr,
            "WARNING: reset-dek generates a new encryption key.\n"
            "         ALL DATA ON THE DRIVE WILL BE PERMANENTLY LOST.\n"
            "         The drive will be usable again but empty.\n\n"
            "To proceed, run:\n"
            "  sudo wd_smart reset-dek --confirm\n");
        return;
    }

    fprintf(stderr, "*** RESETTING ENCRYPTION KEY — ALL DATA WILL BE DESTROYED ***\n");
#ifndef TESTING
    for (int i = 5; i > 0; i--) {
        fprintf(stderr, "  Resetting in %d... (Ctrl-C to cancel)\n", i);
        sleep(1);
    }
#endif

    // Reset DEK: C1 E3 with KRE in CDB bytes 2-5, data page with cipher + random seed
    UInt8 stBuf[48] = {0};
    SCSICommandDescriptorBlock stcdb = {0};
    stcdb[0] = 0xC0; stcdb[1] = 0x45; stcdb[8] = 0x30;
    if (WDExecSCSITask(dev, stcdb, kSCSICDBSize_10Byte, stBuf, 48,
                     kSCSIDataTransfer_FromTargetToInitiator, 10000) != 0) {
        fprintf(stderr, "Error: Could not read encryption status\n");
        return;
    }

    UInt8 cipher = stBuf[4];
    UInt8 page[0x28] = {0};
    page[0] = 0x45;   // signature
    page[3] = 0x01;   // flag
    page[4] = cipher; // cipher ID from status

    // Fill DEK seed with random bytes
    UInt8 xferLen = 0x08; // minimum
    if (cipher == 0x20 || cipher == 0x28 || cipher == 0x30) {
        xferLen = 0x28; // 8 header + 32 random bytes
        page[7] = 0x01; // count
        FILE *rnd = fopen("/dev/random", "r");
        if (rnd) {
            for (int i = 0; i < 32; i++) page[8 + i] = fgetc(rnd);
            fclose(rnd);
        }
    }

    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0xC1;
    cdb[1] = 0xE3;
    cdb[2] = stBuf[8];  // KRE byte 0
    cdb[3] = stBuf[9];  // KRE byte 1
    cdb[4] = stBuf[10]; // KRE byte 2
    cdb[5] = stBuf[11]; // KRE byte 3
    cdb[8] = xferLen;

    if (WDExecSCSITask(dev, cdb, kSCSICDBSize_10Byte, page, xferLen,
                     kSCSIDataTransfer_FromInitiatorToTarget, 60000) == 0)
        printf("DEK reset complete. All data has been erased.\n"
               "The drive is now usable without a password.\n");
    else
        fprintf(stderr, "Error: Could not reset DEK (not supported on this drive)\n");
}

/// Safely power off the drive (spin down + disconnect).
/// After this command, the drive can be physically unplugged.
