# Omatop

A system monitor for [Omarchy](https://omarchy.org) that shows you the culprit. Quiet glyph in the bar, clean stats on click, and a full-screen instrument cluster on right-click or `Super+Ctrl+M`. Vim keys everywhere.

![Omatop overlay: dial cluster, aligned timelines, app list](preview.png)

## What you get

**In the bar.** A small pulse glyph drawn from the last few seconds of CPU. It stays the colour of your theme while the machine is calm, warms toward the urgent colour when the kernel reports real pressure, and breathes when things are critical. Left click opens the quick view, right click opens the cluster.

**The quick view.** CPU, memory, GPU and temperature with two minute sparklines, net and power, the Apps you pinned, and the top three by CPU with the culprit highlighted. Press `o` to jump to the cluster.

**The cluster.** No card, just instruments on a dark scrim. Four dials sweep on open like a car cluster, then track live: CPU, memory, GPU, temperature. Under them, a trip computer row for net, disk, power, load and uptime. Below that the ledger: every vital on one shared two minute axis, so a spike in one lines up with a spike in another. Hover or press `,` `.` to scrub back in time and read every strip at that instant.

**Apps, not PIDs.** One row per application (Chromium is one row, not forty). Focus a row and the dials re-point at that App: the needles glide from the machine's values to Chromium's, and its own timelines slide into the ledger on the same axis. Press `o` to unfold its processes.

**Recent, on top, never moving.** Things you just started from a terminal (`npm run dev`, `cargo build`, `docker compose up`) and recently launched apps sit in a strip at the top, newest first. They never get re-sorted by usage, and each shows its listening ports. Type `/3000` to find whatever is on port 3000, press `x` to stop it. That is the whole workflow. 🎯

**Actions.** `x` stops (asks first). `ss` pauses and resumes, using the cgroup freezer so the whole app freezes atomically. `r` restarts a service. `p` pins an App so it shows in the quick view and survives restarts. The Desktop bucket (compositor, shell, audio) is read-only, on purpose.

**Pressure.** Calm, busy, or critical, computed from the kernel's pressure stall information (PSI) and swap-in rate, not from a CPU percentage. Temperature only counts once the CPU is actually in its throttle zone. The glyph, the quick view and the cluster all read the same value.

**Your theme.** Accent and urgent colours come from the theme. Spacing and type follow the shell. Reduce motion is a setting.

## Install

```bash
omarchy plugin add https://github.com/ryanyogan/omarchy-omatop --enable
```

Add the **Omatop** widget to your bar (System category). The first time you open the cluster it will offer to build the sampler, a small Rust helper that reads the system. Press `b`; it takes about a minute and only happens once. Omarchy ships `cargo`, so there is nothing else to install.

Optional hotkey, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + M", "System monitor", "omarchy-shell shell toggle ryanyogan.omatop")
```

## Keys

| | |
|---|---|
| `j` `k` `gg` `G` `ctrl-d` `ctrl-u` `H` `M` `L` | move (counts work: `5j`, `12G`) |
| `{` `}` | previous, next section |
| `enter` `l` / `h` `esc` | focus an App in the cluster / unfocus |
| `o` `space` | unfold the App's processes |
| `za` `zM` `zR` | fold section, fold all, unfold all |
| `,` `.` `0` | scrub the timelines, back to live |
| `/` then `n` `N` | filter by name, command or `:port` |
| `sc` `sm` `sg` `sn` | sort by cpu, mem, gpu, name |
| `p` `ss` `x` `r` | pin, pause/resume, stop, restart |
| `?` `q` | help, close |

## How it works

A Rust sampler (`sampler/`) runs as a shell service, reads `/proc`, `/sys` and cgroup v2 once a second (four times a second while the cluster is open), keeps two minutes of history, and streams one JSON line per tick. The QML side only renders. Apps are systemd scopes, so accounting uses the kernel's own per cgroup counters: shared pages count once and short lived processes are not missed. Jobs are POSIX process groups on a terminal. Ports come from joining `/proc/net/tcp` with each process's socket inodes. GPU per App comes from DRM fdinfo.

The vocabulary lives in [CONTEXT.md](CONTEXT.md), the wire contract in [docs/sampler-protocol.md](docs/sampler-protocol.md).

## Settings

Show CPU percent next to the glyph, reduce motion, and the sample rates, all in the bar widget's settings.

## License

MIT
