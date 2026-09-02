#!/usr/bin/env bash
# tests/fm-supervise-daemon-catchall.test.sh - the away-mode catch-all must
# consider the attended presentation cursor before escalating status history.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# shellcheck source=bin/fm-supervise-daemon.sh
. "$DAEMON"

TMP_ROOT=$(fm_test_tmproot fm-supervise-daemon-catchall-tests)

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
test_status_appended_after_away_entry_remains_a_candidate
