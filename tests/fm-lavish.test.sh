#!/usr/bin/env bash
# Behavior tests for Firstmate's durable Lavish review entry point.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK_ROOT=$(mktemp -d "$ROOT/.fm-lavish-test.XXXXXX") || fail "could not create the Lavish test home"
DISPOSABLE_ROOT=$(fm_test_tmproot fm-lavish-disposable)
trap 'rm -rf -- "$WORK_ROOT"; fm_test_cleanup' EXIT

FAKEBIN="$WORK_ROOT/fakebin"
CALLS="$WORK_ROOT/lavish.calls"
mkdir -p "$FAKEBIN" "$WORK_ROOT/home/data/review/.lavish"
cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAVISH_CALLS"
printf 'session: http://127.0.0.1:4387/session/test\n'
SH
chmod +x "$FAKEBIN/lavish-axi"

printf '<html><body>disposable review</body></html>\n' > "$DISPOSABLE_ROOT/review.html"

status=0
out=$(PATH="$FAKEBIN:$PATH" LAVISH_CALLS="$CALLS" FM_HOME="$WORK_ROOT/home" \
  "$ROOT/bin/fm-lavish.sh" open "$DISPOSABLE_ROOT/review.html" 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "a Lavish review under /tmp was opened"
assert_contains "$out" "REFUSED" "a disposable Lavish path fails loudly"
assert_contains "$out" 'data/<review-id>/.lavish/<name>.html' \
  "the refusal points to the durable review convention"
assert_absent "$CALLS" "a refused disposable review reached lavish-axi"
pass "Lavish open refuses a disposable path before launching a browser"

status=0
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$WORK_ROOT/home" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$DISPOSABLE_ROOT/review.html" 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "a Lavish review under /tmp was armed"
assert_contains "$out" "REFUSED" "arming a disposable Lavish path fails loudly"
assert_absent "$WORK_ROOT/home/state/procevent" \
  "a refused disposable review created a process-event registration"
pass "Lavish arm refuses a disposable path before registering its poll"

DURABLE_ARTIFACT="$WORK_ROOT/home/data/review/.lavish/review.html"
printf '<html><body>first revision</body></html>\n' > "$DURABLE_ARTIFACT"
PATH="$FAKEBIN:$PATH" LAVISH_CALLS="$CALLS" FM_HOME="$WORK_ROOT/home" \
  "$ROOT/bin/fm-lavish.sh" open "$DURABLE_ARTIFACT" >/dev/null
printf '<html><body>second revision</body></html>\n' > "$DURABLE_ARTIFACT"
PATH="$FAKEBIN:$PATH" LAVISH_CALLS="$CALLS" FM_HOME="$WORK_ROOT/home" \
  "$ROOT/bin/fm-lavish.sh" open "$DURABLE_ARTIFACT" >/dev/null

[ "$(wc -l < "$CALLS" | tr -d ' ')" -eq 2 ] \
  || fail "two updates did not make exactly two Lavish session calls"
first_call=$(sed -n '1p' "$CALLS")
second_call=$(sed -n '2p' "$CALLS")
[ "$first_call" = "$DURABLE_ARTIFACT" ] \
  || fail "the first durable open did not launch the review exactly once: $first_call"
[ "$second_call" = "$DURABLE_ARTIFACT --no-open" ] \
  || fail "the second update launched a new browser or changed file identity: $second_call"
assert_contains "$(cat "$DURABLE_ARTIFACT")" "second revision" \
  "the update keeps the same durable artifact identity"
pass "a later Lavish update reuses one durable file without another browser launch"

printf '\nall Lavish review tests passed\n'
