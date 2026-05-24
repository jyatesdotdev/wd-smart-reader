# Guide

## How It Works

WD external enclosures expose two SCSI logical units through their USB-SATA bridge:

1. **LUN 0** — The disk (block device at `/dev/diskN`)
2. **SES Device** — SCSI Enclosure Services management interface

The SES device accepts SCSI diagnostic page commands that tunnel through to the drive's ATA SMART subsystem:

| Page | Command | Purpose |
|------|---------|---------|
| 0x84 | RECEIVE DIAGNOSTIC RESULTS | SMART pass/fail status |
| 0x85 | RECEIVE DIAGNOSTIC RESULTS | Full 512-byte SMART attribute data |
| 0x86 | RECEIVE DIAGNOSTIC RESULTS | Temperature/fan condition |
| — | SEND DIAGNOSTIC (code 1) | Start short self-test |
| — | SEND DIAGNOSTIC (code 2) | Start extended self-test |
| — | SEND DIAGNOSTIC (code 4) | Abort self-test |
| 0x10 | LOG SENSE | Self-test results log |
| 0x1A | MODE SENSE/SELECT | Power condition (sleep timer) |

## Reading SMART Output

### Status Word

The status from page 0x84 often shows non-zero values (like `0xC24F`) even on healthy drives. This is the SES page format, not a direct ATA SMART threshold flag. **Always check individual attributes.**

### Attribute Values

- **Value/Worst**: Normalized 1–253 (higher = better, 100 = typical starting point)
- **Raw Value**: Actual measured count

### Temperature

Attribute 194 raw value is packed multi-byte. The `temp` command extracts the correct byte for you. If reading raw output, take `raw & 0xFF` for Celsius.

### Helium Level (Attribute 22)

Your 18TB MyBook is a helium-sealed drive. Attribute 22 tracks helium integrity. A value of 100 means the seal is intact. If this drops, the drive is leaking helium and will eventually fail — back up immediately.

## Self-Tests

### Short Test (~2 minutes)
```bash
sudo ./wd_smart short-test
```
Tests basic electrical and mechanical functions, reads a small portion of the surface.

### Extended Test (hours)
```bash
sudo ./wd_smart long-test
```
Full surface scan. On an 18TB drive, expect 20-30+ hours. The drive remains usable during the test but performance may be reduced.

### Important Notes

- **Keep your Mac awake** during extended tests. Use `caffeinate -s &` in a separate terminal to prevent sleep, which will abort the test.
- **Don't open WD Drive Utilities** while a CLI-initiated test is running — the GUI may abort it by claiming the SES device.
- **Progress percentage** is not available through the SES interface. The tool can only report running/completed/failed status.
- The self-test log's "hours" field may show 0 — this is a bridge firmware limitation that doesn't populate the field when tunneling through SES.

### Checking Results
```bash
sudo ./wd_smart status
```
Shows "In progress..." while running, or completed results with pass/fail and the LBA of any failure.

### Aborting
```bash
sudo ./wd_smart abort-test
```

## Sleep Timer

Controls when the drive spins down after being idle:

```bash
sudo ./wd_smart sleep         # show current setting
sudo ./wd_smart sleep 30      # sleep after 30 min
sudo ./wd_smart sleep 0       # never sleep (disable)
```

Common values: 10, 15, 30, 45, 90 minutes. Setting to 0 keeps the drive spinning continuously (reduces wear from spin-up/down cycles but uses more power).

## Monitoring Over Time

Track drive health monthly:

```bash
#!/bin/bash
echo "=== $(date) ===" >> ~/wd_smart_log.txt
sudo ./wd_smart smart >> ~/wd_smart_log.txt
echo "" >> ~/wd_smart_log.txt
```

What to watch for:
- **Reallocated Sectors** increasing → drive is remapping bad sectors
- **Current Pending** appearing → unreadable sectors found
- **Helium Level** dropping → sealed enclosure compromised
- **Load Cycle Count** climbing fast → consider disabling sleep timer
- **Temperature** consistently >55°C → improve ventilation

## When to Replace

Replace the drive if:
- Reallocated Sectors > 50 and climbing
- Current Pending Sectors > 0 persistently
- Extended self-test fails with read errors
- Helium level drops below 95
- Unusual noises (clicking, grinding)
