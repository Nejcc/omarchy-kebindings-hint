import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons

// A which-key style bar: lists every SUPER + key binding along the bottom of the
// screen. It never takes the keyboard, so pressing a key while it shows still
// runs that binding.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property var hints: []   // [{ key, desc }]

  // Safety net: a release bind can be missed, so the bar never stays up for long.
  readonly property int autoHideMs: 6000

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

  // Parses `omarchy menu keybindings --print` lines: "SUPER + J    → Toggle window split".
  function parse(text) {
    var out = [], workspaces = false
    text.split("\n").forEach(function(line) {
      var m = line.match(/^SUPER \+ (.+?)\s+→\s+(.+)$/)
      if (!m || /MOUSE|mouse_/.test(m[1])) return
      if (/^[0-9]$/.test(m[1]) && /workspace/i.test(m[2])) {
        if (!workspaces) out.push({ key: "1 … 0", desc: "Switch to workspace" })
        workspaces = true
        return
      }
      out.push({ key: root.label(m[1].replace(/SUPER \+ /g, "")), desc: m[2] })
    })
    return out
  }

  Component.onCompleted: list.running = true

  Process {
    id: list
    command: ["omarchy", "menu", "keybindings", "--print"]
    stdout: StdioCollector { onStreamFinished: root.hints = root.parse(text) }
  }

  Timer {
    id: hideTimer
    interval: root.autoHideMs
    onTriggered: root.dismiss()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { bottom: true; left: true; right: true }
    margins { bottom: Style.gapsOut; left: Style.gapsOut; right: Style.gapsOut }
    implicitHeight: card.implicitHeight
    color: "transparent"
    WlrLayershell.namespace: "nejcc-keybindings-hint"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      id: card
      width: parent.width
      implicitHeight: grid.implicitHeight + Style.spacing.panelPadding * 2
      radius: Style.cornerRadius
      color: Color.menu.background
      border.color: Color.menu.border
      border.width: 2

      Flow {
        id: grid
        x: Style.spacing.panelPadding
        y: Style.spacing.panelPadding
        width: parent.width - Style.spacing.panelPadding * 2
        spacing: Style.spacing.sm

        Repeater {
          model: root.hints
          delegate: Row {
            required property var modelData
            // As many ~300px columns as fit, stretched to fill the bar.
            readonly property int columns: Math.max(1, Math.floor((grid.width + grid.spacing) / (Style.space(300) + grid.spacing)))
            width: Math.floor((grid.width + grid.spacing) / columns) - grid.spacing
            spacing: Style.spacing.md

            Text {
              width: Style.space(60)
              horizontalAlignment: Text.AlignRight
              text: modelData.key
              color: Color.menu.selectedText
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideLeft
            }
            Text {
              width: parent.width - Style.space(60) - parent.spacing
              text: modelData.desc
              color: Color.menu.text
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
