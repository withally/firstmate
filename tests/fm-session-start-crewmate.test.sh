#!/usr/bin/env bash
# Exercise the primary-only startup boundary before any home mutation.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-session-start-crewmate)
project="$TMP_ROOT/project"
worktree="$TMP_ROOT/.treehouse/project/1/project"
fm_git_worktree "$project" "$worktree" task-boundary
rc=0
out=$(env -u FM_HOME FM_ROOT_OVERRIDE="$worktree" \
  "$ROOT/bin/fm-session-start.sh" 2>&1) || rc=$?
expect_code 2 "$rc" "task worktree must refuse implicit primary startup"
assert_contains "$out" "crewmate task worktree has no FM_HOME" "refusal did not explain the boundary"
assert_absent "$worktree/state" "startup mutated task state before refusing"
assert_absent "$worktree/data" "startup mutated task data before refusing"
rc=0
out=$(FM_HOME="$TMP_ROOT/explicit-home" FM_ROOT_OVERRIDE="$worktree" \
  "$ROOT/bin/fm-session-start.sh" --help 2>&1) || rc=$?
expect_code 0 "$rc" "explicit home must pass the crewmate guard"
assert_not_contains "$out" "REFUSED: crewmate" "explicit home was treated as implicit startup"
pass "treehouse workers cannot start an implicit primary home"
