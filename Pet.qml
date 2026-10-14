import QtQuick
import Quickshell
import "lib/shared.mjs" as Shared
import "lib/work-status.mjs" as WS

// 一只宠物。坐标语义与 dsh-pet 一致：(x, y) = 16:9 动画盒的左上角，盒宽 size；
// 画面下移 bottomPad 让脚底贴住盒底，所以盒底 = 地面。
// 动画链 / 移动 / 拖拽甩抛 / Q 弹全部复用 dsh-pet 的纯函数（lib/shared.mjs）。
Item {
  id: pet

  property var cfg
  property var service
  property var overlay

  // Everything that comes from this pet's sprite pack: animations, timing, geometry (Service.makeRuntime)
  readonly property var rt: service.runtimes[cfg.id] || service.emptyRuntime
  readonly property var anims: rt.anims
  readonly property var weights: rt.weights
  readonly property var physics: Object.assign({}, Shared.DEFAULT_PHYSICS, service.config.physics || {})
  readonly property real fps: rt.fps

  readonly property real size: rt.size
  readonly property real boxH: size * 9 / 16
  // Canvas geometry as 0–1 ratios; hitBox is mirrored with the sprite (see hitX)
  readonly property var hitBox: rt.hitBox
  readonly property real bottomPad: boxH * (1 - rt.feet)
  readonly property real sideAllow: Math.min(hitBox.x0, 1 - hitBox.x1) * size
  readonly property real areaW: overlay.areaW
  readonly property real areaH: overlay.areaH

  width: size
  height: boxH

  // ------------------------------------------------------------ 动画状态
  property string facing: "left" // which way the pet faces on screen
  // The pack says which way it was drawn; the sprite is mirrored when facing the other way
  readonly property bool mirrored: facing !== rt.facing
  property string anim: ""
  property bool once: true
  property string pendingName: ""
  property int front: 0
  property bool endFired: false
  property bool dragging: false
  // 短循环（像素动画）要重复几遍才算播完一次，见 repeatsFor()
  property int repeatLeft: 0
  // 换源后 currentFrame 可能立刻跳到末帧，被误判为播完：这一圈至少要播了一半时长才算数
  //（按时间而不是数帧：Qt 忙时会跳帧）
  property real cycleStart: 0

  function log(msg) {
    console.log("[pixel-pet] " + Qt.formatTime(new Date(), "HH:mm:ss") + " pet=" + cfg.id + " " + msg)
  }

  function imgAt(i) {
    return i === 0 ? imgA : imgB
  }

  function urlFor(name) {
    return rt.urlFor(name)
  }

  function wsActive() {
    var ws = service.workStatus
    return cfg.workStatusEnabled !== false && ws && !WS.isTerminal(ws.state) ? ws : null
  }

  // 播放 name；nextOnce = 播完一遍触发 handleEnded，否则无限循环
  function play(name, nextOnce) {
    if (!name) return
    log("play " + name + (nextOnce ? "" : " (loop)"))
    once = nextOnce
    var f = imgAt(front)
    if (name === anim && pendingName === "" && f.status === AnimatedImage.Ready) {
      endFired = false
      f.currentFrame = 0
      f.playing = true
      onFrontShown()
      return
    }
    anim = name
    pendingName = name
    var b = imgAt(1 - front)
    b.playing = false
    var url = urlFor(name)
    if (String(b.source) === String(url) && b.status === AnimatedImage.Ready) backReady()
    else b.source = url
  }

  function backReady() {
    var b = imgAt(1 - front)
    var f = imgAt(front)
    if (pendingName === "" || String(b.source) !== String(urlFor(pendingName))) return
    pendingName = ""
    endFired = false
    // 先结束上一次淡入：它的收尾会停掉 previous，而 previous 可能正是这次要播的 b
    fade.complete()
    b.currentFrame = 0
    b.playing = true
    // 交叉淡入：新画面在上层从 0 淡到 1，淡完再撤掉旧画面，切换时不露空白帧
    b.z = 1
    f.z = 0
    b.opacity = 0
    fade.target = b
    fade.previous = f
    fade.start()
    front = 1 - front
    onFrontShown()
  }

  // 素材缺失 / 解码失败：放弃这次切换，回到待机，别让动画链卡死
  function backFailed() {
    if (pendingName === "") return
    log("load failed: " + pendingName)
    var failed = pendingName
    pendingName = ""
    anim = ""
    pendingMove = null
    if (anims.idle.length && anims.idle.indexOf(failed) < 0) play(Shared.pick(anims.idle), true)
  }

  // 像素动画一圈往往不到一秒：idle / 小动作 / 移动 / 事件动画重复整圈，直到至少 sprite.minPlaySec 秒。
  // 转身、拖拽、点击回应默认只播一遍；sprite.playSec 可按动画名单独指定秒数（0 = 只播一遍）。
  // 一圈的真实时长（秒）：优先用 pixel-pet-build 写进 manifest 的帧时长之和
  //（Aseprite 导出时会把相同的相邻帧合并成一帧长帧，帧数 / fps 会算短）
  function cycleSec(name, frameCount) {
    var ms = Number(rt.durations[name])
    return ms > 0 ? ms / 1000 : frameCount / fps
  }

  function repeatsFor(name, frameCount) {
    if (!once || frameCount <= 1) return 0
    var sprite = rt.sprite
    var per = sprite.playSec || {}
    var want
    if (Object.prototype.hasOwnProperty.call(per, name)) want = Number(per[name]) || 0
    else if (anims.turn.indexOf(name) >= 0 || anims.drag.indexOf(name) >= 0 || anims.clicks.indexOf(name) >= 0) want = 0
    else want = Number(sprite.minPlaySec) || 0
    return Math.max(0, Math.ceil(want / cycleSec(name, frameCount) - 1e-6) - 1)
  }

  function onFrontShown() {
    cycleStart = Date.now()
    repeatLeft = repeatsFor(anim, imgAt(front).frameCount)
    if (pendingMove) startMoveDrive()
    if (pendingSquash) {
      pendingSquash = false
      startSquash(Shared.SQ_SQUASH)
    }
  }

  function frameTick(img) {
    if (img !== imgAt(front) || pendingName !== "") return
    if (img.frameCount > 1 && img.currentFrame === img.frameCount - 1) {
      var elapsed = Date.now() - cycleStart
      if (elapsed < 500 * cycleSec(anim, img.frameCount)) {
        log("ignored early end of " + anim + " after " + elapsed + " ms")
        return
      }
      cycleStart = Date.now()
      frontEnded(img)
    }
  }

  function frontEnded(img) {
    if (img !== imgAt(front) || pendingName !== "" || !once || endFired) return
    if (repeatLeft > 0) {
      repeatLeft--
      return
    }
    endFired = true
    handleEnded()
  }

  function playIdle() {
    if (anims.idle.length) play(Shared.pick(anims.idle, anim), true)
  }

  function pickNext() {
    var roll = Math.random()
    var k = Shared.rollKind(roll, weights, { fixed: cfg.fixedEnabled === true })
    if (k === "idle") {
      play(Shared.pick(anims.idle, anim), true)
    } else if (k === "turn") {
      play(Shared.pick(anims.turn, anim), true)
    } else if (k === "move" && !moveBusy() && tryMove("") !== false) {
      // 已发起移动
    } else {
      var act = Shared.pickCategoryAction(anims.categories, anims.idle, facing, anim)
      play(act.name, true)
    }
  }

  // 互动或事件动画结束后：工作状态还在进行中就回到对应档位循环
  function resumeWorkStatus() {
    var ws = wsActive()
    if (!ws) return false
    var pool = (anims.events || {}).workStatus || []
    var slot = pool[WS.stateIndex(ws.state)]
    if (slot === undefined) return false
    play(Shared.pickSlot(slot, anim), Array.isArray(slot) && slot.length > 1)
    return true
  }

  function handleEnded() {
    if (dragging) return
    if (resumeAfterPreview) {
      resumeAfterPreview = false
      if (wsActive()) {
        // A previewed turn still ends facing the other way
        if (anims.turn.indexOf(anim) >= 0) facing = facing === "left" ? "right" : "left"
        if (resumeWorkStatus()) return
      }
    }
    // 移动动画播完就收尾位移：别让还没跑完的 moveDrive 挡住下一次挑选
    if (moveDrive && moveDrive.name === anim) finishMove()
    var events = anims.events || {}
    var isEvent = Shared.isEventAnim(events, anim)
    if (isEvent && wsActive()) {
      // 多候选档位：播完一段换下一段，长时间状态不单段重复
      var nextWork = Shared.nextWorkStatusAnim(events.workStatus || [], anim)
      if (nextWork !== null) {
        play(nextWork, true)
        return
      }
      if (Shared.poolIncludes(events.workStatus || [], anim)) {
        play(anim, false)
        return
      }
    }
    if (isEvent) {
      if (!resumeWorkStatus()) playIdle()
      return
    }
    if (anims.turn.indexOf(anim) >= 0) facing = facing === "left" ? "right" : "left"
    if (anims.drag.indexOf(anim) >= 0 || anims.clicks.indexOf(anim) >= 0) {
      if (!resumeWorkStatus()) playIdle()
      return
    }
    pickNext()
  }

  // ------------------------------------------------------------ 移动
  property var pendingMove: null
  property var moveDrive: null

  function moveBusy() {
    return moveDrive !== null || pendingMove !== null || throwAnim.running
  }

  function tryMove(preferredName) {
    if (moveBusy()) {
      log("move skipped: still moving")
      return true
    }
    var moves = anims.moves
    var actions = moves.actions
    if (!actions.length) return false
    var chosen = null
    if (preferredName) {
      for (var i = 0; i < actions.length; i++) if (actions[i].name === preferredName) chosen = actions[i]
    } else {
      chosen = actions[Math.floor(Math.random() * actions.length)]
    }
    if (!chosen) return false
    var mp = Object.assign({}, moves["default"], chosen.params || {})
    // 只看 facing：转身播完时 handleEnded 已经翻过 facing，再按"正在转身"反一次方向就会倒着走
    var dir = facing === "right" ? 1 : -1
    var distScale = size / Shared.PET_REF_WIDTH
    var plan = Shared.planMove({
      cx: x + size / 2,
      cy: y + boxH / 2,
      W: areaW,
      H: areaH,
      dir: dir,
      minDist: mp.minDist * distScale,
      maxDist: mp.maxDist * distScale,
      margin: mp.margin,
      halfW: size / 2,
      sideAllow: sideAllow
    })
    if (!plan) return false
    log("move " + chosen.name + " " + (dir > 0 ? "right" : "left") + " (facing " + facing + ")")
    pendingMove = Object.assign({}, plan, { dir: dir, leadSec: mp.leadSec, tailSec: mp.tailSec, speed: Number(mp.speed) || 0, name: chosen.name })
    play(chosen.name, true)
    return chosen.name
  }

  function startMoveDrive() {
    var pm = pendingMove
    if (!pm || anim !== pm.name) return
    pendingMove = null
    var f = imgAt(front)
    var cycle = f.frameCount > 1 ? cycleSec(pm.name, f.frameCount) : 10
    var duration
    if (pm.speed > 0 && f.frameCount > 1) {
      // speed（画布像素 / 秒）→ 走完这段要多久；走路循环播整圈数，正好覆盖整段路程
      var pxPerSec = pm.speed * size / rt.canvasW
      var moveSec = pm.totalRatio * areaW / pxPerSec
      var cycles = Math.max(1, Math.round((moveSec + pm.leadSec + pm.tailSec) / cycle))
      repeatLeft = cycles - 1
      duration = cycles * cycle
    } else {
      duration = cycle * (repeatLeft + 1)
    }
    moveDrive = Object.assign({}, pm, { t0: Date.now(), duration: duration, travel: Math.max(0.1, duration - pm.leadSec - pm.tailSec) })
  }

  // 直接走到终点并结束位移
  function finishMove() {
    var m = moveDrive
    if (!m) return
    moveDrive = null
    x = Math.round(m.targetRatio * areaW - size / 2)
    y = Math.round(m.startYRatio * areaH - boxH / 2)
  }

  function stopMove() {
    pendingMove = null
    moveDrive = null
  }

  FrameAnimation {
    running: pet.moveDrive !== null
    onTriggered: {
      var m = pet.moveDrive
      if (!m) return
      var t = (Date.now() - m.t0) / 1000
      var ratioX
      if (t <= m.leadSec) ratioX = m.startRatio
      else if (t >= m.duration - m.tailSec) ratioX = m.targetRatio
      else ratioX = m.startRatio + m.dir * m.totalRatio * ((t - m.leadSec) / m.travel)
      // 取整：像素画在小数坐标上最近邻采样会闪
      pet.x = Math.round(ratioX * pet.areaW - pet.size / 2)
      pet.y = Math.round(m.startYRatio * pet.areaH - pet.boxH / 2)
      if (t >= m.duration - m.tailSec) pet.moveDrive = null
    }
  }

  // ------------------------------------------------------------ 拖拽 / 甩抛
  property var dragState: null // { sx, sy, offX, offY }
  property var dragTarget: null
  property var dragVel: ({ vx: 0, vy: 0 })
  property var trail: []
  property var throwState: null
  property var throwSpaceObj: null
  property bool prevGrounded: false

  function clampHome() {
    x = Math.max(-sideAllow, Math.min(areaW - size + sideAllow, x))
    y = Math.max(0, Math.min(areaH - boxH, y))
  }

  function startThrow(vx, vy) {
    stopMove()
    throwSpaceObj = Shared.throwSpace({ areas: [{ x: 0, y: 0, width: areaW, height: areaH }], size: size, sideAllow: sideAllow })
    throwState = { x: x, y: y, vx: vx, vy: vy }
    prevGrounded = false
  }

  function stopThrow() {
    throwState = null
  }

  FrameAnimation {
    running: pet.dragTarget !== null
    onTriggered: {
      var target = pet.dragTarget
      if (!target) return
      var dt = Math.min(frameTime, 1 / 30)
      var v = pet.dragVel
      v.vx = Shared.springStep(v.vx, pet.x, target.x, dt, pet.physics.throwPower)
      v.vy = Shared.springStep(v.vy, pet.y, target.y, dt, pet.physics.throwPower)
      pet.x += v.vx * dt
      pet.y += v.vy * dt
    }
  }

  FrameAnimation {
    id: throwAnim
    running: pet.throwState !== null
    onTriggered: {
      var s = pet.throwState
      if (!s) return
      var fallingVy = s.vy
      var res = Shared.throwStepRegion(s, frameTime, pet.throwSpaceObj, pet.physics, 0)
      pet.x = res.x
      pet.y = res.y
      var grounded = res.y >= pet.areaH - pet.boxH - 1
      if (res.bounced && grounded && !pet.prevGrounded) pet.startSquash(Shared.landingSquash(fallingVy))
      pet.prevGrounded = grounded
      if (res.atRest) pet.throwState = null
      else pet.throwState = { x: res.x, y: res.y, vx: res.vx, vy: res.vy }
    }
  }

  // ------------------------------------------------------------ Q 弹
  property real squashU: 1
  property real squashDepth: Shared.SQ_SQUASH
  property bool pendingSquash: false
  readonly property real squashY: squashU >= 1 ? 1 : Shared.squashScale(squashU, squashDepth)

  function startSquash(depth) {
    squashDepth = depth
    squashAnim.restart()
  }

  NumberAnimation {
    id: squashAnim
    target: pet
    property: "squashU"
    from: 0
    to: 1
    duration: Shared.SQ_DURATION_MS
  }

  // ------------------------------------------------------------ 画面
  Item {
    id: stage
    width: pet.size
    height: pet.boxH
    y: pet.dragging ? 0 : pet.bottomPad
    transform: [
      Scale {
        origin.x: pet.size / 2
        xScale: pet.mirrored ? -1 : 1
      },
      Scale {
        origin.x: pet.size / 2
        origin.y: pet.boxH
        yScale: pet.squashY
      }
    ]

    AnimatedImage {
      id: imgA
      anchors.fill: parent
      asynchronous: true
      cache: false
      smooth: false
      playing: false
      opacity: 0
      onStatusChanged: {
        if (pet.front !== 1) return
        if (status === AnimatedImage.Ready) pet.backReady()
        else if (status === AnimatedImage.Error) pet.backFailed()
      }
      onCurrentFrameChanged: pet.frameTick(imgA)
    }

    AnimatedImage {
      id: imgB
      anchors.fill: parent
      asynchronous: true
      cache: false
      smooth: false
      playing: false
      opacity: 0
      onStatusChanged: {
        if (pet.front !== 0) return
        if (status === AnimatedImage.Ready) pet.backReady()
        else if (status === AnimatedImage.Error) pet.backFailed()
      }
      onCurrentFrameChanged: pet.frameTick(imgB)
    }
  }

  NumberAnimation {
    id: fade
    property var previous: null
    property: "opacity"
    from: 0
    to: 1
    duration: 120
    onFinished: if (previous) {
      if (previous !== pet.imgAt(pet.front)) {
        previous.opacity = 0
        previous.playing = false
      }
      previous = null
    }
  }

  // ------------------------------------------------------------ 输入
  readonly property real hitX: (mirrored ? 1 - hitBox.x1 : hitBox.x0) * size
  readonly property real hitY: (dragging ? 0 : bottomPad) + hitBox.y0 * boxH
  readonly property real hitW: (hitBox.x1 - hitBox.x0) * size
  readonly property real hitH: (hitBox.y1 - hitBox.y0) * boxH

  // overlay 的输入区域（坐标系 = overlay）
  readonly property Region hitRegion: Region {
    x: pet.x + pet.hitX
    y: pet.y + pet.hitY
    width: pet.hitW
    height: pet.hitH
  }

  MouseArea {
    id: hit
    x: pet.hitX
    y: pet.hitY
    width: pet.hitW
    height: pet.hitH
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    preventStealing: true
    hoverEnabled: true
    cursorShape: pet.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor

    function overlayPoint(mouse) {
      return hit.mapToItem(pet.parent, mouse.x, mouse.y)
    }

    onPressed: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        var p = overlayPoint(mouse)
        pet.overlay.openMenu(pet, p.x, p.y)
        return
      }
      var q = overlayPoint(mouse)
      pet.stopThrow()
      pet.stopMove()
      pet.trail = []
      pet.dragState = {
        sx: q.x,
        sy: q.y,
        offX: q.x - (pet.x + pet.size / 2),
        offY: q.y - (pet.y + pet.boxH / 2)
      }
    }

    onPositionChanged: function(mouse) {
      var d = pet.dragState
      if (!d || !(mouse.buttons & Qt.LeftButton)) return
      var p = overlayPoint(mouse)
      if (!pet.dragging) {
        if (Math.hypot(p.x - d.sx, p.y - d.sy) < Shared.DRAG_THRESHOLD) return
        pet.dragging = true
        pet.resumeAfterPreview = false
        pet.dragVel = { vx: 0, vy: 0 }
        if (pet.anims.drag.length) pet.play(Shared.pick(pet.anims.drag), true)
      }
      var now = Date.now()
      pet.trail = Shared.trimTrail(pet.trail.concat([{ t: now, x: p.x, y: p.y }]), now)
      pet.dragTarget = { x: p.x - d.offX - pet.size / 2, y: p.y - d.offY - pet.boxH / 2 }
    }

    onReleased: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      var wasDragging = pet.dragging
      pet.dragState = null
      pet.dragTarget = null
      if (wasDragging) {
        pet.dragging = false
        if (!pet.resumeWorkStatus()) pet.playIdle()
        var vel = Shared.estimateReleaseVelocity(pet.trail, Date.now(), pet.physics)
        pet.trail = []
        if (vel) pet.startThrow(vel.vx, vel.vy)
        else pet.startThrow(0, 0) // 原地松手也让它落回地面
        return
      }
      // 点击：clickAction = "usage" 查看用量（Q 弹 + 用量动画与气泡）；默认 "react" 播点击回应动画 + Q 弹
      if (pet.service.config.clickAction === "usage") {
        pet.startSquash(Shared.SQ_SQUASH)
        pet.service.showUsage(true)
        return
      }
      if (pet.anims.clicks.length) {
        pet.pendingSquash = true
        pet.play(Shared.pick(pet.anims.clicks), true)
      }
    }
  }

  // ------------------------------------------------------------ 菜单动作（PetMenu 调用）
  function menuAction(leaf) {
    if (leaf.action === "whisper") {
      var r = service.requestWhisper(cfg.id)
      if (r === "busy") showBubble(service.tr("whisperBusy"), "", 4000)
      else if (r === "ok") showBubble(service.tr("whisperThinking"), "", 0)
      return
    }
    if (leaf.action === "chat") {
      overlay.openChat(pet)
      return
    }
    if (leaf.action === "usage") {
      service.showUsage(true)
      return
    }
    if (leaf.action === "home") {
      goHome()
      return
    }
    if (leaf.action === "reload") {
      service.reloadConfig()
      return
    }
    if (leaf.action === "hide") {
      service.hidden = true
      return
    }
    if (!leaf.anim) return
    playByName(leaf.anim)
  }

  function playByName(name) {
    stopThrow()
    if (Shared.isNoMirrorAnimation(anims.categories, name) && facing === "right") facing = "left"
    if (anims.moves.actions.some(function(a) { return a.name === name })) {
      stopMove()
      if (tryMove(name) === false) play(name, true)
      return
    }
    stopMove()
    play(name, true)
  }

  function goHome() {
    stopThrow()
    stopMove()
    var p = Shared.anchorPixel({
      corner: (cfg.position || {}).corner || "bottom-right",
      marginX: Number((cfg.position || {}).marginX) || 0,
      marginY: Number((cfg.position || {}).marginY) || 0,
      size: size,
      W: areaW,
      H: areaH
    })
    x = p.x
    y = p.y
    log("home " + Math.round(x) + "," + Math.round(y) + " in " + areaW + "x" + areaH)
  }

  // ------------------------------------------------------------ 气泡
  // 工作状态气泡常驻（直到状态变化）；碎碎念 / 用量等临时气泡盖在上面，到时后露出工作状态气泡
  property var wsBubble: null
  property var tempBubble: null

  function showBubble(text, meme, ms) {
    tempBubble = { text: text, meme: meme || "" }
    if (ms > 0) bubbleTimer.interval = ms
    if (ms > 0) bubbleTimer.restart()
    else bubbleTimer.stop()
  }

  Timer {
    id: bubbleTimer
    onTriggered: pet.tempBubble = null
  }

  Timer {
    id: wsBubbleTimer
    interval: 8000
    onTriggered: pet.wsBubble = null
  }

  readonly property var bubbleContent: tempBubble || wsBubble

  Bubble {
    id: bubble
    content: pet.bubbleContent
    memeDir: Qt.resolvedUrl("assets/memes/")
    readonly property var fontCfg: pet.service.config.bubbleFont || ({})
    // 没指定字体时：中文用 Noto Sans CJK SC，英文用 Noto Sans；没装则由 fontconfig 回退到其他字体
    fontFamily: fontCfg.family || (fontCfg.file ? "" : pet.service.lang === "en" ? "Noto Sans" : "Noto Sans CJK SC")
    fontFile: fontCfg.file ? String(fontCfg.file).replace(/^~(?=\/)/, pet.service.home) : ""
    fontSize: Number(fontCfg.size) > 0 ? Number(fontCfg.size) : 14
    // 头顶居中，夹在屏幕内
    readonly property real headY: pet.bottomPad + pet.hitBox.y0 * pet.boxH
    x: Math.max(-pet.x + 4, Math.min(pet.size / 2 - width / 2, pet.areaW - pet.x - width - 4))
    y: Math.max(-pet.y + 4, headY - height + 6)
    tailX: pet.size / 2 - x
  }

  // ------------------------------------------------------------ 外部事件
  Connections {
    target: pet.service

    function onWorkStatusChanged() {
      pet.applyWorkStatus()
    }

    // 改配置（如 workStatusDetail）后立即按新设置重算气泡；档位没变，不会重播动画
    function onConfigChanged() {
      pet.applyWorkStatus()
    }

    function onSpeak(petId, text, meme, kind) {
      if (petId !== "" && petId !== pet.cfg.id) return
      if (kind === "whisper" || kind === "chat") {
        var pool = (pet.anims.events || {}).whisper || []
        if (pool.length && !pet.dragging) pet.play(Shared.pickSlot(pool[Math.floor(Math.random() * pool.length)], pet.anim), true)
        pet.showBubble(text, meme, 12000)
      } else {
        pet.showBubble(text, "", kind === "error" ? 10000 : 8000)
      }
    }

    function onPlayRequest(petId, name) {
      if (petId !== "" && petId !== pet.cfg.id) return
      pet.playByName(name)
    }

    function onUsageShow(summary) {
      if (pet.cfg.balanceEnabled === false) return
      var pool = (pet.anims.events || {}).balance || []
      var slot = pool[summary.tier]
      if (slot !== undefined && !pet.dragging && !pet.wsActive()) pet.play(Shared.pickSlot(slot, pet.anim), true)
      pet.showBubble(summary.text, "", 10000)
    }
  }

  // 当前展示的会话 + 档位；只有它变化才切动画，工具 / 命令 / 总结变化只刷新气泡
  property string wsSig: ""
  property string wsLine: ""
  property string wsLang: ""

  function applyWorkStatus() {
    if (cfg.workStatusEnabled === false) return
    var ws = service.workStatus
    if (!ws) {
      // 没有活跃会话：正在循环的状态动画播完这一遍就回随机链
      once = true
      wsBubble = null
      wsSig = ""
      return
    }
    var idx = WS.stateIndex(ws.state)
    var terminal = WS.isTerminal(ws.state)
    var sig = ws.key + "|" + ws.state
    var changed = sig !== wsSig
    wsSig = sig
    if (changed || wsLang !== service.lang) {
      wsLang = service.lang
      var texts = service.config.workStatusTexts || []
      wsLine = texts[idx] && texts[idx].length ? texts[idx][Math.floor(Math.random() * texts[idx].length)] : ""
    }

    // 气泡：agent · 项目 / 步骤总结（开启且已有）或档位文案 / 工具 · 命令摘要（workStatusDetail 开启时）
    var showDetail = service.config.workStatusDetail === true
    var mode = service.summaryMode()
    var project = WS.projectName(ws.cwd)
    var lines = [(ws.agent === "codex" ? "Codex" : "Claude") + (project ? " · " + project : "")]
    // model 模式的总结只描述进行中的步骤；transcript 模式结束时显示 agent 的最后一句回复
    var showSummary = ws.summary && (mode === "transcript" || (mode === "model" && !terminal))
    var main = showSummary ? ws.summary : wsLine
    if (!showDetail && ws.state === "waiting" && ws.tool) main += service.tr("toolSuffix", { tool: ws.tool })
    if (main) lines.push(main)
    if (showDetail && ws.tool && !terminal) lines.push(WS.formatDetail(ws.tool, ws.detail, ws.cwd))
    wsBubble = lines.length > 1 ? { text: lines.join("\n"), meme: "" } : null
    if (!changed) return

    if (terminal) wsBubbleTimer.restart()
    else wsBubbleTimer.stop()
    var pool = (anims.events || {}).workStatus || []
    var slot = pool[idx]
    // Let a pack preview finish; it resumes the current work status when it ends
    if (slot === undefined || dragging || resumeAfterPreview) return
    stopMove()
    var multi = Array.isArray(slot) && slot.length > 1
    play(Shared.pickSlot(slot, anim), terminal || multi)
  }

  // A new pack (or a rebuild of this one) changes every URL: drop the current animation and
  // start from idle, or from the work-status animation if an agent is busy.
  readonly property string rtKey: rt.packId + "@" + rt.version
  property string shownKey: ""

  // Shows the animations a save changed (or idle, after switching packs) once, then goes back
  // to what the pet was doing, so an edit is visible right away even while an agent is working.
  property bool resumeAfterPreview: false

  onRtKeyChanged: {
    if (shownKey === "" || shownKey === rtKey) return
    var samePack = shownKey.split("@")[0] === rt.packId
    shownKey = rtKey
    log("pack " + rtKey)
    stopMove()
    pendingName = ""
    anim = ""
    if (dragging) return
    var ch = samePack ? service.packChanges[rt.packId] : null
    var changed = ch && ch.builtAt === rt.version
      ? ch.names.filter(function(n) { return rt.durations[n] !== undefined }) : []
    var name = changed.length ? changed[0] : (anims.idle.length ? Shared.pick(anims.idle) : "")
    if (!name) {
      if (!resumeWorkStatus()) playIdle()
      return
    }
    resumeAfterPreview = true
    play(name, true)
    if (changed.length)
      showBubble(service.tr("packUpdated", { names: changed.slice(0, 3).join(", ") + (changed.length > 3 ? " …" : "") }), "", 3500)
  }

  // 窗口刚创建时宽高还是 0，按 0 算角落会落到屏幕外：等拿到真实尺寸再摆放
  property bool placed: false

  function ensurePlaced() {
    if (areaW <= 0 || areaH <= 0) return
    if (!placed) {
      placed = true
      goHome()
    } else if (!throwState && !moveDrive && !dragging) {
      clampHome()
    }
  }

  onAreaWChanged: ensurePlaced()
  onAreaHChanged: ensurePlaced()

  Component.onCompleted: {
    shownKey = rtKey
    ensurePlaced()
    playIdle()
    if (service.workStatus) applyWorkStatus()
  }
}
