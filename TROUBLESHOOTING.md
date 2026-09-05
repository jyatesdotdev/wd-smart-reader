# Troubleshooting

## First step: `probe` and `-v`

```bash
./wd_smart probe        # which commands does this bridge accept?
./wd_smart -v <command> # print every CDB and its SCSI sense code
```

Every failure message now ends with the SCSI sense triple, e.g.
`sense 05/20/00 (Illegal Request: Invalid command operation code (unsupported))`.
The key ones:

| Sense | Meaning | What to do |
|-------|---------|-----------|
| `05/20/00` | Opcode not supported by this bridge | Feature genuinely unavailable on this model |
| `05/24/00` | Invalid field in CDB | Page not supported (e.g. VPD 0xB1 on Passport) |
| `05/74/40` | WD: invalid data in page | Wrong password, or wrong page layout |
| `04/44/81` | Bridge can't reach the SATA drive | See next section |

## Everything fails with `sense 04/44/81 (Hardware Error)` — but `info` shows serial/capacity

The bridge answers INQUIRY from its own firmware, but anything that has to
talk to the HDD (SMART, encryption status, mode pages, Handy Store) returns
*Internal Target Failure*. `diskutil list` shows no disk and `list` prints
`(no disk)`. In the IOKit registry the LUN 0 nub has no `IOSCSIPeripheralDeviceType00`
child and `IOServiceBusyTimeoutExtensions > 0` — the kernel timed out probing it.

The drive inside the enclosure is not responding: not spinning, SATA link
down, or the bridge is wedged.

1. Unplug the drive, wait 10 seconds, plug it **directly** into the Mac (no hub, no dock)
2. Bus-powered Passports need a full-power port; try another port or the supplied cable
3. Quit WD Discovery / WD Security / WD Drive Utilities (`killall WDDriveUtilityHelper WDSecurityHelper`)
4. Close browser tabs that have WebUSB permission (`ioreg -r -n "My Passport 0748" | grep IOUserClientCreator` shows who holds the device)
5. If it persists across ports and cables, the HDD or bridge has failed

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
3. Some newer WD drives may use a different vendor string. Check output above and update `isWDVendor()` in `src/WDDevice.m` if needed.

### Cannot get exclusive access (0xe00002c5 / 0xe00002c7)
The SES device is claimed by another process, or you lack permission.

**Fix:**
- Quit WD Discovery / WD Drive Utilities / WD Security
- Kill the helpers: `killall WDDriveUtilityHelper WDSecurityHelper`
- Retry with `sudo`

Unmounting the disk is **not** required — the SES LUN is independent of the mounted volume.

## SMART status shows "UNKNOWN"

Page 0x84 returned something other than the ATA pass (`C2 4F`) or fail (`2C F4`) signature. Run with `-v` to see the raw bytes. If Reallocated Sectors, Pending Sectors, and Uncorrectable are all 0, the drive is healthy.

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

- **Passport 0748**: MODE SELECT is rejected by the bridge entirely (`05/20/00`); read works, write doesn't.
- **MyBook 25ED**: write works but `sleep 0` (disable) is rejected — the bridge enforces a minimum. Try `sleep 10`.
- Some enclosures restrict values to presets (10, 15, 30, 45, 90 minutes).

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

On current macOS the SES LUN's `SCSITaskUserClient` is available to admin users, so most commands work without `sudo`. `secure-erase` always needs root (it opens `/dev/rdiskN`); the tool checks and tells you.

If `sudo` still fails with exclusive-access errors, another process holds the device (see above). This tool works with SIP enabled.

## Drive works in WD Drive Utilities but not here

WD Drive Utilities uses a privileged helper (`WDDriveUtilityHelper`) that may hold exclusive access. Quit the app completely (check Activity Monitor for the helper process) before using this tool.

## Multiple WD drives

```bash
./wd_smart list              # [0] My Passport 0748  /dev/disk4  WX61AA3J9126
./wd_smart --disk 1 info
```

`--disk N` binds every command — including `erase` and `secure-erase` — to the
enclosure whose SES device was opened, so the disk LUN is always the sibling of
the selected SES LUN, never "the first WD disk IOKit happens to enumerate".

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
