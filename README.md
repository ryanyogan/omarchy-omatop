# Omatop

A system monitor for [Omarchy](https://omarchy.org) that shows you the culprit. Quiet glyph in the bar, clean stats on click, and a full-screen instrument cluster on right-click or `Super+Ctrl+M`. Vim keys everywhere.

![Omatop overlay: dial cluster, aligned timelines, app list](preview.png)

## What you get

**In the bar.** A small chip mark. It wears your theme foreground while the machine is calm, then shades amber, orange and red as the kernel reports real pressure. It never moves; the colour is the whole signal. Left click opens the quick view, right click opens the cluster.

**The quick view.** CPU, memory, GPU and temperature as glowing timelines, one stable net and power line, and the Apps you pinned. Nothing in it reorders. Press `o` to jump to the cluster.

**The cluster.** No card, just instruments on a dark scrim. Four dials sweep on open like a car cluster, then track live: CPU, memory, GPU, temperature. Under them, a trip computer row for net, disk, power, load and uptime. Below that the ledger: every vital on one shared ten minute axis, so a spike in one lines up with a spike in another. Hover or press `,` `.` to scrub back in time and read every strip at that instant.

**Offenders, without the jumping.** The panel you actually read: the top Apps by 30 second average CPU and memory, listed alphabetically with themed icons and meter bars. Membership is re-picked at most every 30 seconds, so the set is stable and the numbers move inside it. No row ever leaps to the top because something sneezed.

**Apps, not PIDs.** One row per application (Chromium is one row, not forty), alphabetical inside User, System, Desktop and Kernel sections. Tab jumps between sections. Rows never reorder by usage, so what you are looking at stays where it is. Focus a row and the dials re-point at that App: the needles glide from the machine's values to Chromium's, and its own timelines slide into the ledger on the same axis. Press `o` to unfold its processes.

**Recent, on top, never moving.** Things you just started from a terminal (`npm run dev`, `cargo build`, `docker compose up`) and recently launched apps sit in a strip at the top, newest first. They never get re-sorted by usage, and each shows its listening ports. Type `/3000` to find whatever is on port 3000, press `x` to stop it. That is the whole workflow. 🎯

**Actions.** `x` stops (asks first). `ss` pauses and resumes, using the cgroup freezer so the whole app freezes atomically. `r` restarts a service. `p` pins an App so it shows in the quick view and survives restarts. The Desktop bucket (compositor, shell, audio) is read-only, on purpose.

**Pressure.** Calm, under load, heavy load, or critical, computed from the kernel's pressure stall information (PSI) and swap-in rate, not from a CPU percentage. Temperature only counts once the CPU is actually in its throttle zone. The glyph, the quick view and the cluster all read the same value.

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
| `tab` `shift-tab` `{` `}` | next, previous section |
| `enter` `l` / `h` `esc` | focus an App in the cluster / unfocus |
| `o` `space` | unfold the App's processes |
| `za` `zM` `zR` | fold section, fold all, unfold all |
| `,` `.` `0` | scrub the timelines, back to live |
| `/` then `n` `N` | filter by name, command or `:port` |
| `sc` `sm` `sg` `sn` | sort by cpu, mem, gpu, name |
| `p` `ss` `x` `r` | pin, pause/resume, stop, restart |
| `?` `q` | help, close |

## How it works

A Rust sampler (`sampler/`) runs as a shell service, reads `/proc`, `/sys` and cgroup v2 every second (configurable), keeps 120 samples of history, and streams one JSON line per tick. The QML side only renders. Apps are systemd scopes, so accounting uses the kernel's own per cgroup counters: shared pages count once and short lived processes are not missed. Jobs are POSIX process groups on a terminal. Ports come from joining `/proc/net/tcp` with each process's socket inodes. GPU per App comes from DRM fdinfo.

The vocabulary lives in [CONTEXT.md](CONTEXT.md), the wire contract in [docs/sampler-protocol.md](docs/sampler-protocol.md).

## Settings

Show CPU percent next to the glyph, reduce motion, and the refresh interval, all in the bar widget's settings.

## Cost

Measured on a Ryzen AI 9 HX 370 (see `docs/performance.md`): with nothing open the plugin adds about a quarter of a percent of one core and 10 MiB; the sampler sends a 790 byte tick each refresh while nothing is open and only sends the full App list while a surface is looking at it.

## License

MIT
