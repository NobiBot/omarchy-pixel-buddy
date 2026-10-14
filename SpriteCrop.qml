import QtQuick

// One animation of a pack, fitted into this item: the whole canvas, or cropped to the
// animation's visible pixels (`crop`) for icons and thumbnails. Whole-number zoom when it
// fits, so pixel art stays crisp.
Item {
  id: root

  property var service
  property string packId: ""
  property string anim: ""
  property bool playing: false
  // Crop to this animation's visible pixels, or (`cropPack`) to all of the pack's animations
  // together, which keeps the sprite still while switching animations.
  property bool crop: false
  property bool cropPack: false
  property bool mirror: false
  readonly property int status: playing ? img.status : still.status

  readonly property var entry: service && packId ? service.packIndex[packId] : null
  readonly property var canvas: entry && entry.canvas ? entry.canvas : [128, 72]
  readonly property var info: entry && anim && entry.animations ? entry.animations[anim] : null
  // Region of the canvas to show, in canvas pixels
  readonly property var packBounds: {
    var anims = entry ? entry.animations || {} : {}
    var u = null
    for (var n in anims) {
      var b = anims[n].bounds
      if (!b) continue
      u = u ? [Math.min(u[0], b[0]), Math.min(u[1], b[1]), Math.max(u[2], b[2]), Math.max(u[3], b[3])] : b.slice()
    }
    return u ? [Math.max(0, u[0] - 2), Math.max(0, u[1] - 2), Math.min(canvas[0], u[2] + 2), Math.min(canvas[1], u[3] + 2)] : null
  }
  readonly property var region: cropPack && packBounds ? packBounds
    : crop && info && info.bounds ? info.bounds : [0, 0, canvas[0], canvas[1]]
  readonly property real rw: Math.max(1, region[2] - region[0])
  readonly property real rh: Math.max(1, region[3] - region[1])
  readonly property real fit: Math.min(width / rw, height / rh)
  readonly property real zoom: fit >= 1 ? Math.floor(fit) : fit
  // Only animations this pack has: packId and anim can update one binding apart
  readonly property string url: service && info ? service.animUrl(packId, anim) : ""
  readonly property real imgX: Math.round((width - rw * zoom) / 2 - region[0] * zoom)
  readonly property real imgY: Math.round((height - rh * zoom) / 2 - region[1] * zoom)

  clip: true

  // Paused sprites use a plain Image: a paused AnimatedImage keeps showing the old frame
  // after its file is rebuilt, even with a new URL. AnimatedImage only while playing.
  Image {
    id: still
    visible: !root.playing
    source: !root.playing ? root.url : ""
    asynchronous: true
    cache: false
    smooth: root.zoom < 1
    width: root.canvas[0] * root.zoom
    height: root.canvas[1] * root.zoom
    x: root.imgX
    y: root.imgY
    transform: Scale {
      origin.x: (root.region[0] + root.rw / 2) * root.zoom
      xScale: root.mirror ? -1 : 1
    }
  }

  AnimatedImage {
    id: img
    visible: root.playing
    source: root.playing ? root.url : ""
    asynchronous: true
    cache: false
    smooth: root.zoom < 1
    playing: root.playing && status === AnimatedImage.Ready
    width: root.canvas[0] * root.zoom
    height: root.canvas[1] * root.zoom
    x: root.imgX
    y: root.imgY
    transform: Scale {
      origin.x: (root.region[0] + root.rw / 2) * root.zoom
      xScale: root.mirror ? -1 : 1
    }
  }
}
