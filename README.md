# wd-smart-reader

A macOS command-line tool that reads SMART data and runs diagnostics on Western Digital external drives (MyBook, Elements, etc.) through the WD USB bridge enclosure.

## Why

WD external drives use a proprietary USB-SATA bridge that blocks standard SMART passthrough. Tools like `smartctl` cannot access these drives. This tool sends SCSI diagnostic commands through the SES (SCSI Enclosure Services) interface — the same approach WD Drive Utilities uses internally.

## Dependencies

None beyond Xcode Command Line Tools. Uses only macOS system frameworks (Foundation, IOKit, CoreFoundation). Does not require WD Drive Utilities.

```bash
xcode-select --install  # if not already installed
```

## Build

```bash
make
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
| `power-off` | Safely spin down and power off drive |

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

## Compatibility

- macOS (tested on Apple Silicon, arm64)
- WD MyBook, Elements, and other WD USB enclosures with SES interface
- Requires root (sudo) for IOKit SCSI exclusive access

## License

MIT
