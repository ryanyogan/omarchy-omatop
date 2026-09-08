import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "ui"

// A compact instrument cluster: sample-driven gauges, short history traces,
// supporting readings and pinned Apps. All live data disconnects on close.
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
    if (surfaceCounted && service) service.surfaceClosed()
  }

  onOpenedChanged: {
    if (root.opened) {
      if (!root.surfaceCounted && root.service) {
        root.service.surfaceOpened()
        root.surfaceCounted = true
      }
    } else if (root.surfaceCounted) {
      if (root.service) root.service.surfaceClosed()
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

  // ---------------------------------------------------------------- theming

  // This sits on the bar's popup surface, so every colour is the theme's.
  readonly property color ink: root.bar ? root.bar.foreground : Color.foreground
  // Bar active colour may be neutral; warnings use the same role as the overlay.
  readonly property color urgent: Color.urgent
  readonly property color dim: Qt.darker(ink, 1.5)
  readonly property color faint: Util.alpha(ink, 0.45)
  readonly property color hairline: Util.alpha(ink, 0.12)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- state

  // The quick view steps once per sample; no per-core or colour animations.
  readonly property bool animated: false
  readonly property string samplerState: root.service ? String(root.service.samplerState || "starting") : "starting"
  readonly property bool running: samplerState === "running"
  readonly property bool canBuild: samplerState === "missing" || samplerState === "buildFailed"

  // Everything below reads through these three, and they are empty while the
  // dropdown is closed, so a closed dropdown re-evaluates nothing on a tick.
  readonly property var vitals: root.opened && root.service ? root.service.vitals : null
  readonly property var history: root.opened && root.service ? root.service.history : null
  readonly property var apps: root.opened && root.service ? root.service.apps : []
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

  // Optional sensors never masquerade as zero. No extra polling is needed:
  // every fact comes from the same sampler tick as the gauges.
  readonly property var supportingStats: {
    var v = root.vitals
    if (!root.running || !v) return {}
    var facts = {}
    function rate(n) { return Model.bytes(n).trim() + "/s" }
    if (v.net) facts.network = {label: "Network", value: "↓ " + rate(v.net.rx) + "  ↑ " + rate(v.net.tx)}
    if (v.disk) facts.disk = {label: "Disk I/O", value: "R " + rate(v.disk.read) + "  W " + rate(v.disk.write)}
    if (root.gpuAvailable && v.gpu.vramTotal > 0)
      facts.vram = {label: "VRAM", value: Model.bytes(v.gpu.vramUsed).trim() + " / " + Model.bytes(v.gpu.vramTotal).trim()}
    if (v.mem && v.mem.swapTotal > 0)
      facts.swap = {label: "Swap", value: Model.bytes(v.mem.swapUsed).trim() + " / " + Model.bytes(v.mem.swapTotal).trim()}
    if (v.power && v.power.available) {
      var power = []
      if (v.power.watts > 0) power.push(Model.watts(v.power.watts))
      if (v.power.battery >= 0) power.push(Math.round(v.power.battery) + "%" + (v.power.charging ? " charging" : " battery"))
      if (power.length) facts.power = {label: "Power", value: power.join(" · ")}
    }
    if (v.fan && v.fan.available && v.fan.rpm > 0)
      facts.cooling = {label: "Cooling", value: Math.round(v.fan.rpm) + " rpm"}
    return facts
  }

  // ---- Apps ---------------------------------------------------------------

  readonly property var pinnedRows: Model.pinnedApps(root.apps)

  // ---- Sampler state card -------------------------------------------------

  function logTail(count) {
    var raw = root.service ? String(root.service.buildLog || "") : ""
    var lines = raw.split("\n").filter(function(line) { return line.trim() !== "" })
    return lines.slice(-count).join("\n")
  }

  // ---- Footer hints -------------------------------------------------------

  readonly property var hints: root.canBuild
    ? [["o", "full monitor"], ["b", "build"], ["a", "about"]]
    : [["o", "full monitor"]]

  // ---------------------------------------------------------------- metrics

  // Fixed columns so numerals never jitter as digits come and go.
  TextMetrics {
    id: appCpuMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    text: "100.0%"
  }

  TextMetrics {
    id: appMemMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    text: "1023M"
  }

  readonly property real cpuColumn: Math.ceil(appCpuMetrics.advanceWidth)
  readonly property real memColumn: Math.ceil(appMemMetrics.advanceWidth)

  readonly property real appRowHeight: Style.space(30)
  readonly property real appIconSize: Style.space(16)

  // ---------------------------------------------------------------- frame

  readonly property real panelWidth: Style.space(480)

  KeyboardPanel {
    id: panel
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
        if (dy) scroll.contentY = Math.max(0, Math.min(Math.max(0, scroll.contentHeight - scroll.height), scroll.contentY + dy * root.appRowHeight))
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
          spacing: Style.spacing.panelGap

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

          // ------------------------------------------------------- vitals

          Column {
            id: instruments
            width: parent.width
            spacing: Style.space(16)
            visible: root.running

            Row {
              id: gauges
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(12)
              readonly property real size: Math.min(Style.space(142), (instruments.width - spacing * (root.gpuAvailable ? 2 : 1)) / (root.gpuAvailable ? 3 : 2))

              Dial {
                diameter: gauges.size
                label: "cpu"
                value: Math.max(0, root.cpuNow)
                readout: root.cpuNow >= 0 ? Model.pct(root.cpuNow) : "--"
                sublabel: root.tempAvailable ? Model.temp(root.cpuTemp) + " cpu" : "utilization"
                sublabelColor: root.cpuTemp >= 90 ? root.urgent : root.faint
                accent: root.pressureLevel === "calm" ? Color.accent : root.pressureColor
                onScrim: root.ink; onScrimDim: root.faint
                fontFamily: root.fontFamily; animated: false
              }
              Dial {
                diameter: gauges.size
                label: "memory"
                value: Math.max(0, root.memNow)
                readout: root.memTotal > 0 ? Model.bytes(root.memUsed).trim() : "--"
                sublabel: "of " + Model.bytes(root.memTotal).trim()
                accent: Color.accent
                onScrim: root.ink; onScrimDim: root.faint
                fontFamily: root.fontFamily; animated: false
              }
              Dial {
                diameter: gauges.size
                visible: root.gpuAvailable
                label: "gpu"
                value: Math.max(0, root.gpuNow)
                readout: Model.pct(root.gpuNow)
                sublabel: root.vitals && root.vitals.gpu && root.vitals.gpu.temp > 0 ? Model.temp(root.vitals.gpu.temp) + " gpu" : "utilization"
                accent: Color.accent
                onScrim: root.ink; onScrimDim: root.faint
                fontFamily: root.fontFamily; animated: false
              }
            }

            CoreRow {
              width: parent.width
              cores: root.vitals && root.vitals.cpu ? root.vitals.cpu.cores || [] : []
              animated: false
              accent: Color.accent; faint: root.faint; track: root.hairline
              fontFamily: root.fontFamily
              blockHeight: Style.space(6); maxBlockWidth: Style.space(9)
            }

            Text {
              text: "History · 2 min"
              color: root.faint; font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.capitalization: Font.AllUppercase; font.letterSpacing: 1.5
            }

            Row {
              width: parent.width
              spacing: Style.space(18)
              Strip {
                width: (parent.width - parent.spacing) / 2; height: Style.space(44)
                label: "cpu"; samples: root.cpuSeries; maxValue: 100
                valueText: root.cpuNow >= 0 ? Model.pct(root.cpuNow) : "--"
                formatter: function(x) { return Model.pct(x) }
                axisFormatter: function(x) { return Math.round(x) + "%" }
                ink: root.ink; line: Color.accent; dim: root.dim; faint: root.faint; hairline: root.hairline
                fontFamily: root.fontFamily; animated: false; showAxis: true
              }
              Strip {
                width: (parent.width - parent.spacing) / 2; height: Style.space(44)
                label: "memory"; samples: root.memSeries; maxValue: 100
                valueText: root.memNow >= 0 ? Model.pct(root.memNow, 0) : "--"
                formatter: function(x) { return Model.pct(x) }
                axisFormatter: function(x) { return Math.round(x) + "%" }
                ink: root.ink; line: root.ink; dim: root.dim; faint: root.faint; hairline: root.hairline
                fontFamily: root.fontFamily; animated: false; showAxis: true
              }
            }

            Grid {
              width: parent.width
              columns: width >= Style.space(360) ? 2 : 1
              columnSpacing: Style.space(20)
              rowSpacing: Style.space(12)
              Repeater {
                // Fixed keys retain delegates across ticks, even as values change.
                model: ["network", "disk", "vram", "swap", "power", "cooling"]
                delegate: Column {
                  required property string modelData
                  readonly property var fact: root.supportingStats[modelData] || null
                  visible: fact !== null
                  width: (parent.width - parent.columnSpacing * (parent.columns - 1)) / parent.columns
                  spacing: Style.space(4)
                  Rectangle { width: parent.width; height: 1; color: root.hairline }
                  Text {
                    text: parent.fact ? parent.fact.label : ""
                    color: root.faint; font.family: root.fontFamily
                    font.pixelSize: Style.font.caption; font.bold: true
                    font.letterSpacing: 1.5; font.capitalization: Font.AllUppercase
                    textFormat: Text.PlainText
                  }
                  Text {
                    width: parent.width
                    text: parent.fact ? parent.fact.value : ""
                    color: root.ink
                    font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                    textFormat: Text.PlainText; elide: Text.ElideRight
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

          // ------------------------------------------------------- pinned

          // Nothing pinned means nothing here: an empty state would be a whole
          // section explaining its own absence.
          Column {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.running && root.pinnedRows.length > 0

            PanelSeparator { width: parent.width; foreground: root.ink }

            PanelSectionHeader {
              text: "Pinned"
              foreground: root.ink
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.pinnedRows

              PinnedRow {
                required property var modelData
                app: modelData
              }
            }
          }

          // ------------------------------------------------------- footer

          Item {
            width: parent.width
            height: Style.space(28)

            PanelSeparator {
              anchors.top: parent.top
              width: parent.width
              foreground: root.ink
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.verticalCenterOffset: Style.space(3)
              visible: root.running
              text: "Open cluster ↗"
              color: openCluster.containsMouse ? root.ink : Color.accent
              font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
              MouseArea {
                id: openCluster
                anchors.fill: parent; anchors.margins: -Style.space(4)
                hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: root.openOverlay()
              }
            }

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.verticalCenterOffset: Style.space(3)
              spacing: Style.space(14)

              Repeater {
                model: root.hints

                Row {
                  id: hint
                  required property var modelData
                  spacing: Style.space(6)

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.ceil(keyCap.implicitWidth) + Style.space(12)
                    height: Style.space(17)
                    radius: Style.space(4)
                    color: Util.alpha(root.ink, 0.07)
                    border.width: 1
                    border.color: root.hairline

                    Text {
                      id: keyCap
                      anchors.centerIn: parent
                      text: hint.modelData[0]
                      color: root.dim
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: hint.modelData[1]
                    color: root.faint
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // ================================================================ pinned row

  // A narrower cousin of ui/AppRow: themed icon (monogram tile when the theme
  // has none), name, then CPU and memory in fixed columns. No meters: at this
  // width the bars would be shorter than the numbers beside them.
  component PinnedRow: Item {
    id: prow

    property var app: null

    width: parent ? parent.width : 0
    height: root.appRowHeight

    readonly property bool isCulprit: !!(prow.app && root.culprit !== "" && prow.app.id === root.culprit)
    readonly property string iconSource: prow.app && prow.app.icon ? Quickshell.iconPath(prow.app.icon, true) : ""

    Item {
      id: iconSlot
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: root.appIconSize
      height: root.appIconSize

      Image {
        anchors.fill: parent
        source: prow.iconSource
        sourceSize.width: root.appIconSize
        sourceSize.height: root.appIconSize
        visible: prow.iconSource !== ""
        smooth: true
      }

      Rectangle {
        anchors.fill: parent
        radius: Style.space(4)
        visible: prow.iconSource === ""
        color: Util.alpha(root.ink, 0.08)
        border.width: 1
        border.color: root.hairline

        Text {
          anchors.centerIn: parent
          text: prow.app ? (prow.app.kind === "job" ? "›" : String(prow.app.name || "?").charAt(0).toUpperCase()) : ""
          color: root.dim
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    Text {
      id: prowMem
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: root.memColumn
      horizontalAlignment: Text.AlignRight
      text: prow.app ? Model.bytes(prow.app.mem) : ""
      color: root.dim
      textFormat: Text.PlainText
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: prowCpu
      anchors.right: prowMem.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      width: root.cpuColumn
      horizontalAlignment: Text.AlignRight
      text: prow.app ? Model.pct(prow.app.cpu) : ""
      color: root.ink
      textFormat: Text.PlainText
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      anchors.left: iconSlot.right
      anchors.leftMargin: Style.space(10)
      anchors.right: prowCpu.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      text: prow.app ? String(prow.app.name || "") : ""
      elide: Text.ElideRight
      color: prow.isCulprit ? root.pressureColor : root.ink
      textFormat: Text.PlainText
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.weight: prow.isCulprit ? Font.DemiBold : Font.Normal

      Behavior on color {
        enabled: root.animated
        ColorAnimation { duration: 300 }
      }
    }
  }
}
