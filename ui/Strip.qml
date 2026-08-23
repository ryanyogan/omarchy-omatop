import QtQuick
import QtQuick.Shapes
import qs.Commons

// One row of the ledger: a full-width timeline on the shared axis, with the
// label and the live value riding its top edge. Several strips stacked with
// the same `capacity` and `scrub` read as one instrument.
//
// Drawn with Shapes, not Canvas: a 120-point polyline is tessellated on the
// GPU in microseconds, where rasterising a 3000x440 canvas in software every
// second was the single largest cost of the open overlay.
Item {
  id: root

  property string label: ""
  property var samples: []          // oldest first, length <= capacity
  property int capacity: 120
  property real maxValue: 100       // axis ceiling; 0 = autoscale
  property real floorValue: 0       // autoscale never goes below this ceiling
  property string valueText: ""     // live value, preformatted
  property var formatter: null      // function(v) -> string, for scrubbed values
  property int scrub: -1            // -1 live, else sample index from the left
  property color ink: "white"
  property color line: ink
  property color dim: Qt.rgba(1, 1, 1, 0.55)
  property color faint: Qt.rgba(1, 1, 1, 0.3)
  property color hairline: Qt.rgba(1, 1, 1, 0.1)
  property string fontFamily: Style.font.family
  property bool compact: false
  property bool animated: true
  property bool available: true

  readonly property int headerHeight: Style.space(18)

  clip: true
  opacity: available ? 1 : 0.35

  readonly property real scale: {
    if (maxValue > 0) return maxValue
    var m = 0
    for (var i = 0; i < (samples ? samples.length : 0); i++) if (samples[i] > m) m = samples[i]
    return Math.max(floorValue, m * 1.15, 1)
  }

  readonly property string shownValue: {
    if (scrub >= 0 && samples && samples.length) {
      var idx = scrub - (capacity - samples.length)
      if (idx >= 0 && idx < samples.length) return formatter ? formatter(samples[idx]) : String(Math.round(samples[idx]))
      return "--"
    }
    return valueText
  }

  // Geometry, recomputed once per tick (and on resize).
  readonly property real plotTop: 3
  readonly property real plotFloor: Math.max(plotTop + 2, plot.height - 3)
  readonly property real step: plot.width / (capacity - 1)
  readonly property int count: samples ? samples.length : 0
  readonly property real startX: plot.width - (count - 1) * step
  function yOf(v) { return plotFloor - Math.min(1, Math.max(0, v) / scale) * (plotFloor - plotTop) }

  readonly property var points: {
    var out = []
    var data = samples || []
    for (var i = 0; i < data.length; i++) out.push(Qt.point(startX + i * step, yOf(data[i])))
    return out
  }
  readonly property var fillPoints: {
    if (points.length < 2) return []
    var out = points.slice()
    out.push(Qt.point(points[points.length - 1].x, plotFloor))
    out.push(Qt.point(points[0].x, plotFloor))
    out.push(points[0])
    return out
  }
  readonly property point lastPoint: points.length ? points[points.length - 1] : Qt.point(-10, -10)

  Text {
    x: 0
    y: 0
    text: root.label
    color: root.dim
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.5
    font.capitalization: Font.AllUppercase
  }

  Text {
    anchors.right: parent.right
    y: 0
    text: root.shownValue
    color: root.scrub >= 0 ? root.ink : root.line
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  Item {
    id: plot
    x: 0
    y: root.headerHeight
    width: parent.width
    height: Math.max(4, parent.height - root.headerHeight)

    // Guides: baseline and a dashed half-way line.
    Rectangle { x: 0; y: Math.round(root.plotFloor); width: parent.width; height: 1; color: root.hairline }
    Row {
      x: 0
      y: Math.round((root.plotTop + root.plotFloor) / 2)
      spacing: 4
      clip: true
      width: parent.width
      Repeater {
        model: Math.ceil(plot.width / 6)
        Rectangle { width: 2; height: 1; color: root.hairline }
      }
    }

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      visible: root.points.length >= 2

      // Fill: the series colour fading to nothing at the baseline.
      ShapePath {
        strokeColor: "transparent"
        fillGradient: LinearGradient {
          x1: 0; y1: root.plotTop
          x2: 0; y2: root.plotFloor
          GradientStop { position: 0; color: Qt.rgba(root.line.r, root.line.g, root.line.b, 0.26) }
          GradientStop { position: 1; color: Qt.rgba(root.line.r, root.line.g, root.line.b, 0.0) }
        }
        PathPolyline { path: root.fillPoints }
      }

      // Glow under the line.
      ShapePath {
        strokeColor: Qt.rgba(root.line.r, root.line.g, root.line.b, 0.22)
        strokeWidth: 5
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathPolyline { path: root.points }
      }

      // The line.
      ShapePath {
        strokeColor: root.line
        strokeWidth: 1.5
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathPolyline { path: root.points }
      }
    }

    // Newest sample: a dot with a halo.
    Rectangle {
      visible: root.points.length >= 2
      x: root.lastPoint.x - width / 2
      y: root.lastPoint.y - height / 2
      width: 10; height: 10; radius: 5
      color: Qt.rgba(root.line.r, root.line.g, root.line.b, 0.25)
      Rectangle { anchors.centerIn: parent; width: 4; height: 4; radius: 2; color: root.line }
    }

    // Scrubber.
    Rectangle {
      visible: root.scrub >= 0
      x: Math.round(root.scrub * root.step)
      y: 0
      width: 1
      height: parent.height
      color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.45)
    }
    Rectangle {
      readonly property int idx: root.scrub - (root.capacity - root.count)
      visible: root.scrub >= 0 && idx >= 0 && idx < root.count
      x: Math.round(root.scrub * root.step) - 3
      y: (visible ? root.yOf(root.samples[idx]) : 0) - 3
      width: 6; height: 6; radius: 3
      color: root.ink
    }
  }
}
