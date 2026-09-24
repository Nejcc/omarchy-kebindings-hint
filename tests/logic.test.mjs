// Unit tests for Logic.js. Run with: node --test tests/*.test.mjs
// Logic.js is a QML JavaScript library, so it's loaded into a sandbox with its
// `.pragma library` line stripped. No dependencies needed.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const here = new URL(".", import.meta.url)
const source = readFileSync(new URL("../Logic.js", here), "utf8").replace(/^\.pragma library\s*$/m, "")
const L = vm.createContext({})
vm.runInContext(source, L)
// Values created inside the sandbox have their own prototypes; round-trip
// through JSON before deep comparisons.
const plain = (v) => JSON.parse(JSON.stringify(v))

const fixture = readFileSync(new URL("fixture-keybindings.txt", here), "utf8")
const parsed = L.parse(fixture)
const item = (desc) => parsed.items.find((i) => i.desc === desc)

// ------------------------------------------------------------------- label

test("label: maps key names to keycap symbols", () => {
  assert.equal(L.label("APOSTROPHE"), "'")
  assert.equal(L.label("SEMICOLON"), ";")
  assert.equal(L.label("BACKSPACE"), "⌫")
  assert.equal(L.label("LEFT"), "←")
  assert.equal(L.label("RETURN"), "⏎")
})

test("label: joins alternatives and leaves unknown keys alone", () => {
  assert.equal(L.label("W / Q"), "W Q")
  assert.equal(L.label("S / ~"), "S ~")
  assert.equal(L.label("F13"), "F13")
})

test("label: ignores inherited object keys", () => {
  assert.equal(L.label("constructor"), "constructor")
  assert.equal(L.label("toString"), "toString")
})

// ------------------------------------------------------------------- parse

test("parse: reads the real Omarchy list", () => {
  assert.ok(parsed.count > 25, `only ${parsed.count} bindings parsed`)
  assert.equal(parsed.items.length, parsed.count)
  assert.deepEqual(plain(item("Toggle window split")), { key: "J", desc: "Toggle window split" })
})

test("parse: keeps only plain SUPER + key bindings", () => {
  for (const i of parsed.items) assert.ok(!/SUPER|SHIFT|CTRL|ALT/.test(i.key), `modifier leaked into ${i.key}`)
  assert.equal(item("File manager"), undefined) // SUPER SHIFT + F
})

test("parse: skips mouse bindings", () => {
  for (const i of parsed.items) assert.ok(!/mouse/i.test(i.key), `mouse binding ${i.key}`)
})

test("parse: folds the ten workspace keys into one entry", () => {
  const ws = parsed.items.filter((i) => i.desc === "Switch to workspace")
  assert.equal(ws.length, 1)
  assert.equal(ws[0].key, "1–0")
  assert.ok(!parsed.items.some((i) => /^Switch to workspace \d+$/.test(i.desc)))
})

test("parse: groups bindings and puts every one in exactly one group", () => {
  const titles = parsed.groups.map((g) => g.title)
  assert.deepEqual(plain(titles.filter((t) => t !== "Other")),
    plain(L.GROUP_RULES.map((r) => r.title).filter((t) => titles.includes(t))))
  const total = parsed.groups.reduce((n, g) => n + g.items.length, 0)
  assert.equal(total, parsed.count)
  assert.ok(parsed.groups.every((g) => g.items.length > 0), "empty group rendered")
  const groupOf = (desc) => parsed.groups.find((g) => g.items.some((i) => i.desc === desc)).title
  assert.equal(groupOf("Universal copy"), "Clipboard")
  assert.equal(groupOf("Focus on left window"), "Focus")
  assert.equal(groupOf("Toggle window split"), "Windows")
  assert.equal(groupOf("Terminal"), "Apps & menus")
})

test("parse: survives empty, null and garbage input", () => {
  for (const input of ["", null, undefined, "\n\n", "not a keybinding\n→ →"]) {
    const r = L.parse(input)
    assert.equal(r.count, 0)
    assert.equal(r.groups.length, 0)
  }
})

test("parse: handles Windows line endings and trailing spaces", () => {
  const r = L.parse("SUPER + J        → Toggle window split   \r\nSUPER + K    → Keybindings\r\n")
  assert.deepEqual(plain(r.items.map((i) => i.desc).sort()), ["Keybindings", "Toggle window split"])
})

test("parse: keeps an arrow inside a description", () => {
  const r = L.parse("SUPER + X      → Move left → right")
  assert.equal(r.items[0].desc, "Move left → right")
})

test("parse: a lone digit that isn't a workspace switch stays separate", () => {
  const r = L.parse("SUPER + 5      → Open calculator")
  assert.deepEqual(plain(r.items[0]), { key: "5", desc: "Open calculator" })
})

test("parse: large input stays fast", () => {
  const big = Array.from({ length: 20000 }, (_, i) => `SUPER + F${i}   → Action number ${i}`).join("\n")
  const t0 = performance.now()
  const r = L.parse(big)
  assert.equal(r.count, 20000)
  assert.ok(performance.now() - t0 < 1000, "parse took over a second")
})

// ------------------------------------------------------------- neededWidth

const widthOpts = { charWidth: 8, maxRows: 6, minKeyWidth: 54, keyPad: 8, gap: 8, columnGap: 18 }

test("neededWidth: grows with the longest description in each column", () => {
  const short = [{ title: "A", items: [{ key: "J", desc: "Split" }] }]
  const long = [{ title: "A", items: [{ key: "J", desc: "Split the window in two" }] }]
  assert.ok(L.neededWidth(long, widthOpts) > L.neededWidth(short, widthOpts))
})

test("neededWidth: a group past maxRows wraps into another column", () => {
  const items = Array.from({ length: 7 }, (_, i) => ({ key: "K", desc: "Item " + i }))
  const one = L.neededWidth([{ title: "A", items: items.slice(0, 6) }], widthOpts)
  const two = L.neededWidth([{ title: "A", items }], widthOpts)
  assert.ok(two > one * 1.9, "seventh item didn't start a second column")
})

test("neededWidth: empty input needs no width", () => {
  assert.equal(L.neededWidth([], widthOpts), 0)
  assert.equal(L.neededWidth(null, widthOpts), 0)
})

// ---------------------------------------------------------------- actionFor

test("actionFor: maps Hyprland events to binding descriptions", () => {
  assert.ok(L.actionFor("workspace", "3").test("Switch to workspace"))
  assert.ok(L.actionFor("fullscreen", "1").test("Full screen"))
  assert.ok(L.actionFor("closewindow", "abc").test("Close window"))
  assert.ok(L.actionFor("activespecial", "special:scratchpad,eDP-1").test("Toggle scratchpad"))
  assert.ok(L.actionFor("togglegroup", "1,abc").test("Toggle window grouping"))
  assert.ok(L.actionFor("changefloatingmode", "abc,1").test("Pop window out (float & pin)"))
})

test("actionFor: only terminal windows count as the Terminal key", () => {
  for (const cls of ["foot", "kitty", "Alacritty", "com.mitchellh.ghostty"])
    assert.ok(L.actionFor("openwindow", `addr,1,${cls},title`), cls)
  assert.equal(L.actionFor("openwindow", "addr,1,brave-browser,Page"), null)
  assert.equal(L.actionFor("openwindow", "addr,1,footbar,x"), null)
  assert.equal(L.actionFor("openwindow", "addr,1,myfoot,x"), null)
  assert.equal(L.actionFor("openwindow", "addr,1,foot,title, with, commas").test("Terminal"), true)
})

test("actionFor: ignores unrelated and malformed events", () => {
  for (const [name, data] of [["activewindow", "x"], ["", ""], ["openwindow", null], ["openwindow", undefined], [undefined, undefined]])
    assert.equal(L.actionFor(name, data), null)
})

// ------------------------------------------------------------------- record

const fresh = () => ({ transitions: {}, lastAction: "", lastActionAt: 0 })

test("record: counts what follows what", () => {
  let s = fresh()
  s = L.record(s, "workspace", "2", parsed.items, 1000)
  s = L.record(s, "fullscreen", "1", parsed.items, 2000)
  s = L.record(s, "workspace", "3", parsed.items, 3000)
  assert.deepEqual(plain(s.transitions), {
    "Switch to workspace": { "Full screen": 1 },
    "Full screen": { "Switch to workspace": 1 }
  })
  assert.equal(s.lastAction, "Switch to workspace")
})

test("record: the first action only sets the starting point", () => {
  const s = L.record(fresh(), "fullscreen", "1", parsed.items, 1000)
  assert.deepEqual(plain(s.transitions), {})
  assert.equal(s.lastAction, "Full screen")
})

test("record: one key firing several events counts once", () => {
  let s = L.record(fresh(), "fullscreen", "1", parsed.items, 1000)
  s = L.record(s, "workspace", "2", parsed.items, 2000)
  s = L.record(s, "workspace", "2", parsed.items, 2100) // same action within 400ms
  assert.deepEqual(plain(s.transitions), { "Full screen": { "Switch to workspace": 1 } })
  s = L.record(s, "workspace", "3", parsed.items, 3000) // later: a real second switch
  assert.equal(s.transitions["Switch to workspace"]["Switch to workspace"], 1)
})

test("record: doesn't modify the state it was given", () => {
  const start = L.record(fresh(), "fullscreen", "1", parsed.items, 1000)
  const snapshot = JSON.stringify(start)
  L.record(start, "workspace", "2", parsed.items, 2000)
  assert.equal(JSON.stringify(start), snapshot)
})

test("record: ignores events whose binding the user doesn't have", () => {
  const items = parsed.items.filter((i) => i.desc !== "Full screen")
  const s0 = fresh()
  assert.equal(L.record(s0, "fullscreen", "1", items, 1000), s0)
  assert.equal(L.record(s0, "activewindow", "x", parsed.items, 1000), s0)
})

// Pollution would land on the sandbox's own Object.prototype, so check there.
const sandboxPolluted = () => vm.runInContext("({}).polluted !== undefined || ({})['Full screen'] !== undefined", L)

test("record: a binding described as __proto__ can't pollute objects", () => {
  const items = [{ key: "X", desc: "__proto__" }, { key: "F", desc: "Full screen" }]
  let s = L.record(fresh(), "fullscreen", "1", items, 1000)
  s = L.record(s, "fullscreen", "0", items, 5000)
  assert.equal(sandboxPolluted(), false)
})

test("record: a long random event stream stays consistent", () => {
  const names = ["workspace", "fullscreen", "closewindow", "activespecial", "togglegroup",
    "changefloatingmode", "openwindow", "activewindow", "mousemove", ""]
  let s = fresh(), now = 0, counted = 0
  let seed = 42
  const rand = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648
  for (let i = 0; i < 20000; i++) {
    now += Math.floor(rand() * 900)
    const before = s
    s = L.record(s, names[Math.floor(rand() * names.length)], "addr,1,foot,title", parsed.items, now)
    if (s !== before && before.lastAction) counted++
  }
  const total = Object.values(s.transitions).reduce((n, m) => n + Object.values(m).reduce((a, b) => a + b, 0), 0)
  assert.equal(total, counted)
  for (const m of Object.values(s.transitions))
    for (const n of Object.values(m)) assert.ok(Number.isInteger(n) && n > 0)
})

// -------------------------------------------------------------- learnedNext

test("learnedNext: nothing before the first action", () => {
  assert.deepEqual(plain(L.learnedNext("", {}, parsed.items)), [])
})

test("learnedNext: starter habits show up before anything is learned", () => {
  const next = L.learnedNext("Full screen", {}, parsed.items).map((i) => i.desc)
  assert.deepEqual(plain(next), ["Full screen", "Switch to workspace"])
})

test("learnedNext: starter order holds when counts tie", () => {
  const next = L.learnedNext("Terminal", {}, parsed.items).map((i) => i.desc)
  assert.deepEqual(plain(next), ["Terminal", "Full screen", "Switch to workspace"])
})

test("learnedNext: starter order holds even if the engine's sort isn't stable", () => {
  // Qt's JavaScript engine isn't guaranteed to sort stably like Node does, so
  // run the same code with a sort that scrambles ties.
  const U = vm.createContext({})
  vm.runInContext(`
    const stable = Array.prototype.sort
    Array.prototype.sort = function(cmp) { this.reverse(); return stable.call(this, cmp) }
  `, U)
  vm.runInContext(source, U)
  const next = U.learnedNext("Terminal", {}, parsed.items).map((i) => i.desc)
  assert.deepEqual(plain(next), ["Terminal", "Full screen", "Switch to workspace"])
})

test("learnedNext: real habits outrank starter habits", () => {
  const t = { "Full screen": { "Close window": 3 } }
  const next = L.learnedNext("Full screen", t, parsed.items).map((i) => i.desc)
  assert.equal(next[0], "Close window")
})

test("learnedNext: a move seen once isn't suggested yet", () => {
  const t = { "Toggle scratchpad": { "Close window": 1 } }
  const next = L.learnedNext("Toggle scratchpad", t, parsed.items).map((i) => i.desc)
  assert.ok(!next.includes("Close window"))
  const t2 = { "Toggle scratchpad": { "Close window": 2 } }
  assert.ok(L.learnedNext("Toggle scratchpad", t2, parsed.items).some((i) => i.desc === "Close window"))
})

test("learnedNext: skips habits for bindings that no longer exist", () => {
  const t = { "Full screen": { "Removed binding": 50 } }
  const next = L.learnedNext("Full screen", t, parsed.items).map((i) => i.desc)
  assert.ok(!next.includes("Removed binding"))
})

test("learnedNext: an action named like an Object method doesn't crash", () => {
  assert.deepEqual(plain(L.learnedNext("constructor", {}, parsed.items)), [])
  assert.deepEqual(plain(L.learnedNext("toString", {}, parsed.items)), [])
})

// ---------------------------------------------------------------- loadSaved

test("loadSaved: round-trips a normal file", () => {
  const saved = { version: 1, learning: true, transitions: { "Full screen": { "Switch to workspace": 4 } } }
  assert.deepEqual(plain(L.loadSaved(JSON.stringify(saved))), { learning: true, transitions: saved.transitions })
})

test("loadSaved: corrupt or empty files fall back to defaults", () => {
  for (const text of ["", "{", "null", "[]", "42", "\"x\"", "{\"learning\": \"yes\"}"]) {
    const r = L.loadSaved(text)
    assert.equal(r.learning, false, text)
    assert.deepEqual(plain(r.transitions), {}, text)
  }
})

test("loadSaved: drops bad counts and dangerous keys", () => {
  // Raw JSON on purpose: in a JS object literal "__proto__" sets the prototype
  // instead of becoming a key, so JSON.stringify would silently drop it.
  const text = `{
    "learning": true,
    "transitions": {
      "Full screen": { "A": 3, "B": -1, "C": "7", "D": null, "E": 2.9, "F": 0 },
      "__proto__": { "polluted": 1 },
      "Terminal": "not an object",
      "constructor": { "x": 1 },
      "prototype": { "x": 1 },
      "Close window": { "__proto__": 5, "Terminal": 1e308 }
    }
  }`
  const r = L.loadSaved(text)
  assert.deepEqual(plain(r.transitions), { "Full screen": { "A": 3, "E": 2 }, "Close window": { "Terminal": 1e308 } })
  assert.equal(sandboxPolluted(), false)
})

test("loadSaved: infinite and NaN counts are dropped", () => {
  const r = L.loadSaved('{"learning":true,"transitions":{"A":{"B":1e999}}}')
  assert.deepEqual(plain(r.transitions), {})
})

// ------------------------------------------------------------------ suggest

const descs = (list) => list.map((i) => i.desc)

test("suggest: empty workspace suggests getting started", () => {
  assert.deepEqual(plain(descs(L.suggest({}, { windows: 0 }, parsed.items, []))),
    ["Terminal", "Omarchy menu", "Switch to workspace", "Keybindings"])
})

test("suggest: window counts pick the right moves", () => {
  assert.deepEqual(plain(descs(L.suggest({}, { windows: 1 }, parsed.items, []))),
    ["Full screen", "Terminal", "Close window", "Next workspace"])
  assert.deepEqual(plain(descs(L.suggest({}, { windows: 2 }, parsed.items, []))),
    ["Last window", "Toggle window split", "Full screen", "Next workspace"])
  assert.deepEqual(plain(descs(L.suggest({}, { windows: 5 }, parsed.items, []))),
    ["Jump to window", "Last window", "Toggle window split", "Next workspace"])
})

test("suggest: window state goes first", () => {
  assert.equal(descs(L.suggest({ fullscreen: 1 }, { windows: 3 }, parsed.items, []))[0], "Full screen")
  assert.equal(descs(L.suggest({ floating: true }, { windows: 1 }, parsed.items, []))[0], "Pop window out (float & pin)")
  assert.equal(descs(L.suggest({ grouped: ["a", "b"] }, { windows: 2 }, parsed.items, []))[0], "Toggle window grouping")
})

test("suggest: never more than four, never a duplicate", () => {
  const win = { fullscreen: 2, floating: true, grouped: ["a"] }
  for (const n of [0, 1, 2, 3, 10]) {
    const out = descs(L.suggest(win, { windows: n }, parsed.items, [item("Full screen"), item("Terminal")]))
    assert.ok(out.length <= 4)
    assert.equal(new Set(out).size, out.length, `duplicate in ${out}`)
  }
})

test("suggest: learned moves lead, at most two of them", () => {
  const learned = [item("Close window"), item("Terminal"), item("Universal copy")]
  const out = descs(L.suggest({}, { windows: 2 }, parsed.items, learned))
  assert.deepEqual(plain(out.slice(0, 2)), ["Close window", "Terminal"])
  assert.ok(!out.includes("Universal copy"))
})

test("suggest: missing or odd hyprctl data doesn't crash", () => {
  for (const [win, ws] of [[null, null], [undefined, undefined], [{}, {}], [{ grouped: "x" }, { windows: "3" }], ["x", 5]])
    assert.ok(Array.isArray(L.suggest(win, ws, parsed.items, [])))
})

test("suggest: bindings the user removed are skipped", () => {
  const items = parsed.items.filter((i) => i.desc !== "Last window")
  assert.ok(!descs(L.suggest({}, { windows: 2 }, items, [])).includes("Last window"))
})

test("suggest: no bindings, no suggestions", () => {
  assert.deepEqual(plain(L.suggest({}, { windows: 2 }, [], [])), [])
})

// -------------------------------------------------------------- readPayload

test("readPayload: plain summons show the bar", () => {
  for (const p of ["", "{}", null, undefined, "garbage", "[]", "null", '{"other":1}'])
    assert.equal(L.readPayload(p).kind, "show", String(p))
})

test("readPayload: settings payloads", () => {
  assert.deepEqual(plain(L.readPayload('{"enabled":"toggle"}')), { kind: "enabled", value: "toggle" })
  assert.deepEqual(plain(L.readPayload('{"enabled":"off"}')), { kind: "enabled", value: "off" })
  assert.deepEqual(plain(L.readPayload('{"learning":"reset"}')), { kind: "learning", value: "reset" })
})

test("readPayload: unknown values are ignored, not treated as off", () => {
  assert.equal(L.readPayload('{"enabled":"maybe"}').kind, "ignore")
  assert.equal(L.readPayload('{"learning":true}').kind, "ignore")
  assert.equal(L.readPayload('{"learning":null}').kind, "ignore")
})
