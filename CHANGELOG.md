# Changelog

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
