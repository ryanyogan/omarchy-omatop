import QtQuick
import QtQuick.Shapes
import qs.Commons

// One floating cluster dial, in the language of the shell's speed test
// overlay: an open 270° scale with the gap at the bottom, a faint tick ring,
// a glowing value arc, a hubless needle that fades toward the pivot, and a
// digital readout in the middle. Every write to the needle goes through
// `shown`, so the ignition sweep and live readings share one animation.
Item {
  id: dial

  property string label: ""
  property real value: 0
  property real fullScale: 100
  property string unit: "%"
  property string readout: ""          // preformatted; empty = number + unit
  property bool engaged: true
  property bool animated: true
  property real diameter: Style.space(170)
  property color accent: Color.accent
  property color onScrim: "white"
  property color onScrimDim: Qt.rgba(1, 1, 1, 0.55)
  property string fontFamily: Style.font.family
  property string sublabel: ""         // small caption under the readout (e.g. "of 15.0G")

  readonly property real dialStart: 135
  readonly property real dialSweep: 270
  readonly property int tickCount: 46
  readonly property real arcWidth: Math.max(2, Math.round(diameter / 52))
  readonly property real arcRadius: diameter / 2 - arcWidth
  readonly property color trackColor: Qt.rgba(1, 1, 1, 0.14)
  readonly property color minorTickColor: Qt.rgba(1, 1, 1, 0.12)
  readonly property color majorTickColor: Qt.rgba(1, 1, 1, 0.3)

  property real shown: 0
  readonly property real reading: ignition.running ? value : shown
  readonly property real fraction: fullScale > 0 ? Math.max(0, Math.min(1, shown / fullScale)) : 0
  readonly property bool arcVisible: fraction > 0.004

  width: diameter
  height: diameter
  opacity: engaged ? 1 : 0.4
  Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

  // Live readings glide between samples rather than snap.
  Behavior on shown {
    enabled: dial.animated && !ignition.running
    NumberAnimation { duration: 600; easing.type: Easing.OutCubic }
  }
  Behavior on accent { enabled: dial.animated; ColorAnimation { duration: 300 } }

  onValueChanged: { if (!ignition.running) shown = value }
  Component.onCompleted: shown = value

  function ignite() {
    if (!animated) { shown = value; return }
    ignition.restart()
  }

  // Cluster power-on: sweep to full scale and fall back before live figures take over.
  SequentialAnimation {
    id: ignition
    NumberAnimation { target: dial; property: "shown"; to: dial.fullScale; duration: 550; easing.type: Easing.InOutCubic }
    NumberAnimation { target: dial; property: "shown"; to: 0; duration: 650; easing.type: Easing.OutCubic }
    onFinished: dial.shown = dial.value
  }

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      strokeWidth: dial.arcWidth
      strokeColor: dial.trackColor
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathAngleArc { centerX: dial.width / 2; centerY: dial.height / 2; radiusX: dial.arcRadius; radiusY: dial.arcRadius; startAngle: dial.dialStart; sweepAngle: dial.dialSweep }
    }

    // Under-glow, the backlit ring of a real cluster.
    ShapePath {
      strokeWidth: dial.arcWidth * 3
      strokeColor: dial.arcVisible ? Qt.rgba(dial.accent.r, dial.accent.g, dial.accent.b, 0.18) : "transparent"
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathAngleArc { centerX: dial.width / 2; centerY: dial.height / 2; radiusX: dial.arcRadius; radiusY: dial.arcRadius; startAngle: dial.dialStart; sweepAngle: dial.dialSweep * dial.fraction }
    }

    ShapePath {
      strokeWidth: dial.arcWidth
      strokeColor: dial.arcVisible ? dial.accent : "transparent"
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathAngleArc { centerX: dial.width / 2; centerY: dial.height / 2; radiusX: dial.arcRadius; radiusY: dial.arcRadius; startAngle: dial.dialStart; sweepAngle: dial.dialSweep * dial.fraction }
    }
  }

  Repeater {
    model: dial.tickCount
    Item {
      required property int index
      readonly property bool major: index % 5 === 0
      anchors.fill: parent
      rotation: dial.dialStart + (index / (dial.tickCount - 1)) * dial.dialSweep - 270
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: dial.arcWidth * 2 + (parent.major ? 0 : Style.space(2))
        width: parent.major ? Math.max(2, Style.space(2)) : 1
        height: parent.major ? Style.space(9) : Style.space(5)
        radius: width / 2
        color: parent.major ? dial.majorTickColor : dial.minorTickColor
      }
    }
  }

  // Hubless needle.
  Item {
    anchors.fill: parent
    rotation: dial.dialStart + dial.fraction * dial.dialSweep - 270
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      y: dial.arcWidth * 2 + Style.space(10)
      width: Math.max(2, Style.space(3))
      height: dial.diameter * 0.32
      radius: width / 2
      gradient: Gradient {
        GradientStop { position: 0.0; color: dial.accent }
        GradientStop { position: 0.55; color: dial.accent }
        GradientStop { position: 1.0; color: "transparent" }
      }
    }
  }

  Column {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.verticalCenter
    anchors.topMargin: Style.space(8)
    spacing: 0
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: dial.readout !== "" ? dial.readout : (dial.reading < 10 ? dial.reading.toFixed(1) : Math.round(dial.reading).toString())
      color: dial.onScrim
      textFormat: Text.PlainText
      font.family: dial.fontFamily
      font.pixelSize: dial.diameter >= Style.space(160) ? Style.font.display : Style.font.heading
      font.bold: true
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: dial.sublabel !== "" ? dial.sublabel : dial.unit
      color: dial.onScrimDim
      textFormat: Text.PlainText
      font.family: dial.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    text: dial.label
    color: dial.onScrimDim
    textFormat: Text.PlainText
    font.family: dial.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.5
    font.capitalization: Font.AllUppercase
  }
}
