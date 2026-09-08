import QtQuick
import QtQuick.Shapes
import qs.Commons

// One floating cluster dial, in the language of the shell's speed test
// overlay: an open 270° scale with the gap at the bottom, a faint tick ring,
// a glowing value arc, a hubless needle that fades toward the pivot, and a
// digital readout in the middle.
//
// Motion. The dial owns no animation of its own for live readings. The
// parent hands it a `phase` (0 at the moment a new sample lands, 1 when the
// next one is due) from one shared low-rate clock, and the needle and arc
// glide from the last reading to the new one as `phase` advances. Every
// frame the window produces costs the same whether one dial moves or all of
// them, so one clock for the whole overlay is the only cheap way to move.
//
// The value arc is a fragment shader (arc.frag), not a Shape: sweeping a
// Shape arc re-tessellates it every frame, while sweeping the shader is one
// uniform write. If the compiled shader fails to load the Shape below takes
// over, snapping to each sample.
Item {
  id: dial

  property string label: ""
  property real value: 0
  property real fullScale: 100
  property string unit: "%"
  property string readout: ""          // preformatted; empty = number + unit
  property bool engaged: true
  property bool animated: true
  property real phase: 1               // 0..1, from the parent's motion clock
  property real diameter: Style.space(170)
  property color accent: Color.accent
  property color onScrim: "white"
  property color onScrimDim: Qt.rgba(1, 1, 1, 0.55)
  property string fontFamily: Style.font.family
  property string sublabel: ""         // small caption under the readout (e.g. "of 15.0G")
  property color sublabelColor: onScrimDim
  property real readoutOpacity: 1      // parent fades the digits in as a reading lands

  readonly property real dialStart: 135
  readonly property real dialSweep: 270
  readonly property int tickCount: 46
  readonly property real arcWidth: Math.max(2, Math.round(diameter / 52))
  readonly property real arcRadius: diameter / 2 - arcWidth
  // Scale and ticks are the ink at low alpha, so they survive a light theme.
  readonly property color trackColor: Util.alpha(onScrim, 0.14)
  readonly property color minorTickColor: Util.alpha(onScrim, 0.12)
  readonly property color majorTickColor: Util.alpha(onScrim, 0.3)

  // `shown` is what the needle points at. It is stored, not bound, so a new
  // sample can read the reading it is gliding away from.
  property real shown: 0
  property real glideFrom: 0
  property real glideTo: 0

  readonly property real needleFraction: fullScale > 0 ? Math.max(0, Math.min(1, shown / fullScale)) : 0
  readonly property bool arcVisible: needleFraction > 0.004

  width: diameter
  height: diameter
  opacity: engaged ? 1 : 0.4
  Behavior on opacity { enabled: dial.animated; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
  Behavior on accent { enabled: dial.animated; ColorAnimation { duration: 300 } }

  // Ease in and out over the whole interval: no first-frame lurch, and the
  // needle settles exactly as the next sample is due.
  function eased(p) { return 0.5 - 0.5 * Math.cos(Math.PI * Math.max(0, Math.min(1, p))) }

  onValueChanged: {
    if (ignition.running) return
    glideFrom = shown
    glideTo = value
    // No clock running (reduced motion, or a change between ticks): land now.
    if (!animated || phase >= 1) shown = value
  }
  // The parent rewinds `phase` to 0 just before a reading lands, so a fresh
  // glide starts from wherever the needle is now, not from the start of the
  // last one. Until a new value arrives the glide is a hold.
  onPhaseChanged: {
    if (ignition.running) return
    if (phase <= 0) { glideFrom = shown; glideTo = shown; return }
    shown = glideFrom + (glideTo - glideFrom) * eased(phase)
  }
  Component.onCompleted: { shown = value; glideFrom = value; glideTo = value }

  function ignite() {
    if (!animated) { shown = value; return }
    ignition.restart()
  }

  // Cluster power-on: sweep to full scale and fall back before live figures take over.
  SequentialAnimation {
    id: ignition
    NumberAnimation { target: dial; property: "shown"; to: dial.fullScale; duration: 450; easing.type: Easing.InOutCubic }
    NumberAnimation { target: dial; property: "shown"; to: 0; duration: 500; easing.type: Easing.OutCubic }
    onFinished: { dial.shown = dial.value; dial.glideFrom = dial.value; dial.glideTo = dial.value }
  }

  // Scale track: static, so a Shape is fine.
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
  }

  // Value arc: under-glow ring and the arc itself, one quad each.
  component ArcFx: ShaderEffect {
    anchors.fill: parent
    fragmentShader: Qt.resolvedUrl("arc.frag.qsb")
    blending: true
    visible: dial.arcVisible && status === ShaderEffect.Compiled
    property color arcColor: dial.accent
    property vector2d size: Qt.vector2d(width, height)
    property real radius: dial.arcRadius
    property real halfWidth: dial.arcWidth / 2
    property real startAngle: dial.dialStart * Math.PI / 180
    property real sweep: dial.dialSweep * dial.needleFraction * Math.PI / 180
    property real feather: 1.0
  }
  ArcFx { arcColor: Qt.rgba(dial.accent.r, dial.accent.g, dial.accent.b, 0.18); halfWidth: dial.arcWidth * 1.5 }
  ArcFx { id: valueArc }

  // Fallback if the shader did not load: a Shape arc riding the same glide.
  // It re-tessellates every frame of the glide, which is the cost the shader
  // avoids, but it never jumps.
  Shape {
    id: fallbackArc
    anchors.fill: parent
    visible: dial.arcVisible && valueArc.status !== ShaderEffect.Compiled
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeWidth: dial.arcWidth
      strokeColor: dial.accent
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathAngleArc { centerX: dial.width / 2; centerY: dial.height / 2; radiusX: dial.arcRadius; radiusY: dial.arcRadius; startAngle: dial.dialStart; sweepAngle: dial.dialSweep * dial.needleFraction }
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
    rotation: dial.dialStart + dial.needleFraction * dial.dialSweep - 270
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

  // The readout snaps to each sample: a number that spins is not a reading.
  Column {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.verticalCenter
    anchors.topMargin: Style.space(8)
    spacing: 0
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: dial.readout !== "" ? dial.readout : (dial.value < 10 ? dial.value.toFixed(1) : Math.round(dial.value).toString())
      opacity: dial.readoutOpacity
      color: dial.onScrim
      textFormat: Text.PlainText
      font.family: dial.fontFamily
      font.pixelSize: dial.diameter >= Style.space(160) ? Style.font.display : Style.font.heading
      font.bold: true
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: dial.sublabel !== "" ? dial.sublabel : dial.unit
      color: dial.sublabelColor
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
