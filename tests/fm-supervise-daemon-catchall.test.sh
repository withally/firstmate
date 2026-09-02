#!/usr/bin/env bash
# tests/fm-supervise-daemon-catchall.test.sh - the away-mode catch-all must
# consider the attended presentation cursor before escalating status history.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

# shellcheck source=bin/fm-supervise-daemon.sh
. "$DAEMON"

TMP_ROOT=$(fm_test_tmproot fm-supervise-daemon-catchall-tests)

fm_test_status_identity_reader() {
  printf '%s\n' "$FM_TEST_STATUS_IDENTITY"
}

test_presented_status_before_away_entry_is_not_escalated() {
  local dir state status snapshot
  dir=$(make_supercase presented-before-away)
  state="$dir/state"
  status="$state/pilo-continuity-s1.status"
  printf 'done: prototype server stopped after review\n' > "$status"

  snapshot=$(status_presentation_snapshot "$state") \
    || fail "could not snapshot the attended presentation boundary"
  status_commit_presentation_snapshot "$state" "$snapshot" \
    || fail "could not commit the attended presentation boundary"
  prime_status_seen "$state" "$status" \
    || fail "could not prime the canonical signal seen marker"

  afk_enter "$state"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"

  [ ! -s "$state/.subsuper-delivery.jsonl" ] \
    || fail "catch-all escalated status history already handled before away mode"
  pass "catch-all ignores a status line presented before away-mode entry"
}

test_repeated_identical_append_after_seen_marker_is_escalated() {
  local dir state status snapshot line buffered
  dir=$(make_supercase repeated-identical-append)
  state="$dir/state"
  status="$state/pilo-continuity-s1.status"
  line='done: prototype server stopped after review'
  printf '%s\n' "$line" > "$status"

  snapshot=$(status_presentation_snapshot "$state") \
    || fail "could not snapshot the attended presentation boundary"
  status_commit_presentation_snapshot "$state" "$snapshot" \
    || fail "could not commit the attended presentation boundary"
  mark_status_seen "$state" pilo-continuity-s1 "$line" \
    || fail "could not record the canonical seen marker"
  status_seen_matches "$state" pilo-continuity-s1 "$status" "$line" \
    || fail "canonical seen marker did not match its current status event"

  afk_enter "$state"
  printf '%s\n' "$line" >> "$status"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"

  buffered=$(jq -s -r 'map(select(.state == "buffered") | .text) | .[]' \
    "$state/.subsuper-delivery.jsonl" 2>/dev/null || true)
  [ -n "$buffered" ] \
    || fail "catch-all dropped an identical status append after its seen marker"
  printf '%s\n' "$buffered" | grep -F "$line (catch-all scan)" >/dev/null \
    || fail "catch-all buffered the wrong repeated status append"
  pass "catch-all escalates an identical status append after the seen marker"
}

test_reused_task_id_does_not_inherit_seen_marker() {
  local dir state status snapshot line buffered
  dir=$(make_supercase reused-task-id)
  state="$dir/state"
  status="$state/reused.status"
  line='done: replacement task completed'
  printf '%s\n' "$line" > "$status"

  FM_STATUS_IDENT_READER=fm_test_status_identity_reader
  FM_TEST_STATUS_IDENTITY=incarnation-a
  snapshot=$(status_presentation_snapshot "$state") \
    || fail "could not snapshot the original status-file identity"
  status_commit_presentation_snapshot "$state" "$snapshot" \
    || fail "could not commit the original presentation boundary"
  mark_status_seen "$state" reused "$line" "$status" \
    || fail "could not record the original task's seen marker"
  status_retire_presentation_task "$state" reused \
    || fail "could not retire the original task status"

  FM_TEST_STATUS_IDENTITY=incarnation-b
  printf '%s\n' "$line" > "$status"
  afk_enter "$state"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"

  buffered=$(jq -s -r 'map(select(.state == "buffered") | .text) | .[]' \
    "$state/.subsuper-delivery.jsonl" 2>/dev/null || true)
  printf '%s\n' "$buffered" | grep -F "$line (catch-all scan)" >/dev/null \
    || fail "catch-all suppressed a replacement task's first status line"
  unset FM_STATUS_IDENT_READER FM_TEST_STATUS_IDENTITY
  pass "catch-all does not reuse a seen marker across task-file incarnations"
}

test_captured_seen_offset_keeps_racing_append_eligible() {
  local dir state status snapshot line candidate_offset candidate_ident marker marker_data expected_marker buffered
  dir=$(make_supercase captured-candidate)
  state="$dir/state"
  status="$state/pilo-continuity-s1.status"
  line='done: prototype server stopped after review'
  printf 'working: prototype server still running\n' > "$status"

  snapshot=$(status_presentation_snapshot "$state") \
    || fail "could not snapshot the attended presentation boundary"
  status_commit_presentation_snapshot "$state" "$snapshot" \
    || fail "could not commit the attended presentation boundary"
  printf '%s\n' "$line" >> "$status"
  candidate_offset=$(status_last_line_offset "$status") \
    || fail "could not capture the candidate status offset"
  candidate_ident=$(_fm_open_decisions_file_ident "$status") \
    || fail "could not capture the candidate status identity"
  printf '%s\n' "$line" >> "$status"
  mark_status_seen "$state" pilo-continuity-s1 "$line" "$status" \
    "$candidate_offset" "$candidate_ident" \
    || fail "could not record the captured candidate identity"
  marker="$state/.subsuper-seen-status-pilo-continuity-s1"
  marker_data=$(LC_ALL=C command cat "$marker" 2>/dev/null) \
    || fail "could not read the captured candidate marker"
  expected_marker=$(printf 'ident=%s\noffset=%s\n%s' \
    "$candidate_ident" "$candidate_offset" "$line")
  [ "$marker_data" = "$expected_marker" ] \
    || fail "seen marker did not preserve the captured candidate identity"

  afk_enter "$state"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"

  buffered=$(jq -s -r 'map(select(.state == "buffered") | .text) | .[]' \
    "$state/.subsuper-delivery.jsonl" 2>/dev/null || true)
  printf '%s\n' "$buffered" | grep -F "$line (catch-all scan)" >/dev/null \
    || fail "catch-all suppressed an append after the captured candidate"
  pass "catch-all preserves a racing identical append after marker capture"
}

test_status_appended_after_away_entry_remains_a_candidate() {
  local dir state status snapshot buffered
  dir=$(make_supercase appended-after-away)
  state="$dir/state"
  status="$state/pilo-continuity-s1.status"
  printf 'working: prototype server still running\n' > "$status"

  snapshot=$(status_presentation_snapshot "$state") \
    || fail "could not snapshot the attended presentation boundary"
  status_commit_presentation_snapshot "$state" "$snapshot" \
    || fail "could not commit the attended presentation boundary"
  prime_status_seen "$state" "$status" \
    || fail "could not prime the canonical signal seen marker"

  afk_enter "$state"
  printf 'done: prototype server stopped after review\n' >> "$status"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"

  buffered=$(jq -s -r 'map(select(.state == "buffered") | .text) | .[]' \
    "$state/.subsuper-delivery.jsonl" 2>/dev/null || true)
  case "$buffered" in
    *'done: prototype server stopped after review (catch-all scan)'*) ;;
    *) fail "catch-all missed a status line appended after away-mode entry: $buffered" ;;
  esac
  pass "catch-all keeps status appended after away-mode entry eligible"
}

test_presented_status_before_away_entry_is_not_escalated
test_repeated_identical_append_after_seen_marker_is_escalated
test_reused_task_id_does_not_inherit_seen_marker
test_captured_seen_offset_keeps_racing_append_eligible
test_status_appended_after_away_entry_remains_a_candidate
