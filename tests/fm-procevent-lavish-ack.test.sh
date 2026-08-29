#!/usr/bin/env bash
# Behavior tests for Lavish delivery acknowledgement through the real
# process-event capture path and a protocol-faithful fake lavish-axi.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-lavish-ack)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

FAKE_BIN=$(fm_fakebin "$TMP_ROOT/fake-bin")
cat > "$FAKE_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u

artifact=${2-}
delivery_id=
shift 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ack) delivery_id=${2-}; shift 2 ;;
    --timeout-ms) shift 2 ;;
    *) printf 'unexpected argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

if [ -n "$delivery_id" ]; then
  result=
  for candidate in "$FM_HOME/state/procevent-inbox/$LAVISH_SOURCE_ID".*.result; do
    [ -f "$candidate" ] || continue
    result=$candidate
    break
  done
  [ -n "$result" ] || { printf 'ack-before-capture\n' >> "$LAVISH_LOG"; exit 70; }
  [ -f "$FM_HOME/state/procevent/$LAVISH_SOURCE_ID.source" ] \
    || { printf 'retired-before-ack\n' >> "$LAVISH_LOG"; exit 71; }
  printf 'ack %s after %s\n' "$delivery_id" "${result##*/}" >> "$LAVISH_LOG"
  if [ "$LAVISH_SCENARIO" = ack-failure ]; then
    printf 'ack failed\n' >&2
    exit 72
  fi
  if [ "$LAVISH_SCENARIO" = final ] || [ "$LAVISH_SCENARIO" = bound-feed-failure ]; then
    printf 'session:\n  file: %s\n  status: ended\n  ended_by: user\n' "$artifact"
  else
    printf 'session:\n  file: %s\n  status: waiting\n' "$artifact"
  fi
  exit 0
fi

printf 'poll\n' >> "$LAVISH_LOG"
if [ "$LAVISH_SCENARIO" = legacy ]; then
  printf 'session:\n  file: %s\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n' "$artifact"
elif [ "$LAVISH_SCENARIO" = partial ]; then
  printf 'session:\n  file: %s\n  status: feedback\n  session_ended: true\n  ended_by: user\ndelivery_id: 0123456789abcdef\n' "$artifact"
  exit 73
elif [ "$LAVISH_SCENARIO" = partial-truncated ]; then
  printf 'session:\n  file: %s\n  status: feedback\n  session_ended: true\n  ended_by: user\ndelivery_id: 0123456789abcdef\n' "$artifact"
  printf 'x%.0s' {1..512}
  printf '\n'
  exit 73
elif [ "$LAVISH_SCENARIO" = bound-feed-failure ]; then
  printf 'session:\n  file: %s\n  status: feedback\n  session_ended: true\n  ended_by: user\n' "$artifact"
  cat <<'EOF'
delivery_id: 0123456789abcdef
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Missing task: yes\n\nContext data:\n{\n  \"question\": \"missing-bound-task\",\n  \"answer\": \"yes\"\n}","form",choice,"Missing task: yes"
EOF
else
  printf 'session:\n  file: %s\n  status: feedback\n' "$artifact"
  if [ "$LAVISH_SCENARIO" = final ] || [ "$LAVISH_SCENARIO" = ack-failure ]; then
    printf '  session_ended: true\n  ended_by: user\n'
  fi
  printf 'delivery_id: 0123456789abcdef\nfeedback[1]{text}:\n  ship it\n'
  if [ "$LAVISH_SCENARIO" = truncated ]; then
    printf 'x%.0s' {1..512}
    printf '\n'
  fi
fi
SH
chmod +x "$FAKE_BIN/lavish-axi"

run_scenario() {  # <scenario>
  local scenario=$1 home="$TMP_ROOT/$1-home" artifact="$TMP_ROOT/$1.html" id out
  mkdir -p "$home/state"
  printf '<h1>%s</h1>\n' "$scenario" > "$artifact"
  id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  LAVISH_SOURCE_ID=$id LAVISH_SCENARIO=$scenario LAVISH_LOG="$TMP_ROOT/$scenario.log" \
    PATH="$FAKE_BIN:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-procevent-lavish.sh" arm "$artifact" >/dev/null
  if [ "$scenario" = bound-feed-failure ]; then
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      "$ROOT/bin/fm-captain-hold.sh" bind "$id" >/dev/null
  fi
  out=$(LAVISH_SOURCE_ID=$id LAVISH_SCENARIO=$scenario LAVISH_LOG="$TMP_ROOT/$scenario.log" \
    PATH="$FAKE_BIN:$PATH" FM_HOME="$home" \
    FM_PROCEVENT_MAX_OUTPUT_BYTES=$([ "$scenario" = truncated ] || [ "$scenario" = partial-truncated ] && printf 256 || printf 1048576) \
    "$ROOT/bin/fm-procevent.sh" start "$id" 2>&1)
  printf '%s\n%s\n%s\n' "$home" "$id" "$out"
}

result=$(run_scenario feedback)
home=$(printf '%s\n' "$result" | sed -n '1p')
id=$(printf '%s\n' "$result" | sed -n '2p')
assert_grep "ack 0123456789abcdef after $id.1.result" "$TMP_ROOT/feedback.log" \
  "feedback is durably captured before its delivery is acknowledged"
assert_present "$home/state/procevent/$id.source" \
  "a nonterminal acknowledged delivery leaves its source armed"
pass "feedback is captured before ACK"

result=$(run_scenario bound-feed-failure)
home=$(printf '%s\n' "$result" | sed -n '1p')
id=$(printf '%s\n' "$result" | sed -n '2p')
assert_no_grep "ack " "$TMP_ROOT/bound-feed-failure.log" \
  "a bound keyed-answer feed failure was acknowledged"
assert_present "$home/state/procevent/$id.source" \
  "a bound keyed-answer feed failure leaves the source registered"
assert_contains "$result" \
  "source acknowledgement skipped because keyed-answer feed failed; source remains registered: $id" \
  "a bound keyed-answer feed failure prevents ACK and retirement"
pass "a bound keyed-answer feed completes before ACK"

result=$(run_scenario ack-failure)
home=$(printf '%s\n' "$result" | sed -n '1p')
id=$(printf '%s\n' "$result" | sed -n '2p')
assert_grep "ack 0123456789abcdef after $id.1.result" "$TMP_ROOT/ack-failure.log" \
  "an ACK failure happens only after durable capture"
assert_present "$home/state/procevent/$id.source" \
  "a failed ACK leaves the source registered for redelivery"
pass "ACK failure leaves the delivery unacknowledged and source unretired"

result=$(run_scenario truncated)
home=$(printf '%s\n' "$result" | sed -n '1p')
id=$(printf '%s\n' "$result" | sed -n '2p')
[ "$(wc -l < "$TMP_ROOT/truncated.log" | tr -d ' ')" = 1 ] \
  || fail "a truncated capture acknowledged an incomplete Lavish delivery"
assert_present "$home/state/procevent/$id.source" \
  "a truncated capture leaves the source registered for full redelivery"
pass "an incomplete capture is never acknowledged"

result=$(run_scenario partial)
home=$(printf '%s\n' "$result" | sed -n '1p')
id=$(printf '%s\n' "$result" | sed -n '2p')
partial_result="$home/state/procevent-inbox/$id.1.result"
assert_present "$partial_result" \
  "a nonzero poll's partial result is durably captured"
assert_grep "delivery_id: 0123456789abcdef" "$partial_result" \
  "the partial delivery identity is retained for redelivery"
[ "$(wc -l < "$TMP_ROOT/partial.log" | tr -d ' ')" = 1 ] \
  || fail "a nonzero partial poll was acknowledged"
assert_present "$home/state/procevent/$id.source" \
  "a nonzero partial poll keeps the source registered"
assert_contains "$result" \
  "source acknowledgement skipped for incomplete poll; source remains registered: $id (poll exit 73)" \
  "a nonzero partial poll reports its exit code"
pass "a nonzero partial capture is retained and not acknowledged"

result=$(run_scenario partial-truncated)
home=$(printf '%s\n' "$result" | sed -n '1p')
id=$(printf '%s\n' "$result" | sed -n '2p')
assert_no_grep "ack " "$TMP_ROOT/partial-truncated.log" \
  "a truncated nonzero poll was acknowledged"
assert_present "$home/state/procevent/$id.source" \
  "a truncated nonzero poll keeps the source registered"
assert_contains "$result" \
  "source acknowledgement skipped for truncated incomplete poll; source remains registered: $id (poll exit 73; output limit 256 bytes)" \
  "a truncated nonzero poll reports truncation and its exit code together"
assert_not_contains "$result" "truncated: $id at 256 bytes" \
  "a truncated nonzero poll emits a duplicate standalone truncation status"
pass "a truncated nonzero capture reports one complete status"

result=$(run_scenario final)
home=$(printf '%s\n' "$result" | sed -n '1p')
id=$(printf '%s\n' "$result" | sed -n '2p')
assert_grep "ack 0123456789abcdef after $id.1.result" "$TMP_ROOT/final.log" \
  "final feedback is durably captured before ACK"
assert_absent "$home/state/procevent/$id.source" \
  "final feedback retires only after ACK succeeds"
pass "session-ended feedback ACKs before retirement"

result=$(run_scenario legacy)
home=$(printf '%s\n' "$result" | sed -n '1p')
id=$(printf '%s\n' "$result" | sed -n '2p')
[ "$(wc -l < "$TMP_ROOT/legacy.log" | tr -d ' ')" = 1 ] \
  || fail "a legacy response without delivery_id triggered an ACK call"
assert_absent "$home/state/procevent/$id.source" \
  "a legacy final response keeps its existing retirement behavior"
pass "responses without delivery_id preserve legacy behavior"

printf '\nall Lavish ACK adapter tests passed\n'
