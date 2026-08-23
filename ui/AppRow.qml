import QtQuick
import Quickshell
import qs.Commons
import "../Model.js" as Model

// One App or Job: themed icon, name and meta, then CPU and memory meters.
// Meters are scaled to the panel they sit in (cpuScale / memScale), so a
// 4% process in a list where the worst is 8% reads as half a bar.
Item {
  id: root

  property var app: null
  property bool hasCursor: false
  property bool isCulprit: false
  property bool isDetail: false
  property bool expanded: false
  property var processes: []
  property double nowMs: 0
  property bool useAverages: false      // show avgCpu / avgMem (offenders panel)
  property real cpuScale: 10
  property real memScale: 1024 * 1024 * 1024
  property color ink: "white"
  property color dim: Qt.rgba(1, 1, 1, 0.55)
  property color faint: Qt.rgba(1, 1, 1, 0.3)
  property color hairline: Qt.rgba(1, 1, 1, 0.1)
  property color selectedBackground: Qt.rgba(1, 1, 1, 0.08)
  property color selectedText: "white"
  property color accent: Color.accent
  property color pressureColor: accent
  property string fontFamily: Style.font.family
  property bool animated: true
  property int cornerRadius: Style.space(6)

  readonly property int rowHeight: Style.space(36)
  readonly property int procHeight: Style.space(22)
  readonly property int meterWidth: Style.space(96)
  readonly property int numWidth: Style.space(54)
  readonly property int iconSize: Style.space(18)

  implicitHeight: rowHeight + (expanded ? procList.height + Style.space(6) : 0)
  Behavior on implicitHeight { enabled: root.animated; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
  clip: true

  readonly property bool paused: app && app.state === "paused"
  readonly property bool stopping: app && app.state === "stopping"
  readonly property real cpuValue: app ? (useAverages && app.avgCpu !== undefined ? app.avgCpu : app.cpu) : 0
  readonly property real memValue: app ? (useAverages && app.avgMem !== undefined ? app.avgMem : app.mem) : 0
  readonly property string iconSource: app && app.icon ? Quickshell.iconPath(app.icon, true) : ""

  Rectangle {
    anchors.fill: parent
    radius: root.cornerRadius
    color: root.hasCursor ? root.selectedBackground : (root.isDetail ? Qt.rgba(1, 1, 1, 0.04) : "transparent")
    Behavior on color { enabled: root.animated; ColorAnimation { duration: 120 } }
  }

  Rectangle {
    x: 0
    y: Style.space(8)
    width: Style.space(2)
    height: root.rowHeight - Style.space(16)
    radius: 1
    color: root.isCulprit ? root.pressureColor : root.ink
    opacity: (root.isCulprit || root.isDetail) ? 1 : 0
    Behavior on opacity { enabled: root.animated; NumberAnimation { duration: 160 } }
  }

  Item {
    id: line
    x: Style.spacing.rowPaddingX
    width: parent.width - x * 2
    height: root.rowHeight

    // Icon, or a monogram tile when the theme has none.
    Item {
      id: iconSlot
      width: root.iconSize
      height: root.iconSize
      anchors.verticalCenter: parent.verticalCenter
      Image {
        anchors.fill: parent
        source: root.iconSource
        sourceSize.width: root.iconSize
        sourceSize.height: root.iconSize
        visible: root.iconSource !== ""
        smooth: true
        opacity: root.paused ? 0.5 : 1
      }
      Rectangle {
        anchors.fill: parent
        radius: Style.space(4)
        visible: root.iconSource === ""
        color: Qt.rgba(1, 1, 1, 0.08)
        border.width: 1
        border.color: root.hairline
        Text {
          anchors.centerIn: parent
          text: root.app ? (root.app.kind === "job" ? "›" : (root.app.name || "?").charAt(0).toUpperCase()) : ""
          color: root.dim
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    Text {
      id: nameText
      anchors.left: iconSlot.right
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(Style.space(60), meta.x - x - Style.space(12))
      elide: Text.ElideRight
      text: root.app ? root.app.name : ""
      color: root.hasCursor ? root.selectedText : (root.isCulprit ? root.pressureColor : root.ink)
      textFormat: Text.PlainText
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.weight: (root.isCulprit || root.isDetail) ? Font.DemiBold : Font.Normal
      font.strikeout: root.stopping
      opacity: root.paused ? 0.55 : 1
    }

    Row {
      id: meta
      anchors.right: meters.left
      anchors.rightMargin: Style.space(16)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)
      Text { visible: root.paused; text: "paused"; color: root.dim; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase }
      Text { visible: root.app && root.app.pinned === true; text: "pinned"; color: root.accent; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase }
      Text { visible: root.app && root.app.ports && root.app.ports.length > 0; text: root.app ? Model.ports(root.app.ports) : ""; color: root.ink; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
      Text { visible: root.app && root.app.tag && root.app.tag.length > 0; text: root.app ? root.app.tag : ""; color: root.faint; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase }
      Text { visible: root.app && root.app.recent === true; text: root.app ? Model.age(root.app.started, root.nowMs) : ""; color: root.faint; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    }

    Row {
      id: meters
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(14)
      Meter { value: root.cpuValue; scale: root.cpuScale; text: Model.pct(root.cpuValue); tint: root.isCulprit ? root.pressureColor : root.accent }
      Meter { value: root.memValue; scale: root.memScale; text: Model.bytes(root.memValue); tint: root.dim }
    }
  }

  // A meter: fixed-width track, fill proportional to the panel scale, value
  // beside it in a fixed column so digits never nudge the bar.
  component Meter: Row {
    id: meter
    property real value: 0
    property real scale: 1
    property string text: ""
    property color tint: root.accent
    spacing: Style.space(8)
    readonly property real fraction: scale > 0 ? Math.max(0, Math.min(1, value / scale)) : 0
    Rectangle {
      id: track
      width: root.meterWidth
      height: Style.space(5)
      radius: height / 2
      color: Qt.rgba(1, 1, 1, 0.08)
      anchors.verticalCenter: parent.verticalCenter
      Rectangle {
        width: meter.fraction > 0 ? Math.max(height, track.width * meter.fraction) : 0
        height: track.height
        radius: height / 2
        color: meter.tint
        // No easing: eighty bars easing every tick keeps the render loop
        // awake half of every second.
      }
    }
    Text {
      width: root.numWidth
      horizontalAlignment: Text.AlignRight
      text: parent.text
      color: root.hasCursor ? root.selectedText : root.ink
      textFormat: Text.PlainText
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  Column {
    id: procList
    anchors.top: line.bottom
    x: Style.spacing.rowPaddingX + root.iconSize + Style.space(10)
    width: parent.width - x - Style.spacing.rowPaddingX
    spacing: 0
    visible: root.expanded
    opacity: root.expanded ? 1 : 0
    Behavior on opacity { enabled: root.animated; NumberAnimation { duration: 160 } }

    Repeater {
      model: root.expanded ? root.processes : []
      delegate: Item {
        required property var modelData
        width: procList.width
        height: root.procHeight
        Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; width: Style.space(48); text: modelData.pid; color: root.faint; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        Text { anchors.left: parent.left; anchors.leftMargin: Style.space(52); anchors.right: procNums.left; anchors.rightMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideMiddle; text: (modelData.comm || "") + "  " + (modelData.cmd || ""); color: root.dim; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        Row {
          id: procNums
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          Text { width: root.numWidth; horizontalAlignment: Text.AlignRight; text: Model.pct(modelData.cpu); color: root.dim; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { width: root.numWidth + Style.space(14); horizontalAlignment: Text.AlignRight; text: Model.bytes(modelData.mem); color: root.faint; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        }
      }
    }
  }
}
