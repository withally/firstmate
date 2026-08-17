#!/usr/bin/env bash
# Real-agent regression for the internal stow skill's session-bounded
# open-record persistence contract.
set -eu

if [ "${FM_STOW_OPEN_RECORD_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_STOW_OPEN_RECORD_LIVE_E2E=1 to run the stow open-record regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pi >/dev/null 2>&1 || fail "pi is required for the stow open-record regression"
command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required for the stow open-record regression"

TMP_ROOT=$(fm_test_tmproot stow-open-record)
PRIMARY="$TMP_ROOT/primary"
SECONDMATE="$TMP_ROOT/secondmate"
SKILL="$ROOT/.agents/skills/stow/SKILL.md"
OUTPUT="$TMP_ROOT/stow.out"

mkdir -p "$PRIMARY/bin" "$PRIMARY/config" "$PRIMARY/data" \
  "$SECONDMATE/data"
cp "$ROOT/bin/fm-startup-memory-budget.sh" \
  "$ROOT/bin/fm-startup-memory-budget-lib.sh" "$PRIMARY/bin/"
chmod +x "$PRIMARY/bin/fm-startup-memory-budget.sh"
printf '%s\n' 7500 >"$PRIMARY/config/startup-memory-budget"
printf '%s\n' '# Captain' >"$PRIMARY/data/captain.md"
printf '%s\n' '# Shared captain preferences' >"$PRIMARY/data/captain-shared.md"
printf '%s\n' '# Learnings' >"$PRIMARY/data/learnings.md"

cat >"$PRIMARY/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML

tasks-axi add known-stale "Known stale thread" \
  --file "$PRIMARY/data/backlog.md" --queue >/dev/null
tasks-axi add unknown-decoy "Unnamed decoy thread" \
  --file "$PRIMARY/data/backlog.md" --queue >/dev/null
tasks-axi show unknown-decoy --file "$PRIMARY/data/backlog.md" --full \
  >"$TMP_ROOT/unknown.before"

cat >"$SECONDMATE/data/backlog.md" <<'MARKDOWN'
# Backlog

## Queued

- [ ] `secondmate-owned` - This record belongs to another home.
MARKDOWN
shasum -a 256 "$SECONDMATE/data/backlog.md" >"$TMP_ROOT/secondmate.before"

PROMPT=$(cat <<EOF
Invoke /stow against only the disposable synthetic primary home at $PRIMARY.
The current session holds exactly two open-work facts: known-unfiled is an important new queued thread titled "Known unfiled thread", and known-stale has completed successfully without a PR or report.
No other open-work fact is present in this session.
Use the existing record owner for those two facts.
This is a primary-home session, and it holds no evidence from any secondmate session.
Follow the loaded stow skill, including its startup-memory reports and completion receipt.
EOF
)

(
  cd "$PRIMARY"
  FM_HOME="$PRIMARY" pi -p --no-session --no-extensions --no-context-files \
    --model openai-codex/gpt-5.6-terra --thinking medium \
    --skill "$SKILL" "$PROMPT"
) >"$OUTPUT"

tasks-axi show known-unfiled --file "$PRIMARY/data/backlog.md" --full \
  >"$TMP_ROOT/known-unfiled.after" \
  || fail "stow did not file the session-known missing record"
assert_contains "$(cat "$TMP_ROOT/known-unfiled.after")" "state: queued" \
  "the missing record was not filed as queued open work"

tasks-axi show known-stale --file "$PRIMARY/data/backlog.md" --full \
  >"$TMP_ROOT/known-stale.after"
assert_contains "$(cat "$TMP_ROOT/known-stale.after")" "state: done" \
  "stow did not correct the session-known stale record"

tasks-axi show unknown-decoy --file "$PRIMARY/data/backlog.md" --full \
  >"$TMP_ROOT/unknown.after"
cmp -s "$TMP_ROOT/unknown.before" "$TMP_ROOT/unknown.after" \
  || fail "stow changed an open record the session did not name"

shasum -a 256 "$SECONDMATE/data/backlog.md" >"$TMP_ROOT/secondmate.after"
cmp -s "$TMP_ROOT/secondmate.before" "$TMP_ROOT/secondmate.after" \
  || fail "stow crossed the secondmate ownership boundary"

assert_contains "$(cat "$OUTPUT")" "known-unfiled" \
  "the completion receipt omitted the filed open record"
assert_contains "$(cat "$OUTPUT")" "known-stale" \
  "the completion receipt omitted the corrected open record"
assert_contains "$(cat "$OUTPUT")" "nothing this session knew" \
  "the reset-safe receipt did not state its session-scoped meaning"
assert_contains "$(cat "$OUTPUT")" "not a reconciliation" \
  "the reset-safe receipt implied a broader reconciliation"

pass "stow persists only session-known open records and reports the bounded receipt"
