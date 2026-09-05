# AGENTS.md — WD Smart Reader Development Notes

## Project Overview

macOS CLI tool that communicates with Western Digital external drives (MyBook, Elements, My Passport) through the WD USB bridge's SES (SCSI Enclosure Services) interface. Bypasses the bridge's blocking of standard ATA SMART passthrough by using vendor-specific SCSI diagnostic pages.

## Architecture

- Objective-C in `src/` (see ARCHITECTURE.md): `WDScsi.m` transport + sense, `WDDevice.m` IOKit, `WDCommands.m`, `WDEncryption.m`, `main.m`
- Talks to the SES device (LUN 1) via `IOSCSIPeripheralDeviceNub` → `SCSITaskDeviceInterface`
- The disk LUN (LUN 0) is claimed by the kernel's block storage driver and CANNOT be accessed from userspace while mounted
- **Root is usually NOT required**: on macOS 15 the SES LUN's `SCSITaskUserClient` opens fine as an admin user (verified uid 501 on Passport 0748). `secure-erase` needs root for `/dev/rdiskN`. Docs used to say "requires sudo" — that was over-stated.
- Every SCSI call fills `g_lastSense`; all error paths print `WDScsiLastErrorString()`. Use `-v` to trace CDBs. Use `probe` to enumerate support.
- Commands return `kWDExit*` codes; main propagates them (0 ok / 1 fail / 2 usage / 3 no device).
- `--disk N` binding: `WDOpenDevice` stores the parent `IOUSBMassStorageDriver` registry ID in `g_selectedEnclosureID`; `WDFindDiskLUNService` only returns the sibling disk LUN. Never look up "the first WD disk" for destructive ops.

## Testing Rules

- `make test` compiles the five library sources (`LIB_SRCS`; everything except `main.m`) **directly with `-DTESTING`** into the test binary. Never link production `.o` files into tests — the `#ifdef TESTING` guards would be inert and `WDCmdErase(..., "--confirm")` would run real `diskutil eraseDisk`. `nm wd_smart_tests | grep -c NSTask` must print 0.
- Tests override `g_scsiExec`, `g_driveIdentity`, and `g_diskBSDName`. Under TESTING, erase prints `[TESTING] would run: diskutil …`, secure-erase prints `[TESTING] would zero-fill /dev/rdiskN`, power-off skips the real unmount, and `WDReadPassword` never prompts.
- `make test-asan` runs the same suite under AddressSanitizer + UBSan; the bounds tests (VPD 0xC1, LOG SENSE, MODE SELECT clamps) only prove anything under ASan.
- Argument parsing lives in `WDArgs.m` (`WDParseArgs`) precisely so it is unit-testable; `main.m` has no logic worth testing.
- The mock supports fault injection: `g_mock.failAll = YES; failKey/ASC/ASCQ` — use it to reproduce field sense codes.

## Device Discovery

WD enclosures expose two SCSI LUNs on the same USB interface:
- **LUN 0**: Disk (type 0) — claimed by `IOSCSIPeripheralDeviceType00` → `IOBlockStorageDriver`
- **LUN 1**: SES (type 13) — has `SCSITaskUserClient` available for userspace access

Filter: `IOServiceMatching("IOSCSIPeripheralDeviceNub")` → `Vendor Identification` = "WD"/"WDC", then `Peripheral Device Type` == 13 **or** `Product Identification` contains "SES" (see `classifyNub()` in `WDDevice.m`).

## SCSI Commands Used

| Command | Opcode | Purpose |
|---------|--------|---------|
| RECEIVE DIAGNOSTIC RESULTS | 0x1C | Read diagnostic pages (SMART, encryption, temp) |
| SEND DIAGNOSTIC | 0x1D | Self-test, power control |
| LOG SENSE | 0x4D | Self-test results log (page 0x10) |
| MODE SENSE (6) | 0x1A | Sleep timer (page 0x1A) |
| MODE SELECT (6) | 0x15 | Set sleep timer |
| INQUIRY | 0x12 | Device identity, VPD pages |
| WD Read Handy Store | 0xD8 | Read NVRAM blocks (security params) |
| WD Write Handy Store | 0xDA | Write NVRAM blocks |
| WD Encrypt Get Status | 0xC0 (sub 0x45) | Full encryption status |
| WD Encrypt Arm/Disarm | 0xC1 (sub 0xE2) | Set/remove password (legacy) |
| WD Encrypt Unlock | 0xC1 (sub 0xE1) | Unlock locked drive (legacy) |
| WD Encrypt Reset DEK | 0xC1 (sub 0xE3) | Reset encryption key (legacy) |
| TEST UNIT READY | 0x00 | `probe` only |
| WD Optimus probe | 0xA2 | `probe` only — rejected (05/20/00) on both tested bridges |

Protocol reference only (documented from the decompile, **not sent by this tool**): WD Encrypt (Optimus) 0xB5 sub 0xEF.

## Diagnostic Pages (via RECEIVE DIAGNOSTIC 0x1C)

| Page | Purpose | Notes |
|------|---------|-------|
| 0x00 | Supported pages list | |
| 0x08 | Short enclosure status | Standard SES |
| 0x80 | Power control | WD vendor — power off |
| 0x83 | Encryption status (simplified) | Returns 1 byte; unreliable on newer bridges |
| 0x84 | SMART threshold status | Pass=0xC2/0x4F, Fail=0x2C/0xF4 (ATA signature) |
| 0x85 | SMART attribute data | 4-byte header + 4 reserved + 512 bytes ATA SMART data |
| 0x86 | Temperature/fan | NOT supported on Passport or MyBook 25ED |

## VPD Pages (via INQUIRY 0x12 with EVPD)

| Page | Purpose | Passport | MyBook 25ED |
|------|---------|----------|-------------|
| 0x00 | Supported pages | ✓ | ✓ |
| 0x80 | Serial number | ✓ | ✓ |
| 0x83 | Device identification | ✓ | ✓ |
| 0xB0 | Block limits | ✗ | ✓ |
| 0xB1 | Block device characteristics (RPM) | ✗ | ✓ |
| 0xB2 | Logical block provisioning | ✗ | ✓ |
| 0xC1 | Active interfaces (USB3/USB2) | ✓ | ✓ |
| 0xC2 | WD capacity (blocks, block size, bays) | ✓ | ✓ |
| 0xC3 | WD vendor (unknown) | ✗ | ✓ |
| 0xC4 | WD product info (model, USB descriptors) | ✗ | ✓ |
| 0xC7 | WD vendor (unknown) | ✗ | ✓ |

## SMART Status Interpretation

The SMART status page (0x84) returns the ATA SMART RETURN STATUS signature:
- **PASS**: statusMSB=0xC2, statusLSB=0x4F
- **FAIL**: statusMSB=0x2C, statusLSB=0xF4

Do NOT check `status == 0` — that's wrong. Check the signature bytes.

## Self-Test Log (LOG SENSE page 0x10)

Format: 4-byte page header + N×20-byte entries (4-byte parameter header + 16-byte data).

Each entry's data byte[0] contains:
- Bits 7:5 = test code (1=short, 2=extended)
- Bits 3:0 = result (0=OK, 15=in progress, 3-8=failures)

**Important**: The WD bridge reports `hours=0` in test entries. Do NOT skip entries where `testCode != 0` even if hours=0.

## SMART Attribute Raw Value Decoding

| Attribute | Raw format |
|-----------|-----------|
| 3 (Spin Up Time) | Lower 16 bits = current ms, next 16 = average |
| 9 (Power-On Hours) | Lower 32 bits = hours |
| 194 (Temperature) | Byte 0 = current °C, byte 1 = min/worst, byte 4 = max/limit |

## Encryption Protocol

### Status (works on all tested drives)

Read via vendor command `0xC0` with subcommand `0x45`:
```
CDB: C0 45 00 00 00 00 00 00 30 00
```
Returns `EncryptStatusReturnData` (up to 48 bytes):
- Byte 0: Signature (0x45)
- Byte 3: SecurityState (0=Off, 1=Locked, 2=Unlocked, 6=MaxUnlocks, 7=NoDEK)
- Byte 4: CipherID (0x10=AES128ECB, 0x20=AES256ECB, 0x28=AES256XTS, 0x30=FullDisk)
- Bytes 6-7: PasswordLength (big-endian, typically 32)
- Bytes 8-11: KeyResetEnabler
- Byte 15: NumberOfCiphers
- Byte 16+: CipherList

### Password Cooking (Key Derivation)

1. Read Handy Store block 1 (opcode 0xD8, block=1)
2. Extract salt from offset 0x0C (UTF-16LE, typically "WDC." = `57 00 44 00 43 00 2E 00`)
3. Read iterations from offset 0x08 (32-bit LE, default 1000) — **stored but not applied**; the hash is a single SHA-256, matching WD Drive Utilities. Do not "fix" this into PBKDF2.
4. Concatenate: salt_bytes + password_as_UTF16LE
5. SHA-256 hash → 32-byte cooked password

**Important**: Before first use, the Handy Store block 1 must have:
- Signature bytes 0-3 `00 01 44 57` (the tool checks bytes 2-3 = `44 57` and writes all four when initialising)
- Iterations at bytes 8-11 (e.g., `E8 03 00 00` = 1000)
- Valid checksum at byte 511: `-(sum of bytes 0-510) & 0xFF`

### Arm/Disarm/Unlock (Legacy Protocol — 0xC1)

```
CDB: C1 E2 00 00 00 00 [LUN] 00 48 00
```
Page data (0x48 bytes):
- Byte 0: 0x45 (signature)
- Byte 3: operation (0x01=arm, 0x10=disarm, 0x00=change)
- Byte 7: password length (32)
- Offset 0x08: old password (for change/disarm)
- Offset 0x28: new password (for arm/change)

### Optimus Protocol (0xB5)

```
CDB: B5 EF 00 [OP] 00 00 00 00 00 24 00 00  (12-byte)
```
Operations: 0x01=arm, 0x02=unlock, 0x04=resetDEK, 0x06=disarm
Data (0x24 bytes): password at offset 2.

### Nighthawk 1U Bridge (MyBook 25ED, fw 1031) — WORKING

This bridge uses the legacy 0xC1 protocol with specific page layouts:

| Operation | CDB | flag (byte 3) | Password offset | Page size |
|-----------|-----|---------------|-----------------|-----------|
| Arm (set-password) | C1 E2 00 00 00 00 00 00 48 00 | 0x01 | 0x28 | 0x48 |
| Disarm (remove-password) | C1 E2 00 00 00 00 00 00 48 00 | 0x10 | 0x08 | 0x48 |
| Unlock | C1 E1 00 00 00 00 00 00 28 00 | 0x00 | 0x08 | 0x28 |
| Reset DEK | C1 E3 [KRE0-3] 00 00 [len] 00 | 0x01 | N/A | varies |

Page format:
- Byte 0: 0x45 (signature)
- Byte 3: operation flag
- Byte 7: password length (32)
- Offset 0x08 or 0x28: 32-byte cooked password (offset depends on operation)

Reset DEK page (for cipher 0x20/0x28): 0x28 bytes with cipher + 32 random bytes at offset 8.
Reset DEK page for cipher 0x30/0x31: also 0x28 bytes, count 0, 32 **zero** bytes (see the layout table below — only cipher 0x01 uses an 8-byte page).

**Critical**: Sense 05/74/40 means "invalid data in page" (wrong password offset or wrong password), NOT "command unsupported." The Optimus protocol (0xB5) is genuinely unsupported (05/20/00).

### Reset DEK page layout (from WDDevice::EncryptResetDEK decompile)

```
CDB:  C1 E3 [KRE0 KRE1 KRE2 KRE3] [LUN] 00 [len] 00
Page: 45 00 00 01 [cipher] 00 [count LE16] [32-byte seed]
```

| Cipher from status[4] | page[4] | count (page[6..7]) | seed | len |
|---|---|---|---|---|
| 0x01 | 0x01 | — | — | 0x08 |
| 0x30 / 0x31 | same | 0 | 32 zero bytes | 0x28 |
| 0x28 | 0x28 | 1 | 32 random | 0x28 |
| anything else | 0x20 | 1 | 32 random | 0x28 |

The count is a **little-endian UInt16 at offset 6** (`page[6]=1, page[7]=0`), not `page[7]`. Seed comes from `arc4random_buf` — never fall back to zeros for 0x20/0x28. WD's own code `exit(-1)`s if `/dev/random` can't be opened.

### Sense 04/44/81 — bridge cannot reach the drive (observed 2026-09 on Passport 0748)

Every command except INQUIRY/VPD returned `04/44/81` (Hardware Error / Internal Target Failure / vendor ASCQ). TEST UNIT READY returned `04/44/00`. Symptoms:
- `diskutil list` shows nothing; LUN 0 nub has **no** `IOSCSIPeripheralDeviceType00` child, `IOServiceBusyTimeoutExtensions = 2`, ~46 s busy at enumeration
- INQUIRY / VPD 0x80 / 0xC1 / 0xC2 still work (served from bridge firmware)
- Encryption status (C0/45), Handy Store, diag pages, mode pages, log pages all fail
- Closing WD Discovery did **not** help; Chrome held a WebUSB `AppleUSBHostDeviceUserClient` on the device

This is not a locked-drive signature (locked drives still answer C0/45). It means the HDD isn't answering the bridge: no spin-up (power), SATA link, or wedged bridge. Remedy: power-cycle, direct port, no hub. `probe` prints this diagnosis automatically when zero drive-reaching commands succeed.

### LED Control Protocol

Uses MODE SENSE/SELECT on vendor page 0x21:
- MODE SENSE: `1A 08 21 00 10 00` (page 0x21, DBD=1, 16 bytes)
- Response: 4-byte header + page data; LED state at absolute byte 12 (0xFF=on, 0x00=off)
- MODE SELECT: `15 11 00 00 10 00` (PF+SP, 16 bytes)
  - Clear header bytes 0-3
  - Clear PS bit (byte 4 &= 0x7F)
  - Set byte 12 = 0xFF (on) or 0x00 (off)
- Supported on: Passport 0748 ✓, MyBook 25ED (needs probe)

## Disk LUN Access Limitations

The disk LUN (LUN 0) CANNOT be accessed from userspace on macOS while the block storage driver is loaded:
- `IOCreatePlugInInterfaceForService` → 0xe00002c7 (kIOReturnNoResources)
- `IOServiceOpen` → 0xe00002c7
- `USBInterfaceOpenSeize` → 0xe00002c5 (kIOReturnExclusiveAccess)
- `DKIOCSCSIREQUEST` ioctl → errno 25 (ENOTTY)
- ATA PASS-THROUGH (12/16) via SES → rejected by bridge
- `diskutil unmountDisk` does NOT release the driver

The only way to access the disk LUN is to `diskutil eject` (which disconnects the drive entirely).

WD Drive Utilities uses the same IOKit APIs we do — no kernel extensions, no special entitlements. Its helper daemon runs as the user (not root).

## Drive-Specific Findings

### My Passport 0748 (1TB, fw 1022)
- Diagnostic pages: 0x00, 0x08, 0x80, 0x83, 0x84, 0x85 (verified via page 0x00 list: `00 08 80 83 84 85`)
- VPD pages: 0x00, 0x80, 0x83, 0xC1, 0xC2
- No VPD 0xB1 or 0xC4 → `05/24/00` (RPM/form factor unavailable)
- No page 0x86 → `05/24/00` (temperature from SMART attr 194 only)
- Self-test log: LOG SENSE 0x10 returns 404 bytes (pageLen 0x190 = 20 entries), but entries may all be empty
- Encryption: cipher 0x20 AES-256-ECB, SecurityState **0x00 = Off**, pwLen 32, KRE `7C 76 8B 1A`, 2 ciphers.
  **arm/disarm/unlock have never been exercised on hardware** — no such invocation exists in any
  shell/agent history. Earlier notes claiming they "work" were inferred from the mock, not verified.
- LED control: YES, verified — MODE SENSE/SELECT page 0x21, state at byte 12 (0xFF=on, 0x00=off)
- Sleep timer: **read AND write both work.** Earlier notes said the write was "rejected by the bridge" —
  that was wrong, caused by the MODE SELECT status bug below. Verified: set 45/20/15/30 min, all committed.
- Erase (0xC4): **no-op** on this bridge (see commit 754dc6d) — `erase` uses `diskutil eraseDisk` instead
- Not Optimus, no VCD support (MODE SENSE 0x24 → `05/24/00`)

### MODE SELECT (0x15) returns a bogus status on this bridge — verify by read-back

MODE SELECT **commits the write but reports failure**. Observed statuses on writes that all took effect:
`0x05` (not a valid SCSI status), `sense 02/04/01`, `sense 04/00/00`, and occasionally GOOD.

Therefore `WDCmdSleep` and `WDCmdLED` do **not** trust the return code: they re-read the page with
MODE SENSE and compare the value against what was requested. Report success on read-back match,
failure only when the read-back disagrees. Never conclude "the bridge rejects writes" from the
MODE SELECT status alone — that mistake is what produced the incorrect notes above.

### Port sensitivity (2026-09-05)

The same drive failed completely on one port and worked perfectly on another:
- Bad port (`AppleT8132USBXHCI@01000000`): every drive-reaching command → `04/44/81`, TUR → `04/44/00`,
  LUN 0 never got a driver, no `/dev/diskN`
- Good port (`@02000000`, still direct, SuperSpeed): everything works, SMART PASSED, 36 °C

So `04/44/81` is **not** automatically a dead drive — try another port/cable before concluding failure.

### Disk LUN does not re-probe after a failed enumeration

When the kernel's LUN 0 probe times out (~45 s, `IOServiceBusyTimeoutExtensions = 2`) it detaches and
**never retries**. SMART then works fine through the SES tunnel while `/dev/diskN` still does not exist,
so `erase`/`secure-erase` remain unavailable until the drive is replugged. Replug on the known-good port.

### My Book 25ED (18TB, fw 1031, "Nighthawk 1U")
- Diagnostic pages: 0x00, 0x08, 0x80, 0x83, 0x84, 0x85
- VPD pages: 0x00, 0x01, 0x80, 0x83, 0xB0, 0xB1, 0xB2, 0xC1, 0xC2, 0xC3, 0xC4, 0xC7
- VPD 0xB1 works: RPM=7200
- No page 0x86 (temperature from SMART attr 194 only)
- Has helium (SMART attr 22 = 100)
- Encryption: Full Disk (cipher 0x30), arm/disarm/unlock work, reset-dek rejected (E3 opcode unknown)
- LED control: needs probe (page 0x21)
- Sleep timer: read AND write work; disable (value=0) rejected (minimum enforced)
- Not Optimus, no VCD support
- USB: idVendor=0x1058, idProduct=0x25ED (9709)

### Feature Support Matrix

| Feature | Passport 0748 | MyBook 25ED | Detection Method |
|---------|:---:|:---:|---------|
| SMART data/status | ✓ | ✓ | RECEIVE DIAG 0x84/0x85 |
| Self-test control | ✓ | ✓ | SEND DIAG 0x1D |
| Self-test log | ✓ | ✓ | LOG SENSE page 0x10 |
| Temperature | ✓ | ✓ | SMART attr 194 |
| Encryption | ✓ | ✓ | Vendor 0xC0/0x45 |
| Reset DEK | ✗ | ✗ | Vendor 0xC1/0xE3 |
| Sleep timer read | ✓ | ✓ | MODE SENSE page 0x1A |
| Sleep timer write | ✓ | ✓ | MODE SELECT page 0x1A — **verify by read-back, status is unreliable** |
| LED control | ✓ | ? | MODE SENSE/SELECT page 0x21 — **verify by read-back** |
| Power off | ✓ | ✓ | SEND DIAG page 0x80 |
| Erase | ✓ (needs `/dev/diskN`) | ✓ (needs `/dev/diskN`) | `diskutil eraseDisk` — vendor 0xC4 is a no-op |
| Optimus | ✗ | ✗ | Probe opcode 0xA2 |
| VCD | ✗ | ? | MODE SENSE page 0x24 |

## Build

```bash
make          # clang -fobjc-arc -Wall -Wextra; Foundation, IOKit, CoreFoundation, DiskArbitration
make test     # 123 XCTests, ~10 ms, never touches hardware
make test-asan
./wd_smart [--disk N] [-v] <command>     # sudo only if exclusive access fails, or for secure-erase
```

## Key Bugs Fixed

1. **SMART Status false alarm** — was checking `status == 0`, now checks ATA pass signature 0xC2/0x4F
2. **Info showed "SES Device"** — now reads disk LUN product from IOKit registry
3. **Self-test results invisible** — bridge reports hours=0, old skip condition hid valid results; now uses testCode bits
4. **Temperature raw value** — was showing packed 48-bit value, now decodes current temp from low byte
5. **Test suite could erase a real drive** — tests linked production `.o` (no `-DTESTING`), so `testCmdEraseWithConfirm` reached `diskutil eraseDisk` whenever a WD disk was mounted. Now compiled with `-DTESTING`, `g_diskBSDName` is mocked, and NSTask isn't even linked into the test binary.
6. **`--disk N` ignored for info/erase/secure-erase** — identity and BSD-name lookups took the first WD disk regardless of selection. Now bound via `g_selectedEnclosureID`.
7. **Sense data discarded** — all failures were "Could not read X". Now every error carries key/ASC/ASCQ and a WD-specific interpretation.
8. **Exit code always 0** — now 1/2/3 on failure/usage/no-device.
9. **Stack over-read in VPD 0xC1** — 24-byte buffer, loop read up to byte 35 with ≥3 ports. Buffer sized to 36, port count clamped.
10. **MODE SELECT length unbounded** — `buf[5] + 6` from the device could exceed the 44-byte buffer. Clamped.
11. **Reset-DEK zero seed** — `fopen("/dev/random")` failure silently sent 32 zero bytes as the new key seed; also count byte was at offset 7 instead of LE16 at offset 6. Now `arc4random_buf` and correct layout per decompile.
12. **Crash on non-UTF-8 password** — `stringWithUTF8String:` returned nil → `appendData:nil` threw. Now validated.
13. **MODE SELECT writes reported failure while succeeding** — the Passport bridge commits the write but returns a bogus status (`0x05`, `02/04/01`, `04/00/00`). `sleep`/`led` reported "Error: could not set" while the value changed. Now verified by reading the page back and comparing. This bug is also what produced the incorrect "sleep timer write rejected by bridge" note in this file.
14. **Empty sense hid the real status** — when a command failed with no sense data the message said "No Sense", concealing the SCSI status byte. Now prints e.g. "SCSI status 05 (unknown), no sense data".
15. **Device-open failures were opaque** — `0xe00002be` said nothing about who held the SES device. Now reads `IOUserClientCreator` and names the process (e.g. "pid 34000, WD Drive Utiliti").
16. **`--disk N` after the command word was silently ignored** — `erase --confirm --disk 1` erased drive 0, and `unlock --disk 1` used "--disk" as the password. Parsing moved to `WDArgs.m`: options are recognised anywhere and destructive commands reject positional args.
17. **`--disk N` could open the wrong enclosure** — if `QueryInterface` failed on device N, `WDOpenDevice` fell through to N+1. Now aborts.
18. **MODE SELECT sense lost on read-back mismatch** — the error printed the read-back's "OK (44 bytes)" instead of the write's sense. Snapshotted before read-back.
19. **"Unverified" writes exited 0** — when MODE SELECT said GOOD but the read-back failed, the tool claimed success. Now exit 1 ("could not verify").
20. **power-off skipped unmount** — sent the power page with volumes mounted ("Disk Not Ejected Properly"). Now unmounts via DiskArbitration first.
