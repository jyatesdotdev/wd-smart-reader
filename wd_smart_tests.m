#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#ifndef TESTING
#error "Tests must be built with -DTESTING (use `make test`)"
#endif
#import "src/WDSmart.h"


// =============================================================================
// MARK: - Mock SCSI Device Emulator
// =============================================================================

typedef struct {
    UInt8  opcode;
    UInt8  subcode;
    UInt8  cdb[10];
    UInt8  data[0x48];
    UInt32 dataSize;
    UInt8  direction;
} MockSCSIRecord;

typedef struct {
    UInt8  handyStore[512];
    UInt8  encryptStatus[48];
    UInt8  smartStatus[8];
    UInt8  smartData[520];
    UInt8  selfTestLog[512];
    UInt8  securityState;
    UInt8  cookedPassword[32];
    BOOL   passwordSet;
    UInt8  modePage[40];
    UInt8  ledPage[16];
    BOOL   ledSupported;
    UInt8  vpdPages[256][64];   // VPD page responses indexed by page code
    MockSCSIRecord records[64];
    int    recordCount;
    // Fault injection: when set, every command fails with this sense
    BOOL   failAll;
    UInt8  failKey, failASC, failASCQ;
    // Bridge quirk: MODE SELECT commits the write but returns a bogus status
    BOOL   modeSelectLies;
    UInt8  modeSelectStatus;    // 0 -> treated as 0x02 (mock must never be incoherent)
    // Bridge genuinely ignores the write (page unchanged)
    BOOL   modeSelectIgnored;
    // Read-back MODE SENSE fails after a MODE SELECT (exercises 'could not verify')
    BOOL   modeSenseFailsAfterSelect;
    BOOL   sawModeSelect;
    // Diagnostic page 0x83 unsupported (forces the info encryption 'unavailable' path)
    BOOL   diag83Unsupported;
    // Diagnostic page 0x86 thermal supported
    BOOL   thermalSupported;
    UInt8  thermalPage[16];
    // Diagnostic page 0x00 (supported list) and VPD 0x00 served when set
    UInt8  diagPage00[64];
    BOOL   failExceptInquiry;   // everything but opcode 0x12 fails with 05/20/00
    WDDriveIdentity identity;   // returned by g_driveIdentity
    NSString *bsdName;          // what g_diskBSDName returns (nil = no disk)
} MockDrive;

static MockDrive g_mock;

static void mockReset(void) {
    g_mock.bsdName = nil;                      // release ARC field before wiping
    memset((void *)&g_mock, 0, sizeof(g_mock));

    // Valid Handy Store security block
    g_mock.handyStore[0] = 0x00; g_mock.handyStore[1] = 0x01;
    g_mock.handyStore[2] = 0x44; g_mock.handyStore[3] = 0x57;
    g_mock.handyStore[8] = 0xE8; g_mock.handyStore[9] = 0x03; // iterations=1000
    // Salt "WDC." UTF-16LE
    g_mock.handyStore[0x0C] = 0x57; g_mock.handyStore[0x0D] = 0x00;
    g_mock.handyStore[0x0E] = 0x44; g_mock.handyStore[0x0F] = 0x00;
    g_mock.handyStore[0x10] = 0x43; g_mock.handyStore[0x11] = 0x00;
    g_mock.handyStore[0x12] = 0x2E; g_mock.handyStore[0x13] = 0x00;
    UInt8 sum = 0;
    for (int i = 0; i < 511; i++) sum += g_mock.handyStore[i];
    g_mock.handyStore[511] = (UInt8)(-(int8_t)sum);

    // Encryption status
    g_mock.encryptStatus[0] = 0x45;
    g_mock.encryptStatus[3] = 0x00; // Off
    g_mock.encryptStatus[4] = 0x30; // Full Disk
    g_mock.encryptStatus[7] = 0x20; // pwLen=32
    g_mock.encryptStatus[8] = 0xAA; g_mock.encryptStatus[9] = 0xBB;
    g_mock.encryptStatus[10] = 0xCC; g_mock.encryptStatus[11] = 0xDD; // KRE

    // SMART status: PASS
    g_mock.smartStatus[0] = 0x84;
    g_mock.smartStatus[3] = 0x03;
    g_mock.smartStatus[5] = 0xC2; g_mock.smartStatus[6] = 0x4F;

    // SMART data with attributes
    g_mock.smartData[0] = 0x85;
    g_mock.smartData[2] = 0x02; g_mock.smartData[3] = 0x04; // length=516
    g_mock.smartData[8] = 0x01; // revision
    WDSmartAttribute *attr;
    // Attr 0: Temperature
    attr = (WDSmartAttribute *)&g_mock.smartData[10];
    attr->id = 194; attr->current = 65; attr->worst = 60; attr->raw[0] = 35;
    // Attr 1: Power-On Hours = 5000
    attr = (WDSmartAttribute *)&g_mock.smartData[10 + 12];
    attr->id = 9; attr->current = 90; attr->worst = 90;
    attr->raw[0] = 0x88; attr->raw[1] = 0x13; // 5000
    // Attr 2: Reallocated Sectors = 0
    attr = (WDSmartAttribute *)&g_mock.smartData[10 + 24];
    attr->id = 5; attr->current = 100; attr->worst = 100;

    // Self-test log: 1 entry (short test, completed OK)
    g_mock.selfTestLog[2] = 0x00; g_mock.selfTestLog[3] = 0x14; // pageLen=20 (1 entry)
    UInt8 *entry = &g_mock.selfTestLog[4];
    // 4-byte param header
    entry[4] = 0x20; // testCode=1(short), result=0(OK)
    entry[5] = 1;    // testNum
    entry[6] = 0x00; entry[7] = 0x64; // hours=100

    // Mode page 0x1A (power condition) with sleep timer = 10 min (6000 * 100ms)
    g_mock.modePage[4] = 0x9A; // page code
    g_mock.modePage[5] = 0x26; // page length = 10
    // Timer at bytes 14-15 (2-byte BE, in 100ms units). 10 min = 6000
    g_mock.modePage[7] = 0x01; // Standby_z enable
    g_mock.modePage[12] = 0; g_mock.modePage[13] = 0; g_mock.modePage[14] = (6000 >> 8) & 0xFF;
    g_mock.modePage[15] = 6000 & 0xFF;

    // VPD 0x80: Serial number "ABC12345"
    g_mock.vpdPages[0x80][0] = 0x00; g_mock.vpdPages[0x80][1] = 0x80;
    g_mock.vpdPages[0x80][3] = 8;
    memcpy(&g_mock.vpdPages[0x80][4], "ABC12345", 8);

    // VPD 0xB1: RPM=7200, form factor=2 (3.5")
    g_mock.vpdPages[0xB1][0] = 0x00; g_mock.vpdPages[0xB1][1] = 0xB1;
    g_mock.vpdPages[0xB1][3] = 0x3C;
    g_mock.vpdPages[0xB1][4] = 0x1C; g_mock.vpdPages[0xB1][5] = 0x20; // 7200
    g_mock.vpdPages[0xB1][7] = 0x02; // 3.5"

    // VPD 0xC2: Capacity (1TB = ~1953525168 blocks * 512)
    g_mock.vpdPages[0xC2][0] = 0x00; g_mock.vpdPages[0xC2][1] = 0xC2;
    g_mock.vpdPages[0xC2][3] = 16;
    g_mock.vpdPages[0xC2][6] = 1; g_mock.vpdPages[0xC2][7] = 1; // bays
    // blocks = 1953525168 = 0x74706DB0
    g_mock.vpdPages[0xC2][12] = 0x74; g_mock.vpdPages[0xC2][13] = 0x70;
    g_mock.vpdPages[0xC2][14] = 0x6D; g_mock.vpdPages[0xC2][15] = 0xB0;
    // block size = 512 = 0x200
    g_mock.vpdPages[0xC2][18] = 0x02; g_mock.vpdPages[0xC2][19] = 0x00;

    // VPD 0xC1: Active interface "USB3.0"
    g_mock.vpdPages[0xC1][0] = 0x00; g_mock.vpdPages[0xC1][1] = 0xC1;
    g_mock.vpdPages[0xC1][2] = 0x00; g_mock.vpdPages[0xC1][3] = 0x08; // len=8 (1 port)
    g_mock.vpdPages[0xC1][4] = 0x01; // active
    memcpy(&g_mock.vpdPages[0xC1][5], "USB3.0 ", 7);

    // LED mode page 0x21: on
    g_mock.ledSupported = YES;
    g_mock.ledPage[4] = 0x21; g_mock.ledPage[5] = 0x0A;
    g_mock.ledPage[12] = 0xFF;

    // VPD 0x00 supported-page list (matches Passport 0748)
    g_mock.vpdPages[0x00][0] = 0x0D; g_mock.vpdPages[0x00][3] = 5;
    memcpy(&g_mock.vpdPages[0x00][4], (UInt8[]){0x00,0x80,0x83,0xC1,0xC2}, 5);

    // Diag page 0x00 supported-page list (matches Passport 0748)
    g_mock.diagPage00[0] = 0x00; g_mock.diagPage00[3] = 6;
    memcpy(&g_mock.diagPage00[4], (UInt8[]){0x00,0x08,0x80,0x83,0x84,0x85}, 6);

    // Default identity
    strlcpy(g_mock.identity.vendor, "WD", sizeof(g_mock.identity.vendor));
    strlcpy(g_mock.identity.product, "My Book 25ED", sizeof(g_mock.identity.product));
    strlcpy(g_mock.identity.firmware, "1031", sizeof(g_mock.identity.firmware));
    g_mock.identity.found = YES;
}

/// Fill g_lastSense as the real transport would, and return the matching rc.
static int mockFail(UInt8 key, UInt8 asc, UInt8 ascq) {
    g_lastSense.taskStatus = 0x02;
    g_lastSense.senseKey = key; g_lastSense.asc = asc; g_lastSense.ascq = ascq;
    return kWDScsiErrCheck;
}

static int mockExecSCSI(void *ctx,
                        SCSICommandDescriptorBlock cdb,
                        UInt8 cdbSize,
                        void *buffer,
                        UInt32 bufferSize,
                        UInt8 direction,
                        UInt32 timeout) {
    (void)ctx; (void)cdbSize; (void)timeout;

    memset(&g_lastSense, 0, sizeof(g_lastSense));
    g_lastSense.valid = YES;
    g_lastSense.transferred = bufferSize;

    // Record
    if (g_mock.recordCount < 64) {
        MockSCSIRecord *r = &g_mock.records[g_mock.recordCount++];
        r->opcode = cdb[0]; r->subcode = cdb[1];
        memcpy(r->cdb, cdb, 10);
        r->direction = direction; r->dataSize = bufferSize;
        if (direction == kSCSIDataTransfer_FromInitiatorToTarget && buffer && bufferSize <= 0x48)
            memcpy(r->data, buffer, bufferSize);
    }

    if (g_mock.failAll) return mockFail(g_mock.failKey, g_mock.failASC, g_mock.failASCQ);
    if (g_mock.failExceptInquiry && cdb[0] != 0x12) return mockFail(0x05, 0x20, 0x00);

    switch (cdb[0]) {
        case 0x00: // TEST UNIT READY
            return 0;
        case 0xD8: { // Read Handy Store
            UInt32 block = ((UInt32)cdb[2]<<24)|((UInt32)cdb[3]<<16)|((UInt32)cdb[4]<<8)|cdb[5];
            if (block == 1 && buffer) memcpy(buffer, g_mock.handyStore, 512);
            return 0;
        }
        case 0xDA: { // Write Handy Store
            UInt32 block = ((UInt32)cdb[2]<<24)|((UInt32)cdb[3]<<16)|((UInt32)cdb[4]<<8)|cdb[5];
            if (block == 1 && buffer) memcpy(g_mock.handyStore, buffer, 512);
            return 0;
        }
        case 0xC0: { // Encrypt Get Status
            if (cdb[1] == 0x45 && buffer) {
                g_mock.encryptStatus[3] = g_mock.securityState;
                memcpy(buffer, g_mock.encryptStatus, bufferSize < 48 ? bufferSize : 48);
            }
            return 0;
        }
        case 0xC1: { // Encrypt Arm/Disarm/Unlock
            UInt8 *page = (UInt8 *)buffer;
            if (cdb[1] == 0xE2) {
                if (page[3] == 0x01) { // ARM
                    if (g_mock.securityState != 0x00) return mockFail(0x05, 0x74, 0x40);
                    memcpy(g_mock.cookedPassword, &page[0x28], 32);
                    g_mock.passwordSet = YES;
                    g_mock.securityState = 0x02;
                    return 0;
                } else if (page[3] == 0x10) { // DISARM
                    if (!g_mock.passwordSet) return mockFail(0x05, 0x74, 0x40);
                    if (memcmp(&page[0x08], g_mock.cookedPassword, 32) != 0) return mockFail(0x05, 0x74, 0x40);
                    g_mock.passwordSet = NO;
                    g_mock.securityState = 0x00;
                    return 0;
                }
            } else if (cdb[1] == 0xE1) { // UNLOCK
                if (g_mock.securityState != 0x01) return mockFail(0x05, 0x74, 0x40);
                if (memcmp(&page[0x08], g_mock.cookedPassword, 32) != 0) return mockFail(0x05, 0x74, 0x40);
                g_mock.securityState = 0x02;
                return 0;
            } else if (cdb[1] == 0xE3) { // RESET DEK
                g_mock.passwordSet = NO;
                g_mock.securityState = 0x00;
                return 0;
            }
            return mockFail(0x05, 0x20, 0x00);
        }
        case 0x1C: { // RECEIVE DIAGNOSTIC
            UInt8 page = cdb[2];
            if (page == 0x00 && buffer)
                memcpy(buffer, g_mock.diagPage00, bufferSize < 64 ? bufferSize : 64);
            else if (page == 0x83 && g_mock.diag83Unsupported)
                return mockFail(0x05, 0x24, 0x00);
            else if (page == 0x84 && buffer)
                memcpy(buffer, g_mock.smartStatus, bufferSize < 8 ? bufferSize : 8);
            else if (page == 0x85 && buffer)
                memcpy(buffer, g_mock.smartData, bufferSize < 520 ? bufferSize : 520);
            else if (page == 0x86 && buffer) {
                if (!g_mock.thermalSupported) {
                    // Unsupported on Passport/MyBook; tests the SMART-194 fallback
                    memset(buffer, 0, bufferSize);
                    return mockFail(0x05, 0x24, 0x00);
                }
                memcpy(buffer, g_mock.thermalPage, bufferSize < 16 ? bufferSize : 16);
            }
            return 0;
        }
        case 0x1D: { // SEND DIAGNOSTIC (self-test or page)
            return 0; // always succeed
        }
        case 0x4D: // LOG SENSE
            if (buffer) memcpy(buffer, g_mock.selfTestLog, bufferSize < 512 ? bufferSize : 512);
            return 0;
        case 0x12: { // INQUIRY (standard or VPD)
            if (cdb[1] & 0x01) { // EVPD
                UInt8 page = cdb[2];
                if (buffer)
                    memcpy(buffer, g_mock.vpdPages[page], bufferSize < 64 ? bufferSize : 64);
            }
            return 0;
        }
        case 0x1A: { // MODE SENSE
            UInt8 page = cdb[2] & 0x3F;
            if (g_mock.modeSenseFailsAfterSelect && g_mock.sawModeSelect)
                return mockFail(0x05, 0x24, 0x00);
            if (page == 0x21) {
                if (!g_mock.ledSupported) return mockFail(0x05, 0x24, 0x00);
                if (buffer) memcpy(buffer, g_mock.ledPage, bufferSize < 16 ? bufferSize : 16);
                return 0;
            }
            if (buffer) memcpy(buffer, g_mock.modePage, bufferSize < 40 ? bufferSize : 40);
            return 0;
        }
        case 0x15: { // MODE SELECT
            UInt8 *p = (UInt8 *)buffer;
            g_mock.sawModeSelect = YES;
            if (!g_mock.modeSelectIgnored) {
                if (buffer && (p[4] & 0x3F) == 0x21) {
                    memcpy(g_mock.ledPage, buffer, bufferSize < 16 ? bufferSize : 16);
                    g_mock.ledPage[4] = 0x21;
                } else if (buffer) {
                    memcpy(g_mock.modePage, buffer, bufferSize < 40 ? bufferSize : 40);
                }
            }
            // Write committed either way; optionally report a bogus failure
            if (g_mock.modeSelectLies) {
                UInt8 st = g_mock.modeSelectStatus ? g_mock.modeSelectStatus : 0x02;
                g_lastSense.taskStatus = st;
                if (st == 0x02) {
                    g_lastSense.senseKey = 0x02; g_lastSense.asc = 0x04; g_lastSense.ascq = 0x01;
                }
                return kWDScsiErrCheck;
            }
            return 0;
        }
        default:
            return mockFail(0x05, 0x20, 0x00);
    }
}

static NSString *mockDiskBSDName(void) { return g_mock.bsdName; }

static WDDriveIdentity mockDriveIdentity(const char *targetSerial);

static void installMock(void) {
    mockReset();
    g_scsiExec = mockExecSCSI;
    g_scsiCtx = &g_mock;
    g_driveIdentity = mockDriveIdentity;
    g_diskBSDName = mockDiskBSDName;
    g_verbose = 0;
    memset(&g_lastSense, 0, sizeof(g_lastSense));   // deterministic start
}

/// First recorded command matching opcode (and optional subcode), or NULL.
static MockSCSIRecord *findRecord(UInt8 opcode, int subcode) {
    for (int i = 0; i < g_mock.recordCount; i++)
        if (g_mock.records[i].opcode == opcode && (subcode < 0 || g_mock.records[i].subcode == subcode))
            return &g_mock.records[i];
    return NULL;
}

static void uninstallMock(void) {
    g_scsiExec = WDExecSCSITaskReal;
    g_scsiCtx = NULL;
    g_driveIdentity = WDDriveIdentityFromIOKit;
    g_diskBSDName = WDFindDiskBSDNameFromIOKit;
}

/// Capture stdout (and optionally stderr) produced by `block`.
/// Uses a growing memory stream (no silent truncation) and always restores the
/// real streams even if the block throws — otherwise every later test would
/// write into a dead buffer.
static NSString *captureOutput(BOOL alsoStderr, void (^block)(void)) {
    char *buf = NULL; size_t len = 0;
    fflush(stdout); fflush(stderr);
    FILE *oldOut = stdout, *oldErr = stderr;
    FILE *mem = open_memstream(&buf, &len);
    NSCAssert(mem, @"open_memstream failed");
    stdout = mem;
    if (alsoStderr) stderr = mem;
    @try {
        block();
    } @finally {
        fflush(mem);
        stdout = oldOut; stderr = oldErr;
        fclose(mem);
    }
    NSString *s = buf ? ([NSString stringWithUTF8String:buf] ?: @"") : @"";
    free(buf);
    return s;
}

static WDDriveIdentity mockDriveIdentity(const char *targetSerial) {
    (void)targetSerial;
    return g_mock.identity;   // per-test overridable; seeded in mockReset
}

// =============================================================================
// MARK: - Tests
// =============================================================================

@interface WDSmartTests : XCTestCase
@end

@implementation WDSmartTests

- (void)setUp { installMock(); }
- (void)tearDown { uninstallMock(); }

// MARK: - Password Cooking

- (void)testCookPasswordCorrectHash {
    UInt8 cooked[32] = {0};
    XCTAssertEqual(WDCookPassword(NULL, "test123", cooked), 0);
    UInt8 expected[] = {0xDF,0x87,0x01,0xD1,0xE5,0xD3,0xD6,0xD4,
                        0x41,0x8F,0x90,0xD6,0x29,0x3C,0xE4,0x03,
                        0x1D,0xBB,0x56,0x93,0x6E,0x57,0x73,0xDE,
                        0x3B,0xA9,0x69,0xD1,0x38,0x3E,0x0F,0xC2};
    XCTAssertEqual(memcmp(cooked, expected, 32), 0);
}

- (void)testCookPasswordInitializesIterations {
    g_mock.handyStore[8] = 0; g_mock.handyStore[9] = 0;
    UInt8 cooked[32];
    WDCookPassword(NULL, "x", cooked);
    XCTAssertEqual(g_mock.handyStore[8] | (g_mock.handyStore[9]<<8), 1000);
    UInt8 sum = 0;
    for (int i = 0; i < 512; i++) sum += g_mock.handyStore[i];
    XCTAssertEqual(sum, 0, @"Checksum must be valid after write");
}

- (void)testCookPasswordDifferentInputsDifferentOutputs {
    UInt8 c1[32], c2[32];
    WDCookPassword(NULL, "aaa", c1);
    WDCookPassword(NULL, "bbb", c2);
    XCTAssertNotEqual(memcmp(c1, c2, 32), 0);
}

// MARK: - Set Password

- (void)testSetPasswordArms {
    const char *argv[] = {"wd_smart", "set-password", "test123"};
    WDCmdSetPassword(NULL, 3, argv, 1);
    XCTAssertEqual(g_mock.securityState, 0x02);
    XCTAssertTrue(g_mock.passwordSet);
}

- (void)testSetPasswordCDBFormat {
    const char *argv[] = {"wd_smart", "set-password", "pw"};
    WDCmdSetPassword(NULL, 3, argv, 1);
    MockSCSIRecord *r = NULL;
    for (int i = 0; i < g_mock.recordCount; i++)
        if (g_mock.records[i].opcode == 0xC1 && g_mock.records[i].subcode == 0xE2)
            { r = &g_mock.records[i]; break; }
    XCTAssertTrue(r != NULL);
    XCTAssertEqual(r->data[0], 0x45);
    XCTAssertEqual(r->data[3], 0x01);
    XCTAssertEqual(r->data[7], 32);
    XCTAssertNotEqual(r->data[0x28], 0); // password at 0x28
}

- (void)testSetPasswordRejectsMissing {
    const char *argv[] = {"wd_smart", "set-password"};
    WDCmdSetPassword(NULL, 2, argv, 1);
    XCTAssertEqual(g_mock.securityState, 0x00);
}

- (void)testSetPasswordRejectsTooLong {
    const char *argv[] = {"wd_smart", "set-password", "123456789012345678901234567890123"}; // 33 chars
    WDCmdSetPassword(NULL, 3, argv, 1);
    XCTAssertEqual(g_mock.securityState, 0x00);
}

- (void)testSetPasswordFailsWhenAlreadyArmed {
    const char *argv[] = {"wd_smart", "set-password", "first"};
    XCTAssertEqual(WDCmdSetPassword(NULL, 3, argv, 1), kWDExitOK);
    UInt8 firstCooked[32]; memcpy(firstCooked, g_mock.cookedPassword, 32);

    const char *argv2[] = {"wd_smart", "set-password", "second"};
    XCTAssertEqual(WDCmdSetPassword(NULL, 3, argv2, 1), kWDExitFailure, @"second arm must be rejected");
    // First password should still be active and unchanged
    XCTAssertEqual(g_mock.securityState, 0x02);
    XCTAssertEqual(memcmp(firstCooked, g_mock.cookedPassword, 32), 0);
}

// MARK: - Unlock

- (void)testUnlockCorrectPassword {
    const char *argv[] = {"wd_smart", "set-password", "mypass"};
    WDCmdSetPassword(NULL, 3, argv, 1);
    g_mock.securityState = 0x01; // simulate power cycle
    const char *uargv[] = {"wd_smart", "unlock", "mypass"};
    WDCmdUnlock(NULL, 3, uargv, 1);
    XCTAssertEqual(g_mock.securityState, 0x02);
}

- (void)testUnlockWrongPassword {
    const char *argv[] = {"wd_smart", "set-password", "right"};
    WDCmdSetPassword(NULL, 3, argv, 1);
    g_mock.securityState = 0x01;
    const char *uargv[] = {"wd_smart", "unlock", "wrong"};
    WDCmdUnlock(NULL, 3, uargv, 1);
    XCTAssertEqual(g_mock.securityState, 0x01); // still locked
}

- (void)testUnlockPasswordAtOffset0x08 {
    const char *argv[] = {"wd_smart", "set-password", "t"};
    WDCmdSetPassword(NULL, 3, argv, 1);
    g_mock.securityState = 0x01;
    g_mock.recordCount = 0;
    const char *uargv[] = {"wd_smart", "unlock", "t"};
    WDCmdUnlock(NULL, 3, uargv, 1);
    MockSCSIRecord *r = NULL;
    for (int i = 0; i < g_mock.recordCount; i++)
        if (g_mock.records[i].opcode == 0xC1 && g_mock.records[i].subcode == 0xE1)
            { r = &g_mock.records[i]; break; }
    XCTAssertTrue(r != NULL);
    XCTAssertNotEqual(r->data[0x08], 0);
}

- (void)testUnlockFailsWhenNotLocked {
    const char *argv[] = {"wd_smart", "unlock", "x"};
    XCTAssertEqual(WDCmdUnlock(NULL, 3, argv, 1), kWDExitFailure);
    XCTAssertEqual(g_mock.securityState, 0x00);
    XCTAssert(findRecord(0xC1, 0xE1) != NULL, @"unlock command must have been sent");
}

// MARK: - Remove Password

- (void)testRemovePasswordCorrect {
    const char *argv[] = {"wd_smart", "set-password", "secret"};
    WDCmdSetPassword(NULL, 3, argv, 1);
    const char *rargv[] = {"wd_smart", "remove-password", "secret"};
    WDCmdRemovePassword(NULL, 3, rargv, 1);
    XCTAssertEqual(g_mock.securityState, 0x00);
    XCTAssertFalse(g_mock.passwordSet);
}

- (void)testRemovePasswordWrong {
    const char *argv[] = {"wd_smart", "set-password", "correct"};
    WDCmdSetPassword(NULL, 3, argv, 1);
    const char *rargv[] = {"wd_smart", "remove-password", "incorrect"};
    WDCmdRemovePassword(NULL, 3, rargv, 1);
    XCTAssertEqual(g_mock.securityState, 0x02); // still armed
}

- (void)testRemovePasswordAtOffset0x08WithFlag0x10 {
    const char *argv[] = {"wd_smart", "set-password", "p"};
    WDCmdSetPassword(NULL, 3, argv, 1);
    g_mock.recordCount = 0;
    const char *rargv[] = {"wd_smart", "remove-password", "p"};
    WDCmdRemovePassword(NULL, 3, rargv, 1);
    MockSCSIRecord *r = NULL;
    for (int i = 0; i < g_mock.recordCount; i++)
        if (g_mock.records[i].opcode == 0xC1 && g_mock.records[i].subcode == 0xE2
            && g_mock.records[i].data[3] == 0x10)
            { r = &g_mock.records[i]; break; }
    XCTAssertTrue(r != NULL);
    XCTAssertNotEqual(r->data[0x08], 0);
}

// MARK: - Reset DEK

- (void)testResetDEKRequiresConfirm {
    const char *argv[] = {"wd_smart", "reset-dek"};
    WDCmdResetDEK(NULL, 2, argv);
    XCTAssertEqual(g_mock.recordCount, 0, @"Should not send commands without --confirm");
}

- (void)testResetDEKSendsKRE {
    g_mock.securityState = 0x02; g_mock.passwordSet = YES;
    const char *argv[] = {"wd_smart", "reset-dek", "--confirm"};
    WDCmdResetDEK(NULL, 3, argv);
    // Should have read status (C0 45) then sent reset (C1 E3) with KRE in CDB
    BOOL readStatus = NO, sentReset = NO;
    for (int i = 0; i < g_mock.recordCount; i++) {
        if (g_mock.records[i].opcode == 0xC0) readStatus = YES;
        if (g_mock.records[i].opcode == 0xC1 && g_mock.records[i].subcode == 0xE3) {
            sentReset = YES;
            // KRE should be in CDB bytes 2-5
            XCTAssertEqual(g_mock.records[i].cdb[2], 0xAA);
            XCTAssertEqual(g_mock.records[i].cdb[3], 0xBB);
            XCTAssertEqual(g_mock.records[i].cdb[4], 0xCC);
            XCTAssertEqual(g_mock.records[i].cdb[5], 0xDD);
        }
    }
    XCTAssertTrue(readStatus);
    XCTAssertTrue(sentReset);
    XCTAssertEqual(g_mock.securityState, 0x00);
}

// MARK: - Full Round-Trip

- (void)testFullRoundTrip {
    const char *s[] = {"wd_smart", "set-password", "hello"};
    WDCmdSetPassword(NULL, 3, s, 1);
    XCTAssertEqual(g_mock.securityState, 0x02);

    g_mock.securityState = 0x01; // power cycle

    const char *u[] = {"wd_smart", "unlock", "hello"};
    WDCmdUnlock(NULL, 3, u, 1);
    XCTAssertEqual(g_mock.securityState, 0x02);

    const char *r[] = {"wd_smart", "remove-password", "hello"};
    WDCmdRemovePassword(NULL, 3, r, 1);
    XCTAssertEqual(g_mock.securityState, 0x00);
}

// MARK: - SMART Decoding

- (void)testSmartRawValue48Bit {
    WDSmartAttribute attr = {0};
    attr.raw[0]=1; attr.raw[1]=2; attr.raw[2]=3; attr.raw[3]=4; attr.raw[4]=5; attr.raw[5]=6;
    XCTAssertEqual(WDSmartRawValue(&attr), 0x060504030201ULL);
}

- (void)testSmartFormatTemp {
    WDSmartAttribute attr = {0};
    attr.id = 194; attr.raw[0] = 35; attr.raw[1] = 20; attr.raw[4] = 50;
    XCTAssert(strstr(WDSmartRawFormatted(&attr), "35"));
}

- (void)testSmartFormatHours {
    WDSmartAttribute attr = {0};
    attr.id = 9; attr.raw[0] = 0xD2; attr.raw[1] = 0x04;
    const char *s = WDSmartRawFormatted(&attr);
    XCTAssert(strstr(s, "1234") && strstr(s, "51d"));
}

- (void)testSmartFormatSpinUp {
    WDSmartAttribute attr = {0};
    attr.id = 3; attr.raw[0] = 0xE8; attr.raw[1] = 0x03; attr.raw[2] = 0xD0; attr.raw[3] = 0x07;
    XCTAssert(strstr(WDSmartRawFormatted(&attr), "1000") && strstr(WDSmartRawFormatted(&attr), "2000"));
}

- (void)testSelfTestResultStrings {
    XCTAssert(strcmp(WDSelfTestResultString(0), "Completed OK") == 0);
    XCTAssert(strcmp(WDSelfTestResultString(15), "In progress...") == 0);
}

- (void)testSmartAttrName {
    XCTAssert(strcmp(WDSmartAttrName(9), "Power-On Hours") == 0);
    XCTAssert(strcmp(WDSmartAttrName(255), "Vendor Specific") == 0);
}

- (void)testHandyStoreChecksum {
    UInt8 sum = 0;
    for (int i = 0; i < 512; i++) sum += g_mock.handyStore[i];
    XCTAssertEqual(sum, 0);
}

// MARK: - SMART Command

- (void)testCmdSmartDisplaysAttributes {
    NSString *out = captureOutput(NO, ^{ WDCmdSmart(NULL); });
    XCTAssert([out containsString:@"PASSED"], @"Should show SMART PASSED");
    XCTAssert([out containsString:@"Temperature"], @"Should show temp attribute");
    XCTAssert([out containsString:@"Power-On Hours"], @"Should show POH");
    XCTAssert([out containsString:@"Reallocated"], @"Should show reallocated");
}

- (void)testCmdSmartShowsFailed {
    g_mock.smartStatus[5] = 0x2C; g_mock.smartStatus[6] = 0xF4; // FAIL

    NSString *out = captureOutput(NO, ^{ WDCmdSmart(NULL); });

    XCTAssert([out containsString:@"FAILED"]);
}

// MARK: - Status Command (Self-Test Log)

- (void)testCmdStatusShowsResults {
    NSString *out = captureOutput(NO, ^{ WDCmdStatus(NULL); });

    XCTAssert([out containsString:@"Short"], @"Should show test type");
    XCTAssert([out containsString:@"Completed OK"], @"Should show result");
}

- (void)testCmdStatusEmptyLog {
    g_mock.selfTestLog[2] = 0; g_mock.selfTestLog[3] = 0; // pageLen=0

    NSString *out = captureOutput(NO, ^{ WDCmdStatus(NULL); });

    XCTAssert([out containsString:@"No self-test results"]);
}

// MARK: - Temperature Command

- (void)testCmdTempShowsTemperature {
    NSString *out = captureOutput(NO, ^{ WDCmdTemp(NULL); });

    XCTAssert([out containsString:@"35"], @"Should show 35°C from attr 194");
}

- (void)testCmdTempWithThermalPage {
    // Bridge that supports diag page 0x86: thermal condition + fan data + SMART temp
    g_mock.thermalSupported = YES;
    g_mock.thermalPage[0] = 0x86;
    g_mock.thermalPage[4] = 0x01;                 // condition = Warm
    g_mock.thermalPage[6] = 0x05; g_mock.thermalPage[7] = 0xDC;   // fan 1500 rpm (BE)
    g_mock.thermalPage[8] = 0x00; g_mock.thermalPage[9] = 0x64;   // goal PWM 100
    g_mock.thermalPage[10] = 0x00; g_mock.thermalPage[11] = 0x50; // current PWM 80
    NSString *out = captureOutput(NO, ^{ XCTAssertEqual(WDCmdTemp(NULL), kWDExitOK); });
    XCTAssert([out containsString:@"Thermal:  Warm"], @"%@", out);
    XCTAssert([out containsString:@"Fan RPM:  1500"], @"%@", out);
    XCTAssert([out containsString:@"Fan PWM:  80 / 100"], @"%@", out);
    XCTAssert([out containsString:@"Drive:    35°C"], @"%@", out);
}

- (void)testCmdTempThermalPageOnlyWhenSmartFails {
    // 0x86 works but SMART data is unavailable: still OK because we got something
    g_mock.thermalSupported = YES;
    g_mock.thermalPage[4] = 0x00;
    g_mock.smartData[0] = 0; // keep GOOD status but make attribute scan find nothing
    memset(&g_mock.smartData[10], 0, 360);
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdTemp(NULL), kWDExitOK); });
    XCTAssert([out containsString:@"Thermal:  Normal"], @"%@", out);
    XCTAssertFalse([out containsString:@"Drive:"]);
}

// MARK: - Sleep Timer Command

- (void)testCmdSleepReadsTimer {
    NSString *out = captureOutput(NO, ^{ WDCmdSleep(NULL, NULL); });

    XCTAssert([out containsString:@"10 minutes"], @"Should show 10 min timer");
}

- (void)testCmdSleepDisabled {
    // Set timer to 0
    g_mock.modePage[7] = 0; g_mock.modePage[14] = 0; g_mock.modePage[15] = 0;

    NSString *out = captureOutput(NO, ^{ WDCmdSleep(NULL, NULL); });

    XCTAssert([out containsString:@"disabled"]);
}

- (void)testCmdSleepSetsTimer {
    g_mock.recordCount = 0;

    NSString *out = captureOutput(NO, ^{ WDCmdSleep(NULL, "20"); });

    XCTAssert([out containsString:@"20 minutes"]);
    // Verify mode page was written with correct timer value (20*600=12000=0x2EE0)
    UInt32 written = ((UInt32)g_mock.modePage[12]<<24) | ((UInt32)g_mock.modePage[13]<<16) | ((UInt32)g_mock.modePage[14]<<8) | g_mock.modePage[15];
    XCTAssertEqual(written, (UInt32)(20 * 600));
}

- (void)testCmdSleepDisablesWithZero {
    NSString *out = captureOutput(NO, ^{ WDCmdSleep(NULL, "0"); });

    XCTAssert([out containsString:@"disabled"]);
    UInt32 written = ((UInt32)g_mock.modePage[12]<<24) | ((UInt32)g_mock.modePage[13]<<16) | ((UInt32)g_mock.modePage[14]<<8) | g_mock.modePage[15];
    XCTAssertEqual(written, (UInt32)0);
}

// MARK: - Self-Test Commands

- (void)testCmdShortTestSendsDiagnostic {
    g_mock.recordCount = 0;

    NSString *out = captureOutput(NO, ^{ WDCmdShortTest(NULL); });

    XCTAssert([out containsString:@"Short self-test started"]);
    // Verify SEND DIAGNOSTIC was sent
    BOOL found = NO;
    for (int i = 0; i < g_mock.recordCount; i++)
        if (g_mock.records[i].opcode == 0x1D) found = YES;
    XCTAssertTrue(found);
}

- (void)testCmdLongTestSendsDiagnostic {
    g_mock.recordCount = 0;
    NSString *out = captureOutput(NO, ^{ XCTAssertEqual(WDCmdLongTest(NULL), kWDExitOK); });
    XCTAssert([out containsString:@"Extended self-test started"]);
    MockSCSIRecord *r = findRecord(0x1D, -1);
    XCTAssert(r != NULL);
    XCTAssertEqual(r->cdb[1], 0x40, @"extended test code 2 in bits 7:5, no SelfTest bit");
}

- (void)testCmdShortTestCDB {
    g_mock.recordCount = 0;
    WDCmdShortTest(NULL);
    MockSCSIRecord *r = findRecord(0x1D, -1);
    XCTAssert(r != NULL);
    XCTAssertEqual(r->cdb[1], 0x20, @"short test code 1 in bits 7:5");
}

- (void)testCmdAbortTestSendsDiagnostic {
    g_mock.recordCount = 0;
    NSString *out = captureOutput(NO, ^{ XCTAssertEqual(WDCmdAbortTest(NULL), kWDExitOK); });
    XCTAssert([out containsString:@"aborted"]);
    MockSCSIRecord *r = findRecord(0x1D, -1);
    XCTAssert(r != NULL);
    XCTAssertEqual(r->cdb[1], 0x80, @"abort code 4 in bits 7:5");
}

// MARK: - Power Off

- (void)testCmdPowerOffSendsPage {
    g_mock.recordCount = 0;

    NSString *out = captureOutput(NO, ^{ XCTAssertEqual(WDCmdPowerOff(NULL), kWDExitOK); });

    XCTAssert([out containsString:@"powered off"]);
    // Should have sent SEND DIAGNOSTIC (PF bit) carrying page 0x80 with PowerOff bit
    MockSCSIRecord *r = findRecord(0x1D, -1);
    XCTAssert(r != NULL);
    XCTAssertEqual(r->cdb[1], 0x10, @"PF bit");
    XCTAssertEqual(r->data[0], 0x80, @"page code");
    XCTAssertEqual(r->data[3], 0x04, @"page length");
    XCTAssertEqual(r->data[4], 0x01, @"PowerOff bit");
}

- (void)testCmdPowerOffAnnouncesUnmountWhenDiskPresent {
    g_mock.bsdName = @"disk7";
    NSString *out = captureOutput(NO, ^{ WDCmdPowerOff(NULL); });
    XCTAssert([out containsString:@"Unmounting /dev/disk7"], @"%@", out);
}

// MARK: - Erase

- (void)testCmdEraseRequiresConfirm {
    static const char *argv[] = {"wd_smart", "erase"};
    g_mock.bsdName = @"disk99";   // a disk IS present; only --confirm is missing
    g_mock.recordCount = 0;
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdErase(NULL, 2, argv), kWDExitUsage); });
    XCTAssertEqual(g_mock.recordCount, 0, @"must send nothing without --confirm");
    XCTAssert([out containsString:@"erase --confirm"], @"must tell the user how to proceed");
    XCTAssertFalse([out containsString:@"would run"], @"must not reach the erase step");
}

- (void)testCmdEraseWithConfirmNoDisk {
    // No disk LUN bound → must fail cleanly without spawning diskutil
    g_mock.bsdName = nil;
    const char *argv[] = {"wd_smart", "erase", "--confirm"};
    XCTAssertEqual(WDCmdErase(NULL, 3, argv), kWDExitFailure);
}

- (void)testCmdEraseWithConfirmAndDiskIsCompiledOutUnderTesting {
    // With a disk present, the TESTING build must print the would-be command
    // and NOT run diskutil. If this test ever runs diskutil we'd wipe a real drive.
    g_mock.bsdName = @"disk99";
    static const char *argv[] = {"wd_smart", "erase", "--confirm"};
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdErase(NULL, 3, argv), kWDExitOK); });
    XCTAssert([out containsString:@"[TESTING] would run"]);
    XCTAssert([out containsString:@"/dev/disk99"]);
    XCTAssert([out containsString:@"\"My Book\""], @"label = product minus model suffix, got: %@", out);
}

- (void)testEraseLabelFromSingleWordProduct {
    g_mock.bsdName = @"disk99";
    strlcpy(g_mock.identity.product, "Elements", sizeof(g_mock.identity.product));
    static const char *argv[] = {"wd_smart", "erase", "--confirm"};
    NSString *out = captureOutput(YES, ^{ WDCmdErase(NULL, 3, argv); });
    XCTAssert([out containsString:@"\"Elements\""], @"%@", out);
}

- (void)testEraseLabelFallsBackWhenIdentityUnknown {
    g_mock.bsdName = @"disk99";
    g_mock.identity.found = NO;
    static const char *argv[] = {"wd_smart", "erase", "--confirm"};
    NSString *out = captureOutput(YES, ^{ WDCmdErase(NULL, 3, argv); });
    XCTAssert([out containsString:@"\"WD Drive\""], @"%@", out);
}

- (void)testConfirmFlagAnywhereAfterCommand {
    g_mock.bsdName = @"disk99";
    static const char *argv[] = {"wd_smart", "erase", "x", "--confirm"};
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdErase(NULL, 4, argv), kWDExitOK); });
    XCTAssert([out containsString:@"would run"]);
}

- (void)testConfirmFlagIsExactMatch {
    g_mock.bsdName = @"disk99";
    static const char *a1[] = {"wd_smart", "erase", "--CONFIRM"};
    static const char *a2[] = {"wd_smart", "erase", "--confirm=1"};
    XCTAssertEqual(WDCmdErase(NULL, 3, a1), kWDExitUsage);
    XCTAssertEqual(WDCmdErase(NULL, 3, a2), kWDExitUsage);
    XCTAssertFalse(WDHasConfirmFlag(3, a1));
    XCTAssertFalse(WDHasConfirmFlag(3, a2));
}

- (void)testCmdEraseRequiresConfirmReturnsUsage {
    const char *argv[] = {"wd_smart", "erase"};
    XCTAssertEqual(WDCmdErase(NULL, 2, argv), kWDExitUsage);
}

// MARK: - Info Command (VPD parsing)

- (void)testPrintDriveIdentity {
    NSString *out = captureOutput(NO, ^{ WDPrintDriveIdentity(NULL); });

    XCTAssert([out containsString:@"WD"], @"Should show vendor");
    XCTAssert([out containsString:@"My Book 25ED"], @"Should show product");
    XCTAssert([out containsString:@"1031"], @"Should show firmware");
}

- (void)testCmdInfoShowsFullOutput {
    NSString *out = captureOutput(NO, ^{ WDCmdInfo(NULL); });

    XCTAssert([out containsString:@"My Book 25ED"], @"Should show product from identity");
    XCTAssert([out containsString:@"ABC12345"], @"Should show serial");
    XCTAssert([out containsString:@"7200"], @"Should show RPM");
    XCTAssert([out containsString:@"Off"], @"Should show encrypt Off");
    XCTAssert([out containsString:@"Full Disk"], @"Should show cipher");
    XCTAssert([out containsString:@"USB3.0"], @"Should show port");
}

- (void)testCmdInfoShowsLockedState {
    g_mock.securityState = 0x01;

    NSString *out = captureOutput(NO, ^{ WDCmdInfo(NULL); });

    XCTAssert([out containsString:@"Locked"]);
}

- (void)testCmdInfoShowsFormFactor {
    NSString *out = captureOutput(NO, ^{ WDCmdInfo(NULL); });

    XCTAssert([out containsString:@"3.5"], @"Should show form factor");
}

- (void)testCmdInfoShowsCapacity {
    NSString *out = captureOutput(NO, ^{ WDCmdInfo(NULL); });

    XCTAssert([out containsString:@"TB"], @"Should show capacity in TB");
}

- (void)testCmdInfoShowsPort {
    NSString *out = captureOutput(NO, ^{ WDCmdInfo(NULL); });

    XCTAssert([out containsString:@"USB3.0"], @"Should show USB interface");
}

// MARK: - Secure Erase (confirm guard only)

- (void)testCmdSecureEraseRequiresConfirm {
    const char *argv[] = {"wd_smart", "secure-erase"};
    XCTAssertEqual(WDCmdSecureErase(2, argv), kWDExitUsage);
}

- (void)testCmdSecureEraseRequiresRoot {
    // Under TESTING the zero-fill is compiled out, but the root check comes first.
    if (geteuid() == 0) return;   // skip when running as root
    g_mock.bsdName = @"disk99";
    static const char *argv[] = {"wd_smart", "secure-erase", "--confirm"};
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdSecureErase(3, argv), kWDExitFailure); });
    XCTAssert([out containsString:@"root"]);
}

// MARK: - Exit Codes and Sense Reporting

- (void)testCommandsReturnFailureWithSenseWhenBridgeErrors {
    // Reproduce the live failure observed on My Passport 0748: every command
    // fails with 04/44/81 (bridge cannot reach the SATA drive).
    g_mock.failAll = YES; g_mock.failKey = 0x04; g_mock.failASC = 0x44; g_mock.failASCQ = 0x81;

    NSString *out = captureOutput(YES, ^{
        XCTAssertEqual(WDCmdSmart(NULL),  kWDExitFailure);
        XCTAssertEqual(WDCmdStatus(NULL), kWDExitFailure);
        XCTAssertEqual(WDCmdTemp(NULL),   kWDExitFailure);
        XCTAssertEqual(WDCmdSleep(NULL, NULL), kWDExitFailure);
        XCTAssertEqual(WDCmdLED(NULL, NULL),   kWDExitFailure);
        XCTAssertEqual(WDCmdShortTest(NULL),   kWDExitFailure);
        XCTAssertEqual(WDCmdPowerOff(NULL),    kWDExitFailure);
    });
    XCTAssert([out containsString:@"04/44/81"], @"sense code must be surfaced: %@", out);
    XCTAssert([out containsString:@"Hardware Error"]);
    XCTAssert([out containsString:@"power-cycling"], @"should give actionable hint");
}

- (void)testUnsupportedCommandSenseIsDecoded {
    g_mock.failAll = YES; g_mock.failKey = 0x05; g_mock.failASC = 0x20; g_mock.failASCQ = 0x00;
    NSString *out = captureOutput(YES, ^{ WDCmdLED(NULL, NULL); });
    XCTAssert([out containsString:@"05/20/00"]);
    XCTAssert([out containsString:@"unsupported"]);
}

- (void)testWrongPasswordSenseGivesHint {
    const char *argv[] = {"wd_smart", "set-password", "right"};
    WDCmdSetPassword(NULL, 3, argv, 1);
    g_mock.securityState = 0x01;
    static const char *uargv[] = {"wd_smart", "unlock", "wrong"};
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdUnlock(NULL, 3, uargv, 1), kWDExitFailure); });
    XCTAssert([out containsString:@"wrong password"], @"%@", out);
    XCTAssert([out containsString:@"05/74/40"]);
}

- (void)testSuccessfulCommandsReturnOK {
    XCTAssertEqual(WDCmdSmart(NULL), kWDExitOK);
    XCTAssertEqual(WDCmdInfo(NULL), kWDExitOK);
    XCTAssertEqual(WDCmdStatus(NULL), kWDExitOK);
    XCTAssertEqual(WDCmdTemp(NULL), kWDExitOK);
    XCTAssertEqual(WDCmdSleep(NULL, NULL), kWDExitOK);
    XCTAssertEqual(WDCmdLED(NULL, NULL), kWDExitOK);
    XCTAssertEqual(WDCmdShortTest(NULL), kWDExitOK);
}

- (void)testLastErrorStringFormats {
    memset(&g_lastSense, 0, sizeof(g_lastSense));
    XCTAssert(strstr(WDScsiLastErrorString(), "no command"));
    g_lastSense.valid = YES; g_lastSense.ioReturn = 0xe00002c7;
    XCTAssert(strstr(WDScsiLastErrorString(), "0xe00002c7"));
    g_lastSense.ioReturn = 0; g_lastSense.taskStatus = 0; g_lastSense.transferred = 42;
    XCTAssert(strstr(WDScsiLastErrorString(), "42 bytes"));
}

- (void)testVerboseLogsCDB {
    g_verbose = 1;
    NSString *out = captureOutput(YES, ^{ WDCmdShortTest(NULL); });
    g_verbose = 0;
    XCTAssert([out containsString:@"[scsi] CDB: 1D 20"], @"%@", out);
}

// MARK: - Argument Parsing (WDArgs.m)

- (void)testParseDefaultsToSmart {
    WDParsedArgs a; const char *argv[] = {"wd_smart"};
    XCTAssertEqual(WDParseArgs(1, argv, &a), kWDActionRun);
    XCTAssertEqual(strcmp(a.cmdName, "smart"), 0);
    XCTAssertEqual(a.deviceIndex, -1);
    XCTAssertEqual(a.restc, 2);
    XCTAssert(a.rest[2] == NULL);
}

- (void)testParseDiskBeforeCommand {
    WDParsedArgs a; const char *argv[] = {"wd_smart", "--disk", "2", "sleep", "30"};
    XCTAssertEqual(WDParseArgs(5, argv, &a), kWDActionRun);
    XCTAssertEqual(a.deviceIndex, 2);
    XCTAssertEqual(strcmp(a.cmdName, "sleep"), 0);
    XCTAssertEqual(strcmp(a.arg1, "30"), 0);
}

- (void)testParseDiskAfterCommandIsHonored {
    // Regression: previously `erase --confirm --disk 1` silently targeted disk 0
    WDParsedArgs a; const char *argv[] = {"wd_smart", "erase", "--confirm", "--disk", "1"};
    XCTAssertEqual(WDParseArgs(5, argv, &a), kWDActionRun);
    XCTAssertEqual(a.deviceIndex, 1);
    XCTAssertEqual(a.confirm, 1);
    XCTAssert(WDHasConfirmFlag(a.restc, a.rest));
}

- (void)testParseDiskEqualsForm {
    WDParsedArgs a; const char *argv[] = {"wd_smart", "info", "--disk=3"};
    XCTAssertEqual(WDParseArgs(3, argv, &a), kWDActionRun);
    XCTAssertEqual(a.deviceIndex, 3);
}

- (void)testParseDiskNeverBecomesPassword {
    // Regression: previously `unlock --disk 1` used "--disk" as the password
    WDParsedArgs a; const char *argv[] = {"wd_smart", "unlock", "--disk", "1"};
    XCTAssertEqual(WDParseArgs(4, argv, &a), kWDActionRun);
    XCTAssertEqual(a.deviceIndex, 1);
    XCTAssert(a.arg1 == NULL, @"no positional args remain");
    XCTAssertEqual(a.restc, 2);
}

- (void)testParseVerboseAnywhere {
    WDParsedArgs a; const char *argv[] = {"wd_smart", "smart", "-v"};
    XCTAssertEqual(WDParseArgs(3, argv, &a), kWDActionRun);
    XCTAssertEqual(a.verbose, 1);
    const char *argv2[] = {"wd_smart", "--verbose", "smart"};
    XCTAssertEqual(WDParseArgs(3, argv2, &a), kWDActionRun);
    XCTAssertEqual(a.verbose, 1);
}

- (void)testParseConfirmBeforeCommand {
    WDParsedArgs a; const char *argv[] = {"wd_smart", "--confirm", "erase"};
    XCTAssertEqual(WDParseArgs(3, argv, &a), kWDActionRun);
    XCTAssertEqual(strcmp(a.cmdName, "erase"), 0);
    XCTAssert(WDHasConfirmFlag(a.restc, a.rest));
    XCTAssertEqual(strcmp(a.rest[a.restc - 1], "--confirm"), 0, @"--confirm appended after command");
}

- (void)testParseHelpForms {
    WDParsedArgs a;
    const char *h1[] = {"wd_smart", "-h"};       XCTAssertEqual(WDParseArgs(2, h1, &a), kWDActionHelp);
    const char *h2[] = {"wd_smart", "--help"};   XCTAssertEqual(WDParseArgs(2, h2, &a), kWDActionHelp);
    const char *h3[] = {"wd_smart", "help"};     XCTAssertEqual(WDParseArgs(2, h3, &a), kWDActionHelp);
    const char *h4[] = {"wd_smart", "smart", "-h"}; XCTAssertEqual(WDParseArgs(3, h4, &a), kWDActionHelp);
}

- (void)testParseUsageErrors {
    WDParsedArgs a;
    const char *e1[] = {"wd_smart", "--disk"};
    XCTAssertEqual(WDParseArgs(2, e1, &a), kWDActionUsageError);
    XCTAssert(strstr(a.error, "requires an index"));

    const char *e2[] = {"wd_smart", "--disk", "x", "info"};
    XCTAssertEqual(WDParseArgs(4, e2, &a), kWDActionUsageError);
    XCTAssert(strstr(a.error, "invalid --disk"));

    const char *e3[] = {"wd_smart", "--disk", "64"};
    XCTAssertEqual(WDParseArgs(3, e3, &a), kWDActionUsageError);

    const char *e4[] = {"wd_smart", "--bogus", "smart"};
    XCTAssertEqual(WDParseArgs(3, e4, &a), kWDActionUsageError);
    XCTAssert(strstr(a.error, "unknown option"));

    const char *e5[] = {"wd_smart", "frobnicate"};
    XCTAssertEqual(WDParseArgs(2, e5, &a), kWDActionUsageError);
    XCTAssert(strstr(a.error, "unknown command"));
}

- (void)testParseDestructiveRejectsPositionalArgs {
    // A typo'd option must never be swallowed by a destructive command
    WDParsedArgs a; const char *argv[] = {"wd_smart", "erase", "-confirm"};
    XCTAssertEqual(WDParseArgs(3, argv, &a), kWDActionUsageError);
    const char *argv2[] = {"wd_smart", "reset-dek", "--confirm", "now"};
    XCTAssertEqual(WDParseArgs(4, argv2, &a), kWDActionUsageError);
    XCTAssert(strstr(a.error, "takes no arguments"));
}

- (void)testParseTooManyArgs {
    WDParsedArgs a;
    const char *argv[kWDMaxArgs + 4];
    argv[0] = "wd_smart"; argv[1] = "sleep";
    for (int i = 2; i < kWDMaxArgs + 4; i++) argv[i] = "x";
    XCTAssertEqual(WDParseArgs(kWDMaxArgs + 4, argv, &a), kWDActionUsageError);
    XCTAssert(strstr(a.error, "too many"));
}

- (void)testParseRestShapeMatchesCommandExpectations {
    // rest[] must be {prog, cmd, positional..., "--confirm"?, NULL} with argOffset=1
    WDParsedArgs a; const char *argv[] = {"wd_smart", "--disk", "0", "set-password", "hunter2"};
    XCTAssertEqual(WDParseArgs(5, argv, &a), kWDActionRun);
    XCTAssertEqual(a.restc, 3);
    XCTAssertEqual(strcmp(a.rest[1], "set-password"), 0);
    XCTAssertEqual(strcmp(a.rest[2], "hunter2"), 0);
    XCTAssert(a.rest[3] == NULL);
}

- (void)testEveryCommandInTableIsFindable {
    for (int i = 0; i < kWDCommandCount; i++) {
        const WDCommandSpec *s = WDFindCommand(kWDCommands[i].name);
        XCTAssert(s == &kWDCommands[i]);
        if (s->destructive) XCTAssertEqual(strcmp(s->args, "--confirm"), 0, @"%s", s->name);
    }
    XCTAssert(WDFindCommand("probe") != NULL);
    XCTAssert(WDFindCommand(NULL) == NULL);
}

// MARK: - Sense String Branches

- (void)testLastErrorStringStatusWithoutSense {
    g_lastSense = (WDScsiSense){ .valid = YES, .taskStatus = 0x08 };
    XCTAssert(strstr(WDScsiLastErrorString(), "SCSI status 08 (BUSY), no sense data"), @"%s", WDScsiLastErrorString());
    g_lastSense = (WDScsiSense){ .valid = YES, .taskStatus = 0x05 };
    XCTAssert(strstr(WDScsiLastErrorString(), "status 05 (unknown)"));
}

- (void)testLastErrorStringUnknownASC {
    g_lastSense = (WDScsiSense){ .valid = YES, .taskStatus = 0x02, .senseKey = 0x03, .asc = 0x11 };
    const char *s = WDScsiLastErrorString();
    XCTAssert(strstr(s, "sense 03/11/00 (Medium Error)"), @"%s", s);
    XCTAssertFalse(strstr(s, "status"), @"CHECK CONDITION is the expected status; don't append it");
}

- (void)testLastErrorStringAppendsOddStatusWithSense {
    // Sense present but status isn't CHECK CONDITION -> must not hide the status
    g_lastSense = (WDScsiSense){ .valid = YES, .taskStatus = 0x05, .senseKey = 0x02, .asc = 0x04, .ascq = 0x01 };
    XCTAssert(strstr(WDScsiLastErrorString(), ", status 05"), @"%s", WDScsiLastErrorString());
}

- (void)testSenseKeyNames {
    XCTAssertEqual(strcmp(WDScsiSenseKeyName(0x05), "Illegal Request"), 0);
    XCTAssertEqual(strcmp(WDScsiSenseKeyName(0x04), "Hardware Error"), 0);
    XCTAssertEqual(strcmp(WDScsiSenseKeyName(0xF5), "Illegal Request"), 0, @"masks to low nibble");
    XCTAssertEqual(strcmp(WDScsiSenseKeyName(0x0C), "Reserved"), 0);
}

// MARK: - Serial Decode

- (void)testDecodeSerialHex {
    XCTAssertEqualObjects(WDDecodeSerial(@"575836314141334A39313236"), @"WX61AA3J9126");
    XCTAssertEqualObjects(WDDecodeSerial(@"5758"), @"WX");
    XCTAssertEqualObjects(WDDecodeSerial(@"57"), @"W");
}

- (void)testDecodeSerialPassthrough {
    XCTAssertEqualObjects(WDDecodeSerial(@"WX61AA3J9126"), @"WX61AA3J9126", @"not hex");
    XCTAssertEqualObjects(WDDecodeSerial(@"575"), @"575", @"odd length");
    XCTAssertEqualObjects(WDDecodeSerial(@"0001"), @"0001", @"non-printable");
    XCTAssertEqualObjects(WDDecodeSerial(@""), @"");
    XCTAssert(WDDecodeSerial(nil) == nil);
}

// MARK: - Password Prompt Path

- (void)testMissingPasswordReportsAndSendsNothing {
    static const char *argv[] = {"wd_smart", "set-password"};
    g_mock.recordCount = 0;
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdSetPassword(NULL, 2, argv, 1), kWDExitUsage); });
    XCTAssert([out containsString:@"No password provided"], @"%@", out);
    XCTAssertEqual(g_mock.recordCount, 0);
}

- (void)testPasswordLengthCountsCharactersNotBytes {
    // 20 x U+00E9 (2 bytes each in UTF-8 = 40 bytes) must be accepted
    static char pw[64];
    for (int i = 0; i < 20; i++) { pw[i*2] = (char)0xC3; pw[i*2+1] = (char)0xA9; }
    pw[40] = 0;
    static const char *argv[] = {"wd_smart", "set-password", pw};
    XCTAssertEqual(WDCmdSetPassword(NULL, 3, argv, 1), kWDExitOK);
}

// MARK: - Reset DEK cipher 0x28

- (void)testResetDEKPageLayoutAES256XTS {
    g_mock.encryptStatus[4] = 0x28;
    const char *argv[] = {"wd_smart", "reset-dek", "--confirm"};
    WDCmdResetDEK(NULL, 3, argv);
    MockSCSIRecord *r = findRecord(0xC1, 0xE3);
    XCTAssert(r != NULL);
    XCTAssertEqual(r->data[4], 0x28);
    XCTAssertEqual(r->data[6], 1);
    XCTAssertEqual(r->cdb[8], 0x28);
}

// MARK: - Read-back verification: cannot verify

- (void)testSleepReportsFailureWhenReadbackUnavailable {
    // MODE SELECT says GOOD but the read-back MODE SENSE fails: we cannot claim
    // success on a bridge whose status is known to be unreliable.
    g_mock.modeSenseFailsAfterSelect = YES;
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdSleep(NULL, "15"), kWDExitFailure); });
    XCTAssert([out containsString:@"Could not verify sleep timer"], @"%@", out);
    XCTAssertFalse([out containsString:@"set to 15"]);
}

- (void)testLEDReportsFailureWhenReadbackUnavailable {
    g_mock.modeSenseFailsAfterSelect = YES;
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdLED(NULL, "off"), kWDExitFailure); });
    XCTAssert([out containsString:@"Could not verify LED"], @"%@", out);
}

- (void)testSleepMismatchShowsOriginalModeSelectSense {
    // Regression (review H2): after read-back, the MODE SELECT sense was lost and
    // the error said "OK (44 bytes)". The original sense must be reported.
    g_mock.modeSelectIgnored = YES;
    g_mock.modeSelectLies = YES; g_mock.modeSelectStatus = 0x02;
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdSleep(NULL, "55"), kWDExitFailure); });
    XCTAssert([out containsString:@"not applied"], @"%@", out);
    XCTAssert([out containsString:@"MODE SELECT: sense 02/04/01"], @"%@", out);
    XCTAssertFalse([out containsString:@"OK ("], @"must not print the read-back's success as the error");
}

// MARK: - Probe

- (void)testProbeDecodesSupportedPageLists {
    NSString *out = captureOutput(NO, ^{ WDCmdProbe(NULL); });
    XCTAssert([out containsString:@"supported VPD pages: 00 80 83 C1 C2"], @"%@", out);
    XCTAssert([out containsString:@"supported diag pages: 00 08 80 83 84 85"], @"%@", out);
}

- (void)testProbeDiagnosisWithoutBridgeFault {
    // Everything but INQUIRY fails with 'unsupported' (not 04/44): still a
    // diagnosis, but without the internal-target-failure attribution.
    g_mock.failExceptInquiry = YES;
    NSString *out = captureOutput(NO, ^{ XCTAssertEqual(WDCmdProbe(NULL), kWDExitFailure); });
    XCTAssert([out containsString:@"DIAGNOSIS"], @"%@", out);
    XCTAssertFalse([out containsString:@"04/44/xx"], @"%@", out);
}

- (void)testProbeHealthyDrive {
    NSString *out = captureOutput(NO, ^{ XCTAssertEqual(WDCmdProbe(NULL), kWDExitOK); });
    XCTAssert([out containsString:@"0x85 SMART data                    OK"], @"%@", out);
    XCTAssert(![out containsString:@"DIAGNOSIS"]);
}

- (void)testProbeDiagnosesBridgeFault {
    g_mock.failAll = YES; g_mock.failKey = 0x04; g_mock.failASC = 0x44; g_mock.failASCQ = 0x81;
    NSString *out = captureOutput(NO, ^{ XCTAssertEqual(WDCmdProbe(NULL), kWDExitFailure); });
    XCTAssert([out containsString:@"DIAGNOSIS"], @"%@", out);
    XCTAssert([out containsString:@"internal target failure"]);
}

// MARK: - LED

- (void)testCmdLEDReadsState {
    NSString *out = captureOutput(NO, ^{ WDCmdLED(NULL, NULL); });
    XCTAssert([out containsString:@"LED: on"]);
}

- (void)testCmdLEDSetsOff {
    XCTAssertEqual(WDCmdLED(NULL, "off"), kWDExitOK);
    XCTAssertEqual(g_mock.ledPage[12], 0x00);
    XCTAssertEqual(g_mock.ledPage[0], 0, @"header must be cleared");
    XCTAssertEqual(g_mock.ledPage[4] & 0x80, 0, @"PS bit must be cleared");
    NSString *out = captureOutput(NO, ^{ WDCmdLED(NULL, NULL); });
    XCTAssert([out containsString:@"LED: off"]);
}

- (void)testCmdLEDRejectsBadArg {
    XCTAssertEqual(WDCmdLED(NULL, "blink"), kWDExitUsage);
}

- (void)testCmdLEDRejectsWrongPageCode {
    g_mock.ledPage[4] = 0x1A;   // bridge returned a different page
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdLED(NULL, NULL), kWDExitFailure); });
    XCTAssert([out containsString:@"expected 0x21"]);
}

// MARK: - Bounds and Input Validation

- (void)testInfoHandlesManyPortsWithoutOverread {
    // Bridge claims 8 ports (64 bytes) — must clamp to 4, not read off the stack
    g_mock.vpdPages[0xC1][3] = 0x40;
    for (int i = 0; i < 7; i++) {
        g_mock.vpdPages[0xC1][4 + i*8] = (i == 1);
        memcpy(&g_mock.vpdPages[0xC1][5 + i*8], i == 1 ? "USB2.0 " : "USB3.0 ", 7);
    }
    NSString *out = captureOutput(NO, ^{ WDCmdInfo(NULL); });
    XCTAssert([out containsString:@"USB2.0 (active)"], @"%@", out);
    // exactly 4 entries printed = 3 separators
    NSUInteger commas = [[out componentsSeparatedByString:@", "] count] - 1;
    XCTAssertEqual(commas, (NSUInteger)3);
}

- (void)testInfoTrimsSerialPadding {
    memcpy(&g_mock.vpdPages[0x80][4], "WX61AA3J9126    ", 16);
    g_mock.vpdPages[0x80][3] = 16;
    NSString *out = captureOutput(NO, ^{ WDCmdInfo(NULL); });
    XCTAssert([out containsString:@"Serial:   WX61AA3J9126\n"], @"%@", out);
}

- (void)testInfoFallsBackToDiag83WhenSignatureWrong {
    // C0/45 returns GOOD but without the 0x45 signature -> use diag page 0x83
    g_mock.encryptStatus[0] = 0x00;
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdInfo(NULL), kWDExitOK); });
    XCTAssert([out containsString:@"Encrypt:  Off\n"], @"fallback has no cipher suffix: %@", out);
    BOOL sent83 = NO;
    for (int i = 0; i < g_mock.recordCount; i++)
        if (g_mock.records[i].opcode == 0x1C && g_mock.records[i].cdb[2] == 0x83) sent83 = YES;
    XCTAssertTrue(sent83);
}

- (void)testInfoReportsEncryptionUnavailable {
    // Both C0/45 (bad signature) and diag 0x83 (unsupported) fail -> say so and exit 1
    g_mock.encryptStatus[0] = 0x00;
    g_mock.diag83Unsupported = YES;
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdInfo(NULL), kWDExitFailure); });
    XCTAssert([out containsString:@"Encrypt:  unavailable"], @"%@", out);
    XCTAssert([out containsString:@"OK (48 bytes)"], @"first error (sig mismatch after GOOD) echoed: %@", out);
}

// MARK: - Bridge lies about MODE SELECT status (Passport 0748 quirk)

- (void)testSleepWriteSucceedsWhenBridgeReportsBogusFailure {
    // Real hardware: MODE SELECT commits the timer but returns sense 02/04/01.
    g_mock.modeSelectLies = YES; g_mock.modeSelectStatus = 0x02;
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdSleep(NULL, "45"), kWDExitOK); });
    XCTAssert([out containsString:@"45 minutes"], @"%@", out);
    XCTAssertFalse([out containsString:@"Error:"], @"must not report failure: %@", out);
    UInt32 written = ((UInt32)g_mock.modePage[12]<<24)|((UInt32)g_mock.modePage[13]<<16)
                   |((UInt32)g_mock.modePage[14]<<8)|g_mock.modePage[15];
    XCTAssertEqual(written, (UInt32)(45 * 600));
}

- (void)testSleepWriteSucceedsWithGarbageStatus05 {
    g_mock.modeSelectLies = YES; g_mock.modeSelectStatus = 0x05;
    XCTAssertEqual(WDCmdSleep(NULL, "25"), kWDExitOK);
    UInt32 written = ((UInt32)g_mock.modePage[12]<<24)|((UInt32)g_mock.modePage[13]<<16)
                   |((UInt32)g_mock.modePage[14]<<8)|g_mock.modePage[15];
    XCTAssertEqual(written, (UInt32)(25 * 600));
}

- (void)testLEDWriteSucceedsWhenBridgeReportsBogusFailure {
    g_mock.modeSelectLies = YES; g_mock.modeSelectStatus = 0x02;
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdLED(NULL, "off"), kWDExitOK); });
    XCTAssert([out containsString:@"LED turned off"], @"%@", out);
    XCTAssertEqual(g_mock.ledPage[12], 0x00);
}

- (void)testSleepReportsFailureWhenReadbackDisagrees {
    // Bridge genuinely drops the write: read-back still shows the old value
    g_mock.modeSelectIgnored = YES;
    g_mock.modeSelectLies = YES; g_mock.modeSelectStatus = 0x02;
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdSleep(NULL, "55"), kWDExitFailure); });
    XCTAssert([out containsString:@"not applied"], @"%@", out);
}

- (void)testLEDReportsFailureWhenReadbackDisagrees {
    g_mock.modeSelectIgnored = YES;
    g_mock.modeSelectLies = YES; g_mock.modeSelectStatus = 0x02;
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdLED(NULL, "off"), kWDExitFailure); });
    XCTAssert([out containsString:@"not applied"], @"%@", out);
}

- (void)testSleepReportsFailureWhenWriteFailsAndNoReadback {
    // Genuine failure: everything fails, so read-back fails too
    g_mock.failAll = YES; g_mock.failKey = 0x05; g_mock.failASC = 0x20; g_mock.failASCQ = 0x00;
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCmdSleep(NULL, "45"), kWDExitFailure); });
    XCTAssert([out containsString:@"05/20/00"], @"%@", out);
}

- (void)testSleepRejectsGarbage {
    XCTAssertEqual(WDCmdSleep(NULL, "abc"), kWDExitUsage);
    XCTAssertEqual(WDCmdSleep(NULL, "-5"), kWDExitUsage);
    XCTAssertEqual(WDCmdSleep(NULL, "99999999"), kWDExitUsage);
}

- (void)testSleepClampsParamLenToBuffer {
    // Bridge reports absurd page length; MODE SELECT must send exactly the buffer size
    g_mock.modePage[5] = 0xF0;
    g_mock.recordCount = 0;
    XCTAssertEqual(WDCmdSleep(NULL, "15"), kWDExitOK);
    MockSCSIRecord *r = findRecord(0x15, -1);
    XCTAssert(r != NULL);
    XCTAssertEqual(r->dataSize, (UInt32)44);
}

- (void)testSleepClampsParamLenToMinimum {
    // Tiny page length must still include the timer bytes (>= 16)
    g_mock.modePage[5] = 0x02;
    g_mock.recordCount = 0;
    XCTAssertEqual(WDCmdSleep(NULL, "15"), kWDExitOK);
    MockSCSIRecord *r = findRecord(0x15, -1);
    XCTAssert(r != NULL);
    XCTAssertEqual(r->dataSize, (UInt32)16);
}

- (void)testSleepRejectsWrongPage {
    g_mock.modePage[4] = 0x21;
    XCTAssertEqual(WDCmdSleep(NULL, NULL), kWDExitFailure);
}

- (void)testStatusClampsPageLen {
    // Bridge claims 65535 bytes; we must clamp to 20 entries and print only the
    // one non-empty fixture row (no garbage rows from beyond the buffer).
    g_mock.selfTestLog[2] = 0xFF; g_mock.selfTestLog[3] = 0xFF;
    NSString *out = captureOutput(NO, ^{ XCTAssertEqual(WDCmdStatus(NULL), kWDExitOK); });
    NSArray *lines = [out componentsSeparatedByString:@"\n"];
    NSUInteger dataRows = 0;
    for (NSString *l in lines) if ([l hasPrefix:@"1 "] || [l rangeOfString:@"Short"].location != NSNotFound) dataRows++;
    XCTAssertEqual(dataRows, (NSUInteger)1, @"%@", out);
}

- (void)testCookPasswordRejectsInvalidUTF8 {
    static UInt8 cooked[32];
    static const char bad[] = {(char)0xFF, (char)0xFE, 'x', 0};
    NSString *out = captureOutput(YES, ^{ XCTAssertEqual(WDCookPassword(NULL, bad, cooked), -1); });
    XCTAssert([out containsString:@"UTF-8"]);
}

- (void)testCookPasswordRejectsNull {
    UInt8 cooked[32];
    XCTAssertEqual(WDCookPassword(NULL, NULL, cooked), -1);
}

- (void)testCookPasswordDoesNotWriteWhenBlockValid {
    g_mock.recordCount = 0;
    UInt8 cooked[32];
    WDCookPassword(NULL, "x", cooked);
    for (int i = 0; i < g_mock.recordCount; i++)
        XCTAssertNotEqual(g_mock.records[i].opcode, 0xDA, @"must not write Handy Store when already valid");
}

- (void)testCookPasswordInitializesBadSignature {
    memset(g_mock.handyStore, 0, 512);
    UInt8 cooked[32];
    XCTAssertEqual(WDCookPassword(NULL, "x", cooked), 0);
    XCTAssertEqual(g_mock.handyStore[2], 0x44);
    XCTAssertEqual(g_mock.handyStore[3], 0x57);
    XCTAssertEqual(g_mock.handyStore[0x0C], 0x57, @"default salt 'W'");
    UInt8 sum = 0;
    for (int i = 0; i < 512; i++) sum += g_mock.handyStore[i];
    XCTAssertEqual(sum, 0);
}

- (void)testUnlockRejectsTooLongPassword {
    const char *argv[] = {"wd_smart", "unlock", "123456789012345678901234567890123"};
    g_mock.recordCount = 0;
    XCTAssertEqual(WDCmdUnlock(NULL, 3, argv, 1), kWDExitUsage);
    XCTAssertEqual(g_mock.recordCount, 0);
}

- (void)testEncryptLegacyRejectsBadOffset {
    UInt8 cooked[32] = {0};
    XCTAssertEqual(WDScsiEncryptLegacy(NULL, 0xE1, 0, cooked, 0x28), -1, @"0x28+32 > 0x28 page");
}

- (void)testResetDEKPageLayoutFullDisk {
    // cipher 0x30: count=0, zero seed, len 0x28
    g_mock.encryptStatus[4] = 0x30;
    const char *argv[] = {"wd_smart", "reset-dek", "--confirm"};
    WDCmdResetDEK(NULL, 3, argv);
    MockSCSIRecord *r = NULL;
    for (int i = 0; i < g_mock.recordCount; i++)
        if (g_mock.records[i].opcode == 0xC1 && g_mock.records[i].subcode == 0xE3) r = &g_mock.records[i];
    XCTAssert(r != NULL);
    XCTAssertEqual(r->cdb[8], 0x28);
    XCTAssertEqual(r->data[4], 0x30);
    XCTAssertEqual(r->data[6], 0);
    UInt8 zero[32] = {0};
    XCTAssertEqual(memcmp(&r->data[8], zero, 32), 0);
}

- (void)testResetDEKPageLayoutAES256 {
    // cipher 0x20: count=1 at byte 6 (LE16), random seed
    g_mock.encryptStatus[4] = 0x20;
    const char *argv[] = {"wd_smart", "reset-dek", "--confirm"};
    WDCmdResetDEK(NULL, 3, argv);
    MockSCSIRecord *r = NULL;
    for (int i = 0; i < g_mock.recordCount; i++)
        if (g_mock.records[i].opcode == 0xC1 && g_mock.records[i].subcode == 0xE3) r = &g_mock.records[i];
    XCTAssert(r != NULL);
    XCTAssertEqual(r->cdb[8], 0x28);
    XCTAssertEqual(r->data[4], 0x20);
    XCTAssertEqual(r->data[6], 1);
    XCTAssertEqual(r->data[7], 0);
    UInt8 zero[32] = {0};
    XCTAssertNotEqual(memcmp(&r->data[8], zero, 32), 0, @"seed must be random, never zero");
}

- (void)testResetDEKCipher01ShortPage {
    g_mock.encryptStatus[4] = 0x01;
    const char *argv[] = {"wd_smart", "reset-dek", "--confirm"};
    WDCmdResetDEK(NULL, 3, argv);
    MockSCSIRecord *r = NULL;
    for (int i = 0; i < g_mock.recordCount; i++)
        if (g_mock.records[i].opcode == 0xC1 && g_mock.records[i].subcode == 0xE3) r = &g_mock.records[i];
    XCTAssert(r != NULL);
    XCTAssertEqual(r->cdb[8], 0x08);
}

// MARK: - Self-Test Result String Coverage

- (void)testAllSelfTestResultCodes {
    XCTAssert(strcmp(WDSelfTestResultString(0), "Completed OK") == 0);
    XCTAssert(strcmp(WDSelfTestResultString(1), "Aborted (self)") == 0);
    XCTAssert(strcmp(WDSelfTestResultString(2), "Aborted (user)") == 0);
    XCTAssert(strcmp(WDSelfTestResultString(3), "Unknown error") == 0);
    XCTAssert(strcmp(WDSelfTestResultString(4), "Unknown element") == 0);
    XCTAssert(strcmp(WDSelfTestResultString(5), "Electrical fail") == 0);
    XCTAssert(strcmp(WDSelfTestResultString(6), "Servo fail") == 0);
    XCTAssert(strcmp(WDSelfTestResultString(7), "Read fail") == 0);
    XCTAssert(strcmp(WDSelfTestResultString(8), "Handling damage") == 0);
    XCTAssert(strcmp(WDSelfTestResultString(15), "In progress...") == 0);
    XCTAssert(strcmp(WDSelfTestResultString(9), "Reserved") == 0);
    XCTAssert(strcmp(WDSelfTestResultString(14), "Reserved") == 0);
}

// MARK: - Self-Test Log with Failure Entry

- (void)testCmdStatusShowsFailureWithLBA {
    // Add a failed entry with LBA
    g_mock.selfTestLog[2] = 0x00; g_mock.selfTestLog[3] = 0x28; // 2 entries
    UInt8 *entry1 = &g_mock.selfTestLog[4];
    entry1[4] = 0x20; entry1[5] = 1; entry1[6] = 0; entry1[7] = 100; // short, OK
    UInt8 *entry2 = &g_mock.selfTestLog[24];
    entry2[4] = 0x47; // extended(2), read fail(7)
    entry2[5] = 2; entry2[6] = 0; entry2[7] = 200;
    entry2[15] = 0x42; // LBA low byte

    NSString *out = captureOutput(NO, ^{ WDCmdStatus(NULL); });

    XCTAssert([out containsString:@"Read fail"]);
    XCTAssert([out containsString:@"Extended"]);
    XCTAssert([out containsString:@"66"], @"Should show LBA 0x42=66");
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        XCTestSuite *suite = [XCTestSuite testSuiteForTestCaseClass:[WDSmartTests class]];
        [suite runTest];
        XCTestRun *run = [suite testRun];
        printf("\n%lu tests, %lu failures\n",
               (unsigned long)[run testCaseCount],
               (unsigned long)[run failureCount]);
        return [run failureCount] > 0 ? 1 : 0;
    }
}
