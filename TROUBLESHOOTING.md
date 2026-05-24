# Troubleshooting

## "No WD device found or could not access it"

### Drive not detected
1. Check connection:
   ```bash
   diskutil list external
   ```
2. Verify IOKit sees the SES device:
   ```bash
   ioreg -r -c IOSCSIPeripheralDeviceNub | grep -B2 -A2 "SES\|WD"
   ```
3. Some newer WD drives may use a different vendor string. Check output above and update the vendor check in `wd_smart.m` if needed.

### Cannot get exclusive access (0x2c7 or similar)
The SCSI device is claimed by another process.

**Fix:**
- Quit WD Drive Utilities if running
- Kill the helper: `sudo killall WDDriveUtilityHelper`
- Unmount the drive: `diskutil unmountDisk /dev/disk12`

After running the tool, remount:
```bash
diskutil mountDisk /dev/disk12
```

## SMART status shows "CHECK" but attributes look fine

Expected behavior. The SES page 0x84 status word (`0xC24F` etc.) uses a different encoding than ATA SMART's threshold-exceeded flag. If Reallocated Sectors, Pending Sectors, and Uncorrectable are all 0, the drive is healthy.

## Self-test shows "In progress..." but I didn't start one

The self-test log entry at position 0 shows the most recent or currently running test. If the hours field is 0 and no test was started, this may be a stale entry from a previous test or from the factory. The WD SES bridge doesn't always clear log entries properly. Run a short-test and then check status to see fresh results.

## Self-test won't start / "Could not start test"

If the drive recently woke from sleep or was power-cycled, the diagnostic subsystem may need a moment. Try:
1. Wait 30 seconds after the drive mounts
2. Run `abort-test` first to clear any stale state
3. Retry the test

If it still fails, the drive may need a full power cycle (eject + unplug + replug).

## Mac went to sleep and aborted the test

Use `caffeinate` to prevent sleep during long tests:
```bash
caffeinate -s &
sudo ./wd_smart long-test
```
Kill caffeinate when done: `killall caffeinate`

## WD Drive Utilities GUI aborts CLI-initiated tests

The GUI claims exclusive access to the SES device when opened, which can interrupt a running test. Keep the GUI closed while running tests from the CLI.

## "Could not read self-test log" 

The LOG SENSE command for page 0x10 may not be supported on all WD bridge firmware versions. The self-test still runs — you just can't poll progress. Wait the expected duration and check SMART attributes for changes.

## Sleep timer won't set

Some WD enclosures restrict sleep timer values to specific presets (10, 15, 30, 45, 90 minutes). If an arbitrary value fails, try one of these standard values.

## Temperature reads 0 or nonsensical value

The diagnostic page 0x86 (temperature condition) isn't supported on all models. The tool falls back to SMART attribute 194. If that also looks wrong, the raw value may need different byte extraction for your specific drive model.

## Compilation errors

### "framework not found" or missing headers
```bash
xcode-select --install
```

### Warnings about ARC bridge casts
Harmless if building without `-fobjc-arc`. The Makefile includes ARC by default.

## Permission errors

Requires root:
```bash
sudo ./wd_smart
```

If sudo still fails, check that SIP isn't blocking IOKit user clients. This tool works with SIP enabled on macOS 12+.

## Drive works in WD Drive Utilities but not here

WD Drive Utilities uses a privileged helper (`WDDriveUtilityHelper`) that may hold exclusive access. Quit the app completely (check Activity Monitor for the helper process) before using this tool.

## Only one WD drive detected (I have multiple)

The tool currently finds the first WD SES device. If you have multiple WD drives, you'd need to modify `findWDSESDevice()` to accept a serial number or BSD name filter. The IOKit properties include serial numbers for disambiguation.

## Extended test taking forever

Normal for large drives. Rough estimate: ~1 hour per TB for a full surface scan. An 18TB drive may take 18-24+ hours. The drive remains usable during the test.

## macOS update broke the tool

Recompile after OS updates:
```bash
make clean && make
```

If IOKit APIs changed, check:
```bash
ioreg -r -c IOSCSIPeripheralDeviceNub | grep -c "WD"
```
If 0, Apple may have changed the driver stack. File an issue.
