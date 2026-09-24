.pragma library

// Pure logic for the keybindings hint, kept free of QML so it can be tested
// with plain Node (see tests/). Nothing in here touches the screen or files.

// Short labels, the way the keycaps read.
var SYMBOLS = {
  APOSTROPHE: "'", SEMICOLON: ";", COMMA: ",", PERIOD: ".", SLASH: "/", BACKSLASH: "\\",
  MINUS: "-", EQUAL: "=", GRAVE: "`", BACKSPACE: "⌫", RETURN: "⏎", ESCAPE: "Esc",
  SPACE: "Space", TAB: "Tab", PRINT: "PrtSc", Home: "Home",
  LEFT: "←", RIGHT: "→", UP: "↑", DOWN: "↓"
}

function label(key) {
  return String(key).split(" / ").map(function(k) {
    return Object.prototype.hasOwnProperty.call(SYMBOLS, k) ? SYMBOLS[k] : k
  }).join(" ")
}

// First match wins; anything unmatched lands in "Other".
// ponytail: grouped by words in the description; Omarchy's list has no categories.
var GROUP_RULES = [
  { title: "Workspaces",   test: /workspace|scratchpad/i },
  { title: "Focus",        test: /^focus|last window|jump to window/i },
  { title: "Windows",      test: /window|full ?screen|split|group|float|pseudo|expand|shrink/i },
  { title: "Clipboard",    test: /copy|paste|cut\b|select all/i },
  { title: "Apps & menus", test: /menu|terminal|keybindings|browser|file manager|picker|launch/i }
]

// Parses `omarchy menu keybindings --print` output, lines like
// "SUPER + J    → Toggle window split". Returns { groups, items, count }.
function parse(text) {
  var order = GROUP_RULES.map(function(r) { return r.title }).concat(["Other"])
  var buckets = {}
  order.forEach(function(t) { buckets[t] = [] })
  var workspaces = false, total = 0
  String(text || "").split(/\r?\n/).forEach(function(line) {
    var m = line.match(/^SUPER \+ (.+?)\s+→\s+(.+?)\s*$/)
    if (!m || /MOUSE|mouse_/.test(m[1])) return
    var item = { key: label(m[1].replace(/SUPER \+ /g, "")), desc: m[2] }
    if (/^[0-9]$/.test(m[1]) && /workspace/i.test(m[2])) {
      if (workspaces) return
      workspaces = true
      item = { key: "1–0", desc: "Switch to workspace" }
    }
    var rule = GROUP_RULES.find(function(r) { return r.test.test(item.desc) })
    buckets[rule ? rule.title : "Other"].push(item)
    total++
  })
  return {
    count: total,
    items: order.reduce(function(all, t) { return all.concat(buckets[t]) }, []),
    groups: order
      .filter(function(t) { return buckets[t].length > 0 })
      .map(function(t) { return { title: t, items: buckets[t] } })
  }
}

// Width the columns need at full size, estimated from character counts.
// o: { charWidth, maxRows, minKeyWidth, keyPad, gap, columnGap }
function neededWidth(groups, o) {
  var total = 0, cols = 0
  ;(groups || []).forEach(function(g) {
    for (var i = 0; i < g.items.length; i += o.maxRows) {
      var chunk = g.items.slice(i, i + o.maxRows), key = 0, desc = 0
      chunk.forEach(function(it) { key = Math.max(key, it.key.length); desc = Math.max(desc, it.desc.length) })
      total += Math.max(o.minKeyWidth, key * o.charWidth + o.keyPad * 2) + o.gap + desc * o.charWidth
      cols++
    }
  })
  return total + o.columnGap * Math.max(0, cols - 1)
}

// ------------------------------------------------------------------ learning

// A learned move needs to have happened this often before it's suggested.
var MIN_SEEN = 2
// Limits on what's kept. A real file has a few dozen entries and stays under
// 10 KB; anything bigger is ignored rather than parsed on the shell's UI
// thread, where a slow parse can make Hyprland drop the shell's event stream.
var MAX_FILE_CHARS = 1000000
var MAX_ACTIONS = 100
var MAX_NEXT = 100
// The same action again within this many ms is one key firing several events.
var DEDUPE_MS = 400

// Starter habits, written by hand (not recorded) so learning helps from the
// first minute. Each counts as seen MIN_SEEN times, so anything you really do
// more often outranks it.
var STARTER_HABITS = {
  "Terminal":               ["Terminal", "Full screen", "Switch to workspace"],
  "Switch to workspace":    ["Switch to workspace", "Terminal", "Full screen"],
  "Full screen":            ["Full screen", "Switch to workspace"],
  "Close window":           ["Terminal", "Switch to workspace"],
  "Toggle scratchpad":      ["Toggle scratchpad"],
  "Toggle window grouping": ["Toggle window grouping"]
}

var TERMINAL_CLASSES = /^(foot|kitty|Alacritty|alacritty|com\.mitchellh\.ghostty|ghostty)$/

// Hyprland event -> pattern for the binding description it most likely came from.
// ponytail: a guess; a workspace switch by mouse or another plugin counts too.
function actionFor(name, data) {
  var parts = String(data == null ? "" : data).split(",")
  switch (name) {
    case "workspace": return /^Switch to workspace$/
    case "fullscreen": return /^Full screen$/
    case "closewindow": return /^Close window$/
    case "activespecial": return /scratchpad/i
    case "togglegroup": return /window grouping/i
    case "changefloatingmode": return /float/i
    case "openwindow": return TERMINAL_CLASSES.test(parts[2] || "") ? /^Terminal$/ : null
  }
  return null
}

// Keys that must never become object properties (a hand-edited or hostile
// learned file could otherwise reach Object.prototype).
function safeKey(k) {
  return typeof k === "string" && k.length > 0 && k.length <= 200
    && k !== "__proto__" && k !== "constructor" && k !== "prototype"
}

// Folds one Hyprland event into the learning state. Returns the new state; the
// input is not modified. state: { transitions, lastAction, lastActionAt }
function record(state, name, data, items, now) {
  var re = actionFor(name, data)
  if (!re) return state
  var item = (items || []).find(function(i) { return re.test(i.desc) })
  if (!item || !safeKey(item.desc)) return state
  if (item.desc === state.lastAction && now - state.lastActionAt < DEDUPE_MS) return state
  var transitions = state.transitions
  if (state.lastAction) {
    // Copy only what changes: the outer map (small) and the one row. Copying
    // everything on every event is what made big files freeze the shell.
    var old = state.transitions
    var has = Object.prototype.hasOwnProperty
    var sources = Object.keys(old)
    if (!has.call(old, state.lastAction) && sources.length >= MAX_ACTIONS) return state
    transitions = {}
    sources.forEach(function(a) { transitions[a] = old[a] })
    var row = {}
    var oldRow = has.call(old, state.lastAction) ? old[state.lastAction] : {}
    Object.keys(oldRow).forEach(function(b) { row[b] = oldRow[b] })
    if (!has.call(row, item.desc) && Object.keys(row).length >= MAX_NEXT) return state
    row[item.desc] = (row[item.desc] || 0) + 1
    transitions[state.lastAction] = row
  }
  return { transitions: transitions, lastAction: item.desc, lastActionAt: now }
}

// Most common next moves after lastAction, best first, as items.
function learnedNext(lastAction, transitions, items) {
  if (!lastAction) return []
  var next = {}
  // Tiny offsets keep the starter list's order when counts tie.
  var starter = Object.prototype.hasOwnProperty.call(STARTER_HABITS, lastAction) ? STARTER_HABITS[lastAction] : []
  starter.forEach(function(d, i) { next[d] = MIN_SEEN + (9 - i) / 100 })
  var mine = transitions && Object.prototype.hasOwnProperty.call(transitions, lastAction) ? transitions[lastAction] : {}
  Object.keys(mine).forEach(function(d) { next[d] = (next[d] || 0) + mine[d] })
  return Object.keys(next)
    .filter(function(d) { return next[d] >= MIN_SEEN })
    .sort(function(a, b) { return next[b] - next[a] })
    .map(function(d) { return (items || []).find(function(i) { return i.desc === d }) })
    .filter(function(i) { return !!i })
}

// Reads a saved learned file, dropping anything malformed instead of failing.
// Returns null when the file can't be used at all (empty, cut off, not an
// object): the caller then keeps what it has, so a damaged or half-written
// file never switches learning off or forgets everything.
function loadSaved(text) {
  var saved
  if (typeof text !== "string" || text.length > MAX_FILE_CHARS) return null
  try { saved = JSON.parse(text) } catch (e) { return null }
  if (!saved || typeof saved !== "object" || Array.isArray(saved)) return null
  var transitions = {}
  var raw = saved.transitions && typeof saved.transitions === "object" ? saved.transitions : {}
  var kept = 0
  Object.keys(raw).forEach(function(a) {
    if (kept >= MAX_ACTIONS || !safeKey(a) || !raw[a] || typeof raw[a] !== "object") return
    var next = 0
    Object.keys(raw[a]).forEach(function(b) {
      var n = raw[a][b]
      if (next >= MAX_NEXT || !safeKey(b) || typeof n !== "number" || !isFinite(n) || n <= 0) return
      if (!transitions[a]) { transitions[a] = {}; kept++ }
      transitions[a][b] = Math.floor(n)
      next++
    })
  })
  return { learning: saved.learning === true, transitions: transitions }
}

// ---------------------------------------------------------------- suggestions

// Suggests up to four items from what's on screen, with learned next moves
// (up to two) first. Rules match binding descriptions, so rebinding a key
// keeps its suggestion. win/ws are `hyprctl activewindow/activeworkspace -j`.
function suggest(win, ws, items, learned) {
  win = win || {}
  ws = ws || {}
  var n = typeof ws.windows === "number" ? ws.windows : 0
  var want = []
  if (n === 0) want = [/^Terminal$/, /^Omarchy menu$/, /^Switch to workspace$/, /^Keybindings$/]
  else {
    if (win.fullscreen > 0) want.push(/^Full screen$/)
    if (Array.isArray(win.grouped) && win.grouped.length > 0) want.push(/window grouping/)
    if (win.floating === true) want.push(/^Pop window out/)
    if (n >= 3) want.push(/^Jump to window$/, /^Last window$/, /^Toggle window split$/)
    else if (n === 2) want.push(/^Last window$/, /^Toggle window split$/, /^Full screen$/)
    else want.push(/^Full screen$/, /^Terminal$/, /^Close window$/)
    want.push(/^Next workspace$/)
  }
  var out = []
  ;(learned || []).forEach(function(it) {
    if (out.length < 2 && it && out.indexOf(it) === -1) out.push(it)
  })
  want.forEach(function(re) {
    if (out.length >= 4) return
    var hit = (items || []).find(function(i) { return re.test(i.desc) })
    if (hit && out.indexOf(hit) === -1) out.push(hit)
  })
  return out
}

// Payloads that switch settings instead of showing the bar. Returns
// { kind: "show" } or { kind: "enabled"|"learning", value }.
function readPayload(json) {
  var p
  try { p = JSON.parse(json || "{}") } catch (e) { return { kind: "show" } }
  if (!p || typeof p !== "object") return { kind: "show" }
  if (p.learning !== undefined) {
    var l = String(p.learning)
    return ["on", "off", "toggle", "reset"].indexOf(l) !== -1 ? { kind: "learning", value: l } : { kind: "ignore" }
  }
  if (p.enabled !== undefined) {
    var e = String(p.enabled)
    return ["on", "off", "toggle"].indexOf(e) !== -1 ? { kind: "enabled", value: e } : { kind: "ignore" }
  }
  return { kind: "show" }
}
