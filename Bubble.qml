import QtQuick

// Speech bubble above the head: white rounded box with a small tail, optionally with a meme image. Takes no input (not in the overlay's mask).
// Style taken from dsh-pet's bubble.ts (92% white, #2b2b2b).
Item {
  id: bubble

  property var content: null // { text, meme }
  property url memeDir
  // Font: fontFile (path to a font file) > fontFamily (installed font name) > sans-serif
  property string fontFamily: ""
  property string fontFile: ""
  property int fontSize: 14
  property real tailX: width / 2
  property real maxTextWidth: 240

  // Keep the last content while fading out, so it doesn't go blank before disappearing
  property var shownContent: null
  onContentChanged: if (content) shownContent = content

  readonly property bool active: content !== null && content !== undefined
  opacity: active ? 1 : 0
  visible: opacity > 0
  Behavior on opacity {
    NumberAnimation {
      duration: 160
    }
  }

  readonly property int pad: 10
  width: body.width
  height: body.height + tail.height / 2

  FontLoader {
    id: loader
    source: bubble.fontFile ? "file://" + bubble.fontFile : ""
  }

  readonly property string resolvedFamily: loader.status === FontLoader.Ready ? loader.name
    : bubble.fontFamily || "sans-serif"

  Rectangle {
    id: body
    width: Math.max(label.width, meme.visible ? meme.width : 0) + bubble.pad * 2
    height: column.height + bubble.pad * 2
    radius: 12
    color: Qt.rgba(1, 1, 1, 0.94)
    border.color: Qt.rgba(0.17, 0.17, 0.17, 0.12)

    Column {
      id: column
      x: bubble.pad
      y: bubble.pad
      spacing: 6

      Text {
        id: label
        text: bubble.shownContent ? bubble.shownContent.text : ""
        // Content comes from agent sessions and model output and isn't trusted: always show it as plain text.
        // The default AutoText parses rich text when the first line looks like HTML, and remote URLs in <img> would be fetched.
        textFormat: Text.PlainText
        color: "#2b2b2b"
        font.family: bubble.resolvedFamily
        font.pixelSize: bubble.fontSize
        lineHeight: 1.25
        wrapMode: Text.Wrap
        width: Math.min(implicitWidth, bubble.maxTextWidth)
      }

      Image {
        id: meme
        readonly property string name: bubble.shownContent && bubble.shownContent.meme ? bubble.shownContent.meme : ""
        visible: name !== "" && status === Image.Ready
        source: name ? bubble.memeDir + name + ".png" : ""
        width: 110
        height: visible ? width * (implicitHeight / Math.max(1, implicitWidth)) : 0
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: true
      }
    }
  }

  Rectangle {
    id: tail
    width: 12
    height: 12
    rotation: 45
    color: body.color
    x: Math.max(body.radius, Math.min(body.width - body.radius - width, bubble.tailX - width / 2))
    y: body.height - height / 2 - 1
    z: -1
  }
}
