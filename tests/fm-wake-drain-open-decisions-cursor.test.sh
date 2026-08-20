#!/usr/bin/env bash
# End-to-end regression coverage for the incremental OPEN DECISIONS fold.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
CLASSIFY="$ROOT/bin/fm-classify-lib.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-cursor-tests)

append_filler() {  # <file> <count>
  local file=$1 count=$2 before after i=0
  before=$(LC_ALL=C wc -c < "$file" | tr -d '[:space:]')
  while [ "$i" -lt "$count" ]; do
    printf 'working: routine filler %04d\n' "$i" >> "$file"
    i=$((i + 1))
  done
  after=$(LC_ALL=C wc -c < "$file" | tr -d '[:space:]')
  printf '%s' "$((after - before))"
}

last_probe_bytes() {  # <probe> <status-file>
  grep -F "$(printf '%s\t' "$2")" "$1" 2>/dev/null | tail -1 | cut -f2
}

whole_scan() {  # <state>
  STATE=$1 CLASSIFY=$CLASSIFY bash -c '. "$CLASSIFY"; scan_open_decisions "$STATE"'
}

whole_file_fold() {  # <status-file>
  STATUS=$1 CLASSIFY=$CLASSIFY bash -c '. "$CLASSIFY"; status_open_decisions "$STATUS"'
}

snapshot_scan() {  # <state>
  STATE=$1 CLASSIFY=$CLASSIFY bash -c '
    . "$CLASSIFY"
    snapshot=$(status_presentation_snapshot "$STATE") || exit 1
    scan_open_decisions_snapshot "$STATE" "$snapshot"
  '
}

assert_equivalent() {  # <state> <context>
  local state=$1 context=$2 whole incremental
  whole=$(whole_scan "$state") || fail "$context: whole-history scan failed"
  incremental=$(snapshot_scan "$state") || fail "$context: snapshot scan failed"
  [ "$incremental" = "$whole" ] \
    || fail "$context: incremental set differed from whole history: incremental=[$incremental] whole=[$whole]"
}

test_warm_scan_reads_only_new_bytes_and_preserves_identity_set() {
  local dir state status probe out appended read_bytes round
  dir=$(make_case warm-cost)
  state="$dir/state"
  status="$state/task.status"
  probe="$dir/probe"
  out="$dir/out"
  printf 'needs-decision [key=first]: choose one\n' > "$status"
  printf 'blocked: default blocker\n' >> "$status"
  append_filler "$status" 300 >/dev/null

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "cold cursor drain failed"
  assert_equivalent "$state" "cold fold"

  for round in 1 2 3; do
    appended=$(append_filler "$status" 4)
    FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
      || fail "warm cursor drain $round failed"
    read_bytes=$(last_probe_bytes "$probe" "$status")
    [ "$read_bytes" = "$appended" ] \
      || fail "warm drain $round read $read_bytes bytes instead of the $appended newly appended bytes"
    assert_equivalent "$state" "warm fold $round"
  done

  printf 'resolved [key=first]: chose one\n' >> "$status"
  printf 'resolved: blocker cleared\n' >> "$status"
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "resolution cursor drain failed"
  assert_equivalent "$state" "resolved fold"
  [ -z "$(whole_scan "$state")" ] || fail "resolved keys remained open"
  pass "warm scans read only appended bytes and remain identity-equivalent to the whole-history fold"
}

test_invalidation_refolds_truncation_replacement_and_malformed_cursor() {
  local dir state status cursor probe out bytes read_bytes replacement old_size
  dir=$(make_case invalidation)
  state="$dir/state"
  status="$state/task.status"
  cursor="$state/.task.open-decisions-cursor"
  probe="$dir/probe"
  out="$dir/out"
  printf 'needs-decision [key=old]: old choice\n' > "$status"
  append_filler "$status" 80 >/dev/null
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "invalidation bootstrap failed"

  printf 'blocked [key=truncated]: rewritten smaller\n' > "$status"
  bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "truncation refold failed"
  read_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$read_bytes" = "$bytes" ] || fail "truncation did not refold all $bytes bytes"
  assert_equivalent "$state" "truncation"

  old_size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  replacement="$dir/replacement"
  printf 'needs-decision [key=replaced]: replacement choice\n' > "$replacement"
  while [ "$(LC_ALL=C wc -c < "$replacement" | tr -d '[:space:]')" -lt "$old_size" ]; do
    printf ' ' >> "$replacement"
  done
  mv "$replacement" "$status"
  bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "replacement refold failed"
  read_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$read_bytes" = "$bytes" ] || fail "replacement did not refold all $bytes bytes"
  assert_equivalent "$state" "replacement"

  printf 'not-a-cursor\n' > "$cursor"
  : > "$probe"
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "malformed cursor refold failed"
  read_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$read_bytes" = "$bytes" ] || fail "malformed cursor did not refold all $bytes bytes"
  assert_equivalent "$state" "malformed cursor"
  pass "truncation, replacement, and malformed cursors rebuild from authoritative history"
}

test_partial_append_is_visible_but_not_committed_until_complete() {
  local dir state status cursor first second offset
  dir=$(make_case partial-append)
  state="$dir/state"
  status="$state/task.status"
  cursor="$state/.task.open-decisions-cursor"
  printf 'needs-decision [key=partial]: choose' > "$status"

  first=$(snapshot_scan "$state") || fail "partial first scan failed"
  [ "$first" = $'task\tpartial\tneeds-decision\tchoose' ] \
    || fail "partial opening did not match whole-history output: $first"
  assert_equivalent "$state" "partial opening"
  offset=$(sed -n 's/^offset=//p' "$cursor")
  [ "$offset" = 0 ] || fail "partial line advanced the committed cursor to $offset"

  printf ' between A and B\nworking: unrelated\n' >> "$status"
  second=$(snapshot_scan "$state") || fail "completed partial scan failed"
  [ "$second" = $'task\tpartial\tneeds-decision\tchoose between A and B' ] \
    || fail "continued line was split or changed: $second"
  assert_equivalent "$state" "completed partial opening"
  pass "an interrupted append matches whole history before and after its line is completed"
}

test_reused_identity_cannot_trust_a_stale_offset() {
  local dir state status cursor out current_ident current_generation bytes probe read_bytes
  dir=$(make_case reused-identity)
  state="$dir/state"
  status="$state/task.status"
  cursor="$state/.task.open-decisions-cursor"
  out="$dir/out"
  probe="$dir/probe"
  printf 'needs-decision [key=stale]: stale choice with a long original prefix\n' > "$status"
  append_filler "$status" 30 >/dev/null
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "reuse bootstrap failed"

  printf 'blocked [key=fresh]: fresh replacement with different bytes\n' > "$dir/replacement"
  append_filler "$dir/replacement" 35 >/dev/null
  mv "$dir/replacement" "$status"
  current_ident=$(STATE="$state" CLASSIFY="$CLASSIFY" bash -c '. "$CLASSIFY"; _fm_status_file_ident "$STATE/task.status"')
  current_generation=$(STATE="$state" CLASSIFY="$CLASSIFY" bash -c '. "$CLASSIFY"; _fm_status_file_generation "$STATE/task.status"')
  sed -i.bak "s/^ident=.*/ident=$current_ident/; s/^generation=.*/generation=$current_generation/" "$cursor"
  bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  : > "$probe"
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "reused-identity refold failed"
  read_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$read_bytes" = "$bytes" ] || fail "reused identity trusted a stale offset instead of refolding $bytes bytes"
  grep -F '[key=fresh]' "$out" >/dev/null || fail "fresh replacement decision was hidden"
  ! grep -F '[key=stale]' "$out" >/dev/null || fail "stale decision survived identity reuse"
  assert_equivalent "$state" "reused identity"
  pass "a generation-and-anchor check rejects stale state even when device and inode appear reused"
}

test_cursor_and_span_read_failures_refold_without_mutating_trusted_state() {
  local dir state status cursor fakebin real_cat before after cursor_result whole reader
  dir=$(make_case read-failure)
  state="$dir/state"
  status="$state/task.status"
  cursor="$state/.task.open-decisions-cursor"
  fakebin="$dir/fakebin"
  real_cat=$(command -v cat)
  printf 'needs-decision [key=read]: authoritative choice\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" || fail "read-failure bootstrap failed"
  printf 'working: appended after cursor\n' >> "$status"

  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "$cursor" ]; then exit 1; fi
exec "$real_cat" "\$@"
SH
  chmod +x "$fakebin/cat"
  cursor_result=$(STATE="$state" CLASSIFY="$CLASSIFY" PATH="$fakebin:$PATH" bash -c \
    '. "$CLASSIFY"; status_open_decisions_incremental "$STATE/task.status"') \
    || fail "cursor read failure did not refold"
  whole=$(whole_file_fold "$status")
  [ "$cursor_result" = "$whole" ] || fail "cursor read failure differed from whole history"

  reader="$dir/fail-reader"
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$reader"
  before=$(LC_ALL=C cksum "$cursor")
  printf 'blocked [key=after-failure]: still authoritative\n' >> "$status"
  cursor_result=$(STATE="$state" CLASSIFY="$CLASSIFY" FM_STATUS_SPAN_READER="$reader" bash -c \
    '. "$CLASSIFY"; status_open_decisions_incremental "$STATE/task.status"') \
    || fail "span read failure did not use the full-refold fallback"
  after=$(LC_ALL=C cksum "$cursor")
  [ "$after" = "$before" ] || fail "failed span read mutated the cursor"
  whole=$(whole_file_fold "$status")
  [ "$cursor_result" = "$whole" ] || fail "span read fallback differed from whole history"

  cursor_result=$(STATE="$state" CLASSIFY="$CLASSIFY" FM_STATUS_SIZE_READER="$reader" bash -c \
    '. "$CLASSIFY"; status_open_decisions_incremental "$STATE/task.status"') \
    || fail "size read failure did not use the full-refold fallback"
  after=$(LC_ALL=C cksum "$cursor")
  [ "$after" = "$before" ] || fail "failed size read mutated the cursor"
  whole=$(whole_file_fold "$status")
  [ "$cursor_result" = "$whole" ] || fail "size read fallback differed from whole history"
  pass "cursor-cache and incremental-span read failures use the authoritative full fold safely"
}

test_snapshot_is_the_only_fleet_inventory_and_retirement_removes_cursor() {
  local dir state snapshot first second cursor stale_snapshot before replacement
  dir=$(make_case snapshot-retire)
  state="$dir/state"
  printf 'needs-decision [key=first]: first\n' > "$state/first.status"
  snapshot=$(STATE="$state" CLASSIFY="$CLASSIFY" bash -c '. "$CLASSIFY"; status_presentation_snapshot "$STATE"') \
    || fail "snapshot capture failed"
  printf 'blocked [key=late]: late\n' > "$state/late.status"
  first=$(STATE="$state" SNAPSHOT="$snapshot" CLASSIFY="$CLASSIFY" bash -c \
    '. "$CLASSIFY"; scan_open_decisions_snapshot "$STATE" "$SNAPSHOT"') \
    || fail "snapshot-bound scan failed"
  case "$first" in *$'first\tfirst\tneeds-decision\tfirst'*) ;; *) fail "captured file was omitted" ;; esac
  case "$first" in *$'late\t'*) fail "decision scan walked the directory again and included a post-snapshot file" ;; esac
  second=$(snapshot_scan "$state") || fail "next snapshot scan failed"
  case "$second" in *$'late\tlate\tblocked\tlate'*) ;; *) fail "next snapshot did not include the late file" ;; esac

  cursor="$state/.first.open-decisions-cursor"
  [ -f "$cursor" ] || fail "snapshot scan did not create the owning cursor"
  stale_snapshot=$(STATE="$state" CLASSIFY="$CLASSIFY" bash -c '. "$CLASSIFY"; status_presentation_snapshot "$STATE"') \
    || fail "stale snapshot capture failed"
  before=$(LC_ALL=C cksum "$cursor")
  replacement="$dir/first-replacement"
  printf 'needs-decision [key=replaced]: replacement\n' > "$replacement"
  mv "$replacement" "$state/first.status"
  if STATE="$state" SNAPSHOT="$stale_snapshot" CLASSIFY="$CLASSIFY" bash -c \
    '. "$CLASSIFY"; scan_open_decisions_snapshot "$STATE" "$SNAPSHOT"' >/dev/null; then
    fail "a post-snapshot replacement was accepted under stale identity"
  fi
  [ "$(LC_ALL=C cksum "$cursor")" = "$before" ] \
    || fail "a stale snapshot mutated the decision cursor"

  STATE="$state" CLASSIFY="$CLASSIFY" WAKE_LIB="$WAKE_LIB" bash -c \
    '. "$WAKE_LIB"; . "$CLASSIFY"; status_retire_presentation_task "$STATE" first' \
    || fail "status retirement failed"
  [ ! -e "$state/first.status" ] || fail "retirement left the status log"
  [ ! -e "$cursor" ] || fail "retirement left the open-decision cursor"
  pass "the drain inventory comes from one snapshot and retirement removes its cursor with the status log"
}

test_warm_scan_reads_only_new_bytes_and_preserves_identity_set
test_invalidation_refolds_truncation_replacement_and_malformed_cursor
test_partial_append_is_visible_but_not_committed_until_complete
test_reused_identity_cannot_trust_a_stale_offset
test_cursor_and_span_read_failures_refold_without_mutating_trusted_state
test_snapshot_is_the_only_fleet_inventory_and_retirement_removes_cursor
