import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "lib/packs.mjs" as Packs

// Bar icon + popup for sprite packs: browse packs, pick one per pet, create one from the
// Aseprite template, and edit a pack's role mapping, behavior, geometry and info.
// All state lives in the pixel-pet service (Service.qml); this file is only the UI.
//
// Bar icon: first frame of the active pet's idle animation. Left click opens the popup,
// right click hides / shows the pets. IPC: omarchy-shell pixel-pet-studio toggle
Panel {
  id: root

  moduleName: "nobi.pixel-pet"
  ipcTarget: "pixel-pet-studio"
  manageIpc: false

  // The service is created by the shell next to this widget; look it up until it exists.
  property var service: null
  function findService() {
    if (service) return
    var sh = bar ? bar.shell : null
    var s = sh && typeof sh.serviceFor === "function" ? sh.serviceFor("nobi.pixel-pet") : null
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
  property string petChoice: ""
  property string browsePack: ""
  property string mode: "home" // home | edit
  property string tab: "roles"
  property string previewRole: "idle"
  property string previewAnim: ""
  property bool creating: false
  property bool confirmDelete: false

  readonly property var pets: service ? (service.config.pets || []) : []
  readonly property string petId: petChoice && pets.some(function(p) { return p.id === petChoice }) ? petChoice : (pets.length ? pets[0].id : "")
  readonly property var pet: pets.filter(function(p) { return p.id === root.petId })[0] || null
  readonly property string petName: pet ? (pet.name || pet.id) : ""
  readonly property string petPack: service && petId ? service.petPackId(petId) : ""
  readonly property string packId: service && browsePack && service.packIndex[browsePack] ? browsePack : petPack
  readonly property var view: service && packId ? service.packView(packId) : null
  readonly property var iconView: service && petPack ? service.packView(petPack) : null
  readonly property bool inUse: packId !== "" && packId === petPack
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
  }

  function usePack() {
    if (service && packId) service.setPetPack(petId, packId)
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

  function edit(t) {
    mode = "edit"
    tab = ["roles", "behavior", "geometry", "info"].indexOf(t) >= 0 ? t : "roles"
    confirmDelete = false
    flick.contentY = 0
  }

  // omarchy-shell pixel-pet-studio toggle | open | close | edit [roles|behavior|geometry|info]
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
    mode = "home"
    creating = false
    confirmDelete = false
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
    tooltipText: root.service ? "Pixel Pet · " + (root.iconView ? root.iconView.entry.name : "no pack")
      + (root.service.hidden ? " (hidden)" : "") + "\nRight-click to " + (root.service.hidden ? "show" : "hide") + " the pet" : "Pixel Pet"
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
      packId: root.petPack
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
      blocked: newName.activeFocus || nameField.activeFocus || authorField.activeFocus

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.stepRole(dx)
        if (dy !== 0) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy * Style.space(48)))
      }
      onCloseRequested: root.mode === "edit" ? root.mode = "home" : root.close()
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

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          Text {
            visible: !root.service
            width: parent.width
            text: "The pet service isn't running. Check that nobi.pixel-pet is enabled in shell.json."
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // ---------- header
          Item {
            visible: !!root.service
            width: parent.width
            height: Math.max(titleText.implicitHeight, petPicker.height, backBtn.height)

            Button {
              id: backBtn
              visible: root.mode === "edit"
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "‹ Packs"
              bordered: true
              fontSize: Style.font.bodySmall
              onClicked: root.mode = "home"
            }

            Text {
              id: titleText
              anchors.left: root.mode === "edit" ? backBtn.right : parent.left
              anchors.leftMargin: root.mode === "edit" ? Style.spacing.lg : 0
              anchors.right: petPicker.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.mode === "edit" && root.view ? root.view.entry.name : "Pixel Pet"
              elide: Text.ElideRight
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Dropdown {
              id: petPicker
              visible: root.pets.length > 1 && root.mode === "home"
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(140)
              showLabel: false
              options: root.pets.map(function(p) { return { value: p.id, label: "pet: " + (p.name || p.id) } })
              value: root.petId
              onChanged: function(v) {
                root.petChoice = v
                root.browsePack = ""
                value = Qt.binding(function() { return root.petId })
              }
            }

            Text {
              visible: root.mode === "edit"
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.service && root.service.savePending(root.packId) ? "saving…" : "saved"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
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
                  width: parent.width
                  text: root.view ? root.view.entry.name : ""
                  elide: Text.ElideRight
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
                Text {
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
                text: "Use for " + root.petName
                bordered: true
                selected: true
                onClicked: root.usePack()
              }
              Text {
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
                id: mappedText
                anchors.left: parent.left
                text: root.view ? root.view.resolved.mapped + " / " + root.view.resolved.total + " roles mapped" : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                anchors.right: parent.right
                readonly property int missing: root.view ? root.view.resolved.total - root.view.resolved.mapped : 0
                text: missing > 0 ? missing + (missing === 1 ? " plays idle instead" : " play idle instead") : "all set"
                color: missing > 0 ? root.warn : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
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
                      visible: root.service.petPackId(root.petId) === thumb.modelData.id
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
                placeholderText: "Name of the new pet"
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
                  // A new pack goes straight onto the pet, so saves in Aseprite show up there
                  root.service.newPack(name, function(id) {
                    root.service.setPetPack(root.petId, id, true)
                    root.showPack(id)
                  })
                }
              }
              Button { id: cancelBtn; text: "Cancel"; bordered: true; onClicked: root.creating = false }
            }
            Text {
              visible: root.creating
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Copies the starter slime with every animation tag and opens it in Aseprite. Saving there updates the pet."
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
                onClicked: root.service.openInAseprite(root.packId)
              }
              Button { text: "Rebuild"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "Export the pack again from its source files"; onClicked: root.service.rebuildPack(root.packId) }
              Button { text: "Folder"; bordered: true; fontSize: Style.font.bodySmall; tooltipText: "Open this pack's folder (packs/ in the plugin)"; onClicked: root.service.openPackFolder(root.packId) }
            }
          }

          // ======================================================= EDIT
          Column {
            visible: !!root.view && root.mode === "edit"
            width: parent.width
            spacing: Style.space(10)

            ButtonGroup {
              width: parent.width
              options: [{ value: "roles", label: "Roles" }, { value: "behavior", label: "Behavior" },
                        { value: "geometry", label: "Geometry" }, { value: "info", label: "Info" }]
              value: root.tab
              onChanged: function(v) {
                root.tab = v
                root.confirmDelete = false
                value = Qt.binding(function() { return root.tab })
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
                          width: parent.width
                          text: roleRow.modelData.label
                          elide: Text.ElideRight
                          color: root.fg
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                        }
                        Text {
                          text: roleRow.source === "guess" ? "guessed" : roleRow.source === "none" ? "plays idle" : ""
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
                          options: [{ value: "", label: "— idle —" }].concat(root.view ? root.view.names : [])
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
                visible: root.view && root.view.resolved.unused.length > 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.view ? "Not used by any role: " + root.view.resolved.unused.join(", ") : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
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
                width: parent.width
                wrapMode: Text.WordWrap
                text: "How long each animation keeps looping when it plays, in seconds (0 = play once). Walks loop for the whole trip."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Item {
                width: parent.width
                height: minPlay.height
                Text {
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
                  readonly property var playSec: beh.playSec || {}
                  readonly property bool hasPlay: playSec[modelData] !== undefined
                  readonly property var ms: root.view && root.view.entry.animations[modelData] ? root.view.entry.animations[modelData].ms : 0
                  width: parent.width
                  spacing: Style.spacing.sm

                  PanelSeparator { width: parent.width; foreground: root.fg }

                  Item {
                    width: parent.width
                    height: Math.max(animName.implicitHeight, playField.height)
                    HoverHandler { onHoveredChanged: if (hovered) root.previewAnim = animRow.modelData }
                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      Text {
                        id: animName
                        text: animRow.modelData
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }
                      Text {
                        text: (animRow.ms / 1000).toFixed(1) + " s per loop" + (animRow.isWalk ? " · walk" : animRow.isAction ? " · random action" : "")
                        color: root.dim
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
                        // Turn, drag and click reactions play once unless told otherwise (Pet.repeatsFor)
                        readonly property bool once: root.view ? ["turn", "drag", "clicks"].some(function(k) { return root.view.resolved.roles[k].indexOf(animRow.modelData) >= 0 }) : false
                        value: animRow.hasPlay ? Number(animRow.playSec[animRow.modelData]) || 0 : (once ? 0 : minPlay.value)
                        onModified: function(v) { root.setBehavior("playSec", animRow.modelData, v) }
                      }
                    }
                  }

                  Item {
                    visible: animRow.isWalk || animRow.isAction
                    width: parent.width
                    height: extraField.height
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: animRow.isWalk ? "walk speed, canvas px per second" : "how often, compared to other actions"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    NumberField {
                      id: extraField
                      anchors.right: parent.right
                      fieldWidth: Style.space(96)
                      from: 1; to: animRow.isWalk ? 400 : 10
                      value: animRow.isWalk
                        ? Number((animRow.beh.speed || {})[animRow.modelData]) || Number(((root.service.config.animations || {}).moves || {}).default.speed) || 24
                        : Number((animRow.beh.weight || {})[animRow.modelData]) || 1
                      onModified: function(v) { root.setBehavior(animRow.isWalk ? "speed" : "weight", animRow.modelData, v) }
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
                    text: "size on screen"
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    readonly property var g: root.view ? root.view.geometry : null
                    text: g ? (g.scale > 0 ? g.width * g.scale + " px wide (" + g.scale + "× the canvas)" : "pet's own size setting") : ""
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
                    : root.view ? Math.max(1, Math.round((Number(root.pet && root.pet.size) || root.view.geometry.width * 3) / root.view.geometry.width)) : 3
                  onModified: function(v) { root.updatePack(function(pj) { pj.scale = v }) }
                }
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                readonly property var g: root.view ? root.view.geometry : null
                text: g ? "Canvas " + g.width + "×" + g.height + " · feet on row " + Math.round(g.feetY) + " · hitbox " + g.hitBox.map(Math.round).join(", ")
                  + "\nThe hitbox is where you click and drag the pet; the speech bubble sits on its top edge." : ""
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
                width: parent.width
                wrapMode: Text.WordWrap
                readonly property var e: root.view ? root.view.entry : null
                text: e ? "Folder: packs/" + e.id + "\nFiles: " + (e.sources.map(function(s) { return s.file }).join(", ") || "none")
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
                  text: root.confirmDelete ? "Really delete?" : "Delete"
                  bordered: true
                  selected: root.confirmDelete
                  tooltipText: "Moves the pack to ~/.local/share/pixel-pet/trash"
                  onClicked: {
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
    }
  }
}
