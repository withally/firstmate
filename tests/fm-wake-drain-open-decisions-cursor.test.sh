#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions-cursor.test.sh - end-to-end behavior tests
# for the incremental, cursor-backed OPEN DECISIONS scan
# (fm-classify-lib.sh's status_open_decisions_incremental /
# scan_open_decisions_incremental, wired into bin/fm-wake-drain.sh). These drive
# the REAL drain script across MANY successive invocations over a status log
# that keeps growing, and assert both the printed output and a bounded-cost
# property, not the fold's own source text. tests/fm-wake-drain-open-decisions.test.sh
# already covers the fold's single-drain correctness; this file covers the
# cursor's cross-drain persistence and cost bound.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# shellcheck source=tests/cutover-state-fixture-helpers.sh
. "$ROOT/tests/cutover-state-fixture-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
CLASSIFY="$ROOT/bin/fm-classify-lib.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-cursor-tests)

# Append <count> harmless filler lines (routine working: notes, never a
# needs-decision/blocked/resolved verb) to <file> and print the exact number of
# bytes appended, so a test can assert the read-probe's byte count against a
# known ground truth rather than an approximation.
append_filler() {  # <file> <count>
  local file=$1 count=$2 i=0 before after
  before=$(LC_ALL=C wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  [ -n "$before" ] || before=0
  while [ "$i" -lt "$count" ]; do
    printf 'working: routine filler padding line %04d of growing status log\n' "$i" >> "$file"
    i=$((i + 1))
  done
  after=$(LC_ALL=C wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  printf '%s\n' "$((after - before))"
}

# The byte count the read-probe recorded for <file> on its MOST RECENT
# incremental fold call (last matching line in the probe log).
last_probe_bytes() {  # <probe-file> <status-file>
  grep -F "$(printf '%s\t' "$2")" "$1" 2>/dev/null | tail -1 | cut -f2
}

snapshot_scan() {  # <state>
  STATE=$1 CLASSIFY=$CLASSIFY bash -c '
    . "$CLASSIFY"
    snapshot=$(status_presentation_snapshot "$STATE") || exit 1
    scan_open_decisions_snapshot "$STATE" "$snapshot"
  '
}

whole_scan() {  # <state>
  STATE=$1 CLASSIFY=$CLASSIFY bash -c '. "$CLASSIFY"; scan_open_decisions "$STATE"'
}

whole_file_fold() {  # <status-file>
  STATUS=$1 CLASSIFY=$CLASSIFY bash -c '. "$CLASSIFY"; status_open_decisions "$STATUS"'
}

assert_equivalent() {  # <state> <context>
  local state=$1 context=$2 whole incremental
  whole=$(whole_scan "$state") || fail "$context: whole-history scan failed"
  incremental=$(snapshot_scan "$state") || fail "$context: snapshot scan failed"
  [ "$incremental" = "$whole" ] \
    || fail "$context: incremental set differed from whole history: incremental=[$incremental] whole=[$whole]"
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
  current_ident=$(STATE="$state" CLASSIFY="$CLASSIFY" bash -c '. "$CLASSIFY"; _fm_open_decisions_file_ident "$STATE/task.status"')
  current_generation=$(STATE="$state" CLASSIFY="$CLASSIFY" bash -c '. "$CLASSIFY"; _fm_open_decisions_file_generation "$STATE/task.status"')
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
  dir=$(make_case read-failure-safety)
  state="$dir/state"
  status="$state/task.status"
  cursor="$state/.task.open-decisions-cursor"
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
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

test_copied_version_5_cursors_import_across_home_shapes() {
  local dir fixture state task key status out probe appended read_bytes spec
  dir=$(make_case copied-version-5-home-shapes)
  for spec in \
    'main-home|main-home/state|main-copy|main-choice' \
    'local-secondmate|local-secondmate-home/state|local-copy|local-choice' \
    'remote-home|remote-host/fm-homes/remote-copy/state|remote-copy|remote-choice'; do
    IFS='|' read -r fixture state task key <<EOF
$spec
EOF
    state="$dir/$state"
    status="$state/$task.status"
    out="$dir/$task.out"
    probe="$dir/$task.probe"
    fm_cutover_render_fixture "$fixture" "$state" "$task"
    : > "$probe"
    appended=$(printf 'working: %s post-copy append\n' "$fixture" | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
    FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
      || fail "$fixture version-5 cursor import drain failed"
    grep -F "$task [key=$key]" "$out" >/dev/null \
      || fail "$fixture version-5 cursor import hid its copied open decision: $(cat "$out")"
    read_bytes=$(last_probe_bytes "$probe" "$status")
    [ "$read_bytes" = "$appended" ] \
      || fail "$fixture version-5 cursor refolded $read_bytes bytes instead of only its $appended-byte append"
    grep -F 'version=6' "$state/.$task.open-decisions-cursor" >/dev/null \
      || fail "$fixture version-5 cursor was not imported into the current schema"
  done
  pass "copied version-5 open-decision cursors import across main, local-secondmate, and remote-home shapes"
}

test_buried_decision_survives_many_growing_drains_and_resolution_clears_it() {
  local dir state out probe status bootstrap_bytes total_size round increment_bytes probe_bytes
  dir=$(make_case cursor-lifecycle)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task1.status"
  : > "$probe"

  # Open a keyed decision, buried under an initial filler round big enough to
  # make a full-file rescan cost visibly more than a small incremental one.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$status"
  append_filler "$status" 400 >/dev/null

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "first drain over a large buried decision failed"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "the buried decision did not surface on the bootstrap drain"
  bootstrap_bytes=$(last_probe_bytes "$probe" "$status")
  [ -n "$bootstrap_bytes" ] && [ "$bootstrap_bytes" -gt 0 ] \
    || fail "the bootstrap drain recorded no incremental read at all"

  # Many further drains, each appending only a SMALL increment while the total
  # log keeps growing large. The buried decision must resurface on EVERY one of
  # them (never dropped just because it is old or buried under more appends),
  # and each drain's read-probe byte count must match ONLY that round's small
  # increment - never the ever-growing total file size - proving the read cost
  # is bounded by new appends, not by total log size.
  for round in 1 2 3 4 5; do
    increment_bytes=$(append_filler "$status" 20)
    FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
      || fail "drain $round over a growing log failed"
    grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
      || fail "the buried decision was dropped on growth round $round"
    probe_bytes=$(last_probe_bytes "$probe" "$status")
    [ "$probe_bytes" = "$increment_bytes" ] \
      || fail "round $round read $probe_bytes bytes, expected exactly this round's $increment_bytes-byte increment (cost is not bounded)"
  done
  total_size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  [ "$total_size" -gt "$bootstrap_bytes" ] \
    || fail "test setup error: the log never grew past its bootstrap size"

  # Now resolve it. The very next drain's own read (a small increment) must
  # clear it - not by rescanning the whole now-large file, but by folding the
  # small resolved line into the still-persisted open set.
  increment_bytes=$(printf 'resolved [key=api-shape]: went with REST\n' | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "resolution drain failed"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the resolved decision still printed as open right after resolution: $(cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$increment_bytes" ] \
    || fail "the resolution drain read $probe_bytes bytes, expected exactly the $increment_bytes-byte resolved line (cost is not bounded)"

  # Grow the log again after resolution: the decision must stay cleared (a
  # closed decision is not resurrected by unrelated later growth), and the read
  # cost for this final round must still be bounded to that round's increment.
  increment_bytes=$(append_filler "$status" 20)
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-resolution growth drain failed"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "a resolved decision reappeared after later unrelated growth: $(cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$increment_bytes" ] \
    || fail "the post-resolution drain read $probe_bytes bytes, expected exactly the $increment_bytes-byte increment (cost is not bounded)"

  pass "a buried decision survives many growing drains with bounded read cost, and resolution durably clears it at bounded cost too"
}

test_truncated_log_falls_back_to_a_full_refold_not_a_dropped_decision() {
  local dir state out probe status rewritten_bytes probe_bytes
  dir=$(make_case cursor-truncation)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task2.status"
  : > "$probe"

  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$status"
  append_filler "$status" 100 >/dev/null
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "initial drain before truncation failed"
  grep -F 'task2' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "the decision did not surface before truncation"

  # Simulate a rewritten/truncated log (shrunk below the persisted cursor
  # offset): the decision is re-opened by a fresh needs-decision line in the
  # rewritten content, and the incremental scan must fall back to a full
  # re-fold of the new, smaller file rather than trusting a now-invalid cursor.
  printf 'needs-decision [key=migration]: rewritten after truncation\n' > "$status"
  rewritten_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-truncation drain failed"
  grep -F 'task2' "$out" | grep -F '[key=migration]' | grep -F 'rewritten after truncation' >/dev/null \
    || fail "the rewritten decision after truncation did not surface"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$rewritten_bytes" ] \
    || fail "post-truncation drain read $probe_bytes bytes, expected a full re-fold of the $rewritten_bytes-byte rewritten file"

  pass "a truncated/rewritten log falls back to a full re-fold instead of dropping or misreading the decision"
}

test_same_size_rewrite_is_detected_via_inode_identity() {
  local dir state out probe status new_bytes probe_bytes
  dir=$(make_case cursor-rotation)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task3.status"
  : > "$probe"

  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$status"
  append_filler "$status" 100 >/dev/null
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "initial drain before rotation failed"
  grep -F 'task3' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "the decision did not surface before rotation"

  # Replace the file at the same path with a DIFFERENT file of the SAME byte
  # size (mv gives the destination path a new inode) - a same-size rewrite,
  # which a plain offset>size shrink check alone would NOT catch. The buried
  # decision must still surface: the device+inode identity check must detect
  # this as a rotation/recreation and fall back to a full re-fold.
  new_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  printf 'needs-decision [key=migration]: rewritten via rotation\n' > "$dir/replacement"
  padded=$(LC_ALL=C wc -c < "$dir/replacement" | tr -d '[:space:]')
  pad=$((new_bytes - padded))
  [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero | tr '\0' 'x' >> "$dir/replacement"
  mv "$dir/replacement" "$status"
  [ "$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')" = "$new_bytes" ] \
    || fail "test setup error: the rotated replacement is not the same size as the original"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-rotation drain failed"
  grep -F 'task3' "$out" | grep -F '[key=migration]' | grep -F 'rewritten via rotation' >/dev/null \
    || fail "the same-size rotated file's decision did not surface (inode-identity check did not fire)"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$new_bytes" ] \
    || fail "post-rotation drain read $probe_bytes bytes, expected a full re-fold of the $new_bytes-byte replacement"

  pass "a same-size file rotation (new inode) is detected and falls back to a full re-fold"
}

test_read_failure_preserves_state_for_retry() {
  local dir state reader statusfile cursor out before_cursor after_cursor
  dir=$(make_case cursor-read-failure)
  state="$dir/state"
  reader="$dir/fail-reader"
  statusfile="$state/task4.status"
  cursor="$state/.task4.open-decisions-cursor"
  out="$dir/drain.out"

  printf 'needs-decision [key=x]: something important\n' > "$statusfile"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the injected read failure failed"
  grep -F 'task4' "$out" | grep -F '[key=x]' | grep -F 'something important' >/dev/null \
    || fail "the decision did not surface on the bootstrap drain"
  [ -s "$cursor" ] || fail "no cursor was persisted after the bootstrap drain"
  before_cursor=$(LC_ALL=C cksum "$cursor")

  printf 'working: more routine content\n' >> "$statusfile"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"
  chmod +x "$reader"

  FM_STATE_OVERRIDE="$state" FM_STATUS_SPAN_READER="$reader" "$DRAIN" > "$out" \
    || fail "wake drain failed instead of preserving state after the injected read failure"
  [ ! -s "$out" ] \
    || fail "the failed presentation read emitted a partial status presentation: $(command cat "$out")"
  after_cursor=$(LC_ALL=C cksum "$cursor")
  [ "$after_cursor" = "$before_cursor" ] \
    || fail "the failed read advanced or rewrote the persisted cursor"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake drain did not recover after the injected read failure"
  grep -F 'task4' "$out" | grep -F '[key=x]' | grep -F 'something important' >/dev/null \
    || fail "the open decision disappeared when presentation reads recovered: $(command cat "$out")"

  pass "a failed presentation read preserves status state for retry"
}

test_cursor_cache_read_failure_refolds_without_replaying_unread_status() {
  local dir state fakebin statusfile cursor out probe real_cat status_bytes probe_bytes
  dir=$(make_case cursor-cache-read-failure)
  state="$dir/state"
  fakebin="$dir/failbin"
  mkdir -p "$fakebin"
  statusfile="$state/task5.status"
  cursor="$state/.task5.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  real_cat=$(command -v cat)

  {
    printf 'needs-decision [key=cache]: recover from authoritative status\n'
    printf 'note: already handled informational status\n'
  } > "$statusfile"
  append_filler "$statusfile" 40 >/dev/null
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the cursor-cache read failure failed"
  grep -F 'task5' "$out" | grep -F '[key=cache]' | grep -F 'authoritative status' >/dev/null \
    || fail "the decision did not surface before the cursor-cache read failure"
  grep -F 'task5 note: already handled informational status' "$out" >/dev/null \
    || fail "the bootstrap drain did not surface the informational status"
  [ -s "$cursor" ] || fail "no cursor was persisted before the cursor-cache read failure"

  printf 'working: appended before cache failure\n' >> "$statusfile"
  status_bytes=$(LC_ALL=C wc -c < "$statusfile" | tr -d '[:space:]')
  : > "$probe"
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 1 ] && [ "\$1" = "$cursor" ]; then
  exit 1
fi
exec "$real_cat" "\$@"
SH
  chmod +x "$fakebin/cat"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" PATH="$fakebin:$PATH" "$DRAIN" > "$out" \
    || fail "wake drain failed instead of refolding after the cursor-cache read failure"
  grep -F 'task5' "$out" | grep -F '[key=cache]' | grep -F 'authoritative status' >/dev/null \
    || fail "the cursor-cache read failure hid the recurring open decision: $(command cat "$out")"
  if grep -F 'UNREAD STATUS' "$out" >/dev/null \
    || grep -F 'already handled informational status' "$out" >/dev/null; then
    fail "the cursor-cache read failure replayed handled informational status as new: $(command cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$statusfile")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the cursor-cache read failure read $probe_bytes bytes, expected a full $status_bytes-byte authoritative refold"

  pass "a cursor-cache read failure refolds decisions without replaying handled unread status"
}

test_pre_fix_cursor_refolds_corr_tagged_decision() {
  local dir state status cursor out probe status_bytes ident probe_bytes
  dir=$(make_case cursor-corr-tag-migration)
  state="$dir/state"
  status="$state/task7.status"
  cursor="$state/.task7.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"

  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain for the corr-tag cursor migration failed"
  ident=$(sed -n 's/^ident=//p' "$cursor")
  [ -n "$ident" ] || fail "bootstrap drain did not persist a file identity"
  status_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  {
    printf 'version=3\n'
    printf 'offset=%s\n' "$status_bytes"
    printf 'ident=%s\n' "$ident"
  } > "$cursor"
  : > "$probe"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "drain failed while migrating the pre-fix corr-tag cursor"
  grep -F 'task7 [key=loan-installment-cadence-amount] needs-decision: pick the cadence' "$out" >/dev/null \
    || fail "the pre-fix cursor hid the corr-tagged decision after migration: $(cat "$out")"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the pre-fix cursor read $probe_bytes bytes instead of refolding all $status_bytes authoritative bytes"

  pass "a pre-fix cursor is rebuilt so a previously skipped corr-tagged decision surfaces"
}

test_previous_fold_cache_is_refolded_under_current_semantics() {
  local dir state status cursor out probe status_bytes ident appended_bytes probe_bytes
  dir=$(make_case cursor-fold-version)
  state="$dir/state"
  status="$state/task6.status"
  cursor="$state/.task6.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"

  printf 'blocked [key=pending-reply-abcdef0123456789]: forged decision\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain for the fold-version migration failed"
  [ ! -s "$out" ] || fail "the current whole-file semantics accepted the foreign reserved-key decision: $(cat "$out")"
  ident=$(sed -n 's/^ident=//p' "$cursor")
  status_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  {
    printf 'offset=%s\n' "$status_bytes"
    printf 'ident=%s\n' "$ident"
    printf 'pending-reply-abcdef0123456789\tblocked\tforged decision'
  } > "$cursor"
  : > "$probe"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "drain failed while upgrading the previous fold cache"
  [ ! -s "$out" ] || fail "the previous fold cache kept surfacing a foreign reserved-key decision: $(cat "$out")"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the previous fold cache read $probe_bytes bytes instead of refolding all $status_bytes authoritative bytes"

  appended_bytes=$(printf 'needs-decision [key=current]: choose the current path\n' | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "same-version incremental drain failed after cache migration"
  grep -F 'task6 [key=current] needs-decision: choose the current path' "$out" >/dev/null \
    || fail "the same-version append did not fold into the migrated open set"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$appended_bytes" ] \
    || fail "the same-version fold read $probe_bytes bytes instead of only the $appended_bytes-byte append"

  pass "an old fold cache is rebuilt once before same-version incremental reads resume"
}

test_truncated_log_falls_back_to_a_full_refold_not_a_dropped_decision
test_same_size_rewrite_is_detected_via_inode_identity
test_read_failure_preserves_state_for_retry
test_cursor_cache_read_failure_refolds_without_replaying_unread_status
test_pre_fix_cursor_refolds_corr_tagged_decision
test_previous_fold_cache_is_refolded_under_current_semantics
test_buried_decision_survives_many_growing_drains_and_resolution_clears_it
test_partial_append_is_visible_but_not_committed_until_complete
test_reused_identity_cannot_trust_a_stale_offset
test_cursor_and_span_read_failures_refold_without_mutating_trusted_state
test_snapshot_is_the_only_fleet_inventory_and_retirement_removes_cursor
test_copied_version_5_cursors_import_across_home_shapes
