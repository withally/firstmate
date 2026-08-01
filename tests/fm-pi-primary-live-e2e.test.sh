#!/usr/bin/env bash
# Opt-in interactive Pi primary regression on a private tmux socket and isolated homes.
set -u

if [ "${FM_PI_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_LIVE_E2E=1 to run the isolated interactive Pi regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v pi >/dev/null 2>&1 || { echo "skip: pi not found"; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

TMUX=$(command -v tmux)
SOCKET="fm-pi-live-e2e-$$"
SESSION=pi-live-e2e
LAB="$ROOT/.pi-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
PI_DIR="$LAB/pi-agent"
PI_VERSION=$(pi --version)

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -600 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fq "$expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_exact_line() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fxq " $expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_file_value() {
  local file=$1 expected=$2 attempts=${3:-120} i=0 value
  while [ "$i" -lt "$attempts" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    [ "$value" = "$expected" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

export_contains() {
  local file=$1 expected=$2
  node - "$file" "$expected" <<'NODE'
const { readFileSync } = require("node:fs");
const [file, expected] = process.argv.slice(2);
const html = readFileSync(file, "utf8");
const encoded = html.match(/<script id="session-data" type="application\/json">([^<]+)<\/script>/)?.[1];
if (!encoded) process.exit(2);
const session = Buffer.from(encoded, "base64").toString("utf8");
process.exit(session.includes(expected) ? 0 : 1);
NODE
}

wait_for_watcher_pid() {
  local previous=${1:-} attempts=${2:-120} i=0 candidate file
  while [ "$i" -lt "$attempts" ]; do
    file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid 2>/dev/null | head -1 || true)
    candidate=$(sed -n '1p' "$file" 2>/dev/null || true)
    if [ -n "$candidate" ] && [ "$candidate" != "$previous" ] && kill -0 "$candidate" 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local pid_file watcher_pid arm_pid
  pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid 2>/dev/null | head -1 || true)
  watcher_pid=
  arm_pid=
  if [ -n "$pid_file" ]; then
    watcher_pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
    arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  fi
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

send_prompt() {
  local prompt=$1
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$prompt"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
cp "$ROOT/bin/fm-operational-input.sh" "$PROJECT/bin/fm-operational-input.sh"
cp "$ROOT/bin/fm-supervision-instructions.sh" "$PROJECT/bin/fm-supervision-instructions.sh"
chmod +x "$PROJECT/bin/fm-operational-input.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$PI_DIR"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env PI_CODING_AGENT_DIR='$PI_DIR' FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 PI_OFFLINE=1 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; pi; rc=\$?; printf \"PI_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

wait_for_text "Trust project folder?" 40 || fail "Pi trust prompt did not appear"
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "fm-primary-turnend-guard.ts" 60 || fail "Pi primary extensions did not load"
wait_for_text "fm-calm.ts" 60 || fail "Pi Calm extension did not load"

send_prompt "/calm"
wait_for_file_value "$HOME_DIR/config/calm" on || fail "/calm did not persist on in the effective home"
send_prompt "Use the bash tool to run sleep 2. Then reply exactly BOAT-RESIZED."
wait_for_text '\__/' 40 || fail "Calm working boat did not appear during a real Pi run"
"$TMUX" -L "$SOCKET" clear-history -t "$SESSION"
"$TMUX" -L "$SOCKET" resize-window -t "$SESSION" -x 74 -y 32
wait_for_text '\__/' 40 || fail "Calm working boat did not survive a live terminal resize"
wait_for_exact_line "BOAT-RESIZED" || fail "resized Calm boat run did not settle"
"$TMUX" -L "$SOCKET" resize-window -t "$SESSION" -x 160 -y 44

send_prompt "Use the bash tool to run printf PI_E2E_BASH_ONE. Then reply exactly BASH-ONE."
wait_for_exact_line "BASH-ONE" || fail "first bash turn did not complete"
send_prompt "Use the read tool to read the first five lines of README.md. Then reply exactly READ-ONE."
wait_for_exact_line "READ-ONE" || fail "read turn did not complete"
send_prompt "Use the bash tool to run printf PI_E2E_BASH_TWO. Then reply exactly BASH-TWO."
wait_for_exact_line "BASH-TWO" || fail "second bash turn did not complete"

: > "$HOME_DIR/state/pi-e2e.meta"
send_prompt "Reply exactly GUARD-TRIGGER with no tools. When the guard follow-up arrives, use fm_watch_arm_pi and never use bash to arm supervision. After any FIRSTMATE WATCHER WAKE, run bin/fm-wake-drain.sh, read the signaled status, call fm_watch_arm_pi to re-arm, and finish exactly REARMED."
watcher_pid=$(wait_for_watcher_pid "" 240) || fail "guard follow-up did not execute the hidden Pi watcher tool"

printf 'done: pi live e2e watcher fire\n' > "$HOME_DIR/state/pi-e2e.status"
wait_for_exact_line "REARMED" 120 || fail "Pi did not settle after re-arming watcher supervision"
rearmed_watcher_pid=$(wait_for_watcher_pid "$watcher_pid" 240) || fail "watcher wake did not drain and re-arm through the hidden Pi tool"

pane=$(capture)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
if [ "$guard_count" -ne 0 ]; then
  printf '%s\n' "$pane" >&2
  fail "Calm rendered a classified turn-end guard row"
fi
printf '%s\n' "$pane" | grep -Fq "watcher: started Pi extension arm child" \
  && fail "Calm rendered the fm_watch_arm_pi tool shell"
foreground_arm='$ bin/fm-watch-arm.sh'
if printf '%s\n' "$pane" | grep -Fq "$foreground_arm"; then
  fail "Pi used a foreground bash watcher arm"
fi

pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid | head -1)
[ -n "$pid_file" ] || fail "re-armed watcher pid was not recorded"
watcher_pid=$rearmed_watcher_pid
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "re-armed watcher parent was not live"

touch "$HOME_DIR/state/.afk"
away_inner=$(printf '%s' 'Supervisor escalate (1 event(s)): reply exactly AWAY-HANDLED with no tools.' | "$PROJECT/bin/fm-operational-input.sh" encode away-supervisor)
away_message=$(printf '\037%s' "$away_inner")
send_prompt "$away_message"
wait_for_exact_line "AWAY-HANDLED" || fail "Pi did not receive the semantic away escalation"
[ -e "$HOME_DIR/state/.afk" ] || fail "marked away escalation exited away mode"
pane=$(capture)
printf '%s\n' "$pane" | grep -Fq "Supervisor escalate (1 event(s))" \
  && fail "Calm rendered the exact away-supervisor user row"

export_file="$LAB/calm-export.html"
send_prompt "/export $export_file"
for _ in $(seq 1 120); do
  [ -s "$export_file" ] && break
  sleep 0.25
done
[ -s "$export_file" ] || fail "/export did not produce a Calm session artifact"
export_contains "$export_file" "TURN WOULD END BLIND" || fail "export lost the hidden turn-end operational message"
export_contains "$export_file" "Supervisor escalate" || fail "export lost the hidden away operational message"
send_prompt "/share"
wait_for_text "Share URL:" 120 || fail "/share did not complete in the live Calm session"
send_prompt "Reply exactly SHARE-SURVIVED with no tools."
wait_for_exact_line "SHARE-SURVIVED" || fail "/share disrupted the live Calm session"

send_prompt "/calm"
wait_for_file_value "$HOME_DIR/config/calm" off || fail "/calm did not restore the off preference"
send_prompt "Use the bash tool to run printf CALM_OFF_TOOL. Then reply exactly CALM-OFF."
wait_for_exact_line "CALM-OFF" || fail "Calm-off control run did not settle"
wait_for_text "CALM_OFF_TOOL" || fail "Calm off did not restore stock built-in tool rendering"
send_prompt "/calm"
wait_for_file_value "$HOME_DIR/config/calm" on || fail "second /calm did not restore the on preference"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "PI_EXIT=0" 60 || fail "Pi did not exit cleanly"
wait_pid_dead "$watcher_pid" || fail "watcher child survived clean Pi exit"
wait_pid_dead "$arm_pid" || fail "arm child survived clean Pi exit"

"$TMUX" -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env PI_CODING_AGENT_DIR='$PI_DIR' FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' PI_OFFLINE=1 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; pi; rc=\$?; printf \"PI_RESTART_EXIT=%s\\n\" \"\$rc\"; sleep 300'"
wait_for_text "fm-calm.ts" 60 || fail "Pi restart did not reload Calm"
wait_for_file_value "$HOME_DIR/config/calm" on || fail "Pi restart lost the persisted Calm preference"
send_prompt "/calm"
wait_for_file_value "$HOME_DIR/config/calm" off || fail "restarted Pi did not toggle persisted Calm off"
send_prompt "/quit"
wait_for_text "PI_RESTART_EXIT=0" 60 || fail "restarted Pi did not exit cleanly"

printf 'ok - Pi %s live E2E toggled and persisted Calm, animated and resized the boat, hid watcher/guard/away rows, preserved wake and away semantics, exported, survived share, restored stock rendering, restarted, and cleaned up\n' "$PI_VERSION"
