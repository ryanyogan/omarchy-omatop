import QtQuick
import Quickshell
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

  readonly property var nowMs: service ? service.lastTickMs : 0
  readonly property bool live: service && service.samplerState === "running"
  readonly property bool animated: !(service && service.reducedMotion)
  readonly property real tickMs: service ? 1000 / service.rate : 5000
  readonly property var cursorApp: {
    if (cursorIndex < 0 || cursorIndex >= rows.count) return null
    var row = rows.get(cursorIndex)
    if (!row || row.type !== "app") return null
    return service ? service.appsById[row.appId] || null : null
  }
  readonly property var detailApp: service && detailId ? (service.appsById[detailId] || null) : null
  readonly property bool showGpu: service && service.vitals && service.vitals.gpu && service.vitals.gpu.available === true

  // ---- Palette -------------------------------------------------------------
  // No card: the cluster floats on a deep scrim, like the speed test overlay.
  // Text and ticks on that scrim use a fixed light palette; the accent and
  // the Pressure hues still come from the theme.
  readonly property color ink: "white"
  readonly property color dim: Qt.rgba(1, 1, 1, 0.55)
  readonly property color faint: Qt.rgba(1, 1, 1, 0.32)
  readonly property color hairline: Qt.rgba(1, 1, 1, 0.10)
  readonly property color accent: Color.accent
  readonly property color urgent: "#ff6b6b"
  readonly property color selectedBackground: Qt.rgba(1, 1, 1, 0.08)
  readonly property color pressureColor: Model.pressureColor(service ? service.pressure.level : "calm", accent, urgent)
  readonly property string fontFamily: Style.font.family

  // What the cluster is pointed at: the machine, or the focused App.
  readonly property real memTotal: service && service.vitals ? Number(service.vitals.mem.total) || 0 : 0
  readonly property real clusterCpu: detailApp ? detailApp.cpu : (service && service.vitals ? service.vitals.cpu.total : 0)
  readonly property real clusterMem: detailApp ? (memTotal > 0 ? detailApp.mem / memTotal * 100 : 0) : (service && service.vitals && memTotal > 0 ? service.vitals.mem.used / memTotal * 100 : 0)
  readonly property real clusterGpu: detailApp ? Math.max(0, detailApp.gpu) : (service && service.vitals && service.vitals.gpu ? service.vitals.gpu.busy : 0)
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
    mode = "normal"
    pending = ""
    countBuffer = ""
    scrub = -1
    toast = ""
    if (service) {
      service.surfaceOpened()
      if (service.samplerState === "missing") service.startSampler()
    }
    forceReorder = true
    rebuild()
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
    if (service) {
      service.surfaceClosed()
      service.requestDetail("")
    }
    detailId = ""
    confirmApp = null
    mode = "normal"
    // The shell destroys this overlay on hide (keepLoaded is false). Ask the
    // JS engine to collect what it left behind rather than keeping it around.
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
    var desired = Model.sections(service.apps, service.offenders, service.pins, filter, sortKey, collapsed)
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
    function onTicked() { if (root.opened) root.rebuild() }
    function onActionFinished(ev) {
      if (!root.opened) return
      var name = root.service.appsById[ev.id] ? root.service.appsById[ev.id].name : ev.id
      root.toast = ev.ok ? (ev.action + ": " + name) : ("failed " + ev.action + ": " + (ev.error || "unknown"))
      toastTimer.restart()
    }
  }
  Timer { id: toastTimer; interval: 3000; onTriggered: root.toast = "" }

  onFilterChanged: { forceReorder = true; rebuild(); firstApp() }
  onSortKeyChanged: { forceReorder = true; rebuild() }
  onCollapsedChanged: { forceReorder = true; rebuild() }

  // ---- Cursor --------------------------------------------------------------
  function clampCursor() {
    if (rows.count === 0) { cursorIndex = 0; cursorKey = ""; return }
    cursorIndex = Util.clamp(cursorIndex, 0, rows.count - 1)
    cursorKey = rows.get(cursorIndex).key
  }

  function setCursor(i) {
    if (rows.count === 0) return
    cursorIndex = Util.clamp(i, 0, rows.count - 1)
    cursorKey = rows.get(cursorIndex).key
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

    // Deep scrim carries the contrast on any wallpaper.
    Rectangle {
      id: scrim
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.94)
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

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Omatop"
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
            SequentialAnimation on opacity {
              running: root.animated && root.service && root.service.pressure.level === "critical"
              loops: Animation.Infinite
              NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
              NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
            }
          }
          Text {
            text: root.service ? Model.pressureLabel(root.service.pressure.level) : "calm"
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
            visible: root.service && root.service.pressure.level !== "calm" && root.service.pressure.reason
            text: root.service ? root.service.pressure.reason : ""
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
              SequentialAnimation on opacity { running: root.mode === "search" && root.animated; loops: Animation.Infinite; NumberAnimation { to: 0; duration: 500 } NumberAnimation { to: 1; duration: 500 } }
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
            onScrim: root.ink; onScrimDim: root.dim; fontFamily: root.fontFamily; animated: root.animated
          }
          Dial {
            id: memDial
            diameter: cluster.dialSize
            label: root.clusterName ? root.clusterName + "  memory" : "memory"
            value: root.clusterMem
            fullScale: 100
            readout: root.detailApp ? Model.bytes(root.detailApp.mem) : (root.service && root.service.vitals ? Model.bytes(root.service.vitals.mem.used) : "--")
            sublabel: "of " + Model.bytes(root.memTotal)
            accent: root.accent
            onScrim: root.ink; onScrimDim: root.dim; fontFamily: root.fontFamily; animated: root.animated
          }
          Dial {
            id: gpuDial
            diameter: cluster.dialSize
            visible: root.showGpu
            label: root.clusterName ? root.clusterName + "  gpu" : "gpu"
            value: root.clusterGpu
            fullScale: 100
            readout: root.detailApp && root.detailApp.gpu < 0 ? "--" : Model.pct(root.clusterGpu)
            unit: root.service && root.service.vitals && root.service.vitals.gpu ? Model.temp(root.service.vitals.gpu.temp) + " gpu" : "%"
            engaged: !root.detailApp || root.detailApp.gpu >= 0
            accent: root.accent
            onScrim: root.ink; onScrimDim: root.dim; fontFamily: root.fontFamily; animated: root.animated
          }
          Dial {
            id: tempDial
            diameter: cluster.dialSize
            label: "temp"
            value: root.service && root.service.vitals ? root.service.vitals.cpu.temp : 0
            fullScale: 100
            readout: root.service && root.service.vitals ? Model.temp(root.service.vitals.cpu.temp) : "--"
            unit: root.service && root.service.vitals && root.service.vitals.fan && root.service.vitals.fan.available && root.service.vitals.fan.rpm > 0 ? root.service.vitals.fan.rpm + " rpm" : "cpu"
            engaged: root.service && root.service.vitals && root.service.vitals.cpu.temp > 0
            accent: root.service && root.service.vitals && root.service.vitals.cpu.temp >= 90 ? root.urgent : root.accent
            onScrim: root.ink; onScrimDim: root.dim; fontFamily: root.fontFamily; animated: root.animated
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
        readonly property var v: root.service ? root.service.vitals : null

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
          readonly property var v: root.service ? root.service.vitals : null
          readonly property var h: root.service ? root.service.history : null
          readonly property bool compactStrips: root.detailId !== ""

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onPositionChanged: function(mouse) {
              if (mouse.y > strips.height) { root.scrub = -1; return }
              root.scrub = Math.round(Math.max(0, Math.min(1, mouse.x / width)) * 119)
            }
            onExited: root.scrub = -1
          }

          // Strips share the ledger height equally (the detail strips take a
          // fixed slice when an App is focused), so the graphs use every
          // pixel the screen offers.
          readonly property int axisHeight: Style.space(16)
          readonly property int stripCount: 5 + (root.showGpu ? 1 : 0) + (ledger.v && ledger.v.power && ledger.v.power.available ? 1 : 0)
          readonly property real detailSlice: root.detailApp ? Math.min(height * 0.45, Style.space(340)) : 0
          readonly property real stripHeight: Math.max(Style.space(34), (height - axisHeight - detailSlice - Style.space(10) * stripCount) / stripCount)

          Column {
            id: strips
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Style.space(14)

            Strip { width: strips.width; height: ledger.stripHeight; label: "cpu"; maxValue: 100
              samples: ledger.h ? ledger.h.cpu : []; valueText: ledger.v ? Model.pct(ledger.v.cpu.total) : "--"
              formatter: function(x) { return Model.pct(x) }
              ink: root.ink; line: root.pressureColor; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated
              Behavior on line { enabled: root.animated; ColorAnimation { duration: 300 } } }
            Strip { width: strips.width; height: ledger.stripHeight; label: "memory"; maxValue: 100
              samples: ledger.h ? ledger.h.mem : []; valueText: ledger.v ? Model.bytes(ledger.v.mem.used) + "  " + Model.pct(root.clusterMem) : "--"
              formatter: function(x) { return Model.pct(x) }
              ink: root.ink; line: root.accent; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated }
            Strip { width: strips.width; height: ledger.stripHeight; visible: root.showGpu; label: "gpu"; maxValue: 100
              samples: ledger.h ? ledger.h.gpu : []; valueText: ledger.v && ledger.v.gpu ? Model.pct(ledger.v.gpu.busy) : "--"
              formatter: function(x) { return Model.pct(x) }
              ink: root.ink; line: root.accent; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated }
            Strip { width: strips.width; height: ledger.stripHeight; label: "temperature"; maxValue: 100; available: ledger.v && ledger.v.cpu.temp > 0
              samples: ledger.h ? ledger.h.temp : []; valueText: ledger.v ? Model.temp(ledger.v.cpu.temp) : "--"
              formatter: function(x) { return Model.temp(x) }
              ink: root.ink; line: ledger.v && ledger.v.cpu.temp >= 90 ? root.urgent : root.dim; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated }
            Strip { width: strips.width; height: ledger.stripHeight; label: "network"; maxValue: 0; floorValue: 1024 * 64
              samples: ledger.h ? ledger.h.netRx : []; valueText: ledger.v ? "↓ " + Model.bytes(ledger.v.net.rx) + "/s   ↑ " + Model.bytes(ledger.v.net.tx) + "/s" : "--"
              formatter: function(x) { return "↓ " + Model.bytes(x) + "/s" }
              ink: root.ink; line: root.dim; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated }
            Strip { width: strips.width; height: ledger.stripHeight; label: "disk"; maxValue: 0; floorValue: 1024 * 1024
              samples: ledger.h ? ledger.h.diskWrite : []; valueText: ledger.v ? "read " + Model.bytes(ledger.v.disk.read) + "/s   write " + Model.bytes(ledger.v.disk.write) + "/s" : "--"
              formatter: function(x) { return "write " + Model.bytes(x) + "/s" }
              ink: root.ink; line: root.dim; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated }
            Strip { width: strips.width; height: ledger.stripHeight; visible: ledger.v && ledger.v.power && ledger.v.power.available; label: "power"; maxValue: 0; floorValue: 30
              samples: ledger.h ? ledger.h.power : []; valueText: ledger.v && ledger.v.power ? Model.watts(ledger.v.power.watts) : "--"
              formatter: function(x) { return Model.watts(x) }
              ink: root.ink; line: root.dim; dim: root.dim; faint: root.faint; hairline: root.hairline
              fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated }

            Item {
              width: strips.width
              height: ledger.axisHeight
              readonly property string span: Model.span(119 * root.tickMs)
              readonly property string half: Model.span(60 * root.tickMs)
              Text { x: 0; y: Style.space(2); text: "-" + parent.span; color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text { x: strips.width / 2 - width / 2; y: Style.space(2); text: "-" + parent.half; color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
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
                  color: root.detailApp && root.service && root.detailApp.id === root.service.culprit ? root.pressureColor : root.ink
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
                ink: root.ink; line: root.accent; dim: root.dim; faint: root.faint; hairline: root.hairline
                fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated }
              Strip { width: parent.width; height: detailPane.stripHeight; label: "memory"; maxValue: 0; floorValue: 64 * 1024 * 1024
                samples: detailPane.d ? detailPane.d.mem : []; valueText: detailPane.app ? Model.bytes(detailPane.app.mem) : ""
                formatter: function(x) { return Model.bytes(x) }
                ink: root.ink; line: root.accent; dim: root.dim; faint: root.faint; hairline: root.hairline
                fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated }
              Strip { width: parent.width; height: detailPane.stripHeight; visible: root.showGpu && detailPane.app && detailPane.app.gpu >= 0; label: "gpu"; maxValue: 0; floorValue: 10
                samples: detailPane.d ? detailPane.d.gpu : []; valueText: detailPane.app ? Model.pct(detailPane.app.gpu) : ""
                formatter: function(x) { return Model.pct(x) }
                ink: root.ink; line: root.accent; dim: root.dim; faint: root.faint; hairline: root.hairline
                fontFamily: root.fontFamily; scrub: root.scrub; animated: root.animated }
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
              text: "Offenders are the top " + (root.service ? root.service.offenderCpuCount : 10) + " by average cpu and top " + (root.service ? root.service.offenderMemCount : 6) + " by memory over 30 s, listed alphabetically"
              color: root.faint; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            }
            Row {
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
              height: item ? item.implicitHeight : Style.space(36)

              Component {
                id: headerRow
                Item {
                  implicitHeight: Style.space(rowLoader.index === 0 ? 26 : 32)
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
                  app: root.service ? (rowLoader.section === "offenders" ? root.service.offenders.find(function(a) { return a.id === rowLoader.appId }) || null : root.service.appsById[rowLoader.appId] || null) : null
                  hasCursor: rowLoader.index === root.cursorIndex
                  isCulprit: root.service && root.service.culprit === rowLoader.appId
                  isDetail: root.detailId === rowLoader.appId
                  expanded: root.expanded[rowLoader.appId] === true
                  processes: root.service && root.service.processes[rowLoader.appId] ? root.service.processes[rowLoader.appId] : []
                  nowMs: root.nowMs
                  ink: root.ink; dim: root.dim; faint: root.faint; hairline: root.hairline
                  selectedBackground: root.selectedBackground; selectedText: root.ink
                  pressureColor: root.pressureColor
                  accent: root.accent
                  fontFamily: root.fontFamily
                  animated: root.animated
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
                      root.setCursor(rowLoader.index)
                    }
                    onClicked: function(mouse) {
                      root.setCursor(rowLoader.index)
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

        // Sampler state card
        Rectangle {
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(80), Style.space(520))
          height: stateColumn.implicitHeight + Style.space(36)
          radius: Style.space(10)
          color: Qt.rgba(0, 0, 0, 0.6)
          border.width: 1
          border.color: root.hairline
          visible: root.service && root.service.samplerState !== "running" && root.service.samplerState !== "starting"
          Column {
            id: stateColumn
            anchors.fill: parent
            anchors.margins: Style.space(18)
            spacing: Style.space(8)
            Text {
              text: {
                var s = root.service ? root.service.samplerState : ""
                if (s === "missing") return "The sampler is not built yet"
                if (s === "building") return "Building the sampler"
                if (s === "buildFailed") return "The sampler failed to build"
                if (s === "crashed") return "The sampler stopped, restarting"
                return ""
              }
              color: root.ink; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true
            }
            Text {
              width: parent.width
              wrapMode: Text.Wrap
              text: {
                var s = root.service ? root.service.samplerState : ""
                if (s === "missing") return "Omatop reads the system through a small Rust helper. Press b to build it with cargo. This takes about a minute and only happens once."
                if (s === "building") return "cargo build --release is running. The cluster lights up when it finishes."
                if (s === "buildFailed") return "Check that rustc and cargo are installed, then press b to try again."
                return ""
              }
              color: root.dim; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              visible: root.service && root.service.buildLog.length > 0
              text: root.service ? root.service.buildLog.split("\n").filter(function(l) { return l.length }).slice(-6).join("\n") : ""
              color: root.faint; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap
            }
          }
        }
      }

      // ---- Footer ----
      Item {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(18)
        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: root.toast.length ? root.toast
              : (root.mode === "search" ? "type to filter   enter keep   esc clear"
              : "j k move   tab section   enter focus   o processes   p pin   ss pause   x stop   / find   ? help")
          color: root.toast.length ? root.ink : root.faint
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: (root.countBuffer.length ? root.countBuffer + "  " : "") + (root.pending.length ? root.pending + "  " : "") + "sort " + root.sortKey
          color: root.faint
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        z: 10
        opened: root.mode === "confirm"
        message: root.confirmApp ? ("Stop " + root.confirmApp.name + "? " + root.confirmApp.nproc + (root.confirmApp.nproc === 1 ? " process" : " processes") + " will be terminated.") : ""
        confirmText: "Stop"
        background: Qt.rgba(0.06, 0.06, 0.06, 1)
        foreground: root.ink
        scrim: Qt.rgba(0, 0, 0, 0.5)
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
