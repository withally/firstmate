#!/usr/bin/env bash
# Behavioral coverage for signal-marker identity and task retirement.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-seen-identity)

watch_bg() {  # <state> <fakebin> <output>
  local state=$1 fakebin=$2 out=$3
  PATH="$fakebin:$PATH" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=0.1 FM_SIGNAL_GRACE=0.1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
}

reap() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

seen_current() {  # <state> <status-file>
  FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_wake_signal_seen_current "$2" "$3"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

test_reused_task_id_reclassifies_from_byte_zero() {
  local dir state fakebin out status_file replacement new_size pid
  dir=$(make_case reused-signal-id)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/reused.status"
  head -c 100 /dev/zero | tr '\0' x > "$status_file"
  prime_status_seen "$state" "$status_file" || fail "could not prime the old task log marker"
  replacement="$dir/replacement.status"
  {
    printf 'done: early\n'
    head -c 128 /dev/zero | tr '\0' x
  } > "$replacement"
  mv -f "$replacement" "$status_file"
  new_size=$(wc -c < "$status_file" | tr -d ' ')
  [ "$new_size" -eq 140 ] || fail "replacement fixture was not 140 bytes"

  export FM_FAKE_CREW_STATE='state: unknown · source: none · reused task fixture'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "reused task id lost its early terminal signal: $(cat "$out")"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "reused task id did not surface its early terminal signal: $(cat "$out")"
  pass "a reused task id classifies replacement status from byte zero"
}

test_distinct_task_ids_keep_independent_seen_markers() {
  local dir state dotted underscored
  dir=$(make_case distinct-signal-ids)
  state="$dir/state"
  dotted="$state/a.b.status"
  underscored="$state/a_b.status"
  printf 'working: dotted\n' > "$dotted"
  printf 'working: underscored\n' > "$underscored"
  prime_status_seen "$state" "$dotted" || fail "could not prime dotted task marker"
  prime_status_seen "$state" "$underscored" || fail "could not prime underscored task marker"
  seen_current "$state" "$dotted" \
    || fail "a.b and a_b task markers aliased after both were primed"
  seen_current "$state" "$underscored" \
    || fail "a_b marker was not independent after both were primed"
  pass "valid dotted and underscored task ids keep independent signal markers"
}

test_unchanged_status_marker_stays_quiet() {
  local dir state fakebin out status_file pid rc=0
  dir=$(make_case unchanged-signal)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: already announced\n' > "$status_file"
  prime_status_seen "$state" "$status_file" || fail "could not prime unchanged status marker"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · unchanged task fixture'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 30 || rc=$?
  [ "$rc" -eq 124 ] || fail "unchanged status marker unexpectedly ended the watcher (rc=$rc)"
  [ ! -s "$out" ] || fail "unchanged status marker was re-presented: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "unchanged status marker queued a wake"
  pass "an unchanged status marker produces no signal re-presentation"
}

test_retirement_removes_seen_and_presentation_state() {
  local dir state status_file ident
  dir=$(make_case retire-signal-state)
  state="$dir/state"; status_file="$state/task.status"
  printf 'working: old task\n' > "$status_file"
  prime_status_seen "$state" "$status_file" || fail "could not prime retired task marker"
  printf 'signal state\n' > "$state/.task.signal-open-keys"
  printf 'pending signal state\n' > "$state/.task.signal-open-keys.pending.fixture"
  printf 'open decision cursor\n' > "$state/.task.open-decisions-cursor"
  if [ "$(uname)" = Darwin ]; then
    ident=$(stat -f '%d:%i' "$status_file")
  else
    ident=$(stat -c '%d:%i' "$status_file")
  fi
  printf 'task\t%s\t0\nneighbor\t%s\t0\n' "$ident" "$ident" > "$state/.status-presentation-cursor"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    status_retire_presentation_task "$2" task
  ' _ "$ROOT" "$state" || fail "retiring task presentation state failed"

  [ ! -e "$state/.seen-task_status" ] || fail "task signal marker survived retirement"
  [ ! -e "$state/.task.signal-open-keys" ] || fail "signal open-key state survived retirement"
  [ ! -e "$state/.task.signal-open-keys.pending.fixture" ] || fail "pending signal state survived retirement"
  [ ! -e "$state/.task.open-decisions-cursor" ] || fail "open-decision cursor survived retirement"
  [ ! -e "$state/task.status" ] || fail "task status survived retirement"
  ! grep '^task[[:space:]]' "$state/.status-presentation-cursor" >/dev/null \
    || fail "retired task presentation row survived retirement"
  grep '^neighbor[[:space:]]' "$state/.status-presentation-cursor" >/dev/null \
    || fail "retirement removed a neighboring presentation row"
  pass "task retirement removes seen, signal, open-decision, and presentation state"
}

test_reused_task_id_reclassifies_from_byte_zero
test_distinct_task_ids_keep_independent_seen_markers
test_unchanged_status_marker_stays_quiet
test_retirement_removes_seen_and_presentation_state
