// node tests/model.test.js: src/Model.js as the shell loads it, minus the
// QML-only `.pragma library` line.
const fs = require("fs")
const path = require("path")
const assert = require("assert/strict")

const source = fs.readFileSync(path.join(__dirname, "../src/Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const module_ = { exports: {} }
new Function("module", source)(module_)
const M = module_.exports

let count = 0
function test(name, fn) { fn(); count++; process.stdout.write(`ok - ${name}\n`) }

const NOW = Date.parse("2026-11-01T12:00:00Z")

test("ago speaks the bar's vocabulary", () => {
  assert.equal(M.ago("2026-11-01T11:59:50Z", NOW), "now")
  assert.equal(M.ago("2026-11-01T11:50:00Z", NOW), "10m")
  assert.equal(M.ago("2026-11-01T09:00:00Z", NOW), "3h")
  assert.equal(M.ago("2026-10-29T12:00:00Z", NOW), "3d")
  assert.equal(M.ago("2026-09-01T12:00:00Z", NOW), "9w")
  assert.equal(M.ago("", NOW), "")
  assert.equal(M.ago("not a date", NOW), "")
})

test("money and hours drop needless decimals", () => {
  assert.equal(M.money(20), "$20")
  assert.equal(M.money(19.234), "$19.23")
  assert.equal(M.money(null), "—")
  assert.equal(M.hours(750), "750h")
  assert.equal(M.hours(623.5), "623.5h")
})

test("period elapsed and pace", () => {
  const period = { start: "2026-10-29", end: "2026-11-29" }
  const e = M.periodElapsed(period, NOW)
  assert.ok(e > 0.1 && e < 0.12, String(e))
  assert.equal(M.periodElapsed(null, NOW), -1)
  assert.equal(M.periodElapsed({ start: "2026-11-29", end: "2026-10-29" }, NOW), -1)
  assert.equal(M.paceWord(M.pace(96, e)), "under pace")
  assert.equal(M.paceWord(M.pace(89, e)), "on pace")
  assert.equal(M.paceWord(M.pace(50, e)), "ahead of pace")
  assert.equal(M.paceWord(M.pace(50, -1)), "")
})

test("labels", () => {
  assert.equal(M.tierShort("Amp Megawatt Tier"), "Megawatt")
  assert.equal(M.monthDay("2026-11-29"), "Nov 29")
  assert.equal(M.baseName("/home/a/Projects/tabbit/"), "tabbit")
  assert.equal(M.prettyDir("/home/a/x", "/home/a"), "~/x")
  assert.equal(M.prettyDir("/home/a", "/home/a"), "~")
})

test("thread state and subtitle", () => {
  assert.equal(M.state({ working: true, connected: true, dir: "/x" }), "working")
  assert.equal(M.state({ working: true, connected: false, dir: "" }), "orb")
  assert.equal(M.state({ working: false, live: true }), "live")
  assert.equal(M.state({}), "idle")
  const s = M.subtitle({ project: "tabbit", working: false, updatedAt: "2026-11-01T09:00:00Z", messageCount: 1 }, NOW)
  assert.equal(s, "tabbit  ·  3h ago  ·  1 message")
  assert.equal(M.subtitle({ project: "p", working: true, dir: "" }, NOW), "p  ·  working in an orb")
})

test("finished finds threads that went quiet, not ones that left", () => {
  const before = [{ id: "a", working: true }, { id: "b", working: true }, { id: "c", working: false }]
  const after = [{ id: "a", working: false, title: "A" }, { id: "c", working: false }]
  assert.deepEqual(M.finished(before, after).map((r) => r.id), ["a"])
  assert.equal(M.working(after), 0)
  assert.equal(M.working(before), 2)
})

test("ask directories are unique, remembered first, home last", () => {
  const dirs = M.askDirs("/h/b", ["/h/a", "/h/b"], ["/h/c", "/h/a"], "/h", 8)
  assert.deepEqual(dirs, ["/h/b", "/h/a", "/h/c", "/h"])
  assert.equal(M.askDirs("", [], [], "/h", 8)[0], "/h")
  assert.equal(M.askDirs("", ["1", "2", "3", "4"], [], "/h", 2).length, 2)
})

test("the wave is finite, tapered at the edges, and louder with work", () => {
  for (const n of [0, 1, 2, 5, 9]) {
    for (let i = 0; i <= 50; i++) {
      const y = M.wave(i / 50, 3.3, n)
      assert.ok(Number.isFinite(y) && Math.abs(y) <= 1.2, `${n} ${i} ${y}`)
    }
    assert.ok(Math.abs(M.wave(0, 1, n)) < 1e-9)
    assert.ok(Math.abs(M.wave(1, 1, n)) < 1e-6)
  }
  const energy = (n) => { let e = 0; for (let i = 0; i <= 200; i++) e += Math.abs(M.wave(i / 200, 2, n)); return e }
  assert.ok(energy(3) > energy(0) * 3)
})

test("each voice is its own finite, tapered line", () => {
  for (let k = 0; k < 5; k++) {
    for (let i = 0; i <= 40; i++) assert.ok(Math.abs(M.voice(i / 40, 1.7, k)) <= 1)
    assert.ok(Math.abs(M.voice(0, 1, k)) < 1e-9)
  }
  assert.notEqual(M.voice(0.3, 1, 0), M.voice(0.3, 1, 1))
  assert.equal(M.subtitleRest({ project: "p", working: true, dir: "/x" }, NOW), "working")
})

test("parseJson takes the last line and refuses garbage", () => {
  assert.deepEqual(M.parseJson('noise\n{"ok":true}\n'), { ok: true })
  assert.equal(M.parseJson("nope"), null)
  assert.equal(M.parseJson(""), null)
})

test("turn starts keep what is known and drop what stopped", () => {
  const s1 = M.turnStarts({}, [{ id: "a", working: true }, { id: "b", working: false }], 100)
  assert.deepEqual(s1, { a: 100 })
  const s2 = M.turnStarts(s1, [{ id: "a", working: true }, { id: "c", working: true }], 200)
  assert.deepEqual(s2, { a: 100, c: 200 })
  assert.deepEqual(M.turnStarts(s2, [{ id: "a", working: false }], 300), {})
})

test("quiet hours parse, cross midnight and refuse nonsense", () => {
  assert.deepEqual(M.quietHours("22:00-08:00"), { from: 1320, to: 480 })
  assert.deepEqual(M.quietHours(" 9:30 - 17:45 "), { from: 570, to: 1065 })
  for (const bad of ["", "22-08", "25:00-08:00", "10:00-10:00", "10:60-11:00", null, "evening"]) assert.equal(M.quietHours(bad), null, String(bad))
  const at = (h, m) => new Date(2026, 10, 1, h, m)
  assert.equal(M.inQuietHours("22:00-08:00", at(23, 30)), true)
  assert.equal(M.inQuietHours("22:00-08:00", at(7, 59)), true)
  assert.equal(M.inQuietHours("22:00-08:00", at(8, 0)), false)
  assert.equal(M.inQuietHours("22:00-08:00", at(12, 0)), false)
  assert.equal(M.inQuietHours("12:00-13:00", at(12, 30)), true)
  assert.equal(M.inQuietHours("12:00-13:00", at(13, 0)), false)
  assert.equal(M.inQuietHours("", at(3, 0)), false)
})

test("the bell cycles on, snoozed, off", () => {
  assert.equal(M.muteState(0, NOW), "on")
  assert.equal(M.muteState(NOW - 1, NOW), "on")
  assert.equal(M.muteState(NOW + 1, NOW), "snoozed")
  assert.equal(M.muteState(-1, NOW), "off")
  assert.equal(M.nextMute(0, NOW), NOW + 3600000)
  assert.equal(M.nextMute(NOW + 5, NOW), -1)
  assert.equal(M.nextMute(-1, NOW), 0)
})

test("only long, unmuted turns notify", () => {
  const done = [{ id: "a" }, { id: "b" }, { id: "c" }, { id: "d" }]
  const starts = { a: NOW - 120000, b: NOW - 5000, c: NOW - 120000 }
  assert.deepEqual(M.notifiable(done, starts, NOW, 30, ["c"]).map(r => r.id), ["a", "d"])
  assert.deepEqual(M.notifiable(done, starts, NOW, 0, []).map(r => r.id), ["a", "b", "c", "d"])
  assert.deepEqual(M.notifiable([], starts, NOW, 30, []), [])
})

test("search matches every word in title, project or directory", () => {
  const catalog = [
    { id: "1", title: "Refactor the billing webhooks", project: "atlas", dir: "/h/work/atlas" },
    { id: "2", title: "Billing export", project: "beacon", dir: "" },
    { id: "3", title: "Dark theme tokens", project: "atlas", dir: "" },
  ]
  const live = [{ id: "1", title: "Refactor the billing webhooks", working: true }]
  assert.deepEqual(M.search(catalog, live, "BILLING", 40).map(r => r.id), ["1", "2"])
  assert.deepEqual(M.search(catalog, live, "billing atlas", 40).map(r => r.id), ["1"])
  assert.equal(M.search(catalog, live, "billing atlas", 40)[0].working, true)
  assert.deepEqual(M.search(catalog, live, "  ", 40), [])
  assert.deepEqual(M.search(catalog, live, "a", 2).length, 2)
})

process.stdout.write(`\n${count} passed\n`)
