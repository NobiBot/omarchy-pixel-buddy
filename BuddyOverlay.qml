import QtQuick
import Quickshell
import Quickshell.Wayland

// One fullscreen transparent layer-shell window per screen; the buddy moves around / gets thrown inside it.
// The input region (mask) covers only the buddy's body and the speech bubble; clicks anywhere else pass through to the windows below.
// While the right-click menu is open the whole window takes input, and clicking empty space closes the menu.
PanelWindow {
  id: win

  property var service
  property var buddies: []

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }
  color: "transparent"
  // Normal + exclusiveZone 0: the window covers only the usable area and doesn't overlap the bar; its bottom edge is the buddy's ground
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: 0
  WlrLayershell.namespace: "pixel-buddy"
  WlrLayershell.layer: service.config.layer === "overlay" ? WlrLayer.Overlay : WlrLayer.Top
  WlrLayershell.keyboardFocus: chat.open || menu.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  visible: !service.hidden

  property var buddyRegions: []

  // PanelWindow's width/height alias the implicit size and stay 0 when anchored on all four sides; take the real size from an Item that fills the window
  Item {
    id: area
    anchors.fill: parent
  }
  readonly property real areaW: area.width
  readonly property real areaH: area.height

  function rebuildRegions() {
    var out = []
    for (var i = 0; i < buddyRepeater.count; i++) {
      var item = buddyRepeater.itemAt(i)
      if (item) out.push(item.hitRegion)
    }
    out.push(chatRegion)
    buddyRegions = out
  }

  Region {
    id: fullRegion
    x: 0
    y: 0
    width: win.areaW
    height: win.areaH
  }

  Region {
    id: chatRegion
    x: chat.x
    y: chat.y
    width: chat.open ? chat.width : 0
    height: chat.open ? chat.height : 0
  }

  mask: Region {
    regions: menu.open ? [fullRegion] : win.buddyRegions
  }

  Repeater {
    id: buddyRepeater
    model: win.buddies

    Buddy {
      required property var modelData
      cfg: modelData
      service: win.service
      overlay: win
    }

    onItemAdded: win.rebuildRegions()
    onItemRemoved: win.rebuildRegions()
  }

  function openMenu(buddy, px, py) {
    menu.show(buddy, px, py)
  }

  function openChat(buddy) {
    chat.show(buddy)
  }

  BuddyMenu {
    id: menu
    anchors.fill: parent
    service: win.service
  }

  ChatInput {
    id: chat
    service: win.service
    areaWidth: win.areaW
    areaHeight: win.areaH
  }
}
