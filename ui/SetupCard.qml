import QtQuick
import qs.Commons

// The front door for the sampler. Shown in place of the instruments while
// the sampler is not running: not built yet, building, failed, or crashed.
// Mouse users get buttons; keyboard users get the same keys as always
// (b builds, a explains). "Learn more" flips the card to a plain account of
// what the sampler is, what it reads, why it exists and what it costs, so
// nobody has to run a build they do not understand.
Item {
  id: root

  property string state: "missing"     // missing | building | buildFailed | crashed | starting
  property string logTail: ""
  property bool about: false           // showing the explanation instead of the prompt
  property bool compact: false         // dropdown sizing
  property color ink: Color.foreground
  property color dim: Qt.darker(ink, 1.5)
  property color faint: Qt.darker(ink, 2.1)
  property color hairline: Util.alpha(ink, 0.12)
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property bool animated: true

  signal build()

  readonly property bool canBuild: state === "missing" || state === "buildFailed"
  readonly property bool building: state === "building"
  readonly property bool failed: state === "buildFailed"

  readonly property string title: {
    if (state === "missing") return "Needs the system monitor"
    if (state === "building") return "Building the system monitor"
    if (state === "buildFailed") return "The build failed"
    if (state === "crashed") return "The system monitor stopped"
    return "Starting the system monitor"
  }
  readonly property string body: {
    if (state === "missing") return "Omatop reads the machine through a small helper, omatop-sampler, that is built once on this computer. It takes about a minute. Omatop will notify you when a plugin update needs a newer sampler."
    if (state === "building") return "cargo build --release is running. The instruments light up when it finishes."
    if (state === "buildFailed") return "Check that rustc and cargo are installed (Omarchy ships both), then try again."
    if (state === "crashed") return "It is being restarted. If this keeps happening, the log is in the shell's output."
    return "Waiting for the first sample."
  }

  readonly property var sections: [
    ["What it is", "A small Rust program, shipped as source inside the plugin. It is compiled on your machine with the cargo that Omarchy already provides. Cargo may download build dependencies. Nothing is installed system-wide, and it does not need root."],
    ["What it does", "Once a second it reads /proc, /sys and cgroup v2 and writes one line of JSON to the shell. It never opens a network connection. Stopping, pausing and restarting go through the service manager or a signal to your own processes, and Stop always asks first."],
    ["Why it is needed", "Walking /proc every second from QML would keep the shell busy. The sampler does that walk in about 8 ms of native code, so with nothing open Omatop costs the shell around 0.3% of one core."],
    ["What it costs", "About 3.5 MiB of memory and 0.8% of one core at one sample a second, measured in docs/performance.md in the repository. A build takes about a minute; future sampler updates may need another build."]
  ]

  implicitHeight: card.implicitHeight

  Rectangle {
    id: card
    width: parent.width
    implicitHeight: column.implicitHeight + Style.spacing.panelPadding * 2
    radius: Style.space(10)
    color: Util.alpha(root.ink, 0.04)
    border.width: 1
    border.color: root.hairline

    Column {
      id: column
      x: Style.spacing.panelPadding
      y: Style.spacing.panelPadding
      width: parent.width - Style.spacing.panelPadding * 2
      spacing: Style.space(12)

      // ---- Prompt ----
      Row {
        width: parent.width
        spacing: Style.space(14)
        visible: !root.about

        // Icon tile: a chip mark, the same idea as the bar glyph.
        Rectangle {
          id: tile
          width: Style.space(40)
          height: Style.space(40)
          radius: Style.space(9)
          color: Util.alpha(root.failed ? root.urgent : root.accent, 0.14)
          border.width: 1
          border.color: Util.alpha(root.failed ? root.urgent : root.accent, 0.35)
          Rectangle {
            anchors.centerIn: parent
            width: Style.space(16); height: Style.space(16); radius: Style.space(3)
            color: "transparent"
            border.width: 2
            border.color: root.failed ? root.urgent : root.accent
            Rectangle { anchors.centerIn: parent; width: Style.space(6); height: Style.space(6); radius: 1; color: root.failed ? root.urgent : root.accent }
          }
        }

        Column {
          width: parent.width - tile.width - parent.spacing
          spacing: Style.space(4)
          Text {
            width: parent.width
            text: root.title
            wrapMode: Text.WordWrap
            color: root.failed ? root.urgent : root.ink
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: root.compact ? Style.font.subtitle : Style.font.title
            font.weight: Font.DemiBold
          }
          Text {
            width: parent.width
            text: root.body
            wrapMode: Text.WordWrap
            color: root.dim
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: root.compact ? Style.font.caption : Style.font.bodySmall
            lineHeight: 1.25
          }
        }
      }

      // Build log while building or after a failure.
      Text {
        width: parent.width
        visible: !root.about && root.logTail !== "" && (root.building || root.failed)
        text: root.logTail
        wrapMode: Text.WrapAnywhere
        color: root.faint
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        lineHeight: 1.25
      }

      // ---- About ----
      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: root.about
        Text {
          text: "About the system monitor"
          color: root.ink
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: root.compact ? Style.font.subtitle : Style.font.title
          font.weight: Font.DemiBold
        }
        Repeater {
          model: root.sections
          delegate: Column {
            required property var modelData
            width: parent.width
            spacing: Style.space(2)
            Text {
              text: modelData[0]
              color: root.dim
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
              font.capitalization: Font.AllUppercase
            }
            Text {
              width: parent.width
              text: modelData[1]
              wrapMode: Text.WordWrap
              color: root.ink
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: root.compact ? Style.font.caption : Style.font.bodySmall
              lineHeight: 1.3
            }
          }
        }
      }

      // ---- Buttons ----
      Row {
        spacing: Style.space(8)
        Button {
          visible: !root.about && root.canBuild
          label: root.failed ? "Try again" : "Build now"
          keyHint: "b"
          primary: true
          onClicked: root.build()
        }
        Button {
          visible: !root.about && root.building
          label: "Building…"
          enabled: false
        }
        Button {
          visible: !root.about
          label: "Learn more"
          keyHint: "a"
          onClicked: root.about = true
        }
        Button {
          visible: root.about && root.canBuild
          label: root.failed ? "Try again" : "Build now"
          keyHint: "b"
          primary: true
          onClicked: root.build()
        }
        Button {
          visible: root.about
          label: "Back"
          keyHint: "a"
          onClicked: root.about = false
        }
      }
    }
  }

  component Button: Rectangle {
    id: button
    property string label: ""
    property string keyHint: ""
    property bool primary: false
    signal clicked()
    width: buttonRow.implicitWidth + Style.space(24)
    height: Style.space(30)
    radius: height / 2
    color: primary ? Util.alpha(root.accent, area.containsMouse ? 0.32 : 0.22) : Util.alpha(root.ink, area.containsMouse ? 0.12 : 0.06)
    border.width: 1
    border.color: primary ? Util.alpha(root.accent, 0.55) : root.hairline
    opacity: enabled ? 1 : 0.6
    Behavior on color { enabled: root.animated; ColorAnimation { duration: 120 } }
    Row {
      id: buttonRow
      anchors.centerIn: parent
      spacing: Style.space(8)
      Text {
        text: button.label
        color: root.ink
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.weight: button.primary ? Font.DemiBold : Font.Normal
        anchors.verticalCenter: parent.verticalCenter
      }
      Rectangle {
        visible: button.keyHint !== ""
        anchors.verticalCenter: parent.verticalCenter
        width: hint.implicitWidth + Style.space(8)
        height: Style.space(16)
        radius: Style.space(3)
        color: Util.alpha(root.ink, 0.08)
        border.width: 1
        border.color: root.hairline
        Text {
          id: hint
          anchors.centerIn: parent
          text: button.keyHint
          color: root.dim
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }
    MouseArea {
      id: area
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      enabled: button.enabled
      onClicked: button.clicked()
    }
  }
}
