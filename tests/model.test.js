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

process.stdout.write(`\n${count} passed\n`)
