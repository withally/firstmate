#!/usr/bin/env bash
# End-to-end regression coverage for unread-once status presentation.
# The cases preserve upstream #2331's line identities while proving this fork's
# version-5 OPEN DECISIONS cursor migrates without replaying historical bytes.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
CLASSIFY="$ROOT/bin/fm-classify-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-unread-status-tests)

prime_cursor() {  # <state> <status-file>
  local state=$1 status_file=$2
  printf 'note: bootstrap cursor line\n' > "$status_file"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "bootstrap drain failed while priming the presentation cursor"
}

test_buried_notes_surface_once() {
  local dir state out status_file
  dir=$(make_case buried-notes)
  state="$dir/state"
  out="$dir/out"
  status_file="$state/task.status"
  prime_cursor "$state" "$status_file"

  printf 'note: captain said use REST not RPC\n' >> "$status_file"
  printf 'note: re-read acknowledgement\n' >> "$status_file"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed on buried notes"
  grep -F 'task note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the earlier unread note was dropped: $(cat "$out")"
  grep -F 'task note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the latest unread note was dropped: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "second drain failed after presenting notes"
  if grep -F 'captain said use REST not RPC' "$out" >/dev/null \
    || grep -F 're-read acknowledgement' "$out" >/dev/null; then
    fail "an already-presented note replayed: $(cat "$out")"
  fi
  pass "buried note identities surface once"
}

test_signal_annotations_preserve_unread_identities_and_cap() {
  local dir state out status_file
  dir=$(make_case signal-annotations)
  state="$dir/state"
  out="$dir/out"
  status_file="$state/task.status"
  prime_cursor "$state" "$status_file"

  printf 'note: earlier unread answer\n' >> "$status_file"
  printf 'note: newest unread answer\n' >> "$status_file"
  append_wake "$state" signal task.status "signal: copied corpus" \
    || fail "queueing the status signal failed"
  FM_STATE_OVERRIDE="$state" FM_WAKE_ANNOTATION_LIMIT=1 "$DRAIN" > "$out" \
    || fail "signal drain failed"

  grep -F '1 earlier unread wake-EVENT annotation line(s) omitted' "$out" >/dev/null \
    || fail "the existing annotation cap did not report its omitted line"
  grep -F 'latest wake-EVENT observed at drain, not current state: task.status: note: newest unread answer' "$out" >/dev/null \
    || fail "the capped annotation lost the latest unread identity: $(cat "$out")"
  grep -F 'task note: earlier unread answer' "$out" >/dev/null \
    || fail "the lossless unread surface dropped the capped annotation identity"
  grep -F 'task note: newest unread answer' "$out" >/dev/null \
    || fail "the lossless unread surface dropped the newest identity"
  pass "signal annotations retain the fork cap without dropping unread status identities"
}

test_pending_reply_resolution_surfaces_once() {
  local dir state out status_file key
  dir=$(make_case pending-reply)
  state="$dir/state"
  out="$dir/out"
  status_file="$state/task.status"
  key=pending-reply-abcdef0123456789
  prime_cursor "$state" "$status_file"

  printf 'blocked [key=%s]: pending-reply-missed: request=ship-it\n' "$key" >> "$status_file"
  append_wake "$state" signal task.status "signal: pending reply" \
    || fail "queueing the pending-reply opening failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "opening drain failed"
  printf 'resolved [key=%s]: pending-reply-resolved: via=status\n' "$key" >> "$status_file"
  printf 'note: later acknowledgement\n' >> "$status_file"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "resolution drain failed"
  grep -F 'pending-reply-resolved: via=status' "$out" >/dev/null \
    || fail "the buried pending-reply resolution was dropped: $(cat "$out")"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the pending-reply resolution changed OPEN DECISIONS behavior"
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "second resolution drain failed"
  if grep -F 'pending-reply-resolved:' "$out" >/dev/null; then
    fail "the pending-reply resolution replayed"
  fi
  pass "pending-reply resolution identity surfaces once and closes its decision"
}

test_existing_decision_cursor_bounds_first_presentation() {
  local dir state out status_file payload i=1 bytes
  dir=$(make_case migrated-cursor)
  state="$dir/state"
  out="$dir/out"
  status_file="$state/task.status"
  payload=$(printf '%0110d' 0)
  while [ "$i" -le 1200 ]; do
    printf 'note: historical status %04d %s\n' "$i" "$payload" >> "$status_file"
    i=$((i + 1))
  done
  STATE="$state" CLASSIFY="$CLASSIFY" bash -c \
    '. "$CLASSIFY"; scan_open_decisions_incremental "$STATE" >/dev/null' \
    || fail "priming the existing decision cursor failed"
  printf 'working: no new presentation on this later-sorting task\n' > "$state/z-last.status"
  STATE="$state" CLASSIFY="$CLASSIFY" bash -c \
    '. "$CLASSIFY"; status_open_decisions_incremental "$STATE/z-last.status" >/dev/null' \
    || fail "priming the later task cursor failed"
  printf 'note: one newly appended signal line\n' >> "$status_file"
  append_wake "$state" signal task.status "signal: copied corpus" \
    || fail "queueing the representative signal failed"

  FM_STATE_OVERRIDE="$state" FM_WAKE_ANNOTATION_LIMIT=1 "$DRAIN" > "$out" \
    || fail "first migrated presentation failed"
  grep -F 'note: one newly appended signal line' "$out" >/dev/null \
    || fail "the post-cursor note was not presented"
  grep -F 'UNREAD STATUS (new since last drain' "$out" >/dev/null \
    || fail "a later task with no unread span suppressed the fleet unread section"
  grep -F 'task note: one newly appended signal line' "$out" >/dev/null \
    || fail "the fleet unread section lost the post-cursor note identity"
  if grep -F 'note: historical status' "$out" >/dev/null; then
    fail "the first presentation replayed decision-cursor history"
  fi
  bytes=$(LC_ALL=C wc -c < "$out" | tr -d '[:space:]')
  [ "$bytes" -lt 4096 ] \
    || fail "one new line produced a $bytes-byte presentation instead of bounded output"

  FM_STATE_OVERRIDE="$state" FM_WAKE_ANNOTATION_LIMIT=1 "$DRAIN" > "$out" \
    || fail "warm migrated presentation failed"
  if grep -F 'one newly appended signal line' "$out" >/dev/null; then
    fail "the migrated presentation cursor replayed the new line"
  fi
  pass "the existing decision cursor bounds first presentation to appended bytes"
}

test_invalid_decision_cursor_cannot_hide_history() {
  local dir state out status_file cursor
  dir=$(make_case invalid-migration)
  state="$dir/state"
  out="$dir/out"
  status_file="$state/task.status"
  cursor="$state/.task.open-decisions-cursor"
  printf 'note: authoritative history\n' > "$status_file"
  printf 'version=5\noffset=999999\nident=0:0\ngeneration=0\nanchor=0:0\n' > "$cursor"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "invalid-cursor presentation failed"
  grep -F 'task note: authoritative history' "$out" >/dev/null \
    || fail "an invalid seed cursor hid authoritative history"
  pass "an invalid decision cursor falls back to byte zero"
}

test_buried_notes_surface_once
test_signal_annotations_preserve_unread_identities_and_cap
test_pending_reply_resolution_surfaces_once
test_existing_decision_cursor_bounds_first_presentation
test_invalid_decision_cursor_cannot_hide_history
