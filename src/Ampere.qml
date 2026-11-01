import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../omakit"
import "Model.js" as Model

// Ampere: Amp in the Omarchy bar. One icon that glows while Amp works, and a
// keyboard-first panel with the live current, the plan's allowance, every
// recent thread and its actions, search, and a box that starts new work.
//
// Every program starts through omakit's Run block and the one helper,
// bin/ampere; nothing here builds a shell string. On a bar with a widget per
// screen, the first instance polls and hands what it read to the others.
Panel {
  id: root
  moduleName: "io.github.mtolhuys.ampere"
  ipcTarget: "io.github.mtolhuys.ampere"
  manageIpc: false
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------ look
  readonly property color foreground: Commons.Color.popups.text
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------ settings
  readonly property int idleSeconds: Math.max(20, Number(setting("pollIdleSec", 60)))
  readonly property int activeSeconds: Math.max(4, Number(setting("pollActiveSec", 8)))
  readonly property int previewCount: Math.max(3, Math.min(20, Number(setting("threadCount", 6))))
  readonly property bool notifyOnFinish: setting("notifyOnFinish", true) === true
  readonly property int notifyMinSeconds: Math.max(0, Math.min(3600, Number(setting("notifyMinTurnSec", 30)) || 0))
  readonly property string quietHours: String(setting("notifyQuietHours", "") || "")
  readonly property bool webApp: setting("linkBehavior", "Browser tab") === "Web app window"
  readonly property bool showUsage: setting("showUsage", true) === true

  // ------------------------------------------------------------ helper
  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl("..").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string helper: pluginDir + "/bin/ampere"
  readonly property var helperEnv: {
    var env = {}
    var pass = ["WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS",
                "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
                "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_DATA_DIRS", "DISPLAY"]
    for (var i = 0; i < pass.length; i++) {
      var value = Quickshell.env(pass[i])
      if (value) env[pass[i]] = String(value)
    }
    // Background asks run the project's tools, so they get the session's PATH.
    var sessionPath = Quickshell.env("PATH")
    if (sessionPath) env.AMPERE_SESSION_PATH = String(sessionPath)
    var omarchy = Quickshell.env("OMARCHY_PATH")
    if (omarchy) env.AMPERE_OMARCHY_PATH = String(omarchy)
    var amp = String(setting("ampPath", "") || "")
    if (amp) env.AMPERE_AMP = amp
    return env
  }

  // ------------------------------------------------------------ data
  property var threads: []
  property var dirs: []
  property var account: null
  property bool hasSnapshot: false
  property bool loading: false
  property bool ampMissing: false
  property string snapshotError: ""
  property double fetchedAt: 0
  property double accountAt: 0
  property double now: Date.now()

  readonly property int workingCount: Model.working(threads)
  readonly property var usage: account && account.usage ? account.usage : null
  readonly property bool signedOut: usage !== null && usage.signedIn === false

  // ------------------------------------------------------------ list + cursor
  property string query: ""
  property var results: []
  property var catalog: []
  property double catalogAt: 0
  property bool searching: false
  property bool showAll: false
  readonly property bool inSearch: query.trim() !== ""
  readonly property var rows: inSearch ? results : threads.slice(0, showAll ? 40 : previewCount)
  property int cursor: 0
  property bool cursorActive: false
  readonly property var current: rows.length > 0 ? rows[Math.max(0, Math.min(cursor, rows.length - 1))] : null

  property string confirmId: ""
  property string busyId: ""

  // ------------------------------------------------------------ ask
  property string askText: ""
  property string askDir: ""
  property string mode: ""
  property bool fast: false
  readonly property var askDirOptions: Model.askDirs(askDir, dirs, account ? account.runnerDirs : [], home, 5)

  // Whether this instance polls and owns the IPC target. On a bar with a
  // widget per screen the first one does; refreshed on every poll tick.
  property bool leader: true

  // Not `Palette`/`palette`: QtQuick has a type and every Item a property of
  // that name, and either would shadow this one.
  ThemeHues { id: hues }

  // Working threads, in list order, each with its own voice color.
  readonly property var workingIds: threads.filter(function(r) { return r.working }).map(function(r) { return r.id })
  readonly property var voiceColors: workingIds.map(function(id, i) { return hues.voices[i % hues.voices.length] })
  function voiceFor(row) {
    var i = row ? workingIds.indexOf(row.id) : -1
    return i >= 0 ? hues.voices[i % hues.voices.length] : accent
  }
  readonly property var modeTints: ({ "": accent, low: hues.green, medium: hues.cyan, high: hues.blue, ultra: hues.magenta })

  property string toast: ""
  property bool toastUrgent: false

  // ------------------------------------------------------------ notifications
  // muteUntil: 0 on, -1 off until turned back on, else a snooze's end in ms.
  property double muteUntil: 0
  property var mutedThreads: []
  // When each working thread started its turn, as the polls saw it.
  property var turnStarts: ({})
  readonly property string bell: !notifyOnFinish ? "settings" : Model.muteState(muteUntil, now)
  readonly property string bellText: bell === "settings" ? "Notifications are off in Ampere's settings"
    : (bell === "off" ? "Notifications off"
      : (bell === "snoozed" ? "Snoozed until " + Qt.formatTime(new Date(muteUntil), "HH:mm") : "Notifications on"))

  // ------------------------------------------------------------ lifecycle

  Component.onCompleted: {
    memory.read()
    // The bar lists its instances once they are all made.
    Qt.callLater(function() {
      root.leader = root.isLeader()
      if (!root.leader) return
      root.refreshSnapshot()
      root.refreshAccount()
    })
  }

  onOpenedChanged: {
    if (!opened) {
      confirmId = ""
      return
    }
    now = Date.now()
    cursorActive = false
    cursor = 0
    refreshSnapshot()
    if (Date.now() - accountAt > 60000) refreshAccount()
  }

  onRowsChanged: cursor = Math.max(0, Math.min(cursor, rows.length - 1))

  function peers() {
    return bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
  }
  function isLeader() {
    var list = peers()
    return !list || list.length === 0 || list[0] === root
  }
  function share(fields) {
    var list = peers()
    for (var i = 0; list && i < list.length; i++)
      if (list[i] && list[i] !== root && typeof list[i].receive === "function") list[i].receive(fields)
  }
  function receive(fields) {
    for (var key in fields) root[key] = fields[key]
  }

  // ------------------------------------------------------------ runs

  Run {
    id: snapshotRun
    command: [root.helper, "snapshot", String(Math.max(30, root.previewCount * 4))]
    environment: root.helperEnv
    deadlineMs: 20000
    keepBytes: 1048576
    maxBytes: 4194304
    onFinished: result => root.applySnapshot(result)
  }

  Run {
    id: accountRun
    command: [root.helper, "account"]
    environment: root.helperEnv
    deadlineMs: 40000
    keepBytes: 262144
    onFinished: result => root.applyAccount(result)
  }

  // Search runs here, over every thread Amp lists: `amp threads search`
  // takes the term only as an argument, and a search term is private text.
  Run {
    id: catalogRun
    command: [root.helper, "catalog", "500"]
    environment: root.helperEnv
    deadlineMs: 25000
    maxBytes: 4194304
    keepBytes: 4194304
    onFinished: result => {
      var data = Model.parseJson(result.stdout)
      if (data && data.ok) {
        root.catalog = data.threads || []
        root.catalogAt = Date.now()
        root.filterSearch()
      } else {
        root.searching = false
        root.say(root.failure(result, data, "Search failed"), true)
      }
    }
  }

  // Thread changes wait for their answer; launches answer at once.
  Run {
    id: actionRun
    property string verb: ""
    property string thread: ""
    environment: root.helperEnv
    deadlineMs: 45000
    onFinished: result => root.applyAction(verb, thread, result)
  }

  Run {
    id: launchRun
    property string done: ""
    environment: root.helperEnv
    deadlineMs: 15000
    onFinished: result => {
      var data = Model.parseJson(result.stdout)
      if (data && data.ok) { if (done) root.say(done, false) }
      else root.say(root.failure(result, data, "Could not start that"), true)
    }
  }

  Run {
    id: notifyRun
    environment: root.helperEnv
    deadlineMs: 10000
  }

  Store {
    id: memory
    pluginId: "io.github.mtolhuys.ampere"
    name: "memory.json"
    schema: ({
      type: "object",
      required: ["version"],
      additionalProperties: false,
      properties: {
        version: { type: "integer", minimum: 1, maximum: 1 },
        dir: { type: "string", maxLength: 4096 },
        mode: { type: "string", enum: ["", "low", "medium", "high", "ultra"] },
        fast: { type: "boolean" },
        muteUntil: { type: "number", minimum: -1 },
        mutedThreads: { type: "array", maxItems: 200, items: { type: "string", pattern: "^T-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" } }
      }
    })
    onFinished: result => {
      if (result.op !== "read" || result.state !== "ok" || !result.value) return
      root.askDir = result.value.dir || ""
      root.mode = result.value.mode || ""
      root.fast = result.value.fast === true
      root.muteUntil = Number(result.value.muteUntil || 0)
      root.mutedThreads = result.value.mutedThreads || []
    }
  }

  function remember() {
    memory.write({ version: 1, dir: askDir, mode: mode, fast: fast, muteUntil: muteUntil, mutedThreads: mutedThreads })
  }

  // ------------------------------------------------------------ timers

  Timer {
    id: pollTimer
    running: true
    repeat: true
    interval: (root.opened ? 4 : (root.workingCount > 0 ? root.activeSeconds : root.idleSeconds)) * 1000
    // Peers come and go with screens, so who polls is decided on every tick.
    onTriggered: {
      root.leader = root.isLeader()
      if (root.opened || root.leader) root.refreshSnapshot()
    }
  }

  Timer {
    running: true
    repeat: true
    interval: 10 * 60 * 1000
    onTriggered: if (root.isLeader()) root.refreshAccount()
  }

  Timer {
    running: root.opened
    repeat: true
    interval: 1000
    onTriggered: root.now = Date.now()
  }

  Timer {
    id: searchDebounce
    interval: 280
    onTriggered: root.runSearch()
  }

  Timer {
    id: toastTimer
    interval: 3200
    onTriggered: root.toast = ""
  }

  Timer {
    id: confirmTimer
    interval: 4000
    onTriggered: root.confirmId = ""
  }

  // ------------------------------------------------------------ data flow

  function refreshSnapshot() {
    if (snapshotRun.running) return
    loading = true
    snapshotRun.start()
  }

  function refreshAccount() {
    if (accountRun.running) return
    accountRun.start()
  }

  function refreshAll() {
    refreshSnapshot()
    refreshAccount()
    if (inSearch) runSearch()
    say("Refreshing", false)
  }

  function failure(result, data, fallback) {
    if (data && data.error === "amp-missing") return "The Amp CLI is not installed"
    if (data && data.error) return data.error
    if (result.state === "timeout") return fallback + ": Amp did not answer in time"
    if (result.reason) return fallback + ": " + result.reason
    return fallback + " (" + result.state + ")"
  }

  function applySnapshot(result) {
    loading = false
    var data = Model.parseJson(result.stdout)
    if (!data || !data.ok) {
      ampMissing = !!data && data.error === "amp-missing"
      snapshotError = failure(result, data, "Could not reach Amp")
      share({ ampMissing: ampMissing, snapshotError: snapshotError })
      return
    }
    var before = threads
    var hadSnapshot = hasSnapshot
    threads = data.threads || []
    dirs = data.dirs || []
    fetchedAt = Date.now()
    hasSnapshot = true
    ampMissing = false
    snapshotError = data.error || ""
    share({ threads: threads, dirs: dirs, fetchedAt: fetchedAt, hasSnapshot: true, ampMissing: false, snapshotError: snapshotError })
    var starts = turnStarts
    turnStarts = Model.turnStarts(starts, threads, fetchedAt)
    if (hadSnapshot && isLeader()) notifyFinished(Model.finished(before, threads), starts)
  }

  // One notification per poll: a second start() on the same Run would
  // cancel the first before it was sent. Nothing while the panel is open,
  // where the row says it already.
  function notifyFinished(done, starts) {
    if (done.length === 0 || !notifyOnFinish || anyOpen()) return
    if (Model.muteState(muteUntil, Date.now()) !== "on") return
    if (Model.inQuietHours(quietHours, new Date())) return
    done = Model.notifiable(done, starts, Date.now(), notifyMinSeconds, mutedThreads)
    if (done.length === 1) notify("Amp finished a turn", done[0].title, done[0].url)
    else if (done.length > 1)
      notify("Amp finished " + done.length + " turns", done.map(function(r) { return r.title }).join("  ·  "), "https://ampcode.com/")
  }

  function anyOpen() {
    var list = peers()
    for (var i = 0; list && i < list.length; i++) if (list[i] && list[i].opened) return true
    return false
  }

  function setMute(until) {
    now = Date.now()
    muteUntil = until
    share({ muteUntil: muteUntil })
    remember()
  }

  function cycleBell() {
    if (!notifyOnFinish) { say(bellText, true); return }
    setMute(Model.nextMute(muteUntil, Date.now()))
    say(bellText, false)
  }

  function toggleThreadMute(row) {
    var muted = mutedThreads.indexOf(row.id) >= 0
    mutedThreads = muted ? mutedThreads.filter(function(id) { return id !== row.id })
                         : [row.id].concat(mutedThreads).slice(0, 200)
    share({ mutedThreads: mutedThreads })
    remember()
    say(muted ? "This thread notifies again" : "This thread no longer notifies", false)
  }

  function applyAccount(result) {
    var data = Model.parseJson(result.stdout)
    if (!data || !data.ok) {
      if (data && data.error === "amp-missing") ampMissing = true
      return
    }
    account = data
    accountAt = Date.now()
    share({ account: account, accountAt: accountAt })
  }

  function runSearch() {
    if (!query.trim()) { results = []; searching = false; return }
    if (Date.now() - catalogAt < 60000) { filterSearch(); return }
    searching = true
    if (!catalogRun.running) catalogRun.start()
  }

  function filterSearch() {
    searching = false
    results = Model.search(catalog, threads, query, 40)
  }

  function setQuery(text) {
    query = text
    cursor = 0
    if (text.trim() === "") { results = []; searching = false; searchDebounce.stop() }
    else searchDebounce.restart()
  }

  function say(text, isUrgent) {
    toast = text
    toastUrgent = isUrgent === true
    toastTimer.restart()
  }

  // A prompt is private text: it goes to the helper in the environment,
  // which only this account can read, never in the command line.
  function launch(args, doneText, prompt) {
    launchRun.done = doneText || ""
    launchRun.environment = prompt ? Object.assign({}, helperEnv, { AMPERE_PROMPT: String(prompt).slice(0, 16000) }) : helperEnv
    launchRun.command = [helper].concat(args)
    launchRun.start()
  }

  // Thread titles are conversation text: they go to the helper in the
  // environment, never in the command line.
  function notify(title, body, url) {
    notifyRun.environment = Object.assign({}, helperEnv, { AMPERE_NOTIFY: JSON.stringify({ title: title, body: body, url: url || "" }) })
    notifyRun.command = [helper, "notify"]
    notifyRun.start()
  }

  // ------------------------------------------------------------ actions

  function openUrl(url) {
    if (!url) return
    launch(["open", url].concat(webApp ? ["--webapp"] : []), "")
    close()
  }

  function continueThread(row) {
    if (!row) return
    launch(["continue", row.id, row.dir || askDir || home], "")
    close()
  }

  function threadAction(name, row) {
    row = row || current
    if (!row) return
    if (name === "open") openUrl(row.url)
    else if (name === "continue") continueThread(row)
    else if (name === "copy") launch(["copy", row.url], "Link copied")
    else if (name === "markdown") runAction("markdown", row)
    else if (name === "rename") { say("Rename it on ampcode.com", false); openUrl(row.url) }
    else if (name === "archive") runAction("archive", row)
    else if (name === "mute") toggleThreadMute(row)
    else if (name === "delete") {
      if (confirmId === row.id) { confirmId = ""; runAction("delete", row) }
      else { confirmId = row.id; confirmTimer.restart() }
    }
  }

  function runAction(verb, row, extra) {
    if (actionRun.running) { say("One moment, Amp is still answering", true); return }
    busyId = row.id
    actionRun.verb = verb
    actionRun.thread = row.id
    actionRun.command = [helper, "thread", verb, row.id].concat(extra ? [extra] : [])
    actionRun.start()
    if (verb === "markdown") say("Rendering the thread", false)
  }

  function applyAction(verb, id, result) {
    busyId = ""
    var data = Model.parseJson(result.stdout)
    if (!data || !data.ok) { say(failure(result, data, "Amp refused"), true); return }
    var words = { archive: "Archived", delete: "Deleted", markdown: "Markdown copied", visibility: "Visibility changed" }
    say(words[verb] || "Done", false)
    if (verb === "archive" || verb === "delete") {
      threads = threads.filter(function(r) { return r.id !== id })
      results = results.filter(function(r) { return r.id !== id })
    }
    if (verb !== "markdown") refreshSnapshot()
    if (verb === "archive" || verb === "delete") catalog = catalog.filter(function(r) { return r.id !== id })
  }

  function startAsk(route) {
    var text = askText.trim()
    var dir = askDir || (askDirOptions.length ? askDirOptions[0] : home)
    var extra = (mode ? ["--mode", mode] : []).concat(fast ? ["--fast"] : [])
    if (route === "terminal") {
      launch(["new", dir].concat(extra), "", text)
      askText = ""
      close()
      return
    }
    if (!text) { say("Write what Amp should do first", true); return }
    launch(["exec", dir].concat(extra).concat(route === "orb" ? ["--orb"] : []),
           route === "orb" ? "Sent to an orb, it will show up above" : "Amp is on it in the background", text)
    askText = ""
    keyFocus()
    // The new thread appears in Amp's list a moment later.
    Qt.callLater(function() { delayedRefresh.restart() })
  }

  Timer {
    id: delayedRefresh
    interval: 2500
    onTriggered: root.refreshSnapshot()
  }

  function terminalPreset(name) {
    launch(["term", name], "")
    close()
  }

  // ------------------------------------------------------------ cursor

  function moveCursor(delta) {
    if (rows.length === 0) return
    if (!cursorActive) { cursorActive = true; cursor = delta > 0 ? 0 : rows.length - 1 }
    else cursor = Math.max(0, Math.min(rows.length - 1, cursor + delta))
    confirmId = ""
    keys.reveal(keys.rowAt(cursor))
  }

  function pointAt(index) {
    cursorActive = true
    cursor = index
  }

  function keyFocus() {
    keys.forceActiveFocus()
  }

  function focusSearch() {
    searchField.forceActiveFocus()
  }

  function focusAsk() {
    askField.forceActiveFocus()
  }

  // From the keyboard, a thread action needs a row the person can see is
  // chosen; the first press shows the cursor instead of acting on row one.
  function keyAction(name) {
    if (!cursorActive) { moveCursor(1); return }
    threadAction(name)
  }

  function textKey(t) {
    if (t === "/") focusSearch()
    else if (t === "n" || t === "i") focusAsk()
    else if (t === "r") refreshAll()
    else if (t === "c") keyAction("continue")
    else if (t === "o") keyAction("open")
    else if (t === "y") keyAction("copy")
    else if (t === "m") keyAction("markdown")
    else if (t === "e") keyAction("rename")
    else if (t === "a") keyAction("archive")
    else if (t === "q") keyAction("mute")
    else if (t === "b") cycleBell()
    else if (t === "t") terminalPreset("top")
    else if (t === "u") terminalPreset("usage")
    else if (t === "d") openUrl("https://ampcode.com/")
    else if (t === "f") { fast = !fast; remember() }
    else if (t === "s") { showAll = !showAll }
    else if (t >= "0" && t <= "4") { mode = Model.MODES[Number(t)].id; remember() }
  }

  // ------------------------------------------------------------ ipc

  // IpcHandler rather than ShellIpc, which Omarchy 4.0.4 does not have.
  IpcHandler {
    target: root.ipcTarget
    enabled: root.leader
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshAll(); return "ok" }
    function ask(): void { root.open(); Qt.callLater(root.focusAsk) }
    function search(): void { root.open(); Qt.callLater(root.focusSearch) }
    function newThread(): void { root.startAsk("terminal") }
    function resume(): void { if (root.threads.length) root.continueThread(root.threads[0]) }
    function top(): void { root.terminalPreset("top") }
    function working(): string { return String(root.workingCount) }
    function notifications(): string { root.now = Date.now(); return root.bell }
    function mute(): string { root.setMute(-1); return root.bell }
    function unmute(): string { root.setMute(0); return root.bell }
    function snooze(minutes: string): string {
      var m = Math.max(1, Math.min(1440, Number(minutes) || 60))
      root.setMute(Date.now() + m * 60000)
      return root.bell
    }
  }

  // ------------------------------------------------------------ bar icon

  readonly property string barTooltip: ampMissing ? "Amp CLI not found"
    : (workingCount > 0 ? "Amp · " + workingCount + (workingCount === 1 ? " thread working" : " threads working")
      : (usage && usage.agent ? "Amp · " + Model.money(usage.agent.remaining) + " left" : "Amp"))

  Rectangle {
    id: halo
    anchors.centerIn: parent
    width: Math.min(parent.width, parent.height) * 0.92
    height: width
    radius: width / 2
    color: root.accent
    visible: root.workingCount > 0
    opacity: 0
    SequentialAnimation on opacity {
      running: halo.visible && Style.reduceMotion !== true
      loops: Animation.Infinite
      NumberAnimation { from: 0.04; to: 0.26; duration: 1100; easing.type: Easing.InOutSine }
      NumberAnimation { from: 0.26; to: 0.04; duration: 1100; easing.type: Easing.InOutSine }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.ampMissing ? "󱐌" : "󱐋"
    active: root.workingCount > 0 || root.opened
    activeColor: root.accent
    dimmed: root.ampMissing
    tooltipText: root.opened ? "" : root.barTooltip
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refreshAll()
      else if (buttonCode === Qt.RightButton) { if (root.threads.length) root.continueThread(root.threads[0]) }
      else root.toggle()
    }
  }

  Rectangle {
    visible: root.workingCount > 1
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: Math.max(0, (parent.width - Style.bar.iconSlot) / 2 - Style.space(1))
    anchors.topMargin: Math.max(0, (parent.height - Style.bar.iconSlot) / 2)
    width: Math.max(height, badgeText.implicitWidth + Style.space(5))
    height: Style.space(12)
    radius: height / 2
    color: root.accent
    Text {
      id: badgeText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: String(root.workingCount)
      color: Commons.Color.background
      font.family: root.fontFamily
      font.pixelSize: Style.space(8)
      font.bold: true
    }
  }

  // ------------------------------------------------------------ panel

  KeyboardPanel {
    id: keyPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: keyPanel.fittedContentWidth(Style.space(440))
    contentHeight: keyPanel.fittedContentHeight(keys.implicitHeight, Style.space(900))

    // Children rather than the lazy `content` component, which Omarchy 4.0.4's
    // KeyboardPanel does not have.
    PanelKeyCatcher {
      id: keys
      implicitHeight: column.implicitHeight
      anchors.fill: parent

      function rowAt(i) { return rowRepeater.itemAt(i) }
      function reveal(item) {
        if (!item) return
        Qt.callLater(function() {
          var p = item.mapToItem(flick.contentItem, 0, 0)
          var m = Style.space(10)
          var maxY = Math.max(0, flick.contentHeight - flick.height)
          if (p.y < flick.contentY + m) flick.contentY = Math.max(0, p.y - m)
          else if (p.y + item.height > flick.contentY + flick.height - m)
            flick.contentY = Math.min(maxY, p.y + item.height + m - flick.height)
        })
      }

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.keyAction("open")
      onDeleteRequested: root.keyAction("delete")
      onCloseRequested: {
        if (root.confirmId !== "") root.confirmId = ""
        else if (root.inSearch) root.setQuery("")
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.textKey(t) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { id: scroll; policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width - (flick.interactive ? scroll.width + Style.space(6) : 0)
          spacing: Style.space(14)

          // ---------------------------------------------------- hero
          PanelHero {
            id: hero
            width: parent.width
            title: "Amp"
            detail: root.usage ? Model.tierShort(root.usage.tier) : ""
            meta: root.ampMissing ? "Amp CLI not found"
              : (root.signedOut ? "Signed out"
                : ((root.usage && root.usage.user ? "@" + root.usage.user + "  ·  " : "")
                  + (root.workingCount > 0 ? root.workingCount + " working" : (root.hasSnapshot ? "all quiet" : "connecting"))))
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                implicitWidth: Style.space(40)
                implicitHeight: Style.space(40)

                Rectangle {
                  anchors.fill: parent
                  radius: Math.max(Style.cornerRadius, width * 0.28)
                  gradient: Gradient {
                    GradientStop { position: 0.0; color: Util.alpha(root.accent, 0.34) }
                    GradientStop { position: 1.0; color: Util.alpha(hues.magenta, 0.16) }
                  }
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.accent, 0.45)
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: "󱐋"
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                  SequentialAnimation on opacity {
                    running: root.workingCount > 0 && root.opened && Style.reduceMotion !== true
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) parent.opacity = 1
                    NumberAnimation { to: 0.55; duration: 900; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
                  }
                }
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.space(2)
                PanelActionButton {
                  iconText: root.bell === "on" ? "󰂚" : (root.bell === "snoozed" ? "󰂟" : "󰂛")
                  tooltipText: root.bellText + "  (b)"
                  foreground: root.bell === "on" ? root.foreground : (root.bell === "snoozed" ? hues.yellow : Util.alpha(root.foreground, 0.45))
                  hoverColor: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.cycleBell()
                }
                PanelActionButton {
                  iconText: "󰐕"
                  tooltipText: "New thread in a terminal"
                  foreground: root.foreground
                  hoverColor: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.startAsk("terminal")
                }
                PanelActionButton {
                  id: refreshButton
                  iconText: "󰑐"
                  tooltipText: "Refresh  (r)"
                  foreground: root.foreground
                  hoverColor: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.refreshAll()
                  RotationAnimator on rotation {
                    running: (root.loading || accountRun.running) && root.opened && Style.reduceMotion !== true
                    from: 0; to: 360; duration: 900; loops: Animation.Infinite
                    onRunningChanged: if (!running) refreshButton.rotation = 0
                  }
                }
                PanelActionButton {
                  iconText: "󰖟"
                  tooltipText: "Open ampcode.com  (d)"
                  foreground: root.foreground
                  hoverColor: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.openUrl("https://ampcode.com/")
                }
              }
            }
          }

          // ---------------------------------------------------- trouble
          BorderSurface {
            visible: root.ampMissing || root.signedOut || (root.snapshotError !== "" && !root.hasSnapshot)
            width: parent.width
            implicitHeight: troubleColumn.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            color: Util.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(Util.alpha(root.urgent, 0.45), Math.max(1, Style.space(1)))

            Column {
              id: troubleColumn
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.ampMissing ? "Ampere could not find the amp command. Install the Amp CLI, or set its path in this widget's settings."
                  : (root.signedOut ? "You are signed out of Amp." : root.snapshotError)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Row {
                spacing: Style.space(6)
                Chip {
                  visible: root.ampMissing
                  glyph: "󰇚"; text: "Install guide"
                  foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                  onClicked: root.openUrl("https://ampcode.com/manual#getting-started")
                }
                Chip {
                  visible: root.signedOut || (!root.ampMissing && root.snapshotError !== "")
                  glyph: "󰍂"; text: "Sign in"
                  foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                  onClicked: root.terminalPreset("login")
                }
              }
            }
          }

          // ---------------------------------------------------- current
          Oscilloscope {
            width: parent.width
            working: root.workingCount
            voices: root.voiceColors
            animate: root.opened
            stale: !root.hasSnapshot
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            leftLabel: "LIVE CURRENT"
            rightLabel: String(root.workingCount)
            footLabel: !root.hasSnapshot ? "listening for Amp…"
              : (root.fetchedAt ? "updated " + (Model.ago(new Date(root.fetchedAt).toISOString(), root.now) === "now"
                  ? "just now" : Model.ago(new Date(root.fetchedAt).toISOString(), root.now) + " ago") : "")
          }

          // ---------------------------------------------------- allowance
          Column {
            visible: root.showUsage && root.usage !== null && (root.usage.agent !== null || root.usage.orb !== null || root.usage.lines.length > 0)
            width: parent.width
            spacing: Style.space(10)

            readonly property real elapsed: root.usage ? Model.periodElapsed(root.usage.period, root.now) : -1

            // The two allowances side by side; one alone takes the row.
            Row {
              id: meters
              width: parent.width
              spacing: Style.space(18)
              readonly property bool both: !!root.usage && root.usage.agent !== null && root.usage.orb !== null
              readonly property real cell: both ? (width - spacing) / 2 : width
              readonly property real elapsed: parent.elapsed

              Meter {
                visible: !!root.usage && root.usage.agent !== null
                width: meters.cell
                label: "Agent"
                value: root.usage && root.usage.agent ? Model.money(root.usage.agent.remaining) + " / " + Model.money(root.usage.agent.total) : ""
                fraction: root.usage && root.usage.agent ? root.usage.agent.percent / 100 : 0
                hue: {
                  var p = root.usage && root.usage.agent ? Model.pace(root.usage.agent.percent, meters.elapsed) : 0
                  return p <= 0 ? root.accent : (p < 0.85 ? hues.green : (p <= 1.15 ? root.accent : hues.yellow))
                }
                paceAt: meters.elapsed >= 0 ? 1 - meters.elapsed : -1
                detail: root.usage && root.usage.agent
                  ? root.usage.agent.percent + "% left  ·  " + Model.paceWord(Model.pace(root.usage.agent.percent, meters.elapsed))
                  : ""
                foreground: root.foreground; accent: root.accent; urgent: root.urgent; fontFamily: root.fontFamily
              }

              Meter {
                visible: !!root.usage && root.usage.orb !== null
                width: meters.cell
                label: "Orb hours"
                value: root.usage && root.usage.orb ? Model.hours(root.usage.orb.remaining) + " / " + Model.hours(root.usage.orb.total) : ""
                fraction: root.usage && root.usage.orb ? root.usage.orb.percent / 100 : 0
                hue: hues.cyan
                paceAt: meters.elapsed >= 0 ? 1 - meters.elapsed : -1
                detail: root.usage && root.usage.orb ? root.usage.orb.percent + "% left  ·  " + root.usage.orb.size : ""
                foreground: root.foreground; accent: root.accent; urgent: root.urgent; fontFamily: root.fontFamily
              }
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(resetText.implicitHeight, creditText.implicitHeight)
              Text {
                id: resetText
                textFormat: Text.PlainText
                anchors.left: parent.left
                text: root.usage && root.usage.period
                  ? (root.usage.period.resetsInDays !== null ? "Resets in " + root.usage.period.resetsInDays + (root.usage.period.resetsInDays === 1 ? " day" : " days") + "  ·  " : "")
                    + Model.monthDay(root.usage.period.end)
                  : (root.usage && root.usage.agent === null && root.usage.lines.length ? root.usage.lines[0] : "")
                color: Util.alpha(root.foreground, 0.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                width: Math.min(implicitWidth, parent.width - creditText.implicitWidth - Style.space(8))
                elide: Text.ElideRight
              }
              Text {
                id: creditText
                textFormat: Text.PlainText
                anchors.right: parent.right
                visible: !!root.usage && root.usage.credits !== null
                text: root.usage && root.usage.credits !== null ? "Credits " + Model.money(root.usage.credits) : ""
                color: Util.alpha(root.foreground, 0.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---------------------------------------------------- threads
          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: searchField.implicitHeight

              TextField {
                id: searchField
                anchors.left: parent.left
                anchors.right: parent.right
                verticalPadding: Style.space(5)
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                leftPadding: Style.space(28)
                placeholderText: "Search every thread"
                text: root.query
                onTextEdited: root.setQuery(text)
                Keys.onEscapePressed: { if (text !== "") root.setQuery(""); else root.keyFocus() }
                Keys.onDownPressed: { root.keyFocus(); root.moveCursor(1) }
                Keys.onUpPressed: { root.keyFocus(); root.moveCursor(-1) }
                Keys.onReturnPressed: { root.keyFocus(); if (root.rows.length) { root.pointAt(0); root.threadAction("open") } }
              }

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: root.searching ? "󰔟" : "󰍉"
                color: Util.alpha(root.foreground, 0.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                visible: !searchField.activeFocus && searchField.text === ""
                text: "/"
                color: Util.alpha(root.foreground, 0.35)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Item {
              width: parent.width
              implicitHeight: sectionLabel.implicitHeight + Style.space(4)

              PanelSectionHeader {
                id: sectionLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: (root.inSearch ? (root.searching ? "Searching" : root.results.length + " found") : (root.workingCount > 0 ? "Live and recent" : "Recent threads")).toUpperCase()
                font.letterSpacing: 1.2
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.inSearch && root.threads.length > root.previewCount
                text: root.showAll ? "Fewer" : "All " + root.threads.length
                color: moreMouse.containsMouse ? root.accent : Util.alpha(root.foreground, 0.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                MouseArea {
                  id: moreMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.showAll = !root.showAll
                }
              }
            }

            Repeater {
              id: rowRepeater
              model: root.rows

              ThreadRow {
                required property var modelData
                required property int index
                width: column.width
                thread: modelData
                now: root.now
                hasCursor: root.cursorActive && root.cursor === index
                confirming: root.confirmId === modelData.id
                busy: root.busyId === modelData.id
                muted: root.mutedThreads.indexOf(modelData.id) >= 0
                animate: root.opened
                tint: root.voiceFor(modelData)
                projectColor: hues.hueFor(modelData.project)
                foreground: root.foreground
                accent: root.accent
                urgent: root.urgent
                fontFamily: root.fontFamily
                onHovered: root.pointAt(index)
                onActivated: { root.pointAt(index); root.threadAction("open", modelData) }
                onAction: function(name) { root.pointAt(index); root.threadAction(name, modelData) }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.rows.length === 0
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(10)
              bottomPadding: Style.space(10)
              text: root.inSearch ? (root.searching ? "Looking through your threads…" : "Nothing matches “" + root.query.trim() + "”")
                : (root.hasSnapshot ? "No threads yet. Ask Amp something below." : "Reading your threads…")
              color: Util.alpha(root.foreground, 0.45)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          // ---------------------------------------------------- ask
          BorderSurface {
            id: askBox
            width: parent.width
            implicitHeight: askColumn.implicitHeight + Style.space(24)
            radius: Style.cornerRadius
            color: Util.alpha(root.accent, 0.05)
            borderSpec: Border.flat(Util.alpha(root.accent, askField.activeFocus ? 0.55 : 0.22), Math.max(1, Style.space(1)))
            Behavior on color { ColorAnimation { duration: (Style.reduceMotion === true ? 0 : 150) } }

            Column {
              id: askColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(10)

              Row {
                spacing: Style.space(6)
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰚩"
                  color: hues.magenta
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "ASK AMP"
                  color: Util.alpha(root.foreground, 0.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.4
                }
              }

              TextField {
                id: askField
                width: parent.width
                onActiveFocusChanged: if (activeFocus) keys.reveal(askBox)
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                placeholderText: "What should Amp do?   (n)"
                text: root.askText
                onTextEdited: root.askText = text
                Keys.onEscapePressed: root.keyFocus()
                Keys.onPressed: function(event) {
                  if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return
                  event.accepted = true
                  if (event.modifiers & Qt.AltModifier) root.startAsk("orb")
                  else if (event.modifiers & Qt.ControlModifier) root.startAsk("background")
                  else root.startAsk("terminal")
                }
              }

              Flow {
                width: parent.width
                spacing: Style.space(5)
                Repeater {
                  model: root.askDirOptions
                  Chip {
                    required property var modelData
                    required property int index
                    glyph: modelData === root.home ? "󰋜" : "󰉋"
                    text: modelData === root.home ? "~" : Model.baseName(modelData)
                    tooltip: Model.prettyDir(modelData, root.home)
                    maxTextWidth: Style.space(120)
                    selected: (root.askDir || root.askDirOptions[0]) === modelData
                    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                    onClicked: { root.askDir = modelData; root.remember() }
                  }
                }
              }

              Flow {
                width: parent.width
                spacing: Style.space(5)
                Repeater {
                  model: Model.MODES
                  Chip {
                    required property var modelData
                    required property int index
                    text: modelData.label
                    tooltip: modelData.hint + "  (" + index + ")"
                    selected: root.mode === modelData.id
                    tint: root.modeTints[modelData.id] || root.accent
                    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                    onClicked: { root.mode = modelData.id; root.remember() }
                  }
                }
                Chip {
                  glyph: "󱐋"
                  text: "Fast"
                  tooltip: "Faster serving, billed at a premium  (f)"
                  selected: root.fast
                  tint: hues.yellow
                  foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                  onClicked: { root.fast = !root.fast; root.remember() }
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(6)
                readonly property real third: (width - spacing * 2) / 3

                Repeater {
                  model: [
                    { route: "terminal", glyph: "󰆍", label: "Terminal", keys: "Enter", hue: "green", tip: "Open Amp in a terminal with this as the first message" },
                    { route: "background", glyph: "󰒲", label: "Background", keys: "Ctrl+Enter", hue: "cyan", tip: "Run it headless here; a notification says when it is done" },
                    { route: "orb", glyph: "󰅟", label: "Orb", keys: "Alt+Enter", hue: "magenta", tip: "Run it in an Amp orb in the cloud, for this directory's project" }
                  ]
                  CursorSurface {
                    required property var modelData
                    width: parent.third
                    implicitHeight: routeColumn.implicitHeight + Style.space(12)
                    hasCursor: routeMouse.containsMouse
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent

                    Column {
                      id: routeColumn
                      anchors.centerIn: parent
                      spacing: Style.space(1)
                      Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Style.space(6)
                        Text {
                          textFormat: Text.PlainText
                          text: modelData.glyph
                          color: hues.hue(modelData.hue)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                        Text {
                          textFormat: Text.PlainText
                          text: modelData.label
                          color: routeMouse.containsMouse ? hues.hue(modelData.hue) : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: true
                        }
                      }
                      Text {
                        textFormat: Text.PlainText
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.keys
                        color: Util.alpha(root.foreground, 0.4)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    MouseArea {
                      id: routeMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.startAsk(modelData.route)
                    }
                    PanelToolTip {
                      visible: routeMouse.containsMouse
                      text: modelData.tip
                    }
                  }
                }
              }
            }
          }

          // ---------------------------------------------------- toolbox
          Grid {
            id: tiles
            width: parent.width
            columns: 4
            spacing: Style.space(6)
            readonly property real cell: (width - spacing * (columns - 1)) / columns

            Repeater {
              model: [
                { glyph: "󰕮", text: "Dashboard", hue: "blue", tip: "ampcode.com  (d)", web: "https://ampcode.com/" },
                { glyph: "󰄨", text: "Usage", hue: "green", tip: "Detailed usage in a terminal  (u)", term: "usage" },
                { glyph: "󰨇", text: "Top", hue: "cyan", tip: "Live thread monitor  (t)", term: "top" },
                { glyph: "󰒓", text: "Settings", hue: "magenta", tip: "Amp settings on the web", web: "https://ampcode.com/settings" },
                { glyph: "󰘦", text: "MCP", hue: "yellow", tip: "Check MCP servers", term: "doctor" },
                { glyph: "󱁤", text: "Skills", hue: "green", tip: "Installed skills", term: "skills" },
                { glyph: "󰆧", text: "Models", hue: "blue", tip: "Model provider connections", term: "providers" },
                { glyph: "󰚰", text: "Update", hue: "cyan", tip: "Update the Amp CLI" + (root.account && root.account.version ? "  ·  " + root.account.version : ""), term: "update" }
              ]
              Tile {
                required property var modelData
                width: tiles.cell
                glyph: modelData.glyph
                text: modelData.text
                tooltip: modelData.tip
                tint: hues.hue(modelData.hue)
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: modelData.web ? root.openUrl(modelData.web) : root.terminalPreset(modelData.term)
              }
            }
          }

          // ---------------------------------------------------- footer
          Item {
            width: parent.width
            implicitHeight: Math.max(hint.implicitHeight, toastText.implicitHeight)

            Text {
              id: hint
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              visible: root.toast === ""
              horizontalAlignment: Text.AlignHCenter
              text: "⏎ open  ·  c continue  ·  y copy  ·  e rename  ·  a archive  ·  x delete"
              color: Util.alpha(root.foreground, 0.32)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              id: toastText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              horizontalAlignment: Text.AlignHCenter
              opacity: root.toast !== "" ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: (Style.reduceMotion === true ? 0 : 160) } }
              text: root.toast
              color: root.toastUrgent ? root.urgent : root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }
}
