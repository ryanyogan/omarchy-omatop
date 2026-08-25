# Runtime cost

Measured 2026-08-23 on the machine Omatop is developed on. Every number here
came from `/proc` on a live session, not from an estimate.

## Method

Three processes matter: the Omarchy shell (`quickshell -n -p
/usr/share/omarchy/shell`), the sampler
(`~/.config/omarchy/plugins/ryanyogan.omatop/sampler/target/release/omatop-sampler`),
and the compositor (`Hyprland`).

Per state, one 60 s window sampled once per second:

- **CPU**, percent of one core. Two independent sources agree throughout:
  `utime+stime` from `/proc/<pid>/stat` (whole thread group, 10 ms resolution)
  and the sum of `/proc/<pid>/task/*/schedstat` field 1 (nanosecond
  resolution). `/proc/<pid>/schedstat` alone is the main thread only, so it is
  never used unsummed. Tables quote the `stat` figure.
- **RSS**, `VmRSS` from `/proc/<pid>/status` at the first and last sample.
- **Context switches**, `voluntary_ctxt_switches + nonvoluntary_ctxt_switches`
  delta over the window, as a wakeup proxy.
- **GPU busy**, `/sys/class/drm/card1/device/gpu_busy_percent`, mean and max.
- **Whole machine CPU**, `1 - idle_delta/total_delta` from `/proc/stat`.

Harness: `measure.py`, written for this run. No mouse or keyboard input was
generated during any window. Surfaces were driven entirely over IPC
(`omarchy-shell ryanyogan.omatop toggle`, `omarchy-shell shell summon|hide`)
and each one was confirmed present in `hyprctl layers` at the start, middle
and end of its window.

`docs/perf-review.md` is a separate static audit of the same code, written
independently. Its in-engine JS timings corroborate the finding below that
parsing is not where the shell's time goes: it measures `JSON.parse` of the
tick line at 0.410 ms and a full overlay rebuild at 0.210 to 0.825 ms, against
the 121 to 130 ms per tick measured here. Nothing in this document depends on
it.

### Environment

| | |
|---|---|
| CPU cores | 24 |
| Display | eDP-1, 2880x1920 @ 120 Hz, scale 2 |
| Processes on the machine | 495 to 512 (the sampler's stated design point is 500) |
| `refreshSeconds` | 5 (the shipped default), so the sampler runs at 0.2 Hz and ticks 12 times per 60 s window |
| Apps per tick | 63 |

### Caveats

- `perf` is not installed on this machine, so the requested `perf stat` run was
  skipped. `strace` was not used, as instructed.
- Whole machine CPU is the noisiest column. It includes the measurement harness
  itself and every unrelated process, and it moves by more than the plugin's
  own contribution. The per-process columns are the trustworthy ones.
- Eight orphaned `while :; do :; done` shell loops from an earlier session were
  found pinning 8 of 24 cores (PIDs 94234-94237, 116883-116886, up to 46
  minutes of runtime each). They were killed and the machine was left to settle
  before state A. Every number below is from the quiet machine.
- State E's schedstat figure undercounts, because 8 threads exited during its
  window and took their accumulated nanoseconds with them. Its `stat` figure is
  correct, and state E2 (the same state after the thread count stabilised)
  agrees with it.

## Results

Shell and sampler CPU are percent of **one core**. RSS is MiB, start and end of
window.

| State | Shell CPU | Sampler CPU | Shell RSS | Sampler RSS | Shell threads | Shell ctxsw/s | Sampler ctxsw/s | Machine CPU | GPU mean/max |
|---|---|---|---|---|---|---|---|---|---|
| **A** disabled (baseline) | 0.300% | not running | 494.9 / 495.0 | n/a | 34 | 14.6 | n/a | 1.25% | 6.68 / 8 |
| **B** enabled, closed | 0.383% | 0.183% | 501.8 / 500.0 | 3.42 / 3.46 | 36 | 16.6 | 0.30 | 1.80% | 6.53 / 8 |
| **C** dropdown open | 2.717% | 0.183% | 564.8 / 560.1 | 3.46 / 3.49 | 51 | 106.9 | 0.33 | 2.12% | 8.40 / 14 |
| **D** overlay open | 2.883% | 0.167% | 595.8 / 591.4 | 3.49 / 3.49 | 53 | 92.3 | 0.33 | 2.50% | 10.90 / 24 |
| **E** closed again, right after D | 0.567% | 0.167% | 570.2 / 569.4 | 3.49 / 3.54 | 45 | 20.6 | 0.27 | 2.02% | 6.72 / 8 |
| **E2** closed, settled 4 min later | 0.583% | 0.150% | 569.9 / 568.0 | 3.54 / 3.54 | 45 | 24.0 | 0.28 | 1.79% | 6.83 / 8 |

### What the plugin adds, against state A

| State | Shell CPU | Total plugin CPU (shell + sampler) | Shell RSS | Sampler RSS | Threads | Shell ctxsw/s | GPU mean |
|---|---|---|---|---|---|---|---|
| **B** closed | +0.083 pp | **+0.266 pp** | +6.9 MiB | +3.5 MiB | +2 | +2.0 | -0.15 |
| **C** dropdown | +2.417 pp | **+2.600 pp** | +69.9 MiB | +3.5 MiB | +17 | +92.2 | +1.72 |
| **D** overlay | +2.583 pp | **+2.750 pp** | +100.9 MiB | +3.5 MiB | +19 | +77.7 | +4.22 |
| **E2** closed after use | +0.283 pp | **+0.433 pp** | +75.0 MiB | +3.5 MiB | +11 | +9.4 | +0.15 |

Total cost with nothing open is **0.27% of one core, about 10 MiB**. That is
0.011% of this 24 core machine.

### Cost per tick

At 0.2 Hz there are 12 ticks in each window. Subtracting state A's idle floor
(0.1674 CPU seconds per 60 s) isolates the work each tick causes:

| State | Shell CPU seconds / 60 s | ms per tick | Incremental ms per tick |
|---|---|---|---|
| A (no ticks) | 0.1674 | n/a | n/a |
| B closed | 0.2218 | 18.5 | **4.5** |
| C dropdown | 1.6245 | 135.4 | **121.4** |
| D overlay | 1.7233 | 143.6 | **129.7** |
| E2 closed after use | 0.3500 | 29.2 | **15.2** |

Parsing the tick, updating the service and repainting the bar glyph costs
4.5 ms. Having the dropdown visible costs a further 117 ms of that same tick,
and the overlay a further 125 ms.

### Sampler, measured standalone

A second sampler instance was run directly, killed afterwards.

| | |
|---|---|
| Default tick rate with no `rate` command | 1.000 Hz (measured gaps 0.995 to 1.003 s over 11 ticks) |
| Line size | 31,733 bytes mean (min 31,720, max 31,751) |
| CPU per tick | 8.34 ms |
| CPU at 1 Hz | 0.835% of one core |
| CPU at the shipped 0.2 Hz | 0.167%, matching the 0.150 to 0.183% measured in-shell |
| Threads | 2 (main plus the stdin reader) |
| RSS | 3.5 MiB, flat across every state |

`docs/sampler-protocol.md` sets the target at "idle CPU cost < 1 % of one core
at 500 pids". At 501 pids and 1 Hz the sampler measures 0.835%. **The target is
met.** At the shipped default it uses one fifth of that.

Payload composition of one 35,745 byte tick:

| Section | Bytes | Share |
|---|---|---|
| `apps` (63 entries) | 27,753 | 77.6% |
| `history` (9 series x 120 floats) | 7,050 | 19.7% |
| `vitals` | 739 | 2.1% |
| `processes` | 2 | 0.0% |

The `fds` scan is not where the sampler's time goes. Measured over 15 ticks,
twice each:

| | ms per tick |
|---|---|
| `fds on` (default) | 7.87, 8.01 |
| `fds off` | 7.48, 6.91 |

Roughly 0.7 to 1.1 ms of the 8 ms, so about 12%. The rest is the `/proc` walk
itself.

### Compositor

Hyprland was measured separately over 40 s windows. It does not move with the
overlay:

| | Hyprland CPU |
|---|---|
| Closed | 2.547% |
| Overlay open | 2.218% |
| Closed again | 2.341% |

The variation is noise, and the overlay covering the screen removes as much
compositing work as it adds. **The plugin's cost is inside the shell process,
not in the compositor.**

## Observations

### 1. The shell's CPU rises 7.1x when a surface is open, and every bit of it is one animation

State C costs 2.717% against 0.383% closed. The per-second series shows the
shape exactly: a burst once every 5 seconds, nothing between.

```
C, shell CPU% per second (first 30 s)
 2.0  0.0  0.0  0.0 10.0  0.0  0.0  2.0  2.0 11.0  0.0  0.0  0.0  0.0 18.0
 1.0  0.0  0.0  0.0 10.0  0.0  0.0  0.0  0.0 14.0  0.0  0.0  0.0  1.0 11.0
```

The burst period is the 5 s tick. Nothing is animating continuously; the whole
cost lands on the tick.

Setting `reducedMotion: true` and repeating both states isolates it:

| State | Default | `reducedMotion: true` | Reduction |
|---|---|---|---|
| C dropdown | 2.717% | **0.383%** | 7.1x |
| D overlay | 2.883% | **0.700%** | 4.1x |
| C shell ctxsw/s | 106.9 | **14.4** | 7.4x |
| D shell ctxsw/s | 92.3 | **22.8** | 4.0x |
| C GPU mean/max | 8.40 / 14 | **6.25 / 7** | back under baseline |
| D GPU mean/max | 10.90 / 24 | **7.05 / 8** | back to baseline |

With motion reduced, the dropdown costs 0.383%, which is exactly the
closed-state cost. **The dropdown's entire measured CPU and GPU cost is the
slide animation.** For the overlay, motion accounts for 76% of it.

The mechanism is in the source:

- `Panel.qml:213-221` runs a 250 ms `NumberAnimation` on every tick.
  `Panel.qml:586` is `onProgressChanged: requestPaint()`, so each of the 4
  `Sparkline` canvases repaints on every frame of it. At 120 Hz that is about
  30 frames, so roughly 120 canvas repaints per tick.
- `ui/Strip.qml:54` does the same, and its duration is
  `Math.max(80, Math.min(1200, root.tickMs))` (`ui/Strip.qml:53`). With
  `refreshSeconds: 5`, `tickMs` is 5000, so it clamps to **1200 ms**. The
  overlay instantiates 10 `Strip`s. At 120 Hz that is about 144 frames per
  tick per strip, so roughly 1,440 canvas repaints per tick.

Each repaint walks a 120 point path twice (fill then stroke) through Qt Quick's
`Canvas`, which rasterises in software and uploads a texture. On a 2880x1920
display at scale 2 those textures are large, which is why the GPU column moves
with the CPU column.

Longer `refreshSeconds` makes this **worse**, not better: the strip animation
duration tracks the tick interval up to its 1200 ms clamp, so a slower refresh
buys a longer animation rather than a cheaper one.

### 2. The cost does not return to the closed level after the overlay closes

This was the specific question for state E, and the answer is no.

| | B (closed, never opened) | E2 (closed, after opening) | Retained |
|---|---|---|---|
| Shell CPU | 0.383% | 0.583% | **+52%** |
| Shell RSS | 500.0 MiB | 568.0 MiB | **+68.0 MiB** |
| Shell threads | 36 | 45 | **+9** |
| Shell ctxsw/s | 16.6 | 24.0 | **+45%** |
| Per-tick incremental | 4.5 ms | 15.2 ms | **+10.7 ms** |

This is retention, not lag. RSS and thread count were polled every 20 s for a
further 2 minutes after state E and stayed flat at 582 to 584 MB and 45
threads. State E2, taken 4 minutes after the overlay closed, is
indistinguishable from state E.

The overlay's `Loader` and its scene graph nodes, render threads and canvas
textures are never released. The plugin declares `"keepLoaded": false`
(`manifest.json:16`), so this appears to be unload that does not actually
happen, or a Loader that is never reset. `Panel.qml` and `Overlay.qml` do
refcount their surfaces on close, so the intent is clearly there.

### 3. The sample rate refcount is dead code

`Panel.qml:11` says the surfaces send "surfaceOpened/surfaceClosed (which drive
the sample rate)". `Service.qml:57` repeats it: "overlay/panel open count
drives the sample rate". Both `Panel.qml:37,41` and `Overlay.qml:94,111` call
them, and `Service.qml:157-158` maintains the counter.

Nothing reads it. `Service.qml:24` is:

```qml
readonly property real rate: 1 / refreshSeconds
```

`openSurfaces` appears in no other expression in the codebase. The measurements
confirm it: the sampler ran at 0.167 to 0.183% in states B, C and D alike, and
the tick bursts stayed 5 s apart with the overlay open.

The user-visible consequence is that the overlay, the thing you open to watch
the machine, shows data up to 5 seconds stale and its graphs advance once every
5 seconds.

### 4. GPU is affected, but only through the shell

GPU busy sits at 6.5 to 6.8% mean, 8% max at rest, with or without the plugin
(state A 6.68, state B 6.53). It rises to 8.40 mean / 14 max with the dropdown
open, and 10.90 mean / 24 max with the overlay open. Under `reducedMotion` it
returns to 6.25 and 7.05. Hyprland's CPU does not move at all. The GPU load is
the shell uploading canvas textures.

### 5. The sampler is not the problem

The sampler holds 3.5 MiB and 0.15 to 0.18% of one core in every state,
including with the overlay open. It is 2 threads and wakes about 12 times a
minute (16 to 20 context switches per 60 s window). At 1 Hz it would be 0.835%,
inside its own stated 1% target. It is roughly one thirtieth of the shell-side
cost when a surface is open.

### 6. Documentation drift

`docs/sampler-protocol.md` says the `rate` command accepts `0.25..10` and
defaults to 1. The implementation uses `MIN_RATE: f64 = 0.03`
(`sampler/src/main.rs:27`). This matters, because the shipped
`refreshSeconds: 5` sends `rate 0.2`, which is below the documented floor and
would be clamped to 4 s per tick if the docs were accurate. The code accepts
it, so the observed cadence is 5 s. The docs are wrong, not the code.

## Optimisation suggestions, ranked

### 1. Stop repainting canvases on every animation frame

**Cost recovered: 2.33 pp of one core with the dropdown open (7.1x), 2.18 pp
with the overlay open (4.1x), plus the entire GPU rise and 92 wakeups per
second.**

Evidence: setting `reducedMotion: true` drops state C from 2.717% to 0.383%,
which is the closed-state cost, and returns GPU to baseline. The per-second
series shows the cost arriving in one burst per tick, and the burst length
matches the animation duration.

The slide is 20 lines of code buying an effect nobody asked for at 6x the
plugin's entire running cost. Options, cheapest first:

- Drop the slide. Repaint once per tick. This alone recovers everything above.
- Keep the slide but stop rasterising it. The animation translates the path by
  `offset` (`Panel.qml:606`); that is a transform, not new geometry. Draw the
  canvas once per tick and animate the `Item`'s `x` instead, so the scene graph
  moves an existing texture rather than the CPU redrawing one 120 times.
- If the slide must stay on the canvas, cap its cost. `ui/Strip.qml:53` clamps
  the duration to 1200 ms, which is the worst case, not a safe one. A 150 ms
  ceiling would cut Strip repaints per tick by 8x.

### 2. Release the overlay when it closes

**Cost recovered: 68 MiB of RSS, 9 threads, and 0.20 pp of one core, held for
as long as the shell runs after the overlay has been opened once.**

Evidence: B against E2 in the table above, with RSS and thread count confirmed
flat for a further 2 minutes of polling.

The manifest already declares `"keepLoaded": false`. Confirm the overlay's
`Loader` is actually reset on close, that canvas items release their textures,
and that the extra render threads are joined. A user who opens the overlay once
in a session pays 68 MiB for the rest of that session.

### 3. Wire up the sample rate refcount that already exists

**Cost recovered: none directly. This is the fix that makes the tool honest.**

Evidence: `openSurfaces` is written in four places and read in none; the
sampler's rate was identical in states B, C and D.

`Service.qml:24` should read the counter that `Service.qml:157-158` maintains,
for example a 1 Hz floor while any surface is open and `1/refreshSeconds`
otherwise. Do this **after** suggestion 1, not before. At today's per-tick
render cost, raising the dropdown from 0.2 Hz to 1 Hz would take it from 2.717%
to roughly 13%, because the cost is per tick. With suggestion 1 in place the
per-tick cost is about 5 ms, so 1 Hz costs about 0.5% of one core, which is
affordable. The ordering matters.

### 4. Stop resending the full history ring on every tick

**Cost recovered: about 7 kB per tick of serialisation, transfer and
`JSON.parse`, roughly 20% of the payload.**

Evidence: the `history` block is 7,050 of 35,745 bytes, 9 series of 120 floats.
Each tick appends exactly one sample to each series and resends the other 119.
That is 1,080 floats to deliver 9 values.

Send the full ring once on connect, then a delta per tick. This is a protocol
change, so it is worth less than suggestions 1 and 2 and costs more to make.
The 4.5 ms per-tick closed-state cost is already small; this is a
polish item, not a fix.

### 5. Do not bother turning off the fd scan

**Evidence that this is not worth doing**, recorded so nobody spends a day on
it: `fds off` moves the sampler from 7.87 and 8.01 ms per tick to 7.48 and
6.91 ms. That is about 12% of 8 ms, on a process using 0.17% of one core.
Turning it off saves roughly 0.02 pp and costs the Ports feature and per-App
GPU. The sampler's time is in the `/proc` walk, and the sampler is not the
bottleneck.

## Summary

> Superseded. These are the numbers as of commit `65cf1a7`, kept as the
> baseline the fixes are measured against. For the current state of the plugin
> see the **After** section below.

With nothing open, Omatop costs **0.27% of one core and about 10 MiB**, and the
sampler meets its stated design target with room to spare. Opening either
surface multiplies the shell's CPU by 7, and one animation accounts for all of
it in the dropdown and three quarters of it in the overlay. Closing the overlay
does not give the memory or the threads back.

Two changes, both local, take the open cost from 2.9% to about 0.4% and stop
the 68 MiB leak.

---

# After

Re-measured 2026-08-23 against commit `25e3e9a` ("Perf: lean ticks while
closed, immediate tick on open, no per-frame sparkline repaints, O(n) rebuild,
static Repeater models"). The shell and sampler were restarted first so both
the new QML and the rebuilt binary were live.

Same method as above, same harness, same machine, 45 s windows (9 ticks each at
the unchanged 0.2 Hz). State A was not repeated; the "before" column is the
60 s measurement from the first half of this document. Machine load was
comparable (501 to 512 processes, load average under 1.6 at the start of each
window).

## Results

Shell and sampler CPU are percent of one core. RSS is MiB at the end of the
window. Deltas are after minus before.

| State | Shell CPU | Sampler CPU | Shell RSS | Shell threads | Shell ctxsw/s | Machine CPU | GPU mean/max |
|---|---|---|---|---|---|---|---|
| **B** enabled, closed | 0.383 → **0.355** (-0.028) | 0.183 → **0.178** (-0.005) | 500.0 → **500.1** (+0.1) | 36 → **36** (0) | 16.6 → **17.0** (+0.4) | 1.80 → **1.67** | 6.53/8 → **7.07/8** |
| **C** dropdown open | 2.717 → **0.311** (**-2.405**) | 0.183 → **0.133** (-0.050) | 560.1 → **533.0** (-27.1) | 51 → **50** (-1) | 106.8 → **7.8** (**-99.0**) | 2.12 → **1.42** | 8.40/14 → **6.58/8** |
| **D** overlay open | 2.883 → **2.067** (-0.816) | 0.167 → **0.155** (-0.012) | 591.4 → **561.8** (-29.6) | 53 → **51** (-2) | 92.3 → **63.5** (-28.8) | 2.50 → **1.64** | 10.90/24 → **9.69/15** |
| **E** closed after both, settled | 0.583 → **0.511** (-0.072) | 0.150 → **0.155** (+0.005) | 568.0 → **539.4** (-28.6) | 45 → **42** (-3) | 24.0 → **20.5** (-3.5) | 1.79 → **1.86** | 6.83/8 → **6.82/8** |

Cost per tick, shell CPU seconds per window divided by ticks in that window
(12 before, 9 after):

| State | ms per tick before | ms per tick after | Change |
|---|---|---|---|
| B closed | 18.5 | **17.9** | -3% |
| C dropdown | 135.4 | **15.2** | **-89%** |
| D overlay | 143.6 | **102.6** | -29% |
| E closed after use | 29.2 | **24.4** | -16% |

## What changed and what did not

### The dropdown is fixed

State C fell from 2.717% to **0.311%**, an 8.7x reduction, and its context
switches fell from 106.8/s to **7.8/s**, a 13.7x reduction. GPU returned to
baseline (6.58 mean, 8 max, against 6.53/8 in the closed state).

The per-second series is the clearest evidence. Before, the burst per tick was
unmistakable; after, it is gone entirely:

```
C before, shell CPU% per second
  2.0  0.0  0.0  0.0 10.0  0.0  0.0  2.0  2.0 11.0  0.0  0.0  0.0  0.0 18.0

C after
  0.0  0.0  0.0  2.0  0.0  1.0  0.0  0.0  0.0  0.0  0.0  0.0  0.0  0.0  2.0
```

State C is now cheaper than state B (0.311% against 0.355%), which is within
noise of the two being equal. **Having the dropdown open is now free.**

`ui/Strip.qml` no longer has a `phase` property, a slide `NumberAnimation` or
an `onPhaseChanged` handler. It repaints on `onSamplesChanged` only, once per
tick, which is suggestion 1 from the "before" section carried out.

### The overlay is only 1.4x better, and for the same reason as before

State D fell from 2.883% to 2.067%, a 29% reduction. It still costs **5.8x the
closed state** and still shows the burst-per-tick shape:

```
D after, shell CPU% per second
  0.0  0.0  0.0  1.0  8.0  0.0  0.0  0.0  0.0 13.0  0.0  0.0  0.0  1.0  9.0
```

Repeating the `reducedMotion` isolation from the "before" section locates the
remainder:

| | Default | `reducedMotion: true` | Animation share |
|---|---|---|---|
| D after fixes | 2.067% | **0.689%** | **67%** |
| D before fixes | 2.883% | 0.700% | 76% |

The `reducedMotion` figure barely moved (0.700% to 0.689%), which confirms the
once-per-tick work was already cheap and that the fixes acted on the animation
path. Two thirds of the overlay's cost is still per-frame animation. It has
moved from the sparkline to the dial.

`ui/Dial.qml:47-50` is a 400 ms `Behavior on shown`, and `onValueChanged`
(line 53) retriggers it on every tick. `shown` drives `fraction` (line 38),
which drives the `sweepAngle` of two `PathAngleArc`s inside a `Shape` using
`Shape.CurveRenderer` (lines 87 and 95). The overlay instantiates 4 Dials, so
at 120 Hz that is roughly 48 frames x 4 dials x 2 arcs, about 384 arc
re-tessellations per tick, all on the CPU. `ui/Dial.qml:142` compounds it: the
readout text is bound to `dial.reading`, so `toFixed`/`Math.round`, text
relayout and glyph rasterisation also run on every frame of the glide rather
than once per tick.

This is the same defect class as the sparkline slide, in a different primitive.
`Canvas` was fixed; `Shape` was not.

### Retention after use is reduced but not gone

The overlay's layer surface **does** go away now. `hyprctl layers` showed
`omatop-overlay` present throughout state D and absent immediately after
`omarchy-shell shell hide`, and it stayed absent across 13 polls over the
following 2 minutes.

RSS and threads still do not come back. Polled every 10 s for 2 minutes after
the close, RSS settled at 539.3 MiB and the thread count sat at 42 for every
one of the 13 samples. Nothing was still trending down.

| Held after opening both surfaces, against the same run's closed state | Before | After | Improvement |
|---|---|---|---|
| Shell RSS | +68.0 MiB | **+39.3 MiB** | 42% less |
| Shell threads | +9 | **+6** | 33% less |
| Shell CPU | +0.200 pp (+52%) | **+0.156 pp (+44%)** | 22% less |
| Per-tick cost | +10.7 ms | **+6.5 ms** | 39% less |

**RSS does still grow: by 39.3 MiB, permanently, the first time the overlay is
opened.** That is the answer to the explicit question. `keepLoaded: false` now
releases the layer surface, but 6 threads and roughly 39 MiB of heap and
graphics resources survive the unload.

### The closed state is unchanged

B moved from 0.383% to 0.355% and E from 0.583% to 0.511%, both within the
run-to-run noise of this machine. The lean tick did not reduce measured cost,
which is expected: at 4.5 ms per tick the closed-state shell work was already
near zero, and the sampler still walks all of `/proc` on every tick and only
trims what it serialises (`sampler/src/main.rs:453,467` select the output,
they do not skip the scan). The sampler held 0.133 to 0.178% and 3.5 MiB in
every state, as before.

The lean tick is still worth having. It removes about 31 kB per tick of
serialisation, IPC and `JSON.parse` that bought nothing while no surface was
open, and it makes `openSurfaces` a live input (`Service.qml:164-165`) instead
of the dead counter documented in observation 3 above. It simply was not on the
critical path.

## Remaining work, ranked

1. **Stop the dial glide from re-tessellating arcs per frame.** Worth
   **1.38 pp of one core**, 67% of the overlay's cost, measured by the
   `reducedMotion` comparison. Either drop the glide, or animate a cheap
   property (rotation or opacity of a pre-built arc) instead of `sweepAngle`,
   which forces `Shape.CurveRenderer` to rebuild geometry. Separately, bind the
   readout `Text` to `value` rather than `reading` so text does not relayout
   48 times per tick.
2. **Find the 39.3 MiB and 6 threads the overlay does not give back.** The
   layer surface is released; the heap and render threads are not.
3. Suggestion 4 from the "before" section (history deltas instead of resending
   the full ring) is now partly moot while closed, since lean ticks omit
   `history` entirely. It still applies while a surface is open.

## Summary

Before the fixes, Omatop cost 0.27% of one core and about 10 MiB with nothing
open, opening either surface multiplied the shell's CPU by 7, and closing the
overlay gave back neither the memory nor the threads.

After the fixes the closed cost is unchanged and still small, and **the
dropdown is now free**: 0.311% against 0.355% closed, an 8.7x reduction with
its wakeups down 13.7x and its GPU load back at baseline. The overlay improved
1.4x but still costs 2.067%, because two thirds of that is the same per-frame
animation defect relocated from `Canvas` to `Shape`. Retention after use is
down from 68.0 MiB to 39.3 MiB and from 9 threads to 6, so the overlay's layer
surface is now released but its heap and render threads are not.

Two items remain, both local: the dial glide, and the overlay's unload.


---

# After, second pass (motion clock)

Re-measured 2026-08-24 on the same machine, but on a different display: the
external DP-1, 5120x2880 @ 60 Hz, scale 2 (the 120 Hz eDP-1 was inactive).
`refreshSeconds` was 1, not the 5 of the first pass. Harness `docs/measure.py`,
40 s windows, presence confirmed in `hyprctl layers`. Baselines in this
section were taken on the same display the same day against `aba9f67`.

## What changed

- The overlay's needles, value arcs and timelines now glide continuously
  between samples, driven by one shared timer (`motionHz`, default 20 fps)
  rather than per-item `Behavior`s. The value arc is a fragment shader
  (`ui/arc.frag`, compiled to `ui/arc.frag.qsb` with
  `qsb --glsl "100 es,120,150"`), so sweeping it is a uniform write, not a
  re-tessellation. Timelines slide by a transform over a path that carries one
  extra sample on the left.
- The search caret blink and the critical-pressure pulse, both
  `loops: Animation.Infinite`, are gone (the caret is a 2 Hz timer). A looping
  QML animation makes Qt's threaded render loop request a frame on every
  vsync whether or not anything visible changed.

## Results, shell CPU as percent of one core

| State | Before (`aba9f67`) | After |
|---|---|---|
| Closed | 0.40% | 0.50% |
| Dropdown open | 0.87% | 0.65% |
| Overlay open | 3.50% | **7.04%** |
| Overlay, typing a search | **11.44%** | **7.87%** |
| Overlay, critical pressure | ≈11% (same mechanism as search) | ≈7% |

RSS with the overlay open: 647 MiB, back to 615 MiB closed. Threads 44 open,
37 closed. Hyprland 3.25% with the overlay open (2.05% closed).

## What a frame costs

Every ablation landed on the same number. With the overlay open at a measured
20.4 fps, shell CPU was 7.0% whether the dials glided and the strips did not
(8.4%, one noisy run), the strips slid and the dials did not (7.06%), the
shader arcs were hidden (6.99%), the needle was frozen (7.46%), hover was
disabled (7.26%), or the App list was cached in a `layer` (6.39%). At 12 fps
it was 5.03%. With no motion at all, 3.13%.

So one frame of this overlay on this display costs about **3.5 ms of CPU**
across the GUI thread (1.2 ms), the scene-graph render thread (1.2 ms) and
Mesa (1.1 ms), regardless of what moved. Continuous motion is priced in
frames per second and nothing else, which is why the rate is a setting
rather than a constant, and why the overlay picks it from the core count
and drops to stepping while the machine is under heavy or critical Pressure.

The earlier standalone bench put the same figure at 1.5 ms; the live overlay
is a heavier scene (40 App rows, 5K) and the bench under-reported it.

## Honest summary

The cluster now moves the way an instrument cluster should, and its worst
states (search, critical) are 30 to 40% cheaper than before. Its common state
costs twice what it did, for the motion. `motionHz: 0` restores the old cost
exactly; reduce motion does the same and more.

## Third pass: two cadences (2026-08-25, commit after 58ad34a)

The overlay now takes a reading every 5 s (`overlaySeconds`) for the dials,
trip computer, pressure line and list, while the timelines keep taking every
1 s sample. The row meters joined the shared motion clock (no Behaviors), the
needle glide runs 3 s of each 5 s interval, and the default motion ceiling
rose to 30 fps on machines with sixteen or more cores.

Same method as above (`utime+stime` from `/proc/<pid>/stat`, one 30 s
window, no input), 2880x1920 @ 120 Hz, 24 cores, 17 recent Apps listed:

| State | Shell CPU |
|---|---|
| Overlay open, 30 fps | 11.27% of one core |
| Closed, right after | 0.77% of one core |

That is within a point of the 3.5 ms x 30 frames = 10.5% the frame model
predicts, so gliding eighty meters on the clock and rebuilding the list every
fifth tick instead of every tick cost nothing measurable either way: the
frame rate is still the whole price. `motionHz: 20` returns to the ~7% of the
second pass.
