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
  readonly property real refreshSeconds: Util.clamp(Number(widgetSetting("refreshSeconds", 1)) || 1, 1, 30)
  readonly property real rate: 1 / refreshSeconds
  readonly property bool reducedMotion: widgetSetting("reducedMotion", false) === true
  // Overlay reading cadence. Samples keep arriving at `rate` and feed the
  // timelines; the overlay's dials, readouts and list take a reading every
  // this many seconds and glide to it, so nothing there jumps once a second.
  readonly property real overlaySeconds: Util.clamp(Number(widgetSetting("overlaySeconds", 5)) || 5, 1, 30)
  // Overlay motion clock. Every frame the overlay produces costs the same
  // (about 3.5 ms of CPU on a 5K display, whatever moves in it), so this is
  // the whole cost of fluid motion. 30 and 20 divide both 60 and 120 Hz
  // exactly; 12 is a lighter tier; 0 steps once per reading like the bar and
  // dropdown. The overlay picks a tier at or below this from the core count.
  readonly property int motionHz: Util.clamp(Math.round(Number(widgetSetting("motionHz", 30))) || 0, 0, 60)

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

  // Rolling averages per App (30 s time constant) so "who is hurting the
  // machine" does not flicker with every sample. Keyed by App id.
  property var averages: ({})
  readonly property real averageTau: 30
  function updateAverages(list, dt) {
    var alpha = Math.min(1, dt / root.averageTau)
    var now = Date.now()
    var avg = root.averages
    for (var i = 0; i < list.length; i++) {
      var a = list[i]
      var e = avg[a.id]
      if (!e) avg[a.id] = { cpu: a.cpu, mem: a.mem, seen: now }
      else { e.cpu += (a.cpu - e.cpu) * alpha; e.mem += (a.mem - e.mem) * alpha; e.seen = now }
    }
    // Forget Apps not seen for five minutes.
    if (now - root.lastPrune > 60000) {
      for (var id in avg) if (now - avg[id].seen > 300000) delete avg[id]
      root.lastPrune = now
    }
    root.averages = avg
  }
  property double lastPrune: 0

  // Offenders: the Apps worth watching, chosen by average CPU and memory.
  // Membership is re-picked at most every 30 s (or when a surface opens), so
  // the panel is a stable set whose numbers update, not a list that jumps.
  property var offenders: []
  property var offenderIds: []
  property double lastPick: 0
  readonly property int offenderCpuCount: 10
  readonly property int offenderMemCount: 6
  function refreshOffenders(incoming, lean) {
    var now = Date.now()
    var pool = lean ? incoming : root.apps
    if (root.offenderIds.length === 0 || now - root.lastPick > 30000) {
      var cands = pool.filter(function(a) { return a.bucket !== "kernel" })
      var byCpu = cands.slice().sort(function(x, y) { return avgOf(y).cpu - avgOf(x).cpu })
      var byMem = cands.slice().sort(function(x, y) { return avgOf(y).mem - avgOf(x).mem })
      var ids = [], seen = {}
      var take = function(list, n) { for (var i = 0; i < list.length && n > 0; i++) { var id = list[i].id; if (!seen[id]) { seen[id] = true; ids.push(id); n-- } } }
      take(byCpu, root.offenderCpuCount)
      take(byMem, root.offenderMemCount)
      root.offenderIds = ids
      root.lastPick = now
    }
    var byIdNow = {}
    for (var k = 0; k < incoming.length; k++) byIdNow[incoming[k].id] = incoming[k]
    var out = []
    for (var j = 0; j < root.offenderIds.length; j++) {
      var id2 = root.offenderIds[j]
      var app = byIdNow[id2] || root.appsById[id2]
      if (!app) continue
      var av = avgOf(app)
      app.avgCpu = av.cpu
      app.avgMem = av.mem
      app.pinned = Model.isPinned(root.pins, app)
      out.push(app)
    }
    out.sort(Model.byName)
    root.offenders = out
  }
  function avgOf(a) { var e = root.averages[a.id]; return e ? e : { cpu: a.cpu, mem: a.mem } }
  function repickOffenders() { root.lastPick = 0; root.refreshOffenders(root.apps, false) }

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

  function surfaceOpened() { root.openSurfaces = root.openSurfaces + 1; root.repickOffenders() }
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

    // Lean ticks carry only the offenders (top CPU and memory). Keep the last
    // full App list for the surfaces, but feed every tick into the averages.
    var lean = data.lean === true
    var incoming = Array.isArray(data.apps) ? data.apps : []
    root.updateAverages(incoming, Number(data.interval) || 1)
    if (!lean) {
      var byId = {}
      for (var i = 0; i < incoming.length; i++) {
        var a = incoming[i]
        a.pinned = Model.isPinned(root.pins, a)
        a.avgCpu = root.averages[a.id] ? root.averages[a.id].cpu : a.cpu
        a.avgMem = root.averages[a.id] ? root.averages[a.id].mem : a.mem
        byId[a.id] = a
      }
      root.apps = incoming
      root.appsById = byId
    }
    root.refreshOffenders(incoming, lean)
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
    if (!key || key.length > root.maxPinKeyLength) return
    var next = []
    var found = false
    for (var i = 0; i < root.pins.length; i++) {
      if (root.pins[i] === key) { found = true; continue }
      next.push(root.pins[i])
    }
    if (!found) {
      if (next.length >= root.maxPins) return
      next.push(key)
    }
    root.pins = next
    // Re-stamp the live list so rows update without waiting a tick.
    var list = root.apps.slice()
    for (var j = 0; j < list.length; j++) list[j].pinned = Model.isPinned(root.pins, list[j])
    root.apps = list
    root.saveState()
  }

  // ---- Persisted state (pins) -------------------------------------------

  property bool stateLoaded: false
  property bool saveQueued: false
  readonly property int maxStateBytes: 16384
  readonly property int maxPins: 64
  readonly property int maxPinKeyLength: 256

  // Keep only plausible pin keys: strings, bounded length, bounded count.
  function sanitizePins(list) {
    var out = []
    for (var i = 0; i < list.length && out.length < root.maxPins; i++) {
      var p = list[i]
      if (typeof p !== "string" || p.length === 0 || p.length > root.maxPinKeyLength) continue
      if (out.indexOf(p) !== -1) continue
      out.push(p)
    }
    return out
  }

  // The state file lives in a user-writable directory, so treat it as hostile:
  // refuse symlinks, open read-write so a planted FIFO cannot block the shell,
  // check the type of the descriptor we actually opened, and read at most
  // maxStateBytes. The path travels as an argument, never spliced into the
  // script.
  Process {
    id: stateReader
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          if (parsed && Array.isArray(parsed.pins)) root.pins = root.sanitizePins(parsed.pins)
        } catch (e) {}
        root.stateLoaded = true
      }
    }
  }

  function loadState() {
    stateReader.command = ["bash", "-c",
      'f="$0"; [ -e "$f" ] || exit 0; [ -L "$f" ] && exit 1; exec 3<>"$f" || exit 1; '
      + '[ "$(stat -Lc %F /proc/self/fd/3)" = "regular file" ] || exit 1; '
      + 'head -c ' + root.maxStateBytes + ' <&3',
      root.stateFilePath]
    stateReader.running = true
  }

  Process {
    id: stateWriter
    running: false
    onExited: function(code, status) {
      if (root.saveQueued) { root.saveQueued = false; root.saveState() }
    }
  }

  // Writes go to an exclusively created random sibling (mktemp, 0600) and land
  // with an atomic rename, so a planted symlink at the destination is replaced
  // rather than followed and readers never see a partial file.
  function saveState() {
    if (stateWriter.running) { root.saveQueued = true; return }
    var payload = JSON.stringify({ version: 1, pins: root.sanitizePins(root.pins) })
    stateWriter.command = ["bash", "-c",
      'mkdir -p "$0" && tmp=$(mktemp "$0/.omatop.XXXXXXXX") && printf \'%s\' "$2" > "$tmp" '
      + '&& mv -f "$tmp" "$1" || { rm -f "$tmp"; exit 1; }',
      root.stateDir, root.stateFilePath, payload]
    stateWriter.running = true
  }

  Component.onCompleted: { loadState(); startSampler() }
  Component.onDestruction: stopSampler()
}
