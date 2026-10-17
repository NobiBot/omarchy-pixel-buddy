import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Built-in pixel editor for one PNG drawing of a pack (Edit pack → Draw), for people without
// Aseprite. `pixel-buddy-pack draw-load` hands over the drawing as a palette plus one palette
// index per pixel (0 = transparent) and `draw-save` writes it back as a PNG sheet with the simple
// JSON sidecar, so saving rebuilds the pack like any other source file.
//
// The document is `anims`: [{ name, frames: [{ ms, px }] }]. Edits replace the arrays and objects
// they touch instead of changing them, so an undo step is just the previous `anims`. The one
// exception is the frame being drawn on: beginEdit() copies it once, and the stroke writes into
// that copy directly so the canvas can repaint only the pixels that changed.
PanelWindow {
  id: win

  property var service
  property string packId: ""
  property string file: "" // "" = a new drawing, named on its first save

  readonly property var view: service.packView(packId)
  readonly property var geo: view ? view.geometry : null

  // ---------------------------------------------------------------- document
  property int cw: 128
  property int ch: 72
  property var palette: [[0, 0, 0, 0]]
  property var paletteCss: ["rgba(0,0,0,0)"]
  property var anims: []
  property var others: ({}) // animation name -> the other source file that also has it
  property int animIndex: 0
  property int frameIndex: 0
  readonly property var anim: anims[animIndex] || null
  readonly property var frames: anim ? anim.frames : []
  readonly property var frameObj: frames[frameIndex] || null

  property bool loaded: false
  property bool dirty: false
  property bool saving: false
  property bool closeAfterSave: false
  property bool confirmClose: false
  property bool confirmDeleteAnim: false
  property string message: ""
  property bool messageError: false

  // ---------------------------------------------------------------- tools
  property string tool: "pencil" // pencil | eraser | fill | line | rect | picker | move
  property color draft: "#29adff"
  property real hue: 0.56
  property real sat: 0.84
  property real val: 1
  property bool mirrorDraw: false
  property bool onion: true
  property bool grid: true
  property bool guides: true
  property bool wholeAnim: false // move and flip act on every frame of the animation
  property bool playing: true
  property int userZoom: 0
  property int hoverX: -1
  property int hoverY: -1
  property var clipboard: null
  property int strokeTick: 0

  property var undoStack: []
  property var redoStack: []
  property int historyTick: 0

  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.55)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
  readonly property color feetColor: "#9ece6a"
  readonly property color warn: "#e0af68"

  readonly property var starterPalette: ["#000000", "#1d2b53", "#7e2553", "#008751", "#ab5236", "#5f574f",
    "#c2c3c7", "#fff1e8", "#ff004d", "#ffa300", "#ffec27", "#00e436", "#29adff", "#83769c", "#ff77a8", "#ffccaa"]

  // Where the builder puts this drawing on the pack's canvas (bottom-centred when smaller), so the
  // pack's feet line and hitbox can be drawn in this drawing's pixels
  readonly property int offX: geo ? Math.floor((geo.width - cw) / 2) : 0
  readonly property int offY: geo ? geo.height - ch : 0
  readonly property real feetRow: geo ? geo.feetY - offY : -1

  screen: {
    var screens = Quickshell.screens
    var first = (service.config.buddies || [])[0]
    var name = first ? service.screenName(first) : ""
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
    return screens.length ? screens[0] : null
  }
  anchors { left: true; right: true; top: true; bottom: true }
  color: Qt.rgba(0, 0, 0, 0.45)
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "pixel-buddy-draw"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  // ---------------------------------------------------------------- colours
  function css(c) { return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + (c[3] / 255) + ")" }
  function hex2(n) { return (n < 16 ? "0" : "") + n.toString(16) }
  function hexOf(c) { return "#" + hex2(c[0]) + hex2(c[1]) + hex2(c[2]) + (c[3] < 255 ? hex2(c[3]) : "") }
  function rgbaOf(col) { return [Math.round(col.r * 255), Math.round(col.g * 255), Math.round(col.b * 255), Math.round(col.a * 255)] }
  function parseHex(t) {
    var m = /^#?([0-9a-f]{6})([0-9a-f]{2})?$/i.exec(String(t).trim())
    if (!m) return null
    var n = parseInt(m[1], 16)
    return [n >> 16 & 255, n >> 8 & 255, n & 255, m[2] ? parseInt(m[2], 16) : 255]
  }

  function setDraft(c) {
    draft = Qt.rgba(c[0] / 255, c[1] / 255, c[2] / 255, c[3] / 255)
    if (draft.hsvHue >= 0) hue = draft.hsvHue
    sat = draft.hsvSaturation
    val = draft.hsvValue
  }

  function setHsv(h, s, v) {
    hue = h; sat = s; val = v
    draft = Qt.hsva(h, s, v, draft.a)
  }

  function sameColor(a, b) { return a[0] === b[0] && a[1] === b[1] && a[2] === b[2] && a[3] === b[3] }

  // Palette index of a colour, added to the palette if it's new
  function colorIndex(c) {
    if (c[3] === 0) return 0
    for (var i = 1; i < palette.length; i++) if (sameColor(palette[i], c)) return i
    palette = palette.concat([c])
    paletteCss = paletteCss.concat([css(c)])
    return palette.length - 1
  }

  readonly property int draftIndex: {
    var c = rgbaOf(draft)
    for (var i = 1; i < palette.length; i++) if (sameColor(palette[i], c)) return i
    return -1
  }

  // ---------------------------------------------------------------- loading and saving
  function load() {
    loadProc.command = [service.packTool, "draw-load", packId].concat(file ? [file] : [])
    loadProc.running = true
  }

  function applyLoaded(d) {
    cw = d.width
    ch = d.height
    var pal = d.palette.length ? d.palette : [[0, 0, 0, 0]]
    var extra = (d.swatches || []).map(parseHex).filter(function(c) { return c !== null })
    if (pal.length === 1 && !extra.length) extra = starterPalette.map(parseHex)
    extra.forEach(function(c) {
      if (!pal.some(function(p) { return sameColor(p, c) })) pal.push(c)
    })
    palette = pal
    paletteCss = pal.map(css)
    anims = d.anims
    others = d.others || {}
    file = d.file || ""
    animIndex = 0
    frameIndex = 0
    undoStack = []
    redoStack = []
    historyTick++
    dirty = false
    loaded = true
    var firstSolid = pal.filter(function(c, i) { return i > 0 && c[3] === 255 })[0]
    if (firstSolid) setDraft(firstSolid)
    if (d.file) service.drawFile = d.file
  }

  function save(thenClose) {
    if (saving || !loaded) return
    var payload = {
      width: cw, height: ch, palette: palette,
      swatches: palette.slice(1).map(hexOf),
      anims: anims.map(function(a) { return { name: a.name, frames: a.frames } })
    }
    closeAfterSave = thenClose === true
    saving = true
    saveProc.payload = JSON.stringify(payload) + "\n"
    saveProc.command = [service.packTool, "draw-save", packId].concat(file ? [file] : [])
    saveProc.running = true
  }

  function say(text, isError) {
    message = text
    messageError = isError === true
    messageTimer.restart()
  }

  function requestClose() {
    if (dirty) confirmClose = true
    else service.closeSpriteEditor()
  }

  Process {
    id: loadProc
    stdout: StdioCollector { id: loadOut }
    stderr: StdioCollector { id: loadErr }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        win.say(loadErr.text.trim().replace(/^pixel-buddy-pack: /, "") || "Could not open the drawing", true)
        return
      }
      try {
        win.applyLoaded(JSON.parse(loadOut.text))
      } catch (e) {
        win.say("Could not read the drawing: " + e, true)
      }
    }
  }

  Process {
    id: saveProc
    property string payload: ""
    stdinEnabled: true
    stdout: StdioCollector { id: saveOut }
    stderr: StdioCollector { id: saveErr }
    onStarted: {
      write(payload)
      payload = ""
    }
    onExited: function(exitCode) {
      win.saving = false
      if (exitCode !== 0) {
        win.closeAfterSave = false
        win.say(saveErr.text.trim().replace(/^pixel-buddy-pack: /, "") || "Could not save", true)
        return
      }
      win.file = saveOut.text.trim().split("\n").pop()
      win.service.drawFile = win.file
      win.dirty = false
      if (win.closeAfterSave) win.service.closeSpriteEditor()
      else win.say("Saved " + win.file + ". The buddy picks it up in a second.", false)
    }
  }

  Timer {
    id: messageTimer
    interval: 6000
    onTriggered: win.message = ""
  }

  // ---------------------------------------------------------------- editing
  function pushUndo() {
    var u = undoStack
    u.push({ anims: anims, a: animIndex, f: frameIndex })
    if (u.length > 200) u.shift()
    redoStack = []
    historyTick++
  }

  function restore(from, to) {
    if (!from.length) return
    to.push({ anims: anims, a: animIndex, f: frameIndex })
    var s = from.pop()
    anims = s.anims
    animIndex = Math.min(s.a, anims.length - 1)
    frameIndex = Math.min(s.f, anims[animIndex].frames.length - 1)
    dirty = true
    historyTick++
  }

  function undo() { restore(undoStack, redoStack) }
  function redo() { restore(redoStack, undoStack) }

  // Change the document: fn gets a copy of `anims` (copy any animation before changing it)
  function edit(fn) {
    pushUndo()
    var list = anims.slice()
    fn(list)
    anims = list
    animIndex = Math.max(0, Math.min(animIndex, anims.length - 1))
    frameIndex = Math.max(0, Math.min(frameIndex, anims[animIndex].frames.length - 1))
    dirty = true
  }

  function withAnim(list, a) {
    var an = Object.assign({}, list[a])
    an.frames = an.frames.slice()
    list[a] = an
    return an
  }

  // Start drawing on the current frame: an undo step, and a private copy of its pixels to write into
  function beginEdit() {
    var px = frameObj.px.slice()
    var f = frameIndex
    edit(function(list) { withAnim(list, win.animIndex).frames[f] = { ms: win.frameObj.ms, px: px } })
    return px
  }

  function endStroke() {
    strokeTick++
  }

  function blank() {
    var px = new Array(cw * ch)
    for (var i = 0; i < px.length; i++) px[i] = 0
    return px
  }

  function plot(px, x, y, c) {
    if (x < 0 || y < 0 || x >= cw || y >= ch) return
    var i = y * cw + x
    if (px[i] !== c) {
      px[i] = c
      art.dirtyPx.push(i)
    }
    if (mirrorDraw) {
      var j = y * cw + (cw - 1 - x)
      if (px[j] !== c) {
        px[j] = c
        art.dirtyPx.push(j)
      }
    }
  }

  function linePoints(x0, y0, x1, y1) {
    var pts = []
    var dx = Math.abs(x1 - x0), dy = -Math.abs(y1 - y0)
    var sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
    var err = dx + dy
    while (true) {
      pts.push([x0, y0])
      if (x0 === x1 && y0 === y1) break
      var e2 = 2 * err
      if (e2 >= dy) { err += dy; x0 += sx }
      if (e2 <= dx) { err += dx; y0 += sy }
    }
    return pts
  }

  function rectPoints(x0, y0, x1, y1, filled) {
    var pts = []
    var ax = Math.min(x0, x1), bx = Math.max(x0, x1), ay = Math.min(y0, y1), by = Math.max(y0, y1)
    for (var y = ay; y <= by; y++)
      for (var x = ax; x <= bx; x++)
        if (filled || x === ax || x === bx || y === ay || y === by) pts.push([x, y])
    return pts
  }

  function floodFill(px, x, y, c) {
    var target = px[y * cw + x]
    if (target === c) return
    var stack = [y * cw + x]
    while (stack.length) {
      var i = stack.pop()
      if (px[i] !== target) continue
      px[i] = c
      art.dirtyPx.push(i)
      var ix = i % cw
      if (ix > 0) stack.push(i - 1)
      if (ix < cw - 1) stack.push(i + 1)
      if (i >= cw) stack.push(i - cw)
      if (i + cw < px.length) stack.push(i + cw)
    }
  }

  function shifted(px, dx, dy) {
    var out = blank()
    for (var y = 0; y < ch; y++) {
      var ty = y + dy
      if (ty < 0 || ty >= ch) continue
      for (var x = 0; x < cw; x++) {
        var tx = x + dx
        if (tx >= 0 && tx < cw) out[ty * cw + tx] = px[y * cw + x]
      }
    }
    return out
  }

  function flipped(px) {
    var out = new Array(px.length)
    for (var y = 0; y < ch; y++)
      for (var x = 0; x < cw; x++) out[y * cw + x] = px[y * cw + (cw - 1 - x)]
    return out
  }

  // Apply fn(px) -> px to the current frame, or to every frame of the animation
  function mapFrames(fn) {
    var all = wholeAnim, f = frameIndex
    edit(function(list) {
      var an = withAnim(list, win.animIndex)
      for (var i = 0; i < an.frames.length; i++)
        if (all || i === f) an.frames[i] = { ms: an.frames[i].ms, px: fn(an.frames[i].px) }
    })
  }

  // ---------------------------------------------------------------- frames and animations
  function addFrame(copy) {
    var f = frameIndex
    var fr = copy ? { ms: frameObj.ms, px: frameObj.px } : { ms: frameObj ? frameObj.ms : 100, px: blank() }
    edit(function(list) { withAnim(list, win.animIndex).frames.splice(f + 1, 0, fr) })
    frameIndex = f + 1
  }

  function deleteFrame() {
    if (frames.length <= 1) {
      say("An animation needs at least one frame. Delete the animation instead.", true)
      return
    }
    var f = frameIndex
    edit(function(list) { withAnim(list, win.animIndex).frames.splice(f, 1) })
  }

  function moveFrame(d) {
    var f = frameIndex, t = f + d
    if (t < 0 || t >= frames.length) return
    edit(function(list) {
      var fr = withAnim(list, win.animIndex).frames
      var x = fr[f]; fr[f] = fr[t]; fr[t] = x
    })
    frameIndex = t
  }

  function setDuration(ms, all) {
    var f = frameIndex
    edit(function(list) {
      var an = withAnim(list, win.animIndex)
      for (var i = 0; i < an.frames.length; i++)
        if (all || i === f) an.frames[i] = { ms: ms, px: an.frames[i].px }
    })
  }

  function pasteFrame() {
    if (!clipboard || clipboard.length !== cw * ch) return
    var px = clipboard, f = frameIndex
    edit(function(list) { withAnim(list, win.animIndex).frames[f] = { ms: win.frameObj.ms, px: px } })
    say("Pasted over frame " + (f + 1), false)
  }

  function uniqueName(base) {
    var names = anims.map(function(a) { return a.name })
    var n = base, k = 2
    while (names.indexOf(n) >= 0) n = base + "-" + k++
    return n
  }

  function addAnim(copy) {
    var a = copy && anim ? { name: uniqueName(anim.name + "-copy"), frames: anim.frames.slice() }
      : { name: uniqueName("new"), frames: [{ ms: 100, px: blank() }] }
    edit(function(list) { list.splice(win.animIndex + 1, 0, a) })
    animIndex = animIndex + 1
    frameIndex = 0
  }

  function deleteAnim() {
    confirmDeleteAnim = false
    if (anims.length <= 1) {
      say("A drawing needs at least one animation.", true)
      return
    }
    var a = animIndex
    edit(function(list) { list.splice(a, 1) })
    frameIndex = 0
  }

  function renameAnim(name) {
    name = String(name).trim()
    if (!anim || name === anim.name) return true
    if (!name || anims.some(function(x) { return x.name === name })) {
      say(name ? "There's already an animation called " + name : "An animation needs a name", true)
      return false
    }
    edit(function(list) { list[win.animIndex] = Object.assign({}, list[win.animIndex], { name: name }) })
    return true
  }

  function selectAnim(i) {
    animIndex = Math.max(0, Math.min(anims.length - 1, i))
    frameIndex = 0
    confirmDeleteAnim = false
  }

  function stepFrame(d) {
    if (frames.length) frameIndex = (frameIndex + d + frames.length) % frames.length
  }

  // Lowest painted row of the current frame + 1 (the feet line it would give), -1 when empty
  readonly property int frameBottom: {
    strokeTick
    var px = frameObj ? frameObj.px : null
    if (!px) return -1
    for (var i = px.length - 1; i >= 0; i--) if (px[i]) return Math.floor(i / cw) + 1
    return -1
  }

  // ---------------------------------------------------------------- painting helpers
  // Draw a frame with one fillRect per run of same-coloured pixels in a row
  function paintPx(g, px, z, alpha) {
    if (!px) return
    var cssList = paletteCss
    g.globalAlpha = alpha
    for (var y = 0; y < ch; y++) {
      var row = y * cw, x = 0
      while (x < cw) {
        var c = px[row + x]
        if (!c) { x++; continue }
        var s = x
        while (x < cw && px[row + x] === c) x++
        g.fillStyle = cssList[c] || "#ff00ff"
        g.fillRect(s * z, y * z, (x - s) * z, z)
      }
    }
    g.globalAlpha = 1
  }

  readonly property var onionPx: {
    if (!onion || frames.length < 2) return null
    var p = frames[(frameIndex - 1 + frames.length) % frames.length]
    return p ? p.px : null
  }

  // ---------------------------------------------------------------- keyboard
  function handleKey(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    var shift = event.modifiers & Qt.ShiftModifier
    var alt = event.modifiers & Qt.AltModifier
    var k = event.key
    if (ctrl && k === Qt.Key_Z) shift ? redo() : undo()
    else if (ctrl && k === Qt.Key_Y) redo()
    else if (ctrl && k === Qt.Key_S) save(false)
    else if (ctrl && k === Qt.Key_C) { clipboard = frameObj.px; say("Copied frame " + (frameIndex + 1), false) }
    else if (ctrl && k === Qt.Key_V) pasteFrame()
    else if (alt && k === Qt.Key_N) addFrame(true)
    else if (ctrl && (k === Qt.Key_Plus || k === Qt.Key_Equal)) userZoom = Math.min(40, zoom + 1)
    else if (ctrl && k === Qt.Key_Minus) userZoom = Math.max(1, zoom - 1)
    else if (ctrl && k === Qt.Key_0) userZoom = 0
    else if (ctrl || alt) return
    else if (k === Qt.Key_Escape) confirmClose ? confirmClose = false : requestClose()
    else if (k === Qt.Key_B) tool = "pencil"
    else if (k === Qt.Key_E) tool = "eraser"
    else if (k === Qt.Key_G) tool = "fill"
    else if (k === Qt.Key_L) tool = "line"
    else if (k === Qt.Key_R) tool = "rect"
    else if (k === Qt.Key_I) tool = "picker"
    else if (k === Qt.Key_V) tool = "move"
    else if (k === Qt.Key_M) mirrorDraw = !mirrorDraw
    else if (k === Qt.Key_O) onion = !onion
    else if (k === Qt.Key_Space) playing = !playing
    else if (k === Qt.Key_Left || k === Qt.Key_Comma) stepFrame(-1)
    else if (k === Qt.Key_Right || k === Qt.Key_Period) stepFrame(1)
    else if (k === Qt.Key_Up) selectAnim(animIndex - 1)
    else if (k === Qt.Key_Down) selectAnim(animIndex + 1)
    else return
    event.accepted = true
  }

  readonly property var tools: [
    { key: "pencil", label: "Pencil", glyph: "✎", hint: "B · right-click erases · Alt-click picks a colour" },
    { key: "eraser", label: "Eraser", glyph: "⌫", hint: "E" },
    { key: "fill", label: "Fill", glyph: "◧", hint: "G · fills the touching area of one colour" },
    { key: "line", label: "Line", glyph: "╱", hint: "L" },
    { key: "rect", label: "Box", glyph: "▢", hint: "R · hold Shift for a filled box" },
    { key: "picker", label: "Pick", glyph: "◉", hint: "I · takes the colour under the cursor" },
    { key: "move", label: "Move", glyph: "✥", hint: "V · drag to shift the whole frame (or animation)" }
  ]

  // ---------------------------------------------------------------- layout
  Item {
    id: fill
    anchors.fill: parent

    MouseArea {
      anchors.fill: parent
      onPressed: {} // the backdrop swallows clicks
    }

    Rectangle {
      id: card
      anchors.fill: parent
      anchors.margins: Style.space(36)
      radius: Style.cornerRadius
      color: Color.popups.background
      border.color: Color.popups.border
      border.width: Math.max(1, Style.space(2))
      focus: true
      Keys.onPressed: function(event) { win.handleKey(event) }

      // ---- top bar
      Item {
        id: topBar
        x: Style.spacing.panelPadding
        y: Style.spacing.panelPadding
        width: parent.width - Style.spacing.panelPadding * 2
        height: Math.max(title.implicitHeight, topButtons.implicitHeight)

        Text {
          id: title
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - topButtons.width - Style.spacing.lg
          elide: Text.ElideRight
          text: (win.view ? win.view.entry.name : win.packId) + "  ·  " + (win.file || "new drawing") + (win.dirty ? "  ●" : "")
          color: win.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Row {
          id: topButtons
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.md

          Button { text: "Undo"; bordered: true; enabled: win.historyTick >= 0 && win.undoStack.length > 0; opacity: enabled ? 1 : 0.4; tooltipText: "Ctrl+Z"; onClicked: win.undo() }
          Button { text: "Redo"; bordered: true; enabled: win.historyTick >= 0 && win.redoStack.length > 0; opacity: enabled ? 1 : 0.4; tooltipText: "Ctrl+Shift+Z"; onClicked: win.redo() }
          Button { text: win.saving ? "Saving…" : "Save"; bordered: true; selected: true; tooltipText: "Ctrl+S · writes the PNG; the pack rebuilds and the buddy updates"; onClicked: win.save(false) }
          Button { text: "Close"; bordered: true; tooltipText: "Esc"; onClicked: win.requestClose() }
        }
      }

      // ---- confirm / message strip
      Rectangle {
        id: strip
        anchors.top: topBar.bottom
        anchors.topMargin: visible ? Style.spacing.md : 0
        x: Style.spacing.panelPadding
        width: parent.width - Style.spacing.panelPadding * 2
        height: visible ? stripRow.implicitHeight + Style.spacing.md * 2 : 0
        visible: win.confirmClose || win.message !== ""
        radius: Style.cornerRadius
        color: win.confirmClose || win.messageError ? Qt.rgba(0.88, 0.69, 0.41, 0.15) : win.faint

        Row {
          id: stripRow
          anchors.verticalCenter: parent.verticalCenter
          x: Style.spacing.md
          spacing: Style.spacing.md

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: win.confirmClose ? "This drawing has unsaved changes." : win.message
            color: win.messageError && !win.confirmClose ? Color.urgent : win.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Button { visible: win.confirmClose; text: "Save and close"; bordered: true; selected: true; onClicked: { win.confirmClose = false; win.save(true) } }
          Button { visible: win.confirmClose; text: "Discard"; bordered: true; onClicked: win.service.closeSpriteEditor() }
          Button { visible: win.confirmClose; text: "Keep drawing"; bordered: true; onClicked: win.confirmClose = false }
        }
      }

      // ---- tools column
      Column {
        id: toolCol
        anchors.top: strip.bottom
        anchors.topMargin: Style.spacing.lg
        x: Style.spacing.panelPadding
        width: Style.space(96)
        spacing: Style.spacing.sm

        Repeater {
          model: win.tools
          Button {
            required property var modelData
            width: toolCol.width
            leftAlign: true
            text: modelData.glyph + "  " + modelData.label
            fontSize: Style.font.bodySmall
            bordered: true
            selected: win.tool === modelData.key
            tooltipText: modelData.hint
            onClicked: win.tool = modelData.key
          }
        }

        Item { width: 1; height: Style.spacing.md }

        Button { width: toolCol.width; leftAlign: true; text: "Mirror"; fontSize: Style.font.bodySmall; bordered: true; selected: win.mirrorDraw; tooltipText: "M · draw on both halves of the canvas at once"; onClicked: win.mirrorDraw = !win.mirrorDraw }
        Button { width: toolCol.width; leftAlign: true; text: "Onion"; fontSize: Style.font.bodySmall; bordered: true; selected: win.onion; tooltipText: "O · shows the previous frame faintly underneath"; onClicked: win.onion = !win.onion }
        Button { width: toolCol.width; leftAlign: true; text: "Grid"; fontSize: Style.font.bodySmall; bordered: true; selected: win.grid; onClicked: win.grid = !win.grid }
        Button { width: toolCol.width; leftAlign: true; text: "Guides"; fontSize: Style.font.bodySmall; bordered: true; selected: win.guides; tooltipText: "The pack's feet line and hitbox"; onClicked: win.guides = !win.guides }

        Item { width: 1; height: Style.spacing.md }

        Text {
          width: toolCol.width
          wrapMode: Text.WordWrap
          text: "Move and Flip act on"
          color: win.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Button { width: toolCol.width; leftAlign: true; text: win.wholeAnim ? "All frames" : "This frame"; fontSize: Style.font.bodySmall; bordered: true; selected: win.wholeAnim; onClicked: win.wholeAnim = !win.wholeAnim }
        Button { width: toolCol.width; leftAlign: true; text: "Flip ⇆"; fontSize: Style.font.bodySmall; bordered: true; tooltipText: "Mirror the pixels left to right"; onClicked: win.mapFrames(win.flipped) }
      }

      // ---- right column: preview, colours, animations
      Flickable {
        id: side
        anchors.top: strip.bottom
        anchors.topMargin: Style.spacing.lg
        anchors.bottom: timeline.top
        anchors.bottomMargin: Style.spacing.lg
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.panelPadding
        width: Style.space(290)
        contentWidth: width
        contentHeight: sideCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: sideCol
          width: side.width
          spacing: Style.spacing.md

          // Preview: the animation at its real speed
          Rectangle {
            width: parent.width
            height: previewCanvas.height + Style.spacing.md * 2
            radius: Style.cornerRadius
            color: Qt.darker(Color.popups.background, 1.35)

            Canvas {
              id: previewCanvas
              readonly property real pz: Math.max(1, Math.floor((parent.width - Style.spacing.md * 2) / win.cw))
              property int at: 0
              anchors.centerIn: parent
              width: win.cw * pz
              height: win.ch * pz
              onPaint: {
                var g = getContext("2d")
                g.clearRect(0, 0, width, height)
                var fr = win.frames[at % Math.max(1, win.frames.length)]
                win.paintPx(g, fr ? fr.px : null, pz, 1)
              }
              Timer {
                running: win.playing && win.frames.length > 1
                repeat: true
                interval: {
                  var fr = win.frames[previewCanvas.at % Math.max(1, win.frames.length)]
                  return Math.max(10, fr ? fr.ms : 100)
                }
                onTriggered: {
                  previewCanvas.at = (previewCanvas.at + 1) % win.frames.length
                  previewCanvas.requestPaint()
                }
              }
              Connections {
                target: win
                function onAnimsChanged() { previewCanvas.requestPaint() }
                function onAnimIndexChanged() { previewCanvas.at = 0; previewCanvas.requestPaint() }
                function onStrokeTickChanged() { previewCanvas.requestPaint() }
                function onPlayingChanged() { if (!win.playing) { previewCanvas.at = win.frameIndex; previewCanvas.requestPaint() } }
                function onFrameIndexChanged() { if (!win.playing) { previewCanvas.at = win.frameIndex; previewCanvas.requestPaint() } }
              }
            }
          }

          Row {
            spacing: Style.spacing.md
            Button { text: win.playing ? "Pause" : "Play"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "Space"; onClicked: win.playing = !win.playing }
            Button {
              text: "Play on buddy"
              bordered: true
              fontSize: Style.font.bodySmall
              tooltipText: "Plays the saved version of this animation on the buddy (save first)"
              onClicked: win.service.playRequest("", win.anim ? win.anim.name : "")
            }
          }

          PanelSeparator { width: parent.width; foreground: win.fg }

          // ---- colours
          Row {
            spacing: Style.spacing.md
            Rectangle {
              width: Style.space(40)
              height: width
              radius: Style.space(4)
              color: win.tool === "eraser" ? "transparent" : win.draft
              border.color: win.fg
              border.width: 1
              Text {
                anchors.centerIn: parent
                visible: win.tool === "eraser"
                text: "⌫"
                color: win.dim
                font.pixelSize: Style.font.body
              }
            }
            TextField {
              id: hexField
              width: Style.space(120)
              text: win.hexOf(win.rgbaOf(win.draft))
              onAccepted: {
                var c = win.parseHex(text)
                if (c) win.setDraft(c)
                card.forceActiveFocus()
              }
              onActiveFocusChanged: if (!activeFocus) text = Qt.binding(function() { return win.hexOf(win.rgbaOf(win.draft)) })
              Keys.onEscapePressed: card.forceActiveFocus()
            }
          }

          // Saturation / value square and hue strip
          Item {
            width: parent.width
            height: Style.space(120)

            Rectangle {
              id: svBox
              width: parent.width - hueBar.width - Style.spacing.md
              height: parent.height
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: "white" }
                GradientStop { position: 1; color: Qt.hsva(win.hue, 1, 1, 1) }
              }
              Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                  GradientStop { position: 0; color: "transparent" }
                  GradientStop { position: 1; color: "black" }
                }
              }
              Rectangle {
                x: win.sat * svBox.width - width / 2
                y: (1 - win.val) * svBox.height - height / 2
                width: Style.space(10)
                height: width
                radius: width / 2
                color: "transparent"
                border.color: win.val > 0.5 ? "black" : "white"
                border.width: 2
              }
              MouseArea {
                anchors.fill: parent
                function pick(m) {
                  win.setHsv(win.hue, Math.max(0, Math.min(1, m.x / width)), Math.max(0, Math.min(1, 1 - m.y / height)))
                  if (win.tool === "eraser" || win.tool === "picker") win.tool = "pencil"
                }
                onPressed: function(m) { pick(m) }
                onPositionChanged: function(m) { if (pressed) pick(m) }
              }
            }

            Rectangle {
              id: hueBar
              anchors.right: parent.right
              width: Style.space(18)
              height: parent.height
              gradient: Gradient {
                GradientStop { position: 0.0; color: "#ff0000" }
                GradientStop { position: 0.17; color: "#ffff00" }
                GradientStop { position: 0.33; color: "#00ff00" }
                GradientStop { position: 0.5; color: "#00ffff" }
                GradientStop { position: 0.67; color: "#0000ff" }
                GradientStop { position: 0.83; color: "#ff00ff" }
                GradientStop { position: 1.0; color: "#ff0000" }
              }
              Rectangle {
                y: win.hue * hueBar.height - 1
                width: parent.width
                height: 3
                color: "white"
                border.color: "black"
                border.width: 1
              }
              MouseArea {
                anchors.fill: parent
                function pick(m) {
                  win.setHsv(Math.max(0, Math.min(0.999, m.y / height)), win.sat, win.val)
                  if (win.tool === "eraser" || win.tool === "picker") win.tool = "pencil"
                }
                onPressed: function(m) { pick(m) }
                onPositionChanged: function(m) { if (pressed) pick(m) }
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Palette: every colour in this drawing. A new colour joins it the first time you draw with it."
            color: win.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Flow {
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: win.palette.length - 1
              Rectangle {
                required property int index
                readonly property int pi: index + 1
                width: Style.space(22)
                height: width
                radius: Style.space(3)
                readonly property var c: win.palette[pi] || [0, 0, 0, 0]
                color: Qt.rgba(c[0] / 255, c[1] / 255, c[2] / 255, c[3] / 255)
                border.color: pi === win.draftIndex && win.tool !== "eraser" ? win.fg : win.faint
                border.width: pi === win.draftIndex && win.tool !== "eraser" ? 2 : 1
                MouseArea {
                  anchors.fill: parent
                  onClicked: {
                    win.setDraft(win.palette[parent.pi])
                    if (win.tool === "eraser" || win.tool === "picker") win.tool = "pencil"
                  }
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: win.fg }

          // ---- animations
          Text {
            text: "ANIMATIONS"
            color: win.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Repeater {
            model: win.anims.length
            Rectangle {
              id: animRow
              required property int index
              readonly property var a: win.anims[index]
              readonly property bool current: index === win.animIndex
              width: sideCol.width
              height: animText.implicitHeight + Style.spacing.sm * 2
              radius: Style.space(4)
              color: current ? win.faint : "transparent"
              border.color: current ? Color.accent : "transparent"
              border.width: 1
              Text {
                id: animText
                anchors.verticalCenter: parent.verticalCenter
                x: Style.spacing.md
                width: parent.width - Style.spacing.md * 2
                elide: Text.ElideRight
                text: (animRow.a ? animRow.a.name : "") + "  ·  " + (animRow.a ? animRow.a.frames.length : 0)
                  + (animRow.a && animRow.a.frames.length === 1 ? " frame" : " frames")
                  + (animRow.a && win.others[animRow.a.name] ? "  ⚠ also in " + win.others[animRow.a.name] : "")
                color: animRow.a && win.others[animRow.a.name] ? win.warn : win.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                anchors.fill: parent
                onClicked: win.selectAnim(animRow.index)
              }
            }
          }

          Row {
            spacing: Style.spacing.sm
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "name"
              color: win.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            TextField {
              id: nameField
              width: sideCol.width - Style.space(48)
              text: win.anim ? win.anim.name : ""
              onAccepted: {
                if (!win.renameAnim(text)) text = win.anim ? win.anim.name : ""
                card.forceActiveFocus()
              }
              onActiveFocusChanged: if (!activeFocus) text = Qt.binding(function() { return win.anim ? win.anim.name : "" })
              Keys.onEscapePressed: card.forceActiveFocus()
            }
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.sm
            Button { text: "New"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "A new animation with one blank frame"; onClicked: win.addAnim(false) }
            Button { text: "Copy"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "A copy of this animation to start the next one from"; onClicked: win.addAnim(true) }
            Button {
              text: win.confirmDeleteAnim ? "Delete " + (win.anim ? win.anim.name : "") + "?" : "Delete"
              bordered: true
              fontSize: Style.font.bodySmall
              foreground: win.confirmDeleteAnim ? Color.urgent : Color.foreground
              onClicked: win.confirmDeleteAnim ? win.deleteAnim() : win.confirmDeleteAnim = true
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Name animations after what they're for (idle, walk, turn, drag, click-hop, sleep, work-thinking…) or anything you like, then set them in Edit pack → Roles. ⚠ means another file in the pack has the same name; the file whose name sorts last wins."
            color: win.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      // ---- canvas
      Rectangle {
        id: stageBox
        anchors.top: strip.bottom
        anchors.topMargin: Style.spacing.lg
        anchors.bottom: timeline.top
        anchors.bottomMargin: Style.spacing.lg
        anchors.left: toolCol.right
        anchors.leftMargin: Style.spacing.lg
        anchors.right: side.left
        anchors.rightMargin: Style.spacing.lg
        color: Qt.darker(Color.popups.background, 1.35)
        radius: Style.cornerRadius
        clip: true

        Text {
          anchors.centerIn: parent
          visible: !win.loaded
          text: win.messageError ? "" : "Opening…"
          color: win.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Flickable {
          id: flick
          anchors.fill: parent
          visible: win.loaded
          contentWidth: Math.max(width, stage.width + Style.space(48))
          contentHeight: Math.max(height, stage.height + Style.space(48))
          boundsBehavior: Flickable.StopAtBounds
          clip: true

          Item {
            id: stage
            x: (flick.contentWidth - width) / 2
            y: (flick.contentHeight - height) / 2
            width: win.cw * win.zoom
            height: win.ch * win.zoom

            // Checkerboard: transparent pixels
            Canvas {
              anchors.fill: parent
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              onPaint: {
                var g = getContext("2d")
                var s = Math.max(4, win.zoom * 4)
                for (var y = 0; y < height; y += s)
                  for (var x = 0; x < width; x += s) {
                    g.fillStyle = ((x + y) / s) % 2 ? "#d8d8dc" : "#f4f4f6"
                    g.fillRect(x, y, s, s)
                  }
              }
            }

            // The frame. Full repaints on anything but a stroke; a stroke repaints only dirtyPx.
            Canvas {
              id: art
              property bool full: true
              property var dirtyPx: []
              property int moveX: 0
              property int moveY: 0
              x: moveX * win.zoom
              y: moveY * win.zoom
              width: parent.width
              height: parent.height

              function repaintAll() {
                full = true
                requestPaint()
              }

              onPaint: {
                var g = getContext("2d")
                var z = win.zoom
                var px = win.frameObj ? win.frameObj.px : null
                var onionPx = win.onionPx
                if (full) {
                  full = false
                  dirtyPx = []
                  g.clearRect(0, 0, width, height)
                  if (onionPx) win.paintPx(g, onionPx, z, 0.28)
                  win.paintPx(g, px, z, 1)
                  return
                }
                var list = dirtyPx, cssList = win.paletteCss
                dirtyPx = []
                for (var k = 0; k < list.length; k++) {
                  var i = list[k], x = i % win.cw, y = Math.floor(i / win.cw)
                  g.clearRect(x * z, y * z, z, z)
                  if (onionPx && onionPx[i]) {
                    g.globalAlpha = 0.28
                    g.fillStyle = cssList[onionPx[i]]
                    g.fillRect(x * z, y * z, z, z)
                    g.globalAlpha = 1
                  }
                  if (px && px[i]) {
                    g.fillStyle = cssList[px[i]]
                    g.fillRect(x * z, y * z, z, z)
                  }
                }
              }

              Connections {
                target: win
                function onFrameObjChanged() { art.repaintAll() }
                function onOnionPxChanged() { art.repaintAll() }
                function onZoomChanged() { art.repaintAll() }
                function onAnimsChanged() { art.repaintAll() }
              }
              onWidthChanged: repaintAll()
            }

            // Line and box previews
            Canvas {
              id: ghost
              anchors.fill: parent
              property var pts: []
              property string fillCss: ""
              onPaint: {
                var g = getContext("2d")
                g.clearRect(0, 0, width, height)
                g.fillStyle = fillCss
                var z = win.zoom
                for (var k = 0; k < pts.length; k++) {
                  g.fillRect(pts[k][0] * z, pts[k][1] * z, z, z)
                  if (win.mirrorDraw) g.fillRect((win.cw - 1 - pts[k][0]) * z, pts[k][1] * z, z, z)
                }
              }
            }

            // Pixel grid, heavier every 8 pixels
            Canvas {
              anchors.fill: parent
              visible: win.grid && win.zoom >= 4
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              onPaint: {
                var g = getContext("2d")
                g.clearRect(0, 0, width, height)
                var z = win.zoom
                for (var x = 0; x <= win.cw; x++) {
                  g.fillStyle = x % 8 === 0 ? "rgba(0,0,0,0.22)" : "rgba(0,0,0,0.07)"
                  g.fillRect(x * z, 0, 1, height)
                }
                for (var y = 0; y <= win.ch; y++) {
                  g.fillStyle = y % 8 === 0 ? "rgba(0,0,0,0.22)" : "rgba(0,0,0,0.07)"
                  g.fillRect(0, y * z, width, 1)
                }
              }
            }

            // Mirror axis
            Rectangle {
              visible: win.mirrorDraw
              x: parent.width / 2 - 1
              width: 2
              height: parent.height
              color: Color.accent
              opacity: 0.6
            }

            // The pack's hitbox and feet line, in this drawing's pixels
            Rectangle {
              visible: win.guides && !!win.geo
              x: win.geo ? (win.geo.hitBox[0] - win.offX) * win.zoom : 0
              y: win.geo ? (win.geo.hitBox[1] - win.offY) * win.zoom : 0
              width: win.geo ? (win.geo.hitBox[2] - win.geo.hitBox[0]) * win.zoom : 0
              height: win.geo ? (win.geo.hitBox[3] - win.geo.hitBox[1]) * win.zoom : 0
              color: "transparent"
              border.color: Color.accent
              border.width: 1
              opacity: 0.7
            }
            Rectangle {
              visible: win.guides && win.feetRow > 0 && win.feetRow <= win.ch
              y: win.feetRow * win.zoom - 1
              width: parent.width
              height: 2
              color: win.feetColor
              Text {
                anchors.bottom: parent.top
                anchors.right: parent.right
                anchors.margins: 4
                text: "feet line"
                color: win.feetColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // Hovered pixel
            Rectangle {
              visible: win.hoverX >= 0 && win.tool !== "move"
              x: win.hoverX * win.zoom
              y: win.hoverY * win.zoom
              width: win.zoom
              height: win.zoom
              color: "transparent"
              border.color: "black"
              border.width: 1
              Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                color: "transparent"
                border.color: "white"
                border.width: 1
              }
            }

            MouseArea {
              id: drawArea
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              hoverEnabled: true
              preventStealing: true
              cursorShape: win.tool === "move" ? Qt.SizeAllCursor : Qt.CrossCursor

              property var px: null
              property int ink: 0
              property int sx: 0
              property int sy: 0
              property int lx: 0
              property int ly: 0
              property bool active: false

              function cell(m) { return [Math.floor(m.x / win.zoom), Math.floor(m.y / win.zoom)] }
              function inside(p) { return p[0] >= 0 && p[1] >= 0 && p[0] < win.cw && p[1] < win.ch }

              onPressed: function(m) {
                if (!win.loaded || !win.frameObj) return
                card.forceActiveFocus()
                var p = cell(m)
                sx = lx = p[0]
                sy = ly = p[1]
                var erase = m.button === Qt.RightButton || win.tool === "eraser"
                if (win.tool === "picker" || (m.modifiers & Qt.AltModifier)) {
                  if (!inside(p)) return
                  var c = win.frameObj.px[p[1] * win.cw + p[0]]
                  if (c) {
                    win.setDraft(win.palette[c])
                    if (win.tool === "eraser" || win.tool === "picker") win.tool = "pencil"
                  } else {
                    win.tool = "eraser"
                  }
                  return
                }
                if (win.tool === "move") {
                  active = true
                  return
                }
                ink = erase ? 0 : win.colorIndex(win.rgbaOf(win.draft))
                if (win.tool === "line" || win.tool === "rect") {
                  active = true
                  ghost.fillCss = ink ? win.paletteCss[ink] : "rgba(255,255,255,0.7)"
                  ghost.pts = [p]
                  ghost.requestPaint()
                  return
                }
                if (!inside(p)) return
                px = win.beginEdit()
                active = true
                if (win.tool === "fill") {
                  win.floodFill(px, p[0], p[1], ink)
                  active = false
                  art.requestPaint()
                  win.endStroke()
                  return
                }
                win.plot(px, p[0], p[1], ink)
                art.requestPaint()
              }

              onPositionChanged: function(m) {
                var p = cell(m)
                if (inside(p)) {
                  win.hoverX = p[0]
                  win.hoverY = p[1]
                } else {
                  win.hoverX = -1
                }
                if (!active) return
                if (win.tool === "move") {
                  art.moveX = p[0] - sx
                  art.moveY = p[1] - sy
                } else if (win.tool === "line" || win.tool === "rect") {
                  ghost.pts = win.tool === "line" ? win.linePoints(sx, sy, p[0], p[1])
                    : win.rectPoints(sx, sy, p[0], p[1], (m.modifiers & Qt.ShiftModifier) !== 0)
                  ghost.requestPaint()
                } else if (px) {
                  var pts = win.linePoints(lx, ly, p[0], p[1])
                  for (var k = 0; k < pts.length; k++) win.plot(px, pts[k][0], pts[k][1], ink)
                  art.requestPaint()
                }
                lx = p[0]
                ly = p[1]
              }

              onReleased: function(m) {
                if (!active) return
                active = false
                if (win.tool === "move") {
                  var dx = art.moveX, dy = art.moveY
                  art.moveX = 0
                  art.moveY = 0
                  if (dx || dy) win.mapFrames(function(p) { return win.shifted(p, dx, dy) })
                } else if (win.tool === "line" || win.tool === "rect") {
                  var pts = ghost.pts
                  ghost.pts = []
                  ghost.requestPaint()
                  var target = win.beginEdit()
                  for (var k = 0; k < pts.length; k++) win.plot(target, pts[k][0], pts[k][1], ink)
                  art.requestPaint()
                }
                px = null
                win.endStroke()
              }

              onExited: win.hoverX = -1

              onWheel: function(w) {
                if (w.modifiers & Qt.ControlModifier) {
                  win.userZoom = Math.max(1, Math.min(40, win.zoom + (w.angleDelta.y > 0 ? 1 : -1)))
                  w.accepted = true
                } else {
                  w.accepted = false
                }
              }
            }
          }
        }
      }

      // ---- timeline
      Item {
        id: timeline
        anchors.bottom: status.top
        anchors.bottomMargin: Style.spacing.md
        x: Style.spacing.panelPadding
        width: parent.width - Style.spacing.panelPadding * 2
        height: frameControls.implicitHeight + Style.spacing.md + thumbs.height

        Row {
          id: frameControls
          spacing: Style.spacing.md

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: (win.anim ? win.anim.name : "") + "  ·  frame " + (win.frameIndex + 1) + " / " + win.frames.length
            color: win.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Button { text: "+ Blank"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "Add an empty frame after this one"; onClicked: win.addFrame(false) }
          Button { text: "+ Copy"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "Alt+N · add a copy of this frame after it"; onClicked: win.addFrame(true) }
          Button { text: "Delete"; bordered: true; fontSize: Style.font.bodySmall; onClicked: win.deleteFrame() }
          Button { text: "◀"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "Move this frame earlier"; onClicked: win.moveFrame(-1) }
          Button { text: "▶"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "Move this frame later"; onClicked: win.moveFrame(1) }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "duration ms"
            color: win.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          NumberField {
            id: msField
            anchors.verticalCenter: parent.verticalCenter
            fieldWidth: Style.space(96)
            from: 10; to: 5000; stepSize: 10
            value: win.frameObj ? win.frameObj.ms : 100
            onModified: function(v) { if (win.frameObj && v !== win.frameObj.ms) win.setDuration(v, false) }
          }
          Button { text: "Use for all"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "Give every frame of this animation this duration"; onClicked: win.setDuration(win.frameObj ? win.frameObj.ms : 100, true) }
        }

        Flickable {
          id: thumbs
          anchors.top: frameControls.bottom
          anchors.topMargin: Style.spacing.md
          width: parent.width
          height: Style.space(104)
          contentWidth: thumbRow.width
          contentHeight: height
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Row {
            id: thumbRow
            spacing: Style.spacing.sm

            Repeater {
              model: win.frames.length

              Rectangle {
                id: thumb
                required property int index
                readonly property var fr: win.frames[index] || null
                readonly property real tz: Math.min(1, (thumbs.height - Style.space(28)) / win.ch)
                width: thumbCanvas.width + Style.space(8)
                height: thumbs.height
                radius: Style.space(4)
                color: index === win.frameIndex ? win.faint : "transparent"
                border.color: index === win.frameIndex ? Color.accent : win.faint
                border.width: index === win.frameIndex ? 2 : 1

                Rectangle {
                  x: Style.space(4)
                  y: Style.space(4)
                  width: thumbCanvas.width
                  height: thumbCanvas.height
                  color: "#e8e8ec"
                }
                Canvas {
                  id: thumbCanvas
                  x: Style.space(4)
                  y: Style.space(4)
                  width: Math.ceil(win.cw * thumb.tz)
                  height: Math.ceil(win.ch * thumb.tz)
                  onPaint: {
                    var g = getContext("2d")
                    g.clearRect(0, 0, width, height)
                    win.paintPx(g, thumb.fr ? thumb.fr.px : null, thumb.tz, 1)
                  }
                }
                onFrChanged: thumbCanvas.requestPaint()
                Connections {
                  target: win
                  function onStrokeTickChanged() { if (thumb.index === win.frameIndex) thumbCanvas.requestPaint() }
                }
                Text {
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.space(3)
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: (thumb.index + 1) + " · " + (thumb.fr ? thumb.fr.ms : 0) + " ms"
                  color: win.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: {
                    win.frameIndex = thumb.index
                    card.forceActiveFocus()
                  }
                }
              }
            }
          }
        }
      }

      // ---- status line
      Text {
        id: status
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.spacing.panelPadding
        x: Style.spacing.panelPadding
        width: parent.width - Style.spacing.panelPadding * 2
        elide: Text.ElideRight
        readonly property bool offFeet: win.guides && win.feetRow > 0 && win.frameBottom > 0 && win.frameBottom !== win.feetRow
        text: (win.hoverX >= 0 ? "x " + win.hoverX + "  y " + win.hoverY + "   " : "")
          + win.cw + "×" + win.ch + " at " + win.zoom + "×"
          + (win.frameBottom > 0 && win.feetRow > 0 ? "   lowest pixel ends on row " + win.frameBottom + (status.offFeet ? " · feet line is row " + win.feetRow + " (the buddy will " + (win.frameBottom < win.feetRow ? "float" : "sink") + ")" : " · on the feet line") : "")
          + "   ·   B E G L R I V tools · M mirror · O onion · ←/→ frames · ↑/↓ animations · Ctrl+C/V frame · Ctrl+wheel zoom"
        color: offFeet ? win.warn : win.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  readonly property int fitZoom: Math.max(1, Math.floor(Math.min((stageBox.width - Style.space(48)) / cw, (stageBox.height - Style.space(48)) / ch)))
  readonly property int zoom: userZoom > 0 ? userZoom : fitZoom

  Component.onCompleted: {
    card.forceActiveFocus()
    load()
  }
}
