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
fm_fake_exit0 "$FAKE_BIN" lsof

if PATH="$FAKE_BIN:$PATH" FM_HOME="$HOME_DIR" FM_LAVISH_STATE_FILE="$TMP_ROOT/custom-lavish.json" \
  "$ROOT/bin/fm-lavish-session.sh" register task-one "$ARTIFACT" ephemeral-worktree >/dev/null 2>&1; then
  fail "an unsupported custom Lavish state filename was accepted"
fi
pass "unsupported Lavish state filenames are rejected before lifecycle mutation"

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

BEFORE_POLL=$(jq -s -r 'map(select(.key == "durable"))[0].last_polled_at' "$LEDGER")
sleep 1
PATH="$FAKE_BIN:$PATH" FM_HOME="$HOME_DIR" LAVISH_AXI_STATE_DIR="$STATE_DIR" \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$DURABLE" --task-id task-one >/dev/null
AFTER_POLL=$(jq -s -r 'map(select(.key == "durable"))[0].last_polled_at' "$LEDGER")
BEFORE_POLL="$BEFORE_POLL" AFTER_POLL="$AFTER_POLL" node -e '
  if (!(Date.parse(process.env.AFTER_POLL) > Date.parse(process.env.BEFORE_POLL))) process.exit(1)' \
  || fail "a real poll iteration did not refresh the ledger activity clock"
pass "every Lavish poll iteration refreshes a portable ISO activity timestamp"

OWNER_HOME="$TMP_ROOT/owner-home"
mkdir -p "$OWNER_HOME/state"
printf 'worktree=%s\nkind=ship\n' "$(dirname "$ARTIFACT")" > "$OWNER_HOME/state/owner-one.meta"
printf 'worktree=%s\nkind=ship\n' "$(dirname "$ARTIFACT")" > "$OWNER_HOME/state/owner-two.meta"
if PATH="$FAKE_BIN:$PATH" FM_HOME="$OWNER_HOME" LAVISH_AXI_STATE_DIR="$STATE_DIR" \
  "$ROOT/bin/fm-lavish-session.sh" register-auto "$ARTIFACT" >/dev/null 2>&1; then
  fail "register-auto selected one of two matching task owners"
fi
assert_absent "$OWNER_HOME/state/owner-one.lavish-sessions" "ambiguous owner did not create the first ledger"
assert_absent "$OWNER_HOME/state/owner-two.lavish-sessions" "ambiguous owner did not create the second ledger"
pass "register-auto refuses multiple matching lifecycle owners"

AUDIT_HOME="$TMP_ROOT/audit-home"
AUDIT_STATE="$TMP_ROOT/audit-lavish"
mkdir -p "$AUDIT_HOME/state/procevent" "$AUDIT_HOME/data/closed-task" "$AUDIT_STATE" "$TMP_ROOT/audit"
CURRENT="$TMP_ROOT/audit/current/board.html"
ELIGIBLE="$AUDIT_HOME/data/closed-task/board.html"
AMBIGUOUS="$TMP_ROOT/audit/unowned.html"
MISSING="$AUDIT_HOME/data/closed-task/missing.html"
FEEDBACK="$TMP_ROOT/audit/feedback.html"
HELD="$AUDIT_HOME/data/held-task/board.html"
EXPIRED="$TMP_ROOT/audit/expired.html"
EXPIRED_WORKTREE="$TMP_ROOT/.treehouse/example/expired.html"
mkdir -p "$(dirname "$CURRENT")" "$(dirname "$HELD")"
mkdir -p "$(dirname "$EXPIRED_WORKTREE")"
printf x > "$CURRENT"; printf x > "$ELIGIBLE"; printf x > "$AMBIGUOUS"; printf x > "$FEEDBACK"; printf x > "$HELD"; printf x > "$EXPIRED"; printf x > "$EXPIRED_WORKTREE"
cat > "$AUDIT_HOME/state/current-task.meta" <<EOF
worktree=$TMP_ROOT/audit/current
kind=ship
EOF
printf '%s\n' '- [x] closed-task - closed (repo: example) (kind: task)' '- [x] held-task - retained review (repo: example) (kind: task) (hold: keep) (hold-kind: parked)' > "$AUDIT_HOME/data/backlog.md"
CURRENT="$CURRENT" ELIGIBLE="$ELIGIBLE" AMBIGUOUS="$AMBIGUOUS" MISSING="$MISSING" FEEDBACK="$FEEDBACK" HELD="$HELD" EXPIRED="$EXPIRED" EXPIRED_WORKTREE="$EXPIRED_WORKTREE" node <<'NODE' > "$AUDIT_STATE/state.json"
const fs = require("node:fs");
const rows = [
  ["current", process.env.CURRENT, "open", 0],
  ["eligible", process.env.ELIGIBLE, "open", 0],
  ["ambiguous", process.env.AMBIGUOUS, "open", 0],
  ["missing", process.env.MISSING, "open", 0],
  ["feedback", process.env.FEEDBACK, "feedback", 1],
  ["held", process.env.HELD, "open", 0],
  ["expired", process.env.EXPIRED, "open", 0],
  ["expired-worktree", process.env.EXPIRED_WORKTREE, "open", 0],
];
const sessions = {};
for (const [key,file,status,pending_prompts] of rows) sessions[key] = {key,file:fs.existsSync(file)?fs.realpathSync(file):file,url:`http://127.0.0.1:4387/session/${key}`,status,pending_prompts,prompts:pending_prompts?[{tag:"message"}]:[],chat:[],updated_at:key.startsWith("expired")?"2020-01-01T00:00:00.000Z":new Date().toISOString()};
process.stdout.write(JSON.stringify({sessions}, null, 2));
NODE

FREEZE="$TMP_ROOT/candidates.jsonl"
OUT=$(PATH="$FAKE_BIN:$PATH" FM_HOME="$AUDIT_HOME" LAVISH_AXI_STATE_DIR="$AUDIT_STATE" \
  "$ROOT/bin/fm-lavish-audit.sh" audit --freeze "$FREEZE")
assert_contains "$OUT" $'preserve\tcurrent\t' "current task ownership is preserved"
assert_contains "$OUT" $'eligible\teligible\t' "positively closed task is eligible"
assert_contains "$OUT" $'ambiguous\tambiguous\t' "unowned session remains ambiguous"
assert_contains "$OUT" $'ambiguous\tmissing\tunsupported-by-current-Lavish' "missing artifact is unsupported"
assert_contains "$OUT" $'preserve\tfeedback\t' "pending feedback is preserved"
assert_contains "$OUT" $'preserve\theld\tretained-backlog-hold:parked' "retained backlog hold is preserved"
assert_contains "$OUT" $'eligible\texpired\tidle-expired:48h' "48-hour idle session is eligible"
assert_contains "$OUT" $'preserve\texpired-worktree\tretained-worktree-file' "retained worktree wins over idle expiry"
[ "$(wc -l < "$FREEZE" | tr -d ' ')" = 2 ] || fail "freeze did not contain exactly the eligible sessions"
assert_grep '"key":"eligible"' "$FREEZE" "freeze contains the eligible key"
pass "audit classifies every isolated registry row conservatively and freezes only eligible rows"

PATH="$FAKE_BIN:$PATH" FM_HOME="$AUDIT_HOME" LAVISH_AXI_STATE_DIR="$AUDIT_STATE" \
  "$ROOT/bin/fm-lavish-audit.sh" apply "$FREEZE" --batch-size 1 >/dev/null
[ "$(jq -r '.sessions.eligible.status' "$AUDIT_STATE/state.json")" = ended ] \
  || fail "apply did not end its frozen eligible session"
[ "$(jq -r '.sessions.ambiguous.status' "$AUDIT_STATE/state.json")" = open ] \
  || fail "apply changed an ambiguous session"
pass "apply ends only frozen eligible sessions and verifies the transition"

EMPTY_CANDIDATE="$TMP_ROOT/empty-candidates.jsonl"
: > "$EMPTY_CANDIDATE"
AUTHORITY="$TMP_ROOT/authority.json"
AMBIGUOUS="$AMBIGUOUS" AUDIT_STATE="$AUDIT_STATE" node <<'NODE' > "$AUTHORITY"
const fs = require("node:fs");
const row = JSON.parse(fs.readFileSync(`${process.env.AUDIT_STATE}/state.json`, "utf8")).sessions.ambiguous;
process.stdout.write(JSON.stringify({
  schema:"fm-lavish-session-authority.v1",
  ruling_date:"2026-09-08",
  frozen_at:"2026-09-08",
  ruling:"Apply only captain-authorized ambiguous existing-path sessions, except the three links mentioned on 2026-09-08.",
  authorized:[{...row,classification:"ambiguous"}],
  excluded:[
    {key:"7f59a8c16dff9f19",url:"http://127.0.0.1:4387/session/7f59a8c16dff9f19",file:"/Users/ivan/Projects/firstmate/data/nancy-tennis-directions-board-b2/board/index.html",reason:"kept board named in the 2026-09-08 ruling"},
    {key:"4ae99e8ad06d4a8c",url:"http://127.0.0.1:4387/session/4ae99e8ad06d4a8c",file:"/Users/ivan/.treehouse/firstmate-bd0d1d/8/firstmate/data/ally-screener-paid-media/board/index.html",reason:"kept board named in the 2026-09-08 ruling"},
    {key:"cc73671c247bff78",url:"http://127.0.0.1:4387/session/cc73671c247bff78",file:"/Users/ivan/Projects/firstmate/data/syd-board-b1/board/index.html",reason:"kept board named in the 2026-09-08 ruling"},
  ],
}, null, 2));
NODE
PATH="$FAKE_BIN:$PATH" FM_HOME="$AUDIT_HOME" LAVISH_AXI_STATE_DIR="$AUDIT_STATE" \
  "$ROOT/bin/fm-lavish-audit.sh" apply "$EMPTY_CANDIDATE" --authorized "$AUTHORITY" --batch-size 1 >/dev/null
[ "$(jq -r '.sessions.ambiguous.status' "$AUDIT_STATE/state.json")" = ended ] \
  || fail "authorized apply did not end the frozen ambiguous session"
pass "authorized apply requires the exact ruling and three protected board exclusions"

SUMMARY=$(PATH="$FAKE_BIN:$PATH" FM_HOME="$AUDIT_HOME" LAVISH_AXI_STATE_DIR="$AUDIT_STATE" "$ROOT/bin/fm-lavish-audit.sh" summary)
assert_contains "$SUMMARY" 'total=8' "summary counts total registry rows"
assert_contains "$SUMMARY" 'open=4' "summary counts open registry rows after apply"
assert_contains "$SUMMARY" 'feedback=1' "summary counts feedback rows"
assert_contains "$SUMMARY" 'ended=3' "summary counts ended rows"
assert_contains "$SUMMARY" 'missing_file=1' "summary counts open missing-file rows"
assert_contains "$SUMMARY" 'past_expiry=1' "summary counts expired preserved rows after apply"
pass "summary distinguishes registry counts from live connections"

printf '{not-json}\n' > "$AUDIT_HOME/state/bad-owner.lavish-sessions"
if PATH="$FAKE_BIN:$PATH" FM_HOME="$AUDIT_HOME" LAVISH_AXI_STATE_DIR="$AUDIT_STATE" \
  "$ROOT/bin/fm-lavish-audit.sh" audit >/dev/null 2>&1; then
  fail "audit converted malformed ownership inventory into an empty eligible inventory"
fi
pass "malformed ownership inventory refuses the whole audit"

fm_test_cleanup
printf 'all fm-lavish-session tests passed\n'
