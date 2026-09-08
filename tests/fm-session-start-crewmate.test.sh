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
assert_contains "$out" "cross-root FM_ROOT_OVERRIDE" "refusal did not explain the boundary"
assert_absent "$worktree/state" "startup mutated task state before refusing"
assert_absent "$worktree/data" "startup mutated task data before refusing"
outside="$TMP_ROOT/outside-linked-worktree"
home="$TMP_ROOT/inherited-home"
fm_git_worktree "$project" "$outside" inherited-boundary
mkdir -p "$home/state" "$home/data" "$home/config"
rc=0
out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$outside" \
  "$ROOT/bin/fm-session-start.sh" 2>&1) || rc=$?
expect_code 2 "$rc" "an inherited FM_HOME must not authorize a linked task worktree"
assert_contains "$out" "cross-root FM_ROOT_OVERRIDE" \
  "the topology refusal did not explain the primary-scope requirement"
assert_absent "$home/state/.session-start-complete" \
  "inherited-FM_HOME refusal mutated session state"
rc=0
out=$(FM_HOME="$TMP_ROOT/explicit-home" FM_ROOT_OVERRIDE="$worktree" \
  "$ROOT/bin/fm-session-start.sh" --help 2>&1) || rc=$?
expect_code 0 "$rc" "explicit home must pass the crewmate guard"
assert_not_contains "$out" "REFUSED: crewmate" "explicit home was treated as implicit startup"
pass "treehouse workers cannot start an implicit primary home"

# Even a plain primary checkout override cannot authorize this task script.
mkdir -p "$project/state" "$project/bin"
printf '# fixture\n' > "$project/AGENTS.md"
rc=0
out=$(FM_HOME="$project" FM_ROOT_OVERRIDE="$project" "$ROOT/bin/fm-session-start.sh" 2>&1) || rc=$?
expect_code 2 "$rc" "a primary-root override must not bypass the task boundary"
assert_contains "$out" "cross-root FM_ROOT_OVERRIDE" "override refusal missing"
assert_absent "$project/state/.session-start-complete" "override ran primary startup"
