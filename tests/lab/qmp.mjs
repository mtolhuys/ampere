#!/usr/bin/env node
// Keys, text, the wheel and the pointer for Ampere's lab guest (adapted from
// Fathom's lab driver), over QEMU's QMP socket,
// through omakit's own QMP client (tools/lab/qemu.mjs). Every event reaches
// the guest's virtual hardware and nothing else.
//
//   node qmp.mjs <socket> keydown <qcode...>        hold keys down
//   node qmp.mjs <socket> keyup <qcode...>          let them go
//   node qmp.mjs <socket> press <qcode-chord> [ms]  press and release a chord (alt-tab), hold ms
//   node qmp.mjs <socket> wheel <up|down|left|right> [n]
//   node qmp.mjs <socket> pointer <x> <y>           absolute, 0..32767
//   node qmp.mjs <socket> click [left|right|middle]
//   node qmp.mjs <socket> type <text>               type text, one key per character
//   node qmp.mjs <socket> screendump <file>

import { join } from "node:path"
import { pathToFileURL } from "node:url"

const OMAKIT = process.env.AMPERE_OMAKIT_DIR || join(process.env.HOME, "Projects/omarchy/omakit-public")
const { qmpExecute } = await import(pathToFileURL(join(OMAKIT, "tools/lab/qemu.mjs")).href)

const [socket, command, ...rest] = process.argv.slice(2)
if (!socket || !command) {
  process.stderr.write("usage: qmp.mjs <socket> keydown|keyup|press|wheel|pointer|click|screendump ...\n")
  process.exit(2)
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const key = (down, qcode) => ({ type: "key", data: { down, key: { type: "qcode", data: qcode } } })
const btn = (down, button) => ({ type: "btn", data: { down, button } })
const send = (events) => qmpExecute(socket, "input-send-event", { events })

try {
  switch (command) {
    case "keydown":
      await send(rest.map((q) => key(true, q)))
      break
    case "keyup":
      await send([...rest].reverse().map((q) => key(false, q)))
      break
    case "press": {
      const chord = String(rest[0] || "").split("-").filter(Boolean)
      const hold = Number(rest[1] || 100)
      await qmpExecute(socket, "send-key", { keys: chord.map((q) => ({ type: "qcode", data: q })), "hold-time": hold })
      break
    }
    case "wheel": {
      const direction = rest[0]
      const count = Number(rest[1] || 1)
      for (let i = 0; i < count; i += 1) {
        await send([btn(true, `wheel-${direction}`), btn(false, `wheel-${direction}`)])
        await sleep(30)
      }
      break
    }
    case "pointer":
      await send([{ type: "abs", data: { axis: "x", value: Number(rest[0]) } }, { type: "abs", data: { axis: "y", value: Number(rest[1]) } }])
      break
    case "click": {
      const button = rest[0] || "left"
      await send([btn(true, button)])
      await sleep(40)
      await send([btn(false, button)])
      break
    }
    case "type": {
      const named = { " ": "spc", "-": "minus", "/": "slash", ".": "dot", ",": "comma", "'": "apostrophe", "=": "equal", ";": "semicolon" }
      const shifted = { "?": "slash", "!": "1", ":": "semicolon", "_": "minus", '"': "apostrophe" }
      for (const ch of rest.join(" ")) {
        let chord
        if (/[a-z0-9]/.test(ch)) chord = [ch]
        else if (/[A-Z]/.test(ch)) chord = ["shift", ch.toLowerCase()]
        else if (named[ch]) chord = [named[ch]]
        else if (shifted[ch]) chord = ["shift", shifted[ch]]
        else continue
        await qmpExecute(socket, "send-key", { keys: chord.map((q) => ({ type: "qcode", data: q })), "hold-time": 30 })
        await sleep(25)
      }
      break
    }
    case "screendump":
      await qmpExecute(socket, "screendump", { filename: rest[0] })
      break
    default:
      throw new Error(`unknown command ${command}`)
  }
} catch (error) {
  process.stderr.write(`qmp: ${error.message}\n`)
  process.exit(1)
}
