#!/usr/bin/env bash
# tests/fm-watch-arm.test.sh - the arm layer's cycle-close contract when the arm
# did not own the cycle.
#
# The watcher prints its one reason line to its OWN stdout, so only the arm that
# forked it ever reads that line. An arm that ATTACHED to an existing cycle holds
# no handle on it and can observe only a released lock, which is why a completely
# successful cycle used to be reported as
# "watcher: FAILED - cycle ended without an actionable reason" on every harness
# whose protocol reads that line. These are real-process tests: a real
# bin/fm-watch.sh holds the singleton, a real bin/fm-watch-arm.sh attaches to it,
# and a real status change drives a real wake through the watcher-bound delivery
# record and durable queue.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-arm-tests)

# Both starters background a real process the test later waits on, so they set a
# global instead of echoing: a command substitution would make the pid a child of
# a subshell this shell can no longer wait for.
SEED_PID=
ARM_PID=

# Start the real watcher as the singleton holder.
start_seed_watcher() {  # <state> <fakebin> <watch-out>
  local state=$1 fakebin=$2 out=$3 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "seed watcher did not take the lock"
}

# Attach a real arm to the live cycle.
start_attached_arm() {  # <state> <fakebin> <arm-out> <confirm-timeout>
  local state=$1 fakebin=$2 armout=$3 confirm=$4 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT="$confirm" "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$SEED_PID" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$SEED_PID" "$armout" \
    || fail "arm did not attach to the live watcher: $(cat "$armout")"
}

ack_wakes() {  # <state>
  local state=$1 sequence generation err
  err="$state/.test-ack.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  if [ -z "$sequence" ] || [ -z "$generation" ]; then
    [ ! -s "$state/.wake-queue" ] || return 1
    case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in pending:*) return 1 ;; esac
    return 0
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# Print "<sequence>\t<generation>" from the acknowledgement command a drain
# printed, so a case can replay that exact pair later.
drain_ack_pair() {  # <drain-stderr>
  local err=$1 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  printf '%s\t%s\n' "$sequence" "$generation"
}

start_rearm_arm() {  # <home> <state> <fakebin> <arm-out> [predecessor-arm-pid]
  local home=$1 state=$2 fakebin=$3 armout=$4 predecessor=${5:-} i
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_PREDECESSOR_ARM_PID="$predecessor" \
    "$WATCH_ARM" --restart > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -q '^watcher: started ' "$armout" 2>/dev/null && return 0
    is_live_non_zombie "$ARM_PID" || return 0
    sleep 0.05
    i=$((i + 1))
  done
}

test_attached_arm_reports_the_delivered_wake() {
  local dir state fakebin out armout status
  dir=$(make_case attached-delivered-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A real captain-relevant status change: the watcher records it in the durable
  # queue, prints its one reason line to its own stdout, and exits.
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  grep -q '^signal:' "$out" || fail "seed watcher did not surface the signal wake: $(cat "$out")"

  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -q 'demo.status' "$state/.wake-queue" \
    || fail "the wake was not durably recorded, so this case proves nothing"
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported a delivered wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the durably recorded wake reason: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose cycle delivered a wake must close successfully"
  grep -q 'reason=attached-delivered-wake' "$state/.watch-cycle-exits.log" \
    || fail "the delivered-wake close was not classified in the lifecycle ledger"
  pass "watch-arm: an attached arm reports the wake its cycle delivered instead of a false failure"
}

test_attached_arm_reports_the_delivered_wake_after_drain() {
  local dir state fakebin out armout status
  dir=$(make_case attached-drained-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  # A wider confirmation budget keeps the arm in its successor wait while the
  # handling turn presents and acknowledges, which is the ordering this case covers.
  start_attached_arm "$state" "$fakebin" "$armout" 5

  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  # The handling turn acknowledges the records before the attached arm closes: the
  # queue is empty again, while the watcher's identity-bound terminal record
  # still proves which cycle delivered the reason.
  ack_wakes "$state" || fail "post-handling acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledgement left records behind"

  wait_for_exit "$ARM_PID" 200
  status=$?
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported an already-handled wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the delivered reason after the queue drain: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose wake was already drained must close successfully"
  pass "watch-arm: a delivered wake consumed by the handling turn still closes the attached arm cleanly"
}

test_attached_arm_still_fails_on_a_wake_it_did_not_deliver() {
  local dir state fakebin out armout status
  dir=$(make_case attached-no-delivery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A process-event producer advances the same home-wide queue while the
  # observed watcher remains uninvolved, so only watcher-bound evidence can
  # distinguish this from a delivered watcher cycle.
  append_wake "$state" check process-event "check: process-event result captured: fixture"
  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "a cycle that delivered nothing must still fail loudly: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "arm did not exit nonzero for a cycle that delivered nothing (status $status)"
  pass "watch-arm: a cycle that delivered no wake of its own still fails loudly"
}

# Make the watcher's best-effort delivery ledger unwritable and unreadable for
# the whole cycle, exactly as a lost append leaves it: the actionable close
# receipt is then the only identity-bound proof the cycle delivered its wake.
block_delivery_ledger() {  # <state>
  mkdir -p "$1/.watch-deliveries.log"
}

wait_for_file_text() {  # <file> <fixed-text> <tenths>
  local file=$1 text=$2 limit=$3 i=0
  while [ "$i" -lt "$limit" ]; do
    grep -qF "$text" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_attached_arm_resolves_a_lost_ledger_append_from_the_close_receipt() {
  local dir state fakebin out armout watcher_identity successor i
  dir=$(make_case attached-receipt-fallback)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  block_delivery_ledger "$state"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1
  watcher_identity=$(cat "$state/.watch.lock/pid-identity" 2>/dev/null || true)

  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  grep -q '^signal:' "$out" || fail "seed watcher did not surface the signal wake: $(cat "$out")"
  [ ! -f "$state/.watch-deliveries.log" ] \
    || fail "the delivery ledger recorded the wake, so this case proves nothing"
  grep -qF "kind=actionable" "$state/.watch-close" \
    || fail "the watcher did not publish its actionable close receipt: $(cat "$state/.watch-close" 2>/dev/null)"
  grep -qF "identity=$watcher_identity" "$state/.watch-close" \
    || fail "the actionable close receipt is not bound to the observed cycle"

  # The receipt proves the delivery but carries no reason line to replay, so the
  # arm continues supervising with a fresh cycle instead of closing empty.
  wait_for_file_text "$state/.watch-cycle-exits.log" 'reason=observed-actionable-close' 120 \
    || fail "the arm did not classify the identity-bound actionable close: $(cat "$state/.watch-cycle-exits.log" 2>/dev/null)"
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported a delivered wake as a failed cycle: $(cat "$armout")"
  is_live_non_zombie "$ARM_PID" \
    || fail "the arm ended instead of continuing across the actionable close"
  successor=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  # The continued arm owns a fresh watcher child; let it finish reaping before
  # terminating the waiting arm, or a shell blocked in wait can defer TERM.
  if [ -n "$successor" ]; then
    kill "$successor" 2>/dev/null || true
    i=0
    while [ "$i" -lt 80 ] && is_live_non_zombie "$successor"; do
      sleep 0.1
      i=$((i + 1))
    done
  fi
  kill "$ARM_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 80
  pass "watch-arm: a lost ledger append is resolved from the cycle's own actionable close receipt"
}

test_attached_arm_rejects_a_close_receipt_from_another_identity() {
  local dir state fakebin out armout status
  dir=$(make_case attached-foreign-receipt)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  block_delivery_ledger "$state"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # Negative control: an actionable receipt naming this cycle's pid but a
  # foreign identity. SIGKILL leaves it in place, so the receipt is the only
  # evidence the arm can find - and it must not silence the failure.
  printf 'pid=%s\nkind=actionable\nidentity=%s\n' "$SEED_PID" 'not-this-cycle' > "$state/.watch-close"
  kill -KILL "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "a foreign close receipt silenced a genuinely unexplained cycle: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "arm did not exit nonzero for a cycle explained only by a foreign receipt (status $status)"
  pass "watch-arm: a close receipt from another identity cannot resolve this cycle"
}

test_rearm_resurfaces_decision_without_new_queue_row() {
  local dir home state fakebin generation sequence
  dir=$(make_case decision-only-recovery)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  printf 'needs-decision [key=runtime]: choose recovery policy\n' > "$state/remote.status"
  printf 'pending:downtime:decision-only\n' > "$state/.watcher-down"
  : > "$state/.wake-queue"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/arm.out"
  wait_for_exit "$ARM_PID" 120 || fail "decision-only recovery arm did not close"
  grep -F 'check: rearm-resurface' "$dir/arm.out" >/dev/null \
    || fail "re-arm did not emit recovery for decision-only state"
  [ ! -s "$state/.wake-queue" ] || fail "decision-only recovery invented a queue row"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "decision-only recovery presentation failed"
  grep -F 'remote [key=runtime] needs-decision: choose recovery policy' "$dir/drain.out" >/dev/null \
    || fail "decision-only recovery did not re-present the folded decision set"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/drain.err")
  [ "$sequence" = 0 ] && [ -n "$generation" ] || fail "decision-only recovery omitted its zero-row acknowledgement"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "decision-only recovery acknowledgement failed"
  pass "watch-arm: decision-only recovery resurfaces without a new queue row"
}

test_process_event_gets_first_refusal_before_rearm_resurface() {
  local dir home state fakebin
  dir=$(make_case process-event-first-refusal)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  append_wake "$state" check 'procevent:fixture:1' 'check: procevent fixture source 1' \
    || fail "process-event fixture could not publish"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/arm.out"
  wait_for_exit "$ARM_PID" 120 || fail "process-event recovery arm did not close"
  grep -F 'check: process-event result captured:' "$dir/arm.out" >/dev/null \
    || fail "process-event did not receive first refusal"
  ! grep -F 'check: rearm-resurface' "$dir/arm.out" >/dev/null \
    || fail "generic recovery pre-empted process-event delivery"
  ack_wakes "$state" || fail "process-event recovery acknowledgement failed"
  pass "watch-arm: process-event delivery gets first refusal before recovery resurfacing"
}

# On Grok the monitor path is a tracked background arm whose EXIT becomes a
# synthetic primary turn. A benign wake the watcher absorbs must therefore keep
# the watcher blocking so the attached arm never exits - a fix that absorbed the
# wake inside the watcher but still let the arm exit would still burn a turn.
# This drives a real arm + real watcher end to end: a declared external-wait
# signal (the exact shape of the 2026-08-15 burn) must leave BOTH processes
# alive, while a genuine captain-relevant status still exits both.
test_attached_arm_stays_live_through_a_declared_wait_absorb() {
  local dir state fakebin out armout i
  dir=$(make_case declared-wait-no-arm-exit)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; armout="$dir/arm.out"
  printf 'kind=ship\n' > "$state/demo.meta"
  # The crew is NOT provably working, so a paused: signal can only be absorbed via
  # the declared-external-wait rule, not the provably-working path.
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A declared external-wait pause plus the same turn's turn-end.
  printf 'paused: awaiting the upstream release\n' > "$state/demo.status"
  : > "$state/demo.turn-ended"

  # Wait until the watcher has provably processed the signal (its .seen-* marker
  # advanced past the pre-existing signature) so the assertion is not racing the
  # poll rather than relying on a fixed sleep.
  i=0
  while [ "$i" -lt 300 ]; do
    [ -s "$state/.seen-demo_status" ] && break
    is_live_non_zombie "$SEED_PID" || break
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$state/.seen-demo_status" ] || fail "watcher never processed the declared-wait signal: $(cat "$out")"

  # The benign declared wait must NOT surface: the watcher keeps blocking and the
  # arm stays attached. Neither may have exited (the arm's exit is the turn).
  is_live_non_zombie "$SEED_PID" \
    || fail "watcher exited for a declared-wait signal (should absorb and keep blocking): $(cat "$out")"
  is_live_non_zombie "$ARM_PID" \
    || fail "attached arm exited on a declared-wait no-op, which on Grok becomes a synthetic primary turn: $(cat "$armout")"
  [ ! -s "$state/.wake-queue" ] || fail "a declared-wait signal enqueued a durable wake"
  [ ! -s "$out" ] || fail "the watcher printed a wake reason for a declared-wait signal: $(cat "$out")"
  ! grep -q '^signal:' "$armout" || fail "the arm reported a signal wake for a declared wait: $(cat "$armout")"

  # Positive control: a genuine captain-relevant status now DOES exit both,
  # proving the absorb is selective, not a permanently deaf arm.
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120 || fail "watcher did not surface a captain-relevant status after the absorb: $(cat "$out")"
  wait_for_exit "$ARM_PID" 120 || fail "arm did not exit for a genuine wake after the absorb: $(cat "$armout")"
  grep -q '^signal:' "$armout" || fail "arm did not report the genuine signal wake after the absorb: $(cat "$armout")"
  unset FM_FAKE_CREW_STATE FM_CREW_STATE_BIN
  pass "watch-arm: a declared-wait absorb keeps the real attached arm alive (no synthetic turn); a genuine wake still exits it"
}

# A recovery marker can be the only residue of a benign watcher rotation.
# Grok turns every tracked arm completion into a primary-model turn, so an empty
# recovery resurface must keep the same arm blocking across several real watcher
# polls while a later typed wake must still complete it.
test_quiet_recovery_keeps_arm_live_until_an_actionable_wake() {
  local dir home state fakebin
  dir=$(make_case quiet-recovery-no-arm-exit)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/arm.out"
  is_live_non_zombie "$ARM_PID" || fail "quiet-recovery arm did not stay live after start"

  # Publish after the initial recovery check so this is a live recovery cycle,
  # not merely startup with a pre-existing marker.
  sleep 0.5
  FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; fm_recovery_transition "$2" publish downtime' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "quiet recovery publication failed"

  # Three poll budgets are the quiet stretch. The tracked arm itself must not
  # complete, print a recovery reason, or publish a cycle-close row.
  sleep 3
  is_live_non_zombie "$ARM_PID" \
    || fail "quiet rearm-resurface completed the tracked arm: $(cat "$dir/arm.out")"
  grep -Fx 'check: rearm-resurface' "$dir/arm.out" >/dev/null \
    && fail "quiet recovery leaked an actionable reason into arm output"
  [ ! -s "$state/.watch-cycle-exits.log" ] \
    || fail "quiet recovery published an arm-completion lifecycle row: $(cat "$state/.watch-cycle-exits.log")"

  # Positive control: the same live waiter must still deliver genuine work.
  printf 'done: actionable after quiet recovery\n' > "$state/demo.status"
  wait_for_exit "$ARM_PID" 120 \
    || fail "quiet-recovery arm did not complete for a genuine wake: $(cat "$dir/arm.out")"
  grep -q '^signal:' "$dir/arm.out" \
    || fail "quiet-recovery arm did not report the genuine wake: $(cat "$dir/arm.out")"
  grep -q 'reason=actionable-signal' "$state/.watch-cycle-exits.log" \
    || fail "genuine wake after quiet recovery was not classified in the lifecycle ledger"
  pass "watch-arm: quiet recovery spends no arm completion while a later genuine wake still completes"
}

# Drive the recovery contract through a quiet delayed downtime, the next real
# actionable wake, generation-stable acknowledgement, and a live successor arm.
test_delayed_rearm_actionable_acknowledgement_sequence_self_heals() {
  local dir home state fakebin pair sequence generation
  dir=$(make_case delayed-rearm-actionable-acknowledgement)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  git init -q "$home"
  : > "$home/AGENTS.md"
  ln -s "$ROOT/bin" "$home/bin"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/rearm.out"
  is_live_non_zombie "$ARM_PID" || fail "delayed-recovery watcher did not stay live after start"
  grep -q '^watcher: started ' "$dir/rearm.out" \
    || fail "delayed-recovery fixture did not start a real watcher"

  # Publish after the first beat and initial recovery check, matching the
  # reproduced five-second shape while using this suite's one-second poll.
  sleep 0.5
  FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; fm_recovery_transition "$2" publish downtime' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "delayed downtime publication failed"
  sleep 3
  is_live_non_zombie "$ARM_PID" \
    || fail "delayed quiet recovery completed the watcher arm: $(cat "$dir/rearm.out")"
  [ -e "$state/.watch.lock" ] \
    || fail "delayed quiet recovery dropped the live watcher lock"
  ! grep -Fx 'check: rearm-resurface' "$dir/rearm.out" >/dev/null \
    || fail "delayed quiet recovery surfaced a no-work reason"

  printf 'done: recovery now has actionable work\n' > "$state/demo.status"
  wait_for_exit "$ARM_PID" 120 \
    || fail "delayed recovery did not deliver the later actionable wake"
  grep -q '^signal:' "$dir/rearm.out" \
    || fail "delayed recovery lost the later actionable reason: $(cat "$dir/rearm.out")"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "actionable recovery drain failed"
  pair=$(drain_ack_pair "$dir/drain.err") \
    || fail "drain did not print a generation-bound acknowledgement command"
  sequence=${pair%%$'\t'*}
  generation=${pair##*$'\t'}
  [ "$sequence" -gt 0 ] || fail "actionable recovery omitted its durable wake sequence"

  # Drive the normal close-publication primitive after the command was printed.
  # Its pending generation must survive, making that exact command usable.
  FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; fm_recovery_transition "$2" publish downtime' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "close downtime publication failed"
  [ "$(cat "$state/.watcher-down")" = "pending:downtime:$generation" ] \
    || fail "close publication replaced the printed acknowledgement generation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" 2> "$dir/ack.err" \
    || fail "the printed acknowledgement did not survive close publication: $(cat "$dir/ack.err")"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    acked:*) ;;
    *) fail "the surviving acknowledgement did not retire the recovery episode" ;;
  esac

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/next-arm.out"
  is_live_non_zombie "$ARM_PID" \
    || fail "the watcher armed after acknowledgement died inside its first cycle"
  ! grep -F 'check: rearm-resurface' "$dir/next-arm.out" >/dev/null \
    || fail "the watcher armed after acknowledgement re-announced retired recovery"
  printf 'blocked: a later wake the live watcher must still surface\n' > "$state/later.status"
  wait_for_exit "$ARM_PID" 120 || fail "the live watcher did not surface a later wake"
  grep -q '^signal:' "$dir/next-arm.out" \
    || fail "the watcher never reached real supervision work: $(cat "$dir/next-arm.out")"
  pass "watch-arm: delayed quiet recovery, actionable delivery, acknowledgement, and next arm self-heal"
}

# Replay an acknowledgement from a retired episode against a newer real
# watcher cycle, then follow the printed remedy through final retirement.
test_moved_generation_acknowledgement_is_self_healing() {
  local dir home state fakebin pair first_sequence first_generation second_generation
  dir=$(make_case moved-generation-acknowledgement)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "moved-generation fixture watcher did not stay live"
  printf 'done: first handled wake\n' > "$state/first.status"
  wait_for_exit "$ARM_PID" 120 || fail "fixture watcher did not deliver its first wake"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first-drain.out" \
    2> "$dir/first-drain.err" || fail "first drain did not present the durable wake"
  pair=$(drain_ack_pair "$dir/first-drain.err") \
    || fail "first drain did not print a generation-bound acknowledgement command"
  first_sequence=${pair%%$'\t'*}
  first_generation=${pair##*$'\t'}
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$first_sequence" \
    --recovery-generation "$first_generation" \
    || fail "the first handled wake could not be acknowledged"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/second-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "second fixture watcher did not stay live"
  printf 'done: second wake in a newer recovery episode\n' > "$state/second.status"
  wait_for_exit "$ARM_PID" 120 || fail "second fixture watcher did not deliver its wake"
  second_generation=$(sed -n 's/^pending:downtime:\(.*\)$/\1/p' "$state/.watcher-down")
  [ -n "$second_generation" ] || fail "a wake after acknowledgement did not open a recovery episode"
  [ "$second_generation" != "$first_generation" ] \
    || fail "an acknowledged episode kept its generation instead of opening a new one"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$first_sequence" \
    --recovery-generation "$first_generation" 2> "$dir/stale-ack.err" \
    || fail "a replayed old acknowledgement was rejected instead of degrading safely"
  grep -F 're-run bin/fm-wake-drain.sh and use the new WAKE_ACK_REQUIRED command' "$dir/stale-ack.err" >/dev/null \
    || fail "the moved generation did not print the exact remedy: $(cat "$dir/stale-ack.err")"
  grep "$(printf '\tsignal\tsecond.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "the old exact acknowledgement consumed a wake above its sequence"
  [ "$(cat "$state/.watcher-down")" = "pending:downtime:$second_generation" ] \
    || fail "the old exact acknowledgement retired the newer recovery episode"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through 999 \
    --recovery-generation "$first_generation" 2> "$dir/stale-consume.err" \
    || fail "a moved-generation acknowledgement refused sequence-bound consumption"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a moved-generation acknowledgement left handled rows queued"
  [ "$(cat "$state/.watcher-down")" = "pending:downtime:$second_generation" ] \
    || fail "row consumption under a stale generation retired the pending episode"
  grep -F 're-run bin/fm-wake-drain.sh and use the new WAKE_ACK_REQUIRED command' "$dir/stale-consume.err" >/dev/null \
    || fail "sequence-bound consumption omitted the exact remedy"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/redrain.out" \
    2> "$dir/redrain.err" || fail "the remedy re-drain did not run"
  pair=$(drain_ack_pair "$dir/redrain.err") \
    || fail "the remedy re-drain did not print the newer acknowledgement command"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "${pair%%$'\t'*}" \
    --recovery-generation "${pair##*$'\t'}" \
    || fail "the newer recovery episode could not be acknowledged"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    acked:*) ;;
    *) fail "following the printed remedy did not retire the newer recovery episode" ;;
  esac
  pass "watch-arm: moved generation consumes by sequence and names its self-healing remedy"
}

test_attached_arm_reports_the_delivered_wake
test_attached_arm_reports_the_delivered_wake_after_drain
test_attached_arm_still_fails_on_a_wake_it_did_not_deliver
test_attached_arm_resolves_a_lost_ledger_append_from_the_close_receipt
test_attached_arm_rejects_a_close_receipt_from_another_identity
test_rearm_resurfaces_decision_without_new_queue_row
test_process_event_gets_first_refusal_before_rearm_resurface
test_attached_arm_stays_live_through_a_declared_wait_absorb
test_quiet_recovery_keeps_arm_live_until_an_actionable_wake
test_delayed_rearm_actionable_acknowledgement_sequence_self_heals
test_moved_generation_acknowledgement_is_self_healing
