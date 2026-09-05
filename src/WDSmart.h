//
//  WDSmart.h
//  wd_smart — Western Digital external drive management tool
//
//  Shared header for all modules.
//

#ifndef WD_SMART_H
#define WD_SMART_H

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/scsi/SCSITaskLib.h>
#import <CommonCrypto/CommonDigest.h>

// =============================================================================
#pragma mark - Constants
// =============================================================================

/// WD-specific SCSI diagnostic page codes (via RECEIVE DIAGNOSTIC RESULTS)
enum {
    kWDDiagPageSmartStatus      = 0x84,
    kWDDiagPageSmartData        = 0x85,
    kWDDiagPageTemperature      = 0x86,
    kWDDiagPageEncryptionStatus = 0x83,
    kWDDiagPagePowerControl     = 0x80,
};

/// SCSI self-test codes (used with SEND DIAGNOSTIC)
enum {
    kSelfTestShort  = 0x01,
    kSelfTestExtend = 0x02,
    kSelfTestAbort  = 0x04,
};

/// SCSI command timeouts (milliseconds)
enum {
    kTimeoutDefault = 10000,
    kTimeoutShort   = 5000,
    kTimeoutLong    = 300000,
};

/// Return codes from WDExecSCSITask and wrappers.
enum {
    kWDScsiOK            =  0,
    kWDScsiErrNoTask     = -1,   ///< CreateSCSITask failed
    kWDScsiErrTransport  = -2,   ///< IOKit returned an error (see g_lastSense.ioReturn)
    kWDScsiErrCheck      = -3,   ///< Device returned non-GOOD status (see g_lastSense)
};

/// Process exit codes.
enum {
    kWDExitOK         = 0,
    kWDExitFailure    = 1,   ///< Command failed (device error, etc.)
    kWDExitUsage      = 2,   ///< Bad arguments
    kWDExitNoDevice   = 3,   ///< No WD device found / could not open
};

// =============================================================================
#pragma mark - Data Structures
// =============================================================================

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
    UInt8   condition;
    UInt8   reserved2;
    UInt16  fanRPM;
    UInt16  fanGoalPWM;
    UInt16  fanCurrentPWM;
} WDTemperaturePage;

/// Drive identity information (extracted from IOKit registry or mock).
typedef struct {
    char vendor[32];
    char product[64];
    char firmware[16];
    BOOL found;
} WDDriveIdentity;

/// Result of the most recent SCSI command (sense data, status, transfer length).
/// Populated by WDExecSCSITaskReal (and by the test mock) on every call.
typedef struct {
    IOReturn ioReturn;      ///< kIOReturnSuccess unless transport failed
    UInt8    taskStatus;    ///< SCSITaskStatus (0x00 GOOD, 0x02 CHECK CONDITION, ...)
    UInt8    senseKey;      ///< Sense key (low nibble)
    UInt8    asc;           ///< Additional sense code
    UInt8    ascq;          ///< Additional sense code qualifier
    UInt64   transferred;   ///< Bytes actually transferred
    BOOL     valid;         ///< YES once any command has run
} WDScsiSense;

// =============================================================================
#pragma mark - SCSI Abstraction Layer
// =============================================================================

/// Function pointer type for SCSI task execution.
typedef int (*WDScsiExecFn)(void *ctx,
                            SCSICommandDescriptorBlock cdb,
                            UInt8 cdbSize,
                            void *buffer,
                            UInt32 bufferSize,
                            UInt8 direction,
                            UInt32 timeout);

/// Function pointer for drive identity lookup.
typedef WDDriveIdentity (*WDDriveIdentityFn)(const char *targetSerial);

/// Global SCSI execution function — tests override to inject mock.
extern WDScsiExecFn g_scsiExec;
extern void *g_scsiCtx;

/// Global drive identity provider — tests override to inject mock.
extern WDDriveIdentityFn g_driveIdentity;

/// Function pointer for locating the disk LUN's BSD name (e.g. "disk4").
typedef NSString *(*WDDiskBSDNameFn)(void);

/// Global BSD-name provider — tests override so no test ever touches diskutil.
extern WDDiskBSDNameFn g_diskBSDName;

/// Sense/status of the most recently executed SCSI command.
extern WDScsiSense g_lastSense;

/// When non-zero, every SCSI command logs its CDB and result to stderr.
extern int g_verbose;

/// Registry entry ID of the IOUSBMassStorageDriver that owns the currently
/// opened SES device. Used to bind disk-LUN lookups (identity, BSD name) to
/// the SAME enclosure selected with --disk. 0 = not bound (first match).
extern uint64_t g_selectedEnclosureID;

// =============================================================================
#pragma mark - SCSI Functions
// =============================================================================

int WDExecSCSITaskReal(void *ctx, SCSICommandDescriptorBlock cdb, UInt8 cdbSize,
                       void *buffer, UInt32 bufferSize, UInt8 direction, UInt32 timeout);
int WDExecSCSITask(SCSITaskDeviceInterface **dev, SCSICommandDescriptorBlock cdb,
                   UInt8 cdbSize, void *buffer, UInt32 bufferSize, UInt8 direction, UInt32 timeout);

int WDScsiReceiveDiagnostic(SCSITaskDeviceInterface **dev, UInt8 page, void *buf, UInt32 size);
int WDScsiSendDiagnosticSelfTest(SCSITaskDeviceInterface **dev, UInt8 testCode);
int WDScsiSendDiagnosticPage(SCSITaskDeviceInterface **dev, void *buf, UInt32 size);
int WDScsiLogSense(SCSITaskDeviceInterface **dev, UInt8 page, void *buf, UInt32 size);
int WDScsiModeSense(SCSITaskDeviceInterface **dev, UInt8 page, void *buf, UInt32 size);
int WDScsiModeSelect(SCSITaskDeviceInterface **dev, void *buf, UInt32 size, BOOL save);
int WDScsiInquiry(SCSITaskDeviceInterface **dev, void *buf, UInt32 size);
int WDScsiInquiryVPD(SCSITaskDeviceInterface **dev, UInt8 page, void *buf, UInt32 size);
int WDScsiReadHandyStore(SCSITaskDeviceInterface **dev, UInt32 block, void *buf, UInt32 size);
int WDScsiWriteHandyStore(SCSITaskDeviceInterface **dev, UInt32 block, void *buf, UInt32 size);

/// Human-readable description of g_lastSense, e.g.
/// "sense 05/20/00 (Illegal Request: Invalid command operation code)".
/// Returns a pointer to a static buffer.
const char *WDScsiLastErrorString(void);

/// Print "Error: <msg> — <sense description>" to stderr.
void WDScsiPrintError(const char *msg);

// =============================================================================
#pragma mark - Device Discovery
// =============================================================================

SCSITaskDeviceInterface **WDOpenDevice(char *nameOut, size_t nameSize, int deviceIndex);
int WDListDevices(void);
void WDCloseDevice(SCSITaskDeviceInterface **dev);
NSString *WDFindDiskBSDNameFromIOKit(void);

/// Returns the disk-LUN (Peripheral Device Type 0) IOSCSIPeripheralDeviceNub
/// that shares an enclosure with g_selectedEnclosureID, or the first WD disk
/// LUN if unbound. Caller must IOObjectRelease. Returns IO_OBJECT_NULL if none.
io_service_t WDFindDiskLUNService(void);

// =============================================================================
#pragma mark - Helpers
// =============================================================================

const char *WDSmartAttrName(UInt8 attrId);
UInt64 WDSmartRawValue(const WDSmartAttribute *attr);
const char *WDSmartRawFormatted(const WDSmartAttribute *attr);
const char *WDSelfTestResultString(UInt8 code);
WDDriveIdentity WDDriveIdentityFromIOKit(const char *targetSerial);
void WDPrintDriveIdentity(const char *targetSerial);

/// Read a password: from `arg` if non-NULL, otherwise prompt on the terminal
/// with echo disabled. Returns NULL on failure/empty. Writes into `out`.
const char *WDReadPassword(const char *arg, const char *prompt, char *out, size_t outSize);

// =============================================================================
#pragma mark - Commands
// =============================================================================
//
// Every command returns a kWDExit* code so main() can propagate it.

int WDCmdSmart(SCSITaskDeviceInterface **dev);
int WDCmdInfo(SCSITaskDeviceInterface **dev);
int WDCmdShortTest(SCSITaskDeviceInterface **dev);
int WDCmdLongTest(SCSITaskDeviceInterface **dev);
int WDCmdAbortTest(SCSITaskDeviceInterface **dev);
int WDCmdStatus(SCSITaskDeviceInterface **dev);
int WDCmdTemp(SCSITaskDeviceInterface **dev);
int WDCmdSleep(SCSITaskDeviceInterface **dev, const char *setValue);
int WDCmdPowerOff(SCSITaskDeviceInterface **dev);
int WDCmdLED(SCSITaskDeviceInterface **dev, const char *setValue);
int WDCmdProbe(SCSITaskDeviceInterface **dev);
int WDCmdErase(SCSITaskDeviceInterface **dev, int argc, const char *argv[]);
int WDCmdSecureErase(int argc, const char *argv[]);

// =============================================================================
#pragma mark - Encryption Commands
// =============================================================================

int WDCookPassword(SCSITaskDeviceInterface **dev, const char *password, UInt8 *cookedOut);
int WDScsiEncryptLegacy(SCSITaskDeviceInterface **dev, UInt8 subCmd, UInt8 flag, UInt8 *cooked, int pwOffset);
int WDCmdSetPassword(SCSITaskDeviceInterface **dev, int argc, const char *argv[], int argOffset);
int WDCmdUnlock(SCSITaskDeviceInterface **dev, int argc, const char *argv[], int argOffset);
int WDCmdRemovePassword(SCSITaskDeviceInterface **dev, int argc, const char *argv[], int argOffset);
int WDCmdResetDEK(SCSITaskDeviceInterface **dev, int argc, const char *argv[]);

#endif /* WD_SMART_H */
