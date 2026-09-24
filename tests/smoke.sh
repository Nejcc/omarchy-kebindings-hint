#!/usr/bin/env bash
# Live smoke test against a running Omarchy shell with this plugin enabled.
# Shows and hides the bar, flips its settings and hammers it a little.
# Your settings files are backed up first and restored on exit, even on failure.
# Expect a few "on/off" notifications while it runs.
#
#   tests/smoke.sh
set -uo pipefail

ID=nejcc.keybindings-hint
STATE=${XDG_STATE_HOME:-$HOME/.local/state}
LEARNED=$STATE/$ID.learned.json
DISABLED=$STATE/$ID.disabled
BACKUP=$(mktemp -d)
pass=0 fail=0

ok()   { echo "PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

for cmd in hyprctl omarchy-shell python3; do
  command -v "$cmd" >/dev/null || { echo "SKIP  $cmd not found; needs a running Omarchy session"; exit 0; }
done
omarchy-shell shell summon "$ID" '{"learning":"_probe"}' >/dev/null 2>&1 || { echo "SKIP  omarchy-shell not responding"; exit 0; }

# Keep the user's settings; put them back no matter how the test ends.
[ -e "$LEARNED" ] && cp -p "$LEARNED" "$BACKUP/learned.json"
[ -e "$DISABLED" ] && cp -p "$DISABLED" "$BACKUP/disabled"
restore() {
  omarchy-shell shell hide "$ID" >/dev/null 2>&1
  rm -f "$DISABLED"
  [ -e "$BACKUP/disabled" ] && cp -p "$BACKUP/disabled" "$DISABLED"
  if [ -e "$BACKUP/learned.json" ]; then
    # Restore through the plugin too, so its in-memory state matches the file.
    learning=$(python3 -c "import json;print('on' if json.load(open('$BACKUP/learned.json')).get('learning') is True else 'off')" 2>/dev/null || echo off)
    omarchy-shell shell summon "$ID" "{\"learning\":\"$learning\"}" >/dev/null 2>&1
    sleep 1
    cp -p "$BACKUP/learned.json" "$LEARNED"
  fi
  [ -e "$BACKUP/disabled" ] || omarchy-shell shell summon "$ID" '{"enabled":"on"}' >/dev/null 2>&1
  rm -rf "$BACKUP"
}
trap restore EXIT

shown() { hyprctl layers | grep -qE "namespace: ($ID|nejcc-keybindings-hint)"; }
wait_shown() { for _ in $(seq 1 30); do shown && return 0; sleep 0.1; done; return 1; }
wait_hidden() { for _ in $(seq 1 30); do shown || return 0; sleep 0.1; done; return 1; }
summon() { local p='{}'; [ $# -gt 0 ] && p=$1; omarchy-shell shell summon "$ID" "$p" >/dev/null 2>&1; }
hide() { omarchy-shell shell hide "$ID" >/dev/null 2>&1; }
learned() { python3 -c "import json,sys;d=json.load(open('$LEARNED'));print($1)" 2>/dev/null; }
shell_pid() { hyprctl layers | grep "namespace: omarchy-bar" | grep -oE "pid: [0-9]+" | head -1 | cut -d' ' -f2; }
# The shell's config path, read from its own command line, is what `qs log` needs.
shell_config() { ps -o args= -p "$(shell_pid)" | sed -nE 's/.* -p ([^ ]+).*/\1/p'; }
log_lines() { qs log -p "$SHELL_PATH" 2>/dev/null | wc -l; }

# Right after a (re)start the shell reloads its plugins and drops requests for
# a few seconds. Wait until three open/close rounds in a row work.
summon '{"enabled":"on"}'; sleep 0.5
settled=0
for _ in $(seq 1 60); do
  summon; if wait_shown; then settled=$((settled + 1)); else settled=0; fi
  hide; wait_hidden
  [ "$settled" -ge 3 ] && break
  sleep 0.5
done
[ "$settled" -ge 3 ] || { echo "SKIP  the shell never settled; try again in a moment"; exit 0; }
summon '{"enabled":"on"}'; sleep 0.5; hide; wait_hidden
pid_before=$(shell_pid)
SHELL_PATH=$(shell_config)
[ -n "$pid_before" ] && [ -n "$SHELL_PATH" ] || { echo "SKIP  can't find the running Omarchy shell"; exit 0; }
log_before=$(log_lines)

# --- show and hide
summon; check "summon shows the bar" wait_shown
hide;   check "hide removes the bar" wait_hidden
omarchy-shell shell toggle "$ID" >/dev/null 2>&1; check "toggle shows the bar" wait_shown
omarchy-shell shell toggle "$ID" >/dev/null 2>&1; check "toggle again hides it" wait_hidden

# --- on/off switch
summon '{"enabled":"off"}'; sleep 0.5
check "turning off writes the marker file" '[ -e "$DISABLED" ]'
summon; sleep 1
check "while off, summon shows nothing" '! shown'
summon '{"enabled":"on"}'; sleep 0.5
check "turning on removes the marker file" '[ ! -e "$DISABLED" ]'
summon; check "while on, summon shows the bar" wait_shown
hide; wait_hidden
summon '{"enabled":"maybe"}'; sleep 0.5
check "an unknown on/off value changes nothing" '[ ! -e "$DISABLED" ]'
hide

# --- learning
summon '{"learning":"on"}'; sleep 0.5
check "learning on is saved" '[ "$(learned "d[\"learning\"]")" = True ]'
summon '{"learning":"off"}'; sleep 0.5
check "learning off is saved" '[ "$(learned "d[\"learning\"]")" = False ]'
summon '{"learning":"toggle"}'; sleep 0.5
check "learning toggle flips it" '[ "$(learned "d[\"learning\"]")" = True ]'
summon '{"learning":"reset"}'; sleep 0.5
check "reset empties what was learned" '[ "$(learned "d[\"transitions\"]")" = "{}" ]'
check "reset keeps learning on" '[ "$(learned "d[\"learning\"]")" = True ]'
# An outside change to the file (a restore, a hand edit) must survive the
# plugin's next save instead of being overwritten from memory.
python3 -c "import json;d=json.load(open('$LEARNED'));d['transitions']={'Terminal':{'Terminal':7}};json.dump(d,open('$LEARNED','w'))"
sleep 1
summon '{"learning":"on"}'; sleep 0.5
check "an outside change to the learning file is kept" '[ "$(learned "d[\"transitions\"].get(\"Terminal\",{}).get(\"Terminal\")")" = 7 ]'
summon '{"learning":"bogus"}'; sleep 0.5
check "an unknown learning value changes nothing" '[ "$(learned "d[\"learning\"]")" = True ]'
check "settings payloads never show the bar" '! shown'
summon '{"learning":"off"}'; sleep 0.5

# --- auto-hide safety net
summon; wait_shown
sleep 6.5
check "the bar hides itself after 6 seconds" wait_hidden

# --- hammer it
for _ in $(seq 1 50); do summon; hide; done
sleep 1
hide
check "50 quick show/hide cycles leave nothing on screen" wait_hidden
summon; check "still opens after the hammering" wait_shown
hide; wait_hidden
check "the shell didn't restart or crash" '[ "$(shell_pid)" = "$pid_before" ]'
new_warnings=$(qs log -p "$SHELL_PATH" 2>/dev/null | tail -n +"$((log_before + 1))" | grep -iE "warn|error" | grep -ciE "KeybindingsHint|$ID|Logic.js")
check "no new warnings or errors from the plugin in the shell log" '[ "$new_warnings" = 0 ]'

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
