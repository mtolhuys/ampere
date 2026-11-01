import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A fuel gauge: what is left of an allowance, with a hairline where an even
// spend through the period would be today. Left of the line is ahead of pace.
Item {
  id: root

  property string label: ""
  property string value: ""
  property string detail: ""
  property real fraction: 0
  property real paceAt: -1
  property bool known: true
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family

  readonly property bool low: known && fraction < 0.15
  // The fill's hue; a low allowance always takes the theme's warning color.
  property color hue: accent
  readonly property color tone: low ? urgent : hue

  implicitHeight: head.implicitHeight + Style.space(7) + track.height + (foot.visible ? foot.implicitHeight + Style.space(4) : 0)

  property real shown: 0
  Component.onCompleted: shown = Math.max(0, Math.min(1, fraction))
  onFractionChanged: shown = Math.max(0, Math.min(1, fraction))
  Behavior on shown { NumberAnimation { duration: (Style.reduceMotion === true ? 0 : 700); easing.type: Easing.OutQuint } }

  Item {
    id: head
    width: parent.width
    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)

    Text {
      id: labelText
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: root.label.toUpperCase()
      color: Util.alpha(root.foreground, 0.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }

    Text {
      id: valueText
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: root.value
      color: root.low ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }
  }

  Rectangle {
    id: track
    anchors.top: head.bottom
    anchors.topMargin: Style.space(7)
    width: parent.width
    height: Math.max(4, Style.space(6))
    radius: height / 2
    color: Util.alpha(root.foreground, 0.09)

    // Soft halo under the fill.
    Rectangle {
      x: -Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      width: fill.width + Style.space(4)
      height: parent.height + Style.space(6)
      radius: height / 2
      color: Util.alpha(root.tone, 0.12)
      visible: root.known && root.shown > 0.01
    }

    Rectangle {
      id: fill
      height: parent.height
      radius: parent.radius
      width: root.known ? Math.max(height, parent.width * root.shown) : 0
      visible: root.known && root.shown > 0.005
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: Util.alpha(root.tone, 0.55) }
        GradientStop { position: 1.0; color: root.tone }
      }
    }

    Rectangle {
      visible: root.known && root.paceAt >= 0
      x: Math.round(parent.width * Math.max(0, Math.min(1, root.paceAt))) - width / 2
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(2, Style.space(2))
      height: parent.height + Style.space(6)
      radius: width / 2
      color: root.foreground
      opacity: 0.55
    }
  }

  Text {
    id: foot
    textFormat: Text.PlainText
    visible: root.detail !== ""
    anchors.top: track.bottom
    anchors.topMargin: Style.space(4)
    width: parent.width
    text: root.detail
    color: Util.alpha(root.foreground, 0.45)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
}
