import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The live current: an oscilloscope trace of the threads Amp is working on.
// Each working thread adds a voice, so the line beats instead of just getting
// louder; idle is a flat line with a slow heartbeat crossing. It only animates
// while the panel is open and motion is on.
BorderSurface {
  id: root

  property int working: 0
  // One color per working thread, in the order the rows list them; each
  // draws its own voice. Empty draws the idle heartbeat in the accent.
  property var voices: []
  property bool animate: true
  property bool stale: false
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  property string leftLabel: ""
  property string rightLabel: ""
  property string footLabel: ""

  // Eased rather than stepped, so a thread starting or stopping swells the
  // line instead of snapping it.
  property real level: working
  Behavior on level { NumberAnimation { duration: (Style.reduceMotion === true ? 0 : 900); easing.type: Easing.InOutCubic } }

  property real t: 0

  implicitHeight: Style.space(86)
  radius: Style.cornerRadius
  color: Util.alpha(foreground, 0.035)
  borderSpec: Border.controlSpec("normal", foreground, accent)
  clip: true

  FrameAnimation {
    running: root.animate && root.visible && Style.reduceMotion !== true
    onTriggered: {
      root.t += Math.min(frameTime, 0.05)
      scope.requestPaint()
    }
  }

  onLevelChanged: scope.requestPaint()
  onWidthChanged: scope.requestPaint()

  Canvas {
    id: scope
    anchors.fill: parent
    anchors.margins: Style.space(1)
    renderStrategy: Canvas.Cooperative

    function rgba(c, a) { return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")" }

    function line(ctx, x0, y0, x1, y1) { ctx.beginPath(); ctx.moveTo(x0, y0); ctx.lineTo(x1, y1); ctx.stroke() }
    function dot(ctx, x, y, r, style) { ctx.fillStyle = style; ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill() }

    // Graticule: faint divisions like a bench scope, the zero line a touch brighter.
    function drawGrid(ctx, w, h, mid, fg) {
      ctx.lineWidth = 1
      ctx.strokeStyle = rgba(fg, 0.05)
      var step = Math.max(18, Math.round(w / 16))
      for (var gx = step; gx < w; gx += step) line(ctx, gx + 0.5, 0, gx + 0.5, h)
      for (var gy = mid % step; gy < h; gy += step) line(ctx, 0, gy + 0.5, w, gy + 0.5)
      ctx.strokeStyle = rgba(fg, 0.09)
      line(ctx, 0, Math.round(mid) + 0.5, w, Math.round(mid) + 0.5)
    }

    // The trace, blended between the whole thread counts either side of the
    // eased level so a change swells rather than jumps.
    function tracePoints(w, mid, amp, samples) {
      var n = root.level, lo = Math.floor(n), hi = Math.ceil(n), mix = n - lo
      var points = []
      for (var i = 0; i <= samples; i++) {
        var x = i / samples
        var y = Model.wave(x, root.t, lo) * (1 - mix) + Model.wave(x, root.t, hi) * mix
        points.push([x * w, mid - y * amp])
      }
      return points
    }

    function voicePoints(w, mid, amp, samples, k) {
      var points = []
      for (var i = 0; i <= samples; i++) points.push([i / samples * w, mid - Model.voice(i / samples, root.t, k) * amp])
      return points
    }

    function path(ctx, points) {
      ctx.beginPath()
      ctx.moveTo(points[0][0], points[0][1])
      for (var p = 1; p < points.length; p++) ctx.lineTo(points[p][0], points[p][1])
    }

    // Fill under the curve, then four strokes for the phosphor bloom.
    function drawTrace(ctx, points, w, h, top, ac, busy) {
      var fill = ctx.createLinearGradient(0, top, 0, h)
      fill.addColorStop(0, rgba(ac, busy ? 0.16 : 0.06))
      fill.addColorStop(1, rgba(ac, 0))
      path(ctx, points)
      ctx.lineTo(w, h); ctx.lineTo(0, h); ctx.closePath()
      ctx.fillStyle = fill
      ctx.fill()
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      var glow = [[9, 0.05], [5, 0.12], [2.6, 0.30], [1.4, 1.0]]
      for (var g = 0; g < glow.length; g++) {
        var grad = ctx.createLinearGradient(0, 0, w, 0)
        grad.addColorStop(0, rgba(ac, 0))
        grad.addColorStop(0.12, rgba(ac, glow[g][1]))
        grad.addColorStop(0.88, rgba(ac, glow[g][1]))
        grad.addColorStop(1, rgba(ac, 0))
        ctx.strokeStyle = grad
        ctx.lineWidth = glow[g][0]
        path(ctx, points)
        ctx.stroke()
      }
    }

    // A beam that sweeps across while threads work, riding the trace.
    function drawBeam(ctx, points, w, h, ac, at) {
      var sweep = at === undefined ? (root.t * 0.35) % 1 : at
      var sx = sweep * w
      var beam = ctx.createLinearGradient(sx - w * 0.18, 0, sx, 0)
      beam.addColorStop(0, rgba(ac, 0))
      beam.addColorStop(1, rgba(ac, 0.05 * Math.min(1, root.level)))
      ctx.fillStyle = beam
      ctx.fillRect(sx - w * 0.18, 0, w * 0.18, h)
      var py = points[Math.min(points.length - 1, Math.round(sweep * (points.length - 1)))][1]
      dot(ctx, sx, py, 5, rgba(ac, 0.25))
      dot(ctx, sx, py, 2, rgba(ac, 1))
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height
      if (w < 4 || h < 4) return
      var mid = h * 0.56
      var busy = root.level > 0.01
      var ac = root.stale ? root.foreground : root.accent
      var amp = h * (busy ? 0.30 : 0.36)
      drawGrid(ctx, w, h, mid, root.foreground)
      var samples = Math.max(60, Math.round(w / 2))
      if (!busy || root.stale || root.voices.length === 0) {
        var points = tracePoints(w, mid, amp, samples)
        drawTrace(ctx, points, w, h, mid - amp, ac, busy)
        if (busy) drawBeam(ctx, points, w, h, ac)
        return
      }
      // Back to front, so the first thread's voice lies on top. A voice
      // fades in and out with the eased level rather than popping.
      var count = Math.min(root.voices.length, 5)
      for (var k = count - 1; k >= 0; k--) {
        var fade = Math.max(0, Math.min(1, root.level - k))
        if (fade <= 0.01) continue
        var vp = voicePoints(w, mid, amp * fade, samples, k)
        ctx.globalAlpha = Math.max(0.15, fade)
        drawTrace(ctx, vp, w, h, mid - amp, root.voices[k], true)
        drawBeam(ctx, vp, w, h, root.voices[k], (root.t * 0.35 + k * 0.23) % 1)
      }
      ctx.globalAlpha = 1
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors { left: parent.left; top: parent.top; leftMargin: Style.space(10); topMargin: Style.space(7) }
    text: root.leftLabel
    color: Util.alpha(root.foreground, 0.55)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.4
  }

  Row {
    anchors { right: parent.right; top: parent.top; rightMargin: Style.space(10); topMargin: Style.space(5) }
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      anchors.baseline: unit.baseline
      text: root.rightLabel
      color: root.working > 0 ? (root.voices.length ? root.voices[0] : root.accent) : Util.alpha(root.foreground, 0.7)
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
    }
    Text {
      id: unit
      textFormat: Text.PlainText
      text: root.working === 1 ? "thread" : "threads"
      color: Util.alpha(root.foreground, 0.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors { left: parent.left; bottom: parent.bottom; leftMargin: Style.space(10); bottomMargin: Style.space(6) }
    text: root.footLabel
    color: Util.alpha(root.foreground, 0.42)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
