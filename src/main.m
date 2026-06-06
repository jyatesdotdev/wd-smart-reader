//
//  main.m
//  CLI entry point for wd_smart.
//

#import "WDSmart.h"

#pragma mark - Usage

void WDUsage(void) {
    fprintf(stderr,
        "Usage: wd_smart [--disk N] <command> [args]\n"
        "\n"
        "Commands:\n"
        "  smart          Read SMART attributes (default)\n"
        "  info           Drive identity, serial, RPM, capacity, encryption\n"
        "  short-test     Start short self-test (~2 min)\n"
        "  long-test      Start extended self-test (hours)\n"
        "  abort-test     Abort running self-test\n"
        "  status         Show self-test results log\n"
        "  temp           Show drive temperature and fan status\n"
        "  sleep [MIN]    Get or set sleep timer (0 = disable)\n"
        "  led [on|off]   Get or set drive LED\n"
        "  power-off      Safely spin down and power off drive\n"
        "  erase          Quick format via WD bridge (requires --confirm)\n"
        "  secure-erase   Zero-fill every sector (requires --confirm)\n"
        "  list           Show all connected WD drives\n"
        "  set-password   Set encryption password (locks on next power cycle)\n"
        "  unlock         Unlock a locked drive\n"
        "  remove-password Remove encryption password\n"
        "  reset-dek      Reset encryption key (DESTROYS ALL DATA, --confirm)\n"
        "\n"
        "Options:\n"
        "  --disk N       Select drive by index (see 'list' command)\n"
        "\n"
        "Requires: sudo (root access needed for IOKit SCSI commands)\n"
    );
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Parse --disk N option
        int deviceIndex = -1;  // -1 = first available
        int argOffset = 1;

        if (argc > 2 && strcmp(argv[1], "--disk") == 0) {
            deviceIndex = atoi(argv[2]);
            argOffset = 3;
        }

        const char *cmd = (argc > argOffset) ? argv[argOffset] : "smart";

        if (strcmp(cmd, "-h") == 0 || strcmp(cmd, "--help") == 0 || strcmp(cmd, "help") == 0) {
            WDUsage();
            return 0;
        }

        if (strcmp(cmd, "list") == 0) {
            printf("Connected WD drives:\n");
            int count = WDListDevices();
            if (count == 0) printf("  (none found)\n");
            printf("\nUse --disk N to select a drive.\n");
            return 0;
        }

        // Open the WD SES device
        char deviceName[256] = {0};
        SCSITaskDeviceInterface **dev = WDOpenDevice(deviceName, sizeof(deviceName), deviceIndex);
        if (!dev) {
            fprintf(stderr, "Error: No WD device found or could not access it.\n");
            return 1;
        }
        printf("Device: %s\n\n", deviceName);
        fflush(stdout);

        // Dispatch command
        if      (strcmp(cmd, "smart") == 0)      WDCmdSmart(dev);
        else if (strcmp(cmd, "info") == 0)       WDCmdInfo(dev);
        else if (strcmp(cmd, "short-test") == 0) WDCmdShortTest(dev);
        else if (strcmp(cmd, "long-test") == 0)  WDCmdLongTest(dev);
        else if (strcmp(cmd, "abort-test") == 0) WDCmdAbortTest(dev);
        else if (strcmp(cmd, "status") == 0)     WDCmdStatus(dev);
        else if (strcmp(cmd, "temp") == 0)       WDCmdTemp(dev);
        else if (strcmp(cmd, "sleep") == 0)      WDCmdSleep(dev, argc > argOffset+1 ? argv[argOffset+1] : NULL);
        else if (strcmp(cmd, "led") == 0)        WDCmdLED(dev, argc > argOffset+1 ? argv[argOffset+1] : NULL);
        else if (strcmp(cmd, "power-off") == 0)  WDCmdPowerOff(dev);
        else if (strcmp(cmd, "erase") == 0)     WDCmdErase(dev, argc, argv);
        else if (strcmp(cmd, "set-password") == 0)    WDCmdSetPassword(dev, argc, argv, argOffset);
        else if (strcmp(cmd, "unlock") == 0)          WDCmdUnlock(dev, argc, argv, argOffset);
        else if (strcmp(cmd, "remove-password") == 0) WDCmdRemovePassword(dev, argc, argv, argOffset);
        else if (strcmp(cmd, "reset-dek") == 0)       WDCmdResetDEK(dev, argc, argv);
        else if (strcmp(cmd, "secure-erase") == 0) {
            WDCloseDevice(dev);  // release SES before accessing disk LUN
            WDCmdSecureErase(argc, argv);
            return 0;
        }
        else {
            fprintf(stderr, "Unknown command: %s\n\n", cmd);
            WDUsage();
            WDCloseDevice(dev);
            return 1;
        }

        WDCloseDevice(dev);
    }
    return 0;
}
