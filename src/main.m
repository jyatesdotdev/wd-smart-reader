//
//  main.m
//  CLI entry point for wd_smart.
//

#import "WDSmart.h"

#pragma mark - Command Table

typedef enum {
    kCmdNoDevice,       ///< runs without opening the SES device (list, help)
    kCmdDevice,         ///< needs the SES device
    kCmdDeviceThenDisk, ///< opens SES to bind the enclosure, releases it, then uses the disk LUN
} WDCmdKind;

typedef struct {
    const char *name;
    const char *args;       ///< argument synopsis for usage, or ""
    const char *help;
    WDCmdKind   kind;
    BOOL        destructive;
} WDCommandSpec;

static const WDCommandSpec kCommands[] = {
    { "smart",           "",              "Read SMART attributes (default)",                   kCmdDevice, NO },
    { "info",            "",              "Drive identity, serial, RPM, capacity, encryption", kCmdDevice, NO },
    { "short-test",      "",              "Start short self-test (~2 min)",                    kCmdDevice, NO },
    { "long-test",       "",              "Start extended self-test (hours)",                  kCmdDevice, NO },
    { "abort-test",      "",              "Abort running self-test",                           kCmdDevice, NO },
    { "status",          "",              "Show self-test results log",                        kCmdDevice, NO },
    { "temp",            "",              "Show drive temperature and fan status",             kCmdDevice, NO },
    { "sleep",           "[MIN]",         "Get or set sleep timer (0 = disable)",              kCmdDevice, NO },
    { "led",             "[on|off]",      "Get or set drive LED",                              kCmdDevice, NO },
    { "power-off",       "",              "Safely spin down and power off drive",              kCmdDevice, NO },
    { "probe",           "",              "Show which pages/commands this bridge supports",    kCmdDevice, NO },
    { "list",            "",              "Show all connected WD drives",                      kCmdNoDevice, NO },
    { "set-password",    "[PASSWORD]",    "Set encryption password (prompts if omitted)",      kCmdDevice, NO },
    { "unlock",          "[PASSWORD]",    "Unlock a locked drive",                             kCmdDevice, NO },
    { "remove-password", "[PASSWORD]",    "Remove encryption password",                        kCmdDevice, NO },
    { "reset-dek",       "--confirm",     "Reset encryption key (DESTROYS ALL DATA)",          kCmdDevice, YES },
    { "erase",           "--confirm",     "Quick format as ExFAT (DESTROYS ALL DATA)",         kCmdDevice, YES },
    { "secure-erase",    "--confirm",     "Zero-fill every sector (DESTROYS ALL DATA)",        kCmdDeviceThenDisk, YES },
};
static const int kCommandCount = (int)(sizeof(kCommands) / sizeof(kCommands[0]));

static const WDCommandSpec *findCommand(const char *name) {
    for (int i = 0; i < kCommandCount; i++)
        if (strcmp(kCommands[i].name, name) == 0) return &kCommands[i];
    return NULL;
}

#pragma mark - Usage

static void WDUsage(void) {
    fprintf(stderr, "Usage: wd_smart [options] <command> [args]\n\nCommands:\n");
    for (int i = 0; i < kCommandCount; i++) {
        char nameArgs[40];
        snprintf(nameArgs, sizeof(nameArgs), "%s %s", kCommands[i].name, kCommands[i].args);
        fprintf(stderr, "  %-28s %s\n", nameArgs, kCommands[i].help);
    }
    fprintf(stderr,
        "\nOptions:\n"
        "  --disk N       Select drive by index (see 'list' command)\n"
        "  -v, --verbose  Log every SCSI command and its sense result\n"
        "  -h, --help     Show this help\n"
        "\n"
        "Exit codes: 0 ok, 1 command failed, 2 usage error, 3 no device\n"
        "\n"
        "Privileges: SES access usually works as an admin user; secure-erase\n"
        "requires sudo. Use sudo if you see 'Cannot get exclusive access'.\n");
}

#pragma mark - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int deviceIndex = -1;         // -1 = first available
        const char *cmdName = NULL;
        int cmdArgc = 0;              // argv index of the command word
        const char *rest[64];         // argv for the command: rest[0] = program, rest[1] = command, ...
        int restc = 0;
        rest[restc++] = argv[0];

        // Options may appear anywhere before the command word; everything after
        // the command is passed through untouched.
        for (int i = 1; i < argc; i++) {
            const char *a = argv[i];
            if (!cmdName) {
                if (strcmp(a, "--disk") == 0) {
                    if (i + 1 >= argc) { fprintf(stderr, "Error: --disk requires an index\n"); return kWDExitUsage; }
                    char *end = NULL;
                    long v = strtol(argv[++i], &end, 10);
                    if (!end || *end || v < 0 || v > 63) { fprintf(stderr, "Error: invalid --disk index '%s'\n", argv[i]); return kWDExitUsage; }
                    deviceIndex = (int)v;
                    continue;
                }
                if (strcmp(a, "-v") == 0 || strcmp(a, "--verbose") == 0) { g_verbose = 1; continue; }
                if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0 || strcmp(a, "help") == 0) {
                    WDUsage(); return kWDExitOK;
                }
                if (a[0] == '-' && strcmp(a, "--confirm") != 0) {
                    fprintf(stderr, "Unknown option: %s\n\n", a); WDUsage(); return kWDExitUsage;
                }
                cmdName = a;
                cmdArgc = i;
            }
            if (restc < (int)(sizeof(rest) / sizeof(rest[0])) - 1) rest[restc++] = a;
        }
        rest[restc] = NULL;
        (void)cmdArgc;

        if (!cmdName) { cmdName = "smart"; rest[restc++] = "smart"; rest[restc] = NULL; }

        const WDCommandSpec *spec = findCommand(cmdName);
        if (!spec) {
            fprintf(stderr, "Unknown command: %s\n\n", cmdName);
            WDUsage();
            return kWDExitUsage;
        }

        // rest[] now looks like: {prog, cmd, arg1, arg2, ...}; commands take argOffset=1
        const int argOffset = 1;
        const char *arg1 = (restc > 2) ? rest[2] : NULL;

        if (spec->kind == kCmdNoDevice) {
            if (strcmp(cmdName, "list") == 0) {
                printf("Connected WD drives:\n");
                int count = WDListDevices();
                if (count == 0) printf("  (none found)\n");
                printf("\nUse --disk N to select a drive.\n");
                return count ? kWDExitOK : kWDExitNoDevice;
            }
            return kWDExitUsage;
        }

        // Open the WD SES device
        char deviceName[256] = {0};
        SCSITaskDeviceInterface **dev = WDOpenDevice(deviceName, sizeof(deviceName), deviceIndex);
        if (!dev) {
            fprintf(stderr, "Error: No WD device found or could not access it.\n");
            return kWDExitNoDevice;
        }
        printf("Device: %s\n\n", deviceName);
        fflush(stdout);

        int rc;
        if (spec->kind == kCmdDeviceThenDisk) {
            // secure-erase: enclosure is now bound via g_selectedEnclosureID;
            // release the SES device before touching the disk LUN.
            WDCloseDevice(dev);
            rc = WDCmdSecureErase(restc, rest);
            return rc;
        }

        if      (strcmp(cmdName, "smart") == 0)           rc = WDCmdSmart(dev);
        else if (strcmp(cmdName, "info") == 0)            rc = WDCmdInfo(dev);
        else if (strcmp(cmdName, "short-test") == 0)      rc = WDCmdShortTest(dev);
        else if (strcmp(cmdName, "long-test") == 0)       rc = WDCmdLongTest(dev);
        else if (strcmp(cmdName, "abort-test") == 0)      rc = WDCmdAbortTest(dev);
        else if (strcmp(cmdName, "status") == 0)          rc = WDCmdStatus(dev);
        else if (strcmp(cmdName, "temp") == 0)            rc = WDCmdTemp(dev);
        else if (strcmp(cmdName, "sleep") == 0)           rc = WDCmdSleep(dev, arg1);
        else if (strcmp(cmdName, "led") == 0)             rc = WDCmdLED(dev, arg1);
        else if (strcmp(cmdName, "power-off") == 0)       rc = WDCmdPowerOff(dev);
        else if (strcmp(cmdName, "probe") == 0)           rc = WDCmdProbe(dev);
        else if (strcmp(cmdName, "erase") == 0)           rc = WDCmdErase(dev, restc, rest);
        else if (strcmp(cmdName, "set-password") == 0)    rc = WDCmdSetPassword(dev, restc, rest, argOffset);
        else if (strcmp(cmdName, "unlock") == 0)          rc = WDCmdUnlock(dev, restc, rest, argOffset);
        else if (strcmp(cmdName, "remove-password") == 0) rc = WDCmdRemovePassword(dev, restc, rest, argOffset);
        else if (strcmp(cmdName, "reset-dek") == 0)       rc = WDCmdResetDEK(dev, restc, rest);
        else                                              rc = kWDExitUsage;

        WDCloseDevice(dev);
        return rc;
    }
}
