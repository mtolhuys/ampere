import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// The active theme's own hues, read from its colors.toml (read only). The
// shell exposes foreground, accent and urgent; every Omarchy theme also tunes
// red, yellow, green, cyan, blue and magenta for its background, so color
// drawn from here sits in the theme instead of on top of it. A hue the theme
// leaves out falls back to the accent. Re-read whenever the shell's own
// colors change, which is what a theme switch does.
Item {
  id: root
  visible: false

  property color red: Commons.Color.urgent
  property color yellow: Commons.Color.accent
  property color green: Commons.Color.accent
  property color cyan: Commons.Color.accent
  property color blue: Commons.Color.accent
  property color magenta: Commons.Color.accent

  // The order threads take their voice in; red stays the theme's warning.
  readonly property var voices: [cyan, magenta, green, blue, yellow]

  function hue(name) {
    return ({ red: red, yellow: yellow, green: green, cyan: cyan, blue: blue, magenta: magenta })[name] || Commons.Color.accent
  }

  // A stable hue for any text, such as a project name.
  function hueFor(key) {
    return voices[Math.abs(hash(String(key || ""))) % voices.length]
  }
  function hash(text) {
    var h = 0
    for (var i = 0; i < text.length; i++) h = ((h << 5) - h + text.charCodeAt(i)) | 0
    return h
  }

  function load(text) {
    var found = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = /^\s*(red|yellow|green|cyan|blue|magenta|color[1-6])\s*=\s*["']?(#[0-9a-fA-F]{6,8})["']?/.exec(lines[i])
      if (m) found[m[1]] = m[2]
    }
    var names = ["red", "green", "yellow", "blue", "magenta", "cyan"]
    for (var j = 0; j < names.length; j++) {
      var value = found[names[j]] || found["color" + (j + 1)]
      root[names[j]] = value ? value : (names[j] === "red" ? Commons.Color.urgent : Commons.Color.accent)
    }
  }

  FileView {
    id: file
    path: Commons.Color.currentThemePath + "/colors.toml"
    printErrors: false
    onLoaded: root.load(text())
  }

  Connections {
    target: Commons.Color
    function onAccentChanged() { file.reload() }
    function onForegroundChanged() { file.reload() }
    function onBackgroundChanged() { file.reload() }
  }
}
