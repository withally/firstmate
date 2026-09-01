#!/usr/bin/env bash
# Live Herdr+Pi delivered-once guard (live-harness-optin family).
#
# This guard never creates, stops, deletes, or restarts a Herdr session.
# The operator must provide an existing disposable, idle Pi pane and its exact
# working home; the guard types one nonced away-supervisor probe into that pane.
# It then reconstructs the typed-but-unconfirmed journal record and proves the
# transcript witness retires it without a second user turn.
#
# Run explicitly:
#   FM_AFK_DELIVERY_WITNESS_LIVE=1 \
#   FM_AFK_DELIVERY_WITNESS_LIVE_TARGET='<named-session>:<pane-id>' \
#   FM_AFK_DELIVERY_WITNESS_LIVE_HOME='<pi-working-directory>' \
#   tests/fm-afk-delivery-witness-live-e2e.test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_AFK_DELIVERY_WITNESS_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_AFK_DELIVERY_WITNESS_LIVE=1 with an existing disposable Herdr+Pi target and its working home"
  exit 0
fi

for tool in herdr jq pi; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "FM_AFK_DELIVERY_WITNESS_LIVE=1 but $tool is not installed"
done

TARGET=${FM_AFK_DELIVERY_WITNESS_LIVE_TARGET:-}
LIVE_HOME=${FM_AFK_DELIVERY_WITNESS_LIVE_HOME:-}
[ -n "$TARGET" ] || fail "FM_AFK_DELIVERY_WITNESS_LIVE_TARGET is required"
[ -d "$LIVE_HOME" ] || fail "FM_AFK_DELIVERY_WITNESS_LIVE_HOME must be an existing directory"
case "$TARGET" in
  *:*) ;;
  *) fail "live target must be an explicit <named-session>:<pane-id>" ;;
esac
[ "${TARGET%%:*}" != default ] || fail "the delivered-once live guard refuses the default Herdr session"
LIVE_HOME=$(cd "$LIVE_HOME" && pwd -P) || fail "could not canonicalize the Pi working home"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-delivery-witness-live.XXXXXX") \
  || fail "could not create the live guard temporary root"
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
cleanup() {
  local rc=$?
  trap - EXIT
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

export FM_HOME="$LIVE_HOME"
export FM_STATE_OVERRIDE="$STATE"
export FM_ROOT_OVERRIDE="$ROOT"
export FM_SUPERVISOR_BACKEND=herdr
export FM_SUPERVISOR_TARGET="$TARGET"
export FM_DAEMON_PRIMARY_HARNESS=pi

# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"

TRANSCRIPT=$(delivery_transcript_from_herdr pi "$TARGET") \
  || fail "the exact Herdr pane did not expose a readable Pi agent_session transcript"
TRANSCRIPT_CWD=$(jq -r 'select(.type == "session") | .cwd // empty' "$TRANSCRIPT" 2>/dev/null | head -1)
[ "$TRANSCRIPT_CWD" = "$LIVE_HOME" ] \
  || fail "the Herdr pane transcript cwd does not match FM_AFK_DELIVERY_WITNESS_LIVE_HOME"

pi_user_texts() {
  jq -r '
    select(.type == "message" and .message.role == "user")
    | .message.content[]?
    | select(.type == "text")
    | .text
  ' "$TRANSCRIPT" 2>/dev/null
}

TOKEN="FM_AFK_DELIVERY_WITNESS_LIVE_$$_$RANDOM"
before=$(pi_user_texts | grep -F -c "$TOKEN" || true)
[ "$before" -eq 0 ] || fail "the generated live token already exists in the Pi transcript"
escalate_add "$STATE" "live delivered-once guard $TOKEN; reply with exactly $TOKEN"
afk_enter "$STATE"

delivered=0
for _ in $(seq 1 80); do
  if escalate_flush "$STATE"; then
    delivered=1
    break
  fi
  sleep 0.25
done
[ "$delivered" -eq 1 ] \
  || fail "the Pi transcript never confirmed the one allowed nonced delivery attempt"

user_line=$(pi_user_texts | grep -F "$TOKEN" | tail -1)
nonce=$(printf '%s\n' "$user_line" | sed -n 's/.*\[d:\([0-9a-f][0-9a-f]*\)\].*/\1/p')
case "$nonce" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) fail "the delivered Pi user turn did not carry one 12-hex nonce" ;;
esac
after=$(pi_user_texts | grep -F -c "$TOKEN" || true)
[ "$after" -eq 1 ] || fail "the live probe appeared in $after Pi user turns instead of exactly one"

# Reconstruct the crash-recovery shape in the journal: a `typed` record carrying
# that exact already-delivered nonce and its witness baseline, exactly as the
# daemon leaves a batch it typed but crashed before confirming. The daemon must
# retire it from the transcript witness before any pane or composer check can
# lead to a second type.
jq -cn --arg nonce "$nonce" --arg t "$TRANSCRIPT" \
  --arg text "live delivered-once guard $TOKEN; reply with exactly $TOKEN" \
  '{nonce:$nonce,kind:"escalation",source_key:"",text:$text,state:"typed",buffered_epoch:0,typed_epoch:0,delivered_epoch:0,witness_transcript:$t,witness_offset:0}' \
  > "$STATE/.subsuper-delivery.jsonl"
escalate_flush "$STATE" \
  || fail "the existing Pi transcript witness did not retire the recovery record"
final=$(pi_user_texts | grep -F -c "$TOKEN" || true)
[ "$final" -eq 1 ] || fail "recovery retyped the delivered digest into $final Pi user turns"
if jq -s -e 'any(.[]; .state!="delivered")' "$STATE/.subsuper-delivery.jsonl" >/dev/null 2>&1; then
  fail "the transcript-confirmed recovery record did not retire in the journal"
fi

PI_VERSION=$(pi --version 2>/dev/null | head -1 || printf 'pi-version-unknown')
HERDR_VERSION=$(herdr --version 2>/dev/null | head -1 || printf 'herdr-version-unknown')
pass "live delivered-once guard: $PI_VERSION on $HERDR_VERSION produced one nonced user turn and no recovery retype"
