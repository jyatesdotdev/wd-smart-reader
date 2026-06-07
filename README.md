# wd-smart-reader

A macOS command-line tool that reads SMART data and runs diagnostics on Western Digital external drives (MyBook, Elements, etc.) through the WD USB bridge enclosure.

## Why This Exists

WD external drives (MyBook, Elements, EasyStore) use a proprietary USB-SATA bridge that blocks standard SMART passthrough. Every existing tool fails on these enclosures:

- **smartctl** — returns "Operation not supported by device" on WD USB bridges
- **[OS-X-SAT-SMART-Driver](https://github.com/kasbert/OS-X-SAT-SMART-Driver)** (642★) — a macOS kernel extension (kext) for SAT passthrough. Last updated December 2016. Requires unsigned kext loading, which is impossible on Apple Silicon Macs (M1+). Its README explicitly states it is "not compatible to WD Drive Manager, or enclosures with custom kernel extensions."
- **[wdpassport-utils](https://github.com/KenMacD/wdpassport-utils)** — Linux-only Python tool for WD Passport encryption/unlock. No SMART support.
- **[Seagate/openSeaChest](https://github.com/Seagate/openSeaChest)** (718★) — cross-platform drive utility. Cannot communicate through WD's proprietary USB bridge on macOS.
- **[wdepc](https://github.com/tyan-boot/wdepc)** — WD Extended Power Condition tool. Power management only, no SMART.

This tool takes a different approach: instead of trying to pass ATA commands through the bridge (which WD blocks), it talks to the bridge's **SES (SCSI Enclosure Services)** management interface using vendor-specific SCSI diagnostic pages — the same protocol WD Drive Utilities uses internally.

The result is a pure userspace CLI tool that:
- Works on Apple Silicon (no kext required)
- Requires no third-party dependencies
- Provides SMART data, self-tests, temperature, drive info, sleep timer, and erase
- Runs on any modern macOS version

## Dependencies

None beyond Xcode Command Line Tools. Uses only macOS system frameworks (Foundation, IOKit, CoreFoundation). Does not require WD Drive Utilities.

```bash
xcode-select --install  # if not already installed
```

## Build

```bash
make
```

## Test

```bash
make test       # run 50 unit tests
make coverage   # run tests with llvm-cov coverage report
```

## Usage

```bash
sudo ./wd_smart [command]
```

### Commands

| Command | Description |
|---------|-------------|
| `smart` | Read SMART attributes (default) |
| `info` | Drive identity, serial, RPM, capacity, encryption |
| `short-test` | Start short self-test (~2 min) |
| `long-test` | Start extended self-test (hours) |
| `abort-test` | Abort a running self-test |
| `status` | Show self-test results log |
| `temp` | Show drive temperature |
| `sleep [MIN]` | Get or set sleep timer (0 = disable) |
| `led [on\|off]` | Get or set drive LED |
| `power-off` | Safely spin down and power off drive |
| `set-password` | Enable drive encryption (locks on power cycle) |
| `unlock` | Unlock a locked drive |
| `remove-password` | Disable encryption (requires current password) |
| `reset-dek` | Reset encryption key — **destroys all data** |
| `erase` | Quick format via WD bridge (requires `--confirm`) |
| `secure-erase` | Zero-fill every sector (requires `--confirm`) |
| `list` | List connected WD drives |

### Multi-Drive Support

```bash
sudo ./wd_smart --disk 0 info   # first drive
sudo ./wd_smart --disk 1 info   # second drive
sudo ./wd_smart list            # show all connected WD drives
```

### Examples

```bash
sudo ./wd_smart                # show SMART attributes
sudo ./wd_smart info           # drive identity and specs
sudo ./wd_smart short-test     # kick off a quick test
sudo ./wd_smart status         # check test progress/results
sudo ./wd_smart temp           # current drive temperature
sudo ./wd_smart sleep 30       # spin down after 30 min idle
sudo ./wd_smart sleep 0        # disable sleep timer
sudo ./wd_smart power-off      # safe eject / power off

# Encryption
sudo ./wd_smart set-password "mypassword"     # enable encryption
sudo ./wd_smart unlock "mypassword"           # unlock after power cycle
sudo ./wd_smart remove-password "mypassword"  # disable encryption
sudo ./wd_smart reset-dek --confirm           # nuke encryption key (DATA LOSS)

# Destructive
sudo ./wd_smart erase --confirm        # quick format (bridge-level)
sudo ./wd_smart secure-erase --confirm # full zero-fill (20+ hrs on 18TB)
```

## Install (optional)

```bash
sudo make install   # copies to /usr/local/bin
```

## Key Attributes to Watch

| Attribute | Concern if... |
|-----------|---------------|
| Reallocated Sectors (5) | Raw > 0 |
| Current Pending Sectors (197) | Raw > 0 |
| Offline Uncorrectable (198) | Raw > 0 |
| UDMA CRC Error Count (199) | Increasing (cable issue) |
| Reallocation Event Count (196) | Raw > 0 |
| Helium Level (22) | Dropping below 100 (sealed drive leak) |

## Project Structure

```
src/
  WDSmart.h          — Shared header (types, constants, declarations)
  WDScsi.m           — SCSI transport abstraction + command wrappers
  WDDevice.m         — IOKit device discovery and management
  WDCommands.m       — SMART parsing, info, temp, sleep, self-test, erase
  WDEncryption.m     — Password cooking and encryption commands
  main.m             — CLI entry point
wd_smart_tests.m    — 50 unit tests with mock WD drive emulator
Makefile            — Build, test, coverage, install
ARCHITECTURE.md     — Design decisions and testing strategy
AGENTS.md           — Protocol reference and development notes
```

## Compatibility

- macOS (tested on Apple Silicon, arm64)
- WD MyBook, Elements, and other WD USB enclosures with SES interface
- Requires root (sudo) for IOKit SCSI exclusive access

## License

MIT
