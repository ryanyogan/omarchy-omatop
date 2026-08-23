import QtQuick
import qs.Commons

// One row of the ledger: label, current value, and a timeline on the shared
// two-minute axis. Several strips stacked with the same `samples` length and
// the same `scrub` read as one instrument.
Item {
  id: root

  property string label: ""
  property var samples: []          // oldest first, length <= capacity
  property int capacity: 120
  property real maxValue: 100       // axis ceiling; pass 0 to autoscale
  property real floorValue: 0       // autoscale never goes below this ceiling
  property string valueText: ""     // live value, preformatted
  property var formatter: null      // function(v) -> string, for scrubbed values
  property int scrub: -1            // -1 live, else sample index from the left
  property color ink: Color.foreground
  property color line: ink
  property color fill: Util.alpha(ink, 0.10)
  property color dim: Qt.darker(ink, 1.5)
  property color hairline: Util.alpha(ink, 0.12)
  property string fontFamily: Style.font.family
  property bool compact: false      // header-only height while an App is focused
  property bool animated: true
  property real tickMs: 1000        // interval the sampler is running at
  property bool available: true

  readonly property int labelWidth: Style.space(44)
  property int valueWidth: Style.space(64)
  readonly property int fullHeight: Style.space(46)
  readonly property int compactHeight: Style.space(26)

  implicitHeight: compact ? compactHeight : fullHeight
  Behavior on implicitHeight { enabled: root.animated; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
  clip: true
  opacity: available ? 1 : 0.35

  // The graph slides left continuously between samples instead of stepping.
  property real phase: 0
  property int lastCount: 0
  onSamplesChanged: {
    var n = samples ? samples.length : 0
    if (n > lastCount && lastCount > 0 && animated) {
      phase = 0
      slide.restart()
    } else {
      phase = 1
    }
    lastCount = n
    canvas.requestPaint()
  }
  NumberAnimation { id: slide; target: root; property: "phase"; from: 0; to: 1; duration: Math.max(80, Math.min(1200, root.tickMs)); easing.type: Easing.Linear }
  onPhaseChanged: canvas.requestPaint()
  onScrubChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onMaxValueChanged: canvas.requestPaint()

  readonly property real scale: {
    if (maxValue > 0) return maxValue
    var m = 0
    for (var i = 0; i < (samples ? samples.length : 0); i++) if (samples[i] > m) m = samples[i]
    return Math.max(floorValue, m * 1.15, 1)
  }

  readonly property string shownValue: {
    if (scrub >= 0 && samples && samples.length) {
      var offset = samples.length - capacity
      var idx = scrub + offset
      if (idx >= 0 && idx < samples.length) return formatter ? formatter(samples[idx]) : String(Math.round(samples[idx]))
      return "--"
    }
    return valueText
  }

  Text {
    id: labelText
    x: 0
    y: Style.space(4)
    width: root.labelWidth
    text: root.label
    color: root.dim
    textFormat: Text.PlainText; font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1.2
    font.capitalization: Font.AllUppercase
  }

  Text {
    id: valueLabel
    anchors.right: parent.right
    y: Style.space(1)
    width: root.valueWidth
    horizontalAlignment: Text.AlignRight
    text: root.shownValue
    color: root.scrub >= 0 ? root.dim : root.ink
    textFormat: Text.PlainText; font.family: root.fontFamily
    font.pixelSize: root.compact ? Style.font.subtitle : Style.font.title
    font.weight: Font.DemiBold
    Behavior on color { enabled: root.animated; ColorAnimation { duration: 160 } }
  }

  Canvas {
    id: canvas
    x: root.labelWidth
    width: parent.width - root.labelWidth - root.valueWidth - Style.space(8)
    y: root.compact ? Style.space(6) : Style.space(20)
    height: root.compact ? Style.space(14) : parent.height - y - Style.space(2)
    Behavior on y { enabled: root.animated; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    renderStrategy: Canvas.Cooperative
    onHeightChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height
      var data = root.samples || []
      var n = data.length
      var cap = root.capacity
      var step = w / (cap - 1)
      var sc = root.scale

      // Baseline hairline.
      ctx.strokeStyle = root.hairline
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(0, h - 0.5)
      ctx.lineTo(w, h - 0.5)
      ctx.stroke()

      if (n < 2) return

      // Right-align the series: the newest sample sits at the right edge.
      // phase < 1 means the newest sample is still sliding in from the right.
      var shift = (1 - root.phase) * step
      var startX = w - (n - 1) * step + shift

      ctx.save()
      ctx.beginPath()
      ctx.rect(0, 0, w, h)
      ctx.clip()

      ctx.beginPath()
      var x0 = startX, y0 = h - Math.min(1, data[0] / sc) * (h - 2)
      ctx.moveTo(x0, h)
      ctx.lineTo(x0, y0)
      for (var i = 1; i < n; i++) {
        var x = startX + i * step
        var y = h - Math.min(1, Math.max(0, data[i]) / sc) * (h - 2)
        ctx.lineTo(x, y)
      }
      ctx.lineTo(startX + (n - 1) * step, h)
      ctx.closePath()
      ctx.fillStyle = root.fill
      ctx.fill()

      ctx.beginPath()
      ctx.moveTo(x0, y0)
      for (var j = 1; j < n; j++) {
        ctx.lineTo(startX + j * step, h - Math.min(1, Math.max(0, data[j]) / sc) * (h - 2))
      }
      ctx.strokeStyle = root.line
      ctx.lineWidth = 1.5
      ctx.lineJoin = "round"
      ctx.stroke()

      // Scrubber: vertical hairline plus a dot on the series.
      if (root.scrub >= 0) {
        var sx = root.scrub * step
        ctx.strokeStyle = Util.alpha(root.ink, 0.4)
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(Math.round(sx) + 0.5, 0)
        ctx.lineTo(Math.round(sx) + 0.5, h)
        ctx.stroke()
        var idx = root.scrub - (cap - n)
        if (idx >= 0 && idx < n) {
          var sy = h - Math.min(1, Math.max(0, data[idx]) / sc) * (h - 2)
          ctx.fillStyle = root.ink
          ctx.beginPath()
          ctx.arc(sx, sy, 2.5, 0, Math.PI * 2)
          ctx.fill()
        }
      }
      ctx.restore()
    }
  }
}
