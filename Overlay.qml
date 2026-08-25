import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "ui"

// Omatop overlay: the full-screen diagnostic surface.
// Left pane is the ledger (every Vital on one shared two-minute axis); right
// pane is the list (Recent, Pinned, then Buckets). Focusing an App slides its
// own strips into the ledger on the same axis. Keys are fixed and vim-shaped.
Item {
  id: root
  visible: false

  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false

  // ---- Interaction state ---------------------------------------------------
  property string mode: "normal"        // normal | search | confirm | help
  property string filter: ""
  property string sortKey: "name"
  property var collapsed: ({ system: true, desktop: true, kernel: true })
  property var scales: ({})
  property var expanded: ({})
  property int cursorIndex: 0
  property string cursorKey: ""
  property string detailId: ""
  property int scrub: -1
  property string pending: ""           // chord prefix: g z s
  property string countBuffer: ""
  property var confirmApp: null
  property string toast: ""

  readonly property bool live: service && service.samplerState === "running"
  readonly property bool animated: !(service && service.reducedMotion)

  // ---------------------------------------------------------------- cadence
  // Two cadences. Samples arrive every `tickMs` (the sampler rate, 1 Hz by
  // default) and feed the ledger: the timelines take every one and slide.
  // A reading is taken every `readingTicks` samples (`overlaySeconds`, 5 s by
  // default) and feeds everything else: the dials, the trip computer, the
  // pressure line, the list and its meters, the focused App's facts. Between
  // readings those glide toward the new figures; nothing in them jumps once
  // a second. `reading` is a frozen snapshot of the service at that moment,
  // so every readout on the surface describes the same instant.
  readonly property real tickMs: service ? 1000 / service.rate : 1000
  readonly property real readingMs: service ? service.overlaySeconds * 1000 : 5000
  readonly property int readingTicks: Math.max(1, Math.round(readingMs / tickMs))
  property int ticksSinceReading: 0
  property bool readingDue: true
  property var reading: null
  readonly property double nowMs: reading ? reading.t : 0
  readonly property var vitals: reading ? reading.vitals : null
  readonly property var pressure: reading && reading.pressure ? reading.pressure : ({ level: "calm", score: 0, reason: "" })
  readonly property string culprit: reading ? reading.culprit : ""

  function takeReading() {
    if (!service) return
    reading = {
      t: service.lastTickMs,
      vitals: service.vitals,
      pressure: service.pressure,
      culprit: service.culprit,
      apps: service.apps,
      appsById: service.appsById,
      offenders: service.offenders,
      processes: service.processes
    }
    ticksSinceReading = 0
    readingDue = false
    rebuild()
  }

  // Motion rate, tuned to the machine. The setting is a ceiling; the tier
  // comes from core count, and under real Pressure the overlay steps once
  // per reading instead: the frames are CPU time, and that is the moment the
  // machine has none to spare. Rises again when things calm down.
  readonly property int motionCeiling: service ? service.motionHz : 30
  readonly property int cores: vitals && vitals.cpu && vitals.cpu.cores ? vitals.cpu.cores.length : 0
  readonly property int machineTier: cores === 0 ? motionCeiling : cores >= 16 ? 30 : cores >= 8 ? 20 : cores >= 4 ? 12 : 0
  readonly property bool underPressure: pressure.level === "heavy" || pressure.level === "critical"
  readonly property int motionHz: underPressure ? 0 : Math.min(motionCeiling, machineTier)
  readonly property string cadenceNote: "readings every " + Model.span(readingMs)
  readonly property string motionNote: !animated ? cadenceNote
    : motionCeiling === 0 ? cadenceNote
    : underPressure ? cadenceNote + " · motion paused, machine under pressure"
    : motionHz < motionCeiling ? cadenceNote + " · motion " + motionHz + " fps, tuned for this machine"
    : cadenceNote + " · motion " + motionHz + " fps"
  onMotionHzChanged: if (motionHz <= 0) settle()
  readonly property bool motionOn: opened && animated && motionHz > 0
  // Digits do not glide (a number that spins is not a reading), so they fade
  // in over the first part of the glide instead of cutting. Rides the clock.
  readonly property real readoutFade: !motionOn ? 1 : 0.45 + 0.55 * eased(Math.min(1, glidePhase * 2.5))
  function eased(p) { return 0.5 - 0.5 * Math.cos(Math.PI * Math.max(0, Math.min(1, p))) }

  // ---------------------------------------------------------------- motion
  // One clock moves everything; it runs two phases. `phase` runs 0 -> 1
  // across each sample interval and slides the timelines. `glidePhase` runs
  // 0 -> 1 over `glideMs` after each reading and carries the needles, the
  // value arcs and the row meters to the new figures. Every frame the window
  // produces costs the same fixed amount whatever moves in it, so the clock
  // rate (`motionHz`) is the whole cost of motion, and adding the meters to
  // the same clock cost nothing.
  property real phase: 1
  property real glidePhase: 1
  property real readingProgress: 1     // 0 at a reading, 1 when the next is due
  property double phaseStartMs: 0
  property real phaseDurationMs: 1000
  property double glideStartMs: 0
  property real glideDurationMs: 1000
  property double readingTakenMs: 0
  property double lastBeatMs: 0
  // Needles take about three fifths of the interval to arrive, then rest:
  // prompt enough to read as a response, slow enough to read as an instrument.
  readonly property real glideMs: Math.max(400, Math.min(3000, readingMs * 0.6))
  // The timelines scroll at any cadence a slide can still show. Past five
  // seconds the true scroll rate is below a pixel a second, so they step.
  readonly property bool sliding: tickMs <= 5000

  Timer {
    id: motionClock
    interval: Math.max(16, Math.round(1000 / Math.max(1, root.motionHz)))
    repeat: true
    onTriggered: {
      var now = Date.now()
      var p = (now - root.phaseStartMs) / root.phaseDurationMs
      var g = (now - root.glideStartMs) / root.glideDurationMs
      var r = root.readingTakenMs > 0 ? (now - root.readingTakenMs) / root.readingMs : 1
      root.phase = p >= 1 ? 1 : p
      root.glidePhase = g >= 1 ? 1 : g
      root.readingProgress = r >= 1 ? 1 : r
      if (p >= 1 && g >= 1 && r >= 1) stop()
    }
  }
  function runClock() { if (!motionClock.running) motionClock.start() }

  // Slide the timelines by one step across `ms`.
  function slide(ms) {
    if (!motionOn) { phase = 1; return }
    phaseStartMs = Date.now()
    phaseDurationMs = Math.max(50, ms)
    phase = 0
    runClock()
  }
  // Glide the needles and meters to their new figures over `ms`. Must be
  // called before the figures change: a dial that sees a new value while the
  // glide phase reads 1 lands on it at once.
  function glide(ms) {
    if (!motionOn) { glidePhase = 1; return }
    glideStartMs = Date.now()
    glideDurationMs = Math.max(50, ms)
    glidePhase = 0
    runClock()
  }
  function settle() { motionClock.stop(); phase = 1; glidePhase = 1; readingProgress = 1 }

  // A sample landed. Slide across the coming interval, unless this one
  // arrived at an implausible time (the immediate tick on open, a stall)
  // in which case land at once rather than misreport its timing. When the
  // sample is also a reading, start the glide before the figures change.
  function beat(isReading) {
    var now = Date.now()
    var gap = lastBeatMs > 0 ? now - lastBeatMs : 0
    lastBeatMs = now
    if (gap < tickMs * 0.5 || gap > tickMs * 2) phase = 1
    else slide(tickMs)
    if (isReading) {
      readingTakenMs = now
      readingProgress = 0
      glide(glideMs)
    }
  }
  // Focusing an App re-points the dials: a short glide, no sample involved.
  // Keyed on the id, not the App object: every reading rebinds the object,
  // and that must not cut a running glide short.
  onDetailIdChanged: if (opened) glide(240)
  readonly property var cursorApp: {
    if (cursorIndex < 0 || cursorIndex >= rows.count) return null
    var row = rows.get(cursorIndex)
    if (!row || row.type !== "app") return null
    return reading ? reading.appsById[row.appId] || null : null
  }
  readonly property var detailApp: reading && detailId ? (reading.appsById[detailId] || null) : null
  readonly property bool showGpu: !!(vitals && vitals.gpu && vitals.gpu.available === true)

  // ---- Palette -------------------------------------------------------------
  // Keep the cluster in lockstep with the active Omarchy theme.
  readonly property color background: Color.background
  readonly property color ink: Color.foreground
  readonly property color dim: Util.alpha(ink, 0.76)
  readonly property color faint: Util.alpha(ink, 0.54)
  readonly property color hairline: Util.alpha(ink, 0.18)
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color selectedBackground: Util.alpha(accent, 0.18)
  readonly property color pressureColor: Model.pressureColor(pressure.level, accent, urgent)
  readonly property string fontFamily: Style.font.family

  // What the cluster is pointed at: the machine, or the focused App.
  readonly property real memTotal: vitals ? Number(vitals.mem.total) || 0 : 0
  readonly property real clusterCpu: detailApp ? detailApp.cpu : (vitals ? vitals.cpu.total : 0)
  readonly property real clusterMem: detailApp ? (memTotal > 0 ? detailApp.mem / memTotal * 100 : 0) : (vitals && memTotal > 0 ? vitals.mem.used / memTotal * 100 : 0)
  readonly property real clusterGpu: detailApp ? Math.max(0, detailApp.gpu) : (vitals && vitals.gpu ? vitals.gpu.busy : 0)
  readonly property string clusterName: detailApp ? detailApp.name : ""

  // ---- Lifecycle -----------------------------------------------------------
  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (String(screens[i].name || "") === name) return screens[i]
    return null
  }

  function open(payloadJson) {
    if (!service && shell && typeof shell.serviceFor === "function") service = shell.serviceFor("ryanyogan.omatop")
    var screen = focusedScreen()
    if (screen) panel.screen = screen
    if (opened) return
    opened = true
    // A fresh open is a fresh session: no filter, folds, focus or cursor
    // survive from last time, even if this instance somehow did.
    mode = "normal"
    pending = ""
    countBuffer = ""
    scrub = -1
    toast = ""
    filter = ""
    sortKey = "name"
    detailId = ""
    expanded = ({})
    collapsed = ({ system: true, desktop: true, kernel: true })
    cursorIndex = 0
    cursorKey = ""
    rows.clear()
    if (service) {
      service.surfaceOpened()
      if (service.samplerState === "missing") service.startSampler()
    }
    forceReorder = true
    // Read the service as it stands so the surface is never empty, then let
    // the immediate sample the service asks for on open become a reading too.
    takeReading()
    readingDue = true
    if (rows.count > 0 && !cursorApp) moveCursor(1)
    Qt.callLater(function() {
      if (!root.opened) return
      keys.forceActiveFocus()
      list.positionViewAtBeginning()
      cpuDial.ignite(); memDial.ignite(); gpuDial.ignite(); tempDial.ignite()
    })
  }

  function close() {
    if (!opened) return
    opened = false
    settle()
    lastBeatMs = 0
    readingTakenMs = 0
    reading = null
    if (service) {
      service.surfaceClosed()
      service.requestDetail("")
    }
    detailId = ""
    confirmApp = null
    mode = "normal"
    // Every close path must reach the shell, or the loader keeps this
    // instance mounted invisibly and the next summon reopens it with stale
    // rows. Esc and the scrim click land here; shell.hide() lands here too,
    // and the opened guard above makes the round trip idempotent.
    if (shell && typeof shell.hide === "function") Qt.callLater(function() { shell.hide("ryanyogan.omatop") })
    Qt.callLater(function() { gc() })
  }

  function toggle() { opened ? close() : open("{}") }

  // ---- Rows: a keyed ListModel so the ListView can animate moves ----------
  ListModel { id: rows }

  // Keys carry the section: one App can sit in Offenders and in User.
  function rowKey(r) { return r.type === "header" ? "h:" + r.section : r.section + ":" + r.app.id }

  // Rows reorder at most every two seconds so the list reads as "the culprit
  // rose", not as jitter. Values still update on every tick.
  property double lastReorderMs: 0
  property bool forceReorder: false

  function rebuild() {
    if (!service) return
    var now = Date.now()
    var allowMove = forceReorder || (now - lastReorderMs > 2000)
    forceReorder = false
    var desired = Model.sections(reading ? reading.apps : [], reading ? reading.offenders : [], service.pins, filter, sortKey, collapsed)
    // Two rows must never share a key: the keyed diff below moves rows by
    // index, and a duplicate makes it move on a stale index, writing one
    // row's identity onto another. Drop later occurrences rather than
    // corrupt the model.
    var seen = {}
    var unique = []
    for (var u = 0; u < desired.length; u++) {
      var uk = rowKey(desired[u])
      if (seen[uk]) continue
      seen[uk] = true
      unique.push(desired[u])
    }
    desired = unique
    scales = Model.scales(desired)
    var want = {}
    for (var d = 0; d < desired.length; d++) want[rowKey(desired[d])] = true

    for (var i = rows.count - 1; i >= 0; i--) if (!want[rows.get(i).key]) rows.remove(i)

    var index = {}
    for (var m = 0; m < rows.count; m++) index[rows.get(m).key] = m

    for (var t = 0; t < desired.length; t++) {
      var r = desired[t]
      var key = rowKey(r)
      var entry = {
        key: key, type: r.type, section: r.section,
        label: r.label || "", count: r.count || 0, collapsed: r.collapsed === true,
        appId: r.type === "app" ? r.app.id : ""
      }
      var j = index[key] === undefined ? -1 : index[key]
      if (j === -1) {
        rows.insert(t, entry)
        // Everything at or after t shifted down by one.
        for (var k in index) if (index[k] >= t) index[k] += 1
        index[key] = t
      } else if (j !== t && allowMove) {
        rows.move(j, t, 1)
        rows.set(t, entry)
        var lo = Math.min(j, t), hi = Math.max(j, t)
        for (var k2 in index) { var v = index[k2]; if (v >= lo && v <= hi) index[k2] = v === j ? t : (j > t ? v + 1 : v - 1) }
      } else rows.set(j, entry)
    }
    if (allowMove) lastReorderMs = now

    // Keep the cursor on the same row when the list reorders under it.
    if (cursorKey) {
      var found = -1
      for (var c = 0; c < rows.count; c++) if (rows.get(c).key === cursorKey) { found = c; break }
      if (found >= 0) cursorIndex = found
      else clampCursor()
    } else clampCursor()
  }

  Connections {
    target: root.service
    // Every sample slides the timelines; every readingTicks-th one (or the
    // first after something asked for it) becomes the reading.
    function onTicked() {
      if (!root.opened) return
      root.ticksSinceReading += 1
      var isReading = root.readingDue || root.ticksSinceReading >= root.readingTicks
      root.beat(isReading)
      if (isReading) root.takeReading()
    }
    // A pin is an edit, not a sample: re-stamp the reading in place so the
    // row moves now, without pulling newer figures into the surface.
    function onPinsChanged() {
      if (!root.opened || !root.reading) return
      var list = root.reading.apps
      for (var i = 0; i < list.length; i++) list[i].pinned = Model.isPinned(root.service.pins, list[i])
      root.forceReorder = true
      root.rebuild()
    }
    function onActionFinished(ev) {
      if (!root.opened) return
      var name = root.service.appsById[ev.id] ? root.service.appsById[ev.id].name : ev.id
      root.toast = ev.ok ? (ev.action + ": " + name) : ("failed " + ev.action + ": " + (ev.error || "unknown"))
      toastTimer.restart()
      // Something was stopped, paused or restarted: show the consequence on
      // the next sample rather than up to a reading later.
      if (ev.ok) root.readingDue = true
    }
  }
  Timer { id: toastTimer; interval: 3000; onTriggered: root.toast = "" }

  // The ListView lays the new row set out on the next frame; positioning the
  // view inside the same call as the model edits lands it mid-row.
  onFilterChanged: { forceReorder = true; rebuild(); Qt.callLater(firstApp) }
  onSortKeyChanged: { forceReorder = true; rebuild() }
  onCollapsedChanged: { forceReorder = true; rebuild() }

  // ---- Cursor --------------------------------------------------------------
  function clampCursor() {
    if (rows.count === 0) { cursorIndex = 0; cursorKey = ""; return }
    cursorIndex = Util.clamp(cursorIndex, 0, rows.count - 1)
    cursorKey = rows.get(cursorIndex).key
  }

  function setCursor(i, fromPointer) {
    if (rows.count === 0) return
    cursorIndex = Util.clamp(i, 0, rows.count - 1)
    cursorKey = rows.get(cursorIndex).key
    // A keyboard move hands the cursor to the keyboard; without this a 1 px
    // mouse twitch steals it straight back. Pointer-driven moves skip the
    // reset -- it would turn the gate's next sample into a seed and drop it.
    if (!fromPointer) pointerGate.reset()
    // The first App sits under the first header; keep that header in view.
    if (cursorIndex <= 1) list.positionViewAtBeginning()
    else list.positionViewAtIndex(cursorIndex, ListView.Contain)
  }

  // Moves over App rows only; headers are skipped but remain visible.
  function moveCursor(delta) {
    if (rows.count === 0) return
    var i = cursorIndex
    var steps = Math.abs(delta)
    var dir = delta > 0 ? 1 : -1
    while (steps > 0) {
      var n = i + dir
      while (n >= 0 && n < rows.count && rows.get(n).type !== "app") n += dir
      if (n < 0 || n >= rows.count) break
      i = n
      steps--
    }
    setCursor(i)
  }

  function firstApp() {
    for (var i = 0; i < rows.count; i++) if (rows.get(i).type === "app") { setCursor(i); return }
    clampCursor()
  }
  function lastApp() {
    for (var i = rows.count - 1; i >= 0; i--) if (rows.get(i).type === "app") { setCursor(i); return }
  }
  function jumpSection(dir) {
    var i = cursorIndex + dir
    while (i >= 0 && i < rows.count) {
      if (rows.get(i).type === "header") {
        var n = i + 1
        if (dir < 0 && n === cursorIndex) { i += dir; continue }
        if (n < rows.count && rows.get(n).type === "app") { setCursor(n); return }
      }
      i += dir
    }
    if (dir > 0) lastApp(); else firstApp()
  }
  function visibleRowAt(fraction) {
    var y = list.contentY + list.height * fraction
    var idx = list.indexAt(Style.space(10), y)
    if (idx < 0) idx = fraction < 0.5 ? 0 : rows.count - 1
    var dir = fraction < 0.5 ? 1 : -1
    while (idx >= 0 && idx < rows.count && rows.get(idx).type !== "app") idx += dir
    if (idx >= 0 && idx < rows.count) setCursor(idx)
  }

  function toggleFold(section) {
    var next = Util.cloneJson(collapsed)
    next[section] = !(next[section] === true)
    collapsed = next
  }
  function foldAll(fold) {
    var next = {}
    var all = ["recent", "offenders", "pinned", "user", "system", "desktop", "kernel"]
    for (var i = 0; i < all.length; i++) next[all[i]] = fold
    collapsed = next
  }

  function focusDetail(app) {
    if (!app) return
    if (detailId === app.id) { detailId = ""; service.requestDetail(""); return }
    detailId = app.id
    service.requestDetail(app.id)
  }

  function toggleExpand(app) {
    if (!app) return
    var next = Util.cloneJson(expanded)
    if (next[app.id]) delete next[app.id]
    else next[app.id] = true
    expanded = next
    if (next[app.id] && detailId !== app.id) service.requestDetail(app.id)
  }

  function requestStop(app) {
    if (!app || app.readOnly) { root.toast = "Desktop bucket is read-only"; toastTimer.restart(); return }
    confirmApp = app
    mode = "confirm"
    confirm.selectedIndex = 1
  }

  function takeCount(fallback) {
    var n = parseInt(countBuffer)
    countBuffer = ""
    return isFinite(n) && n > 0 ? n : fallback
  }

  // ---- Keys ----------------------------------------------------------------
  function handleKey(event) {
    if (mode === "confirm") {
      if (confirm.handleKey(event)) event.accepted = true
      return
    }
    if (mode === "help") {
      mode = "normal"
      event.accepted = true
      return
    }
    if (mode === "search") {
      if (event.key === Qt.Key_Escape) { filter = ""; mode = "normal" }
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) mode = "normal"
      else if (Util.editsFilter(event, filter)) filter = Util.editedFilter(event, filter)
      else if (event.key === Qt.Key_Down) moveCursor(1)
      else if (event.key === Qt.Key_Up) moveCursor(-1)
      else if (event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) filter += event.text
      event.accepted = true
      return
    }

    var t = event.text
    var handled = true
    var app = cursorApp

    // Chord second keys.
    if (pending === "g") {
      pending = ""
      if (t === "g") firstApp(); else handled = false
      event.accepted = true
      return
    }
    if (pending === "z") {
      pending = ""
      if (t === "a" || t === "o" || t === "c") { var row = rows.count ? rows.get(cursorIndex) : null; if (row) toggleFold(row.section) }
      else if (t === "M") foldAll(true)
      else if (t === "R") foldAll(false)
      event.accepted = true
      return
    }
    if (pending === "s") {
      pending = ""
      if (t === "c") sortKey = "cpu"
      else if (t === "m") sortKey = "mem"
      else if (t === "n") sortKey = "name"
      else if (t === "g") sortKey = "gpu"
      else if (t === "s") { if (app) service.togglePause(app) }
      event.accepted = true
      return
    }

    if (/^[0-9]$/.test(t) && !(t === "0" && countBuffer === "")) { countBuffer += t; event.accepted = true; return }

    if (event.key === Qt.Key_Escape) {
      if (filter) filter = ""
      else if (detailId) { detailId = ""; service.requestDetail("") }
      else if (scrub >= 0) scrub = -1
      else close()
    }
    else if (t === "q") { if (detailId) { detailId = ""; service.requestDetail("") } else close() }
    else if (t === "j" || event.key === Qt.Key_Down) moveCursor(takeCount(1))
    else if (t === "k" || event.key === Qt.Key_Up) moveCursor(-takeCount(1))
    else if (t === "g") pending = "g"
    else if (t === "G") { var c = parseInt(countBuffer); countBuffer = ""; if (isFinite(c) && c > 0) setCursor(c - 1); else lastApp() }
    else if (t === "z") pending = "z"
    else if (t === "s") pending = "s"
    else if (event.key === Qt.Key_D && (event.modifiers & Qt.ControlModifier)) moveCursor(Math.max(1, Math.floor(list.height / Style.space(36) / 2)))
    else if (event.key === Qt.Key_U && (event.modifiers & Qt.ControlModifier)) moveCursor(-Math.max(1, Math.floor(list.height / Style.space(36) / 2)))
    else if (event.key === Qt.Key_PageDown) moveCursor(Math.max(1, Math.floor(list.height / Style.space(36))))
    else if (event.key === Qt.Key_PageUp) moveCursor(-Math.max(1, Math.floor(list.height / Style.space(36))))
    else if (t === "H") visibleRowAt(0.02)
    else if (t === "M") visibleRowAt(0.5)
    else if (t === "L") visibleRowAt(0.98)
    else if (t === "}" || event.key === Qt.Key_Tab) jumpSection(1)
    else if (event.key === Qt.Key_Backtab) jumpSection(-1)
    else if (t === "{") jumpSection(-1)
    else if (t === "n") moveCursor(1)
    else if (t === "N") moveCursor(-1)
    else if (t === "/") { mode = "search" }
    else if (t === "?") { mode = "help" }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || t === "l") focusDetail(app)
    else if (t === "h") { if (detailId) { detailId = ""; service.requestDetail("") } }
    else if (t === "o" || event.key === Qt.Key_Space) toggleExpand(app)
    else if (t === "p") { if (app) service.togglePin(app) }
    else if (t === "x" || event.key === Qt.Key_Delete) requestStop(app)
    else if (t === "r") { if (app && app.kind === "service") service.restartApp(app); else { root.toast = "Restart is for Services only"; toastTimer.restart() } }
    else if (t === "," ) scrub = scrub < 0 ? 118 : Math.max(0, scrub - takeCount(1))
    else if (t === ".") scrub = scrub < 0 ? -1 : Math.min(119, scrub + takeCount(1))
    else if (t === "0") scrub = -1
    else if (t === "b") { if (service.samplerState === "missing" || service.samplerState === "buildFailed") service.buildSampler() }
    else if (t === "a" && setup.visible) setup.about = !setup.about
    else handled = false

    event.accepted = handled
  }

  // ---- Window --------------------------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened || scrim.opacity > 0.01
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omatop-overlay"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }

    // Theme background carries the contrast on any wallpaper.
    Rectangle {
      id: scrim
      anchors.fill: parent
      color: root.background
      opacity: root.opened ? 1 : 0
      Behavior on opacity { enabled: root.animated; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      MouseArea { anchors.fill: parent; enabled: root.opened; onClicked: root.close() }
    }

    Item {
      id: keys
      anchors.fill: parent
      anchors.margins: Math.round(Math.min(panel.width, panel.height) * 0.035)
      anchors.topMargin: Style.space(24)
      anchors.bottomMargin: Style.space(20)
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { root.handleKey(event) }
      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.985
      Behavior on opacity { enabled: root.animated; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on scale { enabled: root.animated; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      // ---- Header ----
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(30)

        // Which machine this is: hostname and kernel, read once on open.
        FileView { id: hostnameFile; path: "/etc/hostname" }
        FileView { id: kernelFile; path: "/proc/sys/kernel/osrelease" }
        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: {
            var host = String(hostnameFile.text() || "").trim()
            var kernel = String(kernelFile.text() || "").trim()
            return [host, kernel ? "linux " + kernel : ""].filter(function(x) { return x !== "" }).join("  ·  ")
          }
          color: root.dim
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 2
          font.capitalization: Font.AllUppercase
        }

        // Pressure, centred like the speed test's title. The same value the bar glyph shows.
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)
          Rectangle {
            width: Style.space(7); height: width; radius: width / 2
            color: root.pressureColor
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { enabled: root.animated; ColorAnimation { duration: 300 } }
            // No pulse: a looping animation pins the window at full refresh
            // (measured at ~3-6% of a core), and it would fire exactly when
            // the machine can least afford it. The colour is the signal.
          }
          Text {
            text: Model.pressureLabel(root.pressure.level)
            color: root.pressureColor
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 2
            font.capitalization: Font.AllUppercase
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { enabled: root.animated; ColorAnimation { duration: 300 } }
          }
          Text {
            visible: root.pressure.level !== "calm" && !!root.pressure.reason
            text: root.pressure.reason || ""
            color: root.dim
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(14)
          Rectangle {
            width: Style.space(240)
            height: Style.space(26)
            radius: Style.space(13)
            color: root.mode === "search" ? Qt.rgba(1, 1, 1, 0.08) : "transparent"
            border.width: 1
            border.color: root.mode === "search" ? Qt.rgba(1, 1, 1, 0.45) : root.hairline
            anchors.verticalCenter: parent.verticalCenter
            Behavior on border.color { enabled: root.animated; ColorAnimation { duration: 120 } }
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.filter.length ? "/" + root.filter : "/  name, command or :port"
              color: root.filter.length ? root.ink : root.faint
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Rectangle {
              visible: root.mode === "search"
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(6); height: Style.space(14)
              color: root.ink
              // A blink is two frames a second, not sixty: a looping
              // opacity animation kept the whole window at full refresh.
              Timer {
                running: root.mode === "search" && root.animated
                interval: 500; repeat: true
                onRunningChanged: parent.opacity = 1
                onTriggered: parent.opacity = parent.opacity > 0.5 ? 0 : 1
              }
            }
          }
          Text {
            text: "?"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }

      // ---- Cluster: four dials. Pointed at the machine, or at the focused App. ----
      Item {
        id: cluster
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        anchors.horizontalCenter: parent.horizontalCenter
        width: dials.width
        height: dials.height
        // Four dials across, sized by whichever is tighter: a quarter of the
        // width or 30% of the height. Large screens get large instruments.
        readonly property real dialSize: Math.max(Style.space(120), Math.min(Math.floor((keys.width - Style.space(56) * 3) / 4), Math.floor(keys.height * 0.30)))
        MouseArea { anchors.fill: parent; onClicked: {} }

        Row {
          id: dials
          spacing: Style.space(56)

          Dial {
            id: cpuDial
            diameter: cluster.dialSize
            label: root.clusterName ? root.clusterName + "  cpu" : "cpu"
            value: root.clusterCpu
            fullScale: 100
            readout: Model.pct(root.clusterCpu)
            unit: root.detailApp ? "of machine" : "%"
            accent: root.pressureColor
            onScrim: root.ink; onScrimDim: root.dim; fontFamily: root.fontFamily; animated: root.animated; phase: root.glidePhase; readoutOpacity: root.readoutFade
          }
          Dial {
            id: memDial
            diameter: cluster.dialSize
            label: root.clusterName ? root.clusterName + "  memory" : "memory"
            value: root.clusterMem
            fullScale: 100
            readout: root.detailApp ? Model.bytes(root.detailApp.mem) : (root.vitals ? Model.bytes(root.vitals.mem.used) : "--")
            sublabel: "of " + Model.bytes(root.memTotal)
            accent: root.accent
            onScrim: root.ink; onScrimDim: root.dim; fontFamily: root.fontFamily; animated: root.animated; phase: root.glidePhase; readoutOpacity: root.readoutFade
          }
          Dial {
            id: gpuDial
            diameter: cluster.dialSize
            visible: root.showGpu
            label: root.clusterName ? root.clusterName + "  gpu" : "gpu"
            value: root.clusterGpu
            fullScale: 100
            readout: root.detailApp && root.detailApp.gpu < 0 ? "--" : Model.pct(root.clusterGpu)
            unit: root.vitals && root.vitals.gpu ? Model.temp(root.vitals.gpu.temp) + " gpu" : "%"
            engaged: !root.detailApp || root.detailApp.gpu >= 0
            accent: root.accent
            onScrim: root.ink; onScrimDim: root.dim; fontFamily: root.fontFamily; animated: root.animated; phase: root.glidePhase; readoutOpacity: root.readoutFade
          }
          Dial {
            id: tempDial
            diameter: cluster.dialSize
            label: "temp"
            value: root.vitals ? root.vitals.cpu.temp : 0
            fullScale: 100
            readout: root.vitals ? Model.temp(root.vitals.cpu.temp) : "--"
            unit: root.vitals && root.vitals.fan && root.vitals.fan.available && root.vitals.fan.rpm > 0 ? root.vitals.fan.rpm + " rpm" : "cpu"
            engaged: root.vitals && root.vitals.cpu.temp > 0
            accent: root.vitals && root.vitals.cpu.temp >= 90 ? root.urgent : root.accent
            onScrim: root.ink; onScrimDim: root.dim; fontFamily: root.fontFamily; animated: root.animated; phase: root.glidePhase; readoutOpacity: root.readoutFade
          }
        }
      }

      // ---- Trip computer: the small digital readouts under the cluster ----
      Row {
        id: trip
        anchors.top: cluster.bottom
        anchors.topMargin: Style.space(10)
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(36)
        readonly property var v: root.vitals

        // Static model: a fresh array literal here would recreate every
        // delegate on each tick. The text bindings update in place instead.
        function tripValue(key) {
          var v = trip.v
          if (!v) return key === "power" ? "" : "--"
          if (key === "net") return "↓" + Model.bytes(v.net.rx) + "/s  ↑" + Model.bytes(v.net.tx) + "/s"
          if (key === "disk") return "r " + Model.bytes(v.disk.read) + "/s  w " + Model.bytes(v.disk.write) + "/s"
          if (key === "power") return v.power && v.power.available ? Model.watts(v.power.watts) + (v.power.battery >= 0 ? "  " + v.power.battery + "%" + (v.power.charging ? " charging" : "") : "") : ""
          if (key === "load") return v.load.map(function(x) { return Number(x).toFixed(2) }).join("  ")
          if (key === "up") return Model.age(root.nowMs / 1000 - v.uptime, root.nowMs)
          return ""
        }

        Repeater {
          model: ["net", "disk", "power", "load", "up"]
          delegate: Row {
            required property var modelData
            spacing: Style.space(8)
            readonly property string value: trip.tripValue(modelData)
            visible: value !== ""
            Text {
              text: modelData
              color: root.faint
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.5
              font.capitalization: Font.AllUppercase
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: parent.value
              opacity: root.readoutFade
              color: root.ink
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }

      Rectangle {
        id: rule
        anchors.top: trip.bottom
        anchors.topMargin: Style.space(14)
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: root.hairline
        // Time to the next reading, as a faint accent filling the rule. It
        // says why the figures change when they do, and rides the clock that
        // is already running.
        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          height: 1
          width: root.motionOn ? Math.round(parent.width * root.readingProgress) : 0
          color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
        }
      }

      // ---- Body ----
      Item {
        id: body
        anchors.top: rule.bottom
        anchors.topMargin: Style.space(12)
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        MouseArea { anchors.fill: parent; onClicked: {} }

        // Ledger: every Vital on one two-minute axis; the focused App's strips join it.
        Item {
          id: ledger
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          width: Math.round(parent.width * 0.40)
          readonly property var v: root.vitals
          readonly property var h: root.service ? root.service.history : null
          readonly property bool compactStrips: root.detailId !== ""

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onPositionChanged: function(mouse) {
              if (mouse.y > strips.height) { root.scrub = -1; return }
              root.scrub = Math.round(Math.max(0, Math.min(1, (mouse.x - cpuStrip.plotX) / cpuStrip.plotWidth)) * 119)
            }
            onExited: root.scrub = -1
          }

          // Strips share the ledger height equally (the detail strips take a
          // fixed slice when an App is focused), so the graphs use every
          // pixel the screen offers.
          readonly property int axisHeight: Style.space(16)
          readonly property int stripGap: Style.space(20)
          readonly property int stripCount: 5 + (root.showGpu ? 1 : 0) + (ledger.v && ledger.v.power && ledger.v.power.available ? 1 : 0)
          readonly property real detailSlice: root.detailApp ? Math.min(height * 0.45, Style.space(340)) : 0
          readonly property int coreRowHeight: Style.space(7) + Style.space(8)
          readonly property real stripHeight: Math.max(Style.space(34), (height - axisHeight - detailSlice - coreRowHeight - stripGap * (stripCount + 1)) / stripCount)

          Column {
            id: strips
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: ledger.stripGap

            Strip { id: cpuStrip; width: strips.width; height: ledger.stripHeight; label: "cpu"; maxValue: 100
              samples: ledger.h ? ledger.h.cpu : []; valueText: ledger.v ? Model.pct(ledger.v.cpu.total) : "--"
              formatter: function(x) { return Model.pct(x) }
              axisFormatter: function(x) { return Math.round(x) + "%" }
              ink: root.ink; line: root.pressureColor; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated; phase: root.phase; sliding: root.sliding; valueOpacity: root.readoutFade
              Behavior on line { enabled: root.animated; ColorAnimation { duration: 300 } } }
            // Every core, one block each, under the cpu timeline it belongs to.
            CoreRow { width: strips.width; height: ledger.coreRowHeight - Style.space(8)
              cores: root.vitals && root.vitals.cpu ? root.vitals.cpu.cores : []
              phase: root.glidePhase; animated: root.animated
              accent: root.accent; urgent: root.urgent; faint: root.faint; track: root.hairline; fontFamily: root.fontFamily }
            Strip { width: strips.width; height: ledger.stripHeight; label: "memory"; maxValue: 100
              samples: ledger.h ? ledger.h.mem : []; valueText: ledger.v ? Model.bytes(ledger.v.mem.used) + "  " + Model.pct(root.clusterMem) : "--"
              formatter: function(x) { return Model.pct(x) }
              axisFormatter: function(x) { return x <= 0 ? "0" : root.memTotal > 0 ? Model.bytes(x / 100 * root.memTotal) : Model.pct(x) }
              ink: root.ink; line: root.accent; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated; phase: root.phase; sliding: root.sliding; valueOpacity: root.readoutFade }
            Strip { width: strips.width; height: ledger.stripHeight; visible: root.showGpu; label: "gpu"; maxValue: 100
              samples: ledger.h ? ledger.h.gpu : []; valueText: ledger.v && ledger.v.gpu ? Model.pct(ledger.v.gpu.busy) : "--"
              formatter: function(x) { return Model.pct(x) }
              axisFormatter: function(x) { return Math.round(x) + "%" }
              ink: root.ink; line: root.accent; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated; phase: root.phase; sliding: root.sliding; valueOpacity: root.readoutFade }
            Strip { width: strips.width; height: ledger.stripHeight; label: "temperature"; maxValue: 100; available: ledger.v && ledger.v.cpu.temp > 0
              samples: ledger.h ? ledger.h.temp : []; valueText: ledger.v ? Model.temp(ledger.v.cpu.temp) : "--"
              formatter: function(x) { return Model.temp(x) }
              axisFormatter: function(x) { return Math.round(x) + "°" }
              ink: root.ink; line: ledger.v && ledger.v.cpu.temp >= 90 ? root.urgent : root.dim; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated; phase: root.phase; sliding: root.sliding; valueOpacity: root.readoutFade }
            Strip { width: strips.width; height: ledger.stripHeight; label: "network"; maxValue: 0; floorValue: 1024 * 64
              samples: ledger.h ? ledger.h.netRx : []; valueText: ledger.v ? "↓ " + Model.bytes(ledger.v.net.rx) + "/s  ↑ " + Model.bytes(ledger.v.net.tx) + "/s" : "--"
              formatter: function(x) { return "↓ " + Model.bytes(x) + "/s" }
              axisFormatter: function(x) { return x <= 0 ? "0" : Model.bytes(x) + "/s" }
              ink: root.ink; line: root.dim; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated; phase: root.phase; sliding: root.sliding; valueOpacity: root.readoutFade }
            Strip { width: strips.width; height: ledger.stripHeight; label: "disk"; maxValue: 0; floorValue: 1024 * 1024
              samples: ledger.h ? ledger.h.diskWrite : []; valueText: ledger.v ? "r " + Model.bytes(ledger.v.disk.read) + "/s  w " + Model.bytes(ledger.v.disk.write) + "/s" : "--"
              formatter: function(x) { return "w " + Model.bytes(x) + "/s" }
              axisFormatter: function(x) { return x <= 0 ? "0" : Model.bytes(x) + "/s" }
              ink: root.ink; line: root.dim; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated; phase: root.phase; sliding: root.sliding; valueOpacity: root.readoutFade }
            Strip { width: strips.width; height: ledger.stripHeight; visible: ledger.v && ledger.v.power && ledger.v.power.available; label: "power"; maxValue: 0; floorValue: 30
              samples: ledger.h ? ledger.h.power : []; valueText: ledger.v && ledger.v.power ? Model.watts(ledger.v.power.watts) : "--"
              formatter: function(x) { return Model.watts(x) }
              axisFormatter: function(x) { return Math.round(x) + "W" }
              ink: root.ink; line: root.dim; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated; phase: root.phase; sliding: root.sliding; valueOpacity: root.readoutFade }

            Item {
              x: cpuStrip.plotX
              width: cpuStrip.plotWidth
              height: ledger.axisHeight
              readonly property string span: Model.span(119 * root.tickMs)
              readonly property string half: Model.span(60 * root.tickMs)
              Text { x: 0; y: Style.space(2); text: "-" + parent.span; color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text { x: parent.width / 2 - width / 2; y: Style.space(2); text: "-" + parent.half; color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text { anchors.right: parent.right; y: Style.space(2); text: root.scrub >= 0 ? "-" + Model.span((119 - root.scrub) * root.tickMs) : "now"; color: root.scrub >= 0 ? root.ink : root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            }
          }

          // The focused App's own strips slide in on the same axis.
          Item {
            id: detailPane
            anchors.top: strips.bottom
            anchors.topMargin: Style.space(10)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            opacity: root.detailApp ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { enabled: root.animated; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            readonly property var app: root.detailApp
            readonly property var d: root.service && root.service.detail && root.service.detail.id === root.detailId ? root.service.detail : null
            // Three strips share whatever the slice leaves after the title and the facts.
            readonly property int factsHeight: Style.space(18) * 4 + Style.space(6)
            readonly property real stripHeight: Math.max(Style.space(30), (height - Style.space(30) - factsHeight - Style.space(4) * 6) / 3)

            Column {
              anchors.fill: parent
              spacing: Style.space(4)
              Rectangle { width: parent.width; height: 1; color: root.hairline }
              Item {
                width: parent.width
                height: Style.space(30)
                Text {
                  anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.bottomMargin: Style.space(4)
                  text: detailPane.app ? detailPane.app.name : ""
                  color: root.detailApp && root.service && root.detailApp.id === root.culprit ? root.pressureColor : root.ink
                  textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true
                }
                Text {
                  anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.bottomMargin: Style.space(5)
                  text: detailPane.app ? (detailPane.app.nproc + (detailPane.app.nproc === 1 ? " process" : " processes") + "   up " + Model.age(detailPane.app.started, root.nowMs)) : ""
                  color: root.dim; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                }
              }
              Strip { width: parent.width; height: detailPane.stripHeight; label: "cpu"; maxValue: 0; floorValue: 10
                samples: detailPane.d ? detailPane.d.cpu : []; valueText: detailPane.app ? Model.pct(detailPane.app.cpu) : ""
                formatter: function(x) { return Model.pct(x) }
                axisFormatter: function(x) { return Math.round(x) + "%" }
                ink: root.ink; line: root.accent; dim: root.dim; faint: root.faint; hairline: root.hairline
                fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated; phase: root.phase; sliding: root.sliding; valueOpacity: root.readoutFade }
              Strip { width: parent.width; height: detailPane.stripHeight; label: "memory"; maxValue: 0; floorValue: 64 * 1024 * 1024
                samples: detailPane.d ? detailPane.d.mem : []; valueText: detailPane.app ? Model.bytes(detailPane.app.mem) : ""
                formatter: function(x) { return Model.bytes(x) }
                ink: root.ink; line: root.accent; dim: root.dim; faint: root.faint; hairline: root.hairline
                fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated; phase: root.phase; sliding: root.sliding; valueOpacity: root.readoutFade }
              Strip { width: parent.width; height: detailPane.stripHeight; visible: root.showGpu && detailPane.app && detailPane.app.gpu >= 0; label: "gpu"; maxValue: 0; floorValue: 10
                samples: detailPane.d ? detailPane.d.gpu : []; valueText: detailPane.app ? Model.pct(detailPane.app.gpu) : ""
                formatter: function(x) { return Model.pct(x) }
                axisFormatter: function(x) { return Math.round(x) + "%" }
                ink: root.ink; line: root.accent; dim: root.dim; faint: root.faint; hairline: root.hairline
                fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated; phase: root.phase; sliding: root.sliding; valueOpacity: root.readoutFade }
              Column {
                width: parent.width
                spacing: Style.space(2)
                topPadding: Style.space(6)
                Repeater {
                  model: ["ports", "unit", "tag", "cmd"]
                  delegate: Item {
                    required property var modelData
                    readonly property string value: {
                      var a = detailPane.app
                      if (!a) return ""
                      if (modelData === "ports") return Model.ports(a.ports) || "none"
                      if (modelData === "unit") return a.unit || (a.kind === "job" ? "job on " + a.tty : "")
                      if (modelData === "tag") return a.tag || ""
                      return a.cmd || ""
                    }
                    width: parent.width
                    height: value === "" ? 0 : Style.space(18)
                    visible: value !== ""
                    Text { x: 0; width: Style.space(44); text: modelData; color: root.faint; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1.5; font.bold: true; font.capitalization: Font.AllUppercase; anchors.verticalCenter: parent.verticalCenter }
                    Text { x: Style.space(44); width: parent.width - x; text: parent.value; elide: Text.ElideMiddle; color: root.dim; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                  }
                }
              }
            }
          }
        }

        Rectangle {
          id: divider
          anchors.left: ledger.right
          anchors.leftMargin: Style.space(18)
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: 1
          color: root.hairline
        }

        // ---- List ----
        Item {
          id: listPane
          anchors.left: divider.right
          anchors.leftMargin: Style.space(18)
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom

          Item {
            id: columns
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(18)
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.right: columnLabels.left
              anchors.rightMargin: Style.space(14)
              elide: Text.ElideRight
              text: "Offenders are the top " + (root.service ? root.service.offenderCpuCount : 10) + " by average cpu and top " + (root.service ? root.service.offenderMemCount : 6) + " by memory over 30 s, listed alphabetically"
              color: root.faint; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            }
            Row {
              id: columnLabels
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.rowPaddingX
              spacing: Style.space(14)
              Text { width: Style.space(96) + Style.space(8) + Style.space(54); horizontalAlignment: Text.AlignRight; text: "cpu"; color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.5; font.capitalization: Font.AllUppercase }
              Text { width: Style.space(96) + Style.space(8) + Style.space(54); horizontalAlignment: Text.AlignRight; text: "memory"; color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.5; font.capitalization: Font.AllUppercase }
            }
          }

          PointerMoveGate { id: pointerGate; referenceItem: listPane }

          ListView {
            id: list
            anchors.top: columns.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            model: rows
            spacing: 0
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: Style.space(400)

            // No transitions. Rows are alphabetical and membership changes at
            // most every 30 s; animated moves interrupted by the next tick
            // left delegates drawn at stale positions.

            delegate: Loader {
              id: rowLoader
              required property int index
              required property string key
              required property string type
              required property string section
              required property string label
              required property int count
              required property bool collapsed
              required property string appId
              width: list.width
              sourceComponent: type === "header" ? headerRow : appRow
              // Right on the frame the delegate is created: the Loader has not
              // loaded `item` yet when this first evaluates, and a placeholder
              // height stacks every following row a few pixels out. Search
              // recreates the whole visible set on every keystroke.
              readonly property int headerHeight: Style.space(index === 0 ? 26 : 32)
              height: type === "header" ? headerHeight : (item ? item.implicitHeight : Style.space(36))

              Component {
                id: headerRow
                Item {
                  implicitHeight: rowLoader.headerHeight
                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.rowPaddingX
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(4)
                    text: (rowLoader.collapsed ? "▸ " : "") + rowLoader.label + "  " + rowLoader.count
                    color: rowLoader.section === "recent" || rowLoader.section === "offenders" ? root.ink : root.dim
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.5
                    font.capitalization: Font.AllUppercase
                  }
                  MouseArea { anchors.fill: parent; onClicked: root.toggleFold(rowLoader.section) }
                }
              }

              Component {
                id: appRow
                AppRow {
                  app: root.reading ? (rowLoader.section === "offenders" ? root.reading.offenders.find(function(a) { return a.id === rowLoader.appId }) || null : root.reading.appsById[rowLoader.appId] || null) : null
                  hasCursor: rowLoader.index === root.cursorIndex
                  isCulprit: root.culprit === rowLoader.appId
                  isDetail: root.detailId === rowLoader.appId
                  expanded: root.expanded[rowLoader.appId] === true
                  processes: root.reading && root.reading.processes[rowLoader.appId] ? root.reading.processes[rowLoader.appId] : []
                  nowMs: root.nowMs
                  ink: root.ink; dim: root.dim; faint: root.faint; hairline: root.hairline
                  selectedBackground: root.selectedBackground; selectedText: root.ink
                  pressureColor: root.pressureColor
                  accent: root.accent
                  fontFamily: root.fontFamily
                  animated: root.animated
                  phase: root.glidePhase
                  useAverages: rowLoader.section === "offenders"
                  cpuScale: root.scales[rowLoader.section] ? root.scales[rowLoader.section].cpu : 10
                  memScale: root.scales[rowLoader.section] ? root.scales[rowLoader.section].mem : 1024 * 1024 * 1024
                  cornerRadius: Style.space(6)

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onPositionChanged: function(mouse) {
                      if (!pointerGate.moved(parent, mouse)) return
                      root.setCursor(rowLoader.index, true)
                    }
                    onClicked: function(mouse) {
                      root.setCursor(rowLoader.index, true)
                      if (mouse.button === Qt.RightButton) root.toggleExpand(root.cursorApp)
                      else root.focusDetail(root.cursorApp)
                    }
                  }
                }
              }
            }

            Text {
              anchors.centerIn: parent
              visible: rows.count === 0
              text: root.live ? (root.filter ? "Nothing matches /" + root.filter : "Waiting for the first sample") : ""
              color: root.faint
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        // Sampler state: the same front door as the quick view, wider.
        SetupCard {
          id: setup
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(80), Style.space(640))
          visible: root.service && root.service.samplerState !== "running" && root.service.samplerState !== "starting"
          state: root.service ? root.service.samplerState : "starting"
          logTail: root.service ? root.service.buildLog.split("\n").filter(function(l) { return l.length }).slice(-6).join("\n") : ""
          ink: root.ink; dim: root.dim; faint: root.faint; hairline: root.hairline
          accent: root.accent; urgent: root.urgent
          fontFamily: root.fontFamily; animated: root.animated
          onBuild: root.service.buildSampler()
        }
      }

      // ---- Footer ----
      Item {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(22)

        readonly property var hints: root.mode === "search"
          ? [["type", "filter"], ["enter", "keep"], ["esc", "clear"]]
          : [["j k", "move"], ["tab", "section"], ["enter", "focus"], ["o", "processes"], ["p", "pin"], ["ss", "pause"], ["x", "stop"], ["/", "find"], ["?", "help"]]

        // Toast replaces the legend while it lasts.
        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          visible: root.toast.length > 0
          text: root.toast
          color: root.ink
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          visible: root.toast.length === 0
          spacing: Style.space(16)
          Repeater {
            model: footer.hints
            delegate: Row {
              required property var modelData
              spacing: Style.space(6)
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: keyLabel.implicitWidth + Style.space(12)
                height: Style.space(17)
                radius: Style.space(4)
                color: Qt.rgba(1, 1, 1, 0.07)
                border.width: 1
                border.color: root.hairline
                Text {
                  id: keyLabel
                  anchors.centerIn: parent
                  text: modelData[0]
                  color: root.dim
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: modelData[1]
                color: root.faint
                textFormat: Text.PlainText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)
          Text {
            visible: root.countBuffer.length > 0 || root.pending.length > 0
            text: root.countBuffer + root.pending
            color: root.ink
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            visible: root.motionNote !== ""
            text: root.motionNote + "  ·"
            color: root.faint
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: "sort " + root.sortKey
            color: root.faint
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }

      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        z: 10
        opened: root.mode === "confirm"
        message: root.confirmApp ? ("Stop " + root.confirmApp.name + "? " + root.confirmApp.nproc + (root.confirmApp.nproc === 1 ? " process" : " processes") + " will be terminated.") : ""
        confirmText: "Stop"
        background: root.background
        foreground: root.ink
        scrim: Util.alpha(root.background, 0.72)
        selectedBackground: root.selectedBackground
        selectedText: root.ink
        fontFamily: root.fontFamily
        cornerRadius: Style.space(10)
        onConfirmed: { if (root.confirmApp) root.service.stopApp(root.confirmApp); root.confirmApp = null; root.mode = "normal" }
        onCanceled: { root.confirmApp = null; root.mode = "normal" }
      }

      HelpCard {
        anchors.fill: parent
        z: 9
        opened: root.mode === "help"
        ink: root.ink; dim: root.dim; faint: root.faint; hairline: root.hairline
        fontFamily: root.fontFamily
        animated: root.animated
        onDismissed: root.mode = "normal"
      }
    }
  }
}
