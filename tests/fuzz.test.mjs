// Fuzz tests for Logic.js: random keybinding lists, Hyprland event streams,
// settings files and payloads, checked against invariants. Seeded, so
// failures reproduce.
// Run with: node --test tests/*.test.mjs   (FUZZ_ROUNDS=200000 for a long run)
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const here = new URL(".", import.meta.url)
const source = readFileSync(new URL("../Logic.js", here), "utf8").replace(/^\.pragma library\s*$/m, "")
const L = vm.createContext({})
vm.runInContext(source, L)
const ROUNDS = Number(process.env.FUZZ_ROUNDS || 20000)
const real = L.parse(readFileSync(new URL("fixture-keybindings.txt", here), "utf8")).items

function rng(seed) {
  let s = seed >>> 0
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296)
}
const pick = (r, a) => a[Math.floor(r() * a.length)]
const junk = [null, undefined, 0, -1, NaN, Infinity, "", "x", [], {}, true, "__proto__", "constructor", "toString",
  "a".repeat(10000), "😀", "‮", "$(x)", "\u0000", "→", " → ", "SUPER + ", "SUPER + X → "]

function line(r) {
  const key = pick(r, ["J", "K", "SPACE", "RETURN", "1", "0", "LEFT", "W / Q", "S / ~", "mouse_up", "LEFT MOUSE BUTTON",
    "APOSTROPHE", "constructor", "__proto__", "😀", ""])
  const desc = r() < 0.8 ? pick(r, real).desc : String(pick(r, junk))
  const mods = pick(r, ["SUPER + ", "SUPER + ", "SUPER SHIFT + ", "SUPER CTRL + ", "", "SUPER +"])
  const sep = pick(r, ["    → ", " → ", "→", " -> ", "\t→\t"])
  return r() < 0.9 ? mods + key + sep + desc : String(pick(r, junk))
}

test("fuzz parse: random keybinding lists never throw and stay consistent", () => {
  const r = rng(11)
  for (let i = 0; i < ROUNDS / 10; i++) {
    const text = Array.from({ length: Math.floor(r() * 80) }, () => line(r)).join(pick(r, ["\n", "\r\n", "\n\n"]))
    let p
    assert.doesNotThrow(() => { p = L.parse(text) }, `round ${i}`)
    assert.equal(p.items.length, p.count)
    assert.equal(p.groups.reduce((n, g) => n + g.items.length, 0), p.count)
    assert.ok(p.groups.every((g) => g.items.length > 0))
    assert.ok(p.items.filter((it) => it.desc === "Switch to workspace" && it.key === "1–0").length <= 1)
    for (const it of p.items) assert.ok(typeof it.key === "string" && typeof it.desc === "string" && it.desc.length > 0)
  }
})

test("fuzz learning: long random event streams keep counts sane and objects clean", () => {
  const r = rng(12)
  const events = ["workspace", "fullscreen", "closewindow", "activespecial", "togglegroup", "changefloatingmode",
    "openwindow", "activewindow", "mousemove", "", "__proto__", "constructor"]
  const items = real.concat([{ key: "X", desc: "__proto__" }, { key: "Y", desc: "constructor" }])
  let s = { transitions: {}, lastAction: "", lastActionAt: 0 }, now = 0
  for (let i = 0; i < ROUNDS * 5; i++) {
    now += Math.floor(r() * 1200)
    const data = pick(r, ["1", "addr,1,foot,title", "addr,1,brave-browser,x", ",,,", "", null, "a,b,kitty"])
    assert.doesNotThrow(() => { s = L.record(s, pick(r, events), data, items, now) }, `event ${i}`)
  }
  for (const [a, next] of Object.entries(s.transitions)) {
    assert.ok(!["__proto__", "constructor", "prototype"].includes(a), a)
    for (const [b, n] of Object.entries(next)) {
      assert.ok(Number.isInteger(n) && n > 0, `${a} -> ${b}: ${n}`)
      assert.ok(real.some((it) => it.desc === b), `learned a move that isn't a binding: ${b}`)
    }
  }
  assert.equal(vm.runInContext("({}).polluted === undefined && Object.keys(Object.prototype).length === 0", L), true)
})

test("fuzz loadSaved: hostile settings files never throw or pollute", () => {
  const r = rng(13)
  const val = (depth) => {
    if (depth > 3 || r() < 0.4) return pick(r, junk.filter((j) => j !== undefined))
    if (r() < 0.5) return Array.from({ length: Math.floor(r() * 4) }, () => val(depth + 1))
    const o = {}
    for (let i = 0; i < Math.floor(r() * 5); i++) o[String(pick(r, junk.concat(real.map((x) => x.desc))))] = val(depth + 1)
    return o
  }
  for (let i = 0; i < ROUNDS; i++) {
    let text = JSON.stringify({ learning: val(2), transitions: val(0) })
    if (r() < 0.2) text = text.replace(/"(transitions|[A-Z][a-z]+[^"]*)"/, '"__proto__"')
    if (r() < 0.05) text = text.slice(0, Math.floor(r() * text.length))
    let out
    assert.doesNotThrow(() => { out = L.loadSaved(text) }, text.slice(0, 200))
    if (out === null) continue
    assert.equal(typeof out.learning, "boolean")
    for (const [a, next] of Object.entries(out.transitions))
      for (const n of Object.values(next)) assert.ok(Number.isInteger(n) && n > 0, `${a}: ${n}`)
  }
  assert.equal(vm.runInContext("({}).polluted === undefined && Object.keys(Object.prototype).length === 0", L), true)
})

test("fuzz loadSaved: an oversized file is ignored, a big allowed one loads fast", () => {
  const make = (n) => {
    const t = {}
    for (let a = 0; a < n; a++) { t["A" + a] = {}; for (let b = 0; b < n; b++) t["A" + a]["B" + b] = b + 1 }
    return JSON.stringify({ learning: true, transitions: t })
  }
  const over = make(340)                        // ~1.2 MB
  assert.ok(over.length > L.MAX_FILE_CHARS)
  assert.equal(L.loadSaved(over), null)
  const text = make(300)                        // ~930 KB, allowed but capped
  assert.ok(text.length < L.MAX_FILE_CHARS)
  const t0 = performance.now()
  const out = L.loadSaved(text)
  assert.equal(Object.keys(out.transitions).length, L.MAX_ACTIONS)
  assert.ok(performance.now() - t0 < 200, `${Math.round(performance.now() - t0)} ms for ${text.length} bytes`)
})

test("fuzz suggest: any screen state gives at most four distinct real bindings", () => {
  const r = rng(14)
  for (let i = 0; i < ROUNDS; i++) {
    const win = r() < 0.9 ? { fullscreen: pick(r, [0, 1, 2, "x", null]), floating: pick(r, [true, false, 1, "yes"]),
      grouped: pick(r, [[], ["a"], "x", null, {}]) } : pick(r, junk)
    const ws = r() < 0.9 ? { windows: pick(r, [0, 1, 2, 3, 9, -1, "2", NaN, null]) } : pick(r, junk)
    const learned = Array.from({ length: Math.floor(r() * 5) }, () => pick(r, real))
    let out
    assert.doesNotThrow(() => { out = L.suggest(win, ws, real, learned) }, `round ${i}`)
    assert.ok(out.length <= 4)
    assert.equal(new Set(out.map((x) => x.desc)).size, out.length, "duplicate suggestion")
    for (const it of out) assert.ok(real.includes(it))
  }
})

test("fuzz readPayload and label: never throw", () => {
  const r = rng(15)
  for (let i = 0; i < ROUNDS; i++) {
    const p = pick(r, junk.concat(['{"enabled":' + pick(r, ['"on"', '"x"', "1", "null", "{}"]) + "}",
      '{"learning":' + pick(r, ['"reset"', '"toggle"', "[]", "true"]) + "}", "{", "[]"]))
    let out
    assert.doesNotThrow(() => { out = L.readPayload(p); L.label(p) }, String(p))
    assert.ok(["show", "enabled", "learning", "ignore"].includes(out.kind))
  }
})

test("fuzz neededWidth: finite for any bindings", () => {
  const r = rng(16)
  const o = { charWidth: 8, maxRows: 6, minKeyWidth: 54, keyPad: 8, gap: 8, columnGap: 18 }
  for (let i = 0; i < ROUNDS / 10; i++) {
    const p = L.parse(Array.from({ length: Math.floor(r() * 60) }, () => line(r)).join("\n"))
    const w = L.neededWidth(p.groups, o)
    assert.ok(Number.isFinite(w) && w >= 0)
  }
})
