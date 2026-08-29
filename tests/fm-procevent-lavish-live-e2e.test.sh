#!/usr/bin/env bash
# Opt-in integration guard for Firstmate's capture/ACK ordering against the
# patched Lavish durability build. The named commit is archived and built in a
# scratch directory, and its server uses an isolated ephemeral port. It never
# invokes the globally installed lavish-axi or the shared server on port 4387.
set -u

if [ "${FM_LAVISH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_LAVISH_LIVE_E2E=1 to run the patched Lavish capture/ACK regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export NODE_NO_WARNINGS=1

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LAVISH_SOURCE=${FM_LAVISH_PATCH_SOURCE:-/Users/ivan/Projects/firstmate/projects/lavish-axi}
LAVISH_COMMIT=${FM_LAVISH_PATCH_COMMIT:-8ba3f32}
TMP_ROOT=$(fm_test_tmproot fm-procevent-lavish-live)
BUILD="$TMP_ROOT/lavish-build"
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$TMP_ROOT/lavish-state"
ARTIFACT="$TMP_ROOT/review.html"
SERVER_STARTED=0
SOURCE_ID=

cleanup_live() {
  if [ -n "$SOURCE_ID" ]; then
    PATH="$BUILD/dist:$PATH" FM_HOME="$HOME_DIR" \
      "$ROOT/bin/fm-procevent.sh" retire "$SOURCE_ID" >/dev/null 2>&1 || true
  fi
  if [ "$SERVER_STARTED" -eq 1 ]; then
    PATH="$BUILD/dist:$PATH" LAVISH_AXI_STATE_DIR="$STATE_DIR" LAVISH_AXI_PORT="$PORT" \
      LAVISH_AXI_NO_OPEN=1 "$BUILD/dist/lavish-axi" stop --port "$PORT" >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup_live EXIT

[ -d "$LAVISH_SOURCE/.git" ] || fail "patched Lavish source is absent: $LAVISH_SOURCE"
git -C "$LAVISH_SOURCE" cat-file -e "$LAVISH_COMMIT^{commit}" 2>/dev/null \
  || fail "patched Lavish commit is absent: $LAVISH_COMMIT"
[ -d "$LAVISH_SOURCE/node_modules" ] \
  || fail "patched Lavish dependencies are absent; this guard never installs them"

mkdir -p "$BUILD" "$HOME_DIR/state" "$STATE_DIR"
git -C "$LAVISH_SOURCE" archive "$LAVISH_COMMIT" | tar -x -C "$BUILD" \
  || fail "could not archive patched Lavish into the scratch build"
ln -s "$LAVISH_SOURCE/node_modules" "$BUILD/node_modules"
(cd "$BUILD" && npm run build --silent) \
  || fail "scratch build of patched Lavish failed"
ln -s cli.mjs "$BUILD/dist/lavish-axi"
chmod +x "$BUILD/dist/lavish-axi"

PORT=$(node -e '
  const net = require("node:net");
  const server = net.createServer();
  server.listen(0, "127.0.0.1", () => {
    const port = server.address().port;
    server.close(() => process.stdout.write(String(port)));
  });
') || fail "could not reserve an ephemeral Lavish port"
case "$PORT" in ''|*[!0-9]*) fail "ephemeral Lavish port is invalid: $PORT" ;; esac
[ "$PORT" != 4387 ] || fail "ephemeral allocation selected the protected shared Lavish port"

printf '<html><body><h1>ACK integration</h1></body></html>\n' > "$ARTIFACT"
PATH="$BUILD/dist:$PATH" LAVISH_AXI_STATE_DIR="$STATE_DIR" LAVISH_AXI_PORT="$PORT" \
  LAVISH_AXI_NO_OPEN=1 "$BUILD/dist/lavish-axi" "$ARTIFACT" --no-open >/dev/null \
  || fail "isolated patched Lavish server/session did not start"
SERVER_STARTED=1

BASE_URL="http://127.0.0.1:$PORT" STATE_FILE="$STATE_DIR/state.json" node --input-type=module <<'EOF' \
  || fail "could not queue feedback in the isolated patched Lavish server"
import { readFile } from "node:fs/promises";
const state = JSON.parse(await readFile(process.env.STATE_FILE, "utf8"));
const key = Object.keys(state.sessions)[0];
if (!key) throw new Error("session key absent");
const response = await fetch(`${process.env.BASE_URL}/api/${key}/prompts`, {
  method: "POST",
  headers: { "content-type": "application/json", origin: process.env.BASE_URL },
  body: JSON.stringify({ prompts: [{ prompt: "capture this", tag: "message" }] }),
});
if (!response.ok) throw new Error(`prompt request failed: ${response.status}`);
EOF

poll_once() {
  PATH="$BUILD/dist:$PATH" LAVISH_AXI_STATE_DIR="$STATE_DIR" LAVISH_AXI_PORT="$PORT" \
    LAVISH_AXI_NO_OPEN=1 "$BUILD/dist/lavish-axi" poll "$ARTIFACT" --timeout-ms 1
}

FIRST=$(poll_once) || fail "first patched Lavish delivery failed"
SECOND=$(poll_once) || fail "patched Lavish redelivery failed"
FIRST_ID=$(printf '%s\n' "$FIRST" | sed -n 's/^delivery_id:[[:space:]]*//p')
SECOND_ID=$(printf '%s\n' "$SECOND" | sed -n 's/^delivery_id:[[:space:]]*//p')
[ -n "$FIRST_ID" ] && [ "$SECOND_ID" = "$FIRST_ID" ] \
  || fail "unacknowledged patched Lavish feedback was not redelivered with one stable delivery_id"

export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
SOURCE_ID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ARTIFACT")
PATH="$BUILD/dist:$PATH" LAVISH_AXI_STATE_DIR="$STATE_DIR" LAVISH_AXI_PORT="$PORT" \
  LAVISH_AXI_NO_OPEN=1 FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ARTIFACT" >/dev/null
RUN_OUTPUT=$(PATH="$BUILD/dist:$PATH" LAVISH_AXI_STATE_DIR="$STATE_DIR" LAVISH_AXI_PORT="$PORT" \
  LAVISH_AXI_NO_OPEN=1 FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-procevent.sh" start "$SOURCE_ID" 2>&1) \
  || fail "Firstmate runner failed against patched Lavish: $RUN_OUTPUT"

RESULT="$HOME_DIR/state/procevent-inbox/$SOURCE_ID.1.result"
assert_present "$RESULT" "Firstmate durably captures the patched Lavish delivery"
assert_grep "delivery_id: $FIRST_ID" "$RESULT" \
  "Firstmate captures the same delivery Lavish redelivered"
assert_contains "$RUN_OUTPUT" "source-acknowledged: $SOURCE_ID" \
  "Firstmate confirms the source ACK after capture"

AFTER_ACK=$(poll_once) || fail "post-ACK patched Lavish poll failed"
assert_contains "$AFTER_ACK" "status: waiting" \
  "the acknowledged delivery is absent from the next patched Lavish poll"
assert_not_contains "$AFTER_ACK" "delivery_id: $FIRST_ID" \
  "the acknowledged delivery does not redeliver"

pass "patched Lavish redelivers until Firstmate captures and acknowledges the delivery"
