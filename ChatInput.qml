import QtQuick
import qs.Commons

// Input box for the right-click "Chat" item: Enter sends, Esc closes. While open the overlay takes the keyboard.
// Replies are shown by Service.speak the same way as murmurs (talking animation + bubble).
Rectangle {
  id: chat

  property var service
  property var buddy: null
  property bool open: false
  property real areaWidth: 0
  property real areaHeight: 0

  visible: open
  width: 260
  height: 40
  radius: Style.cornerRadius
  color: Color.popups.background
  border.color: Color.popups.border
  border.width: 1

  function show(targetBuddy) {
    buddy = targetBuddy
    // Next to the top-right corner of the body hitbox, clamped back if it goes off screen
    var px = targetBuddy.x + targetBuddy.hitX + targetBuddy.hitW + 6
    var py = targetBuddy.y + targetBuddy.hitY + 6
    x = Math.max(4, Math.min(areaWidth - width - 4, px))
    y = Math.max(4, Math.min(areaHeight - height - 4, py))
    input.text = ""
    open = true
    input.forceActiveFocus()
  }

  function close() {
    open = false
    buddy = null
  }

  TextInput {
    id: input
    anchors.fill: parent
    anchors.margins: 10
    verticalAlignment: TextInput.AlignVCenter
    color: Color.popups.text
    font.family: Style.fontFamily
    font.pixelSize: 14
    clip: true
    focus: chat.open

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: input.text === ""
      text: chat.service ? chat.service.tr(chat.service.llmBusy ? "chatBusy" : "chatPlaceholder") : ""
      color: Color.muted
      font: input.font
    }

    Keys.onReturnPressed: send()
    Keys.onEnterPressed: send()
    Keys.onEscapePressed: chat.close()

    function send() {
      var text = input.text.trim()
      if (!text || !chat.buddy) return
      var r = chat.service.requestChat(chat.buddy.cfg.id, text)
      if (r === "busy") return
      chat.buddy.showBubble("……", "", 0)
      chat.close()
    }
  }
}
