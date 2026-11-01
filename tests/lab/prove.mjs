#!/usr/bin/env node
// Ampere's scenarios in the omakit lab (adapted from Fathom's driver): one
// working tree, one disposable
// Omarchy guest, through omakit's own lab code (tools/lab/run.mjs boots,
// logs in, identifies and ends the guest; tools/lab/harness.sh runs the
// suite). The desktop is never touched: every ssh goes to 127.0.0.1 on the
// forwarded port with the lab's key, every key press to the guest's
// virtual keyboard.
//
//   node prove.mjs <plugin-tree> <label> <all|visual|actions|probe> [--memory MiB] [--keep-seconds n]
//
// It boots only while the host keeps 2 GiB available beyond the guest, and
// ends a guest whose SSH is still silent 60 s after QEMU started.
//
// The run record and every document land under the lab's own state
// directory, beside omakit's runs: $XDG_STATE_HOME/omakit/lab/runs/<id>/.

import { spawn, spawnSync } from "node:child_process"
import { closeSync, existsSync, openSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"

const HERE = dirname(fileURLToPath(import.meta.url))
const OMAKIT = process.env.AMPERE_OMAKIT_DIR || join(process.env.HOME, "Projects/omarchy/omakit-public")
const lab = (name) => import(pathToFileURL(join(OMAKIT, "tools/lab", name)).href)
const { labPin, withRelease, guestIsRelease, bytesBoth } = await lab("pin.mjs")
const { labLayout, labDir, writeJson, readJson, stampNow } = await lab("paths.mjs")
const { inspectBase, baseRelease } = await lab("inspect.mjs")
const { probeRunHost, freeBytesAt, guestCpus } = await lab("host.mjs")
const { acquireLock, releaseLock, withGuest } = await lab("run.mjs")
const { SESSION_PREAMBLE } = await lab("guest.mjs")
const { qmpExecute } = await lab("qemu.mjs")

const args = process.argv.slice(2)
const tree = args[0] && resolve(args[0])
const label = args[1]
const what = args[2] || "all"
const keepSeconds = args.includes("--keep-seconds") ? args[args.indexOf("--keep-seconds") + 1] : "0"
// The guest's memory, lower than the pin's when the host has less to spare.
const memoryOverride = args.includes("--memory") ? Number(args[args.indexOf("--memory") + 1]) : null
// The host keeps this much available beyond the guest (it swapped hard once).
const HOST_MARGIN_MIB = 2048
// SSH silent this long after QEMU started: the guest is ended, not waited for.
const SSH_SILENT_SECONDS = 60
if (!tree || !label || !["all", "visual", "actions", "probe"].includes(what)) {
  process.stderr.write("usage: prove.mjs <plugin-tree> <label> <all|visual|actions|probe> [--memory MiB] [--keep-seconds n]\n")
  process.exit(2)
}
if (!existsSync(join(tree, "manifest.json"))) {
  process.stderr.write(`${tree} has no manifest.json\n`)
  process.exit(2)
}
const treeCommit = spawnSync("git", ["-C", tree, "rev-parse", "HEAD"], { encoding: "utf8" }).stdout.trim() || "uncommitted"

const say = (line) => process.stdout.write(`${line}\n`)
const phase = (text) => say(`==> ${text}`)

// Preflight, reading only, the way tools/lab/run.mjs does it for its own suites.
const layout = labLayout(process.env)
let pin = labPin()
pin = withRelease(pin, baseRelease(layout, pin))
const base = inspectBase(layout, pin)
const missing = []
if (base.state !== "ready") missing.push(`a ready base (${base.state}): ${base.reason}; omakit lab setup`)
for (const line of probeRunHost({ pin })) if (line.state !== "ok") missing.push(`${line.name}: ${line.reason}; ${line.remedy || ""}`)
const free = freeBytesAt(layout.cache)
if (free.bytes < pin.measured.overlayAfterRunBytes) missing.push(`disk for one overlay: ${bytesBoth(free.bytes)} free at ${free.path}`)
if (memoryOverride) pin = { ...pin, guest: { ...pin.guest, memoryMiB: memoryOverride } }
const availableMiB = Math.floor(Number(/MemAvailable:\s+(\d+)/.exec(readFileSync("/proc/meminfo", "utf8"))?.[1] || 0) / 1024)
say(`host memory: ${availableMiB} MiB available; the guest takes ${pin.guest.memoryMiB} MiB, ${HOST_MARGIN_MIB} MiB stay free`)
if (availableMiB < pin.guest.memoryMiB + HOST_MARGIN_MIB) missing.push(`memory: ${availableMiB} MiB available, ${pin.guest.memoryMiB + HOST_MARGIN_MIB} MiB needed (--memory lowers the guest's)`)
if (missing.length) {
  say(`lab not ready:\n  ${missing.join("\n  ")}`)
  process.exit(2)
}

const runId = `${stampNow()}-ampere-${label}`
const runDir = labDir(layout.state, "runs", runId)
const startedAt = new Date()
const record = {
  schema: 1,
  runId,
  suite: `ampere-${what}`,
  driver: "ampere lab driver over omakit tools/lab (withGuest + harness.sh)",
  tree: { path: tree, commit: treeCommit, label },
  startedAt: startedAt.toISOString(),
  pin: { release: pin.release.name, isoSha256: pin.release.sha256, expectedGuestVersion: base.manifest.guest.version },
  base: { dir: base.dir, createdAt: base.manifest.createdAt, diskSha256: base.manifest.disk.sha256, origin: base.manifest.build?.origin || null },
  guest: null,
  skew: null,
  testedSource: null,
  host: { kernel: spawnSync("uname", ["-r"], { encoding: "utf8" }).stdout?.trim() || null, qemu: spawnSync("qemu-system-x86_64", ["--version"], { encoding: "utf8" }).stdout?.split("\n")[0] || null, cpus: guestCpus(), memoryMiB: pin.guest.memoryMiB, sshPort: null },
  session: null,
  suiteStatus: null,
  document: null,
  overlayBytes: null,
  baseUnchanged: null,
  durationMs: null,
  ok: false,
  runDir,
}
const save = () => writeJson(layout.state, `runs/${runId}/run.json`, record)

const controller = new AbortController()
let harness = null
const interrupt = () => {
  say("==> interrupted; ending the guest")
  controller.abort()
  if (harness && harness.exitCode === null) harness.kill("SIGTERM")
}
process.on("SIGINT", interrupt)
process.on("SIGTERM", interrupt)

function runHarness({ guest, paths, suiteArgs, timeoutSeconds }) {
  return new Promise((resolvePromise) => {
    const hostLog = openSync(join(runDir, "host.log"), "a", 0o600)
    harness = spawn("bash", [join(OMAKIT, "tools/lab/harness.sh"), join(HERE, "ampere.sh"), runDir, guest.key, String(guest.port), paths.qmp, OMAKIT, SESSION_PREAMBLE, pin.guest.user, pin.guest.password, ...suiteArgs], { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, AMPERE_OMAKIT_DIR: OMAKIT, AMPERE_LAB_DIR: HERE } })
    const feed = (chunk) => {
      writeFileSync(hostLog, chunk)
      process.stdout.write(chunk)
    }
    harness.stdout.on("data", feed)
    harness.stderr.on("data", feed)
    const timer = setTimeout(() => {
      say(`not ok - the suite ran past ${timeoutSeconds} s and was stopped`)
      harness.kill("SIGKILL")
    }, timeoutSeconds * 1000)
    harness.on("close", (code, sig) => {
      clearTimeout(timer)
      closeSync(hostLog)
      resolvePromise(controller.signal.aborted ? "interrupted" : sig ? null : code)
    })
  })
}

// A guest whose SSH stays silent is ended, not waited for (omakit waits up
// to 600 s; the host swapped hard during such a wait once). QEMU quits over
// QMP, omakit's wait sees it exit, and withGuest cleans up as usual.
const qmpSocket = join(layout.staging, `run-${runId}`, "qmp.sock")
let bootedAt = null
let sshAnswered = false
let silenceTimer = null
const endSilentGuest = async (why) => {
  if (sshAnswered || controller.signal.aborted) return
  say(`==> ${why}: ending the guest instead of waiting`)
  record.sshSilent = why
  controller.abort()
  await qmpExecute(qmpSocket, "quit").catch(() => {})
}
const watchPhase = (text) => {
  phase(text)
  if (text.startsWith("booting the guest")) {
    bootedAt = Date.now()
    // A backstop in case the SSH attempts themselves stall.
    silenceTimer = setTimeout(() => endSilentGuest(`no SSH answer ${SSH_SILENT_SECONDS + 30} s after boot`), (SSH_SILENT_SECONDS + 30) * 1000)
    return
  }
  const waiting = /^waiting for the guest's SSH \((\d+) s\)/.exec(text)
  if (waiting) {
    if (Number(waiting[1]) >= SSH_SILENT_SECONDS) endSilentGuest(`SSH silent for ${waiting[1]} s`)
    return
  }
  if (bootedAt && !sshAnswered) {
    sshAnswered = true
    clearTimeout(silenceTimer)
    say(`==> SSH answered ${Math.round((Date.now() - bootedAt) / 1000)} s after boot`)
  }
}

await acquireLock(layout, { runId, pid: process.pid, qmpSocket, startedAt: record.startedAt })
save()
let booted
let failure = null
try {
  booted = await withGuest({ baseDir: base.dir, stagingName: `run-${runId}`, logFile: join(runDir, "qemu.log"), layout, pin, onPhase: watchPhase, signal: controller.signal }, async ({ guest, paths, identity }) => {
    record.guest = identity
    record.host.sshPort = guest.port
    record.skew = identity.linked || !guestIsRelease(identity.version, pin.release)
    record.testedSource = identity.testedSource
    save()
    say(`guest omarchy ${identity.version || "unknown"} on ${identity.kernel || "?"}; tested source ${identity.testedSource}; skew ${record.skew}`)
    phase(`running Ampere ${label} (${treeCommit.slice(0, 7)}): ${what}`)
    const status = await runHarness({ guest, paths, suiteArgs: [tree, label, what, keepSeconds], timeoutSeconds: 3000 })
    record.suiteStatus = status
    if (status === "interrupted") throw Object.assign(new Error("interrupted during the suite"), { code: "interrupted" })
    const documentPath = join(runDir, "ampere-lab.json")
    const document = readJson(documentPath)
    record.document = existsSync(documentPath) ? documentPath : null
    record.ok = status === 0 && document?.ok === true
    if (document) {
      document.where = `the ${record.skew ? "linked" : "stock"} Omarchy ${identity.version || "?"} guest of omakit lab, run ${runId}`
      document.lab = { runId, guest: identity, skew: record.skew, testedSource: identity.testedSource, pin: record.pin, base: record.base, host: record.host, startedAt: record.startedAt, tree: record.tree }
      writeJson(layout.state, `runs/${runId}/ampere-lab.json`, document)
    }
  })
} catch (error) {
  failure = error
  record.error = error?.message || String(error)
  record.errorCode = error?.code || null
} finally {
  clearTimeout(silenceTimer)
  if (booted) {
    record.session = booted.session
    record.host.sshPort = booted.sshPort
    record.overlayBytes = booted.overlayBytes
    record.baseUnchanged = booted.baseUnchanged
  }
  releaseLock(layout, runId)
  record.durationMs = Date.now() - startedAt.getTime()
  save()
}

say("")
say(`run ${runId}: ${record.ok ? "PROVED" : "NOT PROVED"} (suite exit ${record.suiteStatus}, ${Math.round(record.durationMs / 1000)} s, overlay ${record.overlayBytes == null ? "?" : bytesBoth(record.overlayBytes)}, base unchanged ${record.baseUnchanged})`)
say(`record ${join(runDir, "run.json")}`)
if (failure) say(`error: ${failure.message}`)
process.exit(record.ok ? 0 : 1)
