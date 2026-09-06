#!/usr/bin/env bash
# Live Pi watcher wake-turn guard (live-harness-optin family).
#
# A portable extension test pins the agent_settled race itself.
# This credentialed guard proves that a status wake crosses a real named Herdr
# session and starts a real Pi turn without any parent doorbell.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_PI_HERDR_WAKE_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_PI_HERDR_WAKE_LIVE=1 to run the live Pi-on-Herdr watcher wake-turn guard"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || fail "FM_PI_HERDR_WAKE_LIVE=1 but herdr is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_PI_HERDR_WAKE_LIVE=1 but jq is not installed"
command -v pi >/dev/null 2>&1 || fail "FM_PI_HERDR_WAKE_LIVE=1 but Pi is not installed"
[ -x "$LAB_HELPER" ] || fail "FM_PI_HERDR_WAKE_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION=$("$LAB_HELPER" name pi-herdr-wake-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-pi-herdr-wake-live.XXXXXX")
HOME_DIR="$TMP_ROOT/home"
TOKEN="FM_PI_HERDR_WAKE_$$_$RANDOM"
ORIGINAL_PATH=$PATH
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"

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

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-pi-wake-live --no-focus) \
  || fail "could not create the isolated Pi watcher workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
PI_VERSION=$(PATH="$ORIGINAL_PATH" pi --version 2>/dev/null | head -1 || printf 'pi-version-unknown')
HERDR_VERSION=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-version-unknown')
PI_MODEL=openai-codex/gpt-5.6-sol

COMMAND="env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$ROOT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 FM_PI_ARM_READY_TIMEOUT_MS=12000 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; exec pi --approve --no-session --no-context-files --no-skills --no-prompt-templates --model $PI_MODEL --thinking medium -e \"$ROOT/.pi/extensions/fm-primary-pi-watch.ts\"'"
lab pane run "$PANE" "$COMMAND" >/dev/null \
  || fail "could not launch Pi ($PI_VERSION, $PI_MODEL) in the isolated Herdr pane"

ready=0
i=0
while [ "$i" -lt 120 ]; do
  if [ -s "$HOME_DIR/state/.pi-watch-extension-loaded" ] && [ -e "$HOME_DIR/state/.last-watcher-beat" ]; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 0.25
done
[ "$ready" = 1 ] || fail "Pi watcher extension never established its live arm in $TARGET"

cat > "$HOME_DIR/state/live-wake-$TOKEN.meta" <<EOF
project=firstmate
worktree=$ROOT
window=$TARGET
EOF
printf 'done: %s\n' "$TOKEN" > "$HOME_DIR/state/live-wake-$TOKEN.status"

queued=0
acknowledged=0
i=0
while [ "$i" -lt 480 ]; do
  if grep -Fq "$TOKEN" "$HOME_DIR/state/.wake-queue" 2>/dev/null; then
    queued=1
  elif [ "$queued" = 1 ]; then
    acknowledged=1
    break
  fi
  i=$((i + 1))
  sleep 0.25
done
[ "$queued" = 1 ] || {
  lab pane read "$PANE" --source recent --lines 300 >&2 2>/dev/null || true
  fail "Pi watcher never published the live wake row"
}
[ "$acknowledged" = 1 ] || {
  lab pane read "$PANE" --source recent --lines 300 >&2 2>/dev/null || true
  fail "Pi watcher wake row remained unacknowledged without a parent doorbell"
}

pass "live Pi watcher wake: Pi $PI_VERSION on $HERDR_VERSION drained and acknowledged $TOKEN without a parent doorbell in isolated session $SESSION"
