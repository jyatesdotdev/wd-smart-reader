# Architecture

## Overview

`wd_smart` is a single-file macOS CLI tool (~1100 lines of Objective-C) that communicates with Western Digital external drives through the WD USB bridge's SES (SCSI Enclosure Services) interface.

```
┌──────────────────────────────────────────────────────────┐
│                    CLI (main)                             │
│  argv parsing, --disk selection, command dispatch        │
├──────────────────────────────────────────────────────────┤
│                Command Functions                          │
│  cmdSmart, cmdInfo, cmdSetPassword, cmdUnlock, etc.      │
├──────────────────────────────────────────────────────────┤
│              Abstraction Layer                            │
│  g_scsiExec (SCSI I/O)    g_driveIdentity (IOKit info)  │
├──────────────────────────────────────────────────────────┤
│            Hardware Adapters                              │
│  execSCSITaskReal     driveIdentityFromIOKit             │
│  openWDDevice         findWDDiskBSDName                  │
└──────────────────────────────────────────────────────────┘
         │                           │
         ▼                           ▼
┌─────────────────┐       ┌─────────────────────┐
│  IOKit/SCSI     │       │  IOKit Registry     │
│  SCSITaskLib    │       │  Service matching   │
└─────────────────┘       └─────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────┐
│          WD USB Bridge (SES LUN)            │
│  Vendor SCSI commands → SATA translation    │
└─────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────┐
│              Physical HDD                    │
└─────────────────────────────────────────────┘
```

## Design Decisions

### Single-file source

The tool is intentionally a single `.m` file. It has no runtime dependencies beyond macOS system frameworks, builds with one `clang` invocation, and is trivial to audit. The code is organized with `// MARK:` sections.

### Function pointer abstraction for testability

All SCSI I/O flows through a single function pointer (`g_scsiExec`). In production it calls `execSCSITaskReal` (IOKit SCSITaskLib). In tests it's replaced with a mock that emulates a WD drive's command responses.

Similarly, `g_driveIdentity` abstracts IOKit registry lookups so `cmdInfo` and `printDriveIdentity` can be tested without hardware.

### Why SES, not ATA passthrough

WD USB bridges block standard ATA PASS-THROUGH (12/16) commands. However, they expose a second SCSI LUN (type 13, SES) that accepts vendor-specific diagnostic pages for SMART data, self-tests, encryption, and power management. This is the same interface WD Drive Utilities uses.

### Encryption protocol

Password management uses WD's proprietary vendor commands on the SES device:

1. **Key derivation**: Read salt from Handy Store (NVRAM block 1), concatenate with password as UTF-16LE, SHA-256 hash → 32-byte "cooked" password.
2. **Arm** (set-password): CDB `C1 E2`, 0x48-byte page with cooked password at offset 0x28.
3. **Unlock**: CDB `C1 E1`, cooked password at offset 0x08.
4. **Disarm** (remove-password): CDB `C1 E2` with flag 0x10, cooked password at offset 0x08.
5. **Reset DEK**: CDB `C1 E3` with KeyResetEnabler from status.

## File Layout

```
wd_smart.m           — All source code
wd_smart_tests.m     — Unit tests (includes wd_smart.m via #include)
Makefile             — Build, test, coverage, install targets
AGENTS.md            — Protocol reference and development notes
ARCHITECTURE.md      — This file
README.md            — User-facing documentation
.github/workflows/   — CI (GitHub Actions, macOS)
```

## Testing Strategy

### Mock emulator

Tests use a `MockDrive` struct that emulates a WD drive's SCSI responses:
- Handy Store read/write (encryption parameters)
- Encryption status and arm/disarm/unlock with password verification
- SMART diagnostic pages
- Self-test log
- VPD inquiry pages (serial, RPM, capacity, interface)
- Mode sense/select (sleep timer)
- Send diagnostic (self-test, power off)
- Format command (erase)

### What's tested (80% function coverage)

- All encryption flows (set-password, unlock, remove-password, reset-dek)
- Password cooking (SHA-256 hash verification)
- SMART attribute parsing and formatting
- Self-test log parsing (including failure entries with LBA)
- Temperature reading (fallback from page 0x86 to SMART attr 194)
- Sleep timer get/set
- Drive info display (VPD + encryption status)
- Input validation and safety guards (--confirm, password length)
- CDB construction and page layout verification

### What's not tested (IOKit adapter layer)

- `openWDDevice` / `listWDDevices` — IOKit service enumeration
- `findWDDiskBSDName` — IOKit registry traversal
- `execSCSITaskReal` — Real SCSITask execution
- `main` / `usage` — CLI dispatch

These are thin adapters with no business logic. They require real hardware or a kernel-level IOKit mock (which doesn't exist as a standard tool).

## Dependencies

- **Build**: Xcode Command Line Tools (clang, Foundation, IOKit, CoreFoundation)
- **Test**: XCTest framework (included with Xcode)
- **Runtime**: None (statically linked against system frameworks)
