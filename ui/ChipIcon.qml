import QtQuick

// The Omatop mark at any size: the same chip the bar draws — rounded die,
// three legs a side, a solid core — so the dropdown's hero and the bar agree
// on what the plugin looks like. Colour is the caller's; the shape never moves.
Canvas {
  id: root

  property color tint: "white"
  property real iconSize: 24

  width: iconSize
  height: iconSize
  renderStrategy: Canvas.Cooperative

  onTintChanged: requestPaint()
  onIconSizeChanged: requestPaint()

  onPaint: {
    var ctx = root.getContext("2d")
    if (!ctx) return
    ctx.reset()

    var w = root.width
    var h = root.height
    if (w <= 0 || h <= 0) return

    var leg = Math.max(2, Math.round(w * 0.14))
    var lw = Math.max(1, Math.round(w * 0.09))
    var bodyR = Math.max(1.5, w * 0.12)
    var x0 = leg, y0 = leg
    var bw = w - leg * 2, bh = h - leg * 2

    ctx.strokeStyle = root.tint
    ctx.fillStyle = root.tint
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
