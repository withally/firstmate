#!/usr/bin/env bash
# Opt-in credentialed Grok regression proving an auto-backgrounded wake drain
# is consumed inside its initiating turn without a synthetic completion prompt.
set -u

if [ "${FM_GROK_DRAIN_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_GROK_DRAIN_LIVE_E2E=1 to run the interactive Grok drain-consumption regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GROK_BIN=${FM_GROK_DRAIN_BIN:-$(command -v grok || true)}
AUTH=${FM_GROK_AUTH_FILE:-$HOME/.grok/auth.json}
REAL_TMUX=$(command -v tmux || true)
LAB=

[ -x "$GROK_BIN" ] || fail "FM_GROK_DRAIN_BIN must be an exact executable path"
[ -f "$AUTH" ] || fail "FM_GROK_AUTH_FILE must name the already-managed auth artifact"
[ -n "$REAL_TMUX" ] || fail "tmux not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

cleanup() {
  local rc=$?
  if [ -n "$LAB" ] && [ -d "$LAB" ]; then
    env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$LAB/tmux.sock" kill-server 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
      rm -rf -- "$LAB"
    else
      printf 'blocked: preserving failed isolated Grok drain cell at %s\n' "$LAB" >&2
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-grok-drain.XXXXXX") || fail "could not create isolated lab"
PROJECT="$LAB/project"
FM_HOME_DIR="$LAB/fmhome"
GROK_HOME_DIR="$LAB/grok-home"
SESSION=grok-drain-e2e
MARKER="FM_GROK_DRAIN_CONSUMED_$$"
GROK_VERSION=$($GROK_BIN --version)

mkdir -p "$LAB/home" "$FM_HOME_DIR/state" "$FM_HOME_DIR/config" "$GROK_HOME_DIR"
git clone -q --no-hardlinks "$ROOT" "$PROJECT" || fail "could not clone candidate"
git -C "$ROOT" diff --binary HEAD -- > "$LAB/candidate.patch" || fail "could not capture candidate diff"
[ ! -s "$LAB/candidate.patch" ] \
  || git -C "$PROJECT" apply --whitespace=nowarn "$LAB/candidate.patch" \
  || fail "could not apply candidate diff"
ln -s "$AUTH" "$GROK_HOME_DIR/auth.json"

FM_HOME="$FM_HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" FM_STATE_OVERRIDE="$FM_HOME_DIR/state" \
  bash -c '. "$1"; fm_wake_append check grok-drain "check: grok drain output preserved"' _ \
  "$PROJECT/bin/fm-wake-lib.sh" || fail "could not seed isolated wake"

cat > "$LAB/run.sh" <<EOF
#!/usr/bin/env bash
set -u
cd '$PROJECT' || exit 70
exec env -u TMUX -u TMUX_PANE HOME='$LAB/home' GROK_HOME='$GROK_HOME_DIR' GROK_AGENT=1 \
  FM_HOME='$FM_HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' \
  '$GROK_BIN' --trust --always-approve --reasoning-effort low
EOF
chmod +x "$LAB/run.sh"

env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$LAB/tmux.sock" new-session -d -s "$SESSION" "$LAB/run.sh" \
  || fail "could not launch isolated Grok session"

capture() {
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$LAB/tmux.sock" capture-pane -p -t "$SESSION" -S -900 2>/dev/null || true
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

wait_for_text "Grok Build" 180 || fail "Grok did not reach its ready composer"
sleep 1
PROMPT="This is an isolated regression $MARKER. Run exactly \`FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT=15 bin/fm-wake-drain.sh\` with run_terminal_command and the default background setting. If it is automatically moved to background, immediately call get_command_or_subagent_output for that exact task with timeout_ms=30000 and wait for completion in this same turn. After you receive exit 0, reply exactly DRAIN_WAIT_CONSUMED. Do not end the turn before consuming the result and do not run any other tool."
env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$LAB/tmux.sock" send-keys -t "$SESSION" -l "$PROMPT"
env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$LAB/tmux.sock" send-keys -t "$SESSION" Enter

CHAT=
i=0
while [ "$i" -lt 300 ]; do
  CHAT=$(find "$GROK_HOME_DIR/sessions" -type f -name chat_history.jsonl -exec grep -l "$MARKER" {} + 2>/dev/null | head -1 || true)
  if [ -n "$CHAT" ] && jq -se 'any(.[]; .type == "assistant" and .content == "DRAIN_WAIT_CONSUMED")' "$CHAT" >/dev/null; then
    break
  fi
  sleep 0.5
  i=$((i + 1))
done
[ -n "$CHAT" ] || fail "could not locate the isolated Grok chat history"
jq -se 'any(.[]; .type == "assistant" and .content == "DRAIN_WAIT_CONSUMED")' "$CHAT" >/dev/null \
  || fail "Grok did not consume the drain in its initiating turn"
sleep 3

jq -se 'any(.[]; .type == "tool_result" and (.content | contains("automatically moved to background")))' "$CHAT" >/dev/null \
  || fail "Grok did not auto-background the delayed drain"
jq -se 'any(.[]; .type == "assistant" and any(.tool_calls[]?; .name == "get_command_or_subagent_output" and ((.arguments | fromjson).timeout_ms == 30000)))' "$CHAT" >/dev/null \
  || fail "Grok did not use the exact bounded output waiter"
jq -se 'any(.[]; .type == "tool_result" and (.content | contains("Status: completed")) and (.content | contains("Exit Code: 0")) and (.content | contains("check: grok drain output preserved")) and (.content | contains("WAKE_ACK_REQUIRED:")))' "$CHAT" >/dev/null \
  || fail "the consumed drain result lost completion, wake output, or acknowledgement instruction"
[ "$(jq -s '[.[] | select(.type == "user" and .synthetic_reason == "task_completed")] | length' "$CHAT")" -eq 0 ] \
  || fail "consumed drain still stored a synthetic task_completed user prompt"
[ "$(jq -s '[.[] | select(.type == "assistant" and .content == "DRAIN_WAIT_CONSUMED")] | length' "$CHAT")" -eq 1 ] \
  || fail "Grok did not finish the initiating turn exactly once after consuming the drain"

printf 'ok - %s consumed the auto-backgrounded drain in-turn with output and acknowledgement intact and zero task_completed prompts\n' "$GROK_VERSION"
