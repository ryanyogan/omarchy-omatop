import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Omatop service: owns the sampler process and every piece of derived state.
// The bar widget, dropdown panel and overlay are pure readers of this object
// and call its command functions. Nothing here touches Style or Color.
Item {
  id: root
  visible: false

  property var shell: null
  property var manifest: null

  // Pushed by the bar widget (its shell.json entry is plugin-wide truth).
  property var widgetSettings: ({})
  function widgetSetting(name, fallback) {
    var value = widgetSettings ? widgetSettings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }
  readonly property real refreshSeconds: Util.clamp(Number(widgetSetting("refreshSeconds", 5)) || 5, 1, 30)
  readonly property real rate: 1 / refreshSeconds
  readonly property bool reducedMotion: widgetSetting("reducedMotion", false) === true

  // Paths. resolvedUrl percent-encodes, so decode before handing to a process.
  readonly property string pluginDir:
    decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string samplerPath: pluginDir + "/sampler/target/release/omatop-sampler"
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
  readonly property string stateFilePath: stateDir + "/omatop.json"

  // ---- Sampler lifecycle -------------------------------------------------

  // "missing" (binary absent), "building", "buildFailed", "starting", "running", "crashed"
  property string samplerState: "starting"
  property string buildLog: ""
  property int restartAttempts: 0

  // Latest tick, verbatim from the protocol, plus derived views.
  property var tick: null
  property var apps: []
  property var appsById: ({})
  property var vitals: null
  property var history: null
  property var pressure: ({ level: "calm", score: 0, reason: "" })
  property string culprit: ""
  property var detail: null
  property var processes: ({})
  property int tickCount: 0
  property double lastTickMs: 0

  // Pins are identities (App names), not PIDs. Persisted to stateFile.
  property var pins: []
  property var recentActions: []      // last few action events for the UI to toast
  property int openSurfaces: 0        // overlay/panel open count drives lean ticks

  signal ticked()
  signal actionFinished(var event)

  Process {
    id: sampler
    command: [root.samplerPath]
    running: false
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.ingest(line) }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { if (line.length) console.warn("omatop sampler: " + line) }
    }
    onExited: function(code, status) {
      if (!root.sampler_intentionalStop) {
        root.samplerState = "crashed"
        restartTimer.interval = Math.min(30000, 1000 * Math.pow(2, root.restartAttempts))
        root.restartAttempts += 1
        restartTimer.restart()
      }
      root.sampler_intentionalStop = false
    }
  }
  property bool sampler_intentionalStop: false

  Timer {
    id: restartTimer
    repeat: false
    onTriggered: root.startSampler()
  }

  Process {
    id: binaryProbe
    command: ["test", "-x", root.samplerPath]
    running: false
    onExited: function(code) {
      if (code === 0) {
        root.samplerState = "starting"
        root.restartAttempts = 0
        sampler.running = true
        root.pushRate()
        root.pushLean()
      } else {
        root.samplerState = "missing"
      }
    }
  }

  function startSampler() {
    if (sampler.running) return
    binaryProbe.running = true
  }

  function stopSampler() {
    if (!sampler.running) return
    root.sampler_intentionalStop = true
    sampler.signal(15)
  }

  // Build the sampler on demand. Runs cargo inside the plugin dir; the plugin
  // installer never runs code, so this is the sanctioned first-run path.
  Process {
    id: builder
    command: ["bash", "-lc", "cd " + Util.shellQuote(root.pluginDir + "/sampler") + " && cargo build --release 2>&1"]
    running: false
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        root.buildLog = (root.buildLog + line + "\n").slice(-4000)
      }
    }
    onExited: function(code) {
      if (code === 0) {
        root.buildLog = ""
        root.startSampler()
      } else {
        root.samplerState = "buildFailed"
      }
    }
  }

  function buildSampler() {
    if (builder.running) return
    root.buildLog = ""
    root.samplerState = "building"
    builder.running = true
  }

  function send(line) {
    if (!sampler.running) return
    sampler.write(line + "\n")
  }

  function pushRate() { send("rate " + root.rate) }
  onRateChanged: pushRate()

  function surfaceOpened() { root.openSurfaces = root.openSurfaces + 1 }
  function surfaceClosed() { root.openSurfaces = Math.max(0, root.openSurfaces - 1) }
  // Nothing open: lean ticks (vitals + pressure only, ~700 bytes). Something
  // opens: full ticks, and one right now so the surface never shows stale data.
  onOpenSurfacesChanged: pushLean()
  function pushLean() {
    if (root.openSurfaces > 0) send("lean off\nnow")
    else send("lean on")
  }


  // ---- Tick ingestion ----------------------------------------------------

  function ingest(line) {
    if (!line || line.length < 2) return
    var data
    try { data = JSON.parse(line) } catch (e) { console.warn("omatop: bad tick: " + e); return }
    if (!data || data.v !== 1) return

    root.samplerState = "running"
    root.tick = data
    root.vitals = data.vitals || null
    // Lean ticks omit history and apps; keep what we had rather than blanking.
    if (data.history) root.history = data.history
    root.pressure = data.pressure || { level: "calm", score: 0, reason: "" }
    root.culprit = data.culprit || ""
    root.detail = data.detail || null
    root.processes = data.processes || ({})

    var lean = !Array.isArray(data.apps) || (data.apps.length === 0 && root.openSurfaces === 0)
    var list = lean ? root.apps : data.apps
    var byId = lean ? root.appsById : {}
    if (!lean) {
      for (var i = 0; i < list.length; i++) {
        var a = list[i]
        a.pinned = Model.isPinned(root.pins, a)
        byId[a.id] = a
      }
      root.apps = list
      root.appsById = byId
    }
    root.tickCount = root.tickCount + 1
    root.lastTickMs = data.t || Date.now()

    if (Array.isArray(data.events) && data.events.length) {
      for (var j = 0; j < data.events.length; j++) {
        var ev = data.events[j]
        root.recentActions = root.recentActions.concat([ev]).slice(-5)
        root.actionFinished(ev)
      }
    }
    root.ticked()
  }

  // ---- Commands ----------------------------------------------------------

  function requestDetail(appId) { send("detail " + (appId || "-")) }

  function stopApp(app)    { if (app && !app.readOnly) send("stop " + app.id) }
  function pauseApp(app)   { if (app && !app.readOnly) send("pause " + app.id) }
  function resumeApp(app)  { if (app && !app.readOnly) send("resume " + app.id) }
  function restartApp(app) { if (app && app.kind === "service") send("restart " + app.id) }
  function togglePause(app) {
    if (!app) return
    if (app.state === "paused") resumeApp(app)
    else pauseApp(app)
  }

  function togglePin(app) {
    if (!app) return
    var key = Model.pinKey(app)
    var next = []
    var found = false
    for (var i = 0; i < root.pins.length; i++) {
      if (root.pins[i] === key) { found = true; continue }
      next.push(root.pins[i])
    }
    if (!found) next.push(key)
    root.pins = next
    // Re-stamp the live list so rows update without waiting a tick.
    var list = root.apps.slice()
    for (var j = 0; j < list.length; j++) list[j].pinned = Model.isPinned(root.pins, list[j])
    root.apps = list
    root.saveState()
  }

  // ---- Persisted state (pins) -------------------------------------------

  property bool stateLoaded: false

  FileView {
    id: stateFile
    path: root.stateFilePath
    printErrors: false
    blockLoading: false
    onLoaded: {
      try {
        var parsed = JSON.parse(stateFile.text())
        if (parsed && Array.isArray(parsed.pins)) root.pins = parsed.pins
      } catch (e) {}
      root.stateLoaded = true
    }
    onLoadFailed: root.stateLoaded = true
  }

  Process {
    id: stateWriter
    running: false
  }

  function saveState() {
    var payload = JSON.stringify({ version: 1, pins: root.pins })
    stateWriter.command = ["bash", "-c",
      "mkdir -p " + Util.shellQuote(root.stateDir) + " && printf '%s' " + Util.shellQuote(payload)
      + " > " + Util.shellQuote(root.stateFilePath)]
    stateWriter.running = true
  }

  Component.onCompleted: startSampler()
  Component.onDestruction: stopSampler()
}
