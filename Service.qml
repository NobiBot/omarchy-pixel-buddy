import QtQuick
import Quickshell
import Quickshell.Io
import "lib/jsonc.mjs" as Jsonc
import "lib/work-status.mjs" as WS
import "lib/usage.mjs" as Usage
import "lib/i18n.mjs" as I18n
import "lib/packs.mjs" as Packs

// pixel-buddy's state hub: config, sprite packs, Claude Code / Codex work status, usage, LLM, notifications, IPC.
// One BuddyOverlay (fullscreen transparent layer-shell window) per screen that has buddies.
Scope {
  id: root

  // Injected by the host
  property var shell: null
  property string omarchyPath: ""
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string userConfigPath: home + "/.config/pixel-buddy/config.jsonc"
  readonly property string stateDir: home + "/.local/state/pixel-buddy"
  // Directory of the hook event socket (0700), same as bin/pixel-buddy-hook
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") + "/pixel-buddy"

  // ------------------------------------------------------------ Config
  property var config: ({})
  property bool ready: false
  property string configError: ""
  property bool hidden: false

  function tr(key, params) {
    return I18n.t(key, params)
  }

  readonly property var buddies: (config.buddies || []).filter(function(p) { return p.display !== "none" })

  function rebuildConfig() {
    var base
    try {
      base = JSON.parse(defaultFile.text())
    } catch (e) {
      console.warn("[pixel-buddy] Couldn't parse the built-in config:", e)
      return
    }
    var merged = Object.assign({}, base)
    configError = ""
    var userText = userFile.loaded ? userFile.text() : ""
    if (userText.trim() !== "") {
      try {
        // Top-level keys replace whole (same as dsh-pet): any key the user sets is taken entirely from the user's file
        Object.assign(merged, Jsonc.parseJsonc(userText) || {})
      } catch (e) {
        configError = String(e)
        console.warn("[pixel-buddy] Couldn't parse the user config, using the built-in one:", e)
      }
    }
    config = merged
    rebuildRuntimes()
    ready = true
    // restart() wipes the running binding, so start and stop explicitly by the setting; otherwise it would murmur on a timer even with whisperAuto=false
    if (merged.whisperAuto === true) whisperTimer.restart()
    else whisperTimer.stop()
    usageTimer.restart()
    if (configError) speak("", tr("configError", { error: configError }), "", "error")
  }

  function reloadConfig() {
    userFile.reload()
    defaultFile.reload()
    indexFile.reload()
    uiFile.reload()
  }

  FileView {
    id: defaultFile
    path: root.pluginDir + "/assets/config.json"
    blockLoading: true
    onLoaded: root.rebuildConfig()
  }

  // ------------------------------------------------------------ Sprite packs
  // Sources live in packs/ (a symlink to ~/.local/share/pixel-buddy/packs, so edits never trip
  // Omarchy's plugin reload). bin/pixel-buddy-pack watch rebuilds a pack when its files change
  // and lists every pack in ~/.cache/pixel-buddy/index.json. Each buddy plays the pack the bar
  // widget picked for it (~/.config/pixel-buddy/ui.json), else buddies[].pack, else "default".
  readonly property string packTool: pluginDir + "/bin/pixel-buddy-pack"
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/pixel-buddy"
  readonly property string uiStatePath: home + "/.config/pixel-buddy/ui.json"
  property var packIndex: ({})
  property var packList: []
  property var uiState: ({ buddies: {} })
  // buddyId -> everything Buddy.qml needs from its pack (see makeRuntime)
  property var runtimes: ({})
  // Unsaved geometry from the geometry editor, shown live on the buddies: { packId, hitBox, feetY, facing, scale }
  property var geometryPreview: null
  property string packMessage: ""
  property bool packMessageError: false
  property string busyPack: ""
  // packId -> { builtAt, names }: animations whose frames changed in the latest rebuild,
  // so the buddy can show what you just saved
  property var packChanges: ({})

  readonly property var emptyRuntime: makeRuntime("")

  function buddyPackId(buddyId) {
    var chosen = (uiState.buddies || {})[buddyId]
    if (chosen && packIndex[chosen]) return chosen
    var buddy = (config.buddies || []).filter(function(p) { return p.id === buddyId })[0]
    if (buddy && buddy.pack && packIndex[buddy.pack]) return buddy.pack
    if (packIndex["default"]) return "default"
    return packList.length ? packList[0].id : ""
  }

  function packNames(entry) {
    return entry ? Object.keys(entry.animations || {}) : []
  }

  function packJsonOf(packId) {
    var e = packIndex[packId]
    return e ? (e.pack || {}) : {}
  }

  // Role mapping, geometry and status of one pack, for the buddies and the bar widget.
  // `saved` = ignore the geometry editor's unsaved preview.
  function packView(packId, saved) {
    var e = packIndex[packId]
    if (!e) return null
    var names = packNames(e)
    var pj = e.pack || {}
    var resolved = Packs.resolveRoles(pj, names)
    var idleName = resolved.roles.idle.length ? resolved.roles.idle[0] : names[0]
    var geo = Packs.resolveGeometry(pj, { canvas: e.canvas, animations: e.animations }, config.sprite, idleName)
    var gp = geometryPreview
    if (!saved && gp && gp.packId === packId) {
      geo = Object.assign({}, geo, {
        hitBox: gp.hitBox || geo.hitBox,
        feetY: gp.feetY > 0 ? gp.feetY : geo.feetY,
        facing: gp.facing || geo.facing,
        scale: gp.scale > 0 ? gp.scale : geo.scale
      })
    }
    return { id: packId, entry: e, pack: pj, names: names, resolved: resolved, idleName: idleName || "", geometry: geo }
  }

  function animUrl(packId, name) {
    var e = packIndex[packId]
    if (!e || !name) return ""
    // The manifest names each file; builds before it had one replaced "/" with "_"
    var a = (e.animations || {})[name]
    var file = a && a.file ? a.file : String(name).replace(/\//g, "_") + ".webp"
    // Every build has its own folder (webpDir): Qt would keep old frames for a reused path
    return "file://" + cacheDir + "/packs/" + encodeURIComponent(packId) + "/" + (e.webpDir || "webp") + "/"
      + encodeURIComponent(file)
  }

  function makeRuntime(packId, buddy) {
    var sp = config.sprite || {}
    var view = packId ? packView(packId) : null
    var base = config.animations || {}
    var roles = view ? view.resolved.roles : Packs.resolveRoles({}, []).roles
    var beh = view ? (view.pack.behavior || {}) : {}
    var geo = view ? view.geometry : Packs.resolveGeometry({}, null, sp, "")
    var durations = {}
    if (view) view.names.forEach(function(n) { durations[n] = Number(view.entry.animations[n].ms) || 0 })
    var playSec = Object.assign({}, sp.playSec || {}, beh.playSec || {})
    var minPlay = Number((view && view.pack.minPlaySec) || sp.minPlaySec) || 0
    var size = geo.scale > 0 ? geo.width * geo.scale : (Number(buddy && buddy.size) || geo.width * 3)
    return {
      packId: packId,
      version: view ? (view.entry.builtAt || 0) : 0,
      anims: Packs.buildAnimations(base, roles, beh),
      weights: Packs.buildWeights(config.animationWeights, roles),
      durations: durations,
      fps: Number(sp.fps) || 10,
      canvasW: geo.width,
      canvasH: geo.height,
      // Hitbox recentred on the box; offsetX is how far the drawing shifts to match (Buddy.qml stage)
      offsetX: 0.5 - (geo.hitBox[0] + geo.hitBox[2]) / 2 / geo.width,
      hitBox: {
        x0: geo.hitBox[0] / geo.width + 0.5 - (geo.hitBox[0] + geo.hitBox[2]) / 2 / geo.width,
        y0: geo.hitBox[1] / geo.height,
        x1: geo.hitBox[2] / geo.width + 0.5 - (geo.hitBox[0] + geo.hitBox[2]) / 2 / geo.width,
        y1: geo.hitBox[3] / geo.height
      },
      feet: geo.feetY / geo.height,
      facing: geo.facing,
      size: Math.round(size),
      sprite: { playSec: playSec, minPlaySec: minPlay },
      urlFor: function(name) { return root.animUrl(packId, name) }
    }
  }

  function rebuildRuntimes() {
    var next = {}
    var all = config.buddies || []
    for (var i = 0; i < all.length; i++) next[all[i].id] = makeRuntime(buddyPackId(all[i].id), all[i])
    runtimes = next
    refreshNotifyIcons()
  }

  onGeometryPreviewChanged: rebuildRuntimes()

  function applyIndex(text) {
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      return
    }
    var map = {}
    var list = (data.packs || []).map(function(p) {
      var old = root.packIndex[p.id]
      return old && root.savePending(p.id) ? Object.assign({}, p, { pack: old.pack, name: old.name, author: old.author }) : p
    })
    list.forEach(function(p) { map[p.id] = p })
    // Default first, then by name
    list.sort(function(a, b) {
      if (a.id === "default") return -1
      if (b.id === "default") return 1
      return String(a.name).localeCompare(String(b.name))
    })
    var changes = Object.assign({}, packChanges)
    list.forEach(function(p) {
      var old = root.packIndex[p.id]
      if (!old || !old.builtAt || !p.builtAt || old.builtAt === p.builtAt) return
      var was = old.animations || {}
      changes[p.id] = { builtAt: p.builtAt, names: Object.keys(p.animations || {}).filter(function(n) {
        // New animations count; without an old fingerprint there's nothing to compare
        return !was[n] || (!!was[n].hash && was[n].hash !== p.animations[n].hash)
      }) }
    })
    packChanges = changes
    var busy = list.filter(function(p) { return p.status === "building" })[0]
    busyPack = busy ? busy.id : (packTask.running ? busyPack : "")
    packIndex = map
    packList = list
    rebuildRuntimes()
  }

  FileView {
    id: indexFile
    path: root.cacheDir + "/index.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyIndex(text())
  }

  // The watcher logs a line per build; reread the index then too, since a file replaced by
  // rename isn't always reported by the file watch.
  Timer {
    id: indexReload
    interval: 150
    onTriggered: indexFile.reload()
  }

  Process {
    id: packWatcher
    command: [root.packTool, "watch"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        console.log("[pixel-buddy] packs: " + line)
        indexReload.restart()
      }
    }
    stderr: SplitParser {
      onRead: function(line) { console.warn("[pixel-buddy] packs: " + line) }
    }
    onExited: function(exitCode) {
      console.warn("[pixel-buddy] pack watcher exited (" + exitCode + "), restarting")
      watcherRestart.restart()
    }
  }

  Timer {
    id: watcherRestart
    interval: 5000
    onTriggered: packWatcher.running = true
  }

  FileView {
    id: uiFile
    path: root.uiStatePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var s = JSON.parse(text())
        root.uiState = s && typeof s === "object" ? Object.assign({ buddies: {} }, s) : { buddies: {} }
      } catch (e) {
        root.uiState = { buddies: {} }
      }
      root.rebuildRuntimes()
    }
  }

  // `pending` = the pack was just created and may not be in the index yet
  function setBuddyPack(buddyId, packId, pending) {
    if (!packIndex[packId] && !pending) return "no-pack"
    var buddies = Object.assign({}, uiState.buddies || {})
    buddies[buddyId] = packId
    uiState = Object.assign({}, uiState, { buddies: buddies })
    uiFile.setText(JSON.stringify(uiState, null, 2) + "\n")
    rebuildRuntimes()
    return "ok"
  }

  // Edits from the bar widget apply at once in memory and reach pack.json shortly after,
  // so dragging a slider doesn't spawn a write per pixel.
  property var pendingSaves: ({})

  function savePack(packId, packJson) {
    var e = packIndex[packId]
    if (!e) return
    var map = Object.assign({}, packIndex)
    map[packId] = Object.assign({}, e, { pack: packJson, name: packJson.name || packId, author: packJson.author || "" })
    packIndex = map
    packList = packList.map(function(p) { return p.id === packId ? map[packId] : p })
    var saves = Object.assign({}, pendingSaves)
    saves[packId] = true
    pendingSaves = saves
    saveTimer.restart()
    rebuildRuntimes()
  }

  function updatePack(packId, fn) {
    var pj = JSON.parse(JSON.stringify(packJsonOf(packId)))
    fn(pj)
    savePack(packId, pj)
  }

  function setRole(packId, key, names) {
    updatePack(packId, function(pj) { pj.roles = Packs.setRole(pj.roles, key, names) })
  }

  function resetRoles(packId) {
    updatePack(packId, function(pj) { delete pj.roles })
  }

  Timer {
    id: saveTimer
    interval: 400
    onTriggered: root.flushSaves()
  }

  function flushSaves() {
    var ids = Object.keys(pendingSaves)
    if (!ids.length) return
    if (saveProc.running) {
      saveTimer.restart()
      return
    }
    var id = ids[0]
    var rest = Object.assign({}, pendingSaves)
    delete rest[id]
    pendingSaves = rest
    saveProc.packId = id
    saveProc.command = [packTool, "save", id, JSON.stringify(packJsonOf(id))]
    saveProc.running = true
  }

  // True while an edit of this pack hasn't reached pack.json yet; index reloads keep the in-memory copy.
  function savePending(packId) {
    return !!pendingSaves[packId] || (saveProc.running && saveProc.packId === packId)
  }

  Process {
    id: saveProc
    property string packId: ""
    stderr: StdioCollector { id: saveErr }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.showPackMessage(saveErr.text.trim() || "Could not save pack.json", true)
      saveProc.packId = ""
      if (Object.keys(root.pendingSaves).length) saveTimer.restart()
      else indexFile.reload()
    }
  }

  // One pack command at a time (build, new, duplicate, delete, open in Aseprite).
  property var packTaskDone: null

  function runPackTask(args, packId, done) {
    if (packTask.running) {
      showPackMessage("Still working on the last action…", false)
      return false
    }
    busyPack = packId || ""
    packTaskDone = done || null
    packTask.command = [packTool].concat(args)
    packTask.running = true
    return true
  }

  Process {
    id: packTask
    stdout: StdioCollector { id: packTaskOut }
    stderr: StdioCollector { id: packTaskErr }
    onExited: function(exitCode) {
      var done = root.packTaskDone
      root.packTaskDone = null
      root.busyPack = ""
      indexFile.reload()
      if (exitCode !== 0) root.showPackMessage(packTaskErr.text.trim().replace(/^pixel-buddy-pack: /, "") || "Command failed", true)
      if (done) done(exitCode, packTaskOut.text.trim())
    }
  }

  function showPackMessage(text, isError) {
    packMessage = text
    packMessageError = isError === true
    packMessageTimer.restart()
  }

  Timer {
    id: packMessageTimer
    interval: 6000
    onTriggered: root.packMessage = ""
  }

  function rebuildPack(packId) {
    return runPackTask(["build", packId, "--force"], packId, function(code) {
      if (code === 0) root.showPackMessage("Rebuilt " + (root.packIndex[packId] || {}).name, false)
    })
  }

  function newPack(name, done) {
    return runPackTask(["new", name], "", function(code, out) {
      var id = out.split("\n").pop()
      if (code !== 0 || !id) return
      root.openInAseprite(id)
      if (done) done(id)
    })
  }

  function duplicatePack(packId, name, done) {
    return runPackTask(["duplicate", packId, name], packId, function(code, out) {
      var id = out.split("\n").pop()
      if (code === 0 && id && done) done(id)
    })
  }

  function deletePack(packId, done) {
    return runPackTask(["delete", packId], packId, function(code) {
      if (code === 0) root.showPackMessage("Moved to ~/.local/share/pixel-buddy/trash", false)
      if (code === 0 && done) done()
    })
  }

  function openInAseprite(packId) {
    asepriteProc.command = [packTool, "aseprite", packId]
    asepriteProc.running = true
  }

  Process {
    id: asepriteProc
    stderr: StdioCollector { id: asepriteErr }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.showPackMessage(asepriteErr.text.trim().replace(/^pixel-buddy-pack: /, ""), true)
    }
  }

  function openPackFolder(packId) {
    var e = packIndex[packId]
    Quickshell.execDetached(["xdg-open", e ? e.dir : root.pluginDir + "/packs"])
  }

  // Notification icons come from the first buddy's pack: first frames of its waiting / success / error
  // animations, cut by pixel-buddy-pack whenever that mapping or the build changes.
  property string notifyPack: ""
  property string notifyIconsKey: ""

  function refreshNotifyIcons() {
    var first = (config.buddies || [])[0]
    var rt = first ? runtimes[first.id] : null
    if (!rt || !rt.packId) return
    var ws = rt.anims.events.workStatus
    var pickOne = function(slot) { return Array.isArray(slot) ? slot[0] : slot }
    var key = [rt.packId, rt.version, pickOne(ws[3]), pickOne(ws[4]), pickOne(ws[5])].join("|")
    notifyPack = rt.packId
    if (key === notifyIconsKey) return
    notifyIconsKey = key
    Quickshell.execDetached([packTool, "icons", rt.packId, pickOne(ws[3]) || "", pickOne(ws[4]) || "", pickOne(ws[5]) || ""])
  }

  // Geometry editor: a window of its own, opened from the bar widget, so it outlives the popup.
  property string geometryPackId: ""

  function openGeometryEditor(packId) {
    geometryPreview = null
    geometryPackId = packId
  }

  function closeGeometryEditor(save) {
    var gp = geometryPreview
    var id = geometryPackId
    geometryPackId = ""
    if (save && gp && gp.packId === id) {
      updatePack(id, function(pj) {
        if (gp.hitBox) pj.hitBox = gp.hitBox.map(Math.round)
        if (gp.feetY > 0) pj.feetY = Math.round(gp.feetY)
      })
    }
    geometryPreview = null
  }

  LazyLoader {
    active: root.geometryPackId !== ""
    GeometryEditor {
      service: root
      packId: root.geometryPackId
    }
  }

  FileView {
    id: userFile
    path: root.userConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.userFileSeen = true
      if (defaultFile.loaded) root.rebuildConfig()
    }
    // Rebuild only on first load or when a file that existed is deleted; "doesn't exist yet" while polling doesn't rebuild (rebuildConfig restarts every timer)
    onLoadFailed: if (defaultFile.loaded && (root.userFileSeen || !root.ready)) {
      root.userFileSeen = false
      root.rebuildConfig()
    }
  }

  // File watching only covers files that already exist: a config.jsonc created after the shell started is found by polling
  property bool userFileSeen: false
  Timer {
    interval: 5000
    repeat: true
    running: !root.userFileSeen
    onTriggered: userFile.reload()
  }

  // ------------------------------------------------------------ Buddy signals
  // Empty buddyId = all buddies
  signal speak(string buddyId, string text, string meme, string kind)
  signal playRequest(string buddyId, string name)
  signal usageShow(var summary)

  // ------------------------------------------------------------ Work status
  property var wsStore: WS.createStore()
  // Snapshot of the session being shown (a new object reference = buddies switch levels); null = no active session
  property var workStatus: null
  property string lastAgent: "claude"

  function agentEnabled(agent) {
    var a = config.agents || {}
    return a[agent] !== false
  }

  // The hook writes events into runtimeDir/events.sock through socat, one JSON per line (event contents never go in process arguments)
  EventServer {
    id: eventServer
    path: root.runtimeDir + "/events.sock"
    onReceived: line => root.handleEvent(line)
  }

  function handleEvent(json) {
    var ev
    try {
      ev = JSON.parse(json)
    } catch (e) {
      return "bad-json"
    }
    if (!ev || !ev.event) return "bad-event"
    if (!agentEnabled(ev.agent)) return "ignored"
    if (ev.agent === "claude" || ev.agent === "codex") lastAgent = ev.agent
    var res = WS.applyEvent(wsStore, ev, Date.now())
    if (res.entered) notifyFor(res.entry)
    if (res.changed) refreshWorkStatus()
    var mode = summaryMode()
    if (mode === "model") {
      // When a new turn has no summary yet, summarize once a few seconds after the first step instead of waiting the full intervalSec
      if (res.entry && res.entry.steps.length && !res.entry.summary && !summaryKick.running) summaryKick.restart()
    } else if (mode === "transcript" && res.entry) {
      if (ev.event === "Stop" && ev.lastMessage) {
        // Stop carries the last reply, so no need to read the file
        if (WS.setSummary(wsStore, res.entry.key, WS.formatNarration(ev.lastMessage))) refreshWorkStatus()
      } else if (ev.event === "PreToolUse" || ev.event === "Stop") {
        narrationKey = res.entry.key
        narrationDelay.restart()
      }
    }
    return "ok"
  }

  function refreshWorkStatus() {
    var cur = WS.current(wsStore)
    var prev = workStatus
    if (!cur) {
      if (prev) workStatus = null
      return
    }
    // Any change of level, tool, command or summary sends a new snapshot; buddies switch animations only on session / level changes and otherwise just refresh the bubble
    if (prev && prev.key === cur.key && prev.state === cur.state && prev.tool === cur.tool
      && prev.detail === cur.detail && prev.summary === cur.summary) return
    workStatus = Object.assign({}, cur)
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: if (WS.prune(root.wsStore, Date.now())) root.refreshWorkStatus()
  }

  // ------------------------------------------------------------ System notifications
  readonly property var notifyTitleKeys: ({ waiting: "notifyWaiting", success: "notifySuccess", error: "notifyError" })
  readonly property var notifyIcons: ({ waiting: "approval", success: "done", error: "error" })
  // Notifications carry only fixed text like the agent name and status. Omarchy's notification service puts the title and body it receives
  // into bash process arguments and writes them to disk, so however they're sent, project names and messages must never go into notifications.
  function notifyFor(entry) {
    if (config.notificationsEnabled === false) return
    var titleKey = notifyTitleKeys[entry.state]
    if (!titleKey) return
    var onlyUnfocused = !config.notify || config.notify.onlyWhenUnfocused !== false
    if (onlyUnfocused && entry.focused) return
    var agentName = entry.agent === "codex" ? "Codex" : "Claude Code"
    Quickshell.execDetached(["notify-send", "-a", "pixel-buddy",
      "-i", (root.notifyPack ? root.cacheDir + "/packs/" + root.notifyPack + "/pic" : root.pluginDir + "/assets/pic")
        + "/notify-" + notifyIcons[entry.state] + ".png",
      agentName + " · " + tr(titleKey)])
  }

  // ------------------------------------------------------------ Usage
  // Data sources:
  //   omarchy = records from the omarchy.agents plugin (generated by omarchy-agent-usage-update), used directly on Omarchy
  //   builtin = collected by bin/pixel-buddy-usage itself, ported from omarchy agents' collection scripts, for non-Omarchy setups
  // usage.source can force one; the default auto = use omarchy when omarchy-agent-usage-update is found
  property string omarchyCollector: ""
  property bool usageSourceChecked: false
  readonly property string usageSource: {
    var s = (config.usage || {}).source
    if (s === "omarchy" || s === "builtin") return s
    return omarchyCollector ? "omarchy" : "builtin"
  }
  readonly property string usageDir: !usageSourceChecked ? ""
    : usageSource === "omarchy" ? home + "/.local/state/omarchy/agents/usage" : stateDir + "/usage"
  // Raw records: countdowns are computed at display time, so they stay accurate when shown a while after reading
  property var usageRecords: ({})
  property var usageTiers: ({})
  property bool usageShowPending: false
  property bool usageShowManual: false

  Process {
    running: true
    command: ["bash", "-c", "command -v omarchy-agent-usage-update || { [ -x \"$OMARCHY_PATH/bin/omarchy-agent-usage-update\" ] && echo \"$OMARCHY_PATH/bin/omarchy-agent-usage-update\"; } || true"]
    stdout: StdioCollector { id: collectorOut }
    onExited: {
      root.omarchyCollector = collectorOut.text.trim()
      root.usageSourceChecked = true
      console.log("[pixel-buddy] usage source: " + root.usageSource + (root.usageSource === "omarchy" ? " (" + root.omarchyCollector + ")" : ""))
    }
  }

  function usageAgent() {
    var u = config.usage || {}
    return u.agent && u.agent !== "auto" ? u.agent : lastAgent
  }

  function enabledUsageAgents() {
    return ["claude", "codex"].filter(function(a) { return agentEnabled(a) })
  }

  function usageAgeMs(agent) {
    var rec = usageRecords[agent]
    var t = rec ? Date.parse(rec.updatedAt) : NaN
    return isFinite(t) ? Date.now() - t : Infinity
  }

  function updateUsage(agent, text) {
    var rec = null
    try {
      rec = JSON.parse(text)
    } catch (e) {}
    var next = Object.assign({}, usageRecords)
    next[agent] = rec
    usageRecords = next
    var summary = rec ? Usage.summarize(rec, Date.now()) : null
    var prevTier = usageTiers[agent]
    var tiers = Object.assign({}, usageTiers)
    tiers[agent] = summary ? summary.tier : -1
    usageTiers = tiers
    // Don't play on the first read; after that, play once when the level changes (a pending manual check shows itself, so it isn't repeated here)
    if (summary && prevTier !== undefined && prevTier !== summary.tier && agent === usageAgent() && !usageShowPending)
      usageShow(summary)
  }

  // Refresh before showing: re-collect if the record is more than 60 seconds old (manual = the user asked; shows "refreshing" meanwhile)
  function showUsage(manual) {
    var agent = usageAgent()
    if (!usageRecords[agent] && usageRecords[agent === "claude" ? "codex" : "claude"]) agent = agent === "claude" ? "codex" : "claude"
    if (usageAgeMs(agent) > 60000 && usageSourceChecked) {
      if (manual) speak("", tr("usageRefreshing"), "", "info")
      usageShowManual = usageShowManual || manual
      refreshUsage([agent], true)
      return
    }
    displayUsage(manual)
  }

  function displayUsage(manual) {
    var agent = usageAgent()
    var rec = usageRecords[agent] || usageRecords[agent === "claude" ? "codex" : "claude"]
    var summary = rec ? Usage.summarize(rec, Date.now()) : null
    if (summary) usageShow(summary)
    else if (manual) speak("", tr(usageSource === "omarchy" ? "usageNoDataOmarchy" : "usageNoDataBuiltin"), "", "info")
  }

  function refreshUsage(agents, showAfter) {
    if (showAfter) usageShowPending = true
    if (usageProc.running || !usageSourceChecked || !agents.length) return
    var cmd = usageSource === "omarchy"
      ? [omarchyCollector || "omarchy-agent-usage-update", "--limits-only"]
      : [root.pluginDir + "/bin/pixel-buddy-usage"]
    usageProc.command = cmd.concat(agents)
    usageProc.running = true
    usageRefreshTimeout.restart()
  }

  Process {
    id: usageProc
    onExited: {
      usageRefreshTimeout.stop()
      claudeUsageFile.reload()
      codexUsageFile.reload()
      if (root.usageShowPending) usageShowDelay.restart()
    }
  }

  Timer {
    id: usageRefreshTimeout
    interval: 20000
    onTriggered: if (usageProc.running) usageProc.signal(15)
  }

  // Show once the file has been re-read; if the refresh fails, show the old data (the bubble notes how old it is)
  Timer {
    id: usageShowDelay
    interval: 400
    onTriggered: {
      var manual = root.usageShowManual
      root.usageShowPending = false
      root.usageShowManual = false
      root.displayUsage(manual)
    }
  }

  FileView {
    id: claudeUsageFile
    path: root.usageDir ? root.usageDir + "/claude.json" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.updateUsage("claude", text())
  }

  FileView {
    id: codexUsageFile
    path: root.usageDir ? root.usageDir + "/codex.json" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.updateUsage("codex", text())
  }

  // Timed display (usage animation interval)
  Timer {
    id: usageTimer
    interval: Math.max(60, Number((root.config.eventsRefreshSec || {}).balance) || 1800) * 1000
    running: root.ready
    repeat: true
    onTriggered: root.showUsage(false)
  }

  // Keep fresh in the background: re-collect when the record is older than usage.refreshSec (on Omarchy the agents widget usually refreshes already, so this rarely fires)
  Timer {
    interval: Math.max(60, Number((root.config.usage || {}).refreshSec) || 900) * 1000
    running: root.ready && root.usageSourceChecked
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      var limit = interval
      var stale = root.enabledUsageAgents().filter(function(a) { return root.usageAgeMs(a) > limit })
      if (stale.length) root.refreshUsage(stale, false)
    }
  }

  // ------------------------------------------------------------ Murmurs / chat (the LLM is only called when explicitly triggered or with whisperAuto on)
  Llm {
    id: llm
    name: "chat"
    home: root.home
    stateDir: root.stateDir
    onFinished: function(buddyId, kind, text, meme, failed) {
      if (failed) {
        root.speak(buddyId, text, "", "error")
        return
      }
      if (kind === "chat") root.rememberChat(buddyId, llm.lastUserText, text)
      root.speak(buddyId, text, root.knownMeme(meme), kind)
    }
  }

  readonly property bool llmBusy: llm.busy

  // For automatic tasks only (step summaries, timed murmurs): a separate instance that doesn't compete with manual chat; uses the cheap model set in autoModel
  Llm {
    id: autoLlm
    name: "auto"
    home: root.home
    stateDir: root.stateDir
    onFinished: function(buddyId, kind, text, meme, failed) {
      if (kind === "summary") {
        if (failed) {
          console.warn("[pixel-buddy] step summary failed:", text)
          return
        }
        if (WS.setSummary(root.wsStore, autoLlm.tag, text.replace(/\s+/g, " ").slice(0, 30))) root.refreshWorkStatus()
        return
      }
      if (failed) console.warn("[pixel-buddy] timed murmur failed:", text)
      else root.speak(buddyId, text, meme, kind)
    }
  }

  function autoModelFor() {
    var a = config.autoModel || {}
    var provider = a.provider === "codex" ? "codex" : "claude"
    return { provider: provider, model: (provider === "codex" ? a.codexModel : a.claudeModel) || "" }
  }

  // ------------------------------------------------------------ Step summaries (stepSummary.enabled, off by default)
  readonly property var stepSummaryCfg: config.stepSummary || ({})

  // off / transcript (reads what the agent itself wrote in the transcript) / model (summarized by autoModel); the old form enabled: true counts as model
  function summaryMode() {
    var c = stepSummaryCfg
    if (c.mode === "off" || c.mode === "transcript" || c.mode === "model") return c.mode
    return c.enabled === true ? "model" : "off"
  }

  // ---- transcript mode: read the latest assistant text of this turn from the end of the transcript
  property string narrationKey: ""
  property bool narrationPending: false

  function readNarration() {
    var entry = wsStore.sessions[narrationKey]
    if (!entry || !entry.transcript) return
    if (narrationProc.running) {
      narrationPending = true
      return
    }
    narrationProc.key = entry.key
    // The transcript path contains the project path and session ID, so it goes in an env var (readable only by this user), never in process arguments
    narrationProc.environment = ({
      PIXEL_BUDDY_TRANSCRIPT: entry.transcript,
      PIXEL_BUDDY_SINCE: new Date(entry.turnAt - 2000).toISOString()
    })
    narrationProc.command = [root.pluginDir + "/bin/pixel-buddy-last-message"]
    narrationProc.running = true
  }

  // The hook sometimes arrives slightly before the transcript is written: wait a moment before reading
  Timer {
    id: narrationDelay
    interval: 500
    onTriggered: root.readNarration()
  }

  Process {
    id: narrationProc
    property string key: ""
    stdout: StdioCollector { id: narrationOut }
    onExited: function(exitCode) {
      var text = WS.formatNarration(narrationOut.text)
      // If nothing was read (not written yet / nothing said this turn), keep the previous text instead of clearing it
      if (exitCode === 0 && text && WS.setSummary(root.wsStore, narrationProc.key, text)) root.refreshWorkStatus()
      if (root.narrationPending) {
        root.narrationPending = false
        root.readNarration()
      }
    }
  }
  property var summarizedSeq: ({})

  function summarizeCurrentStep() {
    var cur = WS.current(wsStore)
    if (!cur || WS.isTerminal(cur.state) || !cur.steps.length) return
    if (summarizedSeq[cur.key] === cur.stepSeq || autoLlm.busy) return
    var seen = Object.assign({}, summarizedSeq)
    seen[cur.key] = cur.stepSeq
    summarizedSeq = seen
    var system = tr("summarySystem")
    var prompt = tr("summaryRequest", { prompt: cur.prompt || tr("summaryUnknown") }) + "\n" + tr("summarySteps") + "\n"
      + cur.steps.map(function(st, i) { return (i + 1) + ". " + WS.formatDetail(st.tool, st.detail, cur.cwd, 100) }).join("\n")
    var m = autoModelFor()
    autoLlm.tag = cur.key
    autoLlm.run(m.provider, m.model, system, prompt, "", "summary", "", true)
  }

  Timer {
    id: summaryKick
    interval: 8000
    onTriggered: root.summarizeCurrentStep()
  }

  Timer {
    interval: Math.max(20, Number(root.stepSummaryCfg.intervalSec) || 60) * 1000
    running: root.ready && root.summaryMode() === "model"
    repeat: true
    triggeredOnStart: true
    onTriggered: root.summarizeCurrentStep()
  }

  function buddyById(buddyId) {
    for (var i = 0; i < buddies.length; i++) if (buddies[i].id === buddyId) return buddies[i]
    return buddies.length ? buddies[0] : null
  }

  function memeNames() {
    return Object.keys(config.memes || {})
  }

  // Meme names in chat replies come from the model and get joined into image paths: accept only names in the config
  function knownMeme(name) {
    var memes = config.memes || {}
    return name && Object.prototype.hasOwnProperty.call(memes, name) ? name : ""
  }

  function persona(buddy) {
    return (config.whisperPrompt || "") + " " + tr("personaName", { name: buddy.name || buddy.id })
  }

  function llmModel() {
    var l = config.llm || {}
    return (l.provider === "codex" ? l.codexModel : l.claudeModel) || ""
  }

  function requestWhisper(buddyId, auto) {
    var buddy = buddyById(buddyId)
    if (!buddy) return "no-buddy"
    var runner = auto ? autoLlm : llm
    if (runner.busy) return "busy"
    var meme = ""
    var names = memeNames()
    if (config.whisperImageEnabled !== false && names.length) meme = names[Math.floor(Math.random() * names.length)]
    var now = new Date()
    var prompt = tr("whisperNow", { time: Qt.formatTime(now, "HH:mm") })
    if (meme) prompt += " " + tr("whisperMeme", { desc: config.memes[meme] })
    prompt += " " + tr("whisperOutput")
    if (auto) {
      var m = autoModelFor()
      autoLlm.run(m.provider, m.model, persona(buddy), prompt, buddy.id, "whisper", meme, true)
    } else {
      llm.run((config.llm || {}).provider, llmModel(), persona(buddy), prompt, buddy.id, "whisper", meme, false)
    }
    return "ok"
  }

  function requestChat(buddyId, text) {
    var buddy = buddyById(buddyId)
    if (!buddy || !text) return "no-buddy"
    if (llm.busy) return "busy"
    var system = persona(buddy) + " " + tr("chatIntro")
    var useMemes = config.chatImageEnabled !== false && memeNames().length > 0
    if (useMemes) {
      var limit = Number(config.chatImageLimit)
      var names = memeNames()
      if (limit > 0) names = names.slice(0, limit)
      system += " " + tr("chatJson") + " "
        + tr("chatMemes", { list: names.map(function(n) { return n + ": " + config.memes[n] }).join("; ") })
    } else {
      system += " " + tr("chatPlain")
    }
    var rounds = Number(config.chatMemoryRounds)
    if (!(rounds >= 0)) rounds = 5
    var history = chatHistory(buddy.id).slice(-rounds)
    var prompt = history.map(function(h) { return tr("chatOwner") + h.q + "\n" + tr("chatYou") + h.a }).join("\n")
    prompt += (prompt ? "\n" : "") + tr("chatOwner") + text
    llm.lastUserText = text
    llm.run((config.llm || {}).provider, llmModel(), system, prompt, buddy.id, "chat", "", false)
    return "ok"
  }

  Timer {
    id: whisperTimer
    interval: Math.max(60, Number((root.config.eventsRefreshSec || {}).whisper) || 300) * 1000
    running: root.ready && root.config.whisperAuto === true
    repeat: true
    onTriggered: {
      // Don't interrupt while an agent is working, and don't compete with it for quota
      if (WS.anyBusy(root.wsStore)) return
      for (var i = 0; i < root.buddies.length; i++) {
        if (root.buddies[i].whisperEnabled !== false) {
          root.requestWhisper(root.buddies[i].id, true)
          return
        }
      }
    }
  }

  // Chat memory: { buddyId: [{ q, a, t }] }, saved in full; each request uses only the last chatMemoryRounds rounds
  property var memory: ({})

  function chatHistory(buddyId) {
    return memory[buddyId] || []
  }

  function rememberChat(buddyId, q, a) {
    var next = Object.assign({}, memory)
    next[buddyId] = chatHistory(buddyId).concat([{ q: q, a: a, t: Date.now() }])
    memory = next
    memoryFile.setText(JSON.stringify(next, null, 2))
  }

  FileView {
    id: memoryFile
    path: root.stateDir + "/memory.json"
    printErrors: false
    onLoaded: {
      try {
        root.memory = JSON.parse(text()) || {}
      } catch (e) {
        root.memory = {}
      }
    }
  }

  // Chat memory, model prompt files and the event socket are only accessible to this user; listening starts once the directories exist
  Process {
    running: true
    command: ["bash", "-c", 'mkdir -p "$0"; mkdir -p -m 700 "$@"; chmod 700 "$@"', root.home + "/.config/pixel-buddy", root.stateDir, root.runtimeDir]
    onExited: function(exitCode) {
      if (exitCode === 0) eventServer.start()
      else console.warn("[pixel-buddy] couldn't create " + root.runtimeDir + ", hook events won't arrive")
    }
  }

  // ------------------------------------------------------------ IPC: omarchy-shell pixel-buddy <method> [arg]
  IpcHandler {
    target: "pixel-buddy"

    function say(text: string): string {
      root.speak("", text, "", "info")
      return "ok"
    }
    function play(name: string): string {
      root.playRequest("", name)
      return "ok"
    }
    function usage(): string {
      root.showUsage(true)
      return "ok"
    }
    function whisper(): string {
      return root.requestWhisper("", false)
    }
    function chat(text: string): string {
      return root.requestChat("", text)
    }
    function reload(): string {
      root.reloadConfig()
      return "ok"
    }
    // omarchy-shell pixel-buddy packs | usePack <pack> (all buddies) or <buddy>=<pack> | buildPack <pack> | editGeometry <pack>
    function packs(): string {
      return JSON.stringify(root.packList.map(function(p) {
        var v = root.packView(p.id)
        return { id: p.id, name: p.name, status: p.status, roles: v.resolved.mapped + "/" + v.resolved.total,
          buddies: (root.config.buddies || []).filter(function(buddy) { return root.buddyPackId(buddy.id) === p.id }).map(function(buddy) { return buddy.id }) }
      }))
    }
    function usePack(spec: string): string {
      var eq = spec.indexOf("=")
      var packId = eq >= 0 ? spec.slice(eq + 1) : spec
      var ids = eq >= 0 ? [spec.slice(0, eq)] : (root.config.buddies || []).map(function(p) { return p.id })
      var r = "ok"
      ids.forEach(function(id) { r = root.setBuddyPack(id, packId) })
      return r
    }
    function editGeometry(packId: string): string {
      if (!root.packIndex[packId]) return "no-pack"
      root.openGeometryEditor(packId)
      return "ok"
    }
    function buildPack(packId: string): string {
      return root.rebuildPack(packId) ? "ok" : "busy"
    }
    function toggle(): string {
      root.hidden = !root.hidden
      return root.hidden ? "hidden" : "shown"
    }
    function state(): string {
      return JSON.stringify({
        ready: root.ready,
        hidden: root.hidden,
        configError: root.configError,
        buddies: root.buddies.map(function(p) { return p.id }),
        workStatus: root.workStatus,
        sessions: root.wsStore.sessions,
        lastAgent: root.lastAgent,
        usageSource: root.usageSource,
        usage: Object.keys(root.usageRecords).reduce(function(o, a) {
          var r = root.usageRecords[a]
          o[a] = r ? { updatedAt: r.updatedAt, summary: Usage.summarize(r, Date.now()) } : null
          return o
        }, {}),
        llmBusy: llm.busy,
        autoBusy: autoLlm.busy,
        autoModel: root.autoModelFor(),
        stepSummary: root.summaryMode(),
        whisperAuto: root.config.whisperAuto === true
      })
    }
  }

  // ------------------------------------------------------------ One transparent overlay per screen
  function screenName(buddy) {
    var screens = Quickshell.screens
    if (buddy.screen) {
      for (var i = 0; i < screens.length; i++) if (screens[i].name === buddy.screen) return buddy.screen
    }
    return screens.length ? screens[0].name : ""
  }

  function buddiesForScreen(screen) {
    return buddies.filter(function(p) { return screenName(p) === screen.name })
  }

  Variants {
    model: root.ready ? Quickshell.screens.filter(function(s) { return root.buddiesForScreen(s).length > 0 }) : []

    BuddyOverlay {
      required property var modelData
      screen: modelData
      service: root
      buddies: root.buddiesForScreen(modelData)
    }
  }
}
