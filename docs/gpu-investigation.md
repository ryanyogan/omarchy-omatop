# GPU investigation — v1.2.1, 2026-09-13

The largest source of GPU activity in this session is Hyprland compositing the
visible Foot terminal running an active Codex session. Omatop's dot fades add
an independent rendering cost. Hiding the terminal while leaving Chromium
visible almost eliminates the desktop baseline.

## Method and evidence

AMD GPU, Apple Studio Display at 5120×2880, 60 Hz, scale 2. Measured using
`docs/measure.py`, `/sys/class/drm/card1/device/gpu_busy_percent`, and deltas of
`drm-engine-gfx` from `/proc/*/fdinfo/*`. DRM client IDs were deduplicated per
PCI device as specified by the [kernel DRM usage documentation](https://origin.kernel.org/doc/html/latest/gpu/drm-usage-stats.html).
Engine counters measure busy time, not a fraction of peak compute throughput.
Their collection windows differ from the system busy samples below.

Initial 10-second engine-counter checks attributed 33.08% graphics-engine busy
time to Hyprland and 0.72% to Quickshell with the dropdown open. With it closed,
Hyprland remained at 27.39%; other readable clients did not exceed 0.01%.

| Visible state | Window | GPU busy mean | Shell CPU, one core |
| --- | ---: | ---: | ---: |
| Normal tiled workspace, original dot fades open | 20 s | 28.95% | 5.00% |
| Normal tiled workspace, Omatop closed | 20 s | 24.57% | 0.95% |
| Empty workspace, Omatop closed | 12 s | 1.23% | 0.75% |
| Empty workspace, original dot fades open | 12 s | 11.62% | 6.41% |
| Chromium maximized, terminal obscured, Omatop closed | 12 s | 2.23% | 0.83% |
| Foot/Codex maximized, Omatop closed | 12 s | 32.31% | 0.83% |
| Tiled workspace, temporary opaque Foot rule, Omatop closed | 12 s | 25.62% | 0.92% |
| Empty workspace, shared-clock dot fades | 12 s | 6.92% | 5.00% |
| Empty workspace, final shared-clock version | 12 s | 7.00% | 4.83% |
| Empty workspace, final version closed | 12 s | 1.08% | 0.92% |

These are short live comparisons, not isolated laboratory benchmarks. The
terminal was displaying an active agent session throughout, and maximizing a
window changes its rendered area. They establish a visible-terminal effect,
not a universal claim that Foot or Codex always uses this much GPU.

Blur is disabled. Hyprland's variable-frame-rate rendering is enabled and
its damage tracking is at the default of 2. Foot's `damage-whole-window` is
not overridden and defaults to `no` in the installed manual. A temporary
opaque-window rule did not improve GPU busy and was removed. The original
workspace, tiling and configuration were restored.

## Omatop change

Replaced per-cell `ColorAnimation` objects with a single 25 Hz clock in the
panel. It runs only for a 180 ms fade, skips unchanged quantized levels,
and stops on close. Unchanged cells do not depend on the frame clock. The
half-second sampling cadence and fade effect remain.

Compared with the original fades on the empty workspace, the final version
reduced mean device GPU busy by about 40% (11.62 → 7.00) and shell CPU by about
25% (6.41 → 4.83). The remaining cost includes compositing the shell's full-screen
keyboard-panel surface. A longer-term shell-level optimization is a tightly
sized popup surface with separate outside-click handling; it would require
careful keyboard, positioning and multi-monitor validation.

`tests/check-dot-matrix.sh` runs the actual QML component and checks fade
midpoints, completion, unchanged samples, reduced motion, and hidden state.
Performance itself has no deterministic unit-test seam: repeat the controlled
workspace measurement to assess compositor cost on this hardware.

## Remaining terminal optimization

For a future Codex launch, try:

```sh
codex -c tui.animations=false
```

[Official OpenAI configuration documentation](https://learn.chatgpt.com/docs/config-file/config-reference)
defines this switch for the welcome, shimmer and spinner animations. It is a
reasonable next experiment to reduce decorative redraws. It was not applied
to this running session or benchmarked here. Output streaming will still
require redraws. Keeping a long-running active terminal on another workspace
also reduced GPU usage substantially in the measurements above.
