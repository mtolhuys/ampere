#!/usr/bin/bash
# Ampere's scenarios in the omakit lab guest. Sourced by omakit's
# tools/lab/harness.sh, which defines log, ssh_guest, ssh_session,
# wait_for_guest_state, capture_console, stage_plugin, guest_file,
# guest_shell_healthy, RUN_DIR, OMAKIT_DIR and LAB_QMP_SOCKET.
#
#   omakit_lab_suite <plugin-tree> <label> <all|visual|actions|probe> <keep-seconds>
#
# What it does in the guest, the way a person would: puts tests/lab/fake-amp
# where the Amp CLI lives (~/.local/bin/amp) with a fixed set of threads, so
# no Amp account enters the guest; installs the working tree with
# omarchy-plugin-add --enable; then drives the panel with real keys through
# QEMU's virtual keyboard and checks every Amp call in the fixture's log.
# Every fact is printed as `ok - ` or `not ok - `; ampere-lab.json has them.

readonly AMPERE_ID="io.github.mtolhuys.ampere"

omakit_lab_suite() {
  local tree="$1" label="$2" what="${3:-all}" keep="${4:-0}"
  local passed=0 failed=0 results="[]"
  local here="${AMPERE_LAB_DIR:?}"

  qmp() { node "$here/qmp.mjs" "$LAB_QMP_SOCKET" "$@"; }
  check() {
    local scenario="$1" description="$2"; shift 2
    if "$@" >/dev/null 2>&1; then
      printf 'ok - %s: %s\n' "$scenario" "$description"; passed=$((passed + 1))
      results=$(jq -c --arg s "$scenario" --arg d "$description" '. + [{scenario: $s, check: $d, ok: true}]' <<<"$results")
    else
      printf 'not ok - %s: %s\n' "$scenario" "$description"; failed=$((failed + 1))
      results=$(jq -c --arg s "$scenario" --arg d "$description" '. + [{scenario: $s, check: $d, ok: false}]' <<<"$results")
    fi
  }
  note() { printf '    %s\n' "$*"; results=$(jq -c --arg n "$*" '. + [{note: $n}]' <<<"$results"); }
  ipc() { ssh_session "omarchy-shell $AMPERE_ID $1" 2>/dev/null | tr -d '"'; }
  # Polls until the command succeeds, for at most $1 seconds.
  within() { local limit="$1"; shift; local end=$((SECONDS + limit)); until "$@" >/dev/null 2>&1; do ((SECONDS >= end)) && return 1; sleep 1; done; }
  called() { ssh_guest "jq -c .argv \$HOME/.fake-amp/calls.log" | grep -F -- "$1"; }
  called_in() { ssh_guest "jq -c 'select(.argv | index(\"-x\")) | .cwd' \$HOME/.fake-amp/calls.log" | grep -F -- "$1"; }
  clipboard_is() { [[ $(ssh_session "wl-paste -n" 2>/dev/null) == "$1" ]]; }
  panel_open() { ssh_session "hyprctl -j layers | jq -e '[.. | objects | select(.namespace? == \"omarchy-keyboard-panel\")] | length > 0'"; }
  panel_closed() { ! panel_open; }
  working_is() { [[ $(ipc working) == "$1" ]]; }
  shot() { capture_console "$1"; note "screenshot $1.png"; }
  # Close the terminals Ampere opened, by their app id, without a dispatcher.
  close_terminals() { ssh_session "hyprctl -j clients | jq -r '.[] | select(.class | test(\"^org\\\\.omarchy\\\\.(agent|ampere)\")) | .pid' | xargs -r kill" >/dev/null 2>&1 || true; }

  # The shell's log and Ampere's lines in it, on success and on every early return.
  collect() {
    ssh_guest 'cat $(ls -t /run/user/$(id -u)/quickshell/by-id/*/log.log | head -1)' > "$RUN_DIR/shell.log" 2>/dev/null || true
    grep -i ampere "$RUN_DIR/shell.log" | grep -v -i 'outside of the config folder' > "$RUN_DIR/ampere-shell.log" || true
    guest_file '$HOME/.fake-amp/calls.log' amp-calls.log || true
  }
  fail() { collect; sed 's/^/    /' "$RUN_DIR/ampere-shell.log" | tail -40; capture_console failure; return 1; }

  log "Guest: $(ssh_guest "pacman -Q hyprland quickshell omarchy 2>/dev/null | tr '\n' ' '")"
  if [[ $what == probe ]]; then
    # The guest's shell sources, to hold Ampere to the APIs this release has.
    ssh_guest "tar -C /usr/share/omarchy -cf - shell/Ui shell/Commons shell/plugins/agents shell/plugins/bar docs 2>/dev/null" > "$RUN_DIR/guest-shell.tar"
    ls -la "$RUN_DIR/guest-shell.tar"
    jq -n '{ok: true, probe: true}' > "$RUN_DIR/ampere-lab.json"
    return 0
  fi

  # ------------------------------------------------------------ fixture amp
  log "Placing the fixture Amp CLI and its threads"
  ssh_guest "mkdir -p \$HOME/.local/bin \$HOME/.fake-amp \$HOME/work/atlas \$HOME/work/beacon && rm -f \$HOME/.fake-amp/calls.log" || return 1
  ssh_guest "cat > \$HOME/.local/bin/amp && chmod +x \$HOME/.local/bin/amp" < "$here/fake-amp" || return 1
  local home
  home=$(ssh_guest 'printf %s "$HOME"')
  python3 - "$home" > "$RUN_DIR/fixture-state.json" <<'PY' || return 1
import json, sys, time
home = sys.argv[1]
now = time.time()
def iso(ago): return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now - ago))
def tid(n): return "T-01a1%04x-5e8b-77ce-80b8-f242bd33c5%02x" % (n, n)
threads = [
  {"id": tid(1), "title": "Refactor the billing webhooks", "updated": iso(40), "working": True, "connected": True, "project": "atlas", "tree": "file://%s/work/atlas" % home, "messageCount": 14},
  {"id": tid(2), "title": "Investigate flaky checkout test in CI", "updated": iso(300), "working": True, "connected": False, "project": "beacon", "tree": "file:///home/user/workspace/repo", "messageCount": 3},
  {"id": tid(3), "title": "Design tokens for the dark theme", "updated": iso(3600 * 3), "status": "3h", "project": "atlas", "tree": "file://%s/work/atlas" % home, "messageCount": 27},
  {"id": tid(4), "title": "Write migration for invoice numbers", "updated": iso(3600 * 20), "status": "20h", "project": "beacon", "tree": "file://%s/work/beacon" % home, "messageCount": 9},
  {"id": tid(5), "title": "Explain the rate limiter", "updated": iso(86400 * 2), "status": "2d", "project": "atlas", "tree": "file://%s/work/atlas" % home, "messageCount": 4},
  {"id": tid(6), "title": "Release notes for 2.4", "updated": iso(86400 * 6), "status": "6d", "project": "beacon", "tree": "file://%s/work/beacon" % home, "messageCount": 6},
  {"id": tid(7), "title": "Spike: atlas search with embeddings", "updated": iso(86400 * 9), "status": "1w", "project": "atlas", "tree": "file://%s/work/atlas" % home, "messageCount": 31},
  {"id": tid(8), "title": "Clean up feature flags", "updated": iso(86400 * 12), "status": "1w", "project": "beacon", "tree": "file://%s/work/beacon" % home, "messageCount": 2},
]
print(json.dumps({"threads": threads}))
PY
  ssh_guest "cat > \$HOME/.fake-amp/state.json" < "$RUN_DIR/fixture-state.json" || return 1
  local first second
  first=$(jq -r '.threads[0].id' "$RUN_DIR/fixture-state.json")
  second=$(jq -r '.threads[1].id' "$RUN_DIR/fixture-state.json")
  check fixture "the fixture answers amp usage" ssh_guest "\$HOME/.local/bin/amp usage | grep -q Megawatt"

  # ------------------------------------------------------------ install
  log "Staging the working tree ($label) and installing it with omarchy-plugin-add"
  stage_plugin "$tree" /tmp/ampere-src || return 1
  ssh_session "omarchy-plugin-add /tmp/ampere-src --enable --yes" > "$RUN_DIR/install.log" 2>&1 || { cat "$RUN_DIR/install.log"; return 1; }
  wait_for_guest_state "Ampere is installed and enabled" 60 ssh_session \
    "omarchy-plugin-list --json | jq -e --arg id '$AMPERE_ID' 'any(.[]; .id == \$id and .enabled == true)'" || return 1
  wait_for_guest_state "Ampere answers over IPC" 60 ssh_session "omarchy-shell $AMPERE_ID working | grep -q ." || { fail; return 1; }
  check install "two threads read as working" within 40 working_is 2
  sleep 2
  shot bar-working

  # ------------------------------------------------------------ art
  # Clean captures for the README and the marketplace preview: three
  # threads working, the panel in the default theme and a light one.
  if [[ $what == art ]]; then
    ssh_guest "jq '.threads[2].working = true | .threads[2].connected = true' \$HOME/.fake-amp/state.json > /tmp/s.json && mv /tmp/s.json \$HOME/.fake-amp/state.json"
    ssh_session "omarchy-shell $AMPERE_ID refresh" >/dev/null
    check art "three threads read as working" within 30 working_is 3
    ssh_session "omarchy-shell $AMPERE_ID open" >/dev/null
    within 10 panel_open; sleep 4
    shot art-dark
    qmp press j; sleep 0.3; qmp press j; sleep 0.8
    shot art-dark-cursor
    qmp press esc; sleep 1
    sleep 2
    shot art-bar
    ssh_session "omarchy-theme-set 'Catppuccin Latte'" > "$RUN_DIR/theme.log" 2>&1 || true
    sleep 6
    ssh_session "omarchy-shell $AMPERE_ID open" >/dev/null
    sleep 4
    shot art-light
    ssh_session "omarchy-shell $AMPERE_ID close" >/dev/null
  fi

  # ------------------------------------------------------------ visual
  if [[ $what == all || $what == visual ]]; then
    log "The panel, open"
    ssh_session "omarchy-shell $AMPERE_ID open" >/dev/null
    check panel "the panel opens as a keyboard panel" within 10 panel_open
    sleep 3
    shot panel
    qmp press n; sleep 1.2
    shot panel-lower
    qmp press esc; sleep 0.4
    qmp press j; sleep 0.6
    shot panel-cursor
    qmp press slash; sleep 0.4; qmp type atlas
    check search "typing searches Amp's threads" within 10 called '["threads","search","--json","-n","30","atlas"]'
    sleep 1.5
    shot search
    qmp press esc; sleep 0.3; qmp press esc; sleep 0.3; qmp press esc
    check panel "Escape closes the panel" within 6 panel_closed

    local light
    light=$(ssh_session "omarchy-theme-list 2>/dev/null" | grep -i -m1 -E 'latte|light|rose-pine-dawn|flexoki-light|white' || true)
    if [[ -n $light ]]; then
      log "The panel in a light theme ($light)"
      ssh_session "omarchy-theme-set '$light'" > "$RUN_DIR/theme.log" 2>&1 || true
      sleep 6
      ssh_session "omarchy-shell $AMPERE_ID open" >/dev/null
      sleep 3
      shot panel-light
      ssh_session "omarchy-shell $AMPERE_ID close" >/dev/null
      note "light theme: $light"
    else
      note "no light theme found in omarchy-theme-list"
    fi

    log "On a vertical bar"
    ssh_session "omarchy bar position left" > "$RUN_DIR/bar-left.log" 2>&1 || true
    sleep 4
    ssh_session "omarchy-shell $AMPERE_ID open" >/dev/null
    sleep 3
    shot panel-vertical
    ssh_session "omarchy-shell $AMPERE_ID close" >/dev/null
    ssh_session "omarchy bar position top" >/dev/null 2>&1 || true
    sleep 3
  fi

  # ------------------------------------------------------------ actions
  if [[ $what == all || $what == actions ]]; then
    log "Thread actions from the keyboard"
    ssh_session "omarchy-shell $AMPERE_ID open" >/dev/null
    within 10 panel_open; sleep 2
    qmp press j; sleep 0.4; qmp press y
    check copy "y copies the thread link" within 8 clipboard_is "https://ampcode.com/threads/$first"
    qmp press j; sleep 0.4; qmp press a
    check archive "a archives the thread under the cursor" within 15 called "[\"threads\",\"archive\",\"$second\"]"
    sleep 2
    qmp press k; sleep 0.4; qmp press e; sleep 0.8
    qmp press ctrl-a; qmp type "Billing webhooks, renamed"; qmp press ret
    check rename "e renames inline" within 15 called "[\"threads\",\"rename\",\"$first\",\"Billing webhooks, renamed\"]"
    sleep 2
    qmp press j; sleep 0.4; qmp press x; sleep 0.6
    shot delete-confirm
    qmp press x
    check delete "x twice deletes" within 15 called '["threads","delete",'
    sleep 1
    qmp press m
    check markdown "m copies the thread as Markdown" within 15 ssh_session "wl-paste -n | head -1 | grep -q '^# '"

    log "Ask Amp: background and terminal"
    qmp press n; sleep 0.5; qmp type "Write the changelog"; sleep 0.3
    shot ask
    qmp press ctrl-ret
    check ask "Ctrl+Enter runs amp -x in the background" within 15 called '["-x","Write the changelog"]'
    check ask "it runs in the chosen directory" called_in "/work/atlas"
    sleep 4
    shot ask-started
    qmp press n; sleep 0.5; qmp type "Hello from the lab"; qmp press ret
    check ask "Enter opens Amp in a terminal with the message piped in" within 20 called '["<stdin>","Hello from the lab"]'
    check ask "the panel closes when a terminal opens" within 6 panel_closed
    sleep 2
    shot terminal
    close_terminals

    log "A finished turn notifies"
    ssh_session "setsid bash -c 'dbus-monitor \"interface=org.freedesktop.Notifications,member=Notify\" > /tmp/ampere-notify.log 2>&1' >/dev/null 2>&1 < /dev/null &"
    sleep 1
    ssh_guest "jq '(.threads[] | select(.working == true and .connected == true) | .working) |= false' \$HOME/.fake-amp/state.json > /tmp/s.json && mv /tmp/s.json \$HOME/.fake-amp/state.json"
    check notify "a thread going quiet sends a notification" within 30 ssh_guest "grep -q 'Amp finished' /tmp/ampere-notify.log"
    sleep 1
    shot notification

    log "Terminal presets and continue"
    ssh_session "omarchy-shell $AMPERE_ID open" >/dev/null
    within 10 panel_open; sleep 2
    qmp press j; sleep 0.3; qmp press c
    check continue "c continues the thread in a terminal" within 15 called '["threads","continue",'
    sleep 2
    close_terminals
    ssh_session "omarchy-shell $AMPERE_ID open" >/dev/null
    within 10 panel_open; sleep 1.5
    qmp press u
    check presets "u opens detailed usage in a terminal" within 15 called '["usage","--details"]'
    sleep 1
    close_terminals
  fi

  # ------------------------------------------------------------ health
  collect
  no_qml_errors() { ! grep -E -i 'TypeError|ReferenceError|Unable to assign|is not a function|Cannot read|qml.*error' "$RUN_DIR/ampere-shell.log"; }
  check health "no QML errors from Ampere in the shell log" no_qml_errors
  sed 's/^/    /' "$RUN_DIR/ampere-shell.log" | head -30
  check health "the shell still answers" ssh_session "omarchy-shell shell ping | grep -qx ok"
  local config_errors
  config_errors=$(ssh_session "hyprctl configerrors" 2>/dev/null | tr -s '[:space:]' ' ')
  [[ -z ${config_errors// /} ]] || note "hyprctl configerrors (Ampere writes no Hyprland config): $config_errors"

  if ((keep > 0)); then
    log "Keeping the guest for $keep s"
    sleep "$keep"
  fi

  jq -n --argjson results "$results" --argjson passed "$passed" --argjson failed "$failed" --arg label "$label" \
    '{ok: ($failed == 0), passed: $passed, failed: $failed, label: $label, results: $results}' > "$RUN_DIR/ampere-lab.json"
  printf '\n%s passed, %s failed\n' "$passed" "$failed"
  ((failed == 0))
}
