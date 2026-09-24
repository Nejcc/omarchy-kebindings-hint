import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons

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
  readonly property real needed: {
    var cw = charMetrics.advanceWidth, total = 0, cols = 0
    groups.forEach(function(g) {
      for (var i = 0; i < g.items.length; i += maxRows) {
        var chunk = g.items.slice(i, i + maxRows), key = 0, desc = 0
        chunk.forEach(function(it) { key = Math.max(key, it.key.length); desc = Math.max(desc, it.desc.length) })
        total += Math.max(minKeyWidth, key * cw + Style.spacing.lg * 2) + Style.spacing.lg + desc * cw
        cols++
      }
    })
    return total + pad * Math.max(0, cols - 1)
  }
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

  // Payload {"enabled": "toggle" | "on" | "off"} switches the hint instead of showing it.
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) {}
    if (payload.enabled !== undefined) {
      root.setEnabled(payload.enabled === "toggle" ? !root.enabled : payload.enabled === "on")
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

  // Short labels, the way the keycaps read.
  readonly property var symbols: ({
    APOSTROPHE: "'", SEMICOLON: ";", COMMA: ",", PERIOD: ".", SLASH: "/", BACKSLASH: "\\",
    MINUS: "-", EQUAL: "=", GRAVE: "`", BACKSPACE: "⌫", RETURN: "⏎", ESCAPE: "Esc",
    SPACE: "Space", TAB: "Tab", PRINT: "PrtSc", Home: "Home",
    LEFT: "←", RIGHT: "→", UP: "↑", DOWN: "↓"
  })

  function label(key) {
    return key.split(" / ").map(function(k) { return root.symbols[k] || k }).join(" ")
  }

  // First match wins; anything unmatched lands in "Other".
  // ponytail: grouped by words in the description; Omarchy's list has no categories.
  readonly property var groupRules: [
    { title: "Workspaces",   test: /workspace|scratchpad/i },
    { title: "Focus",        test: /^focus|last window|jump to window/i },
    { title: "Windows",      test: /window|full ?screen|split|group|float|pseudo|expand|shrink/i },
    { title: "Clipboard",    test: /copy|paste|cut\b|select all/i },
    { title: "Apps & menus", test: /menu|terminal|keybindings|browser|file manager|picker|launch/i }
  ]

  // Parses `omarchy menu keybindings --print` lines: "SUPER + J    → Toggle window split".
  function parse(text) {
    var buckets = {}, order = root.groupRules.map(function(r) { return r.title }).concat(["Other"])
    order.forEach(function(t) { buckets[t] = [] })
    var workspaces = false, total = 0
    text.split("\n").forEach(function(line) {
      var m = line.match(/^SUPER \+ (.+?)\s+→\s+(.+)$/)
      if (!m || /MOUSE|mouse_/.test(m[1])) return
      var item = { key: root.label(m[1].replace(/SUPER \+ /g, "")), desc: m[2] }
      if (/^[0-9]$/.test(m[1]) && /workspace/i.test(m[2])) {
        if (workspaces) return
        workspaces = true
        item = { key: "1–0", desc: "Switch to workspace" }
      }
      var rule = root.groupRules.find(function(r) { return r.test.test(item.desc) })
      buckets[rule ? rule.title : "Other"].push(item)
      total++
    })
    root.count = total
    root.items = order.reduce(function(all, t) { return all.concat(buckets[t]) }, [])
    root.groups = order
      .filter(function(t) { return buckets[t].length > 0 })
      .map(function(t) { return { title: t, items: buckets[t] } })
  }

  // Suggests next keys from what's on screen. Rules are matched against binding
  // descriptions, so rebinding a key keeps its suggestion. First rules win.
  function suggest(win, ws) {
    var n = ws.windows || 0
    var want = []
    if (n === 0) want = [/^Terminal$/, /^Omarchy menu$/, /^Switch to workspace$/, /^Keybindings$/]
    else {
      if (win.fullscreen > 0) want.push(/^Full screen$/)
      if (win.grouped && win.grouped.length > 0) want.push(/window grouping/)
      if (win.floating) want.push(/^Pop window out/)
      if (n >= 3) want.push(/^Jump to window$/, /^Last window$/, /^Toggle window split$/)
      else if (n === 2) want.push(/^Last window$/, /^Toggle window split$/, /^Full screen$/)
      else want.push(/^Full screen$/, /^Terminal$/, /^Close window$/)
      want.push(/^Next workspace$/)
    }
    var out = []
    want.forEach(function(re) {
      if (out.length >= 4) return
      var hit = root.items.find(function(i) { return re.test(i.desc) })
      if (hit && out.indexOf(hit) === -1) out.push(hit)
    })
    root.suggested = out
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
