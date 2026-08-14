#!/usr/bin/env bash
# Behavioral coverage for bounded inactive terminal-outcome reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECON="$ROOT/bin/fm-inactive-reconcile.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-inactive-reconcile)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

set_mtime() { # <epoch> <path>...
  local epoch=$1 path stamp
  shift
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    :
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
  fi
  for path in "$@"; do
    touch -t "$stamp" "$path"
  done
}

make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  HOME_DIR="$WORLD/home"
  FAKEBIN="$WORLD/fakebin"
  mkdir -p "$HOME_DIR"/{state,data,config,projects} "$FAKEBIN"
  cat > "$FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: test\n' "${FM_FAKE_CREW_STATE:-unknown}"
SH
  chmod +x "$FAKEBIN/fm-crew-state.sh"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
  list-panes) exit 0 ;;
esac
SH
  chmod +x "$FAKEBIN/tmux"
}

write_child() { # <id> <status> [kind]
  local id=$1 status=$2 kind=${3:-ship} old
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$HOME_DIR/projects/alpha" \
    'project=alpha' 'harness=codex' "kind=$kind" 'mode=no-mistakes' \
    'yolo=off' "spawn_gen=spawn-$id" 'pr=https://example.test/owner/repo/pull/1'
  printf '%s\n' "$status" > "$HOME_DIR/state/$id.status"
  : > "$HOME_DIR/state/$id.turn-ended"
  old=$(( $(date +%s) - 120 ))
  set_mtime "$old" "$HOME_DIR/state/$id.meta" "$HOME_DIR/state/$id.status" \
    "$HOME_DIR/state/$id.turn-ended"
}

run_reconcile() { # [--startup]
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_INACTIVE_RECONCILE_SECS="${FM_INACTIVE_RECONCILE_SECS:-60}" \
    FM_INACTIVE_RECONCILE_BUDGET_SECS="${FM_INACTIVE_RECONCILE_BUDGET_SECS:-3}" \
    FM_INACTIVE_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    "$RECON" scan ${1:+"$1"}
}

outcome_count() { # <suffix>
  find "$HOME_DIR/state/terminal-outcomes" -type f -name "*.$1" 2>/dev/null \
    | wc -l | tr -d ' '
}

test_main_receipt_closes_only_with_handled_generation() {
  local err sequence generation
  make_world main-receipt
  write_child child 'done: PR checks green'

  FM_FAKE_CREW_STATE='done' run_reconcile --startup
  assert_grep "$(printf '\tcheck\tinactive-outcome:')" "$HOME_DIR/state/.wake-queue" \
    "terminal main-home outcome did not enter the durable wake queue"
  [ "$(outcome_count pending)" = 1 ] || fail "terminal outcome did not retain one pending receipt"

  err="$WORLD/drain.err"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" >/dev/null 2> "$err"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "presentation omitted its generation-bound acknowledgement"
  [ "$(outcome_count pending)" = 1 ] || fail "presentation acknowledged the receipt before handling"
  [ -s "$HOME_DIR/state/.wake-queue" ] || fail "presentation consumed the wake before handling"

  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" \
    --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "generation-bound handling acknowledgement failed"
  [ "$(outcome_count pending)" = 0 ] || fail "handled outcome remained pending"
  [ "$(outcome_count presented)" = 1 ] || fail "handled outcome did not receive a closed receipt"
  [ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "handled outcome wake remained queued"
  pass "main terminal outcome closes only with post-handling generation acknowledgement"
}

test_nonterminal_and_held_work_never_reports() {
  local state
  for state in working paused parked blocked unknown; do
    make_world "nonterminal-$state"
    write_child child 'working: still active'
    FM_FAKE_CREW_STATE="$state" run_reconcile --startup
    [ "$(outcome_count pending)" = 0 ] || fail "$state produced a terminal receipt"
    [ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "$state produced a terminal wake"
  done

  make_world captain-held
  write_child child 'captain-held: awaiting captain'
  FM_FAKE_CREW_STATE='done' run_reconcile --startup
  [ "$(outcome_count pending)" = 0 ] || fail "captain-held work produced a terminal receipt"

  make_world persistent-secondmate
  write_child mate 'done: idle persistent supervisor' secondmate
  FM_FAKE_CREW_STATE='done' run_reconcile --startup
  [ "$(outcome_count pending)" = 0 ] || fail "persistent secondmate produced a terminal receipt"
  pass "nonterminal, captain-held, and persistent-secondmate work remains untouched"
}

test_stale_generation_cannot_close_or_consume() {
  local err sequence generation rc=0
  make_world stale-generation
  write_child child 'failed: terminal'
  FM_FAKE_CREW_STATE=failed run_reconcile --startup
  err="$WORLD/drain.err"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" >/dev/null 2> "$err"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")

  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" \
    --ack-through "$sequence" --recovery-generation stale-generation >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "stale generation acknowledgement unexpectedly succeeded"
  [ "$(outcome_count pending)" = 1 ] || fail "stale generation closed the terminal receipt"
  [ -s "$HOME_DIR/state/.wake-queue" ] || fail "stale generation consumed the terminal wake"

  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" \
    --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "original generation could not acknowledge retained work"
  pass "stale recovery generations change neither receipt nor wake"
}

test_missing_receipt_cannot_be_acknowledged_away() {
  local err sequence generation pending rc=0
  make_world missing-receipt
  write_child child 'failed: terminal'
  FM_FAKE_CREW_STATE=failed run_reconcile --startup
  pending=$(find "$HOME_DIR/state/terminal-outcomes" -type f -name '*.pending')
  rm -f -- "$pending"
  err="$WORLD/drain.err"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" >/dev/null 2> "$err"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")

  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" \
    --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "acknowledgement consumed a terminal wake whose receipt was missing"
  [ -s "$HOME_DIR/state/.wake-queue" ] || fail "missing receipt allowed its terminal wake to be lost"
  pass "a missing receipt fails acknowledgement closed and preserves its wake"
}

test_generation_change_after_receipt_keeps_wake_recoverable() {
  local err sequence generation real_mv rc=0
  make_world acknowledgement-race
  write_child child 'done: terminal'
  FM_FAKE_CREW_STATE='done' run_reconcile --startup
  err="$WORLD/drain.err"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" >/dev/null 2> "$err"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  real_mv=$(command -v mv)
  cat > "$FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
"${FM_TEST_REAL_MV:?}" "$@" || exit $?
case "$destination" in
  */terminal-outcomes/*.presented)
    printf 'pending:handling:replacement-generation\n' > "${FM_TEST_STATE:?}/.watcher-down"
    ;;
esac
SH
  chmod +x "$FAKEBIN/mv"

  PATH="$FAKEBIN:$PATH" FM_TEST_REAL_MV="$real_mv" FM_TEST_STATE="$HOME_DIR/state" \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" \
    --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "generation-changing acknowledgement unexpectedly succeeded"
  [ "$(outcome_count presented)" = 1 ] || fail "receipt was not durable before generation revalidation"
  [ -s "$HOME_DIR/state/.wake-queue" ] || fail "generation change lost the still-uncommitted wake"

  PATH="${PATH#"$FAKEBIN:"}" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" \
    --ack-through "$sequence" --recovery-generation replacement-generation \
    || fail "replacement generation could not finish the idempotent acknowledgement"
  [ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "replacement generation left the handled wake queued"
  pass "generation change after receipt commit leaves a recoverable queued wake"
}

bind_secondmate() { # <local|remote>
  local route=$1
  printf 'mate\n' > "$HOME_DIR/.fm-secondmate-home"
  if [ "$route" = local ]; then
    mkdir -p "$WORLD/parent/state"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$WORLD/parent" \
      > "$HOME_DIR/.fm-secondmate-parent"
  else
    printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$HOME_DIR/.fm-secondmate-parent"
  fi
}

test_secondmate_parent_report_is_append_first_and_idempotent() {
  local rc=0
  make_world local-secondmate
  bind_secondmate local
  write_child child 'done: terminal'
  cat > "$FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in */terminal-outcomes/*.reported) exit 97 ;; esac
exec /bin/mv "$@"
SH
  chmod +x "$FAKEBIN/mv"
  FM_FAKE_CREW_STATE='done' run_reconcile --startup >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "simulated receipt failure unexpectedly succeeded"
  assert_grep 'done [key=inactive-outcome-mate-child-done]:' "$WORLD/parent/state/mate.status" \
    "local secondmate did not append before attempting receipt closure"
  [ "$(outcome_count pending)" = 1 ] || fail "append-first failure did not retain the pending receipt"

  rm -f -- "$FAKEBIN/mv"
  FM_FAKE_CREW_STATE='done' run_reconcile --startup
  [ "$(outcome_count reported)" = 1 ] || fail "secondmate did not close its reported receipt"

  FM_FAKE_CREW_STATE='done' run_reconcile --startup
  [ "$(grep -c 'inactive-outcome-mate-child-done' "$WORLD/parent/state/mate.status")" = 1 ] \
    || fail "secondmate duplicated its parent report on retry"

  make_world remote-secondmate
  bind_secondmate remote
  write_child child 'failed: terminal'
  FM_FAKE_CREW_STATE=failed run_reconcile --startup
  assert_grep 'failed [key=inactive-outcome-mate-child-failed]:' \
    "$HOME_DIR/state/parent-replies.status" \
    "remote secondmate did not append the established relay input"
  [ "$(outcome_count reported)" = 1 ] || fail "remote secondmate did not close its reported receipt"
  pass "secondmate parent reporting is append-first and restart-idempotent"
}

test_bounded_scan_resumes_after_stalled_state_read() {
  local started elapsed
  make_world bounded-resume
  write_child a 'working: state read stalls'
  write_child b 'done: terminal'
  cat > "$FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = a ]; then
  sleep 30
else
  printf 'state: done · source: test\n'
fi
SH
  chmod +x "$FAKEBIN/fm-crew-state.sh"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile --startup
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 3 ] || fail "stalled current-state read exceeded the aggregate budget (${elapsed}s)"
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile --startup
  assert_grep 'child=b state=done' "$HOME_DIR/state/.wake-queue" \
    "next bounded scan did not resume after the stalled child"
  pass "bounded scan resumes after a stalled current-state read"
}

test_watcher_poll_surfaces_missed_terminal_outcome() {
  local output pid i signature
  make_world watcher
  write_child child 'done: terminal'
  if [ "$(uname)" = Darwin ]; then
    signature=$(stat -f '%z:%Fm' "$HOME_DIR/state/child.status")
  else
    signature=$(stat -c '%s:%Y' "$HOME_DIR/state/child.status")
  fi
  printf '%s' "$signature" > "$HOME_DIR/state/.seen-child_status"
  output="$WORLD/watch.out"

  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_RECONCILE_BUDGET_SECS=3 \
    FM_INACTIVE_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" FM_FAKE_CREW_STATE='done' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$output" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 300 ] && kill -0 "$pid" 2>/dev/null; do
    grep -Fq 'check: inactive-outcome' "$output" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_grep 'check: inactive-outcome' "$output" \
    "watcher poll did not surface the bounded reconciliation wake: $(cat "$output")"
  assert_grep 'inactive-outcome:' "$HOME_DIR/state/.wake-queue" \
    "watcher poll did not retain the terminal wake durably"
  pass "watcher poll surfaces a missed terminal outcome"
}

test_broken_parent_route_has_repair_and_retirement_path() {
  local err sequence generation
  make_world repair-route
  printf 'mate\n' > "$HOME_DIR/.fm-secondmate-home"
  write_child child 'done: terminal'

  FM_FAKE_CREW_STATE='done' run_reconcile --startup
  [ "$(outcome_count pending)" = 1 ] || fail "broken parent route did not retain its pending receipt"
  assert_grep 'inactive-reconcile:' "$HOME_DIR/state/.wake-queue" \
    "broken parent route did not surface a durable local repair wake"

  err="$WORLD/drain.err"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" >/dev/null 2> "$err"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" \
    --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "repair wake could not be acknowledged after handling"
  [ "$(outcome_count pending)" = 1 ] || fail "repair-wake handling lost the terminal outcome receipt"

  mkdir -p "$WORLD/parent/state"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$WORLD/parent" \
    > "$HOME_DIR/.fm-secondmate-parent"
  FM_FAKE_CREW_STATE='done' run_reconcile --startup
  assert_grep 'done [key=inactive-outcome-mate-child-done]:' "$WORLD/parent/state/mate.status" \
    "repaired route did not deliver the retained outcome"
  [ "$(outcome_count pending)" = 0 ] || fail "repaired route left the terminal outcome pending forever"
  [ "$(outcome_count reported)" = 1 ] || fail "repaired route did not retire the outcome as reported"
  pass "broken parent route remains visible and retires after repair"
}

test_reconciliation_never_invokes_forge_or_check_scripts() {
  local tool
  make_world local-only
  write_child child 'done: terminal'
  : > "$WORLD/network.log"
  for tool in gh gh-axi curl; do
    cat > "$FAKEBIN/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${FM_TEST_NETWORK_LOG:?}"
exit 97
SH
    chmod +x "$FAKEBIN/$tool"
  done
  cat > "$HOME_DIR/state/child.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'check-script\n' >> "${FM_TEST_NETWORK_LOG:?}"
exit 97
SH
  chmod +x "$HOME_DIR/state/child.check.sh"

  FM_TEST_NETWORK_LOG="$WORLD/network.log" FM_FAKE_CREW_STATE='done' run_reconcile --startup
  [ ! -s "$WORLD/network.log" ] || fail "reconciliation reached a forbidden command: $(cat "$WORLD/network.log")"
  pass "reconciliation reads no forge, network, or state check path"
}

test_main_receipt_closes_only_with_handled_generation
test_nonterminal_and_held_work_never_reports
test_stale_generation_cannot_close_or_consume
test_missing_receipt_cannot_be_acknowledged_away
test_generation_change_after_receipt_keeps_wake_recoverable
test_secondmate_parent_report_is_append_first_and_idempotent
test_bounded_scan_resumes_after_stalled_state_read
test_watcher_poll_surfaces_missed_terminal_outcome
test_reconciliation_never_invokes_forge_or_check_scripts
test_broken_parent_route_has_repair_and_retirement_path

echo "all inactive reconciliation tests passed"
