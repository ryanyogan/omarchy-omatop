import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Omatop's bar presence: a chip mark whose colour walks the utilisation ramp
// tinted by Pressure. It is meant to be ignorable: the colour is the signal
// and it never moves.
//
// Left click toggles the dropdown, right click opens the full overlay,
// middle click and the wheel do nothing on purpose.
BarWidget {
  id: root
  moduleName: "ryanyogan.omatop"

  // The shared Service instance (kind "service" in the manifest). serviceFor
  // reads shell._services, so this re-evaluates when the service finishes
  // loading after the bar.
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(root.moduleName) : null

  // ---------------------------------------------------------------- theming

  readonly property color ink: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent

  // ---------------------------------------------------------------- state

  // The service mirrors the widget's own settings, but it may not be up yet.
  readonly property bool reducedMotion: service ? service.reducedMotion === true
                                                : setting("reducedMotion", false) === true
  readonly property bool showPercent: setting("showPercent", false) === true

  readonly property string samplerState: service ? String(service.samplerState || "starting") : "starting"
  readonly property bool samplerReady: samplerState === "running"
  readonly property real cpuNow:
    service && service.vitals && service.vitals.cpu ? Number(service.vitals.cpu.total) || 0 : -1

  readonly property string pressureLevel:
    service && service.pressure ? String(service.pressure.level || "calm") : "calm"
  readonly property color pressureColor: Model.pressureColor(root.pressureLevel, root.ink, root.urgent)



  readonly property string percentText:
    root.samplerReady && root.cpuNow >= 0 ? Model.pct(root.cpuNow, 0) : "--"

  readonly property real memUsed:
    service && service.vitals && service.vitals.mem ? Number(service.vitals.mem.used) || 0 : 0
  readonly property real memTotal:
    service && service.vitals && service.vitals.mem ? Number(service.vitals.mem.total) || 0 : 0

  // Hover text: the Pressure verdict and the two numbers people actually
  // want at a glance. No product name; the glyph already says which widget.
  readonly property string tooltip: {
    if (root.samplerState === "missing") return "Sampler not built, open to build"
    if (root.samplerState === "building") return "Building the sampler…"
    if (root.samplerState === "buildFailed") return "Sampler build failed — open for the log"
    if (root.samplerState === "crashed") return "Sampler crashed, restarting"
    if (!root.samplerReady) return "Sampler starting…"
    var head = Model.pressureLabel(root.pressureLevel)
    if (root.cpuNow >= 0) head += " · CPU " + Model.pct(root.cpuNow, 0)
    if (root.memTotal > 0) head += " · MEM " + Model.pct(100 * root.memUsed / root.memTotal, 0)
    var reason = service && service.pressure ? String(service.pressure.reason || "") : ""
    return root.pressureLevel !== "calm" && reason !== "" ? head + " · " + reason : head
  }

  // ---------------------------------------------------------------- wiring

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
    // The widget's shell.json entry is the settings source of truth for the
    // whole plugin; push it into the shared service too.
    if (root.service && "widgetSettings" in root.service)
      root.service.widgetSettings = root.settings
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function toggleOverlay() {
    if (bar && bar.shell) bar.shell.toggle(root.moduleName, "{}")
  }

  // Shape contract for shell.summon/hide/toggle routing to the dropdown.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The bar's open-panel pill tracks the painted mark, not the whole slot.
  readonly property real openPanelIndicatorWidth: content.visible ? content.width : 0

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    dimmed: !root.samplerReady
    fixedWidth: root.vertical ? -1
      : Math.round(content.implicitWidth + Style.spaceReal(8.5) * 2)
    tooltipText: root.tooltip

    onPressed: function(b) {
      if (b === Qt.MiddleButton) return
      if (b === Qt.RightButton) root.toggleOverlay()
      else root.togglePanel()
    }

    // Measured on a constant so the cell never twitches between 9% and 100%.
    TextMetrics {
      id: percentMetrics
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      text: "100%"
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: 0

      // The mark. Three fixed bars tinted by
      // Pressure — a shape rather than a font icon, so it stays honest at
      // any bar size and never depends on a Nerd Font being present.
      // The mark: a chip. A rounded die with legs on all four sides and a
      // core inside. It never moves; only its colour walks the utilisation
      // ramp (calm, amber, orange, red).
      Canvas {
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        renderStrategy: Canvas.Cooperative

        property color tint: root.samplerReady ? root.pressureColor : root.ink
        opacity: root.samplerReady ? 1 : 0.6

        Behavior on tint {
          enabled: !root.reducedMotion
          ColorAnimation { duration: 300 }
        }
        onTintChanged: requestPaint()

        onPaint: {
          var ctx = glyph.getContext("2d")
          if (!ctx) return
          ctx.reset()

          var w = glyph.width
          var h = glyph.height
          if (w <= 0 || h <= 0) return

          var leg = Math.max(2, Math.round(w * 0.14))
          var lw = Math.max(1, Math.round(w * 0.09))
          var bodyR = Math.max(1.5, w * 0.12)
          var x0 = leg, y0 = leg
          var bw = w - leg * 2, bh = h - leg * 2

          ctx.strokeStyle = glyph.tint
          ctx.fillStyle = glyph.tint
          ctx.lineWidth = lw
          ctx.lineCap = "round"

          // Legs: three per side, centred on the body edges.
          var positions = [0.28, 0.5, 0.72]
          for (var i = 0; i < positions.length; i++) {
            var t = positions[i]
            var px = Math.round(x0 + bw * t)
            var py = Math.round(y0 + bh * t)
            ctx.beginPath()
            ctx.moveTo(px, 0); ctx.lineTo(px, y0 - 1)
            ctx.moveTo(px, h); ctx.lineTo(px, h - y0 + 1)
            ctx.moveTo(0, py); ctx.lineTo(x0 - 1, py)
            ctx.moveTo(w, py); ctx.lineTo(w - x0 + 1, py)
            ctx.stroke()
          }

          // Body outline.
          ctx.beginPath()
          ctx.moveTo(x0 + bodyR, y0)
          ctx.arcTo(x0 + bw, y0, x0 + bw, y0 + bh, bodyR)
          ctx.arcTo(x0 + bw, y0 + bh, x0, y0 + bh, bodyR)
          ctx.arcTo(x0, y0 + bh, x0, y0, bodyR)
          ctx.arcTo(x0, y0, x0 + bw, y0, bodyR)
          ctx.closePath()
          ctx.stroke()

          // Core.
          var cw = Math.max(2, Math.round(bw * 0.34))
          ctx.fillRect(Math.round(w / 2 - cw / 2), Math.round(h / 2 - cw / 2), cw, cw)
        }
      }

      // Live percent cell: measured, gap included, so it collapses to nothing
      // in one smooth motion and never nudges the mark between digits.
      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: root.showPercent && !root.vertical
          ? Math.ceil(percentMetrics.advanceWidth) + Style.space(5) : 0
        height: percentLabel.implicitHeight
        clip: true
        visible: width > 0

        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        Text {
          id: percentLabel
          anchors.right: parent.right
          text: root.percentText
          color: root.samplerReady ? root.pressureColor : button.foreground
          font.family: button.fontFamily
          font.pixelSize: button.fontSize

          Behavior on color {
            enabled: !root.reducedMotion
            ColorAnimation { duration: 300 }
          }
        }
      }
    }
  }
}
