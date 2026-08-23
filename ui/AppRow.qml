import QtQuick
import qs.Commons
import "../Model.js" as Model

// One App or Job in the list. Columns are fixed-width so numerals never jitter.
Item {
  id: root

  property var app: null
  property bool hasCursor: false
  property bool isCulprit: false
  property bool isDetail: false
  property bool expanded: false
  property var processes: []
  property double nowMs: 0
  property color ink: Color.foreground
  property color dim: Qt.darker(ink, 1.5)
  property color faint: Qt.darker(ink, 2.1)
  property color hairline: Util.alpha(ink, 0.12)
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color pressureColor: ink
  property string fontFamily: Style.font.family
  property bool animated: true
  property bool showGpu: true
  property int cornerRadius: Style.cornerRadius

  readonly property int rowHeight: Style.space(30)
  readonly property int procHeight: Style.space(22)
  readonly property int numWidth: Style.space(58)
  readonly property int gpuWidth: showGpu ? Style.space(48) : 0

  implicitHeight: rowHeight + (expanded ? procList.height + Style.space(6) : 0)
  Behavior on implicitHeight { enabled: root.animated; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
  clip: true

  readonly property bool paused: app && app.state === "paused"
  readonly property bool stopping: app && app.state === "stopping"
  readonly property color nameColor: hasCursor ? selectedText : (isCulprit ? pressureColor : ink)

  Rectangle {
    anchors.fill: parent
    radius: Math.min(root.cornerRadius, Style.space(6))
    color: root.hasCursor ? root.selectedBackground : (root.isDetail ? Util.alpha(root.ink, 0.04) : "transparent")
    Behavior on color { enabled: root.animated; ColorAnimation { duration: 120 } }
  }

  // Detail marker on the left edge: a thin bar in the pressure colour for the
  // culprit, ink for the focused App.
  Rectangle {
    x: 0
    y: Style.space(6)
    width: Style.space(2)
    height: root.rowHeight - Style.space(12)
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

    // Leading glyphs: pin and job marker.
    Text {
      id: marker
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      text: root.app && root.app.pinned ? "●" : (root.app && root.app.kind === "job" ? "›" : "")
      color: root.app && root.app.pinned ? root.ink : root.faint
      textFormat: Text.PlainText; font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: nameText
      anchors.left: marker.right
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(Style.space(60), parent.width - marker.width - meta.width - numbers.width - Style.space(16))
      elide: Text.ElideRight
      text: root.app ? root.app.name : ""
      color: root.nameColor
      textFormat: Text.PlainText; font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.weight: (root.isCulprit || root.isDetail) ? Font.DemiBold : Font.Normal
      font.strikeout: root.stopping
      opacity: root.paused ? 0.55 : 1
      Behavior on color { enabled: root.animated; ColorAnimation { duration: 160 } }
    }

    // Meta: tag, ports, age, state. Caption sized, dim, right next to numbers.
    Row {
      id: meta
      anchors.right: numbers.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        visible: root.paused
        text: "paused"
        color: root.dim
        textFormat: Text.PlainText; font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.0
        font.capitalization: Font.AllUppercase
      }
      Text {
        visible: root.app && root.app.ports && root.app.ports.length > 0
        text: root.app ? Model.ports(root.app.ports) : ""
        color: root.hasCursor ? root.selectedText : root.ink
        textFormat: Text.PlainText; font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        visible: root.app && root.app.tag && root.app.tag.length > 0
        text: root.app ? root.app.tag : ""
        color: root.faint
        textFormat: Text.PlainText; font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.0
        font.capitalization: Font.AllUppercase
      }
      Text {
        visible: root.app && root.app.recent === true
        text: root.app ? Model.age(root.app.started, root.nowMs) : ""
        color: root.faint
        textFormat: Text.PlainText; font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      id: numbers
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        width: root.numWidth
        horizontalAlignment: Text.AlignRight
        text: root.app ? Model.pct(root.app.cpu) : ""
        color: root.hasCursor ? root.selectedText : (root.isCulprit ? root.pressureColor : root.ink)
        textFormat: Text.PlainText; font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        width: root.numWidth
        horizontalAlignment: Text.AlignRight
        text: root.app ? Model.bytes(root.app.mem) : ""
        color: root.hasCursor ? root.selectedText : root.dim
        textFormat: Text.PlainText; font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        width: root.gpuWidth
        visible: root.showGpu
        horizontalAlignment: Text.AlignRight
        text: root.app && root.app.gpu >= 0 ? Model.pct(root.app.gpu) : "·"
        color: root.hasCursor ? root.selectedText : root.faint
        textFormat: Text.PlainText; font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }

  // Expanded: the App's Processes, indented, caption sized.
  Column {
    id: procList
    anchors.top: line.bottom
    x: Style.spacing.rowPaddingX + Style.space(14)
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
        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(48)
          text: modelData.pid
          color: root.faint
          textFormat: Text.PlainText; font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(52)
          anchors.right: procNums.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideMiddle
          text: (modelData.comm || "") + "  " + (modelData.cmd || "")
          color: root.dim
          textFormat: Text.PlainText; font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Row {
          id: procNums
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          Text { width: root.numWidth; horizontalAlignment: Text.AlignRight; text: Model.pct(modelData.cpu); color: root.dim; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { width: root.numWidth; horizontalAlignment: Text.AlignRight; text: Model.bytes(modelData.mem); color: root.faint; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { width: root.gpuWidth; visible: root.showGpu; horizontalAlignment: Text.AlignRight; text: modelData.state || ""; color: root.faint; textFormat: Text.PlainText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        }
      }
    }
  }
}
