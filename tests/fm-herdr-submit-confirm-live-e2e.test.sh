#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# real Pi renders a busy-queued message as a `Steering:` transcript echo while
# its ordinary composer classifier remains unknown during working state.
# A stub cannot prove either signal.
# This guard launches real Claude Code and real Pi in an isolated Herdr lab.
# It requires confirmed idle Claude delivery plus short/long, idle/busy Pi
# delivery, including the full tail of each long message.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_HERDR_SUBMIT_CONFIRM_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_SUBMIT_CONFIRM_LIVE=1 to run the live Herdr submit-confirmation guard"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but herdr is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but jq is not installed"
command -v claude >/dev/null 2>&1 || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but Claude Code is not installed"
command -v pi >/dev/null 2>&1 || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but Pi is not installed"
[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
CAPTURE_ROOT=/Users/ivan/Projects/firstmate/data/fm-send-verify-fn-k8/captures
CAPTURE_SEQ=0
mkdir -p "$FAKEBIN"
mkdir -p "$CAPTURE_ROOT" || fail "could not create the required live capture directory $CAPTURE_ROOT"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
if [ "\${args[0]:-}" = pane ] && [ "\${args[1]:-}" = read ]; then
  capture="$CAPTURE_ROOT/\$(date +%Y%m%dT%H%M%S)-adapter-pane-read-\$\$-\$RANDOM.txt"
  rc=0
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}" >"\$capture" 2>/dev/null || rc=\$?
  cat "\$capture"
  exit "\$rc"
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
read_live_pane() {  # <pane> <label> -> exact pane output, preserved on disk
  local pane=$1 label=$2 capture rc=0
  CAPTURE_SEQ=$((CAPTURE_SEQ + 1))
  capture="$CAPTURE_ROOT/$(date +%Y%m%dT%H%M%S)-${CAPTURE_SEQ}-${label}.txt"
  lab pane read "$pane" --source recent --lines 400 >"$capture" 2>/dev/null || rc=$?
  cat "$capture"
  return "$rc"
}
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done|blocked) idle=1; break ;; esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never registered an idle agent in the lab pane"

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4 "" claude) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(read_live_pane "$PANE" claude || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

# Pi/Grok-on-Herdr uses Pi's queue surface regardless of provider model.
# Exercise the pinned OpenAI model from an idle composer and while a turn is
# already working, with both short and 1500+ character multiline messages.
PI_WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive-pi --no-focus) \
  || fail "could not create the isolated Pi submit-confirm workspace"
PI_PANE=$(printf '%s' "$PI_WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "Pi workspace create did not return a pane id"
PI_TARGET="$SESSION:$PI_PANE"
PI_VERSION=$(PATH="$ORIGINAL_PATH" pi --version 2>/dev/null | head -1 || printf 'pi-version-unknown')
PI_MODEL='openai-codex/gpt-5.6-sol'

lab pane run "$PI_PANE" "pi --model $PI_MODEL --thinking low --approve --no-context-files --no-skills --no-prompt-templates --no-extensions --no-session --tools bash" >/dev/null \
  || fail "could not launch Pi ($PI_VERSION, $PI_MODEL) in the isolated Herdr pane"

wait_pi_idle() {
  local i=0 status stable=0
  while [ "$i" -lt 240 ]; do
    status=$(lab agent get "$PI_PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$status" in
      idle|done)
        stable=$((stable + 1))
        [ "$stable" -ge 4 ] && return 0
        ;;
      *) stable=0 ;;
    esac
    i=$((i + 1))
    sleep 0.25
  done
  return 1
}

wait_pi_busy() {
  local i=0 status
  while [ "$i" -lt 120 ]; do
    status=$(lab agent get "$PI_PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    [ "$status" = working ] && return 0
    i=$((i + 1))
    sleep 0.25
  done
  return 1
}

wait_pi_text() {  # <needle>
  local needle=$1 i=0 screen
  while [ "$i" -lt 240 ]; do
    screen=$(read_live_pane "$PI_PANE" pi || true)
    printf '%s\n' "$screen" | grep -Fq "$needle" && return 0
    i=$((i + 1))
    sleep 0.25
  done
  return 1
}

wait_pi_idle || fail "Pi ($PI_VERSION, $PI_MODEL) never registered a stable idle composer"
PI_SHORT_IDLE="FM_PI_SHORT_IDLE_$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$PI_TARGET" "Reply with exactly $PI_SHORT_IDLE." 3 0.4 0.3 "" pi)
[ "$verdict" = empty ] \
  || fail "Pi ($PI_VERSION, $PI_MODEL) short idle submit must confirm empty, got '$verdict'"
wait_pi_text "$PI_SHORT_IDLE" || fail "Pi short idle prompt/reply never rendered"
wait_pi_idle || fail "Pi did not return idle after the short idle submit"

PI_BUSY_TRIGGER_1="FM_PI_BUSY_TRIGGER_1_$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$PI_TARGET" "Use the bash tool to run sleep 8, then reply exactly $PI_BUSY_TRIGGER_1." 3 0.4 0.3 "" pi)
[ "$verdict" = empty ] || fail "Pi busy trigger submit did not confirm, got '$verdict'"
wait_pi_busy || fail "Pi never became busy for the short queued-submit case"
PI_SHORT_BUSY="FM_PI_SHORT_BUSY_$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$PI_TARGET" "Reply with exactly $PI_SHORT_BUSY." 3 0.4 0.3 "" pi)
[ "$verdict" = empty ] \
  || fail "Pi ($PI_VERSION, $PI_MODEL) short busy queue submit must confirm empty, got '$verdict'"
wait_pi_text "$PI_SHORT_BUSY" || fail "Pi short busy queue echo/prompt never rendered"
wait_pi_idle || fail "Pi did not return idle after the short busy submit"

PI_LONG_IDLE_HEAD="FM_PI_LONG_IDLE_HEAD_$$_$RANDOM"
PI_LONG_IDLE_TAIL="FM_PI_LONG_IDLE_TAIL_$$_$RANDOM"
PI_LONG_IDLE=$(awk -v head="$PI_LONG_IDLE_HEAD" -v tail="$PI_LONG_IDLE_TAIL" 'BEGIN {
  print head
  for (i=1; i<=40; i++) printf "LONG_IDLE_LINE_%02d abcdefghijklmnopqrstuvwxyz 0123456789\n", i
  print tail
  print "Reply with exactly LONG_IDLE_ACK."
}')
[ "${#PI_LONG_IDLE}" -ge 1500 ] || fail "Pi long-idle live fixture is shorter than 1500 characters"
verdict=$(fm_backend_herdr_send_text_submit "$PI_TARGET" "$PI_LONG_IDLE" 3 0.4 0.3 "" pi)
[ "$verdict" = empty ] \
  || fail "Pi ($PI_VERSION, $PI_MODEL) long idle submit must confirm empty, got '$verdict'"
wait_pi_text "$PI_LONG_IDLE_TAIL" || fail "Pi long idle submission did not render its tail token"
wait_pi_idle || fail "Pi did not return idle after the long idle submit"

PI_BUSY_TRIGGER_2="FM_PI_BUSY_TRIGGER_2_$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$PI_TARGET" "Use the bash tool to run sleep 8, then reply exactly $PI_BUSY_TRIGGER_2." 3 0.4 0.3 "" pi)
[ "$verdict" = empty ] || fail "Pi second busy trigger submit did not confirm, got '$verdict'"
wait_pi_busy || fail "Pi never became busy for the long queued-submit case"
PI_LONG_BUSY_HEAD="FM_PI_LONG_BUSY_HEAD_$$_$RANDOM"
PI_LONG_BUSY_TAIL="FM_PI_LONG_BUSY_TAIL_$$_$RANDOM"
PI_LONG_BUSY=$(awk -v head="$PI_LONG_BUSY_HEAD" -v tail="$PI_LONG_BUSY_TAIL" 'BEGIN {
  print head
  for (i=1; i<=40; i++) printf "LONG_BUSY_LINE_%02d abcdefghijklmnopqrstuvwxyz 0123456789\n", i
  print tail
  print "Reply with exactly LONG_BUSY_ACK."
}')
[ "${#PI_LONG_BUSY}" -ge 1500 ] || fail "Pi long-busy live fixture is shorter than 1500 characters"
verdict=$(fm_backend_herdr_send_text_submit "$PI_TARGET" "$PI_LONG_BUSY" 3 0.4 0.3 "" pi)
[ "$verdict" = empty ] \
  || fail "Pi ($PI_VERSION, $PI_MODEL) long busy queue submit must confirm empty, got '$verdict'"
wait_pi_text "$PI_LONG_BUSY_TAIL" || fail "Pi long busy queued submission did not render its tail token"
pass "live Herdr submit confirm: Pi ($PI_VERSION, $PI_MODEL) confirms short/long idle/busy sends in isolated session $SESSION"
CHECKED=$((CHECKED + 1))

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
