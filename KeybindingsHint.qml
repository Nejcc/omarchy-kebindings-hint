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
  readonly property int totalColumns: groups.reduce(function(n, g) { return n + g.columns }, 0)

  function open(payloadJson) {
    root.opened = true
    hideTimer.restart()
    list.running = true   // refresh in the background; the cached list shows first
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
    root.groups = order
      .filter(function(t) { return buckets[t].length > 0 })
      .map(function(t) { return { title: t, items: buckets[t], columns: Math.ceil(buckets[t].length / root.maxRows) } })
  }

  Component.onCompleted: list.running = true

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
          }
          Text {
            anchors.left: superCap.right
            anchors.leftMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            text: "+ key"
            color: root.muted
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
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

        // Groups side by side; each gets width for as many columns as it wraps into.
        Row {
          id: columns
          width: parent.width
          spacing: root.pad
          readonly property real unit: (width - spacing * (root.totalColumns - 1)) / Math.max(1, root.totalColumns)

          Repeater {
            model: root.groups
            delegate: Column {
              id: group
              required property var modelData
              width: columns.unit * modelData.columns + columns.spacing * (modelData.columns - 1)
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
                columnSpacing: columns.spacing

                Repeater {
                  model: group.modelData.items
                  delegate: Row {
                    required property var modelData
                    width: columns.unit
                    spacing: Style.spacing.lg

                    Keycap { id: cap; label: modelData.key }
                    Text {
                      width: parent.width - cap.width - parent.spacing
                      anchors.verticalCenter: cap.verticalCenter
                      text: modelData.desc
                      color: root.text
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.title
                      elide: Text.ElideRight
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
    width: Math.max(filled ? 0 : Style.space(54), keyText.implicitWidth + Style.spacing.lg * 2)
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
      font.pixelSize: Style.font.title
      font.bold: true
    }
  }
}
