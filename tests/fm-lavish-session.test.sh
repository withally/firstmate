#!/usr/bin/env bash
# Behavior tests for Firstmate's Lavish ownership ledger and conservative audit.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lavish-session)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$TMP_ROOT/lavish"
FAKE_BIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ARTIFACT="$TMP_ROOT/task-worktree/board.html"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$STATE_DIR" "$(dirname "$ARTIFACT")"
printf '<h1>board</h1>\n' > "$ARTIFACT"

write_store() {
  local status=${1:-open}
  ARTIFACT="$ARTIFACT" STATUS="$status" node <<'NODE' > "$STATE_DIR/state.json"
const file = require("node:fs").realpathSync(process.env.ARTIFACT);
process.stdout.write(JSON.stringify({sessions:{abc123:{key:"abc123",file,url:"http://127.0.0.1:4387/session/abc123",status:process.env.STATUS,pending_prompts:0,prompts:[],chat:[],updated_at:"2026-09-08T00:00:00.000Z"}}}, null, 2));
NODE
}

cat > "$FAKE_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = end ]; then
  ARTIFACT=$2 STATE_FILE="$LAVISH_AXI_STATE_DIR/state.json" node <<'NODE'
const fs = require("node:fs");
const state = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
const file = fs.realpathSync(process.env.ARTIFACT);
const session = Object.values(state.sessions).find(row => row.file === file);
if (!session) process.exit(2);
session.status = "ended";
session.ended_by = "agent";
fs.writeFileSync(process.env.STATE_FILE, JSON.stringify(state, null, 2));
NODE
  printf 'ended\n'
  exit 0
fi
if [ -f "${1:-}" ]; then
  ARTIFACT=$1 STATE_FILE="$LAVISH_AXI_STATE_DIR/state.json" node <<'NODE'
const fs = require("node:fs");
const state = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
const file = fs.realpathSync(process.env.ARTIFACT);
if (!Object.values(state.sessions).some(row => row.file === file)) state.sessions.durable = {key:"durable",file,url:"http://127.0.0.1:4387/session/durable",status:"open",pending_prompts:0,prompts:[],chat:[],updated_at:"2026-09-08T00:01:00.000Z"};
fs.writeFileSync(process.env.STATE_FILE, JSON.stringify(state, null, 2));
NODE
  exit 0
fi
exit 0
SH
chmod +x "$FAKE_BIN/lavish-axi"
fm_fake_exit0 "$FAKE_BIN" curl

write_store open
PATH="$FAKE_BIN:$PATH" FM_HOME="$HOME_DIR" LAVISH_AXI_STATE_DIR="$STATE_DIR" \
  "$ROOT/bin/fm-lavish-session.sh" register task-one "$ARTIFACT" ephemeral-worktree >/dev/null
LEDGER="$HOME_DIR/state/task-one.lavish-sessions"
assert_present "$LEDGER" "register creates the private task ledger"
assert_grep '"task_id":"task-one"' "$LEDGER" "ledger binds the task"
assert_grep '"key":"abc123"' "$LEDGER" "ledger binds the Lavish key"
assert_grep '"disposition":"ephemeral-worktree"' "$LEDGER" "ledger records the disposition"

PATH="$FAKE_BIN:$PATH" FM_HOME="$HOME_DIR" LAVISH_AXI_STATE_DIR="$STATE_DIR" \
  "$ROOT/bin/fm-lavish-session.sh" end-ephemeral task-one >/dev/null
[ "$(jq -r '.sessions.abc123.status' "$STATE_DIR/state.json")" = ended ] \
  || fail "end-ephemeral did not transition the isolated Lavish session"
assert_grep '"ended_at":' "$LEDGER" "verified end is recorded in the ledger"
pass "Lavish ledger registration and verified ephemeral end run through the executable"

write_store open
PATH="$FAKE_BIN:$PATH" FM_HOME="$HOME_DIR" LAVISH_AXI_STATE_DIR="$STATE_DIR" \
  "$ROOT/bin/fm-lavish-session.sh" register task-one "$ARTIFACT" ephemeral-worktree >/dev/null
DURABLE="$HOME_DIR/data/task-one/board.html"
PATH="$FAKE_BIN:$PATH" FM_HOME="$HOME_DIR" LAVISH_AXI_STATE_DIR="$STATE_DIR" \
  "$ROOT/bin/fm-lavish-session.sh" safe-park task-one "$ARTIFACT" "$DURABLE" >/dev/null
assert_present "$DURABLE" "safe-park copies the artifact into task-owned durable data"
[ "$(jq -r '.sessions.abc123.status' "$STATE_DIR/state.json")" = ended ] \
  || fail "safe-park did not end the superseded worktree session"
[ "$(jq -r '.sessions.durable.status' "$STATE_DIR/state.json")" = open ] \
  || fail "safe-park did not leave the durable review live"
jq -s -e 'any(.[]; .key == "durable" and .disposition == "durable-review")' "$LEDGER" >/dev/null \
  || fail "safe-park did not record the durable ownership binding"
pass "safe-park verifies the durable replacement before ending the superseded session"

DURABLE_SOURCE_ID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$DURABLE")
mkdir -p "$HOME_DIR/state/decision-bindings"
printf 'schema=fm-decision-binding.v1\norigin=(any)\n' > "$HOME_DIR/state/decision-bindings/$DURABLE_SOURCE_ID.origin"
if PATH="$FAKE_BIN:$PATH" FM_HOME="$HOME_DIR" LAVISH_AXI_STATE_DIR="$STATE_DIR" \
  "$ROOT/bin/fm-lavish-session.sh" end task-one "$DURABLE" >/dev/null 2>&1; then
  fail "durable end ignored an open decision binding"
fi
[ "$(jq -r '.sessions.durable.status' "$STATE_DIR/state.json")" = open ] \
  || fail "refused durable end still changed the session"
pass "durable end refuses while a captain review binding remains open"

AUDIT_HOME="$TMP_ROOT/audit-home"
AUDIT_STATE="$TMP_ROOT/audit-lavish"
LSOF_FILE="$TMP_ROOT/empty-lsof"
: > "$LSOF_FILE"
mkdir -p "$AUDIT_HOME/state/procevent" "$AUDIT_HOME/data/closed-task" "$AUDIT_STATE" "$TMP_ROOT/audit"
CURRENT="$TMP_ROOT/audit/current/board.html"
ELIGIBLE="$AUDIT_HOME/data/closed-task/board.html"
AMBIGUOUS="$TMP_ROOT/audit/unowned.html"
MISSING="$AUDIT_HOME/data/closed-task/missing.html"
FEEDBACK="$TMP_ROOT/audit/feedback.html"
mkdir -p "$(dirname "$CURRENT")"
printf x > "$CURRENT"; printf x > "$ELIGIBLE"; printf x > "$AMBIGUOUS"; printf x > "$FEEDBACK"
cat > "$AUDIT_HOME/state/current-task.meta" <<EOF
worktree=$TMP_ROOT/audit/current
kind=ship
EOF
printf '%s\n' '- [x] closed-task - closed (repo: example) (kind: task)' > "$AUDIT_HOME/data/backlog.md"
CURRENT="$CURRENT" ELIGIBLE="$ELIGIBLE" AMBIGUOUS="$AMBIGUOUS" MISSING="$MISSING" FEEDBACK="$FEEDBACK" node <<'NODE' > "$AUDIT_STATE/state.json"
const fs = require("node:fs");
const rows = [
  ["current", process.env.CURRENT, "open", 0],
  ["eligible", process.env.ELIGIBLE, "open", 0],
  ["ambiguous", process.env.AMBIGUOUS, "open", 0],
  ["missing", process.env.MISSING, "open", 0],
  ["feedback", process.env.FEEDBACK, "feedback", 1],
];
const sessions = {};
for (const [key,file,status,pending_prompts] of rows) sessions[key] = {key,file:fs.existsSync(file)?fs.realpathSync(file):file,url:`http://127.0.0.1:4387/session/${key}`,status,pending_prompts,prompts:pending_prompts?[{tag:"message"}]:[],chat:[],updated_at:"2026-09-08T00:00:00.000Z"};
process.stdout.write(JSON.stringify({sessions}, null, 2));
NODE

FREEZE="$TMP_ROOT/candidates.jsonl"
OUT=$(FM_HOME="$AUDIT_HOME" LAVISH_AXI_STATE_DIR="$AUDIT_STATE" FM_LAVISH_LSOF_FILE="$LSOF_FILE" \
  "$ROOT/bin/fm-lavish-audit.sh" audit --freeze "$FREEZE")
assert_contains "$OUT" $'preserve\tcurrent\t' "current task ownership is preserved"
assert_contains "$OUT" $'eligible\teligible\t' "positively closed task is eligible"
assert_contains "$OUT" $'ambiguous\tambiguous\t' "unowned session remains ambiguous"
assert_contains "$OUT" $'ambiguous\tmissing\tunsupported-by-current-Lavish' "missing artifact is unsupported"
assert_contains "$OUT" $'preserve\tfeedback\t' "pending feedback is preserved"
[ "$(wc -l < "$FREEZE" | tr -d ' ')" = 1 ] || fail "freeze did not contain exactly the eligible session"
assert_grep '"key":"eligible"' "$FREEZE" "freeze contains the eligible key"
pass "audit classifies every isolated registry row conservatively and freezes only eligible rows"

PATH="$FAKE_BIN:$PATH" FM_HOME="$AUDIT_HOME" LAVISH_AXI_STATE_DIR="$AUDIT_STATE" FM_LAVISH_LSOF_FILE="$LSOF_FILE" \
  "$ROOT/bin/fm-lavish-audit.sh" apply "$FREEZE" --batch-size 1 >/dev/null
[ "$(jq -r '.sessions.eligible.status' "$AUDIT_STATE/state.json")" = ended ] \
  || fail "apply did not end its frozen eligible session"
[ "$(jq -r '.sessions.ambiguous.status' "$AUDIT_STATE/state.json")" = open ] \
  || fail "apply changed an ambiguous session"
pass "apply ends only frozen eligible sessions and verifies the transition"

SUMMARY=$(FM_HOME="$AUDIT_HOME" LAVISH_AXI_STATE_DIR="$AUDIT_STATE" FM_LAVISH_LSOF_FILE="$LSOF_FILE" "$ROOT/bin/fm-lavish-audit.sh" summary)
assert_contains "$SUMMARY" 'total=5' "summary counts total registry rows"
assert_contains "$SUMMARY" 'open=3' "summary counts open registry rows after apply"
assert_contains "$SUMMARY" 'feedback=1' "summary counts feedback rows"
assert_contains "$SUMMARY" 'ended=1' "summary counts ended rows"
assert_contains "$SUMMARY" 'missing_file=1' "summary counts open missing-file rows"
pass "summary distinguishes registry counts from live connections"

fm_test_cleanup
printf 'all fm-lavish-session tests passed\n'
