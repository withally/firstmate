#!/usr/bin/env bash
# End-to-end copied-state migration coverage for fork version-5 status cursors.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# shellcheck source=tests/cutover-state-fixture-helpers.sh
. "$ROOT/tests/cutover-state-fixture-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-cutover-state-migration-tests)

exercise_version_5_home() {  # <fixture> <state> <task> <key> <post-copy-note>
  local fixture=$1 state=$2 task=$3 key=$4 note=$5 out status cursor probe appended read_bytes
  out="${state%/state}/$task.out"
  status="$state/$task.status"
  cursor="$state/.$task.open-decisions-cursor"
  probe="${state%/state}/$task.probe"
  fm_cutover_render_fixture "$fixture" "$state" "$task"
  : > "$probe"
  appended=$(printf 'note: %s\n' "$note" | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "first drain over copied $fixture state failed"
  grep -F "$task [key=$key]" "$out" >/dev/null \
    || fail "the imported cursor hid the copied $fixture decision: $(cat "$out")"
  grep -F "$task note: $note" "$out" >/dev/null \
    || fail "the imported presentation cursor hid the post-copy note: $(cat "$out")"
  if grep -F 'historical note already presented before cutover' "$out" >/dev/null; then
    fail "the imported presentation cursor bulk-replayed $fixture history: $(cat "$out")"
  fi
  grep -F 'version=6' "$cursor" >/dev/null \
    || fail "the version-5 $fixture decision cursor was not imported into the current schema"
  read_bytes=$(grep -F "$(printf '%s\t' "$status")" "$probe" | tail -1 | cut -f2)
  [ "$read_bytes" = "$appended" ] \
    || fail "the version-5 $fixture importer refolded $read_bytes bytes instead of only the $appended-byte post-copy append"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "warm drain after $fixture migration failed"
  if grep -F "$note" "$out" >/dev/null; then
    fail "the imported presentation cursor replayed its post-copy note: $(cat "$out")"
  fi
}

test_copied_home_shapes_import_without_history_replay() {
  local dir
  dir=$(make_case copied-home-shapes)
  exercise_version_5_home main-home "$dir/main-home/state" main-copy main-choice \
    "main-home first post-copy update"
  exercise_version_5_home local-secondmate "$dir/local-secondmate-home/state" local-copy local-choice \
    "local-secondmate first post-copy update"
  exercise_version_5_home remote-home "$dir/remote-host/fm-homes/remote-copy/state" remote-copy remote-choice \
    "remote-home first post-copy update"
  pass "copied main, local-secondmate, and remote-home version-5 state imports without hidden decisions or history replay"
}

test_copied_home_shapes_import_without_history_replay
