#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'done: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_unread_informational_lines_surface_once() {
  local dir state out
  dir=$(make_case unread-informational)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: initial work\n' > "$state/task-note.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "initial unread-status drain failed"
  printf 'note: captain answer that must not be buried\n' >> "$state/task-note.status"
  printf 'note: later routine append\n' >> "$state/task-note.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "unread-status drain failed"
  grep -F 'task-note note: captain answer that must not be buried' "$out" >/dev/null \
    || fail "an earlier unread note disappeared behind a later append: $(cat "$out")"
  grep -F 'task-note note: later routine append' "$out" >/dev/null \
    || fail "the latest unread note was not presented: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second unread-status drain failed"
  if grep -F 'captain answer that must not be buried' "$out" >/dev/null; then
    fail "an already-presented informational line replayed: $(cat "$out")"
  fi
  pass "every unread informational line surfaces exactly once"
}

test_buried_pending_reply_resolution_surfaces_and_closes() {
  local dir state out key
  dir=$(make_case buried-pending-reply)
  state="$dir/state"
  out="$dir/drain.out"
  key=pending-reply-abcdef0123456789
  printf 'blocked [key=%s]: pending-reply-missed: task=mate pending-reply-id=abcdef0123456789 request=ship it\n' \
    "$key" > "$state/mate.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "pending-reply opening drain failed"
  printf 'resolved [key=%s]: pending-reply-resolved: task=mate pending-reply-id=abcdef0123456789 via=status\n' \
    "$key" >> "$state/mate.status"
  printf 'note: unrelated later append\n' >> "$state/mate.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "pending-reply resolution drain failed"
  grep -F 'pending-reply-resolved: task=mate pending-reply-id=abcdef0123456789 via=status' "$out" >/dev/null \
    || fail "a pending-reply resolution disappeared behind a later append: $(cat "$out")"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the presented pending-reply resolution did not close its bounded decision: $(cat "$out")"
  fi
  pass "a buried pending-reply resolution surfaces and closes its exact decision"
}

test_presentation_cursor_stops_at_captured_endpoint() {
  local dir state out snapshot acknowledged
  dir=$(make_case presentation-race)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'note: initial presented line\n' > "$state/race.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "cursor priming drain failed"
  printf 'note: included in snapshot\n' >> "$state/race.status"

  snapshot=$(STATE="$state" bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-classify-lib.sh"; status_presentation_snapshot "$STATE"' _ "$ROOT") \
    || fail "presentation snapshot failed"
  printf 'note: appended after snapshot\n' >> "$state/race.status"
  acknowledged=$(STATE="$state" SNAPSHOT="$snapshot" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-classify-lib.sh"; status_acknowledge_presented_snapshot "$STATE" "$SNAPSHOT"' _ "$ROOT") \
    || fail "presentation acknowledgement failed"
  STATE="$state" SNAPSHOT="$acknowledged" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-classify-lib.sh"; status_commit_presentation_snapshot "$STATE" "$SNAPSHOT"' _ "$ROOT" \
    || fail "presentation cursor commit failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "post-snapshot drain failed"
  grep -F 'race note: appended after snapshot' "$out" >/dev/null \
    || fail "a post-snapshot append was swallowed by cursor advancement: $(cat "$out")"
  if grep -F 'race note: included in snapshot' "$out" >/dev/null; then
    fail "the committed captured span replayed on the next drain: $(cat "$out")"
  fi
  pass "the presentation cursor advances only through its captured endpoint"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

test_trailing_open_key_closes_only_when_answered() {
  local dir state out
  dir=$(make_case trailing-open-key)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision: choose the favicon route [key=favicon]\n' > "$state/trailing.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a trailing opening key"
  grep -Fx 'trailing [key=favicon] needs-decision: choose the favicon route' "$out" >/dev/null \
    || fail "an unanswered trailing-key decision was not reported under its explicit key"

  printf 'resolved [key=unrelated]: answered a different question\n' >> "$state/trailing.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated answer"
  grep -F 'trailing [key=favicon]' "$out" >/dev/null \
    || fail "an unrelated keyed answer closed the trailing-key decision"

  printf 'resolved: chose the geometric mark [key=favicon]\n' >> "$state/trailing.status"
  printf 'resolved [key=favicon]: repeated in canonical form\n' >> "$state/trailing.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after resolving a trailing opening key"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an answered trailing-key decision stayed open: $(cat "$out")"
  fi
  pass "a trailing opening key stays visible until its matching answer"
}

test_independent_trailing_openings_never_collide_in_default() {
  local dir state out
  dir=$(make_case independent-trailing-openings)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision: choose the asset source [key=source]\n' > "$state/independent.status"
  printf 'needs-decision: choose the rollout cadence [key=rollout]\n' >> "$state/independent.status"
  printf 'resolved: unrelated legacy default answer\n' >> "$state/independent.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on independent trailing openings"
  grep -F 'independent [key=source]' "$out" >/dev/null \
    || fail "a bare default resolution masked the first trailing-key decision"
  grep -F 'independent [key=rollout]' "$out" >/dev/null \
    || fail "a bare default resolution masked the second trailing-key decision"
  if grep -F 'independent needs-decision:' "$out" >/dev/null; then
    fail "independent trailing-key decisions collided in the default bucket"
  fi

  printf 'resolved [key=source]: use the local asset\n' >> "$state/independent.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after answering one independent decision"
  if grep -F 'independent [key=source]' "$out" >/dev/null; then
    fail "the answered independent decision stayed visible"
  fi
  grep -F 'independent [key=rollout]' "$out" >/dev/null \
    || fail "answering one independent decision masked the other"
  pass "independent trailing-key decisions never collide in the default bucket"
}

test_colon_first_key_shape_opens_and_closes_by_its_key() {
  local dir state out
  dir=$(make_case colon-first)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision: [key=parser-policy] choose the parser policy\n' > "$state/colon-first.status"
  printf 'resolved [key=unrelated]: answered another question\n' >> "$state/colon-first.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on the colon-first shape"
  grep -F 'colon-first [key=parser-policy] needs-decision: choose the parser policy' "$out" >/dev/null \
    || fail "a colon-first opening did not retain its explicit key and normalized note"

  printf 'resolved [key=parser-policy]: use the narrow parser policy\n' >> "$state/colon-first.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after resolving a colon-first opening"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an answered colon-first decision stayed open: $(cat "$out")"
  fi
  pass "a colon-first opening stays visible under its key until matching resolution"
}

test_bracket_metadata_before_colon_preserves_the_status_verb() {
  local dir state out
  dir=$(make_case bracket-metadata)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [corr=request-7] [route=parent] [key=metadata]: choose the route\n' > "$state/metadata.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on bracket metadata"
  grep -F 'metadata [key=metadata] needs-decision: choose the route' "$out" >/dev/null \
    || fail "bracket metadata before the colon defeated status-verb recovery"

  printf 'resolved [corr=request-7] [key=metadata]: route selected\n' >> "$state/metadata.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after resolving a metadata-tagged opening"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "a metadata-tagged decision stayed open after matching resolution"
  fi
  pass "bracket metadata before the colon does not defeat status-verb recovery"
}

test_trailing_multi_key_open_closes_each_key_independently() {
  local dir state out
  dir=$(make_case trailing-multi-key)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision: choose the source and rollout [key=source] [key=rollout]\n' > "$state/multi.status"
  printf 'resolved [key=source]: use the local asset\n' >> "$state/multi.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a partially answered multi-key decision"
  grep -F 'multi [key=rollout] needs-decision: choose the source and rollout' "$out" >/dev/null \
    || fail "the unanswered key from a multi-key opening did not remain visible"
  if grep -F 'multi [key=source]' "$out" >/dev/null; then
    fail "the answered key from a multi-key opening stayed visible"
  fi

  printf 'resolved [key=rollout]: stage the rollout\n' >> "$state/multi.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after both multi-key answers"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "a fully answered multi-key opening stayed open: $(cat "$out")"
  fi
  pass "each trailing multi-key opening remains visible until separately answered"
}

test_malformed_opening_key_still_surfaces_the_decision() {
  local dir state out
  dir=$(make_case malformed-key)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision: [key=bad key] choose A or B\n' > "$state/colonfirst.status"
  printf 'needs-decision [key=bad key]: choose C or D\n' > "$state/prefix.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a malformed opening key"
  grep -F 'colonfirst needs-decision: [key=bad key] choose A or B' "$out" >/dev/null \
    || fail "a malformed colon-first key hid an unanswered decision"
  grep -F 'prefix needs-decision: choose C or D' "$out" >/dev/null \
    || fail "a malformed prefix key hid an unanswered decision"

  printf 'resolved: picked A\n' >> "$state/colonfirst.status"
  printf 'resolved: picked C\n' >> "$state/prefix.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after default resolutions"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "a malformed-key decision stayed open after its default resolution: $(cat "$out")"
  fi
  pass "a malformed opening key keeps its decision visible under the default bucket"
}

test_buried_decision_still_surfaces
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_no_open_decisions_prints_nothing
test_unread_informational_lines_surface_once
test_buried_pending_reply_resolution_surfaces_and_closes
test_presentation_cursor_stops_at_captured_endpoint
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
test_trailing_open_key_closes_only_when_answered
test_independent_trailing_openings_never_collide_in_default
test_colon_first_key_shape_opens_and_closes_by_its_key
test_bracket_metadata_before_colon_preserves_the_status_verb
test_trailing_multi_key_open_closes_each_key_independently
test_malformed_opening_key_still_surfaces_the_decision
