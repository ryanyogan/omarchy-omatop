import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "ui"

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
  // Only evaluated while hovered (see tooltipText below): the shell reads
  // the tooltip once on hover-enter, so a string built every tick while
  // nobody is looking is pure garbage in the one component always loaded.
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
    // containsMouse flips before entered() fires, so the binding is current
    // when the shell reads it on hover-enter.
    tooltipText: button.tooltipHovered ? root.tooltip : ""

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

      // The mark: a chip, drawn by the shared ChipIcon so the bar and the
      // dropdown's hero stay the same shape. It never moves; only its colour
      // walks the utilisation ramp (calm, amber, orange, red).
      ChipIcon {
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        iconSize: Style.bar.iconCanvas

        tint: root.samplerReady ? root.pressureColor : root.ink
        opacity: root.samplerReady ? 1 : 0.6

        Behavior on tint {
          enabled: !root.reducedMotion
          ColorAnimation { duration: 300 }
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
