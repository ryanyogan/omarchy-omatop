import QtQuick
import Quickshell
import "ui" as Widgets
Scope {
  id: root
  property int requests: 0
  property bool failed: false
  function check(ok, message) {
    if (!ok) { failed = true; console.error("FAIL: " + message); Qt.quit(); throw new Error(message) }
  }
  Widgets.DotMatrix {
    id: dots
    width: 280; height: 56; columns: 2; rows: 8; capacity: 2
    values: [0, 0]
    onFadeRequested: root.requests++
  }
  Timer {
    interval: 10; running: true
    onTriggered: {
      root.check(!dots.fading, "initial state is settled")
      dots.values = [100, 0]
      root.check(dots.fading && root.requests === 1, "one shared-clock request for changed levels")
      dots.frameTime = dots.fadeStarted + 90
      root.check(Math.abs(dots.cellAmount(0, 0) - 0.5) < 0.001, "changed dots fade smoothly at midpoint")
      root.check(dots.cellAmount(1, 0) === 0, "unchanged dots stay dark")
      dots.frameTime = dots.fadeStarted + 200
      root.check(!dots.fading && dots.cellAmount(0, 7) === 1, "fade settles on target")
      dots.values = [100, 0]
      root.check(!dots.fading && root.requests === 1, "unchanged levels do not request a repaint clock")
      dots.values = [0, 0]
      root.check(dots.fading, "falling values also fade")
      dots.animated = false
      root.check(!dots.fading && dots.cellAmount(0, 0) === 0, "reduced motion settles immediately")
      dots.animated = true
      dots.values = [100, 100]
      dots.visible = false
      root.check(!dots.fading, "hidden matrix stops fading")
      console.log("PASS: one clock request, midpoint interpolation, unchanged cells, completion, unchanged sample, reduced motion, hidden state")
      Qt.quit()
    }
  }
}
