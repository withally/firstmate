#!/usr/bin/env bash
# Live macOS case-insensitive-filesystem proof for fm-spawn's worktree guard.
#
# Run explicitly with FM_SPAWN_CASE_IDENTITY_LIVE=1 on the macOS host whose
# filesystem behavior is being trusted. The opt-in refuses every non-Darwin
# platform by name, refuses a case-sensitive fixture, drives fm-spawn.sh through
# its public CLI, and requires the real case-variant primary path to be refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_SPAWN_CASE_IDENTITY_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_SPAWN_CASE_IDENTITY_LIVE=1 to run the macOS case-insensitive worktree-identity proof"
  exit 0
fi

PLATFORM=$(uname -s 2>/dev/null || echo unknown)
[ "$PLATFORM" = Darwin ] || {
  echo "not ok - FM_SPAWN_CASE_IDENTITY_LIVE=1 requires macOS Darwin, got '$PLATFORM'" >&2
  exit 1
}

TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-identity-live)
fm_git_identity fmtest fmtest@example.invalid

PROJECT="$TMP_ROOT/PrimaryProject"
PROJECT_VARIANT="$TMP_ROOT/primaryproject"
HOME_DIR="$TMP_ROOT/home"
ID=case-identity-live
mkdir -p "$PROJECT" "$HOME_DIR/data/$ID"
git init -q -b main "$PROJECT"
git -C "$PROJECT" commit -q --allow-empty -m init
printf 'brief\n' > "$HOME_DIR/data/$ID/brief.md"

[ -d "$PROJECT_VARIANT" ] || {
  echo "not ok - Darwin filesystem at '$TMP_ROOT' is case-sensitive; live case-identity proof cannot run" >&2
  exit 1
}
[ "$PROJECT" -ef "$PROJECT_VARIANT" ] || {
  echo "not ok - Darwin case variants do not identify the same device and inode at '$TMP_ROOT'" >&2
  exit 1
}

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '@caseidentity\n'; exit 0 ;;
  list-windows|has-session|new-session|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
fm_fake_exit0 "$FAKEBIN" treehouse
fm_fake_exit0 "$FAKEBIN" sleep

mkdir -p "$HOME_DIR/state" "$HOME_DIR/projects" "$HOME_DIR/config"
set +e
OUT=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$PROJECT" TMUX="fake,1,0" \
  PATH="$FAKEBIN:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT_VARIANT" codex \
    --mode no-mistakes --yolo off 2>&1)
STATUS=$?
set -e

printf '# command: FM_SPAWN_CASE_IDENTITY_LIVE=1 tests/fm-spawn-worktree-identity-live.test.sh\n'
printf '# platform: %s\n' "$PLATFORM"
printf '# primary: %s\n' "$PROJECT_VARIANT"
printf '# pane cwd: %s\n' "$PROJECT"
printf '# exit: %s\n' "$STATUS"
printf '%s\n' "$OUT"

expect_code 1 "$STATUS" "case-variant primary checkout should be refused"
assert_contains "$OUT" "treehouse get did not enter a worktree" \
  "case-variant primary checkout did not produce the settle-loop refusal"
assert_not_contains "$OUT" "spawned $ID" "case-variant primary checkout was wrongly launched"
pass "Darwin case-insensitive filesystem: fm-spawn refuses the primary checkout by identity"
