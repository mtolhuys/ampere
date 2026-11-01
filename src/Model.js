.pragma library

// Pure helpers for Ampere's panel. No QML types in here, so tests can load
// this file in node (tests/model.test.js) exactly as the shell does.

var MODES = [
  { id: "", label: "Default", hint: "Amp's own choice" },
  { id: "low", label: "Low", hint: "Quick and frugal" },
  { id: "medium", label: "Medium", hint: "Balanced" },
  { id: "high", label: "High", hint: "Deep reasoning" },
  { id: "ultra", label: "Ultra", hint: "Everything it has" }
]

var VISIBILITIES = ["private", "unlisted", "workspace", "group"]

function parseJson(text) {
  try {
    var value = JSON.parse(String(text || "").trim().split("\n").pop())
    return value && typeof value === "object" ? value : null
  } catch (e) {
    return null
  }
}

function time(iso) {
  var t = Date.parse(iso || "")
  return isFinite(t) ? t : 0
}

// "now", "4m", "3h", "2d", "5w": the bar's own vocabulary, short enough for a
// right-aligned column.
function ago(iso, now) {
  var t = time(iso)
  if (!t) return ""
  var s = Math.max(0, ((now || Date.now()) - t) / 1000)
  if (s < 45) return "now"
  if (s < 3600) return Math.round(s / 60) + "m"
  if (s < 86400) return Math.round(s / 3600) + "h"
  if (s < 86400 * 14) return Math.round(s / 86400) + "d"
  return Math.round(s / (86400 * 7)) + "w"
}

function money(value) {
  if (typeof value !== "number" || !isFinite(value)) return "—"
  return "$" + (Math.abs(value - Math.round(value)) < 0.005 ? String(Math.round(value)) : value.toFixed(2))
}

function hours(value) {
  if (typeof value !== "number" || !isFinite(value)) return "—"
  return (Math.abs(value - Math.round(value)) < 0.05 ? String(Math.round(value)) : value.toFixed(1)) + "h"
}

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

// How far through the billing period we are, 0..1, or -1 when unknown. The
// period's end date is exclusive in Amp's report, like its start is inclusive.
function periodElapsed(period, now) {
  if (!period || !period.start || !period.end) return -1
  var a = Date.parse(period.start + "T00:00:00Z"), b = Date.parse(period.end + "T00:00:00Z")
  if (!isFinite(a) || !isFinite(b) || b <= a) return -1
  return clamp(((now || Date.now()) - a) / (b - a), 0, 1)
}

// Pace compares what is used with how much of the period has gone. Below one
// is under budget; the panel only speaks up past 1.15.
function pace(percentLeft, elapsed) {
  if (typeof percentLeft !== "number" || elapsed <= 0) return 0
  return (1 - percentLeft / 100) / elapsed
}

function paceWord(p) {
  if (p <= 0) return ""
  if (p < 0.85) return "under pace"
  if (p <= 1.15) return "on pace"
  return "ahead of pace"
}

function monthDay(isoDay) {
  var t = Date.parse((isoDay || "") + "T12:00:00Z")
  if (!isFinite(t)) return ""
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  var d = new Date(t)
  return months[d.getUTCMonth()] + " " + d.getUTCDate()
}

function tierShort(tier) {
  return String(tier || "").replace(/^Amp\s+/i, "").replace(/\s+Tier$/i, "")
}

function baseName(path) {
  var p = String(path || "").replace(/\/+$/, "")
  var i = p.lastIndexOf("/")
  return i >= 0 ? p.slice(i + 1) : p
}

function prettyDir(path, home) {
  var p = String(path || "")
  if (home && p === home) return "~"
  if (home && p.indexOf(home + "/") === 0) return "~" + p.slice(home.length)
  return p
}

// One state word per thread, in the order the dot is drawn.
function state(row) {
  if (!row) return "idle"
  if (row.working) return row.connected === false && row.dir === "" ? "orb" : "working"
  if (row.live) return "live"
  return "idle"
}

function subtitle(row, now) {
  var parts = []
  if (row.project) parts.push(row.project)
  if (row.working) parts.push(row.dir === "" ? "working in an orb" : "working")
  else {
    var age = ago(row.updatedAt, now)
    if (age) parts.push(age === "now" ? "just now" : age + " ago")
  }
  if (row.messageCount > 0) parts.push(row.messageCount + (row.messageCount === 1 ? " message" : " messages"))
  return parts.join("  ·  ")
}

// The subtitle without the project, which the row draws in its own hue.
function subtitleRest(row, now) {
  var copy = {}
  for (var k in row) copy[k] = row[k]
  copy.project = ""
  return subtitle(copy, now)
}

function working(rows) {
  var n = 0
  for (var i = 0; i < (rows || []).length; i++) if (rows[i] && rows[i].working) n++
  return n
}

// Ids that were working in `before` and are present but idle in `after`:
// the threads that just finished a turn.
function finished(before, after) {
  var was = {}
  var out = []
  for (var i = 0; i < (before || []).length; i++) if (before[i].working) was[before[i].id] = true
  for (var j = 0; j < (after || []).length; j++) {
    var row = after[j]
    if (was[row.id] && !row.working) out.push(row)
  }
  return out
}

// Directories the ask box offers: the remembered one first, then where recent
// threads ran, then the runner's, then home. Unique, at most `limit`.
function askDirs(remembered, threadDirs, runnerDirs, home, limit) {
  var out = []
  function add(p) { if (p && out.indexOf(p) < 0) out.push(p) }
  add(remembered)
  for (var i = 0; i < (threadDirs || []).length; i++) add(threadDirs[i])
  for (var j = 0; j < (runnerDirs || []).length; j++) add(runnerDirs[j])
  add(home)
  return out.slice(0, limit || 8)
}

// The oscilloscope trace. x in 0..1, t in seconds, n working threads. Each
// thread adds a voice at its own frequency, so two threads read as a beat and
// not as one louder line; idle is a flat line with a slow heartbeat crossing.
function wave(x, t, n) {
  var taper = Math.pow(Math.sin(Math.PI * clamp(x, 0, 1)), 0.7)
  if (n <= 0) {
    var p = ((t * 0.18) % 1.6) - 0.3
    var d = (x - p) / 0.018
    var blip = Math.exp(-d * d) * 0.55 - Math.exp(-((x - p - 0.03) / 0.02) * ((x - p - 0.03) / 0.02)) * 0.22
    return (blip + Math.sin(x * 40 + t * 2) * 0.012) * taper
  }
  var voices = Math.min(n, 5)
  var y = 0
  for (var k = 0; k < voices; k++) {
    var f = 7 + k * 4.3
    y += Math.sin(x * f * Math.PI + t * (2.2 + k * 0.9) + k * 1.7) / (1 + k * 0.55)
  }
  y += Math.sin(x * 61 + t * 7.3) * 0.08
  var norm = 0
  for (var m = 0; m < voices; m++) norm += 1 / (1 + m * 0.55)
  return (y / norm) * taper * (0.55 + 0.45 * Math.min(1, n / 3))
}

// One thread's own voice on the scope: its own frequency and drift, tapered
// at the edges, so several working threads read as separate colored lines.
function voice(x, t, k) {
  var taper = Math.pow(Math.sin(Math.PI * clamp(x, 0, 1)), 0.7)
  var f = 5 + k * 3.7
  var y = Math.sin(x * f * Math.PI + t * (1.9 + k * 0.75) + k * 2.1)
  y += Math.sin(x * (f * 2.3) * Math.PI - t * (3.1 + k * 0.4)) * 0.22
  return (y / 1.22) * taper * (0.92 - k * 0.1)
}

if (typeof module !== "undefined") {
  module.exports = {
    MODES: MODES, VISIBILITIES: VISIBILITIES, parseJson: parseJson, ago: ago, money: money,
    hours: hours, periodElapsed: periodElapsed, pace: pace, paceWord: paceWord, monthDay: monthDay,
    tierShort: tierShort, baseName: baseName, prettyDir: prettyDir, state: state, subtitle: subtitle,
    working: working, finished: finished, askDirs: askDirs, wave: wave, clamp: clamp,
    voice: voice, subtitleRest: subtitleRest
  }
}
