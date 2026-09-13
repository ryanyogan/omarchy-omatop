import QtQuick
import qs.Commons

// A persistent, quiet action; no timer or animation while an update is pending.
Rectangle {
  id: root
  property string version: ""
  property color ink: Color.foreground
  property string fontFamily: Style.font.family
  signal update()
  implicitHeight: copy.implicitHeight + Style.space(24)
  color: Util.alpha(Color.accent, mouse.containsMouse ? 0.10 : 0.05)
  border.width: 1
  border.color: Util.alpha(Color.accent, 0.35)
  radius: Style.space(4)
  Accessible.role: Accessible.Button
  Accessible.name: "Update sampler to " + version
  Accessible.description: "Rebuild and restart Omatop's system monitor"
  Accessible.onPressAction: root.update()

  Column {
    id: copy
    x: Style.space(12); y: Style.space(12)
    width: parent.width - action.width - Style.space(40)
    spacing: Style.space(4)
    Text {
      width: parent.width
      text: "Sampler update available"
      color: root.ink
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
    }
    Text {
      width: parent.width
      text: "Update to " + root.version + " to finish upgrading Omatop."
      color: Util.alpha(root.ink, 0.70)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
    }
  }
  Text {
    id: action
    anchors.right: parent.right
    anchors.rightMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    text: "Update · B"
    color: Color.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.update()
  }
}
