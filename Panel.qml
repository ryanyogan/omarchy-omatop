import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "ui"

// A compact dot-matrix monitor: live readings, recent activity,
// and supporting readings. All live data disconnects on close.
Panel {
  id: root
  moduleName: "ryanyogan.omatop"
  // The shell's `toggle ryanyogan.omatop` routes to the overlay (multi-kind
  // plugin), so the dropdown answers on its own target:
  //   omarchy-shell ryanyogan.omatop toggle
  ipcTarget: "ryanyogan.omatop"

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root

  // ---------------------------------------------------------------- lifecycle

  // The sample rate is refcounted in the service, so a close must answer
  // exactly one open, no matter who closed us (key, outside click, popout
  // switch, hotkey). Driving it off `opened` is the only place that sees
  // all of them.
  property bool surfaceCounted: false

  // Backstop for teardown without a close (shell reload, plugin disable):
  // answer the open we counted or the sampler's refcount drifts for good.
  Component.onDestruction: {
    if (surfaceCounted && service) service.panelClosed()
  }

  onOpenedChanged: {
    if (!root.opened) dotClock.stop()
    if (root.opened) {
      if (!root.surfaceCounted && root.service) {
        root.service.panelOpened()
        root.surfaceCounted = true
      }
    } else if (root.surfaceCounted) {
      if (root.service) root.service.panelClosed()
      root.surfaceCounted = false
    }
  }

  function open() {
    root.controller.show()
    Qt.callLater(function() { root.focusKeys() })
  }

  function openFromHotkey() { open() }

  function close() { root.controller.hide() }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function focusKeys() { keyCatcher.forceActiveFocus() }

  function openOverlay() {
    if (root.bar && root.bar.shell) {
      root.close()
      root.bar.shell.toggle(root.moduleName, "{}")
    }
  }

  function buildSampler() {
    if (root.service && root.service.buildSampler) root.service.buildSampler()
  }

  // Only repaint during the brief dot fades. Sharing one 25 Hz clock avoids
  // a separate display-rate animation on every cell and synchronizes matrices.
  property double dotFrameMs: 0
  property double dotFadeUntil: 0
  function animateDots() {
    if (!root.opened) return
    dotFadeUntil = Date.now() + 180
    if (!dotClock.running) dotClock.start()
  }
  Timer {
    id: dotClock
    interval: 40
    repeat: true
    onTriggered: {
      root.dotFrameMs = Date.now()
      if (root.dotFrameMs >= root.dotFadeUntil) stop()
    }
  }

  // ---------------------------------------------------------------- theming

  // This sits on the bar's popup surface, so every colour is the theme's.
  readonly property color ink: root.bar ? root.bar.foreground : Color.foreground
  // Bar active colour may be neutral; warnings use the same role as the overlay.
  readonly property color urgent: Color.urgent
  readonly property color dim: Qt.darker(ink, 1.5)
  readonly property color faint: Util.alpha(ink, 0.60)
  readonly property color hairline: Util.alpha(ink, 0.12)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- state

  // The quick view updates together at 2 Hz, without a continuous render clock.
  readonly property bool animated: false
  readonly property string samplerState: root.service ? String(root.service.samplerState || "starting") : "starting"
  readonly property bool running: samplerState === "running"
  readonly property bool canBuild: !!(root.service && root.service.canBuildSampler)

  // Everything below reads through these snapshots, and they are empty while the
  // dropdown is closed, so a closed dropdown re-evaluates nothing on a tick.
  readonly property var vitals: root.opened && root.service ? root.service.vitals : null
  readonly property var history: root.opened && root.service ? root.service.history : null
  readonly property string culprit: root.service ? String(root.service.culprit || "") : ""

  readonly property string pressureLevel:
    root.service && root.service.pressure ? String(root.service.pressure.level || "calm") : "calm"
  readonly property string pressureReason:
    root.service && root.service.pressure ? String(root.service.pressure.reason || "") : ""
  readonly property color pressureColor: Model.pressureColor(root.pressureLevel, root.ink, root.urgent)

  // ---- Vitals -------------------------------------------------------------

  readonly property real cpuNow: vitals && vitals.cpu ? Number(vitals.cpu.total) || 0 : -1
  readonly property real cpuTemp: vitals && vitals.cpu ? Number(vitals.cpu.temp) || 0 : 0
  readonly property real memTotal: vitals && vitals.mem ? Number(vitals.mem.total) || 0 : 0
  readonly property real memUsed: vitals && vitals.mem ? Number(vitals.mem.used) || 0 : 0
  // The small-caps status line under the name: the sampler's state while it
  // isn't running, then the culprit while the machine is under Pressure (the
  // sampler names none when calm, so a quiet machine never accuses whatever
  // is idling on top), otherwise uptime. The Pressure reason rides along in
  // the sampler's own words when there is one.
  readonly property string headline: {
    if (samplerState === "missing") return "Sampler not built"
    if (samplerState === "building") return "Building the sampler…"
    if (samplerState === "buildFailed") return "Build failed"
    if (samplerState === "crashed") return "Sampler restarting"
    if (!running || !vitals) return "Starting…"
    var bits = []
    var id = root.culprit
    var app = id !== "" && root.service && root.service.appsById ? root.service.appsById[id] : null
    if (app) {
      var figure = Number(app.cpu) >= 1 ? Model.pct(app.cpu, 0) : Model.bytes(app.mem)
      bits.push(String(app.name || "") + " " + figure)
    } else if (Number(vitals.uptime) > 0) {
      bits.push("up " + Model.age(0, Number(vitals.uptime) * 1000))
    }
    if (root.pressureLevel !== "calm" && root.pressureReason !== "") bits.push(root.pressureReason)
    return bits.length ? bits.join("  ·  ") : "System"
  }
  readonly property real memNow: memTotal > 0 ? memUsed / memTotal * 100 : -1
  readonly property real gpuNow: vitals && vitals.gpu ? Number(vitals.gpu.busy) || 0 : -1

  readonly property bool gpuAvailable: !!(running && vitals && vitals.gpu && vitals.gpu.available === true)
  readonly property bool tempAvailable: !!(running && cpuTemp > 0)

  readonly property var cpuSeries: history && history.cpu ? history.cpu : []
  // history.mem is already a percent of total (sampler protocol).
  readonly property var memSeries: history && history.mem ? history.mem : []

  // Binary units match the sampler's byte counters, including honest zeros.
  function byteText(value) {
    var n = Number(value)
    if (!isFinite(n) || n < 0) return "--"
    var units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var unit = 0
    while (n >= 1024 && unit < units.length - 1) { n /= 1024; unit++ }
    return (unit === 0 ? String(Math.round(n)) : n.toFixed(n >= 100 ? 0 : n >= 10 ? 1 : 2)) + " " + units[unit]
  }

  // Supporting rows share two aligned value columns and explicit captions.
  readonly property var supportingStats: {
    var v = root.vitals
    if (!root.running || !v) return {}
    var facts = {}
    function rate(n) { return root.byteText(n) + "/s" }
    if (v.net) facts.network = {label: "Network", rows: [["Download", rate(v.net.rx)], ["Upload", rate(v.net.tx)]]}
    if (v.disk) facts.disk = {label: "Disk I/O", rows: [["Read", rate(v.disk.read)], ["Write", rate(v.disk.write)]]}
    if (v.mem && v.mem.swapTotal > 0)
      facts.swap = {label: "Swap", rows: [["Used", root.byteText(v.mem.swapUsed)], ["Total", root.byteText(v.mem.swapTotal)]]}
    if (v.fan && v.fan.available)
      facts.cooling = {label: "Fan speed", rows: [["Speed", Math.round(v.fan.rpm) + " rpm"]]}
    return facts
  }

  // ---- Sampler state card -------------------------------------------------

  function logTail(count) {
    var raw = root.service ? String(root.service.buildLog || "") : ""
    var lines = raw.split("\n").filter(function(line) { return line.trim() !== "" })
    return lines.slice(-count).join("\n")
  }

  // ---------------------------------------------------------------- frame

  readonly property real panelWidth: Style.space(456)

  KeyboardPanel {
    id: panel
    padding: Style.space(16)
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(800))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) {
        if (dy) scroll.contentY = Math.max(0, Math.min(Math.max(0, scroll.contentHeight - scroll.height), scroll.contentY + dy * Style.space(24)))
      }
      onTabRequested: function(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
          root.bar.switchPanelFrom(root.barIdentity, direction)
      }
      onActivateRequested: root.openOverlay()
      onTextKey: function(t) {
        if (t === "o" || t === "O") root.openOverlay()
        else if ((t === "b" || t === "B") && root.canBuild) root.buildSampler()
        else if ((t === "a" || t === "A") && !root.running) setup.about = !setup.about
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: parent.width
          spacing: Style.space(16)

          // ------------------------------------------------------- header

          // Same shape as the HEY plugin's header (and Hydrate's, and Omaday's):
          // mark, name, a small-caps status line, and the Pressure chip pinned
          // to the trailing edge.
          Item {
            id: heroItem
            width: parent.width
            height: hero.implicitHeight

            // Inside the Component blocks below, PanelHero's internal `id: root`
            // shadows the panel's; all panel state goes through this handle.
            readonly property var omatop: root

            PanelHero {
              id: hero
              width: parent.width
              title: "Omatop"
              meta: root.headline
              foreground: root.ink
              fontFamily: root.fontFamily
              iconComponent: Component {
                ChipIcon {
                  iconSize: Style.font.display
                  tint: heroItem.omatop.running ? heroItem.omatop.pressureColor : heroItem.omatop.ink
                  opacity: heroItem.omatop.running ? 1 : 0.6
                  Behavior on tint {
                    enabled: heroItem.omatop.animated
                    ColorAnimation { duration: 300 }
                  }
                }
              }
              trailingControl: Component {
                // The Pressure chip: a tinted wash of the level's own hue, so a
                // calm machine keeps the theme's foreground and a loaded one
                // warms without shouting.
                Rectangle {
                  id: chip
                  readonly property var omatop: heroItem.omatop
                  visible: omatop.running
                  height: Style.space(18)
                  width: visible
                    ? Style.space(7) + pressureDot.width + Style.space(6)
                      + Math.ceil(pressureLabel.implicitWidth) + Style.space(8)
                    : 0
                  radius: height / 2
                  color: Util.alpha(omatop.pressureColor, 0.12)
                  border.width: 1
                  border.color: Util.alpha(omatop.pressureColor, 0.35)

                  Behavior on color {
                    enabled: chip.omatop.animated
                    ColorAnimation { duration: 300 }
                  }
                  Behavior on border.color {
                    enabled: chip.omatop.animated
                    ColorAnimation { duration: 300 }
                  }

                  Rectangle {
                    id: pressureDot
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(7)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(6)
                    height: width
                    radius: width / 2
                    color: chip.omatop.pressureColor

                    Behavior on color {
                      enabled: chip.omatop.animated
                      ColorAnimation { duration: 300 }
                    }
                  }

                  Text {
                    id: pressureLabel
                    anchors.left: pressureDot.right
                    anchors.leftMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.pressureLabel(chip.omatop.pressureLevel)
                    color: chip.omatop.pressureColor
                    textFormat: Text.PlainText
                    font.family: chip.omatop.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.2
                    font.capitalization: Font.AllUppercase

                    Behavior on color {
                      enabled: chip.omatop.animated
                      ColorAnimation { duration: 300 }
                    }
                  }
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.ink }

          SamplerNotice {
            width: parent.width
            visible: root.running && !!(root.service && root.service.samplerUpdateAvailable)
            version: root.service ? root.service.requiredSamplerVersion : ""
            ink: root.ink
            fontFamily: root.fontFamily
            onUpdate: root.buildSampler()
          }

          // ------------------------------------------------------- vitals

          Column {
            id: instruments
            width: parent.width
            spacing: Style.space(12)
            visible: root.running

            Item {
              width: parent.width
              height: Style.space(14)
              Text {
                text: "Recent activity"
                color: root.faint; font.family: root.fontFamily
                font.pixelSize: Style.font.caption; font.bold: true
                font.capitalization: Font.AllUppercase; font.letterSpacing: 1
              }
              Text {
                anchors.right: parent.right
                text: "LIVE · 0.5s"
                color: Color.accent; font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MetricRow {
              label: "CPU"
              reading: root.cpuNow >= 0 ? Model.pct(root.cpuNow) : "--"
              detail: root.tempAvailable ? Model.temp(root.cpuTemp) + "C  ·  utilization" : "utilization"
              detailColor: root.cpuTemp >= 90 ? root.urgent : root.faint
              samples: root.cpuSeries
              tint: root.pressureLevel === "calm" ? Color.accent : root.pressureColor
            }
            MetricRow {
              label: "Memory"
              reading: root.memTotal > 0 ? root.byteText(root.memUsed) : "--"
              detail: root.memTotal > 0 ? "of " + root.byteText(root.memTotal) + " · " + Model.pct(root.memNow, 0) : "unavailable"
              samples: root.memSeries
              tint: root.ink
            }
            MetricRow {
              visible: root.gpuAvailable
              label: "GPU"
              reading: Model.pct(root.gpuNow)
              detail: root.vitals && root.vitals.gpu && root.vitals.gpu.temp > 0 ? Model.temp(root.vitals.gpu.temp) + "C  ·  utilization" : "utilization"
              samples: root.history && root.history.gpu ? root.history.gpu : []
              tint: Color.accent
            }

            Item {
              width: parent.width
              height: Style.space(12)
              Text {
                text: "Recent peaks · oldest → newest"
                color: root.faint; font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                anchors.right: parent.right
                text: "0–100%"
                color: root.faint; font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(8)
              readonly property var cores: root.vitals && root.vitals.cpu ? root.vitals.cpu.cores || [] : []
              visible: cores.length > 0
              Rectangle { width: parent.width; height: 1; color: root.hairline }
              Item {
                width: parent.width; height: Style.space(14)
                Text {
                  text: "Per-core activity"
                  color: root.faint; font.family: root.fontFamily
                  font.pixelSize: Style.font.caption; font.bold: true
                  font.capitalization: Font.AllUppercase; font.letterSpacing: 1
                }
                Text {
                  anchors.right: parent.right
                  text: parent.parent.cores.length + " cores"
                  color: root.faint; font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
              DotMatrix {
                width: parent.width; height: Style.space(24)
                values: parent.cores; history: false; rows: 5
                ink: Color.accent; track: Util.alpha(root.ink, 0.06)
                animated: root.opened && root.service && !root.service.reducedMotion
                frameTime: root.dotFrameMs
                onFadeRequested: root.animateDots()
              }
            }

            Column {
              width: parent.width
              spacing: 0
              Repeater {
                // Stable keys retain the rows and their text across ticks.
                model: ["network", "disk", "swap", "cooling"]
                delegate: Item {
                  id: stat
                  required property string modelData
                  readonly property var fact: root.supportingStats[modelData] || null
                  readonly property bool single: fact !== null && fact.rows.length === 1
                  visible: fact !== null
                  width: parent.width
                  height: Style.space(48)

                  Rectangle { width: parent.width; height: 1; color: root.hairline }
                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: stat.fact ? stat.fact.label : ""
                    color: root.ink; font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    textFormat: Text.PlainText
                  }
                  Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(112)
                    height: Style.space(32)
                    spacing: Style.space(16)
                    Repeater {
                      model: 2
                      Item {
                        required property int index
                        readonly property var reading: !stat.fact ? null
                          : stat.single ? (index === 1 ? stat.fact.rows[0] : null) : stat.fact.rows[index]
                        width: (parent.width - parent.spacing) / 2
                        height: parent.height
                        Text {
                          anchors.right: parent.right
                          y: stat.single ? Math.round((parent.height - height) / 2) : 0
                          text: parent.reading ? parent.reading[1] : ""
                          color: root.ink; font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          textFormat: Text.PlainText
                        }
                        Text {
                          anchors.right: parent.right
                          anchors.bottom: parent.bottom
                          visible: !stat.single
                          text: parent.reading ? parent.reading[0] : ""
                          color: root.faint; font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          textFormat: Text.PlainText
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // ------------------------------------------------------- sampler state

          // The front door: what the sampler is and a button to build it.
          SetupCard {
            id: setup
            width: parent.width
            visible: !root.running
            compact: true
            state: root.samplerState
            logTail: root.samplerState === "building" ? root.logTail(3) : root.samplerState === "buildFailed" ? root.logTail(6) : ""
            ink: root.ink; dim: root.dim; faint: root.faint; hairline: root.hairline
            accent: Color.accent; urgent: root.urgent
            fontFamily: root.fontFamily; animated: root.animated
            onBuild: root.buildSampler()
          }

          // ------------------------------------------------------- footer

          Rectangle {
            width: parent.width
            height: Style.space(28)
            color: footerMouse.containsMouse ? Util.alpha(root.ink, 0.04) : "transparent"
            Accessible.role: Accessible.Button
            Accessible.name: "Open full monitor"
            Accessible.onPressAction: root.openOverlay()

            Rectangle { width: parent.width; height: 1; color: root.hairline }

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Full monitor"
              color: footerMouse.containsMouse ? Color.accent : root.ink
              font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
            }
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "O / Enter  ↗"
              color: root.faint
              font.family: root.fontFamily; font.pixelSize: Style.font.caption
            }
            MouseArea {
              id: footerMouse
              anchors.fill: parent
              hoverEnabled: true; cursorShape: Qt.PointingHandCursor
              onClicked: root.openOverlay()
            }
          }
        }
      }
    }
  }

  component MetricRow: Item {
    id: metric
    property string label: ""
    property string reading: ""
    property string detail: ""
    property color detailColor: root.faint
    property var samples: []
    property color tint: Color.accent
    width: parent.width
    height: Style.space(60)

    Column {
      width: Style.space(152)
      spacing: Style.space(4)
      Text {
        text: metric.label
        color: root.faint; font.family: root.fontFamily
        font.pixelSize: Style.font.caption; font.bold: true
        font.capitalization: Font.AllUppercase; font.letterSpacing: 1
      }
      Text {
        text: metric.reading
        color: root.ink; font.family: root.fontFamily
        font.pixelSize: Style.font.display; font.weight: Font.DemiBold
      }
      Text {
        width: parent.width
        text: metric.detail
        color: metric.detailColor; font.family: root.fontFamily
        font.pixelSize: Style.font.caption; elide: Text.ElideRight
      }
    }
    DotMatrix {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, parent.width - Style.space(168))
      height: Style.space(44)
      values: metric.samples
      ink: metric.tint; track: Util.alpha(root.ink, 0.06)
      animated: root.opened && root.service && !root.service.reducedMotion
      frameTime: root.dotFrameMs
      onFadeRequested: root.animateDots()
    }
  }

}
