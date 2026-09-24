import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import qs.Commons
import "Logic.js" as Logic

// A which-key style bar: lists every SUPER + key binding along the bottom of the
// screen, grouped by what it does. It never takes the keyboard, so pressing a
// key while it shows still runs that binding.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property var groups: []   // [{ title, items: [{ key, desc }] }]
  property int count: 0
  property var items: []       // every parsed binding, flat
  property var suggested: []   // up to 4 items worth pressing next, from the screen's state
  readonly property var suggestedDescs: suggested.map(function(i) { return i.desc })

  // Safety net: a release bind can be missed, so the bar never stays up for long.
  readonly property int autoHideMs: 6000

  readonly property color accent: Color.menu.selectedText
  readonly property color text: Color.menu.text
  readonly property color muted: Qt.rgba(text.r, text.g, text.b, 0.55)
  readonly property color keyFill: Qt.rgba(accent.r, accent.g, accent.b, 0.12)
  readonly property color keyEdge: Qt.rgba(accent.r, accent.g, accent.b, 0.35)
  readonly property int pad: Style.spacing.panelPadding
  readonly property int slide: Style.space(14)
  // Groups longer than this wrap into another column, so the bar stays short.
  readonly property int maxRows: 6
  readonly property int minKeyWidth: Style.space(54)

  // Columns take the width their text needs. Estimate that width at full size
  // from character counts; if it doesn't fit (narrow or scaled screens) shrink
  // the font to fit instead of cutting descriptions off.
  readonly property real available: panel.width - pad * 2
  readonly property real needed: Logic.neededWidth(groups, {
    charWidth: charMetrics.advanceWidth, maxRows: maxRows, minKeyWidth: minKeyWidth,
    keyPad: Style.spacing.lg, gap: Style.spacing.lg, columnGap: pad
  })
  readonly property real fit: needed > 0 ? Math.min(1, available / needed) : 1
  // ponytail: 9px floor; below ~1250px logical width the last column can still clip.
  readonly property int fontPx: Math.max(9, Math.floor(Style.font.title * fit))
  // Leftover width spreads between groups so the bar fills the screen.
  readonly property real groupGap: pad + Math.max(0, available - needed * fit) / Math.max(1, groups.length - 1)

  TextMetrics {
    id: charMetrics
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.title
    text: "M"
  }

  // Turned off, holding SUPER does nothing. Remembered across restarts by the
  // presence of a marker file.
  property bool enabled: true
  readonly property string disabledFile: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/nejcc.keybindings-hint.disabled"

  function setEnabled(on) {
    root.enabled = on
    if (!on) root.dismiss()
    Quickshell.execDetached(["sh", "-c", on ? 'rm -f "$1"' : 'mkdir -p "$(dirname "$1")" && touch "$1"', "sh", root.disabledFile])
    Quickshell.execDetached(["notify-send", "-u", "low", "Keybindings hint " + (on ? "on" : "off"),
      on ? "Hold SUPER to see your keybindings." : "Holding SUPER no longer shows the bar."])
  }

  // ---------------------------------------------------------------- learning
  // Optional, off by default. Hyprland never says which key was pressed, so
  // this watches its events, maps each to the binding that most likely caused
  // it, and counts "after A you did B". Stored only in a local state file.
  property bool learning: false
  property var transitions: ({})   // { "Action A": { "Action B": count } }
  property string lastAction: ""
  property real lastActionAt: 0
  readonly property string learnedPath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/nejcc.keybindings-hint.learned.json"

  function record(name, data) {
    var next = Logic.record({ transitions: root.transitions, lastAction: root.lastAction, lastActionAt: root.lastActionAt },
      name, data, root.items, Date.now())
    if (next.transitions !== root.transitions) saveTimer.restart()
    root.transitions = next.transitions
    root.lastAction = next.lastAction
    root.lastActionAt = next.lastActionAt
  }

  function save() {
    learnedFile.setText(JSON.stringify({ version: 1, learning: root.learning, transitions: root.transitions }, null, 2) + "\n")
  }

  function setLearning(mode) {
    if (mode === "reset") {
      root.transitions = ({})
      root.lastAction = ""
    } else {
      root.learning = mode === "toggle" ? !root.learning : mode === "on"
    }
    root.save()
    Quickshell.execDetached(["notify-send", "-u", "low", "Keybindings hint learning " + (mode === "reset" ? "reset" : root.learning ? "on" : "off"),
      mode === "reset" ? "Forgot everything it had learned." : root.learning
        ? "Suggestions will include what you usually do next." : "Suggestions come from what's on screen only."])
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (root.learning && event && event.name) root.record(String(event.name), event.data)
    }
  }

  // Watched, so an outside change (a restore, a hand edit, a sync) is picked up
  // instead of being overwritten by the next save.
  FileView {
    id: learnedFile
    path: root.learnedPath
    atomicWrites: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var saved = Logic.loadSaved(text())
      root.learning = saved.learning
      root.transitions = saved.transitions
    }
  }

  Timer {
    id: saveTimer
    interval: 2000
    onTriggered: root.save()
  }

  // Payloads switch settings instead of showing the bar:
  //   {"enabled": "toggle" | "on" | "off"}
  //   {"learning": "toggle" | "on" | "off" | "reset"}
  function open(payloadJson) {
    var payload = Logic.readPayload(payloadJson)
    if (payload.kind !== "show") {
      if (payload.kind === "learning") root.setLearning(payload.value)
      if (payload.kind === "enabled") root.setEnabled(payload.value === "toggle" ? !root.enabled : payload.value === "on")
      if (root.shell && typeof root.shell.hide === "function") root.shell.hide((root.manifest && root.manifest.id) || "nejcc.keybindings-hint")
      return
    }
    if (!root.enabled) return root.dismiss()
    root.opened = true
    hideTimer.restart()
    list.running = true   // refresh in the background; the cached list shows first
    activeWindow.running = true
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "nejcc.keybindings-hint")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function parse(text) {
    var r = Logic.parse(text)
    root.count = r.count
    root.items = r.items
    root.groups = r.groups
  }

  function suggest(win, ws) {
    root.suggested = Logic.suggest(win, ws, root.items,
      root.learning ? Logic.learnedNext(root.lastAction, root.transitions, root.items) : [])
  }

  Process {
    id: activeWindow
    command: ["hyprctl", "activewindow", "-j"]
    stdout: StdioCollector { id: activeWindowOut; onStreamFinished: activeWorkspace.running = true }
  }

  Process {
    id: activeWorkspace
    command: ["hyprctl", "activeworkspace", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        var win = {}, ws = {}
        try { win = JSON.parse(activeWindowOut.text) } catch (e) {}
        try { ws = JSON.parse(text) } catch (e) {}
        root.suggest(win, ws)
      }
    }
  }

  Component.onCompleted: {
    list.running = true
    enabledCheck.running = true
  }

  Process {
    id: enabledCheck
    command: ["test", "-e", root.disabledFile]
    onExited: function(code) { root.enabled = code !== 0 }
  }

  Process {
    id: list
    command: ["omarchy", "menu", "keybindings", "--print"]
    stdout: StdioCollector { onStreamFinished: root.parse(text) }
  }

  Timer {
    id: hideTimer
    interval: root.autoHideMs
    onTriggered: root.dismiss()
  }

  PanelWindow {
    id: panel
    // Stay mapped until the fade-out finishes.
    visible: root.opened || card.opacity > 0
    anchors { bottom: true; left: true; right: true }
    margins { bottom: Style.gapsOut; left: Style.gapsOut; right: Style.gapsOut }
    implicitHeight: card.implicitHeight + root.slide
    color: "transparent"
    WlrLayershell.namespace: "nejcc-keybindings-hint"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      id: card
      width: parent.width
      implicitHeight: body.implicitHeight + root.pad * 2
      y: root.opened ? root.slide : root.slide * 2
      opacity: root.opened ? 1 : 0
      radius: Style.cornerRadius
      color: Color.menu.background
      border.color: Color.menu.border
      border.width: 1

      Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      Column {
        id: body
        x: root.pad
        y: root.pad
        width: parent.width - root.pad * 2
        spacing: Style.spacing.xl

        // Header: the held key on the left, a count on the right.
        Item {
          width: parent.width
          height: superCap.height

          Keycap {
            id: superCap
            label: "SUPER"
            filled: true
            minWidth: 0
          }
          Text {
            id: plusKey
            anchors.left: superCap.right
            anchors.leftMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            text: "+ key"
            color: root.muted
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
          }

          // What you'll most likely press next, given what's on screen.
          Row {
            anchors.left: plusKey.right
            anchors.leftMargin: root.pad * 2
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.pad
            visible: root.suggested.length > 0

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "SUGGESTED"
              color: root.muted
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
              font.bold: true
            }

            Repeater {
              model: root.suggested
              delegate: Row {
                required property var modelData
                spacing: Style.spacing.lg
                Keycap { id: hotCap; label: modelData.key; filled: true; minWidth: 0 }
                Text {
                  anchors.verticalCenter: hotCap.verticalCenter
                  text: modelData.desc
                  color: root.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: root.fontPx
                }
              }
            }
          }
          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.count + " bindings · release to close"
            color: root.muted
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Color.menu.border
          opacity: 0.35
        }

        // Groups side by side, each as wide as its text.
        Row {
          id: columns
          spacing: root.groupGap

          Repeater {
            model: root.groups
            delegate: Column {
              id: group
              required property var modelData
              spacing: Style.spacing.md

              Text {
                text: group.modelData.title.toUpperCase()
                color: root.muted
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.2
                font.bold: true
                bottomPadding: Style.spacing.xs
              }

              Grid {
                flow: Grid.TopToBottom
                rows: Math.min(root.maxRows, group.modelData.items.length)
                rowSpacing: Style.spacing.md
                columnSpacing: root.pad

                Repeater {
                  model: group.modelData.items
                  delegate: Row {
                    required property var modelData
                    spacing: Style.spacing.lg

                    Keycap { id: cap; label: modelData.key; filled: root.suggestedDescs.indexOf(modelData.desc) !== -1 }
                    Text {
                      anchors.verticalCenter: cap.verticalCenter
                      text: modelData.desc
                      color: root.text
                      font.family: Style.font.menuFamily
                      font.pixelSize: root.fontPx
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  component Keycap: Rectangle {
    property string label
    property bool filled: false
    // Shared minimum width keeps descriptions lined up; long labels grow past it.
    property real minWidth: root.minKeyWidth * root.fit
    width: Math.max(minWidth, keyText.implicitWidth + Style.spacing.lg * 2)
    height: keyText.implicitHeight + Style.spacing.sm * 2
    radius: Math.max(3, Style.cornerRadius / 2)
    color: filled ? root.accent : root.keyFill
    border.color: filled ? root.accent : root.keyEdge
    border.width: 1

    Text {
      id: keyText
      anchors.centerIn: parent
      text: parent.label
      color: parent.filled ? Color.menu.background : root.accent
      font.family: Style.font.menuFamily
      font.pixelSize: root.fontPx
      font.bold: true
    }
  }
}
