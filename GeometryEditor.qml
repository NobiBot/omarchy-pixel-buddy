import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Feet line and hitbox editor for one pack. Opened from the bar widget's Geometry tab; lives
// in the service so it stays open when the popup closes. Every drag is pushed to
// service.geometryPreview, so the buddies on screen follow along; Save writes pack.json.
PanelWindow {
  id: win

  property var service
  property string packId: ""

  readonly property var view: service.packView(packId, true)
  readonly property var saved: view ? view.geometry : null
  readonly property int cw: saved ? saved.width : 128
  readonly property int ch: saved ? saved.height : 72
  readonly property var names: view ? view.names : []

  // Working copy in canvas pixels
  property var hitBox: saved ? saved.hitBox.slice() : [0, 0, 1, 1]
  property real feetY: saved ? saved.feetY : 0
  property string animName: view ? view.idleName : ""
  property int frame: 0
  property bool mirror: false

  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.55)
  readonly property color feetColor: "#9ece6a"
  readonly property color boxColor: Color.accent

  screen: {
    var screens = Quickshell.screens
    var first = (service.config.buddies || [])[0]
    var name = first ? service.screenName(first) : ""
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
    return screens.length ? screens[0] : null
  }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "pixel-buddy-geometry"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  implicitWidth: card.width
  implicitHeight: card.height

  function push() {
    service.geometryPreview = { packId: packId, hitBox: hitBox.slice(), feetY: feetY }
  }

  function clampBox(b) {
    var x0 = Math.max(0, Math.min(cw - 1, Math.round(Math.min(b[0], b[2]))))
    var y0 = Math.max(0, Math.min(ch - 1, Math.round(Math.min(b[1], b[3]))))
    var x1 = Math.max(x0 + 1, Math.min(cw, Math.round(Math.max(b[0], b[2]))))
    var y1 = Math.max(y0 + 1, Math.min(ch, Math.round(Math.max(b[1], b[3]))))
    return [x0, y0, x1, y1]
  }

  function setBox(b) {
    hitBox = clampBox(b)
    push()
  }

  function setFeet(y) {
    feetY = Math.max(1, Math.min(ch, Math.round(y)))
    push()
  }

  function autoFit() {
    var a = view && view.entry.animations[animName]
    if (!a || !a.bounds) return
    setBox(a.bounds)
    setFeet(a.bounds[3])
  }

  function reset() {
    if (!saved) return
    hitBox = saved.hitBox.slice()
    feetY = saved.feetY
    service.geometryPreview = null
  }

  // Canvas pixel <-> screen, accounting for the mirror preview
  readonly property real zoom: Math.max(1, Math.floor(Math.min(Style.space(820) / cw, Style.space(480) / ch)))
  function sx(px) { return (mirror ? cw - px : px) * zoom }
  function cx(x) { var p = x / zoom; return mirror ? cw - p : p }

  Rectangle {
    id: card
    width: content.implicitWidth + Style.spacing.panelPadding * 2
    height: content.implicitHeight + Style.spacing.panelPadding * 2
    radius: Style.cornerRadius
    color: Color.popups.background
    border.color: Color.popups.border
    border.width: Math.max(1, Style.space(2))
    focus: true

    Keys.onEscapePressed: win.service.closeGeometryEditor(false)
    Keys.onReturnPressed: win.service.closeGeometryEditor(true)
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Left) win.frame = Math.max(0, win.frame - 1)
      else if (event.key === Qt.Key_Right) win.frame = Math.min(img.frameCount - 1, win.frame + 1)
      else return
      event.accepted = true
    }

    Column {
      id: content
      x: Style.spacing.panelPadding
      y: Style.spacing.panelPadding
      spacing: Style.spacing.panelGap

      Item {
        width: stage.width
        height: Math.max(title.implicitHeight, controls.implicitHeight)

        Text {
          id: title
          anchors.verticalCenter: parent.verticalCenter
          text: (win.view ? win.view.entry.name : "") + "  ·  geometry"
          color: win.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Row {
          id: controls
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.md

          Dropdown {
            width: Style.space(180)
            showLabel: false
            options: win.names
            value: win.animName
            onChanged: function(v) { win.animName = v; win.frame = 0 }
          }
          Button {
            text: "‹"
            bordered: true
            onClicked: win.frame = Math.max(0, win.frame - 1)
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "frame " + (win.frame + 1) + " / " + Math.max(1, img.frameCount)
            color: win.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Button {
            text: "›"
            bordered: true
            onClicked: win.frame = Math.min(img.frameCount - 1, win.frame + 1)
          }
          Button {
            text: "Mirror"
            bordered: true
            selected: win.mirror
            onClicked: win.mirror = !win.mirror
          }
        }
      }

      Rectangle {
        id: stage
        width: win.cw * win.zoom
        height: win.ch * win.zoom
        color: Qt.darker(Color.popups.background, 1.35)
        clip: true

        AnimatedImage {
          id: img
          anchors.fill: parent
          source: win.service.animUrl(win.packId, win.animName)
          smooth: false
          cache: false
          playing: false
          currentFrame: Math.min(win.frame, Math.max(0, frameCount - 1))
          transform: Scale { origin.x: stage.width / 2; xScale: win.mirror ? -1 : 1 }
        }

        // Pixel grid every canvas pixel when zoomed far enough, heavier every 8
        Canvas {
          anchors.fill: parent
          visible: win.zoom >= 4
          onPaint: {
            var g = getContext("2d")
            g.clearRect(0, 0, width, height)
            for (var x = 0; x <= win.cw; x++) {
              g.fillStyle = x % 8 === 0 ? "rgba(255,255,255,0.10)" : "rgba(255,255,255,0.04)"
              g.fillRect(x * win.zoom, 0, 1, height)
            }
            for (var y = 0; y <= win.ch; y++) {
              g.fillStyle = y % 8 === 0 ? "rgba(255,255,255,0.10)" : "rgba(255,255,255,0.04)"
              g.fillRect(0, y * win.zoom, width, 1)
            }
          }
        }

        // Hitbox: drag inside to move, corners to resize
        Rectangle {
          id: box
          x: Math.min(win.sx(win.hitBox[0]), win.sx(win.hitBox[2]))
          y: win.hitBox[1] * win.zoom
          width: Math.abs(win.sx(win.hitBox[2]) - win.sx(win.hitBox[0]))
          height: (win.hitBox[3] - win.hitBox[1]) * win.zoom
          color: Qt.rgba(win.boxColor.r, win.boxColor.g, win.boxColor.b, 0.10)
          border.color: win.boxColor
          border.width: 2

          MouseArea {
            anchors.fill: parent
            anchors.margins: Style.space(10)
            cursorShape: Qt.SizeAllCursor
            property real px: 0
            property real py: 0
            property var start: null
            onPressed: function(m) {
              var p = mapToItem(stage, m.x, m.y)
              px = p.x; py = p.y; start = win.hitBox.slice()
            }
            onPositionChanged: function(m) {
              if (!start) return
              var p = mapToItem(stage, m.x, m.y)
              var dx = Math.round((p.x - px) / win.zoom) * (win.mirror ? -1 : 1)
              var dy = Math.round((p.y - py) / win.zoom)
              dx = Math.max(-start[0], Math.min(win.cw - start[2], dx))
              dy = Math.max(-start[1], Math.min(win.ch - start[3], dy))
              win.setBox([start[0] + dx, start[1] + dy, start[2] + dx, start[3] + dy])
            }
            onReleased: start = null
          }

          Text {
            anchors.bottom: parent.top
            anchors.bottomMargin: 4
            text: "hitbox · click, drag, speech bubble"
            color: win.boxColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Repeater {
          model: [[0, 1], [2, 1], [0, 3], [2, 3]]

          Rectangle {
            required property var modelData
            readonly property int ix: modelData[0]
            readonly property int iy: modelData[1]
            width: Style.space(12)
            height: width
            x: win.sx(win.hitBox[ix]) - width / 2
            y: win.hitBox[iy] * win.zoom - height / 2
            color: win.boxColor

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              cursorShape: Qt.CrossCursor
              onPositionChanged: function(m) {
                var p = mapToItem(stage, m.x, m.y)
                var b = win.hitBox.slice()
                b[parent.ix] = win.cx(p.x)
                b[parent.iy] = p.y / win.zoom
                win.setBox(b)
              }
            }
          }
        }

        // Feet line: drag up and down
        Rectangle {
          y: win.feetY * win.zoom - 1
          width: parent.width
          height: 2
          color: win.feetColor

          Text {
            anchors.bottom: parent.top
            anchors.left: parent.left
            anchors.margins: 6
            text: "feet · y " + Math.round(win.feetY)
            color: win.feetColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            anchors.fill: parent
            anchors.topMargin: -Style.space(6)
            anchors.bottomMargin: -Style.space(6)
            cursorShape: Qt.SizeVerCursor
            onPositionChanged: function(m) { win.setFeet(mapToItem(stage, m.x, m.y).y / win.zoom) }
          }
        }
      }

      Text {
        id: summary
        width: stage.width
        elide: Text.ElideRight
        text: "feetY " + Math.round(win.feetY) + "   hitBox " + win.hitBox.join(", ")
          + "   canvas " + win.cw + "×" + win.ch + "   ←/→ frames · Enter saves · Esc cancels"
        color: win.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Item {
        width: stage.width
        height: actions.implicitHeight

        Row {
          id: actions
          anchors.right: parent.right
          spacing: Style.spacing.md

          Button { text: "Fit to sprite"; bordered: true; tooltipText: "Hitbox around this animation's pixels, feet on its lowest row"; onClicked: win.autoFit() }
          Button { text: "Reset"; bordered: true; onClicked: win.reset() }
          Button { text: "Cancel"; bordered: true; onClicked: win.service.closeGeometryEditor(false) }
          Button { text: "Save"; bordered: true; selected: true; onClicked: win.service.closeGeometryEditor(true) }
        }
      }
    }
  }

  Component.onCompleted: card.forceActiveFocus()
}
