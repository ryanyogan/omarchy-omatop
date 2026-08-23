import QtQuick
import qs.Commons

// The `?` card: every key the overlay understands, grouped by what it does.
Item {
  id: root

  property bool opened: false
  property color ink: Color.foreground
  property color dim: Qt.darker(ink, 1.5)
  property color faint: Qt.darker(ink, 2.1)
  property color hairline: Util.alpha(ink, 0.12)
  property string fontFamily: Style.font.family
  property bool animated: true

  signal dismissed()

  visible: opacity > 0
  opacity: opened ? 1 : 0
  Behavior on opacity { enabled: root.animated; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

  readonly property var groups: [
    ["Move", [
      ["j  k", "down, up (takes a count: 5j)"],
      ["gg  G", "first, last (12G jumps to row 12)"],
      ["ctrl-d  ctrl-u", "half page"],
      ["H  M  L", "top, middle, bottom of the view"],
      ["{  }", "previous, next section"]
    ]],
    ["Look", [
      ["enter  l", "focus an App in the ledger"],
      ["h  esc", "unfocus"],
      ["o  space", "show the App's processes"],
      ["za  zM  zR", "fold section, fold all, unfold all"],
      [",  .  0", "scrub the timelines, back to live"]
    ]],
    ["Find", [
      ["/", "filter by name, command or :port"],
      ["n  N", "next, previous in the filtered list"],
      ["sc  sm  sg  sn", "sort by cpu, mem, gpu, name"]
    ]],
    ["Act", [
      ["p", "pin (watched in the bar dropdown)"],
      ["ss", "pause or resume"],
      ["x", "stop (asks first)"],
      ["r", "restart a Service"],
      ["q", "close"]
    ]]
  ]

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.55)
    MouseArea { anchors.fill: parent; onClicked: root.dismissed() }
  }

  Rectangle {
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(80), Style.space(760))
    height: grid.implicitHeight + Style.spacing.panelPadding * 2 + Style.space(40)
    radius: Style.space(10)
    color: Qt.rgba(0.06, 0.06, 0.06, 1)
    border.width: 1
    border.color: root.hairline
    scale: root.opened ? 1 : 0.98
    Behavior on scale { enabled: root.animated; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    Text {
      id: title
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.margins: Style.spacing.panelPadding
      text: "Keys"
      color: root.ink
      textFormat: Text.PlainText; font.family: root.fontFamily
      font.pixelSize: Style.font.heading
      font.weight: Font.DemiBold
    }
    Text {
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.spacing.panelPadding
      text: "any key closes"
      color: root.faint
      textFormat: Text.PlainText; font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Grid {
      id: grid
      anchors.top: title.bottom
      anchors.topMargin: Style.space(14)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.spacing.panelPadding
      columns: 2
      columnSpacing: Style.space(28)
      rowSpacing: Style.space(16)

      Repeater {
        model: root.groups
        delegate: Column {
          required property var modelData
          width: (grid.width - grid.columnSpacing) / 2
          spacing: Style.space(4)
          Text {
            text: modelData[0]
            color: root.dim
            textFormat: Text.PlainText; font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.2
            font.capitalization: Font.AllUppercase
            bottomPadding: Style.space(4)
          }
          Repeater {
            model: modelData[1]
            delegate: Item {
              required property var modelData
              width: parent.width
              height: Style.space(20)
              Text {
                x: 0
                width: Style.space(120)
                text: modelData[0]
                color: root.ink
                textFormat: Text.PlainText; font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                x: Style.space(120)
                width: parent.width - x
                text: modelData[1]
                elide: Text.ElideRight
                color: root.dim
                textFormat: Text.PlainText; font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }
      }
    }
  }
}
