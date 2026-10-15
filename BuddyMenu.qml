import QtQuick
import qs.Commons
import "lib/shared.mjs" as Shared

// Right-click menu: actions → categories → animations (tree from dsh-pet's buildMenuTree) + tool items.
// Columns open one level at a time; while open the overlay's whole window takes input, and clicking empty space or Esc closes it.
Item {
  id: menu

  property var service
  property bool open: false
  property var buddy: null
  property var tree: []
  // Index of the expanded node at each level: path[0] = selected item in the first column
  property var path: []
  property real originX: 0
  property real originY: 0

  readonly property int rowH: 26
  readonly property int colW: 168

  visible: open
  focus: open

  function show(targetBuddy, px, py) {
    buddy = targetBuddy
    var t = Shared.buildMenuTree(targetBuddy.anims)
    var tools = []
    if (targetBuddy.cfg.whisperEnabled !== false) tools.push({ label: service.tr(service.llmBusy ? "menuWhisperBusy" : "menuWhisper"), action: "whisper" })
    tools.push({ label: service.tr("menuChat"), action: "chat" })
    if (targetBuddy.cfg.balanceEnabled !== false) tools.push({ label: service.tr("menuUsage"), action: "usage" })
    tools.push({ label: service.tr("menuHome"), action: "home" })
    tools.push({ label: service.tr("menuReload"), action: "reload" })
    tools.push({ label: service.tr("menuHide"), action: "hide" })
    tree = t.concat(tools)
    path = []
    originX = px
    originY = py
    open = true
  }

  function close() {
    open = false
    path = []
  }

  function columnItems(level) {
    var items = tree
    for (var i = 0; i < level; i++) {
      var node = items[path[i]]
      if (!node || !node.children) return []
      items = node.children
    }
    return items
  }

  readonly property int columnCount: {
    var n = 1
    var items = tree
    for (var i = 0; i < path.length; i++) {
      var node = items[path[i]]
      if (!node || !node.children) break
      items = node.children
      n++
    }
    return n
  }

  function hover(level, index) {
    var next = path.slice(0, level)
    next.push(index)
    path = next
  }

  function activate(level, index) {
    var node = columnItems(level)[index]
    if (!node) return
    if (node.children) {
      hover(level, index)
      return
    }
    var target = buddy
    close()
    if (target) target.menuAction(node)
  }

  // Click on empty space closes
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onPressed: menu.close()
  }

  // Open to the left or right of the click: flip to the left when it doesn't fit
  readonly property bool flipLeft: originX + colW * Math.max(columnCount, 3) > width

  Repeater {
    model: menu.columnCount

    Rectangle {
      id: col
      required property int index
      readonly property var items: menu.columnItems(index)
      // A child column lines up with its parent's selected row, moving up if it would run off the bottom
      readonly property real wantY: index === 0 ? menu.originY : menu.originY + menu.rowOffset(index) * menu.rowH
      x: menu.flipLeft ? menu.originX - (index + 1) * menu.colW : menu.originX + index * menu.colW
      y: Math.max(4, Math.min(menu.height - height - 4, wantY))
      width: menu.colW
      height: Math.min(items.length * menu.rowH + 8, menu.height - 8)
      radius: Style.cornerRadius
      color: Color.menu.background
      border.color: Color.menu.border
      border.width: 1
      clip: true

      Flickable {
        anchors.fill: parent
        anchors.margins: 4
        contentHeight: list.height
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: list
          width: parent.width

          Repeater {
            model: col.items

            Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property bool selected: menu.path[col.index] === index
              width: list.width
              height: menu.rowH
              color: selected || area.containsMouse ? Color.menu.selectedBackground : "transparent"

              Text {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: arrow.left
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.label
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: row.selected ? Color.menu.selectedText : Color.menu.text
                font.family: Style.fontFamily
                font.pixelSize: 13
              }

              Text {
                id: arrow
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.children ? "›" : ""
                color: Color.menu.text
                font.pixelSize: 13
              }

              MouseArea {
                id: area
                anchors.fill: parent
                hoverEnabled: true
                onEntered: if (row.modelData.children) menu.hover(col.index, row.index)
                  else if (menu.path.length > col.index) menu.path = menu.path.slice(0, col.index)
                onClicked: menu.activate(col.index, row.index)
              }
            }
          }
        }
      }
    }
  }

  // Row that column `level` lines up with: the summed offsets of the selected rows in the columns before it
  function rowOffset(level) {
    var off = 0
    for (var i = 0; i < level; i++) off += path[i] || 0
    return off
  }

  Keys.onEscapePressed: close()
}
