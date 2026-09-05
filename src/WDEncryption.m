//
//  WDEncryption.m
//  Password cooking and encryption commands.
//
//  Protocol reference: AGENTS.md "Encryption Protocol". Page layouts were
//  verified against WD Drive Utilities (see ghidra_decompiled.txt).
//

#import "WDSmart.h"

#pragma mark - Password Cooking

/// Derive the 32-byte "cooked" password the bridge expects.
///
/// Handy Store block 1 holds a UTF-16LE salt (usually "WDC.") and an iteration
/// count (usually 1000). The algorithm matches cookpw.py / wdpassport-utils and
/// WD's Windows/macOS tools:
///   1. Decode salt to characters, concatenate the password string
///   2. Encode as UTF-16LE (no BOM)
///   3. SHA-256, repeated `iterations` times (each round hashes the previous digest)
///
/// A single SHA-256 (the old implementation) is what the drive rejects as
/// 05/74/40 "wrong password".
int WDCookPassword(SCSITaskDeviceInterface **dev, const char *password, UInt8 *cookedOut) {
    if (!password || !cookedOut) return -1;

    // Password must be valid UTF-8 (argv could contain anything)
    NSString *passwordStr = [NSString stringWithUTF8String:password];
    if (!passwordStr) {
        fprintf(stderr, "Error: Password is not valid UTF-8\n");
        return -1;
    }

    // Read Handy Store block 1
    UInt8 hsBlock[512] = {0};
    if (WDScsiReadHandyStore(dev, 1, hsBlock, sizeof(hsBlock)) != 0) {
        WDScsiPrintError("Could not read security parameters (Handy Store)");
        return -1;
    }

    BOOL needsWrite = NO;

    // Verify security block signature (bytes 0-3 should be 00 01 44 57)
    if (hsBlock[2] != 0x44 || hsBlock[3] != 0x57) {
        // Initialize the security block
        memset(hsBlock, 0, 512);
        hsBlock[0] = 0x00; hsBlock[1] = 0x01; hsBlock[2] = 0x44; hsBlock[3] = 0x57;
        // Default salt "WDC." in UTF-16LE at offset 0x0C
        UInt8 defaultSalt[] = {0x57, 0x00, 0x44, 0x00, 0x43, 0x00, 0x2E, 0x00};
        memcpy(&hsBlock[0x0C], defaultSalt, 8);
        needsWrite = YES;
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
        needsWrite = YES;
    }

    if (needsWrite) {
        // Recalculate checksum: sum bytes 0-510, negate, store at 511
        UInt8 sum = 0;
        for (int i = 0; i < 511; i++) sum += hsBlock[i];
        hsBlock[511] = (UInt8)(0x100 - sum);

        if (WDScsiWriteHandyStore(dev, 1, hsBlock, sizeof(hsBlock)) != 0) {
            WDScsiPrintError("Could not write security parameters (Handy Store)");
            return -1;
        }
    }

    // Decode salt UTF-16LE to characters (same as wdpassport-utils mk_password_block)
    NSMutableString *saltStr = [NSMutableString string];
    for (int i = 0x0C; i < 0x1C; i += 2) {
        unichar ch = (unichar)(hsBlock[i] | (hsBlock[i+1] << 8));
        if (ch == 0) break;
        [saltStr appendFormat:@"%C", ch];
    }
    NSString *combined = [saltStr stringByAppendingString:passwordStr];
    NSData *utf16 = [combined dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    if (!utf16 || utf16.length == 0) {
        fprintf(stderr, "Error: Could not encode salted password\n");
        return -1;
    }

    // Iterate SHA-256: round 1 hashes the UTF-16 payload; later rounds hash the digest.
    UInt32 rounds = iterations;
    if (rounds < 1) rounds = 1000;
    if (rounds > 1000000) rounds = 1000000;
    UInt8 digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256([utf16 bytes], (CC_LONG)[utf16 length], digest);
    for (UInt32 r = 1; r < rounds; r++)
        CC_SHA256(digest, CC_SHA256_DIGEST_LENGTH, digest);
    memcpy(cookedOut, digest, CC_SHA256_DIGEST_LENGTH);
    return 0;
}

#pragma mark - Encryption Commands

/// Send an encryption command using the legacy 0xC1 protocol.
/// Page format: signature 0x45 at byte 0, flag at byte 3, pwlen at byte 7.
///   Arm:    CDB=C1 E2, page[3]=0x01, password at offset 0x28, 0x48-byte page
///   Disarm: CDB=C1 E2, page[3]=0x10, password at offset 0x08, 0x48-byte page
///   Unlock: CDB=C1 E1, page[3]=0x00, password at offset 0x08, 0x28-byte page
int WDScsiEncryptLegacy(SCSITaskDeviceInterface **dev, UInt8 subCmd, UInt8 flag, UInt8 *cooked, int pwOffset) {
    UInt8 page[0x48] = {0};
    UInt8 pageSize = (subCmd == 0xE1) ? 0x28 : 0x48;
    if (pwOffset < 0 || pwOffset + 32 > pageSize) return -1;

    page[0] = 0x45;
    page[3] = flag;
    page[7] = 32;
    memcpy(&page[pwOffset], cooked, 32);
    // 0x48-byte pages: arm has NEW at 0x28 and zeros at 0x08 (no current pw);
    // disarm has OLD at 0x08 and zeros at 0x28. cookpw.py's "duplicate KEK"
    // form is for sg_raw convenience when both slots hold the same key;
    // arming from Off with a non-zero "old" slot is 05/74/40.

    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0xC1;
    cdb[1] = subCmd;
    cdb[6] = g_selectedLUN;   // WD Drive Utilities onLUN: — SES is LUN 1
    cdb[8] = pageSize;
    return WDExecSCSITask(dev, cdb, kSCSICDBSize_10Byte, page, pageSize,
                        kSCSIDataTransfer_FromInitiatorToTarget, 60000);
}

/// Interpret the sense from a failed encryption command in user terms.
static const char *encryptFailureHint(void) {
    if (g_lastSense.senseKey == 0x05 && g_lastSense.asc == 0x74 && g_lastSense.ascq == 0x40)
        return "wrong password";
    if (g_lastSense.senseKey == 0x05 && g_lastSense.asc == 0x20)
        return "command not supported by this bridge";
    if (g_lastSense.senseKey == 0x04)
        return "bridge cannot reach the drive";
    return NULL;
}

static void printEncryptError(const char *what) {
    const char *hint = encryptFailureHint();
    if (hint)
        fprintf(stderr, "Error: %s (%s) — %s\n", what, hint, WDScsiLastErrorString());
    else
        WDScsiPrintError(what);
}

/// Common argument handling: password from argv or prompt. Returns NULL on failure.
static const char *getPasswordArg(int argc, const char *argv[], int argOffset,
                                  const char *prompt, char *buf, size_t bufSize) {
    const char *arg = (argc > argOffset + 1) ? argv[argOffset + 1] : NULL;
    const char *pw = WDReadPassword(arg, prompt, buf, bufSize);
    if (!pw) {
        fprintf(stderr, "Error: No password provided\n");
        return NULL;
    }
    // WD's 32 limit is in characters (UTF-16 units, matching what gets hashed),
    // not bytes. Fall back to byte length if the string isn't valid UTF-8; the
    // cooking step will reject it with a clearer message.
    NSString *s = [NSString stringWithUTF8String:pw];
    size_t n = s ? s.length : strlen(pw);
    if (n < 1 || n > 32) {
        fprintf(stderr, "Error: Password must be 1-32 characters\n");
        return NULL;
    }
    return pw;
}

/// Wipe password material from the stack before returning.
static void scrub(void *p, size_t n) { memset_s(p, n, 0, n); }

/// Set a password (arm encryption). Drive locks on next power cycle.
int WDCmdSetPassword(SCSITaskDeviceInterface **dev, int argc, const char *argv[], int argOffset) {
    char pwBuf[128];
    const char *password = getPasswordArg(argc, argv, argOffset, "New password: ", pwBuf, sizeof(pwBuf));
    if (!password) return kWDExitUsage;

    UInt8 cooked[32] = {0};
    int rc = kWDExitFailure;
    if (WDCookPassword(dev, password, cooked) == 0) {
        if (WDScsiEncryptLegacy(dev, 0xE2, 0x01, cooked, 0x28) == 0) {
            printf("Password set. Drive will lock on next power cycle.\n"
                   "Use 'unlock' to access after reconnecting.\n");
            rc = kWDExitOK;
        } else {
            printEncryptError("Could not set password");
        }
    }
    scrub(cooked, sizeof(cooked)); scrub(pwBuf, sizeof(pwBuf));
    return rc;
}

/// Unlock a locked drive with password.
int WDCmdUnlock(SCSITaskDeviceInterface **dev, int argc, const char *argv[], int argOffset) {
    char pwBuf[128];
    const char *password = getPasswordArg(argc, argv, argOffset, "Password: ", pwBuf, sizeof(pwBuf));
    if (!password) return kWDExitUsage;

    UInt8 cooked[32] = {0};
    int rc = kWDExitFailure;
    if (WDCookPassword(dev, password, cooked) == 0) {
        if (WDScsiEncryptLegacy(dev, 0xE1, 0x00, cooked, 0x08) == 0) {
            printf("Drive unlocked.\n");
            rc = kWDExitOK;
        } else {
            printEncryptError("Unlock failed");
        }
    }
    scrub(cooked, sizeof(cooked)); scrub(pwBuf, sizeof(pwBuf));
    return rc;
}

/// Remove password (disarm encryption). Requires current password.
int WDCmdRemovePassword(SCSITaskDeviceInterface **dev, int argc, const char *argv[], int argOffset) {
    char pwBuf[128];
    const char *password = getPasswordArg(argc, argv, argOffset, "Current password: ", pwBuf, sizeof(pwBuf));
    if (!password) return kWDExitUsage;

    UInt8 cooked[32] = {0};
    int rc = kWDExitFailure;
    if (WDCookPassword(dev, password, cooked) == 0) {
        if (WDScsiEncryptLegacy(dev, 0xE2, 0x10, cooked, 0x08) == 0) {
            printf("Password removed. Encryption disabled.\n");
            rc = kWDExitOK;
        } else {
            printEncryptError("Could not remove password");
        }
    }
    scrub(cooked, sizeof(cooked)); scrub(pwBuf, sizeof(pwBuf));
    return rc;
}

/// Reset the Data Encryption Key. DESTROYS ALL DATA. Requires --confirm.
///
/// Mirrors WDDevice::EncryptResetDEK from WD Drive Utilities:
///   CDB: C1 E3 [KRE0..3] [LUN] 00 [len] 00
///   Page: 45 00 00 01 [cipher] 00 [count LE16] [32-byte seed]
///   - cipher 0x20/0x28: count=1, random seed, len=0x28
///   - cipher 0x30/0x31: count=0, zero seed,   len=0x28
///   - cipher 0x01:      len=0x08 (no seed)
int WDCmdResetDEK(SCSITaskDeviceInterface **dev, int argc, const char *argv[]) {
    if (!WDHasConfirmFlag(argc, argv)) {
        fprintf(stderr,
            "WARNING: reset-dek generates a new encryption key.\n"
            "         ALL DATA ON THE DRIVE WILL BE PERMANENTLY LOST.\n"
            "         The drive will be usable again but empty.\n\n"
            "To proceed, run:\n"
            "  sudo wd_smart reset-dek --confirm\n");
        return kWDExitUsage;
    }

    fprintf(stderr, "*** RESETTING ENCRYPTION KEY — ALL DATA WILL BE DESTROYED ***\n");
#ifndef TESTING
    for (int i = 5; i > 0; i--) {
        fprintf(stderr, "  Resetting in %d... (Ctrl-C to cancel)\n", i);
        sleep(1);
    }
#endif

    // Read encryption status for cipher ID and KeyResetEnabler
    UInt8 stBuf[48] = {0};
    SCSICommandDescriptorBlock stcdb = {0};
    stcdb[0] = 0xC0; stcdb[1] = 0x45; stcdb[8] = 0x30;
    if (WDExecSCSITask(dev, stcdb, kSCSICDBSize_10Byte, stBuf, 48,
                     kSCSIDataTransfer_FromTargetToInitiator, kTimeoutDefault) != 0 || stBuf[0] != 0x45) {
        WDScsiPrintError("Could not read encryption status");
        return kWDExitFailure;
    }

    UInt8 cipher = stBuf[4];
    UInt8 page[0x28] = {0};
    page[0] = 0x45;   // signature
    page[3] = 0x01;   // flag
    UInt8 xferLen;

    if (cipher == 0x01) {
        page[4] = 0x01;
        xferLen = 0x08;
    } else if (cipher == 0x30 || cipher == 0x31) {
        page[4] = cipher;
        // count = 0, seed stays zero (bridge generates key internally)
        xferLen = 0x28;
    } else {
        page[4] = (cipher == 0x28) ? 0x28 : 0x20;
        page[6] = 0x01;   // count (LE16)
        page[7] = 0x00;
        arc4random_buf(&page[8], 32);   // never a predictable seed
        xferLen = 0x28;
    }

    SCSICommandDescriptorBlock cdb = {0};
    cdb[0] = 0xC1;
    cdb[1] = 0xE3;
    cdb[2] = stBuf[8];  // KRE byte 0
    cdb[3] = stBuf[9];  // KRE byte 1
    cdb[4] = stBuf[10]; // KRE byte 2
    cdb[5] = stBuf[11]; // KRE byte 3
    cdb[6] = 0x00;      // LUN
    cdb[8] = xferLen;

    if (WDExecSCSITask(dev, cdb, kSCSICDBSize_10Byte, page, xferLen,
                     kSCSIDataTransfer_FromInitiatorToTarget, 60000) == 0) {
        printf("DEK reset complete. All data has been erased.\n"
               "The drive is now usable without a password.\n");
        return kWDExitOK;
    }
    printEncryptError("Could not reset DEK");
    return kWDExitFailure;
}
