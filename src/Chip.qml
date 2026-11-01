import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A pill for a choice: a mode, a directory, Fast. Selected chips take the
// accent; the rest stay outlines.
BorderSurface {
  id: root

  property string text: ""
  property string glyph: ""
  property string tooltip: ""
  property bool selected: false
  // The chip's own hue when chosen: a mode's, Fast's, or the accent.
  property color tint: accent
  // Long labels elide past this width; 0 leaves them whole.
  property real maxTextWidth: 0
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family

  signal clicked()

  readonly property bool hot: mouse.containsMouse

  implicitWidth: row.implicitWidth + Style.space(18)
  implicitHeight: Math.max(Style.space(24), row.implicitHeight + Style.space(8))
  radius: height / 2
  color: selected ? Util.alpha(tint, 0.2) : (hot ? Util.alpha(tint, 0.08) : "transparent")
  borderSpec: selected
    ? Border.flat(tint, Math.max(1, Style.space(1)))
    : Border.flat(Util.alpha(foreground, hot ? 0.35 : 0.16), Math.max(1, Style.space(1)))

  Behavior on color { ColorAnimation { duration: (Style.reduceMotion === true ? 0 : 120) } }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(5)

    Text {
      textFormat: Text.PlainText
      visible: root.glyph !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: root.glyph
      color: root.selected || root.hot ? root.tint : Util.alpha(root.tint, 0.75)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.text
      width: root.maxTextWidth > 0 ? Math.min(implicitWidth, root.maxTextWidth) : implicitWidth
      elide: Text.ElideMiddle
      color: root.selected ? root.foreground : Util.alpha(root.foreground, 0.72)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: root.selected
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
