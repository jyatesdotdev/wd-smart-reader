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
make test       # run 81 unit tests against a mock drive (never touches hardware)
make coverage   # run tests with llvm-cov coverage report
```

## Usage

```bash
./wd_smart [options] <command> [args]
```

SES access normally works as an admin user without `sudo`. Use `sudo` if you
see "Cannot get exclusive access", and always for `secure-erase` (it writes to
`/dev/rdiskN`).

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
| `probe` | Show which SCSI pages/commands this bridge supports, with diagnosis |
| `set-password [PW]` | Enable drive encryption (locks on power cycle); prompts if omitted |
| `unlock [PW]` | Unlock a locked drive; prompts if omitted |
| `remove-password [PW]` | Disable encryption (requires current password) |
| `reset-dek` | Reset encryption key — **destroys all data** |
| `erase` | Quick format via WD bridge (requires `--confirm`) |
| `secure-erase` | Zero-fill every sector (requires `--confirm`) |
| `list` | List connected WD drives |

### Options

| Option | Description |
|--------|-------------|
| `--disk N` | Select drive by index (see `list`). Binds `info`/`erase`/`secure-erase` to that enclosure. |
| `-v`, `--verbose` | Log every SCSI CDB and its sense result to stderr |
| `-h`, `--help` | Show usage |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Command failed (device error — stderr shows the SCSI sense, e.g. `sense 04/44/81 (Hardware Error: …)`) |
| 2 | Usage error / missing `--confirm` |
| 3 | No WD device found or could not open it |

### Multi-Drive Support

```bash
./wd_smart list                 # show all connected WD drives with /dev name and serial
./wd_smart --disk 0 info        # first drive
./wd_smart --disk 1 info        # second drive
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

# Diagnostics
./wd_smart probe               # which pages does this bridge support?
./wd_smart -v smart            # trace every CDB and sense code

# Encryption (omit the password to be prompted securely)
./wd_smart set-password                       # prompts: New password:
./wd_smart unlock                             # prompts: Password:
./wd_smart remove-password "mypassword"       # or pass it on the command line
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
  WDScsi.m           — SCSI transport, sense capture/decoding, command wrappers
  WDDevice.m         — IOKit discovery, enclosure binding for --disk, list
  WDCommands.m       — SMART parsing, info, temp, sleep, LED, probe, self-test, erase
  WDEncryption.m     — Password cooking and encryption commands
  main.m             — CLI entry point
wd_smart_tests.m    — 81 unit tests with mock WD drive emulator (built with -DTESTING)
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
