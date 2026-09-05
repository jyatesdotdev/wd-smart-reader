# Architecture

## Overview

`wd_smart` is a small macOS CLI (~1500 lines of Objective-C across five source
files) that communicates with Western Digital external drives through the WD
USB bridge's SES (SCSI Enclosure Services) interface.

```
┌──────────────────────────────────────────────────────────┐
│                    CLI (src/main.m)                       │
│  command table, option parsing, exit-code propagation    │
├──────────────────────────────────────────────────────────┤
│           Commands (WDCommands.m, WDEncryption.m)         │
│  WDCmdSmart, WDCmdInfo, WDCmdProbe, WDCmdSetPassword…    │
│  every command returns a kWDExit* code                   │
├──────────────────────────────────────────────────────────┤
│              Abstraction Layer (WDSmart.h)                │
│  g_scsiExec (SCSI I/O)  g_driveIdentity  g_diskBSDName   │
│  g_lastSense (sense/status of last command)              │
├──────────────────────────────────────────────────────────┤
│            Hardware Adapters (WDScsi.m, WDDevice.m)       │
│  WDExecSCSITaskReal   WDOpenDevice   WDFindDiskLUNService │
│  WDDriveIdentityFromIOKit   WDFindDiskBSDNameFromIOKit   │
├──────────────────────────────────────────────────────────┤
│            System Frameworks                             │
│  IOKit (SCSITaskLib)  DiskArbitration  NSTask (diskutil) │
└──────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────┐
│          WD USB Bridge (SES LUN 1)          │
│  Vendor SCSI commands → SATA translation    │
└─────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────┐
│              Physical HDD                    │
└─────────────────────────────────────────────┘
```

## File Layout

```
src/
  WDSmart.h        — Shared header: constants, structs, exit codes, all declarations
  WDScsi.m         — SCSI transport (WDExecSCSITaskReal), sense capture/decoding,
                     verbose logging, CDB wrappers (INQUIRY, MODE SENSE, LOG SENSE…)
  WDDevice.m       — IOKit discovery: open SES LUN, bind enclosure, find disk LUN,
                     list devices, BSD-name lookup
  WDCommands.m     — SMART decoding, info, temp, status, sleep, LED, probe, power,
                     erase, secure-erase, password prompt helper
  WDEncryption.m   — Password cooking (SHA-256) and arm/unlock/disarm/reset-DEK
  main.m           — Command table, option parsing, dispatch
wd_smart_tests.m   — 81 XCTest cases against a mock WD drive (built with -DTESTING)
Makefile           — build, test, coverage, install
AGENTS.md          — Protocol reference and per-drive findings
```

## Design Decisions

### Function-pointer seams for testability

All hardware access flows through three global function pointers that tests
replace with mocks:

| Seam | Production | Purpose |
|------|-----------|---------|
| `g_scsiExec` | `WDExecSCSITaskReal` | Every SCSI command |
| `g_driveIdentity` | `WDDriveIdentityFromIOKit` | Model/firmware from the disk LUN's registry entry |
| `g_diskBSDName` | `WDFindDiskBSDNameFromIOKit` | `/dev/diskN` for erase / secure-erase |

The mock never touches IOKit, `diskutil`, or `/dev/rdisk*`. On top of that,
test binaries are compiled with `-DTESTING`, which compiles out the countdown
sleeps and replaces the `diskutil eraseDisk` / zero-fill paths with a
`[TESTING] would run: …` message. `nm wd_smart_tests | grep NSTask` returns
nothing — the erase machinery isn't even linked into the test binary.

**Never link production `.o` files into the test binary.** An earlier version
did, which meant `#ifndef TESTING` guards were inactive and a test with
`--confirm` would have run `diskutil eraseDisk` on any mounted WD drive.

### Sense data is first-class

`WDExecSCSITaskReal` fills `g_lastSense` (IOReturn, task status, sense
key/ASC/ASCQ, bytes transferred) on every call. `WDScsiLastErrorString()`
renders it with WD-specific interpretations learned from hardware:

| Sense | Meaning |
|-------|---------|
| `05/20/00` | Command not supported by this bridge (e.g. Optimus on legacy bridges) |
| `05/24/00` | Invalid field in CDB (unsupported VPD/mode page) |
| `05/74/40` | WD: wrong password *or* wrong page layout — **not** "unsupported" |
| `04/44/81` | Bridge cannot reach the SATA drive. INQUIRY still works because the bridge answers from ROM; everything else fails. Power-cycle. |

`-v` / `--verbose` logs every CDB and its result. `probe` runs a fixed battery
of read-only commands and prints a support matrix plus a diagnosis.

### Enclosure binding for `--disk N`

WD enclosures present two LUNs under one `IOUSBMassStorageDriver`. When
`WDOpenDevice` opens the Nth SES LUN it records the parent driver's registry
entry ID in `g_selectedEnclosureID`. `WDFindDiskLUNService` then only accepts
the disk LUN under that same parent, so `info`, `erase`, and `secure-erase`
operate on the drive the user selected — not whichever WD disk IOKit
enumerates first.

`list` pairs disk↔SES the same way (by parent ID), not by enumeration order.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Command ran but failed (device error — see stderr for sense) |
| 2 | Usage error (bad args, missing `--confirm`) |
| 3 | No WD device found / could not open |

### Why SES, not ATA passthrough

WD USB bridges reject ATA PASS-THROUGH (12/16). They do expose an SES LUN
(type 13) that accepts vendor diagnostic pages for SMART, self-tests,
encryption, and power management — the same path WD Drive Utilities uses.

### Disk LUN access and DriverKit

The disk LUN (LUN 0) is claimed by `IOBlockStorageDriver` and cannot be
opened from userspace while a driver is attached (`kIOReturnNoResources`).
When *no* driver attaches (e.g. the drive failed to spin up), it still lacks a
`SCSITaskUserClientIniter`, so it remains inaccessible.

A DriverKit extension with `com.apple.developer.driverkit.family.scsicontroller`
could in principle sit between `IOUSBMassStorageDriver` and the LUN nubs to
expose a raw-command path to LUN 0 (enabling true ATA IDENTIFY / SMART READ
DATA even on bridges that block SES). That is a separate project: it needs an
app bundle host, notarisation, and user approval in System Settings. The CLI
here deliberately stays kext/dext-free.

### Encryption protocol

Password management uses WD's proprietary vendor commands on the SES device:

1. **Key derivation**: read salt + iteration count from Handy Store block 1
   (initialising it if the signature is missing), concatenate salt and
   password as UTF-16LE, SHA-256 → 32-byte "cooked" password.
2. **Arm**: `C1 E2`, 0x48-byte page, flag 0x01, cooked password at 0x28.
3. **Unlock**: `C1 E1`, 0x28-byte page, cooked password at 0x08.
4. **Disarm**: `C1 E2`, 0x48-byte page, flag 0x10, cooked password at 0x08.
5. **Reset DEK**: `C1 E3` with KeyResetEnabler in CDB[2..5]; page layout
   depends on cipher (see `WDCmdResetDEK`). Seed comes from `arc4random_buf`.

Passwords may be passed on the command line (visible in `ps`/history) or, if
omitted, are prompted with echo off via `readpassphrase(3)`; when stdin is not
a TTY one line is read from stdin.

## Testing Strategy

### Mock emulator

`MockDrive` in `wd_smart_tests.m` emulates a WD bridge: Handy Store, encryption
state machine with password verification, SMART pages, self-test log, VPD
pages, power-condition and LED mode pages. It fills `g_lastSense` exactly as
the real transport does, and supports fault injection (`failAll` + sense
triple) to reproduce field failures such as the `04/44/81` bridge fault.

### What's tested

- All encryption flows, password cooking, Handy Store initialisation, UTF-8
  validation, page layouts for every reset-DEK cipher branch
- SMART/self-test/temperature/sleep/LED/info decoding and formatting
- Bounds: VPD 0xC1 port clamping, MODE SELECT length clamping, LOG SENSE
  page-length clamping, wrong-page detection
- Exit codes and sense reporting for every command
- `--confirm` guards and root requirement for secure-erase
- `probe` diagnosis logic

### What's not tested (IOKit adapter)

`WDDevice.m` (open/list/bind/BSD-name) and `WDExecSCSITaskReal` require real
hardware. They contain no business logic beyond registry traversal.

## Dependencies

- **Build**: Xcode Command Line Tools (clang; Foundation, IOKit, CoreFoundation, DiskArbitration)
- **Test**: XCTest (ships with Xcode)
- **Runtime**: none
