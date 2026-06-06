# AGENTS.md — WD Smart Reader Development Notes

## Project Overview

macOS CLI tool that communicates with Western Digital external drives (MyBook, Elements, My Passport) through the WD USB bridge's SES (SCSI Enclosure Services) interface. Bypasses the bridge's blocking of standard ATA SMART passthrough by using vendor-specific SCSI diagnostic pages.

## Architecture

- Single Objective-C file (`wd_smart.m`) using IOKit, Foundation, CoreFoundation
- Talks to the SES device (LUN 1) via `IOSCSIPeripheralDeviceNub` → `SCSITaskDeviceInterface`
- The disk LUN (LUN 0) is claimed by the kernel's block storage driver and CANNOT be accessed from userspace while mounted
- Requires root (sudo) for `ObtainExclusiveAccess` on the SES device

## Device Discovery

WD enclosures expose two SCSI LUNs on the same USB interface:
- **LUN 0**: Disk (type 0) — claimed by `IOSCSIPeripheralDeviceType00` → `IOBlockStorageDriver`
- **LUN 1**: SES (type 13) — has `SCSITaskUserClient` available for userspace access

Filter: `IOServiceMatching("IOSCSIPeripheralDeviceNub")` → check `Vendor Identification` = "WD"/"WDC" and `Product Identification` contains "SES".

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
| WD Encrypt (Optimus) | 0xB5 (sub 0xEF) | All encrypt ops (Optimus protocol) |

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
3. Read iterations from offset 0x08 (32-bit LE, default 1000)
4. Concatenate: salt_bytes + password_as_UTF16LE
5. SHA-256 hash → 32-byte cooked password

**Important**: Before first use, the Handy Store block 1 must have:
- Valid signature at bytes 0-3: `00 01 44 57`
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
Reset DEK page (for cipher 0x30/0x31 or special PIDs): 0x08 bytes, no random.

**Critical**: Sense 05/74/40 means "invalid data in page" (wrong password offset or wrong password), NOT "command unsupported." The Optimus protocol (0xB5) is genuinely unsupported (05/20/00).

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
- Diagnostic pages: 0x00, 0x08, 0x80, 0x83, 0x84, 0x85
- VPD pages: 0x00, 0x80, 0x83, 0xC1, 0xC2
- No VPD 0xB1 (RPM not available)
- No page 0x86 (temperature from SMART attr 194 only)
- Self-test log: only retains most recent result
- Encryption: AES-256-ECB (cipher 0x20), arm/disarm/unlock work, reset-dek rejected
- LED control: YES — MODE SENSE/SELECT page 0x21, LED state at byte 12 (0xFF=on, 0x00=off)
- Sleep timer: read works, write (MODE SELECT) rejected by bridge
- Erase (0xC4): works
- Not Optimus, no VCD support

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
| Sleep timer write | ✗ | ✓ | MODE SELECT page 0x1A |
| LED control | ✓ | ? | MODE SENSE/SELECT page 0x21 |
| Power off | ✓ | ✓ | SEND DIAG page 0x80 |
| Erase | ✓ | ? | Vendor 0xC4 |
| Optimus | ✗ | ✗ | Probe opcode 0xA2 |
| VCD | ✗ | ? | MODE SENSE page 0x24 |

## Build

```bash
make          # clang with -fobjc-arc, Foundation, IOKit, CoreFoundation
sudo ./wd_smart [--disk N] <command>
```

## Key Bugs Fixed

1. **SMART Status false alarm** — was checking `status == 0`, now checks ATA pass signature 0xC2/0x4F
2. **Info showed "SES Device"** — now reads disk LUN product from IOKit registry
3. **Self-test results invisible** — bridge reports hours=0, old skip condition hid valid results; now uses testCode bits
4. **Temperature raw value** — was showing packed 48-bit value, now decodes current temp from low byte
