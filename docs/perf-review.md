# Omatop performance review

Static audit of the QML and the tick path, plus a few measured numbers. Read only, nothing was changed.

## How the numbers were produced

- One real sampler run: `sampler/target/release/omatop-sampler` for 7 s, 7 tick lines, this machine (24 cores, 63 Apps).
  Line size is **31,966 bytes**, stable to +/- 20 bytes across ticks.
- Byte breakdown of one line: `apps` 25,041, `history` 6,114, `vitals` 635, `pressure` 44, everything else < 30.
- JS timings measured in the same engine the shell uses (`qml6`, Qt 6.11.1, V4), 300 iterations each:

| Operation | ms per call |
|---|---|
| `JSON.parse` of the 31,966 byte line | **0.410** |
| `JSON.parse` of a vitals-only 708 byte line | **0.010** |
| `appsById` rebuild (63 entries) | 0.003 |
| `Model.sections(63 apps)` | 0.115 |
| `Overlay.rebuild()` steady state, default folds, 25 rows | **0.210** |
| `Overlay.rebuild()` all sections unfolded, 68 rows | **0.825** |

- Sampler CPU, `rate 0.2`, measured from `/proc/<pid>/stat` over 20 s (4 ticks):
  `fds on` = 6 jiffies, `fds off` = 3 jiffies. The per-pid fd scan is **half** the sampler's CPU.

Two structural facts that set the baseline:

- The overlay is genuinely free when closed. `manifest.json:18` sets `keepLoaded: false`, and per
  `docs/shell-api-reference.md:634` the shell's Loader is `active: keepLoaded || shell.openPanelIds[id] === true`,
  so `Overlay.qml` is destroyed on hide. Nothing in section 2 below costs anything while the overlay is closed.
- The dropdown is **not** free when closed. `BarWidget.qml:110-119` uses its own `Loader { active: true }`, so the
  whole of `Panel.qml` stays instantiated for the life of the shell.

---

## 1. Every tick parses 32 KB that nobody reads while everything is closed

**Cost: 0.410 ms of GUI-thread JS and about 32 KB of garbage every 5 s, forever. 23 MB/hour of allocation in the
shared shell process. This is the single largest closed-state item.**

Evidence:
- `Service.qml:166` `JSON.parse(line)` on the full 31,966 byte line, unconditionally.
- `Service.qml:170-188` assigns 9 properties and rebuilds `apps` (63 element array) and `appsById` (63 key object).
- `Service.qml:178-184` loops all 63 apps calling `Model.isPinned` (`Model.js:16-21`, O(pins) each) and writing `a.pinned`.
- Nothing consumes any of it while closed: `Panel.qml:89-91` gates `vitals`/`history`/`apps` behind `root.opened`,
  and because `&&` short-circuits on `root.opened` first, `service.vitals` is never *read*, so QML never captures it
  as a binding dependency. Those three bindings are correctly and completely cold. The overlay is destroyed.
- `apps` (25,041 B) and `history` (6,114 B) are 98% of the line and have zero readers in the closed state.

Mechanism: the sampler always sends the full payload. `Service.qml:57` declares `openSurfaces` with the comment
"overlay/panel open count drives the sample rate", and `Service.qml:157-158` maintain it, but **nothing reads it**.
The feature was never wired up.

Fix (sampler + service):

```qml
// Service.qml
onOpenSurfacesChanged: {
  send("apps " + (openSurfaces > 0 ? "on" : "off"))   // new sampler command
  send("fds "  + (openSurfaces > 0 ? "on" : "off"))   // command already exists, main.rs:279
}
```

In the sampler, when `apps` is off, omit `apps`, `history`, `processes` and `detail` from the serialized `Tick`
(`#[serde(skip_serializing_if)]`), keep advancing the history ring internally so the overlay is full on open.
Measured effect: 0.410 ms -> 0.010 ms per tick, 32 KB -> 708 B, and `fds off` halves the sampler's own CPU.

---

## 2. `Overlay.rebuild()` is O(n^2) in rows, once per tick

**Cost: 0.210 ms/tick at the default folds (25 rows), 0.825 ms/tick with sections unfolded (68 rows). Quadratic:
2.7x the rows costs 7x the time. At 200 rows this is roughly 6 ms per tick on the GUI thread, which is most of a
120 Hz frame budget in a process that is also drawing the bar.**

Evidence:
- `Overlay.qml:151` `for (var s = 0; s < rows.count; s++) if (rows.get(s).key === key) { j = s; break }`
  sits inside the loop over `desired` at `Overlay.qml:142`. That is n^2/2 `ListModel.get()` calls plus an
  equal number of `.key` reads, each going through the element's meta-object and allocating a JS string.
- `Overlay.qml:140` adds a full removal scan (n gets), `Overlay.qml:162` adds a full cursor scan (n gets).
- Driven every tick from `Overlay.qml:168-170`.
- `Model.sections` on top of that is 0.115 ms (`Model.js:96-129`): it allocates a 69 element row array of fresh
  objects, 4 bucket arrays, and runs 5 sorts.

Fix: build the index once, outside the loop.

```js
var index = {}                                  // key -> current row position
for (var s = 0; s < rows.count; s++) index[rows.get(s).key] = s
// then inside the desired loop:
var j = index[key] === undefined ? -1 : index[key]
```

Rebuild `index` after any `insert`/`move`/`remove`, or simpler: compute `desired` first, diff the two key arrays
linearly, and only touch `rows` where they differ. Linear diff takes this to roughly 0.13 ms flat.

---

## 3. Four Dials animate for 600 ms of every 5 s tick and re-triangulate CurveRenderer arcs every frame

**Cost: the render loop is held awake for 600 ms out of every 5000 ms (12% duty cycle) with the overlay open.
At 120 Hz that is 72 frames per tick in which 8 `ShapePath` arc geometries are rebuilt and re-uploaded, plus
4 needle rotations. On integrated graphics this is the largest GPU-side item in the open overlay.**

Evidence:
- `ui/Dial.qml:47-50` `Behavior on shown { NumberAnimation { duration: 600 } }`, fed by
  `ui/Dial.qml:53` `onValueChanged: { if (!ignition.running) shown = value }`. `value` changes every tick
  (`Overlay.qml:537,548,560,572`), so `shown` animates for 600 ms every tick.
- `ui/Dial.qml:38` `fraction` re-evaluates on every animation frame, driving
  `ui/Dial.qml:87` and `ui/Dial.qml:95` (`sweepAngle: dial.dialSweep * dial.fraction`) and
  `ui/Dial.qml:120` (needle `rotation`).
- `ui/Dial.qml:71` `preferredRendererType: Shape.CurveRenderer`. A changed `PathAngleArc.sweepAngle` invalidates
  the ShapePath and re-runs curve generation for that path, every frame, for both the arc and the 3x-width
  under-glow at `ui/Dial.qml:82-88`.
- Four dials are instantiated (`Overlay.qml:533-579`), all with `animated: root.animated` (default true).

Not a per-tick cost, correctly: the 46-tick `Repeater` at `ui/Dial.qml:99-115` binds only to constants
(`dialStart`, `tickCount`, `dialSweep`), so the 184 tick Items across 4 dials are laid out once at creation and
never again. Same for the readout `Text` at `ui/Dial.qml:142`: all four call sites pass a non-empty `readout`,
so the text is the once-per-tick preformatted string, not the per-frame `reading`.

Fix: cut the duty cycle. Either drop the duration to match the eye rather than the tick
(`duration: 240`, 4.8% duty cycle), or make the glide conditional on a meaningful delta:

```qml
Behavior on shown {
  enabled: dial.animated && !ignition.running && Math.abs(dial.shown - dial.value) > 1.5
  NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
}
```

---

## 4. Repeaters whose model is a fresh JS array literal destroy and recreate every delegate, every tick

**Cost: with the overlay open, roughly 15 Items (5 Rows x 2 Texts, plus the Row itself) are destroyed and
recreated every tick for the trip computer, and 8 more when the detail pane is open. Item creation is far more
expensive than a binding re-evaluation, and it churns the QML object pool in the shared process.**

Evidence:
- `Overlay.qml:590` `readonly property var v: root.service ? root.service.vitals : null`. `service.vitals` is
  reassigned every tick at `Service.qml:171`, so `trip.v` changes identity every tick.
- `Overlay.qml:592-599` the `Repeater`'s `model` is an array literal built from `trip.v`, so it is a **new array
  object every tick**. `QQmlDelegateModel` cannot diff two unrelated arrays: it resets and recreates all delegates.
- The same literal also does 8 `Model.bytes()` calls and 6 string concatenations per tick
  (`Overlay.qml:594-598`), including `Date.now()` twice at `Overlay.qml:598`.
- Same pattern at `Overlay.qml:777-783`: the detail metadata `Repeater` model is a fresh filtered array literal
  derived from `detailPane.app`, which changes identity every tick (see finding 5), so its 4 rows are recreated
  every tick, concatenating the (up to 200 char) `cmd` string each time.

Fix: make the model a `ListModel` populated once and updated by role, or split the five readouts into five
statically declared `Row`s whose `Text.text` binds directly. A `Text.text` set to an equal string is a no-op in
`QQuickText`, so static declaration makes an unchanged readout cost nothing.

---

## 5. `appsById` is rebuilt every tick, so every live `AppRow` re-evaluates about 20 bindings

**Cost: with the overlay open, roughly 30 rows are live (about 20 visible plus `cacheBuffer: Style.space(400)`
at `Overlay.qml:844`, 30 px rows). 30 x ~20 = about 600 binding evaluations per tick, each running a
`Model.pct`/`Model.bytes` or a comparison.**

Evidence:
- `Service.qml:186` `root.appsById = byId` assigns a brand new object every tick.
- `Overlay.qml:891` `app: root.service ? root.service.appsById[rowLoader.appId] || null : null` therefore
  re-evaluates and yields a **different object** every tick (the values come from `JSON.parse`, so even unchanged
  Apps are new objects).
- `app` changing identity invalidates every binding in `ui/AppRow.qml` that dereferences it:
  `:33` `implicitHeight`, `:37` `paused`, `:38` `stopping`, `:72-73` marker text and colour, `:84` name,
  `:88-90` weight/strikeout/opacity, `:112-113` ports visible+text, `:119-120` tag visible+text,
  `:128-129` recent visible + `Model.age`, `:145` cpu, `:153` mem, `:162` gpu, `:182` the process `Repeater` model.
- `Overlay.qml:896` `processes: root.service.processes[rowLoader.appId] ? ... : []` returns a **fresh empty array
  literal** per row per tick, because `Service.qml:176` assigns a new `{}` to `processes` every tick. That flips
  `ui/AppRow.qml:182`'s `Repeater` model to a new array on every row on every tick.

Directly answering the question asked: **`ListModel.set()` on an unchanged row is not the problem.** Measured on
Qt 6.11.1 with an `Instantiator` counting delegate change signals: 500 `set()` calls with identical values
produced **0** delegate notifications; one real change produced 1. Qt's `ListElement::set*Property` compares before
recording the role as changed, so `Overlay.qml:153-154` is free when the data is unchanged. The delegate churn
comes entirely from the `appsById` lookup at `Overlay.qml:891`.

Fix: stop routing App data through `appsById` in the delegate. `rebuild()` already writes a row entry per App
(`Overlay.qml:145-149`) and we now know identical `set()` costs nothing, so carry the display values as roles:

```js
var entry = {
  key: key, type: r.type, section: r.section, label: r.label || "", count: r.count || 0,
  collapsed: r.collapsed === true, appId: r.type === "app" ? r.app.id : "",
  name: a.name, cpuText: Model.pct(a.cpu), memText: Model.bytes(a.mem),
  gpuText: a.gpu >= 0 ? Model.pct(a.gpu) : "·",
  portsText: Model.ports(a.ports), tag: a.tag || "", state: a.state, pinned: a.pinned === true
}
```

and have `AppRow` read `rowLoader.cpuText` etc. Rows whose numbers did not move then re-evaluate **nothing**.
Also give `Service.qml` a shared empty object so `processes` does not change identity on an idle tick:

```qml
readonly property var _noProcesses: ({})
// in ingest:
root.processes = data.processes || root._noProcesses
```

---

## 6. The bar widget rebuilds its tooltip string on every tick, whether or not anyone is hovering

**Cost: small per tick (a few microseconds and 2 to 4 string allocations), but it runs forever in the
always-loaded widget, which is exactly where the owner wants zero.**

Evidence:
- `BarWidget.qml:47-57` `tooltip` depends on `root.cpuNow` (`:35-36`, reads `service.vitals`, changes every tick)
  and on `service.pressure.reason` (`:55`). It concatenates up to three fragments and calls `Model.pct`.
- `BarWidget.qml:132` `tooltipText: root.tooltip` pushes the new string into the shell's `WidgetButton` every tick.
- `BarWidget.qml:44-45` `percentText` calls `Model.pct` every tick even when `showPercent` is false, in which case
  the containing `Item` has `width: 0` and `visible: false` (`BarWidget.qml:204-208`).

Fix:

```qml
readonly property string percentText:
  root.showPercent && root.samplerReady && root.cpuNow >= 0 ? Model.pct(root.cpuNow, 0) : "--"

// and gate the tooltip on hover, or at minimum on the cheap inputs only:
tooltipText: button.hovered ? root.tooltip : ""
```

The glyph itself is clean: `BarWidget.qml:162-169` repaints only when `tint` actually changes value, and
`Model.pressureColor` returns an identical `color` on an unchanged level, so QML suppresses the notification.

---

## 7. Panel bindings that are not gated on `opened`, and one ungated `requestPaint`

**Cost: 5 binding evaluations and 2 to 3 string allocations per tick in a permanently instantiated dropdown, plus,
whenever the pressure level does change, a 300 ms `ColorAnimation` and a Canvas repaint on an invisible panel.**

Evidence:
- `Panel.qml:92` `culprit: root.service ? String(root.service.culprit || "") : ""` reads `service.culprit`
  unconditionally, so it is captured as a dependency and re-runs every tick.
- `Panel.qml:94-97` `pressureLevel` and `pressureReason` read `service.pressure`, which `Service.qml:173`
  reassigns to a **new object every tick** even when nothing changed. Both re-run every tick while closed.
- `Panel.qml:568-587` the `Sparkline` component gates two of its three repaint triggers on `opened`
  (`:584` samples, `:585` opened) but **not the third**: `:587` `onLineColorChanged: requestPaint()`.
  The CPU row's `lineColor` is `root.pressureColor` (`Panel.qml:374`), and `:579-582` puts a 300 ms
  `ColorAnimation` on it, so a pressure change while the dropdown is closed drives a repaint on every frame of
  that animation on an invisible `Canvas`.
- `Panel.qml:304-343` and `:741-744`: five more `Behavior on color` blocks that will animate while closed.
- `Panel.qml:223-234` `Connections.onTicked` runs every tick regardless of `opened`; it early-returns correctly
  but still touches `slideAnim.stop()` and re-assigns `slideSource.value`.

Fix: apply the same short-circuit pattern already used correctly at `Panel.qml:89-91`.

```qml
readonly property string culprit: root.opened && root.service ? String(root.service.culprit || "") : ""
readonly property string pressureLevel:
  root.opened && root.service && root.service.pressure ? String(root.service.pressure.level || "calm") : "calm"
readonly property string pressureReason:
  root.opened && root.service && root.service.pressure ? String(root.service.pressure.reason || "") : ""
```

and gate the third repaint trigger: `onLineColorChanged: if (root.opened) requestPaint()`.

Complementary fix in the service, which also helps the overlay: stop reassigning unchanged objects.

```js
// Service.qml ingest, replacing line 173
var p = data.pressure || { level: "calm", score: 0, reason: "" }
if (!root.pressure || root.pressure.level !== p.level || root.pressure.reason !== p.reason)
  root.pressure = p
```

---

## 8. The entire dropdown tree is instantiated for the life of the shell

**Cost: about 150 resident QML Items, 4 `Canvas` items with their textures, 4 `TextMetrics`, a `KeyboardPanel` and
a `PanelKeyCatcher`, for a surface that is closed almost all the time. This is memory and startup latency in the
shared process, not per-tick CPU.**

Evidence:
- `BarWidget.qml:110-119` `Loader { id: panelLoader; active: true; source: "Panel.qml" }`. Unlike the shell's own
  panel Loader (`docs/shell-api-reference.md:634`), this one is never deactivated.
- `Panel.qml:240-560` the full content column, including 4 `VitalRow`s each containing a `Sparkline` `Canvas`
  (`Panel.qml:670-679`), the `Pinned` `Repeater` (`:486-493`) and the busiest row.
- `Panel.qml:165-192` four `TextMetrics` objects, each holding a laid-out font run.

`active: true` is required, because the bar reads `panelLoader.item.opened` and calls `open()`/`close()`/
`closeForPopoutSwitch()` synchronously (`BarWidget.qml:84-98`). The fix is to keep the Panel shell and make its
*content* lazy:

```qml
// Panel.qml, wrapping the Column at :267
Loader {
  id: contentLoader
  width: parent.width
  active: root.opened || panel.open      // stays alive through the close animation
  sourceComponent: contentComponent
}
```

---

## 9. The Strip slide animation never plays in steady state, and is pathological during warm-up

**Cost while warm: zero (see below). Cost during the first 120 ticks after a cold start, or any time the history
ring is not yet full: 1200 ms of full-rate `Canvas` repaints per tick across 7 to 10 canvases. At 120 Hz that is
about 144 repaints per canvas per tick, each rebuilding two 120 point paths.**

Evidence:
- `ui/Strip.qml:42-52` the slide only starts when `n > lastCount`. The sampler's ring is capped at 120
  (`sampler/src/history.rs:15` `CAP: usize = 120`) and the measured tick has `n = 120` for all 9 series, so once
  the ring is full `n === lastCount` forever and the code takes the `else` branch, setting `phase = 1`.
  `phase` is already 1, so `onPhaseChanged` (`:54`) never fires. **The intended slide is dead code in normal use.**
- During warm-up the branch is taken and `ui/Strip.qml:53` gives the animation
  `duration: Math.max(80, Math.min(1200, root.tickMs))`. `Overlay.qml:42` computes
  `tickMs: 1000 / service.rate` = 5000 at the default 5 s refresh, so the duration clamps to **1200 ms** and
  `onPhaseChanged: canvas.requestPaint()` fires on every frame of it, for each of the 7 ledger strips
  (`Overlay.qml:677-712`) and up to 3 detail strips (`Overlay.qml:758-772`).

Fix: either delete the slide (it does not run anyway, and `phase` can be a constant 1), or make it honest and
cheap by scaling the duration to the frame budget rather than the tick:

```qml
NumberAnimation { id: slide; target: root; property: "phase"; from: 0; to: 1
                  duration: Math.max(80, Math.min(300, root.tickMs)); easing.type: Easing.Linear }
```

On the render-strategy question: **keep `Canvas.Cooperative`.** `Canvas.Threaded` moves the JS `onPaint` itself
onto the render thread, which requires a second V4 context per Canvas and makes the cross-item reads in
`ui/Strip.qml:117-124` (`root.samples`, `root.scale`, `root.hairline`, `root.fill`) unsafe or copied. In a single
shared shell process that is a worse trade than the rasterization it saves. If these polylines ever do become the
bottleneck, the real answer is `QtQuick.Shapes` `ShapePath` + `PathPolyline`, which keeps the geometry in the
scene graph and re-uploads only on change, not a different Canvas strategy. At the current 1 repaint per strip
per tick, none of this is worth doing.

---

## 10. Two animations that loop forever

**Cost: while either is active the scene graph renders at the display's full rate indefinitely, which on
integrated graphics is the difference between an idle compositor and a busy one.**

Evidence:
- `Overlay.qml:445-450` `SequentialAnimation on opacity { running: ... pressure.level === "critical";
  loops: Animation.Infinite; ... }`. 900 ms in each direction, forever, for as long as the machine is under
  critical pressure. This is arguably intended (a critical indicator should be noticeable), but it means the
  overlay never lets the GPU idle in exactly the situation where the machine is already struggling.
- `Overlay.qml:505` `SequentialAnimation on opacity { running: root.mode === "search" && root.animated;
  loops: Animation.Infinite; ... }`. The search caret blinks at 1 Hz for as long as the user is in search mode,
  which is a full-rate render loop while someone is typing a filter.

Everything else was checked and is bounded: `Overlay.qml:396,411,412` (180 ms open/close), `:735` (200 ms detail
fade), `:849-850` (260 ms list move), `ui/AppRow.qml:34,45,58,91,179`, `ui/Strip.qml:35,100,109`,
`ui/Dial.qml:44,51,62-67`, `ui/HelpCard.qml:20,66`, `BarWidget.qml:164-167,210,220-223`.

Fix: bound the critical blink (`loops: 6` and re-trigger on level change), and stop the caret with
`running: root.mode === "search" && root.animated && keys.activeFocus`, or replace it with a static caret.

---

## 11. The scrub MouseArea repaints every strip on every distinct pixel bucket

**Cost: 7 to 10 full `Canvas` repaints plus 7 to 10 `shownValue` re-evaluations per scrub step, up to 120 steps
across one sweep of the ledger.**

Evidence:
- `Overlay.qml:658-668` a `hoverEnabled` `MouseArea` over the whole ledger. `onPositionChanged` runs its arithmetic
  on **every** motion event (up to 1000/s on a high polling-rate mouse).
- `root.scrub` is an `int`, so assigning an equal value is suppressed by QML, which throttles the downstream work
  to the 120 distinct buckets. But each real change hits `ui/Strip.qml:55` `onScrubChanged: canvas.requestPaint()`
  on every strip, plus `ui/Strip.qml:66-74` `shownValue` and `ui/Strip.qml:96` colour on every strip.

Fix: compute the bucket and bail before assigning, so the handler itself is a comparison in the common case.

```qml
onPositionChanged: function(mouse) {
  var left = Style.space(44), right = width - Style.space(64) - Style.space(8)
  var next = (mouse.x < left || mouse.x > right) ? -1
           : Math.round((mouse.x - left) / (right - left) * 119)
  if (next !== root.scrub) root.scrub = next
}
```

---

## 12. About 5.9 KB of every 32 KB line (18%) is never read by any QML

Measured from the real tick.

| Field | Bytes/line | Readers |
|---|---:|---|
| `apps[].pids` | 1,551 | none |
| `apps[].userUnit` | 1,039 | none |
| `apps[].leader` | 873 | none |
| `apps[].icon` | 697 | none |
| `history.netTx` | 893 | none (the net Strip draws `netRx` only, `Overlay.qml:699`) |
| `history.diskRead` | 592 | none (the disk Strip draws `diskWrite` only, `Overlay.qml:704`) |
| `vitals.cpu.cores` (24 entries) | ~100 | none |
| `vitals.psi` | 57 | none (pressure is already reduced by the sampler) |
| `vitals.gpu.vramUsed`/`vramTotal` | ~40 | none |
| `vitals.cpu.freq`, `mem.avail`, `mem.swapTotal`, `mem.swapUsed` | ~55 | none |
| **Total** | **~5,900** | |

Verified by grepping every `.qml` and `.js` in the plugin for each identifier: zero hits for `pids`, `leader`,
`userUnit`, `icon`, `cores`, `psi`, `vramUsed`, `vramTotal`, `freq`, `avail`, `swapTotal`, `swapUsed`, `netTx`,
`diskRead`. `apps[].tty` has exactly one reader (`Overlay.qml:780`), `apps[].nproc` two
(`Overlay.qml:754`, `:1018`), `apps[].cmd` three (`Overlay.qml:782` detail row, `Model.js:133` search, and the
per-process `cmd` in `ui/AppRow.qml:203`, which is a different field).

Fix: drop `pids`, `leader`, `userUnit`, `icon`, `cores`, `psi`, the vram pair and the freq/avail/swap group from
the wire format (`#[serde(skip_serializing)]`), or gate them behind a `verbose on` command for debugging. Keep
`netTx` and `diskRead` only if a future strip will draw them; otherwise drop them too. `cmd` is needed for search,
but 3,205 bytes/line for a 200 char field on 63 Apps is worth truncating to 120 chars.

---

## 13. Smaller items, in order

- **`fds` is never sent.** `sampler/src/main.rs:279` implements `fds <on|off>` and the protocol documents it
  (`docs/sampler-protocol.md`), but `Service.qml` has no caller. Measured: leaving it on doubles the sampler's
  CPU (6 vs 3 jiffies per 20 s). Turn it off whenever `openSurfaces === 0`, since Ports and per-App GPU are only
  ever displayed in the overlay and the dropdown's pinned rows.
- **`detail` can leak.** `Overlay.qml:112` clears it in `close()`, but with `keepLoaded: false` the shell can
  destroy the Loader; if `close()` did not run, the sampler keeps computing per-App history forever. Add
  `Component.onDestruction: { if (service) { service.surfaceClosed(); service.requestDetail("") } }` guarded by
  `opened`, which also stops `openSurfaces` from drifting upward across summons.
- **`Overlay.qml:39` `nowMs: service.lastTickMs`** changes every tick and is pushed to every live `AppRow`
  (`:897`), re-running `Model.age` (`Model.js:69-77`) for each row flagged `recent` (`ui/AppRow.qml:128-129`).
  Cheap, but it is pure churn for a value that only needs 1 s granularity.
- **`Util.cloneJson` is not a per-tick cost.** It is `JSON.parse(JSON.stringify(...))`
  (`/usr/share/omarchy/shell/Commons/Util.qml:73-75`), and both call sites, `Overlay.qml:243` (`toggleFold`) and
  `Overlay.qml:263` (`toggleExpand`), are keystroke-driven on objects with fewer than 10 keys. No change needed.
- **`Overlay.qml:50` `showGpu`** reads `service.vitals` every tick to produce a bool that changes at most once per
  boot. It gates `visible` and widths on the gpu column across the whole list. Cache it on first non-null tick.
- **Doc drift, no perf impact.** `docs/sampler-protocol.md` says the history ring "advances once per second" at a
  "1 Hz base rate"; `sampler/src/main.rs:398-400` advances it once per tick, and `Overlay.qml:717-718` correctly
  derives the axis from `tickMs` (so the axis reads 10m at the 5 s default). The code is right and the doc is
  stale. `Panel.qml:6-7` and `:565-566` still describe "two minutes of history", which at 5 s ticks is 10 minutes.

---

## Confirmed clean

Audited and found to cost nothing, listed so they are not re-investigated:

- `Panel.qml:89-91`. The `root.opened &&` short-circuit means `service.vitals`/`history`/`apps` are never read
  while closed, so QML does not capture them as dependencies. These three bindings are genuinely cold.
- `ListModel.set()` with unchanged values (`Overlay.qml:153-154`). Measured 0 delegate notifications for 500
  identical sets on Qt 6.11.1.
- The 46-tick `Repeater` in each Dial (`ui/Dial.qml:99-115`). Binds only to constants; laid out once.
- The Dial readout `Text` (`ui/Dial.qml:142`). All four call sites pass a preformatted `readout`, so it updates
  once per tick, not per animation frame.
- `BarWidget.qml:140-145` `TextMetrics`. Text is the constant `"100%"`.
- `BarWidget.qml:155-198` the glyph `Canvas`. Repaints only on a real colour change; the bar heights are constants.
- The overlay while closed. `keepLoaded: false` plus `docs/shell-api-reference.md:634` means it is destroyed.

---

## Do these five first

1. **Stop sending `apps`, `history` and `processes` when `openSurfaces === 0`, and send `fds off` with it.**
   `Service.qml:57,157-158,163-198` plus a new sampler command. Takes the closed-state tick from 0.410 ms and
   32 KB to 0.010 ms and 708 B, and halves the sampler's own CPU. This is the whole "zero cost while closed" goal
   in one change.
2. **Replace the O(n^2) key scan in `Overlay.rebuild()` with a key-to-index map.** `Overlay.qml:151` (and the
   scans at `:140`, `:162`). 0.825 ms to about 0.13 ms at 68 rows, and removes the quadratic blowup on
   process-heavy machines.
3. **Carry the App display values as ListModel roles and drop `appsById[appId]` from the delegate.**
   `Overlay.qml:145-149,891,896` and `ui/AppRow.qml`. Unchanged rows then re-evaluate nothing, because identical
   `set()` is already proven free. Add the shared `_noProcesses` object in `Service.qml:176` at the same time.
4. **Cut the Dial glide from 600 ms to 240 ms and gate it on a meaningful delta.** `ui/Dial.qml:47-50`. Drops the
   overlay's render-loop duty cycle from 12% to under 5% and cuts CurveRenderer geometry rebuilds proportionally.
5. **Gate the three ungated Panel bindings and the third `requestPaint` on `opened`, and stop reassigning an
   unchanged `pressure` object.** `Panel.qml:92,94-97,587` and `Service.qml:173`. Small in absolute terms, but it
   is the only remaining per-tick work in the permanently-loaded dropdown, and the `pressure` fix removes the
   notification that drives it and several overlay bindings.
