#!/usr/bin/env bash
# Canonical current and isolated legacy operational-input protocol matrices.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-operational-input.sh"
# shellcheck source=/dev/null
. "$OWNER"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

classify_cli() {
  printf '%s' "$1" | "$OWNER" classify 2>/dev/null
}

kind_cli() {
  printf '%s' "$1" | "$OWNER" kind 2>/dev/null
}

count_literal() {  # <text> <literal>
  local rest=$1 needle=$2 count=0
  while [ "${rest#*"$needle"}" != "$rest" ]; do
    rest=${rest#*"$needle"}
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

test_current_generic_matrix() {
  local kind body encoded parsed stripped prefix_hex reply_rule rule_count
  reply_rule='Handle FIRSTMATE_OP digests, doorbells, steers, and marked from-firstmate requests silently: reply only with the required status-file line, or nothing; never send captain-addressed chat, because "captain" is reserved for the main firstmate.'
  prefix_hex=$(printf '%s' "$FM_OPERATIONAL_PREFIX" | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a346495253544d4154455f4f503a20 ] \
    || fail "current operational prefix lost the landed U+2063 FIRSTMATE_OP bytes: $prefix_hex"

  for kind in session-start watcher turn-end-guard away-supervisor launch-brief branch-outcome; do
    body="CURRENT_BODY_FOR_${kind}"
    fm_operational_input_encode "$kind" "$body" encoded secondmate \
      || fail "could not encode current $kind fixture"
    fm_operational_input_kind "$encoded" parsed \
      || fail "could not parse current $kind fixture"
    [ "$parsed" = "$kind" ] \
      || fail "current $kind fixture became $parsed"
    [ "$(kind_cli "$encoded")" = "$kind" ] \
      || fail "cross-language CLI lost current $kind"
    [ "$(classify_cli "$encoded")" = "$kind" ] \
      || fail "classifier lost current $kind"
    rule_count=$(count_literal "$encoded" "$reply_rule")
    [ "$rule_count" = 1 ] \
      || fail "current $kind carrier must include the silent operational-input rule exactly once, found $rule_count"
    fm_operational_input_body "$encoded" stripped \
      || fail "could not recover current $kind body"
    [ "$stripped" = "$body" ] \
      || fail "current $kind body changed during encode/parse"
  done
  pass "operational input: every current generic envelope retains its exact structured kind"
}

test_main_recipient_preserves_captain_boundary() {
  local body encoded parsed stripped rule_count
  body='This outcome is captain-facing: give the captain a visible response now.'
  encoded=$(printf '%s' "$body" | "$OWNER" encode branch-outcome main) \
    || fail "main-bound branch outcome could not be encoded"
  fm_operational_input_kind "$encoded" parsed \
    || fail "main-bound branch outcome did not remain current operational input"
  [ "$parsed" = branch-outcome ] \
    || fail "main-bound branch outcome became $parsed"
  rule_count=$(count_literal "$encoded" "$FM_OPERATIONAL_SILENT_REPLY_RULE")
  [ "$rule_count" = 0 ] \
    || fail "main-bound branch outcome carried the worker-only silent rule"
  fm_operational_input_body "$encoded" stripped \
    || fail "main-bound branch outcome body could not be recovered"
  [ "$stripped" = "$body" ] \
    || fail "main-bound branch outcome body changed during encoding"
  pass "operational input: main-bound branch outcomes retain their visible-response instruction"
}

test_main_body_preserves_literal_carrier_suffix() {
  local body kind encoded stripped
  body="main-bound body${FM_OPERATIONAL_SILENT_REPLY_CARRIER}"
  for kind in watcher from-firstmate; do
    encoded=$(printf '%s' "$body" | "$OWNER" encode "$kind" main) \
      || fail "main-bound $kind body could not be encoded"
    stripped=$(printf '%s' "$encoded" | "$OWNER" body) \
      || fail "main-bound $kind body could not be parsed"
    [ "$stripped" = "$body" ] \
      || fail "main-bound $kind body lost its literal carrier suffix"
  done
  pass "operational input: main-bound bodies preserve a literal carrier-like suffix"
}

test_default_main_and_explicit_worker_carriers() {
  local body main_encoded mate_encoded main_count mate_count
  body='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
  main_encoded=$(printf '%s' "$body" | "$OWNER" encode session-start) \
    || fail "main-bound session-start nudge could not be encoded"
  mate_encoded=$(printf '%s' "$body" | "$OWNER" encode session-start secondmate) \
    || fail "secondmate session-start nudge could not be encoded"
  main_count=$(count_literal "$main_encoded" "$FM_OPERATIONAL_SILENT_REPLY_RULE")
  [ "$main_count" = 0 ] \
    || fail "main-bound session-start nudge carried the worker-only silent rule"
  mate_count=$(count_literal "$mate_encoded" "$FM_OPERATIONAL_SILENT_REPLY_RULE")
  [ "$mate_count" = 1 ] \
    || fail "secondmate session-start nudge must carry the silent rule exactly once, found $mate_count"
  pass "operational input: main-bound nudges stay captain-facing while explicit mate inputs carry silence"
}

test_current_from_firstmate_carrier() {
  local encoded parsed separator stripped reply_rule rule_count
  reply_rule='Handle FIRSTMATE_OP digests, doorbells, steers, and marked from-firstmate requests silently: reply only with the required status-file line, or nothing; never send captain-addressed chat, because "captain" is reserved for the main firstmate.'
  separator=$(printf '\342\201\243')
  fm_message_mark_from_firstmate "corr=0123456789abcdef inspect the report" encoded secondmate
  [ "${encoded#"[fm-from-firstmate]$separator"}" != "$encoded" ] \
    || fail "from-firstmate lost its live-charter-compatible leading carrier"
  fm_operational_input_kind "$encoded" parsed \
    || fail "from-firstmate current carrier did not parse"
  [ "$parsed" = from-firstmate ] \
    || fail "from-firstmate current carrier became $parsed"
  [ "$(classify_cli "$encoded")" = from-firstmate ] \
    || fail "cross-language classifier lost from-firstmate"
  rule_count=$(count_literal "$encoded" "$reply_rule")
  [ "$rule_count" = 1 ] \
    || fail "from-firstmate carrier must include the silent operational-input rule exactly once, found $rule_count"
  fm_operational_input_body "$encoded" stripped \
    || fail "could not recover the from-firstmate body"
  [ "$stripped" = 'corr=0123456789abcdef inspect the report' ] \
    || fail "from-firstmate body changed while carrying the silent reply rule"
  pass "operational input: the established from-firstmate carrier remains structurally typed and byte-compatible"
}

test_landed_untyped_prefix_is_explicitly_legacy() {
  local untyped parsed
  untyped="${FM_OPERATIONAL_PREFIX}body whose historical subtype is unknowable"
  fm_legacy_operational_input_kind "$untyped" parsed \
    || fail "landed untyped FIRSTMATE_OP input was not retained"
  [ "$parsed" = legacy-operational ] \
    || fail "landed untyped FIRSTMATE_OP input falsely became $parsed"
  ! fm_operational_input_kind "$untyped" parsed \
    || fail "untyped FIRSTMATE_OP input passed the current typed parser"
  [ "$(classify_cli "$untyped")" = legacy-operational ] \
    || fail "CLI did not expose the untyped prefix as legacy-operational"
  pass "operational input: untyped landed FIRSTMATE_OP transcripts are explicit legacy-operational input"
}

test_isolated_legacy_matrix() {
  local watcher turnend away parsed
  watcher="${FM_LEGACY_WATCHER_PREFIX}signal: legacy${FM_LEGACY_WATCHER_SUFFIX}"
  turnend="${FM_LEGACY_TURNEND_PREFIX}watcher: FAILED - legacy"
  away="${FM_LEGACY_AWAY_PREFIX}1 event(s)): done: legacy"

  for fixture in \
    "session-start|$FM_LEGACY_SESSIONSTART" \
    "watcher|$watcher" \
    "turn-end-guard|$turnend" \
    "away-supervisor|$away"
  do
    expected=${fixture%%|*}
    message=${fixture#*|}
    ! fm_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture leaked into the current parser"
    fm_legacy_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture was not recognized"
    [ "$parsed" = "$expected" ] \
      || fail "legacy $expected fixture became $parsed"
  done
  pass "operational input: historical prose compatibility is isolated from current parsing"
}

test_genuine_near_misses_remain_unclassified() {
  local marker fixture parsed
  marker=$FM_OPERATIONAL_MARK
  while IFS= read -r fixture || [ -n "$fixture" ]; do
    [ -n "$fixture" ] || continue
    ! fm_operational_input_classify "$fixture" parsed \
      || fail "genuine near miss was classified as $parsed: $fixture"
    [ -z "$(classify_cli "$fixture" || true)" ] \
      || fail "CLI classified a genuine near miss: $fixture"
  done <<EOF
Captain quote: ${FM_OPERATIONAL_PREFIX}v1 watcher
FIRSTMATE_OP: v1 watcher
$marker arbitrary captain text
Captain quote: $FM_LEGACY_SESSIONSTART
${FM_LEGACY_SESSIONSTART} Please explain this sentence.
FIRSTMATE WATCHER WAKE: can you explain this phrase?
TURN WOULD END BLIND - can you make this warning friendlier?
Supervisor escalate (1 event(s)): is this wording clear?
[fm-from-firstmate] inspect this visible label
EOF
  pass "operational input: quoted, ASCII-only, arbitrary-U+2063, altered-legacy, and label-only near misses stay genuine"
}

test_cross_language_adapter_uses_the_owner() {
  local encoded parsed
  encoded=$(FM_TEST_ROOT="$ROOT" HELPER="$ROOT/.opencode/plugins/lib/fm-operational-input.js" \
    node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
const { encodeFirstmateOperationalInput } = await import(pathToFileURL(process.env.HELPER).href);
process.stdout.write(await encodeFirstmateOperationalInput(process.env.FM_TEST_ROOT, "watcher", "CROSS_LANGUAGE_BODY"));
JS
  ) || fail "OpenCode cross-language adapter could not invoke the canonical owner"
  fm_operational_input_kind "$encoded" parsed \
    || fail "OpenCode cross-language adapter returned an invalid current envelope"
  [ "$parsed" = watcher ] \
    || fail "OpenCode cross-language adapter changed watcher to $parsed"
  pass "operational input: the OpenCode adapter constructs through the canonical owner"
}

test_invalid_current_encodings_are_rejected() {
  local output
  output=$(printf 'body' | "$OWNER" encode legacy-operational 2>/dev/null) \
    && fail "legacy-operational was accepted as a current producer kind"
  [ -z "$output" ] || fail "invalid current kind printed protocol data"
  output=$(printf '' | "$OWNER" encode watcher 2>/dev/null) \
    && fail "empty current operational body was accepted"
  [ -z "$output" ] || fail "empty current body printed protocol data"
  pass "operational input: current construction rejects legacy kinds and empty bodies"
}

test_current_generic_matrix
test_main_recipient_preserves_captain_boundary
test_main_body_preserves_literal_carrier_suffix
test_default_main_and_explicit_worker_carriers
test_current_from_firstmate_carrier
test_landed_untyped_prefix_is_explicitly_legacy
test_isolated_legacy_matrix
test_genuine_near_misses_remain_unclassified
test_cross_language_adapter_uses_the_owner
test_invalid_current_encodings_are_rejected
