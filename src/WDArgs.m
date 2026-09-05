//
//  WDArgs.m
//  Command-line parsing, separated from main() so it can be unit-tested.
//
//  Grammar:  wd_smart [options] <command> [args] [options]
//  Options (--disk N, -v/--verbose, -h/--help, --confirm) are recognised
//  ANYWHERE on the line. Positional args are everything else after the
//  command word. Destructive commands accept no positional args at all, so
//  a mistyped option can never be swallowed as a password or ignored.
//

#import "WDSmart.h"

const WDCommandSpec kWDCommands[] = {
    { "smart",           "",           "Read SMART attributes (default)",                   kWDCmdDevice,         NO  },
    { "info",            "",           "Drive identity, serial, RPM, capacity, encryption", kWDCmdDevice,         NO  },
    { "short-test",      "",           "Start short self-test (~2 min)",                    kWDCmdDevice,         NO  },
    { "long-test",       "",           "Start extended self-test (hours)",                  kWDCmdDevice,         NO  },
    { "abort-test",      "",           "Abort running self-test",                           kWDCmdDevice,         NO  },
    { "status",          "",           "Show self-test results log",                        kWDCmdDevice,         NO  },
    { "temp",            "",           "Show drive temperature and fan status",             kWDCmdDevice,         NO  },
    { "sleep",           "[MIN]",      "Get or set sleep timer (0 = disable)",              kWDCmdDevice,         NO  },
    { "led",             "[on|off]",   "Get or set drive LED",                              kWDCmdDevice,         NO  },
    { "power-off",       "",           "Unmount, spin down and power off drive",            kWDCmdDevice,         NO  },
    { "probe",           "",           "Show which pages/commands this bridge supports",    kWDCmdDevice,         NO  },
    { "list",            "",           "Show all connected WD drives",                      kWDCmdNoDevice,       NO  },
    { "set-password",    "[PASSWORD]", "Set encryption password (prompts if omitted)",      kWDCmdDevice,         NO  },
    { "unlock",          "[PASSWORD]", "Unlock a locked drive",                             kWDCmdDevice,         NO  },
    { "remove-password", "[PASSWORD]", "Remove encryption password",                        kWDCmdDevice,         NO  },
    { "reset-dek",       "--confirm",  "Reset encryption key (DESTROYS ALL DATA)",          kWDCmdDevice,         YES },
    { "erase",           "--confirm",  "Quick format as ExFAT (DESTROYS ALL DATA)",         kWDCmdDevice,         YES },
    { "secure-erase",    "--confirm",  "Zero-fill every sector (DESTROYS ALL DATA)",        kWDCmdDeviceThenDisk, YES },
};
const int kWDCommandCount = (int)(sizeof(kWDCommands) / sizeof(kWDCommands[0]));

const WDCommandSpec *WDFindCommand(const char *name) {
    if (!name) return NULL;
    for (int i = 0; i < kWDCommandCount; i++)
        if (strcmp(kWDCommands[i].name, name) == 0) return &kWDCommands[i];
    return NULL;
}

static void setErr(WDParsedArgs *out, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void setErr(WDParsedArgs *out, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vsnprintf(out->error, sizeof(out->error), fmt, ap);
    va_end(ap);
    out->action = kWDActionUsageError;
}

int WDParseArgs(int argc, const char *argv[], WDParsedArgs *out) {
    memset(out, 0, sizeof(*out));
    out->deviceIndex = -1;
    out->action = kWDActionRun;
    out->rest[out->restc++] = argc > 0 ? argv[0] : "wd_smart";

    const char *positional[kWDMaxArgs];
    int npos = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];

        if (strcmp(a, "--disk") == 0) {
            if (i + 1 >= argc) { setErr(out, "--disk requires an index"); return out->action; }
            char *end = NULL;
            long v = strtol(argv[++i], &end, 10);
            if (!end || *end || v < 0 || v > 63) { setErr(out, "invalid --disk index '%s'", argv[i]); return out->action; }
            out->deviceIndex = (int)v;
            continue;
        }
        if (strncmp(a, "--disk=", 7) == 0) {
            char *end = NULL;
            long v = strtol(a + 7, &end, 10);
            if (!end || *end || v < 0 || v > 63) { setErr(out, "invalid --disk index '%s'", a + 7); return out->action; }
            out->deviceIndex = (int)v;
            continue;
        }
        if (strcmp(a, "-v") == 0 || strcmp(a, "--verbose") == 0) { out->verbose = 1; continue; }
        if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0 || strcmp(a, "help") == 0) {
            out->action = kWDActionHelp; return out->action;
        }
        if (strcmp(a, "--confirm") == 0) { out->confirm = 1; continue; }

        if (a[0] == '-' && a[1] != '\0') {
            setErr(out, "unknown option '%s'", a);
            return out->action;
        }

        if (!out->cmdName) { out->cmdName = a; continue; }

        if (npos >= kWDMaxArgs) { setErr(out, "too many arguments"); return out->action; }
        positional[npos++] = a;
    }

    if (!out->cmdName) out->cmdName = "smart";
    out->spec = WDFindCommand(out->cmdName);
    if (!out->spec) { setErr(out, "unknown command '%s'", out->cmdName); return out->action; }

    if (out->spec->destructive && npos > 0) {
        setErr(out, "'%s' takes no arguments (got '%s'); did you mean an option?", out->cmdName, positional[0]);
        return out->action;
    }

    // rest[] = { prog, cmd, positional..., "--confirm"? , NULL } — the shape
    // every WDCmd* expects (argOffset = 1, --confirm found by scanning).
    out->rest[out->restc++] = out->cmdName;
    for (int i = 0; i < npos && out->restc < kWDMaxArgs + 3; i++) out->rest[out->restc++] = positional[i];
    if (out->confirm && out->restc < kWDMaxArgs + 3) out->rest[out->restc++] = "--confirm";
    out->rest[out->restc] = NULL;
    out->arg1 = npos > 0 ? positional[0] : NULL;
    return out->action;
}
