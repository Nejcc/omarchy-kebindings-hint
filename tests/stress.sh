#!/usr/bin/env bash
# Hard live stress test for the keybindings bar. Switches between workspaces
# 7, 8 and 9 a few hundred times (so they should be empty), throws garbage
# payloads at the plugin, attacks its learning file while it runs, and
# flickers the bar open and closed. Your settings files are backed up first
# and restored at the end. Expect some on/off notifications.
#
#   tests/stress.sh
#   LOG=/path/to/log tests/stress.sh
set -uo pipefail

ID=nejcc.keybindings-hint
STATE=${XDG_STATE_HOME:-$HOME/.local/state}
LEARNED=$STATE/$ID.learned.json
DISABLED=$STATE/$ID.disabled
LOG=${LOG:-$(mktemp /tmp/keybindings-stress.XXXXXX.log)}
BACKUP=$(mktemp -d)
pass=0 fail=0

log()  { echo "$(date +%T)  $*" | tee -a "$LOG"; }
ok()   { log "PASS  $1"; pass=$((pass + 1)); }
bad()  { log "FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

for cmd in hyprctl omarchy-shell python3; do
  command -v "$cmd" >/dev/null || { echo "SKIP  needs $cmd"; exit 0; }
done
d() { hyprctl dispatch "$1" >/dev/null 2>&1; }
count_on() { hyprctl clients -j | python3 -c "import json,sys;print(sum(1 for c in json.load(sys.stdin) if c['workspace']['id']==$1))"; }
for ws in 7 8 9; do [ "$(count_on $ws)" = 0 ] || { echo "SKIP  workspace $ws isn't empty"; exit 0; }; done

shown() { hyprctl layers | grep -qE "namespace: ($ID|nejcc-keybindings-hint)"; }
summon() { local p='{}'; [ $# -gt 0 ] && p=$1; omarchy-shell shell summon "$ID" "$p" >/dev/null 2>&1; }
hide() { omarchy-shell shell hide "$ID" >/dev/null 2>&1; }
wait_shown() { for _ in $(seq 1 30); do shown && return 0; sleep 0.1; done; return 1; }
wait_hidden() { for _ in $(seq 1 30); do shown || return 0; sleep 0.1; done; return 1; }
shell_pid() { hyprctl layers | grep "namespace: omarchy-bar" | grep -oE "pid: [0-9]+" | head -1 | cut -d' ' -f2; }
shell_config() { ps -o args= -p "$(shell_pid)" | sed -nE 's/.* -p ([^ ]+).*/\1/p'; }
valid_json() { python3 -c "import json,sys;json.load(open('$LEARNED'))" 2>/dev/null; }
learned() { python3 -c "import json;d=json.load(open('$LEARNED'));print($1)" 2>/dev/null; }

start_ws=$(hyprctl activeworkspace -j | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
[ -e "$LEARNED" ] && cp -p "$LEARNED" "$BACKUP/learned.json"
[ -e "$DISABLED" ] && cp -p "$DISABLED" "$BACKUP/disabled"
cleanup() {
  restore_idle
  hide
  chmod u+rw "$LEARNED" 2>/dev/null
  rm -rf "$LEARNED" "$DISABLED"
  [ -e "$BACKUP/disabled" ] && cp -p "$BACKUP/disabled" "$DISABLED"
  if [ -e "$BACKUP/learned.json" ]; then cp -p "$BACKUP/learned.json" "$LEARNED"; fi
  [ -e "$BACKUP/disabled" ] || summon '{"enabled":"on"}'
  sleep 1
  # The file is watched, so the plugin picks the restored copy up by itself.
  [ -e "$BACKUP/learned.json" ] && cp -p "$BACKUP/learned.json" "$LEARNED"
  for pid in $(hyprctl clients -j | python3 -c "import json,sys;print(' '.join(str(c['pid']) for c in json.load(sys.stdin) if c['class']=='stress-log'))"); do kill "$pid"; done
  d "hl.dsp.focus({ workspace = \"$start_ws\" })"
  rm -rf "$BACKUP"
}
trap cleanup EXIT

# Keep the screen awake: Omarchy's screensaver starting in the middle of a
# burst of workspace switches makes Hyprland drop the shell's event stream,
# which has nothing to do with the plugin but would fail the test.
if omarchy toggle idle status 2>/dev/null | grep -q '"enabled":false'; then
  omarchy toggle idle stay-awake >/dev/null 2>&1
  restore_idle() { omarchy toggle idle allow-idle >/dev/null 2>&1; }
else
  restore_idle() { :; }
fi

pid_before=$(shell_pid)
SHELL_PATH=$(shell_config)
log_before=$(qs log -p "$SHELL_PATH" 2>/dev/null | wc -l)
rss_before=$(ps -o rss= -p "$pid_before" | tr -d ' ')
log "keybindings bar stress test; log at $LOG"
d "hl.dsp.exec_cmd(\"[float; pin; size 760 460; move 1140 60] foot --app-id=stress-log -T 'Stress test' tail -n 40 -f $LOG\")"
sleep 1
summon '{"enabled":"on"}'; sleep 0.5; hide

# --- garbage payloads
log "300 garbage payloads"
big=$(head -c 100000 /dev/zero | tr '\0' 'x')
payloads=('{' '[]' 'null' '"s"' '42' '{"enabled":1}' '{"enabled":null}' '{"learning":{}}' '{"learning":"RESET"}'
  '{"enabled":"on","learning":"bogus"}' '{"__proto__":{"polluted":1}}' '{"constructor":{}}' "{\"x\":\"$big\"}"
  '{"enabled":"maybe"}' '💥' '{"learning":["toggle"]}' ' ' '{}{}' '{"enabled":"on"')
for i in $(seq 1 300); do summon "${payloads[RANDOM % ${#payloads[@]}]}"; [ $((i % 7)) = 0 ] && hide; done
hide; wait_hidden
summon; check "after 300 garbage payloads the bar still opens" wait_shown
# Memory is measured from here: the first phase warms up the shell's caches.
rss_before=$(ps -o rss= -p "$pid_before" | tr -d ' ')
hide; wait_hidden
check "garbage never turned the hint off" '[ ! -e "$DISABLED" ]'

# --- flicker: holding and releasing SUPER very fast
log "300 open/close pairs, 20 ms apart"
for i in $(seq 1 300); do summon; sleep 0.02; hide; done
sleep 1; hide
check "nothing left on screen after the flicker" wait_hidden

# --- the learning file under attack while the plugin watches it
summon '{"learning":"on"}'; sleep 0.5
attack() { log "  learning file: $1"; }
attack "garbage";            printf 'not json at all' > "$LEARNED"; sleep 0.6
attack "cut-off JSON";       printf '{"learning": true, "transitions": {"Full screen": {"Full' > "$LEARNED"; sleep 0.6
attack "__proto__ keys";     printf '{"learning":true,"transitions":{"__proto__":{"polluted":9},"Full screen":{"__proto__":3,"Terminal":2}}}' > "$LEARNED"; sleep 0.6
attack "5 MB file";          python3 -c "
import json;t={('A%d'%a):{('B%d'%b):b+1 for b in range(400)} for a in range(400)}
json.dump({'learning':True,'transitions':t},open('$LEARNED','w'))"; sleep 2
attack "930 KB file (allowed, capped)"; python3 -c "
import json;t={('A%d'%a):{('B%d'%b):b+1 for b in range(300)} for a in range(300)}
json.dump({'learning':True,'transitions':t},open('$LEARNED','w'))"; sleep 2
attack "deep nesting";       python3 -c "open('$LEARNED','w').write('{\"learning\":true,\"transitions\":' + '['*5000 + ']'*5000 + '}')"; sleep 0.6
attack "deleted";            rm -f "$LEARNED"; sleep 0.6
attack "unreadable";         printf '{"learning":true,"transitions":{}}' > "$LEARNED"; chmod 000 "$LEARNED"; sleep 0.6; chmod 644 "$LEARNED"
attack "empty";              : > "$LEARNED"; sleep 0.6
summon; check "the bar opens after every attack" wait_shown
hide; wait_hidden
printf '{"version":1,"learning":true,"transitions":{}}' > "$LEARNED"; sleep 0.8

# --- event flood with learning on
# 8 switches a second: faster than anyone switches by hand. (Much faster
# floods make the whole Omarchy shell fall behind Hyprland's event stream,
# with or without this plugin.)
log "200 workspace switches between 7, 8 and 9 with learning on, 8 a second"
for i in $(seq 1 200); do d "hl.dsp.focus({ workspace = \"$(( 7 + i % 3 ))\" })"; sleep 0.12; done
# Learning saves 2 seconds after the last event; give a busy shell time.
for _ in $(seq 1 40); do
  [ "$(learned "d[\"transitions\"].get(\"Switch to workspace\",{}).get(\"Switch to workspace\",0) > 0")" = True ] && break
  sleep 0.5
done
check "the learning file is valid JSON after the flood" valid_json
check "the flood was learned" '[ "$(learned "d[\"transitions\"].get(\"Switch to workspace\",{}).get(\"Switch to workspace\",0) > 0")" = True ]'
summon; check "the bar opens after the flood" wait_shown
hide; wait_hidden

# --- settings flips
log "20 on/off flips and 20 learning flips"
for i in $(seq 1 20); do summon '{"enabled":"toggle"}'; summon '{"learning":"toggle"}'; done
sleep 1
check "an even number of on/off flips leaves it on" '[ ! -e "$DISABLED" ]'
check "an even number of learning flips leaves learning on" '[ "$(learned "d[\"learning\"]")" = True ]'

# --- auto-hide still works
summon; wait_shown; sleep 6.5
check "the 6-second auto-hide still works" wait_hidden

# --- verdict
check "the shell didn't restart or crash" '[ "$(shell_pid)" = "$pid_before" ]'
# Hyprland drops a client that reads its event stream too slowly; if that
# happened the whole shell stops seeing workspace changes until restarted.
check "Hyprland never dropped the shell's event stream" '! qs log -p "$SHELL_PATH" 2>/dev/null | tail -n +"$((log_before + 1))" | grep -q "event socket error"'
rss_after=$(ps -o rss= -p "$pid_before" | tr -d ' ')
log "shell memory: ${rss_before} KB -> ${rss_after} KB"
check "shell memory grew by less than 60 MB" '[ $(( rss_after - rss_before )) -lt 61440 ]'
check "no pollution reached other plugins (sanity: bar still renders)" 'summon; wait_shown; r=$?; hide; wait_hidden; [ $r = 0 ]'
# Quickshell itself warns when it can't watch the file we made unreadable on
# purpose; that one is expected.
new_warnings=$(qs log -p "$SHELL_PATH" 2>/dev/null | tail -n +"$((log_before + 1))" | grep -iE "warn|error" | grep -iE "KeybindingsHint|$ID|Logic.js" | grep -v "inotify_add_watch")
[ -n "$new_warnings" ] && log "$(echo "$new_warnings" | sort | uniq -c | head -5)"
check "no warnings or errors from the plugin in the shell log" '[ -z "$new_warnings" ]'

log "$pass passed, $fail failed"
[ "$fail" = 0 ]
