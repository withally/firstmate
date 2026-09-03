#!/usr/bin/env bash
# Real Pi/Herdr regression for exact-id secondmate marker delivery.
#
# This is opt-in because it launches a real interactive Pi process and a real
# isolated Herdr lab session.
# It exercises the end-user command shape against metadata written by a real
# fm-spawn.sh --secondmate launch, reads the durable inbox record, captures the
# non-aborting Pi turn, and proves both sides of the routing boundary:
#   - exact task id through explicit FM_HOME receives exactly one marker and
#     worker carrier, then appends the requested status line without assistant text;
#   - direct terminal input remains unmarked.
#
# Every Herdr call, including calls made inside the production backend adapter,
# is routed through bin/fm-herdr-lab.sh. The PATH shim strips only the adapter's
# already-validated trailing --session pair, then delegates to the lab helper,
# which appends its own required trailing --session before invoking real Herdr.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

if [ "${FM_SEND_MARKER_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SEND_MARKER_HERDR_E2E=1 to run the real Pi/Herdr secondmate-marker regression"
  exit 0
fi

for tool in git herdr jq pi; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-send-secondmate-marker-v7)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-send-marker-herdr-e2e.XXXXXX")
SENDER_HOME="$TMP_ROOT/sender-home"
SECOND_HOME="$TMP_ROOT/secondmate-home"
CAPTURE="$TMP_ROOT/pi-before-agent.jsonl"
FAKEBIN="$TMP_ROOT/fakebin"
ORIGINAL_PATH=$PATH
REAL_PI=$(command -v pi)
ID='marker-pi-sm'
TOKEN="LIVE_OP_SILENCE_$$"
STATUS_FILE="$SECOND_HOME/state/$ID.status"
STATUS_LINE="done: $TOKEN"
REQUEST="$TOKEN: read this marked inbox request, run exactly this command: printf '%s\\n' '$STATUS_LINE' >> '$STATUS_FILE' - then move the request record to handled/."
DIRECT='FM_MARKER_HERDR_DIRECT captain input'

cleanup() {
  local rc=$?
  trap - EXIT
  if ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$SENDER_HOME/state" "$SENDER_HOME/data" "$SENDER_HOME/config" "$SENDER_HOME/projects" "$FAKEBIN"

# Route production adapter invocations through the same guarded helper as every
# explicit E2E probe. The helper itself runs with the original PATH, preventing
# recursion into this shim.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo "wrapper requires the isolated lab session" >&2; exit 98; }
  for arg in "\${args[@]}"; do
    case "\$arg" in
      --session|--session=*) echo "wrapper refused non-trailing session flag" >&2; exit 99 ;;
    esac
  done
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

git clone -q --no-hardlinks "$ROOT" "$SECOND_HOME"
git -C "$SECOND_HOME" checkout -q --detach HEAD
mkdir -p "$SECOND_HOME/state" "$SECOND_HOME/data" "$SECOND_HOME/config" "$SECOND_HOME/projects"
printf '%s\n' "$ID" > "$SECOND_HOME/.fm-secondmate-home"
cat > "$SECOND_HOME/data/charter.md" <<'EOF'
# Isolated marker capture secondmate

You are a task-local secondmate used only for the marker transport regression.
Do not initiate work before an instruction arrives.
When the instruction inbox doorbell arrives, read each record in numeric order,
act on its request, and move each handled record to handled/.
Append the requested status line to the status file after acting on the request.
EOF

# A separate explicit Pi extension grants session-only project trust and records
# both before_agent_start prompts and completed assistant messages.
# The PATH wrapper adds only that test resource while preserving the production
# secondmate launch and its own extension arguments unchanged.
CAPTURE_JSON=$(printf '%s' "$CAPTURE" | jq -Rs .)
CAPTURE_EXTENSION="$TMP_ROOT/fm-send-marker-capture.ts"
cat > "$CAPTURE_EXTENSION" <<EOF
import { appendFileSync } from "node:fs";
const capturePath = $CAPTURE_JSON;
export default function (pi: any) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("before_agent_start", (event) => {
    appendFileSync(capturePath, \`\${JSON.stringify({ kind: "before_agent_start", prompt: event.prompt, hex: Buffer.from(event.prompt, "utf8").toString("hex") })}\\n\`);
  });
  pi.on("message_end", (event) => {
    appendFileSync(capturePath, \`\${JSON.stringify({ kind: "message_end", role: event?.message?.role, content: event?.message?.content })}\\n\`);
  });
}
EOF
printf '#!/usr/bin/env bash\nexec %q -e %q "$@"\n' "$REAL_PI" "$CAPTURE_EXTENSION" > "$FAKEBIN/pi"
chmod +x "$FAKEBIN/pi"

"$LAB_HELPER" provision "$SESSION"
PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SENDER_HOME" HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$SECOND_HOME" --secondmate --harness pi --backend herdr >/dev/null

META="$SENDER_HOME/state/$ID.meta"
[ -f "$META" ] || fail "real secondmate spawn did not write exact-id metadata"
[ "$(fm_meta_get "$META" kind)" = secondmate ] || fail "real secondmate metadata did not record kind=secondmate"
TARGET=$(fm_backend_target_of_meta "$META")
PANE=${TARGET#*:}
case "$TARGET" in
  "$SESSION":w*:p*) : ;;
  *) fail "real secondmate metadata recorded an unexpected Herdr target: $TARGET" ;;
esac

wait_for_prompt() { # <needle>
  local needle=$1 _
  for _ in $(seq 1 240); do
    if [ -s "$CAPTURE" ] && jq -e --arg needle "$needle" \
      'select(.kind == "before_agent_start" and ((.prompt // "") | contains($needle)))' \
      "$CAPTURE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

literal_count() { # <haystack> <needle>
  printf '%s' "$1" | grep -F -o -- "$2" | wc -l | tr -d ' '
}

record_body() { # <record-path>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

last_assistant_content() {
  jq -cs '
    [.[] | select(.kind == "message_end" and .role == "assistant")]
    | if length == 0 then empty else .[-1].content end
  ' "$CAPTURE" 2>/dev/null || true
}

assistant_text_count() {
  jq -cs '
    [.[] | select(.kind == "message_end" and .role == "assistant")
      | (.content // [])[]?
      | select(.type == "text" and ((.text // "") != ""))]
    | length
  ' "$CAPTURE"
}

wait_for_idle() {
  local status _ stable=0
  for _ in $(seq 1 240); do
    status=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null \
      | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$status" in
      idle|done)
        stable=$((stable + 1))
        [ "$stable" -ge 4 ] && return 0
        ;;
      *) stable=0 ;;
    esac
    sleep 0.25
  done
  return 1
}

# The startup charter proves the CLI extension loaded. Wait until the real
# worker has settled before exercising the inbox. A single native idle sample
# can precede Pi's final redraw.
wait_for_prompt 'Isolated marker capture secondmate' \
  || fail "real Pi before_agent_start capture did not load for the startup charter"
wait_for_idle || fail "real Pi did not become idle after the startup capture"

: > "$CAPTURE"

PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SENDER_HOME" \
  "$ROOT/bin/fm-send.sh" "$ID" "$REQUEST" >/dev/null
REC="$SENDER_HOME/state/$ID.inbox/001.msg"
HANDLED="$SENDER_HOME/state/$ID.inbox/handled/001.msg"
BODY=
for _ in $(seq 1 240); do
  for candidate in "$REC" "$HANDLED"; do
    if [ -f "$candidate" ]; then
      BODY=$(record_body "$candidate" 2>/dev/null || true)
      [ -n "$BODY" ] && break 2
    fi
  done
  sleep 0.25
done
[ -n "$BODY" ] || fail "real fm-send did not leave a readable durable inbox record"
case "$BODY" in
  "$FM_FROMFIRST_MARK"corr=*"$REQUEST""$FM_OPERATIONAL_WORKER_CARRIER") : ;;
  *) fail "durable secondmate record did not preserve marker, correlation, request, and worker carrier"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$BODY" | od -An -tx1)" ;;
esac
[ "$(literal_count "$BODY" "$FM_OPERATIONAL_WORKER_CARRIER")" = 1 ] \
  || fail "durable secondmate record did not contain exactly one worker carrier"
[ "$(literal_count "$BODY" "$FM_OPERATIONAL_SILENT_REPLY_RULE")" = 1 ] \
  || fail "durable secondmate record did not contain exactly one silence rule"
wait_for_prompt 'Firstmate instruction waiting' \
  || fail "real Pi did not receive the durable inbox doorbell"
DOORBELL=$(jq -r -s '
  [.[] | select(.kind == "before_agent_start" and ((.prompt // "") | contains("Firstmate instruction waiting")))]
  | if length == 0 then empty else .[-1].prompt end
' "$CAPTURE")
[ "$(literal_count "$DOORBELL" "$FM_OPERATIONAL_SILENT_REPLY_RULE")" = 1 ] \
  || fail "inbox doorbell did not carry exactly one silence rule"
for _ in $(seq 1 240); do
  if [ -f "$HANDLED" ] && [ -f "$STATUS_FILE" ] && grep -Fqx "$STATUS_LINE" "$STATUS_FILE"; then
    break
  fi
  sleep 0.25
done
[ -f "$HANDLED" ] || fail "real Pi did not acknowledge the durable inbox record"
[ "$(grep -Fxc "$STATUS_LINE" "$STATUS_FILE" 2>/dev/null || true)" = 1 ] \
  || fail "real Pi did not append exactly one requested status line"
wait_for_idle || fail "real Pi did not become idle after the exact-id capture"
ASSISTANT_CONTENT=$(last_assistant_content)
[ "$(assistant_text_count)" = 0 ] \
  || fail "real Pi emitted assistant text for the silent inbox request"
[ "$ASSISTANT_CONTENT" = '[]' ] \
  || fail "real Pi emitted assistant content for the silent inbox request: ${ASSISTANT_CONTENT:-<missing>}"
printf 'evidence: exact-id durable-body-hex=%s status=%s assistant-content=%s\n' \
  "$(printf '%s' "$BODY" | od -An -tx1 | tr -d ' \n')" "$STATUS_LINE" "$ASSISTANT_CONTENT"
pass "real Pi/Herdr: exact-id inbox request is marked, acted, acked, and silent"

# Direct terminal input bypasses fm-send's metadata-routed transformation and
# therefore remains conversational captain input.
"$LAB_HELPER" run "$SESSION" pane send-text "$PANE" "$DIRECT" >/dev/null
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null
wait_for_prompt "$DIRECT" || fail "real Pi did not receive direct terminal input"
GOT=$(jq -r -s --arg needle "$DIRECT" '
  [.[] | select(.kind == "before_agent_start" and ((.prompt // "") | contains($needle)))]
  | if length == 0 then empty else .[-1].prompt end
' "$CAPTURE")
[ "$GOT" = "$DIRECT" ] || fail "direct captain input was changed or marked"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$GOT" | od -An -tx1)"
if fm_message_from_firstmate "$GOT"; then
  fail "direct captain input was classified as from-firstmate"
fi
printf 'evidence: direct-input received-hex=%s\n' "$(printf '%s' "$GOT" | od -An -tx1 | tr -d ' \n')"
pass "real Pi/Herdr: direct captain terminal input stays unmarked"
