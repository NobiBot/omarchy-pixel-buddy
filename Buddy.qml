import QtQuick
import Quickshell
import "lib/shared.mjs" as Shared
import "lib/work-status.mjs" as WS
import "lib/phrases.mjs" as Phrases

// One buddy. Coordinates mean the same as in dsh-pet: (x, y) = top-left of the 16:9 animation box, box width = size;
// the picture is shifted down by bottomPad so the feet touch the box bottom, so box bottom = ground.
// Animation chain / movement / drag and throw / squash bounce all reuse dsh-pet's pure functions (lib/shared.mjs).
Item {
  id: buddy

  property var cfg
  property var service
  property var overlay

  // Everything that comes from this buddy's sprite pack: animations, timing, geometry (Service.makeRuntime)
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

  // ------------------------------------------------------------ Animation state
  property string facing: "left" // which way the buddy faces on screen
  // The pack says which way it was drawn; the sprite is mirrored when facing the other way
  readonly property bool mirrored: facing !== rt.facing
  property string anim: ""
  property bool once: true
  property string pendingName: ""
  property int front: 0
  property bool endFired: false
  property bool dragging: false
  // Short loops (pixel animations) repeat a few times before counting as played once; see repeatsFor()
  property int repeatLeft: 0
  // After a source change currentFrame can jump straight to the last frame and look finished: a loop only counts once at least half its duration has played
  // (by time rather than frame count: Qt skips frames when busy)
  property real cycleStart: 0

  function log(msg) {
    console.log("[pixel-buddy] " + Qt.formatTime(new Date(), "HH:mm:ss") + " buddy=" + cfg.id + " " + msg)
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

  // Play name; nextOnce = call handleEnded after one play, otherwise loop forever
  // Why the current animation plays: "idle", "turn", "drag", "click", or "" (anything else).
  // One animation can fill several roles (idle doubling as drag), so the role, not the name,
  // decides how long it loops and what comes after it.
  property string playRole: ""

  function hasRole(role, name) {
    if (name === anim && playRole !== "") return playRole === role
    var pool = role === "click" ? anims.clicks : anims[role]
    return !!pool && pool.indexOf(name) >= 0
  }

  function play(name, nextOnce, role) {
    if (!name) return
    playRole = role || ""
    sayAnimLine(name)
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
    // Finish the previous fade first: its cleanup stops previous, and previous may be the very b being played now
    fade.complete()
    b.currentFrame = 0
    b.playing = true
    // Crossfade: the new picture fades from 0 to 1 on top, then the old one is removed, so no blank frame shows during the switch
    b.z = 1
    f.z = 0
    b.opacity = 0
    fade.target = b
    fade.previous = f
    fade.start()
    front = 1 - front
    onFrontShown()
  }

  // Missing / undecodable asset: give up this switch and go back to idle so the animation chain doesn't get stuck
  function backFailed() {
    if (pendingName === "") return
    log("load failed: " + pendingName)
    var failed = pendingName
    pendingName = ""
    anim = ""
    pendingMove = null
    if (anims.idle.length && anims.idle.indexOf(failed) < 0) play(Shared.pick(anims.idle), true, "idle")
  }

  // A pixel animation loop is often under a second: idle / small actions / moves / event animations repeat whole loops until at least sprite.minPlaySec seconds.
  // Turns, drags and click reactions play once by default; sprite.playSec can set seconds per animation name (0 = play once).
  // The real length of one loop (seconds): prefer the sum of frame durations pixel-buddy-build writes into the manifest
  // (Aseprite merges identical neighbouring frames into one long frame on export, so frames / fps comes out too short)
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
    else if (hasRole("turn", name) || hasRole("drag", name) || hasRole("click", name)) want = 0
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
    if (anims.idle.length) play(Shared.pick(anims.idle, anim), true, "idle")
  }

  function pickNext() {
    // Hold still while the geometry editor is open, so the outlines are easy to judge
    if (editingGeometry) {
      playIdle()
      return
    }
    var roll = Math.random()
    var k = Shared.rollKind(roll, weights, { fixed: cfg.fixedEnabled === true })
    if (k === "idle") {
      play(Shared.pick(anims.idle, anim), true, "idle")
    } else if (k === "turn") {
      play(Shared.pick(anims.turn, anim), true, "turn")
    } else if (k === "move" && !moveBusy() && tryMove("") !== false) {
      // Move started
    } else {
      var act = Shared.pickCategoryAction(anims.categories, anims.idle, facing, anim)
      play(act.name, true, act.id === "FALLBACK" ? "idle" : "")
    }
  }

  // After an interaction or event animation ends: if a work status is still active, go back to that level's loop
  function resumeWorkStatus() {
    var ws = wsActive()
    if (!ws) return false
    var pool = (anims.events || {}).workStatus || []
    var slot = pool[WS.stateIndex(ws.state)]
    // Unmapped state: no animation, the buddy carries on as usual
    if (!slot || (Array.isArray(slot) && !slot.length)) return false
    play(Shared.pickSlot(slot, anim), Array.isArray(slot) && slot.length > 1)
    return true
  }

  function handleEnded() {
    if (dragging) return
    if (resumeAfterPreview) {
      resumeAfterPreview = false
      if (wsActive()) {
        // A previewed turn still ends facing the other way
        if (hasRole("turn", anim)) facing = facing === "left" ? "right" : "left"
        if (resumeWorkStatus()) return
      }
    }
    // Finish the movement when the move animation ends, so an unfinished moveDrive doesn't block the next pick
    if (moveDrive && moveDrive.name === anim) finishMove()
    var events = anims.events || {}
    var isEvent = Shared.isEventAnim(events, anim)
    if (isEvent && wsActive()) {
      // Levels with several candidates: switch to the next one after each plays, so long states don't repeat one clip
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
    if (hasRole("turn", anim)) facing = facing === "left" ? "right" : "left"
    if (hasRole("drag", anim) || hasRole("click", anim)) {
      if (!resumeWorkStatus()) playIdle()
      return
    }
    pickNext()
  }

  // ------------------------------------------------------------ Movement
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
    var distScale = size / Shared.BUDDY_REF_WIDTH
    function planFor(d) {
      return Shared.planMove({
        cx: x + size / 2,
        cy: y + boxH / 2,
        W: areaW,
        H: areaH,
        dir: d,
        minDist: mp.minDist * distScale,
        maxDist: mp.maxDist * distScale,
        margin: mp.margin,
        halfW: size / 2,
        sideAllow: sideAllow
      })
    }
    // Look only at facing: when a turn finishes handleEnded has already flipped facing, and flipping again for "turning" would walk backwards
    var dir = facing === "right" ? 1 : -1
    // Without a turn animation the buddy could never change direction and would get stuck at a
    // screen edge: pick a direction per walk (the other one if blocked) and just flip the sprite.
    var noTurn = !anims.turn.length
    if (noTurn && Math.random() < 0.5) dir = -dir
    var plan = planFor(dir)
    if (!plan && noTurn) {
      dir = -dir
      plan = planFor(dir)
    }
    if (!plan) return false
    if (noTurn) facing = dir > 0 ? "right" : "left"
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
      // speed (canvas pixels / second) → how long this stretch takes; the walk loop plays whole loops that cover the full distance
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

  // Jump straight to the destination and end the movement
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
    running: buddy.moveDrive !== null
    onTriggered: {
      var m = buddy.moveDrive
      if (!m) return
      var t = (Date.now() - m.t0) / 1000
      var ratioX
      if (t <= m.leadSec) ratioX = m.startRatio
      else if (t >= m.duration - m.tailSec) ratioX = m.targetRatio
      else ratioX = m.startRatio + m.dir * m.totalRatio * ((t - m.leadSec) / m.travel)
      // Round: nearest-neighbour sampling of pixel art at fractional coordinates flickers
      buddy.x = Math.round(ratioX * buddy.areaW - buddy.size / 2)
      buddy.y = Math.round(m.startYRatio * buddy.areaH - buddy.boxH / 2)
      if (t >= m.duration - m.tailSec) buddy.moveDrive = null
    }
  }

  // ------------------------------------------------------------ Drag / throw
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
    running: buddy.dragTarget !== null
    onTriggered: {
      var target = buddy.dragTarget
      if (!target) return
      var dt = Math.min(frameTime, 1 / 30)
      var v = buddy.dragVel
      v.vx = Shared.springStep(v.vx, buddy.x, target.x, dt, buddy.physics.throwPower)
      v.vy = Shared.springStep(v.vy, buddy.y, target.y, dt, buddy.physics.throwPower)
      buddy.x += v.vx * dt
      buddy.y += v.vy * dt
    }
  }

  FrameAnimation {
    id: throwAnim
    running: buddy.throwState !== null
    onTriggered: {
      var s = buddy.throwState
      if (!s) return
      var fallingVy = s.vy
      var res = Shared.throwStepRegion(s, frameTime, buddy.throwSpaceObj, buddy.physics, 0)
      buddy.x = res.x
      buddy.y = res.y
      var grounded = res.y >= buddy.areaH - buddy.boxH - 1
      if (res.bounced && grounded && !buddy.prevGrounded) buddy.startSquash(Shared.landingSquash(fallingVy))
      buddy.prevGrounded = grounded
      if (res.atRest) buddy.throwState = null
      else buddy.throwState = { x: res.x, y: res.y, vx: res.vx, vy: res.vy }
    }
  }

  // ------------------------------------------------------------ Squash bounce
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
    target: buddy
    property: "squashU"
    from: 0
    to: 1
    duration: Shared.SQ_DURATION_MS
  }

  // ------------------------------------------------------------ Picture
  Item {
    id: stage
    width: buddy.size
    height: buddy.boxH
    // Sprites drawn off-center are shifted so the body (hitbox) sits in the middle of the box,
    // where walking, mirroring and the bubble expect it
    x: buddy.rt.offsetX * buddy.size
    y: buddy.dragging ? 0 : buddy.bottomPad
    transform: [
      Scale {
        origin.x: (0.5 - buddy.rt.offsetX) * buddy.size
        xScale: buddy.mirrored ? -1 : 1
      },
      Scale {
        origin.x: (0.5 - buddy.rt.offsetX) * buddy.size
        origin.y: buddy.boxH
        yScale: buddy.squashY
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
        if (buddy.front !== 1) return
        if (status === AnimatedImage.Ready) buddy.backReady()
        else if (status === AnimatedImage.Error) buddy.backFailed()
      }
      onCurrentFrameChanged: buddy.frameTick(imgA)
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
        if (buddy.front !== 0) return
        if (status === AnimatedImage.Ready) buddy.backReady()
        else if (status === AnimatedImage.Error) buddy.backFailed()
      }
      onCurrentFrameChanged: buddy.frameTick(imgB)
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
      if (previous !== buddy.imgAt(buddy.front)) {
        previous.opacity = 0
        previous.playing = false
      }
      previous = null
    }
  }

  // ------------------------------------------------------------ Input
  readonly property real hitX: (mirrored ? 1 - hitBox.x1 : hitBox.x0) * size
  readonly property real hitY: (dragging ? 0 : bottomPad) + hitBox.y0 * boxH
  readonly property real hitW: (hitBox.x1 - hitBox.x0) * size
  readonly property real hitH: (hitBox.y1 - hitBox.y0) * boxH

  // The overlay's input region (coordinates = overlay)
  readonly property Region hitRegion: Region {
    x: buddy.x + buddy.hitX
    y: buddy.y + buddy.hitY
    width: buddy.hitW
    height: buddy.hitH
  }

  // While the geometry editor is open for this buddy's pack, draw what it edits on the buddy itself:
  // the hitbox (click / drag area, bubble anchor) and the feet line (sits on the ground).
  readonly property bool editingGeometry: service.geometryPackId !== "" && service.geometryPackId === rt.packId
  // Back to the home corner, out from under the editor window, and hold still there
  onEditingGeometryChanged: if (editingGeometry && placed && !dragging) goHome()

  Rectangle {
    visible: buddy.editingGeometry
    x: buddy.hitX
    y: buddy.hitY
    width: buddy.hitW
    height: buddy.hitH
    color: "transparent"
    border.color: "#e0a050"
    border.width: 2
  }

  Rectangle {
    visible: buddy.editingGeometry && !buddy.dragging
    y: buddy.boxH - 1
    width: buddy.size
    height: 2
    color: "#9ece6a"
  }

  MouseArea {
    id: hit
    x: buddy.hitX
    y: buddy.hitY
    width: buddy.hitW
    height: buddy.hitH
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    preventStealing: true
    hoverEnabled: true
    cursorShape: buddy.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor

    function overlayPoint(mouse) {
      return hit.mapToItem(buddy.parent, mouse.x, mouse.y)
    }

    onPressed: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        var p = overlayPoint(mouse)
        buddy.overlay.openMenu(buddy, p.x, p.y)
        return
      }
      var q = overlayPoint(mouse)
      buddy.stopThrow()
      buddy.stopMove()
      buddy.trail = []
      buddy.dragState = {
        sx: q.x,
        sy: q.y,
        offX: q.x - (buddy.x + buddy.size / 2),
        offY: q.y - (buddy.y + buddy.boxH / 2)
      }
    }

    onPositionChanged: function(mouse) {
      var d = buddy.dragState
      if (!d || !(mouse.buttons & Qt.LeftButton)) return
      var p = overlayPoint(mouse)
      if (!buddy.dragging) {
        if (Math.hypot(p.x - d.sx, p.y - d.sy) < Shared.DRAG_THRESHOLD) return
        buddy.dragging = true
        buddy.resumeAfterPreview = false
        buddy.dragVel = { vx: 0, vy: 0 }
        if (buddy.anims.drag.length) buddy.play(Shared.pick(buddy.anims.drag), true, "drag")
      }
      var now = Date.now()
      buddy.trail = Shared.trimTrail(buddy.trail.concat([{ t: now, x: p.x, y: p.y }]), now)
      buddy.dragTarget = { x: p.x - d.offX - buddy.size / 2, y: p.y - d.offY - buddy.boxH / 2 }
    }

    onReleased: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      var wasDragging = buddy.dragging
      buddy.dragState = null
      buddy.dragTarget = null
      if (wasDragging) {
        buddy.dragging = false
        if (!buddy.resumeWorkStatus()) buddy.playIdle()
        var vel = Shared.estimateReleaseVelocity(buddy.trail, Date.now(), buddy.physics)
        buddy.trail = []
        if (vel) buddy.startThrow(vel.vx, vel.vy)
        else buddy.startThrow(0, 0) // Letting go in place also drops it back to the ground
        return
      }
      // Click: clickAction = "usage" shows usage (squash bounce + usage animation and bubble); the default "react" plays a click reaction + squash bounce
      if (buddy.service.config.clickAction === "usage") {
        buddy.startSquash(Shared.SQ_SQUASH)
        buddy.service.showUsage(true)
        return
      }
      if (buddy.anims.clicks.length) {
        buddy.pendingSquash = true
        buddy.play(Shared.pick(buddy.anims.clicks), true, "click")
      }
    }
  }

  // ------------------------------------------------------------ Menu actions (called by BuddyMenu)
  function menuAction(leaf) {
    if (leaf.action === "whisper") {
      var r = service.requestWhisper(cfg.id)
      if (r === "busy") showBubble(service.tr("whisperBusy"), "", 4000)
      else if (r === "ok") showBubble(service.tr("whisperThinking"), "", 0)
      return
    }
    if (leaf.action === "chat") {
      overlay.openChat(buddy)
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

  // ------------------------------------------------------------ Bubble
  // The work status bubble stays (until the status changes); temporary bubbles like murmurs / usage cover it, and it shows again when they time out
  property var wsBubble: null
  property var tempBubble: null

  // `anim` = a line from the pack's animPhrases, which the next animation's line may replace
  function showBubble(text, meme, ms, anim) {
    tempBubble = { text: text, meme: meme || "", anim: !!anim }
    if (ms > 0) bubbleTimer.interval = ms
    if (ms > 0) bubbleTimer.restart()
    else bubbleTimer.stop()
  }

  // A random line for the animation that just started, if the pack has any. An agent's work
  // status, a murmur, chat or usage in the bubble wins over it.
  function sayAnimLine(name) {
    var lines = (rt.animPhrases || {})[name]
    if (!lines || !lines.length || wsBubble || (tempBubble && !tempBubble.anim)) return
    var line = Phrases.pickLine(lines)
    if (line) showBubble(line, "", 4000, true)
  }

  Timer {
    id: bubbleTimer
    onTriggered: buddy.tempBubble = null
  }

  Timer {
    id: wsBubbleTimer
    interval: 8000
    onTriggered: buddy.wsBubble = null
  }

  readonly property var bubbleContent: editingGeometry ? { text: service.tr("geometryBubble"), meme: "" } : (tempBubble || wsBubble)

  Bubble {
    id: bubble
    content: buddy.bubbleContent
    memeDir: Qt.resolvedUrl("assets/memes/")
    readonly property var fontCfg: buddy.service.config.bubbleFont || ({})
    // With no font set, use Noto Sans; if it isn't installed, fontconfig falls back to another font
    fontFamily: fontCfg.family || (fontCfg.file ? "" : "Noto Sans")
    fontFile: fontCfg.file ? String(fontCfg.file).replace(/^~(?=\/)/, buddy.service.home) : ""
    fontSize: Number(fontCfg.size) > 0 ? Number(fontCfg.size) : 14
    // Centred above the head, kept on screen
    readonly property real headY: buddy.bottomPad + buddy.hitBox.y0 * buddy.boxH
    x: Math.max(-buddy.x + 4, Math.min(buddy.size / 2 - width / 2, buddy.areaW - buddy.x - width - 4))
    y: Math.max(-buddy.y + 4, headY - height + 6)
    tailX: buddy.size / 2 - x
  }

  // ------------------------------------------------------------ External events
  Connections {
    target: buddy.service

    function onWorkStatusChanged() {
      buddy.applyWorkStatus()
    }

    // After a config change (e.g. workStatusDetail), recompute the bubble with the new settings right away; the level hasn't changed, so the animation doesn't replay
    function onConfigChanged() {
      buddy.applyWorkStatus()
    }

    function onSpeak(buddyId, text, meme, kind) {
      if (buddyId !== "" && buddyId !== buddy.cfg.id) return
      if (kind === "whisper" || kind === "chat") {
        var pool = (buddy.anims.events || {}).whisper || []
        if (pool.length && !buddy.dragging) buddy.play(Shared.pickSlot(pool[Math.floor(Math.random() * pool.length)], buddy.anim), true)
        buddy.showBubble(text, meme, 12000)
      } else {
        buddy.showBubble(text, "", kind === "error" ? 10000 : 8000)
      }
    }

    function onPlayRequest(buddyId, name) {
      if (buddyId !== "" && buddyId !== buddy.cfg.id) return
      buddy.playByName(name)
    }

    function onUsageShow(summary) {
      if (buddy.cfg.balanceEnabled === false) return
      var pool = (buddy.anims.events || {}).balance || []
      var slot = pool[summary.tier]
      if (slot && !buddy.dragging && !buddy.wsActive()) buddy.play(Shared.pickSlot(slot, buddy.anim), true)
      buddy.showBubble(summary.text, "", 10000)
    }
  }

  // The session + level currently shown; only a change here switches animations, while tool / command / summary changes only refresh the bubble
  property string wsSig: ""
  property string wsLine: ""
  property var wsTexts: null

  function applyWorkStatus() {
    if (cfg.workStatusEnabled === false) return
    var ws = service.workStatus
    if (!ws) {
      // No active session: the looping status animation finishes this play, then goes back to the random chain
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
    if (changed || wsTexts !== rt.phrases) {
      wsTexts = rt.phrases
      var texts = rt.phrases || []
      wsLine = Phrases.pickLine(texts[idx] || [])
    }

    // Bubble: agent · project / step summary (when enabled and available) or level text / tool · command summary (when workStatusDetail is on)
    var showDetail = service.config.workStatusDetail === true
    var mode = service.summaryMode()
    var project = WS.projectName(ws.cwd)
    var lines = [(ws.agent === "codex" ? "Codex" : "Claude") + (project ? " · " + project : "")]
    // Summaries in model mode describe only the step in progress; transcript mode shows the agent's last reply when it finishes
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
    if (!slot || (Array.isArray(slot) && !slot.length) || dragging || resumeAfterPreview) return
    stopMove()
    var multi = Array.isArray(slot) && slot.length > 1
    play(Shared.pickSlot(slot, anim), terminal || multi)
  }

  // A new pack (or a rebuild of this one) changes every URL: drop the current animation and
  // start from idle, or from the work-status animation if an agent is busy.
  // Phrases edited in the bar widget (or a switch to a pack with its own): pick a new line now
  readonly property var phrases: rt.phrases
  onPhrasesChanged: if (service.workStatus) applyWorkStatus()

  readonly property string rtKey: rt.packId + "@" + rt.version
  property string shownKey: ""

  // Shows the animations a save changed (or idle, after switching packs) once, then goes back
  // to what the buddy was doing, so an edit is visible right away even while an agent is working.
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

  // Right after the window is created its size is still 0, and placing corners at 0 puts them off screen: wait for the real size before placing
  property bool placed: false

  function ensurePlaced() {
    if (areaW <= 0 || areaH <= 0) return
    if (!placed) {
      placed = true
      placedSize = size
      goHome()
    } else if (!throwState && !moveDrive && !dragging) {
      clampHome()
    }
  }

  onAreaWChanged: ensurePlaced()
  onAreaHChanged: ensurePlaced()

  // The position is the box's top-left corner, so a new size (pack scale, buddy size, another
  // pack) would grow the buddy down and right, off the screen. Keep the feet where they were
  // and grow around them, then pull the buddy back inside the screen.
  property real placedSize: 0

  onSizeChanged: {
    var old = placedSize
    placedSize = size
    if (!placed || old <= 0 || old === size || dragging) return
    stopMove()
    stopThrow()
    var cx = x + old / 2
    var bottom = y + old * 9 / 16
    // boxH and the hitbox follow `size` through bindings that may not have updated yet
    Qt.callLater(function() {
      buddy.x = Math.round(cx - buddy.size / 2)
      buddy.y = Math.round(bottom - buddy.boxH)
      buddy.clampHome()
    })
  }

  // A new hitbox changes how far the buddy may hang off the sides
  onHitBoxChanged: if (placed && !dragging && !throwState && !moveDrive) clampHome()

  Component.onCompleted: {
    shownKey = rtKey
    ensurePlaced()
    playIdle()
    if (service.workStatus) applyWorkStatus()
  }
}
