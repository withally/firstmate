#!/usr/bin/env bash
# Opt-in credentialed Grok regression proving the persistent monitor-owned
# coordinator establishes a verified successor before an actionable wake turn.
set -u

if [ "${FM_GROK_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_GROK_LIVE_E2E=1 to run the interactive Grok continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v grok >/dev/null 2>&1 || fail "grok not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

TMUX=$(command -v tmux)
SOCKET="fm-grok-live-e2e-$$"
SESSION=grok-live-e2e
LAB="$ROOT/.grok-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
GROK_VERSION=$(grok --version)

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -1200 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

chat_history() {
  find "$HOME/.grok/sessions" -type f \
    -path "*${LAB##*/}%2Fproject/*/chat_history.jsonl" -print 2>/dev/null \
    | head -1
}

primary_turn_count() {
  local chat=$1
  grep -c '"type":"assistant".*"model_id":' "$chat" 2>/dev/null || true
}

monitor_event_count() {
  local chat=$1 needle=$2
  jq -r --arg needle "$needle" '
    select(.type == "user" and .synthetic_reason == "notification_drain")
    | .content[]?
    | select(.type == "text" and (.text | contains("FIRSTMATE_GROK_WAKE")) and (.text | contains($needle)))
    | 1
  ' "$chat" 2>/dev/null | wc -l | tr -d ' '
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
  local coordinator_pid arm_pid watcher_pid pid
  coordinator_pid=$(sed -n 's/^pid=//p' "$HOME_DIR/state/.grok-watch-coordinator" 2>/dev/null || true)
  arm_pid=$(sed -n 's/^pid=//p' "$HOME_DIR/state/.watch-arm-owner" 2>/dev/null || true)
  watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.2
  for pid in "$watcher_pid" "$arm_pid" "$coordinator_pid"; do
    if [ -n "$pid" ] && lab_pid_is_safe "$pid"; then
      kill -TERM "$pid" 2>/dev/null || true
      kill -CONT "$pid" 2>/dev/null || true
    fi
  done
  sleep 0.2
  for pid in "$watcher_pid" "$arm_pid" "$coordinator_pid"; do
    if [ -n "$pid" ] && lab_pid_is_safe "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm.sh"
cp "$ROOT/bin/fm-watch.sh" "$PROJECT/bin/fm-watch.sh"
cp "$ROOT/bin/fm-grok-watch-coordinator.mjs" "$PROJECT/bin/fm-grok-watch-coordinator.mjs"
cp "$ROOT/bin/fm-subagent-pretool-check.sh" "$PROJECT/bin/fm-subagent-pretool-check.sh"
cp "$ROOT/bin/fm-supervision-instructions.sh" "$PROJECT/bin/fm-supervision-instructions.sh"
cp "$ROOT/docs/supervision-protocols/grok.md" "$PROJECT/docs/supervision-protocols/grok.md"
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch.sh" \
  "$PROJECT/bin/fm-grok-watch-coordinator.mjs" "$PROJECT/bin/fm-subagent-pretool-check.sh" \
  "$PROJECT/bin/fm-supervision-instructions.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'project=fixture\n' > "$HOME_DIR/state/grok-e2e.meta"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 FM_CHECK_INTERVAL=999999 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; exec grok --trust --always-approve --reasoning-effort low'"

wait_for_text "Grok Build" 180 || fail "Grok did not reach its ready composer"
sleep 1
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
PROMPT='Use the `monitor` tool exactly once with command `exec bin/fm-grok-watch-coordinator.mjs`, description `Firstmate watcher coordinator`, and persistent=true. Never use a shell ampersand or start a second monitor. When a FIRSTMATE_GROK_WATCH_READY notification arrives, respond exactly ARM_READY. When a FIRSTMATE_GROK_WAKE notification arrives, run its exact `bin/fm-watch-arm.sh --handling-delivered <recovery_generation> --watcher-pid <successor_watcher_pid>` confirmation as its own tool call, then run `bin/fm-wake-drain.sh` as a separate tool call, handle the one wake, run the exact WAKE_ACK_REQUIRED acknowledgement as its own tool call, and respond exactly WAKE_HANDLED. Do not re-arm and do not echo the event JSON.'
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$PROMPT"
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter

i=0
chat=
while [ "$i" -lt 120 ]; do
  chat=$(chat_history)
  [ -n "$chat" ] && [ -f "$chat" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -n "$chat" ] && [ -f "$chat" ] || fail "Grok chat history was not created for the live cell"
i=0
while [ "$i" -lt 240 ]; do
  grep -F '"type":"assistant","content":"ARM_READY"' "$chat" >/dev/null 2>&1 && break
  sleep 0.5
  i=$((i + 1))
done
grep -F '"type":"assistant","content":"ARM_READY"' "$chat" >/dev/null 2>&1 \
  || fail "Grok did not consume the coordinator readiness event"
i=0
initial_watcher=
while [ "$i" -lt 120 ]; do
  initial_watcher=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$initial_watcher" ] && kill -0 "$initial_watcher" 2>/dev/null \
    && [ -s "$HOME_DIR/state/.grok-watch-coordinator" ]; then
    break
  fi
  sleep 0.5
  i=$((i + 1))
done
if [ -z "$initial_watcher" ] || ! kill -0 "$initial_watcher" 2>/dev/null; then
  fail "Grok did not start the monitor-owned coordinator watcher"
fi
baseline_turns=$(primary_turn_count "$chat")
event_needle="signal: $HOME_DIR/state/grok-e2e.status"
baseline_events=$(monitor_event_count "$chat" "$event_needle")

# Quiet recovery must remain inside the live successor wait and produce no
# monitor notification or primary turn.
FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c \
  '. "$1"; fm_recovery_transition "$2" publish downtime' _ \
  "$PROJECT/bin/fm-wake-lib.sh" "$HOME_DIR/state/.watcher-down" \
  || fail "could not publish the isolated quiet recovery episode"
sleep 4
quiet_turns=$(primary_turn_count "$chat")
quiet_events=$(monitor_event_count "$chat" "$event_needle")
[ "$quiet_turns" -eq "$baseline_turns" ] \
  || fail "quiet recovery spent a primary turn ($baseline_turns -> $quiet_turns)"
[ "$quiet_events" -eq "$baseline_events" ] \
  || fail "quiet recovery emitted an actionable monitor event"
quiet_watcher=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
if [ "$quiet_watcher" != "$initial_watcher" ] || ! kill -0 "$quiet_watcher" 2>/dev/null; then
  fail "quiet recovery did not retain the initial live watcher"
fi

printf 'done: grok live successor-first fire\n' > "$HOME_DIR/state/grok-e2e.status"
wait_for_text "WAKE_HANDLED" 300 || fail "Grok did not consume and acknowledge the actionable monitor event"

successor_watcher=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
[ -n "$successor_watcher" ] && [ "$successor_watcher" != "$initial_watcher" ] \
  || fail "the actionable Grok turn had no distinct successor watcher"
kill -0 "$successor_watcher" 2>/dev/null || fail "the actionable Grok turn left no live successor watcher"
! kill -0 "$initial_watcher" 2>/dev/null || fail "the predecessor watcher overlapped the successor"
[ "$(monitor_event_count "$chat" "$event_needle")" -eq $((baseline_events + 1)) ] \
  || fail "one actionable signal did not produce exactly one Grok monitor event"
[ "$(grep -c 'reason=actionable-signal' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null || true)" -eq 1 ] \
  || fail "one actionable signal did not produce exactly one arm completion"
grep -F "successor=started:$successor_watcher" "$HOME_DIR/state/.watch-cycle-exits.log" >/dev/null \
  || fail "the completed predecessor was not linked to the live successor before delivery"
[ "$(sed -n 's/^pid=//p' "$HOME_DIR/state/.watch-arm-owner" | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "the live Grok path did not retain exactly one arm owner"
[ ! -s "$HOME_DIR/state/.wake-queue" ] \
  || fail "Grok did not acknowledge the one durable signal row"

guard_status=0
guard_out=$(printf '%s' '{"sessionId":"grok-live-successor-first","stopHookActive":false}' \
  | GROK_AGENT=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_ROOT_OVERRIDE="$PROJECT" bash "$PROJECT/bin/fm-turnend-guard.sh" 2>&1) || guard_status=$?
[ "$guard_status" -eq 0 ] || fail "successor-first Grok path still forced TURN WOULD END BLIND: $guard_out"
! printf '%s\n' "$guard_out" | grep -qF 'TURN WOULD END BLIND' \
  || fail "successor-first Grok path emitted a blind-turn continuation"
! capture | grep -qF 'bin/fm-watch-arm.sh &' \
  || fail "Grok used a shell ampersand instead of its persistent monitor"

printf 'ok - %s live E2E delivered one actionable monitor event only after one live successor, with no blind-turn continuation\n' "$GROK_VERSION"
