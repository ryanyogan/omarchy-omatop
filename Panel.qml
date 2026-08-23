import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The dropdown: a fixed-width popout anchored to the bar mark. Top to bottom —
// Pressure header, the Vitals with two minutes of history each, Pinned Apps,
// the Top three, and a hint line pointing at the full overlay.
//
// Everything here is a reader of Service.qml. The only things it sends back
// are surfaceOpened/surfaceClosed (which drive the sample rate) and a build
// request when the sampler binary isn't there yet.
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
  // exactly one open — no matter who closed us (key, outside click, popout
  // switch, hotkey). Driving it off `opened` is the only place that sees
  // all of them.
  property bool surfaceCounted: false

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

  readonly property color ink: root.bar ? root.bar.foreground : Color.foreground
  readonly property color urgent: root.bar ? root.bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(ink, 1.5)
  readonly property color hairline: Util.alpha(ink, 0.12)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- state

  readonly property bool reducedMotion: root.service ? root.service.reducedMotion === true : false
  readonly property string samplerState: root.service ? String(root.service.samplerState || "starting") : "starting"
  readonly property bool running: samplerState === "running"

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
  readonly property real memNow: memTotal > 0 ? memUsed / memTotal * 100 : -1
  readonly property real gpuNow: vitals && vitals.gpu ? Number(vitals.gpu.busy) || 0 : -1

  readonly property bool gpuAvailable: !!(running && vitals && vitals.gpu && vitals.gpu.available === true)
  readonly property bool tempAvailable: !!(running && cpuTemp > 0)
  readonly property bool netAvailable: !!(running && vitals && vitals.net)
  readonly property bool powerAvailable:
    !!(running && vitals && vitals.power && vitals.power.available === true && Number(vitals.power.watts) > 0)

  readonly property var cpuSeries: history && history.cpu ? history.cpu : []
  readonly property var gpuSeries: history && history.gpu ? history.gpu : []
  readonly property var tempSeries: history && history.temp ? history.temp : []

  // History carries memory in bytes; the row reads as a percentage of total,
  // so convert once per tick here rather than inside onPaint.
  // history.mem is already a percent of total (sampler protocol).
  readonly property var memSeries: root.history && root.history.mem ? root.history.mem : []


  // Temperature has no natural ceiling; keep the axis stable at 90° unless
  // the machine actually runs hotter, so the line doesn't rescale every tick.
  readonly property real tempCeiling: Math.max(90, Model.maxOf(root.tempSeries, 0))

  readonly property string netText:
    netAvailable ? "↓ " + Model.rate(vitals.net.rx) + "   ↑ " + Model.rate(vitals.net.tx) : ""
  readonly property string powerText: powerAvailable ? Model.watts(vitals.power.watts) : ""

  // ---- Apps ---------------------------------------------------------------

  readonly property var pinnedRows: Model.pinnedApps(root.apps)
  // One line, not a list: a list sorted by usage reorders itself, which is
  // exactly the jumping this dropdown avoids.
  readonly property var busiest: Model.topApps(root.apps, 1)[0] || null

  // ---- Sampler state card -------------------------------------------------

  function logTail(count) {
    var raw = root.service ? String(root.service.buildLog || "") : ""
    var lines = raw.split("\n").filter(function(line) { return line.trim() !== "" })
    return lines.slice(-count).join("\n")
  }

  readonly property string stateTitle: {
    if (root.samplerState === "missing") return "Sampler not built yet."
    if (root.samplerState === "building") return "Building sampler…"
    if (root.samplerState === "buildFailed") return "Build failed"
    return "Sampler starting…"
  }

  readonly property string stateBody: {
    if (root.samplerState === "missing") return "Press b to build it (cargo, ~1 min)."
    if (root.samplerState === "building") return root.logTail(3)
    if (root.samplerState === "buildFailed") return root.logTail(6)
    return ""
  }

  // ---------------------------------------------------------------- metrics

  // Fixed columns so numerals never jitter as digits come and go.
  TextMetrics {
    id: labelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1.2
    text: "MEMORY"
  }

  TextMetrics {
    id: vitalValueMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
    text: "100%"
  }

  TextMetrics {
    id: appCpuMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    text: "100%"
  }

  TextMetrics {
    id: appMemMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    text: "9999M"
  }

  readonly property real labelColumn: Math.ceil(labelMetrics.advanceWidth)
  readonly property real valueColumn: Math.ceil(vitalValueMetrics.advanceWidth)
  readonly property real cpuColumn: Math.ceil(appCpuMetrics.advanceWidth)
  readonly property real memColumn: Math.ceil(appMemMetrics.advanceWidth)

  readonly property real vitalRowHeight: Style.space(28)
  readonly property real appRowHeight: Style.space(24)

  // ---------------------------------------------------------------- motion

  // Sparklines repaint once per tick. A per-frame slide was measured at 7x
  // the plugin's entire idle cost, for an effect nobody asked for.
  readonly property real slide: 1

  // ---------------------------------------------------------------- frame

  readonly property real panelWidth: Style.space(360)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
          root.bar.switchPanelFrom(root.barIdentity, direction)
      }
      onActivateRequested: root.openOverlay()
      onTextKey: function(t) {
        if (t === "o" || t === "O") root.openOverlay()
        else if ((t === "b" || t === "B")
                 && (root.samplerState === "missing" || root.samplerState === "buildFailed"))
          root.buildSampler()
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.spacing.panelGap

        // ------------------------------------------------------- header

        Column {
          width: parent.width
          spacing: Style.spacing.xs

          Item {
            width: parent.width
            height: Style.space(22)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Omatop"
              color: root.ink
              textFormat: Text.PlainText; font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Rectangle {
              id: pressurePill
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              height: Style.space(18)
              width: Style.space(7) + pressureDot.width + Style.space(5)
                + Math.ceil(pressureLabel.implicitWidth) + Style.space(7)
              radius: height / 2
              color: Util.alpha(root.pressureColor, 0.12)
              border.width: 1
              border.color: Util.alpha(root.pressureColor, 0.4)

              Behavior on color {
                enabled: !root.reducedMotion
                ColorAnimation { duration: 300 }
              }
              Behavior on border.color {
                enabled: !root.reducedMotion
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
                color: root.pressureColor

                Behavior on color {
                  enabled: !root.reducedMotion
                  ColorAnimation { duration: 300 }
                }
              }

              Text {
                id: pressureLabel
                anchors.left: pressureDot.right
                anchors.leftMargin: Style.space(5)
                anchors.verticalCenter: parent.verticalCenter
                text: Model.pressureLabel(root.pressureLevel).toUpperCase()
                color: root.pressureColor
                textFormat: Text.PlainText; font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.2

                Behavior on color {
                  enabled: !root.reducedMotion
                  ColorAnimation { duration: 300 }
                }
              }
            }
          }

          // Why the machine is unhappy, in the sampler's own words.
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignRight
            visible: root.running && root.pressureLevel !== "calm" && root.pressureReason !== ""
            text: root.pressureReason
            elide: Text.ElideRight
            color: root.dim
            textFormat: Text.PlainText; font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ------------------------------------------------------- vitals

        Column {
          width: parent.width
          spacing: Style.spacing.md
          visible: root.running

          VitalRow {
            label: "CPU"
            value: root.cpuNow >= 0 ? Model.pct(root.cpuNow, 0) : "--"
            samples: root.cpuSeries
            ceiling: 100
            // CPU is the row Pressure is mostly about, so it carries the hue.
            lineColor: root.pressureColor
          }

          VitalRow {
            label: "Memory"
            value: root.memNow >= 0 ? Model.pct(root.memNow, 0) : "--"
            samples: root.memSeries
            ceiling: 100
          }

          VitalRow {
            label: "GPU"
            visible: root.gpuAvailable
            value: root.gpuNow >= 0 ? Model.pct(root.gpuNow, 0) : "--"
            samples: root.gpuSeries
            ceiling: 100
          }

          VitalRow {
            label: "Temp"
            visible: root.tempAvailable
            value: Model.temp(root.cpuTemp)
            samples: root.tempSeries
            ceiling: root.tempCeiling
          }

          // Throughput and draw: numbers only. A sparkline here would be
          // noise — these are read, not watched.
          Item {
            width: parent.width
            height: root.appRowHeight
            visible: root.netAvailable || root.powerAvailable

            Text {
              id: netLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: root.labelColumn
              text: "NET"
              color: root.dim
              textFormat: Text.PlainText; font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
            }

            Text {
              id: powerValue
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.powerAvailable
              text: root.powerText
              color: root.ink
              textFormat: Text.PlainText; font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              anchors.left: netLabel.right
              anchors.leftMargin: Style.spacing.md
              anchors.right: root.powerAvailable ? powerValue.left : parent.right
              anchors.rightMargin: root.powerAvailable ? Style.spacing.md : 0
              anchors.verticalCenter: parent.verticalCenter
              text: root.netText
              elide: Text.ElideRight
              color: root.ink
              textFormat: Text.PlainText; font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        // ------------------------------------------------------- sampler state

        Column {
          width: parent.width
          spacing: Style.spacing.sm
          visible: !root.running

          Text {
            width: parent.width
            text: root.stateTitle
            wrapMode: Text.WordWrap
            color: root.samplerState === "buildFailed" ? root.urgent : root.ink
            textFormat: Text.PlainText; font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
          }

          Text {
            width: parent.width
            visible: root.stateBody !== ""
            text: root.stateBody
            wrapMode: Text.WrapAnywhere
            color: root.dim
            textFormat: Text.PlainText; font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            lineHeight: 1.25
          }
        }

        // ------------------------------------------------------- pinned

        Column {
          width: parent.width
          spacing: Style.spacing.sm
          visible: root.running && root.pinnedRows.length > 0

          PanelSectionHeader {
            text: "Pinned"
            foreground: root.ink
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.pinnedRows

            AppRow {
              required property var modelData
              app: modelData
            }
          }
        }

        // ------------------------------------------------------- busiest

        Item {
          width: parent.width
          height: Style.space(24)
          visible: root.running && root.busiest !== null

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "BUSIEST"
            color: root.dim
            textFormat: Text.PlainText; font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.2
          }
          Text {
            anchors.right: busiestNum.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: root.busiest ? root.busiest.name : ""
            color: root.busiest && root.service && root.busiest.id === root.service.culprit ? root.pressureColor : root.ink
            textFormat: Text.PlainText; font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            id: busiestNum
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(52)
            horizontalAlignment: Text.AlignRight
            text: root.busiest ? Model.pct(root.busiest.cpu) : ""
            color: root.ink
            textFormat: Text.PlainText; font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ------------------------------------------------------- footer

        Item {
          width: parent.width
          height: Style.space(26)

          Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: root.hairline
          }

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: Style.space(3)
            text: "Right-click or Super+Ctrl+M for the full monitor  ·  o opens it"
            elide: Text.ElideRight
            color: Qt.darker(root.dim, 1.15)
            textFormat: Text.PlainText; font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // ================================================================ sparkline

  // Two minutes of one Vital: a filled area under a 1px line. Repaints on the
  // tick, and — unless motion is reduced — walks the series left by exactly
  // one sample width while the newest point arrives, so it slides.
  component Sparkline: Canvas {
    id: spark

    property var samples: []
    property real ceiling: 100
    property color lineColor: root.ink
    property real progress: root.slide

    height: Style.space(22)
    renderStrategy: Canvas.Cooperative

    Behavior on lineColor {
      enabled: !root.reducedMotion
      ColorAnimation { duration: 300 }
    }

    onSamplesChanged: if (root.opened) requestPaint()
    Connections { target: root; function onOpenedChanged() { if (root.opened) spark.requestPaint() } }
    onProgressChanged: requestPaint()
    onLineColorChanged: requestPaint()

    onPaint: {
      var ctx = spark.getContext("2d")
      if (!ctx) return
      ctx.reset()

      var w = spark.width
      var h = spark.height
      var data = spark.samples
      var n = data ? data.length : 0
      if (w <= 0 || h <= 0 || n < 2) return

      var top = 1
      var floorY = h - 1
      var span = Math.max(1, floorY - top)
      var ceil = Math.max(1, spark.ceiling)
      var step = w / (n - 1)
      var offset = (1 - Util.clamp(spark.progress, 0, 1)) * step

      var xs = []
      var ys = []
      for (var i = 0; i < n; i++) {
        xs.push(i * step + offset)
        ys.push(floorY - Util.clamp((Number(data[i]) || 0) / ceil, 0, 1) * span)
      }

      ctx.beginPath()
      ctx.moveTo(0, floorY)
      ctx.lineTo(0, ys[0])
      for (var f = 0; f < n; f++) ctx.lineTo(xs[f], ys[f])
      ctx.lineTo(xs[n - 1], floorY)
      ctx.closePath()
      ctx.fillStyle = Util.alpha(root.ink, 0.10)
      ctx.fill()

      ctx.beginPath()
      ctx.moveTo(0, ys[0])
      for (var s = 0; s < n; s++) ctx.lineTo(xs[s], ys[s])
      ctx.lineWidth = 1
      ctx.strokeStyle = spark.lineColor
      ctx.stroke()
    }
  }

  // ================================================================ vital row

  component VitalRow: Item {
    id: vrow

    property string label: ""
    property string value: "--"
    property var samples: []
    property real ceiling: 100
    property color lineColor: root.ink

    width: parent ? parent.width : 0
    height: root.vitalRowHeight

    Text {
      id: vrowLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: root.labelColumn
      text: vrow.label.toUpperCase()
      color: root.dim
      textFormat: Text.PlainText; font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1.2
    }

    Text {
      id: vrowValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: root.valueColumn
      horizontalAlignment: Text.AlignRight
      text: vrow.value
      color: root.ink
      textFormat: Text.PlainText; font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }

    Sparkline {
      anchors.left: vrowLabel.right
      anchors.leftMargin: Style.spacing.md
      anchors.right: vrowValue.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      samples: vrow.samples
      ceiling: vrow.ceiling
      lineColor: vrow.lineColor
    }
  }

  // ================================================================ app row

  component AppRow: Item {
    id: arow

    property var app: null

    width: parent ? parent.width : 0
    height: root.appRowHeight

    readonly property bool isCulprit: !!(arow.app && root.culprit !== "" && arow.app.id === root.culprit)

    Text {
      id: arowMem
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: root.memColumn
      horizontalAlignment: Text.AlignRight
      text: arow.app ? Model.bytes(arow.app.mem) : ""
      color: root.dim
      textFormat: Text.PlainText; font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: arowCpu
      anchors.right: arowMem.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      width: root.cpuColumn
      horizontalAlignment: Text.AlignRight
      text: arow.app ? Model.pct(arow.app.cpu, 0) : ""
      color: root.ink
      textFormat: Text.PlainText; font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: arowPorts
      anchors.right: arowCpu.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      text: arow.app ? Model.ports(arow.app.ports) : ""
      color: root.dim
      textFormat: Text.PlainText; font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.left: parent.left
      anchors.right: arowPorts.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      text: arow.app ? String(arow.app.name || "") : ""
      elide: Text.ElideRight
      color: arow.isCulprit ? root.pressureColor : root.ink
      textFormat: Text.PlainText; font.family: root.fontFamily
      font.pixelSize: Style.font.body

      Behavior on color {
        enabled: !root.reducedMotion
        ColorAnimation { duration: 300 }
      }
    }
  }
}
