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

// When each working thread started its turn, as first seen by a poll: the
// start already known is kept, a thread new to work starts `now`, and a
// thread that stopped is dropped.
function turnStarts(starts, rows, now) {
  var out = {}
  for (var i = 0; i < (rows || []).length; i++) {
    var row = rows[i]
    if (row && row.working) out[row.id] = starts && starts[row.id] ? starts[row.id] : now
  }
  return out
}

// "22:00-08:00" as minutes since midnight, or null when it is not a range.
// The range may cross midnight; equal ends are no range at all.
function quietHours(spec) {
  var m = /^\s*(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*$/.exec(String(spec || ""))
  if (!m) return null
  var from = Number(m[1]) * 60 + Number(m[2])
  var to = Number(m[3]) * 60 + Number(m[4])
  if (Number(m[1]) > 23 || Number(m[3]) > 23 || Number(m[2]) > 59 || Number(m[4]) > 59 || from === to) return null
  return { from: from, to: to }
}

function inQuietHours(spec, date) {
  var range = quietHours(spec)
  if (!range) return false
  var t = date.getHours() * 60 + date.getMinutes()
  return range.from < range.to ? t >= range.from && t < range.to : t >= range.from || t < range.to
}

// muteUntil: 0 notifies, -1 is muted until turned back on, a time in ms is a
// snooze that ends by itself.
function muteState(muteUntil, now) {
  if (muteUntil === -1) return "off"
  return muteUntil > now ? "snoozed" : "on"
}

// The bell's cycle: on, snoozed for an hour, off, on.
function nextMute(muteUntil, now) {
  var s = muteState(muteUntil, now)
  return s === "on" ? now + 3600000 : (s === "snoozed" ? -1 : 0)
}

// Of the threads that just finished, the ones worth a notification: not
// muted, and working for at least `minSeconds`. A turn whose start was not
// seen counts as long, so a restart never drops a notification.
function notifiable(done, starts, now, minSeconds, muted) {
  return (done || []).filter(function(row) {
    if ((muted || []).indexOf(row.id) >= 0) return false
    var start = starts ? starts[row.id] : 0
    return !start || now - start >= (minSeconds || 0) * 1000
  })
}

// The panel's own thread search: every word must appear in the title, the
// project or the directory, in any case. Working state comes from the live
// rows; at most `limit` results, in the catalog's order (newest first).
function search(catalog, live, query, limit) {
  var words = String(query || "").toLowerCase().split(/\s+/).filter(function(w) { return w !== "" })
  if (words.length === 0) return []
  var byId = {}
  for (var i = 0; i < (live || []).length; i++) byId[live[i].id] = live[i]
  var out = []
  for (var j = 0; j < (catalog || []).length && out.length < (limit || 40); j++) {
    var row = catalog[j]
    var hay = ((row.title || "") + " " + (row.project || "") + " " + (row.dir || "")).toLowerCase()
    if (words.every(function(w) { return hay.indexOf(w) >= 0 })) out.push(byId[row.id] || row)
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
    voice: voice, subtitleRest: subtitleRest, turnStarts: turnStarts, quietHours: quietHours,
    inQuietHours: inQuietHours, muteState: muteState, nextMute: nextMute, notifiable: notifiable,
    search: search
  }
}
