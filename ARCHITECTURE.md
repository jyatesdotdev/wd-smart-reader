# Architecture

## Overview

`wd_smart` is a small macOS CLI (~2100 lines of Objective-C across six source
files) that communicates with Western Digital external drives through the WD
USB bridge's SES (SCSI Enclosure Services) interface.

```
┌──────────────────────────────────────────────────────────┐
│              CLI (src/main.m + src/WDArgs.m)              │
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
  WDArgs.m         — Command table (kWDCommands) and WDParseArgs(); no I/O, fully unit-tested
  main.m           — Usage text and dispatch only
wd_smart_tests.m   — 123 XCTest cases against a mock WD drive (built with -DTESTING)
Makefile           — build, test, test-asan, coverage, install
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

### Argument parsing is a pure function

`WDParseArgs()` turns `argv` into a `WDParsedArgs` struct: options (`--disk N`,
`--disk=N`, `-v`, `--confirm`, `-h`) are recognised **anywhere** on the line,
the first non-option word is the command, and remaining words are positional
args. Destructive commands reject any positional arg, so a mistyped option
(`-confirm`, `--disk` after the command) can never be silently swallowed as a
password or ignored. `main()` only prints usage and dispatches. This exists
because an earlier version parsed options only *before* the command word, so
`erase --confirm --disk 1` targeted drive 0.

### Writes are verified by read-back

The Passport 0748 bridge commits MODE SELECT writes but returns a bogus status
(`0x05`, `02/04/01`, `04/00/00`). `WDCmdSleep` and `WDCmdLED` therefore ignore
the MODE SELECT return code and re-read the page: match → success; mismatch →
failure with the *original* MODE SELECT sense (snapshotted before the read-back
overwrites `g_lastSense`); read-back unavailable → failure ("could not
verify"), never an optimistic exit 0.

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

- Argument parsing: every option form and position, usage errors, destructive
  commands rejecting positional args, the `rest[]` shape commands rely on
- All encryption flows, password cooking, Handy Store initialisation, UTF-8
  validation, character-vs-byte length, page layouts for every reset-DEK cipher
- SMART/self-test/temperature (including the 0x86 thermal page)/sleep/LED/info
  decoding and formatting, encryption-status fallback and "unavailable" paths
- Bounds: VPD 0xC1 port clamping, MODE SELECT length clamping (both ends),
  LOG SENSE page-length clamping, wrong-page detection — also run under ASan
- Bridge quirks: committed-but-reported-failed writes, genuinely dropped
  writes, read-back unavailable, original sense preserved on mismatch
- Sense string rendering for every branch; serial hex decoding
- Exit codes and sense reporting for every command; CDB bytes for self-test
  codes and power-off page
- `--confirm` guards (exact match, any position) and root requirement for
  secure-erase; erase label derivation and fallback
- `probe` page-list decoding and both diagnosis variants

Tests use `open_memstream` for output capture (no silent truncation) and
restore `stdout`/`stderr` in `@finally` so a throwing test cannot poison the
rest of the run. `make test-asan` runs the same suite under
AddressSanitizer + UBSan.

### What's not tested (IOKit adapter)

`WDDevice.m` (open/list/bind/BSD-name/unmount) and `WDExecSCSITaskReal`
require real hardware. They contain no business logic beyond registry
traversal; the two pure helpers that live there (`WDRegistryString` is
IOKit-bound, but `WDDecodeSerial` is not) are exported and tested.

## Dependencies

- **Build**: Xcode Command Line Tools (clang; Foundation, IOKit, CoreFoundation, DiskArbitration)
- **Test**: XCTest (ships with Xcode)
- **Runtime**: none
