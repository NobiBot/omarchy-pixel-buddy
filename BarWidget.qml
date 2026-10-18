import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "lib/packs.mjs" as Packs
import "lib/phrases.mjs" as Phrases

// Bar icon + popup for sprite packs: browse packs, pick one per buddy, create one from the
// Aseprite template, and edit a pack's role mapping, behavior, geometry, drawings and info.
// All state lives in the pixel-buddy service (Service.qml); this file is only the UI.
//
// Bar icon: first frame of the active buddy's idle animation. Left click opens the popup,
// right click hides / shows the buddies. IPC: omarchy-shell pixel-buddy-studio toggle
Panel {
  id: root

  moduleName: "nobi.pixel-buddy"
  ipcTarget: "pixel-buddy-studio"
  manageIpc: false

  // The service is created by the shell next to this widget; look it up until it exists.
  property var service: null
  function findService() {
    if (service) return
    var sh = bar ? bar.shell : null
    var s = sh && typeof sh.serviceFor === "function" ? sh.serviceFor("nobi.pixel-buddy") : null
    if (s) service = s
  }
  Timer {
    interval: 500
    repeat: true
    running: !root.service
    triggeredOnStart: true
    onTriggered: root.findService()
  }

  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.55)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.10)
  readonly property color warn: "#e0af68"
  readonly property color bad: Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- state
  property string buddyChoice: ""
  property string browsePack: ""
  property string mode: "home" // home | edit
  property string tab: "roles"
  property string previewRole: "idle"
  property string previewAnim: ""
  property bool creating: false
  property bool confirmDelete: false
  // Shown after clicking Aseprite when it isn't installed: points to other editors
  property bool asepriteHelp: false
  // The phrase field being typed in, so arrow keys and Escape go to the text (nulls itself when the field is destroyed)
  property Item phraseField: null
  // Right-click menu on a pack thumbnail
  property string menuPack: ""
  property bool menuConfirm: false
  property point menuAt: Qt.point(0, 0)

  function openPackMenu(id, item) {
    menuAt = item.mapToItem(keyCatcher, 0, item.height + Style.spacing.sm)
    menuConfirm = false
    menuPack = id
  }

  function deletePack(id) {
    menuPack = ""
    service.deletePack(id, function() {
      if (root.browsePack === id) root.browsePack = ""
      root.mode = "home"
    })
  }

  readonly property var buddies: service ? (service.config.buddies || []) : []
  readonly property string buddyId: buddyChoice && buddies.some(function(p) { return p.id === buddyChoice }) ? buddyChoice : (buddies.length ? buddies[0].id : "")
  readonly property var buddy: buddies.filter(function(p) { return p.id === root.buddyId })[0] || null
  readonly property string buddyName: buddy ? (buddy.name || buddy.id) : ""
  readonly property string buddyPack: service && buddyId ? service.buddyPackId(buddyId) : ""
  readonly property string packId: service && browsePack && service.packIndex[browsePack] ? browsePack : buddyPack
  readonly property var view: service && packId ? service.packView(packId) : null
  readonly property var iconView: service && buddyPack ? service.packView(buddyPack) : null
  readonly property bool inUse: packId !== "" && packId === buddyPack
  readonly property bool busy: service ? service.busyPack !== "" && service.busyPack === packId : false

  // Roles that have something to show, for the ‹ › cycling in the preview
  readonly property var mappedRoles: view ? Packs.ROLES.filter(function(r) { return view.resolved.roles[r.key].length > 0 }) : []
  readonly property var shownRole: Packs.ROLES.filter(function(r) { return r.key === root.previewRole })[0] || Packs.ROLES[0]
  readonly property string shownAnim: {
    if (!view) return ""
    if (previewAnim && view.names.indexOf(previewAnim) >= 0) return previewAnim
    var list = view.resolved.roles[shownRole.key] || []
    return list.length ? list[0] : view.idleName
  }

  function roleLabel(key) {
    var r = Packs.ROLES.filter(function(x) { return x.key === key })[0]
    return r ? r.label : key
  }

  function stepRole(d) {
    var list = mappedRoles
    if (!list.length) return
    var i = list.findIndex(function(r) { return r.key === root.previewRole })
    previewRole = list[((i < 0 ? 0 : i + d) % list.length + list.length) % list.length].key
    previewAnim = ""
  }

  function showPack(id) {
    browsePack = id
    previewRole = "idle"
    previewAnim = ""
    confirmDelete = false
    asepriteHelp = false
  }

  function usePack() {
    if (service && packId) service.setBuddyPack(buddyId, packId)
  }

  function formatsOf(entry) {
    var seen = []
    ;(entry ? entry.sources : []).forEach(function(s) {
      var f = s.format === "sheet" ? "png sheet" : s.format
      if (seen.indexOf(f) < 0) seen.push(f)
    })
    return seen.join(", ") || "no sources"
  }

  function statusText() {
    if (!view) return ""
    var e = view.entry
    if (busy || e.status === "building") return "building…"
    if (e.status === "stale") return "changed, rebuilding soon"
    if (e.status === "error" || e.status === "unbuilt") return e.errors.length ? e.errors[0] : "not built yet"
    return ""
  }

  function updatePack(fn) {
    if (service && packId) service.updatePack(packId, fn)
  }

  function setBehavior(kind, name, value) {
    updatePack(function(pj) {
      pj.behavior = pj.behavior || {}
      pj.behavior[kind] = pj.behavior[kind] || {}
      if (value === null) delete pj.behavior[kind][name]
      else pj.behavior[kind][name] = value
    })
  }

  // The selected pack's random chain: { name: { kind, chance, set } } for the Behavior tab's chance fields
  readonly property var chain: {
    var out = {}
    if (!root.view || !root.service) return out
    var roles = root.view.resolved.roles
    Packs.chainChances(roles, root.view.pack.behavior, Packs.buildWeights(root.service.config.animationWeights, roles))
      .forEach(function(e) { out[e.name] = e })
    return out
  }

  // Work-status lines, labelled like the Roles tab's work states
  readonly property var workLabels: Packs.ROLES.filter(function(r) { return r.group === "work" }).map(function(r) { return r.label })

  readonly property bool customPhrases: !!root.view && Array.isArray(root.view.pack.phrases)
  readonly property var phrases: root.view && root.service ? root.service.packPhrases(root.view.pack) : []

  // One edit to a list of lines: i < 0 adds `change.text`; change null removes line i;
  // otherwise change.text and/or change.chance (null = share the rest) replace line i's.
  function changedLines(lines, i, change) {
    var out = (lines || []).slice()
    if (i < 0) out.push(change.text)
    else if (change === null) out.splice(i, 1)
    else out[i] = Phrases.makeLine(change.text !== undefined ? change.text : Phrases.lineText(out[i]),
                                   change.chance !== undefined ? change.chance : Phrases.lineChance(out[i]))
    return out
  }

  // Writes the selected pack's work-status lines. The first edit copies the config's lines into the pack.
  function setPhrase(state, i, change) {
    var src = phrases
    var texts = workLabels.map(function(_, k) { return k === state ? root.changedLines(src[k], i, change) : (src[k] || []).slice() })
    updatePack(function(pj) { pj.phrases = texts })
  }

  // Lines for animations, by tag name; a pack lists every animation it has, custom names included
  readonly property var animPhrases: root.view && root.service ? root.service.packAnimPhrases(root.view.pack) : ({})

  function setAnimPhrase(name, i, change) {
    var lines = changedLines(animPhrases[name], i, change)
    updatePack(function(pj) {
      var all = Object.assign({}, root.service.packAnimPhrases(pj))
      if (lines.length) all[name] = lines
      else delete all[name]
      if (Object.keys(all).length) pj.animPhrases = all
      else delete pj.animPhrases
    })
  }

  // Which roles an animation plays as, for the Phrases tab ("random actions, click reactions")
  function animRoles(name) {
    if (!view) return ""
    return Packs.ROLES.filter(function(r) { return view.resolved.roles[r.key].indexOf(name) >= 0 })
      .map(function(r) { return r.label }).join(", ")
  }

  // Sections of the Phrases tab: the six work states, then each animation. Rebuilt only when the
  // animation names change (not on every save), so a field keeps its focus while you add lines.
  readonly property string phraseAnimKey: view ? view.names.join("\n") : ""
  readonly property var phraseSections: {
    var out = workLabels.map(function(l, k) { return { kind: "work", key: k, title: l.toUpperCase(), first: k === 0 } })
    var names = phraseAnimKey ? phraseAnimKey.split("\n") : []
    names.forEach(function(n, i) { out.push({ kind: "anim", key: n, title: n, first: i === 0 }) })
    return out
  }

  function setSectionLine(section, i, change) {
    if (section.kind === "work") setPhrase(section.key, i, change)
    else setAnimPhrase(section.key, i, change)
  }

  function edit(t) {
    mode = "edit"
    tab = ["roles", "behavior", "geometry", "phrases", "info"].indexOf(t) >= 0 ? t : "roles"
    asepriteHelp = false
    confirmDelete = false
    flick.contentY = 0
  }

  // omarchy-shell pixel-buddy-studio toggle | open | close | edit [roles|behavior|geometry|phrases|info]
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function edit(tab: string): void {
      if (!root.opened) root.open()
      Qt.callLater(function() { root.edit(tab) })
    }
  }

  onOpenedChanged: if (opened) {
    findService()
    if (service) service.checkSetup()
    mode = "home"
    creating = false
    confirmDelete = false
    asepriteHelp = false
    menuPack = ""
    if (browsePack && service && !service.packIndex[browsePack]) browsePack = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------------------------------------------------------------- bar icon
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰩃"
    tooltipText: root.service ? "Pixel Buddy · " + (root.iconView ? root.iconView.entry.name : "no pack")
      + (root.service.hidden ? " (hidden)" : "") + "\nRight-click to " + (root.service.hidden ? "show" : "hide") + " the buddy" : "Pixel Buddy"
    iconComponent: root.iconView ? iconComp : null
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && root.service) root.service.hidden = !root.service.hidden
      else root.toggle()
    }
  }

  Component {
    id: iconComp
    SpriteCrop {
      service: root.service
      packId: root.buddyPack
      anim: root.iconView ? root.iconView.idleName : ""
      crop: true
      opacity: root.service && root.service.hidden ? 0.45 : 1
    }
  }

  // ---------------------------------------------------------------- popup
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: newName.activeFocus || nameField.activeFocus || authorField.activeFocus || (root.phraseField !== null && root.phraseField.activeFocus)

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.stepRole(dx)
        if (dy !== 0) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy * Style.space(48)))
      }
      onCloseRequested: {
        if (root.menuPack !== "") root.menuPack = ""
        else if (root.mode !== "home") root.mode = "home"
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        onContentYChanged: root.menuPack = ""

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          Text {
            textFormat: Text.PlainText
            visible: !root.service
            width: parent.width
            text: "The buddy service isn't running. Check that nobi.pixel-buddy is enabled in shell.json."
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // ---------- header
          Item {
            visible: !!root.service
            width: parent.width
            height: Math.max(titleText.implicitHeight, buddyPicker.height, backBtn.height)

            Button {
              id: backBtn
              visible: root.mode !== "home"
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "‹ Packs"
              bordered: true
              fontSize: Style.font.bodySmall
              onClicked: root.mode = "home"
            }

            Text {
              textFormat: Text.PlainText
              id: titleText
              anchors.left: root.mode !== "home" ? backBtn.right : parent.left
              anchors.leftMargin: root.mode !== "home" ? Style.spacing.lg : 0
              anchors.right: buddyPicker.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.mode === "edit" && root.view ? root.view.entry.name : "Pixel Buddy"
              elide: Text.ElideRight
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Dropdown {
              id: buddyPicker
              visible: root.buddies.length > 1 && root.mode === "home"
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(140)
              showLabel: false
              options: root.buddies.map(function(p) { return { value: p.id, label: "buddy: " + (p.name || p.id) } })
              value: root.buddyId
              onChanged: function(v) {
                root.buddyChoice = v
                root.browsePack = ""
                value = Qt.binding(function() { return root.buddyId })
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.mode === "edit"
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.service && root.service.savePending(root.packId) ? "saving…" : "saved"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- first-run setup: Pillow (needed to build packs) and the agent hooks (asks first)
          Rectangle {
            id: setupCard
            readonly property bool needPillow: !!root.service && root.service.pillowMissing
            readonly property var agents: root.service ? root.service.agentsToConnect : []
            visible: root.mode === "home" && (needPillow || (agents.length > 0 && !root.service.setupDismissed))
            width: parent.width
            height: visible ? setupCol.implicitHeight + Style.spacing.md * 2 : 0
            radius: Style.cornerRadius
            color: Qt.rgba(root.warn.r, root.warn.g, root.warn.b, 0.12)
            border.color: root.warn
            border.width: 1

            Column {
              id: setupCol
              x: Style.spacing.md
              y: Style.spacing.md
              width: parent.width - Style.spacing.md * 2
              spacing: Style.spacing.md

              Text {
                textFormat: Text.PlainText
                text: "Finish setup"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                visible: setupCard.needPillow
                width: parent.width
                wrapMode: Text.WordWrap
                text: "The buddy needs Pillow (python-pillow) to build its animations. Install opens a terminal that asks for your password; the buddy appears a few seconds after it finishes."
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                textFormat: Text.PlainText
                visible: setupCard.agents.length > 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Connect " + setupCard.agents.map(function(a) { return a === "codex" ? "Codex" : "Claude Code" }).join(" and ")
                  + " so the buddy acts out what your agent is doing. This adds hooks to "
                  + setupCard.agents.map(function(a) { return a === "codex" ? "~/.codex/hooks.json" : "~/.claude/settings.json" }).join(" and ")
                  + " (backed up first)."
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Flow {
                width: parent.width
                spacing: Style.spacing.md
                Button {
                  visible: setupCard.needPillow
                  text: "Install Pillow"
                  bordered: true
                  selected: true
                  fontSize: Style.font.bodySmall
                  onClicked: root.service.installPillow()
                }
                Button {
                  visible: setupCard.agents.length > 0
                  text: root.service && root.service.hooksBusy ? "Connecting…" : "Connect " + (setupCard.agents.length > 1 ? "agents" : setupCard.agents[0] === "codex" ? "Codex" : "Claude Code")
                  bordered: true
                  selected: !setupCard.needPillow
                  fontSize: Style.font.bodySmall
                  onClicked: root.service.connectAgents()
                }
                Button {
                  visible: !setupCard.needPillow
                  text: "Not now"
                  bordered: true
                  fontSize: Style.font.bodySmall
                  tooltipText: "Hide this; Connect stays on the home screen"
                  onClicked: root.service.dismissSetup()
                }
              }
            }
          }

          // ---------- preview
          Rectangle {
            id: hero
            visible: !!root.view
            width: parent.width
            height: root.mode === "edit" ? Style.space(110) : Math.round(width * 9 / 16 * 0.62)
            radius: Style.cornerRadius
            color: root.faint

            SpriteCrop {
              anchors.fill: parent
              anchors.margins: Style.spacing.md
              service: root.service
              packId: root.packId
              anim: root.shownAnim
              playing: root.opened
              cropPack: true
            }

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.margins: Style.spacing.md
              width: roleChip.implicitWidth + Style.spacing.lg * 2
              height: roleChip.implicitHeight + Style.spacing.sm * 2
              radius: Style.cornerRadius
              color: Color.popups.background
              opacity: 0.92
              Text {
                textFormat: Text.PlainText
                id: roleChip
                anchors.centerIn: parent
                text: root.previewAnim ? root.previewAnim : root.roleLabel(root.shownRole.key) + " ← " + (root.shownAnim || "nothing")
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.spacing.md
              spacing: Style.spacing.xs
              Button { text: "‹"; bordered: true; fontSize: Style.font.bodySmall; onClicked: root.stepRole(-1) }
              Button { text: "›"; bordered: true; fontSize: Style.font.bodySmall; onClicked: root.stepRole(1) }
            }
          }

          // ======================================================= HOME
          Column {
            visible: !!root.view && root.mode === "home"
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              height: Math.max(nameCol.implicitHeight, useBtn.height)

              Column {
                id: nameCol
                anchors.left: parent.left
                anchors.right: useBtn.left
                anchors.rightMargin: Style.spacing.lg
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xxs
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.view ? root.view.entry.name : ""
                  elide: Text.ElideRight
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.view ? (root.view.entry.author ? "by " + root.view.entry.author + " · " : "") + root.formatsOf(root.view.entry) : ""
                  elide: Text.ElideRight
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Button {
                id: useBtn
                visible: !root.inUse
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Use for " + root.buddyName
                bordered: true
                selected: true
                onClicked: root.usePack()
              }
              Text {
                textFormat: Text.PlainText
                visible: root.inUse
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "● in use"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Item {
              width: parent.width
              height: mappedText.implicitHeight
              Text {
                textFormat: Text.PlainText
                id: mappedText
                anchors.left: parent.left
                text: root.view ? root.view.resolved.mapped + " / " + root.view.resolved.total + " roles mapped" : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                readonly property int missing: root.view ? root.view.resolved.total - root.view.resolved.mapped : 0
                text: missing > 0 ? missing + " not mapped (skipped)" : "all set"
                color: missing > 0 ? root.warn : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.statusText()
              wrapMode: Text.WordWrap
              color: root.view && (root.view.entry.status === "error" || root.view.entry.status === "unbuilt") ? root.bad : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            PanelSectionHeader {
              width: parent.width
              text: "PACKS"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Flickable {
              width: parent.width
              height: thumbs.height
              contentWidth: thumbs.width
              clip: true
              flickableDirection: Flickable.HorizontalFlick
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentWidth > width
              onContentXChanged: root.menuPack = ""

              Row {
                id: thumbs
                spacing: Style.spacing.md

                Repeater {
                  model: root.service ? root.service.packList : []

                  Rectangle {
                    id: thumb
                    required property var modelData
                    readonly property bool current: modelData.id === root.packId
                    readonly property var tview: root.service.packView(modelData.id)
                    width: Style.space(76)
                    height: Style.space(76)
                    radius: Style.cornerRadius
                    color: thumbHover.hovered ? root.faint : "transparent"
                    border.width: current ? 2 : 1
                    border.color: current ? Color.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)

                    SpriteCrop {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.bottom: thumbName.top
                      anchors.margins: Style.spacing.sm
                      service: root.service
                      packId: thumb.modelData.id
                      anim: thumb.tview ? thumb.tview.idleName : ""
                      crop: true
                      playing: thumbHover.hovered
                    }
                    Text {
                      textFormat: Text.PlainText
                      id: thumbName
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: Style.spacing.sm
                      anchors.horizontalCenter: parent.horizontalCenter
                      width: parent.width - Style.spacing.md * 2
                      horizontalAlignment: Text.AlignHCenter
                      text: thumb.modelData.name
                      elide: Text.ElideRight
                      color: thumb.current ? root.fg : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Rectangle {
                      visible: root.service.buddyPackId(root.buddyId) === thumb.modelData.id
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.margins: Style.spacing.sm
                      width: Style.space(7); height: width; radius: width / 2
                      color: Color.accent
                    }
                    HoverHandler { id: thumbHover }
                    TapHandler {
                      onTapped: root.showPack(thumb.modelData.id)
                      onDoubleTapped: { root.showPack(thumb.modelData.id); root.usePack() }
                    }
                    TapHandler {
                      acceptedButtons: Qt.RightButton
                      onTapped: root.openPackMenu(thumb.modelData.id, thumb)
                    }
                  }
                }

                Rectangle {
                  width: Style.space(76)
                  height: Style.space(76)
                  radius: Style.cornerRadius
                  color: newHover.hovered ? root.faint : "transparent"
                  border.width: 1
                  border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)
                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: "+ New"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  HoverHandler { id: newHover }
                  TapHandler {
                    onTapped: {
                      root.creating = true
                      newName.text = ""
                      Qt.callLater(function() { newName.forceActiveFocus() })
                    }
                  }
                }
              }
            }

            // New pack from the Aseprite template
            Row {
              visible: root.creating
              width: parent.width
              spacing: Style.spacing.md
              TextField {
                id: newName
                width: parent.width - createBtn.width - cancelBtn.width - parent.spacing * 2
                placeholderText: "Name of the new buddy"
                onAccepted: createBtn.clicked()
                Keys.onEscapePressed: root.creating = false
              }
              Button {
                id: createBtn
                text: "Create"
                bordered: true
                selected: true
                onClicked: {
                  var name = newName.text.trim()
                  if (!name) return
                  root.creating = false
                  // A new pack goes straight onto the buddy, so saves in Aseprite show up there
                  root.service.newPack(name, function(id) {
                    root.service.setBuddyPack(root.buddyId, id, true)
                    root.showPack(id)
                    if (!root.service.asepriteInstalled)
                      root.service.showPackMessage("Created " + name + ". Open its Folder and draw idle.png in any pixel-art editor.", false)
                  })
                }
              }
              Button { id: cancelBtn; text: "Cancel"; bordered: true; onClicked: root.creating = false }
            }
            Text {
              textFormat: Text.PlainText
              visible: root.creating
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.service && !root.service.asepriteInstalled
                ? "Makes a pack with a blank 128×72 idle.png and puts it on the buddy. Draw it in any pixel-art editor (Folder opens the pack); saving updates the buddy."
                : "Opens a blank 128×72 canvas in Aseprite with an idle tag, and puts it on the buddy. Draw, save, and the buddy updates. Add a tag per animation; the Roles tab maps them."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Flow {
              width: parent.width
              spacing: Style.spacing.md
              Button { text: "Edit pack"; bordered: true; selected: true; fontSize: Style.font.bodySmall; onClicked: root.edit("roles") }
              Button {
                visible: root.view && root.view.entry.sources.some(function(s) { return s.format === "aseprite" })
                text: "Aseprite"
                bordered: true
                fontSize: Style.font.bodySmall
                tooltipText: "Open this pack's .aseprite file; saving it rebuilds the pack"
                onClicked: {
                  if (root.service.asepriteInstalled) root.service.openInAseprite(root.packId)
                  else root.asepriteHelp = true
                }
              }
              Button { text: "Phrases"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "What the buddy says with this pack while Claude Code or Codex works"; onClicked: root.edit("phrases") }
              Button { text: "Rebuild"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "Export the pack again from its source files"; onClicked: root.service.rebuildPack(root.packId) }
              Button { text: "Folder"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "Open this pack's folder in ~/.local/share/pixel-buddy/packs"; onClicked: root.service.openPackFolder(root.packId) }
              Button {
                visible: !!root.service && root.service.setupDismissed && root.service.agentsToConnect.length > 0
                text: "Connect agents"
                bordered: true
                fontSize: Style.font.bodySmall
                tooltipText: "Add the Claude Code / Codex hooks so the buddy shows what your agent is doing"
                onClicked: root.service.connectAgents()
              }
            }

            // Aseprite clicked but not installed
            Rectangle {
              visible: root.asepriteHelp
              width: parent.width
              height: visible ? helpCol.implicitHeight + Style.spacing.md * 2 : 0
              radius: Style.cornerRadius
              color: Qt.rgba(root.warn.r, root.warn.g, root.warn.b, 0.12)
              border.color: root.warn
              border.width: 1

              Column {
                id: helpCol
                x: Style.spacing.md
                y: Style.spacing.md
                width: parent.width - Style.spacing.md * 2
                spacing: Style.spacing.md

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: "Aseprite isn't installed. You can draw this buddy in another pixel-art editor such as LibreSprite (free) and export a GIF or PNG strip into the pack's folder; the file name becomes the animation name."
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: "To install Aseprite: yay -S aseprite (it builds from source, which takes a while). LibreSprite: sudo pacman -S libresprite."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Row {
                  spacing: Style.spacing.md
                  Button { text: "Open folder"; bordered: true; selected: true; fontSize: Style.font.bodySmall; onClicked: root.service.openPackFolder(root.packId) }
                  Button { text: "Dismiss"; bordered: true; fontSize: Style.font.bodySmall; onClicked: root.asepriteHelp = false }
                }
              }
            }
          }

          // ======================================================= EDIT
          Column {
            visible: !!root.view && root.mode === "edit"
            width: parent.width
            spacing: Style.space(10)

            // Five tabs: smaller chips that wrap when they don't fit the popup's width
            Flow {
              width: parent.width
              spacing: Style.spacing.sm
              Repeater {
                model: [{ value: "roles", label: "Roles" }, { value: "behavior", label: "Behavior" },
                        { value: "geometry", label: "Geometry" }, { value: "phrases", label: "Phrases" },
                        { value: "info", label: "Info" }]
                Button {
                  required property var modelData
                  text: modelData.label
                  bordered: true
                  selected: root.tab === modelData.value
                  fontSize: Style.font.bodySmall
                  onClicked: {
                    root.tab = modelData.value
                    root.confirmDelete = false
                  }
                }
              }
            }

            // ---------- Roles
            Column {
              visible: root.tab === "roles"
              width: parent.width
              spacing: Style.spacing.md

              Repeater {
                model: Packs.GROUPS

                Column {
                  id: groupCol
                  required property var modelData
                  width: parent.width
                  spacing: Style.spacing.sm

                  PanelSectionHeader {
                    width: parent.width
                    topPadding: Style.spacing.md
                    text: groupCol.modelData.label.toUpperCase()
                    foreground: root.fg
                    fontFamily: root.fontFamily
                  }

                  Repeater {
                    model: Packs.ROLES.filter(function(r) { return r.group === groupCol.modelData.key })

                    Item {
                      id: roleRow
                      required property var modelData
                      readonly property var list: root.view ? root.view.resolved.roles[modelData.key] : []
                      readonly property string source: root.view ? root.view.resolved.source[modelData.key] : "none"
                      readonly property var others: root.view ? root.view.names.filter(function(n) { return roleRow.list.indexOf(n) < 0 }) : []
                      width: parent.width
                      height: Math.max(roleLabelCol.implicitHeight, roleControl.height) + Style.spacing.xs * 2

                      Rectangle {
                        anchors.fill: parent
                        radius: Style.cornerRadius
                        color: root.previewRole === roleRow.modelData.key && !root.previewAnim ? root.faint : "transparent"
                      }
                      TapHandler { onTapped: { root.previewRole = roleRow.modelData.key; root.previewAnim = "" } }

                      Column {
                        id: roleLabelCol
                        anchors.left: parent.left
                        anchors.leftMargin: Style.spacing.sm
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * 0.38
                        Text {
                          textFormat: Text.PlainText
                          width: parent.width
                          text: roleRow.modelData.label
                          elide: Text.ElideRight
                          color: root.fg
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                        }
                        Text {
                          textFormat: Text.PlainText
                          text: roleRow.source === "guess" ? "guessed" : roleRow.source === "none" ? (roleRow.modelData.key === "idle" ? "uses the first animation" : "skipped") : ""
                          visible: text !== ""
                          color: roleRow.source === "none" ? root.warn : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      Item {
                        id: roleControl
                        anchors.right: parent.right
                        anchors.rightMargin: Style.spacing.sm
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * 0.58
                        height: roleRow.modelData.multi === true ? multiFlow.implicitHeight : single.height

                        // One animation per slot
                        Dropdown {
                          id: single
                          visible: roleRow.modelData.multi !== true
                          width: parent.width
                          showLabel: false
                          options: [{ value: "", label: "— none —" }].concat(root.view ? root.view.names : [])
                          value: roleRow.list.length ? roleRow.list[0] : ""
                          onChanged: function(v) {
                            root.service.setRole(root.packId, roleRow.modelData.key, v ? [v] : [])
                            root.previewRole = roleRow.modelData.key
                            root.previewAnim = ""
                            // Dropdown assigns `value` itself; follow the mapping again
                            value = Qt.binding(function() { return roleRow.list.length ? roleRow.list[0] : "" })
                          }
                        }

                        // Several animations, one picked at random each time
                        Flow {
                          id: multiFlow
                          visible: roleRow.modelData.multi === true
                          width: parent.width
                          spacing: Style.spacing.sm
                          layoutDirection: Qt.RightToLeft

                          Dropdown {
                            visible: roleRow.others.length > 0
                            width: Style.space(64)
                            showLabel: false
                            options: roleRow.others
                            value: ""
                            onChanged: function(v) {
                              if (v) root.service.setRole(root.packId, roleRow.modelData.key, roleRow.list.concat([v]))
                              value = ""
                            }
                            Text {
                              textFormat: Text.PlainText
                              anchors.centerIn: parent
                              text: "+ add"
                              color: root.dim
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                            }
                          }

                          Repeater {
                            model: roleRow.list
                            Button {
                              required property string modelData
                              text: modelData + "  ×"
                              bordered: true
                              fontSize: Style.font.caption
                              verticalPadding: Style.spacing.xs
                              tooltipText: "Remove " + modelData + " from " + roleRow.modelData.label
                              onClicked: root.service.setRole(root.packId, roleRow.modelData.key, roleRow.list.filter(function(n) { return n !== modelData }))
                              onHovered: function(h) { if (h) root.previewAnim = modelData }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.view && root.view.resolved.unused.length > 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.view ? "Not used by any role: " + root.view.resolved.unused.join(", ") : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                visible: root.view && root.view.resolved.missing.length > 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.view ? "pack.json names animations this pack doesn't have: " + root.view.resolved.missing.join(", ") : ""
                color: root.warn
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Button {
                text: "Guess again"
                bordered: true
                tooltipText: "Forget your choices and map every role from the animation names"
                onClicked: root.service.resetRoles(root.packId)
              }
            }

            // ---------- Behavior
            Column {
              visible: root.tab === "behavior"
              width: parent.width
              spacing: Style.spacing.md

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                text: "How long each animation keeps looping when it plays, in seconds (0 = play once). Walks loop for the whole trip. Between work events the buddy picks idle, walk, turn and random-action animations by their % chance; ones on auto share what the others leave."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Item {
                width: parent.width
                height: minPlay.height
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "shortest loop, all animations"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                NumberField {
                  id: minPlay
                  anchors.right: parent.right
                  fieldWidth: Style.space(96)
                  from: 0; to: 60
                  value: root.view ? Math.round(Number(root.view.pack.minPlaySec !== undefined ? root.view.pack.minPlaySec : (root.service.config.sprite || {}).minPlaySec) || 0) : 0
                  onModified: function(v) { root.updatePack(function(pj) { pj.minPlaySec = v }) }
                }
              }

              Repeater {
                model: root.view ? root.view.names : []

                Column {
                  id: animRow
                  required property string modelData
                  readonly property var beh: root.view ? (root.view.pack.behavior || {}) : {}
                  readonly property bool isWalk: root.view ? root.view.resolved.roles.walk.indexOf(modelData) >= 0 : false
                  readonly property bool isAction: root.view ? root.view.resolved.roles.actions.indexOf(modelData) >= 0 : false
                  readonly property var chainEntry: root.chain[modelData] || null
                  readonly property var playSec: beh.playSec || {}
                  readonly property bool hasPlay: playSec[modelData] !== undefined
                  readonly property var ms: root.view && root.view.entry.animations[modelData] ? root.view.entry.animations[modelData].ms : 0
                  width: parent.width
                  spacing: Style.spacing.sm

                  PanelSeparator { width: parent.width; foreground: root.fg }

                  Item {
                    width: parent.width
                    height: Math.max(animText.implicitHeight, playField.height)
                    HoverHandler { onHoveredChanged: if (hovered) root.previewAnim = animRow.modelData }
                    Column {
                      id: animText
                      anchors.verticalCenter: parent.verticalCenter
                      Text {
                        textFormat: Text.PlainText
                        id: animName
                        text: animRow.modelData
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: "animation loop length " + (animRow.ms / 1000).toFixed(1) + " s" + (animRow.isWalk ? " · walk" : animRow.isAction ? " · random action" : "")
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      // What the seconds field means in plays, the way Buddy.repeatsFor rounds it: whole loops, at least the time set
                      Text {
                        textFormat: Text.PlainText
                        readonly property real loopSec: animRow.ms / 1000
                        readonly property int plays: playField.value <= 0 || loopSec <= 0 ? 1 : Math.ceil(playField.value / loopSec - 1e-6)
                        text: animRow.isWalk ? "loops for the whole walk"
                          : plays === 1 ? "plays once"
                          : "plays " + plays + "× (" + (plays * loopSec).toFixed(1) + " s) · set 0 s to play once"
                        color: plays > 1 && !animRow.isWalk ? root.warn : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                    Row {
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.sm
                      Button {
                        visible: animRow.hasPlay
                        text: "↺"
                        tooltipText: "Back to the default"
                        onClicked: root.setBehavior("playSec", animRow.modelData, null)
                      }
                      NumberField {
                        id: playField
                        fieldWidth: Style.space(96)
                        from: 0; to: 120
                        // Turn, drag and click reactions play once unless told otherwise (Buddy.repeatsFor)
                        readonly property bool once: root.view ? ["turn", "drag", "clicks"].some(function(k) { return root.view.resolved.roles[k].indexOf(animRow.modelData) >= 0 }) : false
                        value: animRow.hasPlay ? Number(animRow.playSec[animRow.modelData]) || 0 : (once ? 0 : minPlay.value)
                        onModified: function(v) { root.setBehavior("playSec", animRow.modelData, v) }
                      }
                    }
                  }

                  Item {
                    visible: animRow.isWalk
                    width: parent.width
                    height: extraField.height
                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      text: "walk speed, canvas px per second"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    NumberField {
                      id: extraField
                      anchors.right: parent.right
                      fieldWidth: Style.space(96)
                      from: 1; to: 400
                      value: Number((animRow.beh.speed || {})[animRow.modelData]) || Number((((root.service.config.animations || {}).moves || {}).default || {}).speed) || 24
                      onModified: function(v) { root.setBehavior("speed", animRow.modelData, v) }
                    }
                  }

                  // How often the random chain picks this animation; auto ones share what the others leave
                  Item {
                    visible: animRow.chainEntry !== null
                    width: parent.width
                    height: chanceField.height
                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      text: animRow.chainEntry && animRow.chainEntry.set ? "animation chance %" : "animation chance % (auto)"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Row {
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.sm
                      Button {
                        visible: !!animRow.chainEntry && animRow.chainEntry.set
                        text: "↺"
                        tooltipText: "Back to auto: share what the other animations leave"
                        onClicked: root.setBehavior("chance", animRow.modelData, null)
                      }
                      NumberField {
                        id: chanceField
                        fieldWidth: Style.space(96)
                        from: 0; to: 100
                        value: animRow.chainEntry ? Math.round(animRow.chainEntry.chance) : 0
                        onModified: function(v) { root.setBehavior("chance", animRow.modelData, v) }
                      }
                    }
                  }
                }
              }
            }

            // ---------- Geometry
            Column {
              visible: root.tab === "geometry"
              width: parent.width
              spacing: Style.spacing.lg

              Item {
                width: parent.width
                height: facingGroup.height
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "drawn facing"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                ButtonGroup {
                  id: facingGroup
                  anchors.right: parent.right
                  options: [{ value: "left", label: "Left" }, { value: "right", label: "Right" }]
                  value: root.view ? root.view.geometry.facing : "left"
                  onChanged: function(v) {
                    root.updatePack(function(pj) { pj.facing = v })
                    value = Qt.binding(function() { return root.view ? root.view.geometry.facing : "left" })
                  }
                }
              }

              Item {
                width: parent.width
                height: scaleField.height
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  Text {
                    textFormat: Text.PlainText
                    text: "size on screen"
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    readonly property var g: root.view ? root.view.geometry : null
                    text: g ? (g.scale > 0 ? g.width * g.scale + " px wide (" + g.scale + "× the canvas)" : "buddy's own size setting") : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                NumberField {
                  id: scaleField
                  anchors.right: parent.right
                  fieldWidth: Style.space(96)
                  from: 1; to: 12
                  value: root.view && root.view.geometry.scale > 0 ? root.view.geometry.scale
                    : root.view ? Math.max(1, Math.round((Number(root.buddy && root.buddy.size) || root.view.geometry.width * 3) / root.view.geometry.width)) : 3
                  onModified: function(v) { root.updatePack(function(pj) { pj.scale = v }) }
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                readonly property var g: root.view ? root.view.geometry : null
                text: g ? "Canvas " + g.width + "×" + g.height + " · feet on row " + Math.round(g.feetY) + " · hitbox " + g.hitBox.map(Math.round).join(", ")
                  + "\nThe hitbox is where you click and drag the buddy; the speech bubble sits on its top edge." : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Button {
                text: "Open geometry editor"
                bordered: true
                selected: true
                onClicked: {
                  root.service.openGeometryEditor(root.packId)
                  root.close()
                }
              }
            }

            // ---------- Phrases
            Column {
              visible: root.tab === "phrases"
              width: parent.width
              spacing: Style.spacing.md

              Repeater {
                model: root.phraseSections

                Column {
                  id: section
                  required property var modelData
                  readonly property bool work: modelData.kind === "work"
                  readonly property var lines: (work ? root.phrases[modelData.key] : root.animPhrases[modelData.key]) || []
                  readonly property string roles: work ? "" : root.animRoles(modelData.key)
                  readonly property var chances: Phrases.chances(lines)
                  readonly property real silence: lines.length ? Phrases.silence(lines) : 0
                  width: parent.width
                  spacing: Style.spacing.sm

                  // Group heading before the first work state and the first animation
                  Text {
                    textFormat: Text.PlainText
                    visible: section.modelData.first
                    width: parent.width
                    topPadding: section.work ? 0 : Style.spacing.lg
                    text: section.work ? "Work status" : "Animations"
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: section.modelData.first
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: section.work
                      ? "The bubble's line while Claude Code or Codex works. Each time the state changes the buddy picks a line by its % chance; with none, it shows no bubble." + (root.customPhrases ? "" : " This pack uses the config's lines until you edit one.") + " ▶ shows a line on " + root.buddyName + "."
                      : "Every animation in this pack, by its tag name. Give one a few lines and each time it starts playing the buddy says one, picked by its % chance. Lines on idle or walk come up often, so give those a low %. A work status, murmur or chat in the bubble takes priority."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Button {
                    visible: section.work && section.modelData.first && root.customPhrases
                    text: "Reset to defaults"
                    bordered: true
                    fontSize: Style.font.bodySmall
                    tooltipText: "Forget this pack's work-status lines and use workStatusTexts from the config again"
                    onClicked: root.updatePack(function(pj) { delete pj.phrases })
                  }

                  PanelSectionHeader {
                    width: parent.width
                    topPadding: Style.spacing.md
                    text: section.modelData.title
                    foreground: root.fg
                    fontFamily: root.fontFamily
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: section.roles !== ""
                    width: parent.width
                    elide: Text.ElideRight
                    text: "plays as: " + section.roles
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: section.silence >= 0.5
                    width: parent.width
                    text: "says nothing " + Math.round(section.silence) + "% of the time"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Repeater {
                    model: section.lines

                    // The line on top, its chance and buttons right-aligned below
                    Column {
                      id: lineRow
                      required property var modelData
                      required property int index
                      readonly property string text: Phrases.lineText(modelData)
                      readonly property var chance: Phrases.lineChance(modelData)
                      width: section.width
                      spacing: Style.spacing.xs

                      TextField {
                        width: parent.width
                        text: lineRow.text
                        // An emptied field removes the line
                        onEditingFinished: if (text.trim() !== lineRow.text)
                          root.setSectionLine(section.modelData, lineRow.index, text.trim() ? { text: text.trim() } : null)
                        onActiveFocusChanged: if (activeFocus) root.phraseField = this
                      }
                      Item {
                        width: parent.width
                        height: lineControls.height
                        Row {
                          id: lineControls
                          anchors.right: parent.right
                          spacing: Style.spacing.sm
                          Text {
                            textFormat: Text.PlainText
                            anchors.verticalCenter: parent.verticalCenter
                            text: lineRow.chance !== null ? "chance %" : "chance % (auto)"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                          Button {
                            visible: lineRow.chance !== null
                            text: "↺"
                            fontSize: Style.font.bodySmall
                            tooltipText: "Back to auto: share what the other lines leave"
                            onClicked: root.setSectionLine(section.modelData, lineRow.index, { chance: null })
                          }
                          // Lines left on auto share what the others leave of 100%
                          NumberField {
                            fieldWidth: Style.space(72)
                            fontSize: Style.font.bodySmall
                            from: 0; to: 100
                            value: Math.round(section.chances[lineRow.index] || 0)
                            onModified: function(v) { root.setSectionLine(section.modelData, lineRow.index, { chance: v }) }
                          }
                          Button {
                            text: "▶"
                            bordered: true
                            fontSize: Style.font.bodySmall
                            tooltipText: "Show this line on the buddy"
                            onClicked: root.service.speak(root.buddyId, lineRow.text, "", "preview")
                          }
                          Button {
                            text: "×"
                            bordered: true
                            fontSize: Style.font.bodySmall
                            tooltipText: "Remove this line"
                            onClicked: root.setSectionLine(section.modelData, lineRow.index, null)
                          }
                        }
                      }
                    }
                  }

                  TextField {
                    width: parent.width
                    placeholderText: "+ add a line, Enter to save"
                    onAccepted: if (text.trim()) {
                      root.setSectionLine(section.modelData, -1, { text: text.trim() })
                      text = ""
                    }
                    onActiveFocusChanged: if (activeFocus) root.phraseField = this
                  }
                }
              }
            }

            // ---------- Info
            Column {
              visible: root.tab === "info"
              width: parent.width
              spacing: Style.spacing.lg

              Column {
                width: parent.width
                spacing: Style.spacing.xs
                Text { text: "Name"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                TextField {
                  id: nameField
                  width: parent.width
                  text: root.view ? root.view.entry.name : ""
                  onEditingFinished: if (text.trim() && root.view && text.trim() !== root.view.entry.name) {
                    var t = text.trim()
                    root.updatePack(function(pj) { pj.name = t })
                  }
                }
              }
              Column {
                width: parent.width
                spacing: Style.spacing.xs
                Text { text: "Author"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                TextField {
                  id: authorField
                  width: parent.width
                  text: root.view ? root.view.entry.author : ""
                  onEditingFinished: if (root.view && text.trim() !== root.view.entry.author) {
                    var t = text.trim()
                    root.updatePack(function(pj) { pj.author = t })
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                readonly property var e: root.view ? root.view.entry : null
                text: e ? "Folder: ~/.local/share/pixel-buddy/packs/" + e.id + "\nFiles: " + (e.sources.map(function(s) { return s.file }).join(", ") || "none")
                  + "\n" + Object.keys(e.animations || {}).length + " animations"
                  + (e.canvas ? " · canvas " + e.canvas[0] + "×" + e.canvas[1] : "")
                  + (e.warnings.length ? "\n⚠ " + e.warnings.join("\n⚠ ") : "")
                  + (e.errors.length ? "\n✕ " + e.errors.join("\n✕ ") : "")
                  + (e.packError ? "\n✕ " + e.packError : "") : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Flow {
                width: parent.width
                spacing: Style.spacing.md
                Button { text: "Folder"; bordered: true; onClicked: root.service.openPackFolder(root.packId) }
                Button {
                  text: "Duplicate"
                  bordered: true
                  onClicked: root.service.duplicatePack(root.packId, (root.view ? root.view.entry.name : "Pack") + " copy", function(id) { root.showPack(id) })
                }
                Button {
                  // Same rule as the right-click menu: the last pack stays
                  readonly property bool onlyPack: !root.service || root.service.packList.length <= 1
                  enabled: !onlyPack
                  opacity: onlyPack ? 0.4 : 1
                  text: onlyPack ? "Delete (last pack)" : root.confirmDelete ? "Really delete?" : "Delete"
                  bordered: true
                  selected: root.confirmDelete
                  tooltipText: onlyPack ? "A buddy needs at least one pack" : "Moves the pack to ~/.local/share/pixel-buddy/trash"
                  onClicked: {
                    if (onlyPack) return
                    if (!root.confirmDelete) {
                      root.confirmDelete = true
                      return
                    }
                    root.confirmDelete = false
                    root.service.deletePack(root.packId, function() {
                      root.browsePack = ""
                      root.mode = "home"
                    })
                  }
                }
              }
            }
          }

          // ---------- messages from pack commands
          Text {
            textFormat: Text.PlainText
            visible: root.service && root.service.packMessage !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.service ? root.service.packMessage : ""
            color: root.service && root.service.packMessageError ? root.bad : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // ---------- right-click menu for a pack thumbnail
      MouseArea {
        anchors.fill: parent
        visible: root.menuPack !== ""
        z: 10
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: root.menuPack = ""
      }

      Rectangle {
        id: packMenu
        readonly property var entry: root.service && root.menuPack ? root.service.packIndex[root.menuPack] : null
        readonly property bool onlyPack: root.service ? root.service.packList.length <= 1 : true
        visible: root.menuPack !== "" && !!entry
        z: 11
        width: Style.space(200)
        height: menuCol.implicitHeight + Style.spacing.md * 2
        x: Math.max(0, Math.min(root.menuAt.x, parent.width - width))
        y: Math.max(0, Math.min(root.menuAt.y, parent.height - height))
        radius: Style.cornerRadius
        color: Color.menu.background
        border.color: Color.menu.border
        border.width: 1

        component MenuItem: Rectangle {
          id: item
          property string label: ""
          property bool danger: false
          property bool active: true
          signal activated()
          width: parent ? parent.width : 0
          height: Style.spacing.popupRowHeight
          radius: Style.cornerRadius
          color: itemHover.hovered && active ? Color.menu.selectedBackground : "transparent"
          opacity: active ? 1 : 0.4
          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            text: item.label
            color: item.danger ? Color.urgent : (itemHover.hovered ? Color.menu.selectedText : Color.menu.text)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          HoverHandler { id: itemHover }
          TapHandler { onTapped: if (item.active) item.activated() }
        }

        Column {
          id: menuCol
          x: Style.spacing.md
          y: Style.spacing.md
          width: parent.width - Style.spacing.md * 2
          spacing: Style.spacing.xxs

          Text {
            textFormat: Text.PlainText
            width: parent.width
            leftPadding: Style.spacing.lg
            bottomPadding: Style.spacing.xs
            text: packMenu.entry ? packMenu.entry.name : ""
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Column {
            visible: !root.menuConfirm
            width: parent.width
            spacing: Style.spacing.xxs
            MenuItem {
              label: "Use for " + root.buddyName
              active: !!root.service && root.service.buddyPackId(root.buddyId) !== root.menuPack
              onActivated: { var id = root.menuPack; root.menuPack = ""; root.showPack(id); root.usePack() }
            }
            MenuItem {
              label: "Edit pack"
              onActivated: { var id = root.menuPack; root.menuPack = ""; root.showPack(id); root.edit("roles") }
            }
            MenuItem {
              label: "Duplicate"
              onActivated: {
                var id = root.menuPack
                root.menuPack = ""
                root.service.duplicatePack(id, (packMenu.entry ? packMenu.entry.name : "Pack") + " copy", function(nid) { root.showPack(nid) })
              }
            }
            MenuItem {
              label: "Open folder"
              onActivated: { var id = root.menuPack; root.menuPack = ""; root.service.openPackFolder(id) }
            }
            MenuItem {
              label: packMenu.onlyPack ? "Delete (last pack)" : "Delete…"
              danger: true
              active: !packMenu.onlyPack
              onActivated: root.menuConfirm = true
            }
          }

          Column {
            visible: root.menuConfirm
            width: parent.width
            spacing: Style.spacing.sm
            Text {
              textFormat: Text.PlainText
              width: parent.width
              leftPadding: Style.spacing.lg
              rightPadding: Style.spacing.lg
              wrapMode: Text.WordWrap
              text: "Delete this pack and its sprite files?"
                + (root.service && root.service.buddyPackId(root.buddyId) === root.menuPack ? " The buddy switches to another pack." : "")
                + " They move to ~/.local/share/pixel-buddy/trash."
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MenuItem { label: "Delete"; danger: true; onActivated: root.deletePack(root.menuPack) }
            MenuItem { label: "Cancel"; onActivated: root.menuConfirm = false }
          }
        }
      }
    }
  }
}
