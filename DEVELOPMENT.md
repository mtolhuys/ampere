# Developing Ampere

## Layout

| Path | What |
|---|---|
| `manifest.json` | One `bar-widget`, its settings schema |
| `src/Ampere.qml` | The widget: bar icon, data flow, actions, keys, IPC, the panel |
| `src/Oscilloscope.qml` | The live-current trace (Canvas, animates only while open) |
| `src/Meter.qml`, `ThreadRow.qml`, `Chip.qml`, `Tile.qml` | Panel parts |
| `src/ThemeHues.qml` | The theme's six hues from `colors.toml` (not `Palette`: QtQuick owns that name) |
| `src/Model.js` | Pure logic: formatting, pace, thread state, the wave |
| `bin/ampere` | The one helper every process goes through (Python, stdlib) |
| `omakit/` | omakit's Run and Store blocks, unmodified (never edit; `omakit add run . --update`) |
| `tests/` | Unit tests and the lab suite |

## Rules

- Every process starts through `Run { }` with `bin/ampere` as `command[0]`.
  No bare `Process`, no shell strings. The helper validates thread ids,
  URLs (`https://ampcode.com/…` only), directories (under `$HOME`), modes and
  terminal presets before it calls anything.
- Every `Text` is `textFormat: Text.PlainText`. Titles come from Amp and from
  other people's threads.
- Use only shell APIs that Omarchy 4.0.4 has. It has no `ShellIpc`, no lazy
  `KeyboardPanel.content`, and no `Style.duration`, `Style.reduceMotion` or
  `Style.easeOut`. Ampere uses `IpcHandler`, eager panel children, and
  `Style.reduceMotion === true` guards, which work on both 4.0.4 and dev.
- Animations run only while the panel is open, and respect reduced motion.

## Tests

```bash
node tests/model.test.js
python3 -I tests/test_helper.py
```

## The lab (live testing)

Live tests run in the omakit lab, a disposable Omarchy guest, never on the
desktop. Inside the guest, `tests/lab/fake-amp` stands in for the Amp CLI with
a fixed set of threads, so no Amp account enters it. The suite installs the
working tree with `omarchy-plugin-add --enable`, drives the panel with real
keys over QEMU's virtual keyboard, checks every Amp call in the fixture's
log, and saves screenshots.

```bash
node tests/lab/prove.mjs . <label> all      # or: visual | actions | probe
```

Needs a ready lab (`omakit lab inspect`) and omakit's source at
`~/Projects/omarchy/omakit-public` (or `AMPERE_OMAKIT_DIR`). Records and
screenshots land in `~/.local/state/omakit/lab/runs/<run>/`. `probe` copies
the guest's shell sources out, so you can check an API against the release.

## Deploying to your own desktop

`bin/dev-reload` copies the checkout into `~/.config/omarchy/plugins/`. The
shell's watcher does not follow symlinks. Omacale keeps a loaded widget's
compiled code, so after a change there, `omarchy-restart-shell`.

## Marketplace checks

```bash
omakit verify . --json
omakit inspect . --offline
omakit submit . --category <c> --tags <a,b> --json --offline
```

These read a commit. Keep the baseline free of capabilities: a detected one
sends every update, docs included, to the marketplace's manual queue. That is
why background asks are plain detached processes (a shell restart stops
Quickshell alone, which the lab's restart scenario proves) rather than
service units.
