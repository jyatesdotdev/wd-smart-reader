//
//  main.m
//  CLI entry point for wd_smart. All parsing lives in WDArgs.m (unit-tested);
//  this file only prints usage and dispatches.
//

#import "WDSmart.h"

static void WDUsage(void) {
    fprintf(stderr, "Usage: wd_smart [options] <command> [args]\n\nCommands:\n");
    for (int i = 0; i < kWDCommandCount; i++) {
        char nameArgs[40];
        snprintf(nameArgs, sizeof(nameArgs), "%s %s", kWDCommands[i].name, kWDCommands[i].args);
        fprintf(stderr, "  %-28s %s\n", nameArgs, kWDCommands[i].help);
    }
    fprintf(stderr,
        "\nOptions (accepted anywhere on the line):\n"
        "  --disk N       Select drive by index (see 'list' command)\n"
        "  -v, --verbose  Log every SCSI command and its sense result\n"
        "  --confirm      Required by destructive commands\n"
        "  -h, --help     Show this help\n"
        "\n"
        "Exit codes: 0 ok, 1 command failed, 2 usage error, 3 no device\n"
        "\n"
        "Privileges: SES access usually works as an admin user; secure-erase\n"
        "requires sudo. Use sudo if you see 'Cannot get exclusive access'.\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        WDParsedArgs a;
        WDParseArgs(argc, argv, &a);

        if (a.action == kWDActionHelp) { WDUsage(); return kWDExitOK; }
        if (a.action == kWDActionUsageError) {
            fprintf(stderr, "Error: %s\n\n", a.error);
            WDUsage();
            return kWDExitUsage;
        }
        g_verbose = a.verbose;

        if (a.spec->kind == kWDCmdNoDevice) {
            // Only "list" is in this class.
            printf("Connected WD drives:\n");
            int count = WDListDevices();
            if (count == 0) printf("  (none found)\n");
            printf("\nUse --disk N to select a drive.\n");
            return count ? kWDExitOK : kWDExitNoDevice;
        }

        char deviceName[256] = {0};
        SCSITaskDeviceInterface **dev = WDOpenDevice(deviceName, sizeof(deviceName), a.deviceIndex);
        if (!dev) {
            fprintf(stderr, "Error: No WD device found or could not access it.\n");
            return kWDExitNoDevice;
        }
        printf("Device: %s\n\n", deviceName);
        fflush(stdout);

        if (a.spec->kind == kWDCmdDeviceThenDisk) {
            // secure-erase: enclosure is bound via g_selectedEnclosureID;
            // release the SES device before touching the disk LUN.
            WDCloseDevice(dev);
            return WDCmdSecureErase(a.restc, a.rest);
        }

        const char *c = a.cmdName;
        int rc;
        if      (!strcmp(c, "smart"))           rc = WDCmdSmart(dev);
        else if (!strcmp(c, "info"))            rc = WDCmdInfo(dev);
        else if (!strcmp(c, "short-test"))      rc = WDCmdShortTest(dev);
        else if (!strcmp(c, "long-test"))       rc = WDCmdLongTest(dev);
        else if (!strcmp(c, "abort-test"))      rc = WDCmdAbortTest(dev);
        else if (!strcmp(c, "status"))          rc = WDCmdStatus(dev);
        else if (!strcmp(c, "temp"))            rc = WDCmdTemp(dev);
        else if (!strcmp(c, "sleep"))           rc = WDCmdSleep(dev, a.arg1);
        else if (!strcmp(c, "led"))             rc = WDCmdLED(dev, a.arg1);
        else if (!strcmp(c, "power-off"))       rc = WDCmdPowerOff(dev);
        else if (!strcmp(c, "probe"))           rc = WDCmdProbe(dev);
        else if (!strcmp(c, "erase"))           rc = WDCmdErase(dev, a.restc, a.rest);
        else if (!strcmp(c, "set-password"))    rc = WDCmdSetPassword(dev, a.restc, a.rest, 1);
        else if (!strcmp(c, "unlock"))          rc = WDCmdUnlock(dev, a.restc, a.rest, 1);
        else if (!strcmp(c, "remove-password")) rc = WDCmdRemovePassword(dev, a.restc, a.rest, 1);
        else if (!strcmp(c, "reset-dek"))       rc = WDCmdResetDEK(dev, a.restc, a.rest);
        else { fprintf(stderr, "Internal error: no handler for '%s'\n", c); rc = kWDExitUsage; }

        WDCloseDevice(dev);
        return rc;
    }
}
