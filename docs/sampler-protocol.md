# Sampler protocol

The sampler is `sampler/` (Rust, `cargo build --release` → `sampler/target/release/omatop-sampler`).
The shell runs it as a long-lived child process. Communication is newline-delimited JSON:
the sampler writes one JSON object per tick to stdout; the shell writes one command per line to stdin.

Vocabulary is defined in `CONTEXT.md`. Field names below use it.

## Commands (stdin, one per line)

| Command | Effect |
|---|---|
| `rate <hz>` | set tick rate (float, 0.25..10). Default 1. |
| `detail <appId>` | include `detail` (that App's History) in every tick. `detail -` clears. |
| `stop <appId>` | Stop: SIGTERM every Process, SIGKILL survivors after 5 s. For systemd units use `systemctl [--user] stop`. |
| `pause <appId>` | Units: `systemctl [--user] freeze <unit>` (cgroup freezer, atomic). Jobs: SIGSTOP the process group. |
| `resume <appId>` | Units: `systemctl [--user] thaw <unit>`. Jobs: SIGCONT. |
| `restart <appId>` | `.service` units (user or system): `systemctl [--user] restart <unit>`. A `.scope` has no `ExecStart` and cannot be restarted. |
| `fds <on|off>` | enable the per-pid fd scan (Ports + GPU per App). Default on. |

Actions reply on the next tick via `events: [{ "type": "action", "id", "action", "ok": bool, "error"?: string }]`.

## Tick (stdout, one line)

```jsonc
{
  "v": 1,                // protocol version
  "t": 1787502281123,    // unix ms
  "interval": 1.0,       // seconds since previous tick
  "ncpu": 24,
  "vitals": {
    "cpu":   { "total": 12.4, "cores": [3.1, ...], "temp": 61.0, "freq": 3400 },
    "mem":   { "total": 15032385536, "used": 6700000000, "avail": 8600000000, "swapTotal": 0, "swapUsed": 0 },
    "gpu":   { "busy": 7, "temp": 48.0, "vramUsed": 123456, "vramTotal": 2147483648, "available": true },
    "disk":  { "read": 0, "write": 12345 },          // bytes/s, summed over physical devices
    "net":   { "rx": 12345, "tx": 678 },             // bytes/s, excluding lo
    "power": { "watts": 12.3, "battery": 77, "charging": false, "available": true },
    "fan":   { "rpm": 0, "available": true },
    "psi":   { "cpu": 0.0, "mem": 0.0, "io": 0.0, "memFull": 0.0, "ioFull": 0.0 },  // avg10 values
    "load":  [0.5, 0.7, 0.8],
    "uptime": 12345.6
  },
  "pressure": { "level": "calm" | "busy" | "critical", "score": 0.0..1.5, "reason": "CPU stall 42%" },
  "culprit": "<appId>" | null,
  "history": {           // system History, oldest first, up to 120 samples at the 1 Hz base rate.
                         // cpu/gpu/mem are percent (mem = used/total*100), temp in C, net/disk bytes/s, power W
    "cpu": [..], "mem": [..], "gpu": [..], "temp": [..], "netRx": [..], "netTx": [..],
    "diskRead": [..], "diskWrite": [..], "power": [..]
  },
  "apps": [
    {
      "id": "scope:app-Hyprland-chromium-e1bdd203.scope",   // stable while the App lives
      "kind": "app" | "job" | "service" | "desktop" | "kernel",
      "bucket": "apps" | "desktop" | "services" | "kernel",
      "name": "Chromium",        // .desktop Name, else scope name, else comm
      "icon": "chromium",        // .desktop Icon or ""
      "tag": "Browser" | "",     // first recognised .desktop Category, mapped to a short label
      "cmd": "chromium --enable-features=...",   // leader cmdline, truncated to 200 chars
      "unit": "app-Hyprland-chromium-e1bdd203.scope" | "",
      "userUnit": true,          // systemctl --user vs system
      "cpu": 38.2,               // percent of whole machine
      "mem": 3100000000,         // RSS bytes summed
      "gpu": 12.0,               // percent of GPU time, -1 if unknown
      "nproc": 42,
      "pids": [3808, 3863, ...],
      "leader": 3808,
      "started": 1787499744,     // unix seconds of oldest Process
      "ports": [3000, 5432],     // listening TCP ports
      "state": "running" | "paused" | "stopping",
      "recent": true,            // started < 30 min ago OR has ports
      "tty": "pts/3" | "",       // Jobs only
      "readOnly": false          // true for bucket desktop
    }
  ],
  "processes": {             // only for the `detail` App
    "<appId>": [ { "pid", "comm", "cpu", "mem", "state", "cmd", "threads" } ]
  },
  "detail": { "id": "<appId>", "cpu": [..], "mem": [..], "gpu": [..] },   // only when requested
  "events": []
}
```

## Rules

- **App** = one systemd cgroup under `/proc/<pid>/cgroup` (v2, line `0::`).
  - `app.slice/**/*.scope` or `*.service` under `app.slice` → bucket `apps`, kind `app`.
  - `session.slice/**` and `wayland-wm*` → bucket `desktop`, kind `desktop`, `readOnly: true`.
  - `*.service` elsewhere (user or system) → bucket `services`, kind `service`.
  - pid 2 and its children (kthreads) → bucket `kernel`, one App named "Kernel".
  - Anything else under `system.slice` or `init.scope` → bucket `services`.
- **Job** = a foreground or background process group on a terminal, the POSIX definition: leader has
  `pid == pgid`, `tty != 0`, and `pid != sid` (so login shells and the terminal itself are excluded, while
  `bash script.sh`, pipelines and compound commands are included). Members = same pgid plus descendants of the leader. `id` = `job:<leaderPid>:<started>`. The terminal App's numbers **exclude** Job members;
  its `pids` also exclude them. Job `name` = leader comm, `cmd` = leader cmdline.
- **Ports**: parse `/proc/net/tcp` and `tcp6`, state `0A`; map inode → port; each pid's `/proc/<pid>/fd/*` link
  `socket:[inode]` attributes the port to its App/Job.
- **GPU per App**: `/proc/<pid>/fdinfo/*` lines `drm-client-id` + `drm-engine-gfx: <ns>`; dedupe by client id;
  delta ns / interval ns × 100. `-1` when no drm fd.
- **CPU**: per-pid utime+stime delta from `/proc/<pid>/stat` (fields 14,15) over `interval × CLK_TCK × ncpu` → percent of machine.
- **mem**: `statm` RSS pages × page size, summed.
- **History**: ring of 120 samples per series at the 1 Hz base; when `rate` > 1 the ring still advances once per second (downsample by averaging).
- **Pressure**: `score = max(psi.cpu/60, psi.memFull/10, psi.ioFull/40, swapInPagesPerSec/2000)`, then
  `score *= 1.3` when CPU temp >= 95 C (thermal throttle zone on this CPU; temperature alone is never a reason).
  `busy` ≥ 0.35, `critical` ≥ 0.9. `reason` names the dominant term ("cpu stall 42%", "memory stall", "io stall", "swapping").
- **Culprit**: App matching the dominant term: cpu → highest `cpu`; memory/swapping → highest `mem`; io → highest
  per-cgroup `io.pressure` some avg10 (fall back to cpu). `null` when `calm`.
- **State**: `paused` when the unit's `cgroup.freeze` reads 1, or for Jobs when the sampler itself sent SIGSTOP
  (never inferred from the `T` state, which Ctrl-Z also produces).
- **Scope coalescing**: when a process in scope A has its parent in scope B (Chromium's browser and renderer
  scopes), both scopes form one App named and iconed from the parent scope. Terminal scopes named
  `xdg-terminal-exec` take their name/icon from the leader comm (foot, alacritty, ...).
- **Zombies** (state Z) are skipped entirely and never form Apps.
- **Accounting**: for units prefer the cgroup files (`cpu.stat` usage_usec, `memory.current`) over per-pid sums;
  per-pid accounting is used for Jobs and for the terminal remainder.
- **History persistence**: the ring is written to `$HOME/.local/state/omarchy/omatop-history.json` every 10 s and
  reloaded at startup when less than 5 minutes old, so a shell plugin reload does not erase the last two minutes.
- Never exit on a read error; skip that pid. No `panic = "abort"`: a panic in one tick must not take the sampler down. Processes may vanish mid-read.
- Default tick rate 1 Hz; idle CPU cost target < 1 % of one core at 500 pids.
