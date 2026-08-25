import QtQuick
import qs.Commons
import "../Model.js" as Model

// One block per CPU core, in a row the width of the timeline above it. A
// block's colour is its load on the same calm / load / heavy / critical ramp
// the pressure glyph uses, and its brightness is the load itself, so one
// pinned core reads as one hot block while the total still says 4%.
//
// Blocks glide between readings on the parent's `phase`, the shared clock
// the dials and meters use: no Behaviors, nothing pins the window's refresh.
Item {
  id: root

  property var cores: []               // percent per core, from vitals.cpu.cores
  property real phase: 1
  property bool animated: true
  property color accent: Color.accent
  property color urgent: "#ff6b6b"
  property color track: Qt.rgba(1, 1, 1, 0.08)
  property color faint: Qt.rgba(1, 1, 1, 0.3)
  property string fontFamily: Style.font.family
  property bool showLabel: true
  property int blockHeight: Style.space(7)
  property int maxBlockWidth: Style.space(12)
  property int gap: Style.space(2)

  readonly property int count: cores ? cores.length : 0
  readonly property int labelWidth: showLabel ? Style.space(66) : 0
  implicitHeight: blockHeight
  visible: count > 0

  function eased(p) { return 0.5 - 0.5 * Math.cos(Math.PI * Math.max(0, Math.min(1, p))) }
  function tierColor(load) {
    if (load >= 90) return Model.pressureColor("critical", accent, urgent)
    if (load >= 60) return Model.pressureColor("heavy", accent, urgent)
    if (load >= 30) return Model.pressureColor("load", accent, urgent)
    return accent
  }

  Text {
    visible: root.showLabel
    x: 0
    anchors.verticalCenter: parent.verticalCenter
    text: root.count + " cores"
    color: root.faint
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Row {
    x: root.labelWidth
    width: parent.width - root.labelWidth
    height: root.blockHeight
    spacing: root.gap
    // Small squares, never stretched: a row of 4 and a row of 64 read the same.
    readonly property real blockWidth: root.count > 0 ? Math.max(2, Math.min(root.maxBlockWidth, (width - root.gap * (root.count - 1)) / root.count)) : 0

    Repeater {
      model: root.count
      Rectangle {
        id: block
        required property int index
        readonly property real load: root.cores && index < root.cores.length ? Math.max(0, Math.min(100, Number(root.cores[index]) || 0)) : 0
        // What the block shows, gliding toward `load` as phase advances.
        property real shown: 0
        property real glideFrom: 0
        property real glideTo: 0
        readonly property real phase: root.phase
        onLoadChanged: {
          glideFrom = shown
          glideTo = load
          if (!root.animated || phase >= 1) shown = load
        }
        onPhaseChanged: {
          if (phase <= 0) { glideFrom = shown; glideTo = shown; return }
          shown = glideFrom + (glideTo - glideFrom) * root.eased(phase)
        }
        Component.onCompleted: { shown = load; glideFrom = load; glideTo = load }

        width: parent.blockWidth
        height: root.blockHeight
        radius: Math.min(2, height / 3)
        color: root.track
        Rectangle {
          anchors.fill: parent
          radius: parent.radius
          color: root.tierColor(block.shown)
          opacity: 0.12 + 0.88 * block.shown / 100
        }
      }
    }
  }
}
