#!/usr/bin/env bash
# End-to-end demo of attended routine-status absorption, driving the REAL
# bin/fm-watch.sh watcher process and the REAL bin/fm-wake-drain.sh the model reads.
set -u
REPO=${REPO:?set REPO}
. "$REPO/tests/wake-helpers.sh"
. "$REPO/bin/fm-classify-lib.sh"
WATCH="$ROOT/bin/fm-watch.sh"; DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-absorb-e2e)

run_watcher() { # <state> <fakebin> <out> [env...]
  local state=$1 fakebin=$2 out=$3; shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    env "$@" "$WATCH" > "$out" &
  local pid=$! i=0
  while [ $i -lt 60 ]; do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; i=$((i+1)); done
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 1
}

hr() { printf '\n=== %s ===\n' "$1"; }
export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

hr "SCENARIO A: routine 'working:' status from a provably-live worker (attended, absorb default on)"
dirA=$(make_case demo-absorb); stA="$dirA/state"
printf 'working: compiling step 2\n' > "$stA/task.status"
echo "worker wrote:      $(cat "$stA/task.status")"
echo "live-work proof:   $FM_FAKE_CREW_STATE"
if run_watcher "$stA" "$dirA/fakebin" "$dirA/watch.out"; then
  echo "watcher:           EXITED (would spend an LLM turn)"
else
  echo "watcher:           still blocking -> NO LLM turn spent"
fi
echo "watcher stdout:    '$(cat "$dirA/watch.out")'"
echo "durable wake queue: '$(cat "$stA/.wake-queue" 2>/dev/null)'"
echo "triage log:        $(grep -F 'absorbed benign signal' "$stA/.watch-triage.log")"
echo "delayed-presentation receipt on disk (survives a crash):"
echo "  $stA/.status-absorbed-task -> $(cat "$stA/.status-absorbed-task")"

echo "(the watcher process was then SIGKILLed - the drain below runs against a crashed watcher)"

hr "SCENARIO A cont.: the next GENUINE model turn (unrelated check wake) drains"
append_wake "$stA" check unrelated.check.sh 'check: unrelated genuine model turn' >/dev/null
FM_STATE_OVERRIDE="$stA" "$DRAIN" 2>/dev/null | sed 's/^/  | /'
echo "receipt after presentation: $([ -e "$stA/.status-absorbed-task" ] && echo present || echo removed)"

hr "SCENARIO A cont.: a second drain must NOT replay the same line"
FM_STATE_OVERRIDE="$stA" "$DRAIN" 2>/dev/null | sed 's/^/  | /'

hr "SCENARIO B: terminal 'done:' status, same live worker -> must still wake immediately"
dirB=$(make_case demo-terminal); stB="$dirB/state"
printf 'done: shipped clean\n' > "$stB/task.status"
if run_watcher "$stB" "$dirB/fakebin" "$dirB/watch.out"; then
  echo "watcher:           EXITED -> model turn taken (correct)"
else echo "watcher:           still blocking (WRONG)"; fi
echo "watcher stdout:    $(cat "$dirB/watch.out")"
echo "durable wake queue: $(cat "$stB/.wake-queue" 2>/dev/null)"

hr "SCENARIO C: unparseable status line, same live worker -> must still wake"
dirC=$(make_case demo-unparseable); stC="$dirC/state"
printf 'progress text without a status verb\n' > "$stC/task.status"
if run_watcher "$stC" "$dirC/fakebin" "$dirC/watch.out"; then
  echo "watcher:           EXITED -> model turn taken (correct)"
else echo "watcher:           still blocking (WRONG)"; fi
echo "watcher stdout:    $(cat "$dirC/watch.out")"

hr "SCENARIO D: home-local off switch (config/attended-routine-status-absorb = off)"
dirD=$(make_case demo-off); stD="$dirD/state"
mkdir -p "$dirD/config"; printf 'off\n' > "$dirD/config/attended-routine-status-absorb"
echo "home config:       $dirD/config/attended-routine-status-absorb = $(cat "$dirD/config/attended-routine-status-absorb")"
printf 'working: compiling step 2\n' > "$stD/task.status"
if run_watcher "$stD" "$dirD/fakebin" "$dirD/watch.out" FM_HOME="$dirD" FM_ROOT_OVERRIDE="$dirD"; then
  echo "watcher:           EXITED -> model turn taken (absorption disabled, correct)"
else echo "watcher:           still blocking (WRONG)"; fi
echo "watcher stdout:    $(cat "$dirD/watch.out")"

hr "SCENARIO E: absorbed worker then goes quiet -> stale detection still wedge-escalates"
echo "(covered by tests/fm-watch-triage.test.sh::test_nonterminal_stale_provably_working_absorbed_then_escalated,"
echo " which now enters via the attended signal-absorb path)"
