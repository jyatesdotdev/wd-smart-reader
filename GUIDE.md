# Guide

## How It Works

WD external enclosures expose two SCSI logical units through their USB-SATA bridge:

1. **LUN 0** — The disk (block device at `/dev/diskN`)
2. **LUN 1** — SES (SCSI Enclosure Services) management interface

The SES device accepts SCSI diagnostic page commands that tunnel through to the drive's ATA SMART subsystem. The most common ones:

| Page | Command | Purpose |
|------|---------|---------|
| 0x84 | RECEIVE DIAGNOSTIC RESULTS | SMART pass/fail status |
| 0x85 | RECEIVE DIAGNOSTIC RESULTS | Full 512-byte SMART attribute data |
| 0x86 | RECEIVE DIAGNOSTIC RESULTS | Temperature/fan condition (not supported on Passport 0748 or MyBook 25ED) |
| 0x80 | SEND DIAGNOSTIC | Power off |
| — | SEND DIAGNOSTIC (code 1/2/4) | Start short / extended / abort self-test |
| 0x10 | LOG SENSE | Self-test results log |
| 0x1A | MODE SENSE/SELECT | Power condition (sleep timer) |
| 0x21 | MODE SENSE/SELECT | LED |
| C0/45 | WD vendor | Encryption status |
| D8/DA | WD vendor | Handy Store (password salt) |

Run `./wd_smart probe` to see exactly which of these your bridge supports. The full protocol reference is in AGENTS.md.

## Reading SMART Output

### Status Word

Page 0x84 returns the ATA SMART RETURN STATUS signature: `C2 4F` means **PASSED**, `2C F4` means **FAILED**. The tool decodes this and prints `SMART Status: PASSED/FAILED/UNKNOWN`. A pass only means no attribute has crossed its threshold — **still check the individual attributes** below for early warning signs.

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
./wd_smart short-test
```
Tests basic electrical and mechanical functions, reads a small portion of the surface.

### Extended Test (hours)
```bash
./wd_smart long-test
```
Full surface scan at roughly 1–1.5 hours per TB. On an 18TB drive, expect 20-30+ hours. The drive remains usable during the test but performance may be reduced.

### Important Notes

- **Keep your Mac awake** during extended tests. Use `caffeinate -s &` in a separate terminal to prevent sleep, which will abort the test.
- **Don't open WD Drive Utilities** while a CLI-initiated test is running — the GUI may abort it by claiming the SES device.
- **Progress percentage** is not reported by the tool. Page 0x85 carries the raw ATA SMART data, which does include self-test progress at ATA offset 362-363, but the tool doesn't parse it yet. `status` shows running/completed/failed only.
- The self-test log's "hours" field may show 0 — this is a bridge firmware limitation that doesn't populate the field when tunneling through SES.

### Checking Results
```bash
./wd_smart status
```
Shows "In progress..." while running, or completed results with pass/fail and the LBA of any failure.

### Aborting
```bash
./wd_smart abort-test
```

## Sleep Timer

Controls when the drive spins down after being idle:

```bash
./wd_smart sleep         # show current setting
./wd_smart sleep 30      # sleep after 30 min
./wd_smart sleep 0       # never sleep (disable)
```

Common values: 10, 15, 30, 45, 90 minutes. Setting to 0 keeps the drive spinning continuously (reduces wear from spin-up/down cycles but uses more power). **The MyBook 25ED rejects 0** — its bridge enforces a minimum; the Passport 0748 accepts any value. The tool verifies every write by reading the timer back, so "set to N minutes" means the drive really has it.

## Monitoring Over Time

Track drive health monthly:

```bash
#!/bin/bash
echo "=== $(date) ===" >> ~/wd_smart_log.txt
./wd_smart smart >> ~/wd_smart_log.txt || echo "wd_smart exit $?" >> ~/wd_smart_log.txt
echo "" >> ~/wd_smart_log.txt
```

`wd_smart` exits non-zero on failure (1 = device error, 2 = usage, 3 = no drive), so the `||` above records problems instead of silently logging nothing.

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
