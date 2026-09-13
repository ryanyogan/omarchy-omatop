import QtQuick
import qs.Commons

// Fixed scene-graph rectangles, faded on the panel's shared 25 Hz clock.
// No per-cell animations, paths or texture uploads. History is peak-binned so
// a short spike survives compression; live mode gives each core its own column.
Item {
  id: root
  property var values: []
  property bool history: true
  property int capacity: 120
  property int rows: 8
  property int columns: history ? 36 : Math.min(64, values.length)
  property bool animated: true
  property color ink: Color.accent
  property color track: Qt.rgba(1, 1, 1, 0.06)
  property real ceiling: 100
  readonly property real cellWidth: width / Math.max(1, columns)
  readonly property real cellHeight: height / rows
  readonly property var levels: {
    var result = []
    var data = values || []
    var slots = history ? capacity : data.length
    var offset = history ? Math.max(0, capacity - data.length) : 0
    for (var col = 0; col < columns; col++) {
      var start = Math.floor(col * slots / columns)
      var end = Math.max(start + 1, Math.floor((col + 1) * slots / columns))
      var peak = 0
      for (var i = start; i < end; i++) {
        var idx = i - offset
        if (idx >= 0 && idx < data.length) peak = Math.max(peak, Number(data[idx]) || 0)
      }
      result.push(peak > 0 ? Math.max(1, Math.min(rows, Math.ceil(peak / Math.max(1, ceiling) * rows))) : 0)
    }
    return result
  }
  // All matrices share one short-lived clock, so a tiny changed cell cannot
  // independently drive a full 5K compositor surface at display refresh rate.
  property double frameTime: 0
  property double fadeStarted: 0
  property bool fading: false
  property bool initialized: false
  property int previousRows: rows
  property var targetLevels: []
  property var fromAmounts: []
  readonly property real phase: fading ? Math.max(0, Math.min(1, (frameTime - fadeStarted) / 180)) : 1
  readonly property real easedPhase: phase * phase * (3 - 2 * phase)
  signal fadeRequested()

  function cellAmount(col, row) {
    var target = row < (targetLevels[col] || 0) ? 1 : 0
    var from = fromAmounts[col * rows + row]
    // Unchanged cells never bind to the clock, so only the moving edge updates.
    if (!fading || from === undefined || from === target) return target
    return from + (target - from) * easedPhase
  }

  function syncLevels() {
    var next = levels
    var same = previousRows === rows && next.length === targetLevels.length
    if (same) {
      for (var i = 0; i < next.length; i++) {
        if (next[i] !== targetLevels[i]) { same = false; break }
      }
    }
    if (same) return
    var shouldFade = initialized && animated && visible
      && previousRows === rows && next.length === targetLevels.length
    var from = []
    if (shouldFade) {
      for (var col = 0; col < next.length; col++) {
        for (var row = 0; row < rows; row++) from.push(cellAmount(col, row))
      }
    }
    fromAmounts = from
    targetLevels = next.slice()
    previousRows = rows
    fadeStarted = Date.now()
    fading = shouldFade
    if (fading) fadeRequested()
  }

  onLevelsChanged: syncLevels()
  onAnimatedChanged: if (!animated) fading = false
  onVisibleChanged: if (!visible) fading = false
  onFrameTimeChanged: if (fading && frameTime >= fadeStarted + 180) fading = false
  Component.onCompleted: { syncLevels(); initialized = true }

  Repeater {
    model: root.columns
    Item {
      id: column
      required property int index
      x: index * root.cellWidth
      width: root.cellWidth
      height: root.height
      Repeater {
        model: root.rows
        Rectangle {
          required property int index
          x: Math.floor((root.cellWidth - width) / 2)
          y: Math.round(root.height - (index + 1) * root.cellHeight)
          width: Math.max(1, Math.floor(root.cellWidth - Style.space(2)))
          height: Math.max(1, Math.floor(root.cellHeight - Style.space(2)))
          readonly property real amount: root.cellAmount(column.index, index)
          color: Qt.rgba(root.track.r + (root.ink.r - root.track.r) * amount,
                         root.track.g + (root.ink.g - root.track.g) * amount,
                         root.track.b + (root.ink.b - root.track.b) * amount,
                         root.track.a + (root.ink.a - root.track.a) * amount)
        }
      }
    }
  }
}
