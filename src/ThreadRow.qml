import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// One thread. The dot says what it is doing: a pulsing ring while it works,
// solid while it is live in Amp's switcher, hollow when it is history. The
// row's actions appear under the cursor, so the list stays quiet otherwise.
CursorSurface {
  id: root

  property var thread: ({})
  property double now: Date.now()
  property bool renaming: false
  property bool confirming: false
  property bool busy: false
  property bool animate: true
  property color urgent: Commons.Color.urgent
  // The thread's voice on the scope while it works, and its project's hue.
  property color tint: accent
  property color projectColor: foreground
  property string fontFamily: Style.font.family

  signal hovered()
  signal activated()
  signal action(string name)
  signal renameAccepted(string name)
  signal renameCancelled()

  readonly property string phase: Model.state(thread)
  readonly property bool hot: hasCursor || mouse.containsMouse

  implicitHeight: Math.max(Style.space(44), body.implicitHeight + Style.space(14))

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onEntered: root.hovered()
    onPositionChanged: if (!root.hasCursor) root.hovered()
    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) root.action("continue")
      else if (mouse.button === Qt.RightButton) root.action("copy")
      else root.activated()
    }
  }

  // ---- status dot
  Item {
    id: dot
    width: Style.space(18)
    height: width
    anchors.left: parent.left
    anchors.leftMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter

    Rectangle {
      id: ripple
      anchors.centerIn: parent
      width: core.width
      height: width
      radius: width / 2
      color: "transparent"
      border.width: Math.max(1, Style.space(1.5))
      border.color: root.tint
      visible: root.phase === "working" || root.phase === "orb"
      opacity: 0

      SequentialAnimation on width {
        running: ripple.visible && root.animate && Style.reduceMotion !== true
        loops: Animation.Infinite
        NumberAnimation { from: core.width; to: dot.width; duration: 1400; easing.type: Easing.OutCubic }
        PauseAnimation { duration: 200 }
      }
      SequentialAnimation on opacity {
        running: ripple.visible && root.animate && Style.reduceMotion !== true
        loops: Animation.Infinite
        NumberAnimation { from: 0.9; to: 0; duration: 1400; easing.type: Easing.OutCubic }
        PauseAnimation { duration: 200 }
      }
    }

    Rectangle {
      id: core
      anchors.centerIn: parent
      width: Style.space(8)
      height: width
      radius: width / 2
      color: root.phase === "working" || root.phase === "orb" ? root.tint
        : (root.phase === "live" ? Util.alpha(root.foreground, 0.55) : "transparent")
      border.width: root.phase === "idle" ? Math.max(1, Style.space(1.5)) : 0
      border.color: Util.alpha(root.foreground, 0.35)
    }
  }

  Column {
    id: body
    anchors.left: dot.right
    anchors.leftMargin: Style.space(8)
    anchors.right: trailing.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      visible: !root.renaming
      width: parent.width
      text: root.thread.title || "Untitled thread"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: root.phase === "working" || root.phase === "orb"
      elide: Text.ElideRight
    }

    TextField {
      id: nameField
      visible: root.renaming
      width: parent.width
      verticalPadding: Style.space(3)
      foreground: root.foreground
      accent: root.accent
      font.family: root.fontFamily
      placeholderText: "New name"
      onVisibleChanged: if (visible) { text = root.thread.title || ""; forceActiveFocus(); selectAll() }
      Keys.onReturnPressed: root.renameAccepted(text)
      Keys.onEnterPressed: root.renameAccepted(text)
      Keys.onEscapePressed: root.renameCancelled()
    }

    Row {
      width: parent.width
      spacing: 0

      Text {
        id: projectText
        textFormat: Text.PlainText
        visible: !root.confirming && !root.renaming && text !== ""
        text: root.thread.project || ""
        color: root.projectColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width - (projectText.visible ? projectText.implicitWidth : 0)
        text: root.confirming ? "Press x again to delete this thread for good"
          : (root.renaming ? "Enter saves  ·  Esc cancels"
            : (projectText.visible && Model.subtitleRest(root.thread, root.now) ? "  ·  " : "") + Model.subtitleRest(root.thread, root.now))
        color: root.confirming ? root.urgent : Util.alpha(root.foreground, 0.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  Item {
    id: trailing
    anchors.right: parent.right
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    width: actions.visible ? actions.width : ageText.implicitWidth
    height: actions.height

    Text {
      id: ageText
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: !actions.visible && !root.renaming
      text: root.busy ? "…" : (root.thread.working ? "live" : Model.ago(root.thread.updatedAt, root.now))
      color: root.thread.working ? root.tint : Util.alpha(root.foreground, 0.42)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: root.thread.working === true
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      visible: root.hot && !root.renaming && !root.confirming
      opacity: visible ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: (Style.reduceMotion === true ? 0 : 120) } }

      Repeater {
        model: [
          { name: "continue", glyph: "󰆍", tip: "Continue in a terminal  (c)" },
          { name: "open", glyph: "󰖟", tip: "Open on ampcode.com  (Enter)" },
          { name: "copy", glyph: "󰆏", tip: "Copy link  (y)" },
          { name: "rename", glyph: "󰏫", tip: "Rename  (e)" },
          { name: "archive", glyph: "󰀼", tip: "Archive  (a)" }
        ]

        PanelActionButton {
          required property var modelData
          iconText: modelData.glyph
          tooltipText: modelData.tip
          foreground: Util.alpha(root.foreground, 0.75)
          hoverColor: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.body
          size: Style.space(24)
          onHovered: function(isHovered) { if (isHovered) root.hovered() }
          onClicked: root.action(modelData.name)
        }
      }
    }
  }
}
