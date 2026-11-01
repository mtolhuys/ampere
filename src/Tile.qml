import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A launcher tile in the panel's footer: a glyph over a word.
CursorSurface {
  id: root

  property string glyph: ""
  property string text: ""
  property string tooltip: ""
  property color tint: accent
  property string fontFamily: Style.font.family

  signal clicked()

  hasCursor: mouse.containsMouse
  bordered: true
  implicitHeight: column.implicitHeight + Style.space(14)

  Column {
    id: column
    anchors.centerIn: parent
    spacing: Style.space(3)

    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.glyph
      color: mouse.containsMouse ? root.tint : Util.alpha(root.tint, 0.8)
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconLarge
      Behavior on color { ColorAnimation { duration: (Style.reduceMotion === true ? 0 : 120) } }
    }

    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.text
      color: Util.alpha(root.foreground, 0.62)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }

  PanelToolTip {
    visible: root.tooltip !== "" && mouse.containsMouse
    text: root.tooltip
  }
}
