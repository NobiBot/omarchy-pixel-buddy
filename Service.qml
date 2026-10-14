import QtQuick
import Quickshell
import Quickshell.Io
import "lib/jsonc.mjs" as Jsonc
import "lib/work-status.mjs" as WS
import "lib/usage.mjs" as Usage
import "lib/i18n.mjs" as I18n
import "lib/packs.mjs" as Packs

// pixel-pet 的状态中枢：配置、精灵包、Claude Code / Codex 工作状态聚合、用量、LLM、通知、IPC。
// 每块有宠物的屏幕各一个 PetOverlay（全屏透明 layer-shell 窗口）。
Scope {
  id: root

  // 宿主注入
  property var shell: null
  property string omarchyPath: ""
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string userConfigPath: home + "/.config/pixel-pet/config.jsonc"
  readonly property string stateDir: home + "/.local/state/pixel-pet"
  // hook 事件 socket 所在目录（0700），与 bin/pixel-pet-hook 一致
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") + "/pixel-pet"

  // ------------------------------------------------------------ 配置
  property var config: ({})
  property bool ready: false
  property string configError: ""
  property bool hidden: false
  // 界面语言：language 设置（auto / zh / en），auto 从 LANGUAGE / LC_ALL / LC_MESSAGES / LANG 判断
  property string lang: "zh"

  function tr(key, params) {
    return I18n.t(lang, key, params)
  }

  readonly property var pets: (config.pets || []).filter(function(p) { return p.display !== "none" })

  function rebuildConfig() {
    var base
    try {
      base = JSON.parse(defaultFile.text())
    } catch (e) {
      console.warn("[pixel-pet] 内置配置解析失败:", e)
      return
    }
    var merged = Object.assign({}, base)
    var user = {}
    configError = ""
    var userText = userFile.loaded ? userFile.text() : ""
    if (userText.trim() !== "") {
      try {
        // 顶层整段替换（与 dsh-pet 同口径）：写了哪个字段就整段用用户的
        user = Jsonc.parseJsonc(userText) || {}
        Object.assign(merged, user)
      } catch (e) {
        configError = String(e)
        console.warn("[pixel-pet] 用户配置解析失败，使用内置配置:", e)
      }
    }
    lang = I18n.resolveLang(merged.language, {
      LANGUAGE: Quickshell.env("LANGUAGE") || "",
      LC_ALL: Quickshell.env("LC_ALL") || "",
      LC_MESSAGES: Quickshell.env("LC_MESSAGES") || "",
      LANG: Quickshell.env("LANG") || ""
    })
    // 内置文案是中文：英文界面下，用户没自定义的就换成英文版
    if (lang === "en") {
      if (!("workStatusTexts" in user)) merged.workStatusTexts = I18n.WORK_STATUS_TEXTS_EN
      if (!("whisperPrompt" in user)) merged.whisperPrompt = I18n.WHISPER_PROMPT_EN
    }
    config = merged
    rebuildRuntimes()
    ready = true
    // restart() 会冲掉 running 绑定，所以按开关显式启停，否则 whisperAuto=false 也会定时碎碎念
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
  // Sources live in packs/ (a symlink to ~/.local/share/pixel-pet/packs, so edits never trip
  // Omarchy's plugin reload). bin/pixel-pet-pack watch rebuilds a pack when its files change
  // and lists every pack in ~/.cache/pixel-pet/index.json. Each pet plays the pack the bar
  // widget picked for it (~/.config/pixel-pet/ui.json), else pets[].pack, else "default".
  readonly property string packTool: pluginDir + "/bin/pixel-pet-pack"
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/pixel-pet"
  readonly property string uiStatePath: home + "/.config/pixel-pet/ui.json"
  property var packIndex: ({})
  property var packList: []
  property var uiState: ({ pets: {} })
  // petId -> everything Pet.qml needs from its pack (see makeRuntime)
  property var runtimes: ({})
  // Unsaved geometry from the geometry editor, shown live on the pets: { packId, hitBox, feetY, facing, scale }
  property var geometryPreview: null
  property string packMessage: ""
  property bool packMessageError: false
  property string busyPack: ""
  // packId -> { builtAt, names }: animations whose frames changed in the latest rebuild,
  // so the pet can show what you just saved
  property var packChanges: ({})

  readonly property var emptyRuntime: makeRuntime("")

  function petPackId(petId) {
    var chosen = (uiState.pets || {})[petId]
    if (chosen && packIndex[chosen]) return chosen
    var pet = (config.pets || []).filter(function(p) { return p.id === petId })[0]
    if (pet && pet.pack && packIndex[pet.pack]) return pet.pack
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

  // Role mapping, geometry and status of one pack, for the pets and the bar widget.
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
    // Every build has its own folder (webpDir): Qt would keep old frames for a reused path
    return "file://" + cacheDir + "/packs/" + encodeURIComponent(packId) + "/" + (e.webpDir || "webp") + "/"
      + encodeURIComponent(String(name).replace(/\//g, "_")) + ".webp"
  }

  function makeRuntime(packId, pet) {
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
    var size = geo.scale > 0 ? geo.width * geo.scale : (Number(pet && pet.size) || geo.width * 3)
    return {
      packId: packId,
      version: view ? (view.entry.builtAt || 0) : 0,
      anims: Packs.buildAnimations(base, roles, beh),
      weights: Packs.buildWeights(config.animationWeights, roles),
      durations: durations,
      fps: Number(sp.fps) || 10,
      canvasW: geo.width,
      canvasH: geo.height,
      hitBox: { x0: geo.hitBox[0] / geo.width, y0: geo.hitBox[1] / geo.height, x1: geo.hitBox[2] / geo.width, y1: geo.hitBox[3] / geo.height },
      feet: geo.feetY / geo.height,
      facing: geo.facing,
      size: Math.round(size),
      sprite: { playSec: playSec, minPlaySec: minPlay },
      urlFor: function(name) { return root.animUrl(packId, name) }
    }
  }

  function rebuildRuntimes() {
    var next = {}
    var all = config.pets || []
    for (var i = 0; i < all.length; i++) next[all[i].id] = makeRuntime(petPackId(all[i].id), all[i])
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
        console.log("[pixel-pet] packs: " + line)
        indexReload.restart()
      }
    }
    stderr: SplitParser {
      onRead: function(line) { console.warn("[pixel-pet] packs: " + line) }
    }
    onExited: function(exitCode) {
      console.warn("[pixel-pet] pack watcher exited (" + exitCode + "), restarting")
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
        root.uiState = s && typeof s === "object" ? Object.assign({ pets: {} }, s) : { pets: {} }
      } catch (e) {
        root.uiState = { pets: {} }
      }
      root.rebuildRuntimes()
    }
  }

  // `pending` = the pack was just created and may not be in the index yet
  function setPetPack(petId, packId, pending) {
    if (!packIndex[packId] && !pending) return "no-pack"
    var pets = Object.assign({}, uiState.pets || {})
    pets[petId] = packId
    uiState = Object.assign({}, uiState, { pets: pets })
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
      if (exitCode !== 0) root.showPackMessage(packTaskErr.text.trim().replace(/^pixel-pet-pack: /, "") || "Command failed", true)
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
      if (code === 0) root.showPackMessage("Moved to ~/.local/share/pixel-pet/trash", false)
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
      if (exitCode !== 0) root.showPackMessage(asepriteErr.text.trim().replace(/^pixel-pet-pack: /, ""), true)
    }
  }

  function openPackFolder(packId) {
    var e = packIndex[packId]
    Quickshell.execDetached(["xdg-open", e ? e.dir : root.pluginDir + "/packs"])
  }

  // Notification icons come from the first pet's pack: first frames of its waiting / success / error
  // animations, cut by pixel-pet-pack whenever that mapping or the build changes.
  property string notifyPack: ""
  property string notifyIconsKey: ""

  function refreshNotifyIcons() {
    var first = (config.pets || [])[0]
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
    // 只在首次加载、或原本存在的文件被删掉时重建；轮询时的"还不存在"不重建（rebuildConfig 会重启各定时器）
    onLoadFailed: if (defaultFile.loaded && (root.userFileSeen || !root.ready)) {
      root.userFileSeen = false
      root.rebuildConfig()
    }
  }

  // 文件监听只盯已存在的文件：shell 启动后才新建的 config.jsonc 靠轮询发现
  property bool userFileSeen: false
  Timer {
    interval: 5000
    repeat: true
    running: !root.userFileSeen
    onTriggered: userFile.reload()
  }

  // ------------------------------------------------------------ 宠物对外信号
  // petId 为空 = 所有宠物
  signal speak(string petId, string text, string meme, string kind)
  signal playRequest(string petId, string name)
  signal usageShow(var summary)

  // ------------------------------------------------------------ 工作状态
  property var wsStore: WS.createStore()
  // 当前展示的会话快照（对象引用变化 = 宠物要切档位）；null = 没有活跃会话
  property var workStatus: null
  property string lastAgent: "claude"

  function agentEnabled(agent) {
    var a = config.agents || {}
    return a[agent] !== false
  }

  // hook 经 socat 把事件写进 runtimeDir/events.sock，每行一个 JSON（事件内容不进进程参数）
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
      // 新一轮还没有总结时，第一步出现后稍等几秒先总结一次，不必等满 intervalSec
      if (res.entry && res.entry.steps.length && !res.entry.summary && !summaryKick.running) summaryKick.restart()
    } else if (mode === "transcript" && res.entry) {
      if (ev.event === "Stop" && ev.lastMessage) {
        // Stop 自带最后一条回复，不用读文件
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
    // 档位、工具、命令或总结任一变化都发新快照；宠物只在会话 / 档位变化时切动画，其余只刷新气泡
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

  // ------------------------------------------------------------ 系统通知
  readonly property var notifyTitleKeys: ({ waiting: "notifyWaiting", success: "notifySuccess", error: "notifyError" })
  readonly property var notifyIcons: ({ waiting: "approval", success: "done", error: "error" })
  // 通知只发 agent 名称和状态等固定文字。Omarchy 的通知服务会把收到的标题和正文
  // 放进 bash 进程参数里落盘，所以无论怎么发，项目名和消息都不能进通知。
  function notifyFor(entry) {
    if (config.notificationsEnabled === false) return
    var titleKey = notifyTitleKeys[entry.state]
    if (!titleKey) return
    var onlyUnfocused = !config.notify || config.notify.onlyWhenUnfocused !== false
    if (onlyUnfocused && entry.focused) return
    var agentName = entry.agent === "codex" ? "Codex" : "Claude Code"
    Quickshell.execDetached(["notify-send", "-a", "pixel-pet",
      "-i", (root.notifyPack ? root.cacheDir + "/packs/" + root.notifyPack + "/pic" : root.pluginDir + "/assets/pic")
        + "/notify-" + notifyIcons[entry.state] + ".png",
      agentName + " · " + tr(titleKey)])
  }

  // ------------------------------------------------------------ 用量
  // 数据源：
  //   omarchy = omarchy.agents 插件的记录（由 omarchy-agent-usage-update 生成），Omarchy 上直接用
  //   builtin = bin/pixel-pet-usage 自己采集，行为移植自 omarchy agents 的采集脚本，供非 Omarchy 环境使用
  // usage.source 可强制指定；默认 auto = 能找到 omarchy-agent-usage-update 就用 omarchy
  property string omarchyCollector: ""
  property bool usageSourceChecked: false
  readonly property string usageSource: {
    var s = (config.usage || {}).source
    if (s === "omarchy" || s === "builtin") return s
    return omarchyCollector ? "omarchy" : "builtin"
  }
  readonly property string usageDir: !usageSourceChecked ? ""
    : usageSource === "omarchy" ? home + "/.local/state/omarchy/agents/usage" : stateDir + "/usage"
  // 原始记录：倒计时在显示时才计算，避免读取后过一阵再显示时倒计时不准
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
      console.log("[pixel-pet] 用量数据源: " + root.usageSource + (root.usageSource === "omarchy" ? " (" + root.omarchyCollector + ")" : ""))
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
    var summary = rec ? Usage.summarize(rec, Date.now(), lang) : null
    var prevTier = usageTiers[agent]
    var tiers = Object.assign({}, usageTiers)
    tiers[agent] = summary ? summary.tier : -1
    usageTiers = tiers
    // 首次读取不播；之后档位变化时播一次（等待中的手动查看会自己显示，这里不重复）
    if (summary && prevTier !== undefined && prevTier !== summary.tier && agent === usageAgent() && !usageShowPending)
      usageShow(summary)
  }

  // 先刷新再显示：记录超过 60 秒没更新就重新采集（manual = 用户主动查看，期间提示"正在刷新"）
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
    var summary = rec ? Usage.summarize(rec, Date.now(), lang) : null
    if (summary) usageShow(summary)
    else if (manual) speak("", tr(usageSource === "omarchy" ? "usageNoDataOmarchy" : "usageNoDataBuiltin"), "", "info")
  }

  function refreshUsage(agents, showAfter) {
    if (showAfter) usageShowPending = true
    if (usageProc.running || !usageSourceChecked || !agents.length) return
    var cmd = usageSource === "omarchy"
      ? [omarchyCollector || "omarchy-agent-usage-update", "--limits-only"]
      : [root.pluginDir + "/bin/pixel-pet-usage"]
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

  // 等文件重新读完再显示；刷新失败时显示旧数据（气泡会注明是多久前的）
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

  // 定时显示（余额动画周期）
  Timer {
    id: usageTimer
    interval: Math.max(60, Number((root.config.eventsRefreshSec || {}).balance) || 1800) * 1000
    running: root.ready
    repeat: true
    onTriggered: root.showUsage(false)
  }

  // 后台保鲜：记录比 usage.refreshSec 旧就重新采集（Omarchy 上 agents 组件通常已在刷新，这里基本不触发）
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

  // ------------------------------------------------------------ 碎碎念 / 对话（只在显式触发或 whisperAuto 开启时调用 LLM）
  Llm {
    id: llm
    name: "chat"
    lang: root.lang
    home: root.home
    stateDir: root.stateDir
    onFinished: function(petId, kind, text, meme, failed) {
      if (failed) {
        root.speak(petId, text, "", "error")
        return
      }
      if (kind === "chat") root.rememberChat(petId, llm.lastUserText, text)
      root.speak(petId, text, root.knownMeme(meme), kind)
    }
  }

  readonly property bool llmBusy: llm.busy

  // 自动任务（步骤总结、定时碎碎念）专用：独立实例，不和手动对话抢；用 autoModel 指定的便宜模型
  Llm {
    id: autoLlm
    name: "auto"
    lang: root.lang
    home: root.home
    stateDir: root.stateDir
    onFinished: function(petId, kind, text, meme, failed) {
      if (kind === "summary") {
        if (failed) {
          console.warn("[pixel-pet] 步骤总结失败:", text)
          return
        }
        if (WS.setSummary(root.wsStore, autoLlm.tag, text.replace(/\s+/g, " ").slice(0, 30))) root.refreshWorkStatus()
        return
      }
      if (failed) console.warn("[pixel-pet] 定时碎碎念失败:", text)
      else root.speak(petId, text, meme, kind)
    }
  }

  function autoModelFor() {
    var a = config.autoModel || {}
    var provider = a.provider === "codex" ? "codex" : "claude"
    return { provider: provider, model: (provider === "codex" ? a.codexModel : a.claudeModel) || "" }
  }

  // ------------------------------------------------------------ 步骤总结（stepSummary.enabled，默认关）
  readonly property var stepSummaryCfg: config.stepSummary || ({})

  // off / transcript（读会话记录里 agent 自己写的话）/ model（用 autoModel 总结）；旧写法 enabled: true 视为 model
  function summaryMode() {
    var c = stepSummaryCfg
    if (c.mode === "off" || c.mode === "transcript" || c.mode === "model") return c.mode
    return c.enabled === true ? "model" : "off"
  }

  // ---- transcript 模式：从会话记录末尾读本轮最新一段 assistant 文字
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
    // 会话记录路径含项目路径和会话 ID，走环境变量（只有本用户可读），不放进进程参数
    narrationProc.environment = ({
      PIXEL_PET_TRANSCRIPT: entry.transcript,
      PIXEL_PET_SINCE: new Date(entry.turnAt - 2000).toISOString()
    })
    narrationProc.command = [root.pluginDir + "/bin/pixel-pet-last-message"]
    narrationProc.running = true
  }

  // hook 有时比记录文件写入早一点：稍等再读
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
      // 没读到（记录还没写入 / 本轮还没说话）就保留上一段，不清空
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

  function petById(petId) {
    for (var i = 0; i < pets.length; i++) if (pets[i].id === petId) return pets[i]
    return pets.length ? pets[0] : null
  }

  function memeNames() {
    return Object.keys(config.memes || {})
  }

  // 对话回复里的表情包名由模型给出，而名字会拼进图片路径：只认配置里有的
  function knownMeme(name) {
    var memes = config.memes || {}
    return name && Object.prototype.hasOwnProperty.call(memes, name) ? name : ""
  }

  function persona(pet) {
    return (config.whisperPrompt || "") + (lang === "en" ? " " : "") + tr("personaName", { name: pet.name || pet.id })
  }

  function llmModel() {
    var l = config.llm || {}
    return (l.provider === "codex" ? l.codexModel : l.claudeModel) || ""
  }

  function requestWhisper(petId, auto) {
    var pet = petById(petId)
    if (!pet) return "no-pet"
    var runner = auto ? autoLlm : llm
    if (runner.busy) return "busy"
    var meme = ""
    var names = memeNames()
    if (config.whisperImageEnabled !== false && names.length) meme = names[Math.floor(Math.random() * names.length)]
    var now = new Date()
    var sep = lang === "en" ? " " : ""
    var prompt = tr("whisperNow", { time: Qt.formatTime(now, "HH:mm") })
    if (meme) prompt += sep + tr("whisperMeme", { desc: config.memes[meme] })
    prompt += sep + tr("whisperOutput")
    if (auto) {
      var m = autoModelFor()
      autoLlm.run(m.provider, m.model, persona(pet), prompt, pet.id, "whisper", meme, true)
    } else {
      llm.run((config.llm || {}).provider, llmModel(), persona(pet), prompt, pet.id, "whisper", meme, false)
    }
    return "ok"
  }

  function requestChat(petId, text) {
    var pet = petById(petId)
    if (!pet || !text) return "no-pet"
    if (llm.busy) return "busy"
    var sep = lang === "en" ? " " : ""
    var system = persona(pet) + sep + tr("chatIntro")
    var useMemes = config.chatImageEnabled !== false && memeNames().length > 0
    if (useMemes) {
      var limit = Number(config.chatImageLimit)
      var names = memeNames()
      if (limit > 0) names = names.slice(0, limit)
      system += sep + tr("chatJson") + sep
        + tr("chatMemes", { list: names.map(function(n) { return n + (lang === "en" ? ": " : "：") + config.memes[n] }).join(lang === "en" ? "; " : "；") })
    } else {
      system += sep + tr("chatPlain")
    }
    var rounds = Number(config.chatMemoryRounds)
    if (!(rounds >= 0)) rounds = 5
    var history = chatHistory(pet.id).slice(-rounds)
    var prompt = history.map(function(h) { return tr("chatOwner") + h.q + "\n" + tr("chatYou") + h.a }).join("\n")
    prompt += (prompt ? "\n" : "") + tr("chatOwner") + text
    llm.lastUserText = text
    llm.run((config.llm || {}).provider, llmModel(), system, prompt, pet.id, "chat", "", false)
    return "ok"
  }

  Timer {
    id: whisperTimer
    interval: Math.max(60, Number((root.config.eventsRefreshSec || {}).whisper) || 300) * 1000
    running: root.ready && root.config.whisperAuto === true
    repeat: true
    onTriggered: {
      // 有 agent 正在干活时不打扰，也不和它抢额度
      if (WS.anyBusy(root.wsStore)) return
      for (var i = 0; i < root.pets.length; i++) {
        if (root.pets[i].whisperEnabled !== false) {
          root.requestWhisper(root.pets[i].id, true)
          return
        }
      }
    }
  }

  // 对话记忆：{ petId: [{ q, a, t }] }，全量保存，每次请求只截最近 chatMemoryRounds 轮
  property var memory: ({})

  function chatHistory(petId) {
    return memory[petId] || []
  }

  function rememberChat(petId, q, a) {
    var next = Object.assign({}, memory)
    next[petId] = chatHistory(petId).concat([{ q: q, a: a, t: Date.now() }])
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

  // 对话记忆、模型提示词文件和事件 socket 只给本用户访问；目录建好后再开始监听
  Process {
    running: true
    command: ["bash", "-c", 'mkdir -p "$0"; mkdir -p -m 700 "$@"; chmod 700 "$@"', root.home + "/.config/pixel-pet", root.stateDir, root.runtimeDir]
    onExited: function(exitCode) {
      if (exitCode === 0) eventServer.start()
      else console.warn("[pixel-pet] 无法创建 " + root.runtimeDir + "，收不到 hook 事件")
    }
  }

  // ------------------------------------------------------------ IPC：omarchy-shell pixel-pet <method> [arg]
  IpcHandler {
    target: "pixel-pet"

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
    // omarchy-shell pixel-pet packs | usePack <pack> (all pets) or <pet>=<pack> | buildPack <pack> | editGeometry <pack>
    function packs(): string {
      return JSON.stringify(root.packList.map(function(p) {
        var v = root.packView(p.id)
        return { id: p.id, name: p.name, status: p.status, roles: v.resolved.mapped + "/" + v.resolved.total,
          pets: (root.config.pets || []).filter(function(pet) { return root.petPackId(pet.id) === p.id }).map(function(pet) { return pet.id }) }
      }))
    }
    function usePack(spec: string): string {
      var eq = spec.indexOf("=")
      var packId = eq >= 0 ? spec.slice(eq + 1) : spec
      var ids = eq >= 0 ? [spec.slice(0, eq)] : (root.config.pets || []).map(function(p) { return p.id })
      var r = "ok"
      ids.forEach(function(id) { r = root.setPetPack(id, packId) })
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
        pets: root.pets.map(function(p) { return p.id }),
        workStatus: root.workStatus,
        sessions: root.wsStore.sessions,
        lastAgent: root.lastAgent,
        usageSource: root.usageSource,
        usage: Object.keys(root.usageRecords).reduce(function(o, a) {
          var r = root.usageRecords[a]
          o[a] = r ? { updatedAt: r.updatedAt, summary: Usage.summarize(r, Date.now(), root.lang) } : null
          return o
        }, {}),
        llmBusy: llm.busy,
        autoBusy: autoLlm.busy,
        autoModel: root.autoModelFor(),
        stepSummary: root.summaryMode(),
        lang: root.lang,
        whisperAuto: root.config.whisperAuto === true
      })
    }
  }

  // ------------------------------------------------------------ 每块屏一个透明 overlay
  function screenName(pet) {
    var screens = Quickshell.screens
    if (pet.screen) {
      for (var i = 0; i < screens.length; i++) if (screens[i].name === pet.screen) return pet.screen
    }
    return screens.length ? screens[0].name : ""
  }

  function petsForScreen(screen) {
    return pets.filter(function(p) { return screenName(p) === screen.name })
  }

  Variants {
    model: root.ready ? Quickshell.screens.filter(function(s) { return root.petsForScreen(s).length > 0 }) : []

    PetOverlay {
      required property var modelData
      screen: modelData
      service: root
      pets: root.petsForScreen(modelData)
    }
  }
}
