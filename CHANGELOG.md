# Changelog

## 1.2.0

- Redesigned the quick view around the overlay’s instrument cluster: CPU, memory and GPU gauges, temperatures beside their readings, and compact CPU/memory history on a shared two-minute axis. Per-core activity and pinned Apps remain.
- Added disk read/write throughput, VRAM usage, swap usage and fan speed. Network and power now have their own readable cells; battery status includes charging and still appears at zero watts or zero percent. Unavailable sensors stay hidden.
- The dropdown steps at the sampler cadence, with no gauge sweeps, continuous motion clock or per-core colour animations. Supporting-stat delegates persist across samples instead of being rebuilt on each update. The overlay retains its existing motion settings.
- Scroll with the wheel, arrow keys or j/k when the panel exceeds the available screen height. Open the cluster with a visible mouse shortcut, o or Enter.
- Temperature warnings use the theme’s urgent colour, matching the overlay even when the bar’s active colour is neutral.
- Updated quick-view preview and performance notes.

## 1.1.8

- The dropdown gets the same header as the other plugins: the chip mark, the name, a small-caps status line (culprit under load, uptime when calm, sampler state before that), and the Pressure chip on the trailing edge, over a separator. The mark is now one shared component, so the bar and the dropdown can never drift apart.
- Every timeline states its scale on the value row: the reading, then the ceiling the plot is on, so memory reads `49%  7.3G / 14.9G` and the autoscaling strips (network, disk, power) show the ceiling they are currently on. The baseline is always zero.
- Quieter while closed. Lean ticks slim their App rows to the four fields the rolling averages actually read, taking the line the shell parses every second from ~10 KB to ~3 KB; the fd scan (ports, per-App GPU) pauses while nothing renders it; offender sorting skips while no surface reads it; an unchanged Pressure keeps its object identity so a calm tick wakes no bindings in the bar or the closed dropdown; and the bar tooltip is only built while hovered.
- Fix: percent formatting ignored its digits argument, so the bar's optional CPU cell rendered `38.2%` into a slot measured for `38%` and clipped the leading digit.
- Fix: byte figures in the hundreds pad to a stable width, so the net and power line no longer shifts sideways when a rate crosses 100M.
- A teardown without a close (shell reload mid-overlay) can no longer leave the sampler shipping full ticks forever.
- New preview: the quick view, the cluster and the bar, shot on the Sherbet theme.

## 1.1.7

- State moves to `~/.local/state/omatop/` (history ring and pins). Existing files are moved over on first run. The old location was inside Omarchy's own state directory, and every atomic write there tripped the shell bar's wallpaper watcher, which re-sampled the background image with ImageMagick every 10 s. That alone cost about 40% of a core on a 5K display. Omatop was the trigger on this machine; the watcher fix itself is proposed upstream.

## 1.1.6

- Fix: searching, backspacing and searching again no longer leaves old rows drawn over the new ones. A filter, sort or fold change now rebuilds the list from scratch; readings keep the in-place update.

## 1.1.5

- Fix: focusing an App no longer pushes the ledger over the footer. The machine timelines go compact while an App is focused, the App's pane takes the room that frees and fits its strips and facts to it (facts fold to one line when the pane is short), and the ledger clips as a backstop.

## 1.1.4

- The cluster follows the active theme: background, foreground, accent and urgent all come from it, so a light theme gets a light cluster instead of a black slab. Dial scales and ticks, meter tracks, the search box and the key caps take the theme ink at low alpha too. The scrim keeps a hint of the desktop behind it.
- Thanks to @SeanGSR for the theme work in #4, their first contribution to Omatop. Welcome aboard!

## 1.1.3

- First-run setup card in the quick view and the cluster: Build now, Learn more (what the sampler is, what it reads, why it exists, what it costs), building and failed states with the log tail.

## 1.1.2

- One block per CPU core under the cpu timeline, in the ledger and the quick view, on the calm / load / heavy / critical ramp.

## 1.1.1

- Overlay readings every 5 s (`overlaySeconds`, 1 to 10) while the timelines keep the 1 s beat; dials, meters and readouts glide to each reading on one shared clock.
- Timelines carry their scale beside the name and gridlines at zero, half and full; full width, name left, value right.
- Roomier quick view. Motion ceiling default 30 fps.
- README: settings from the terminal, full key reference.

## 1.1.0

- Fluid overlay motion on one machine-tuned clock; value arcs as a fragment shader.
