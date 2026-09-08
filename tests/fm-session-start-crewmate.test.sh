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
outside_project="$TMP_ROOT/outside-project"
fm_git_worktree "$outside_project" "$outside" inherited-boundary
mkdir -p "$home/state" "$home/data" "$home/config"
rc=0
out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$outside" \
  "$ROOT/bin/fm-session-start.sh" 2>&1) || rc=$?
expect_code 2 "$rc" "an inherited FM_HOME must not authorize a linked task worktree"
assert_contains "$out" "cross-root FM_ROOT_OVERRIDE" \
  "the topology refusal did not explain the primary-scope requirement"
assert_absent "$home/state/.session-start-complete" \
  "inherited-FM_HOME refusal mutated session state"
explicit_home="$TMP_ROOT/explicit-home"
explicit_fakebin="$TMP_ROOT/explicit-fakebin"
explicit_root="$TMP_ROOT/explicit-root"
mkdir -p "$explicit_home/state" "$explicit_home/data" "$explicit_home/config" "$explicit_fakebin" "$explicit_root"
git init -q -b main "$explicit_root"
printf '# Firstmate test root\n' > "$explicit_root/AGENTS.md"
cp -R "$ROOT/bin" "$explicit_root/bin"
git -C "$explicit_root" add AGENTS.md bin
git -C "$explicit_root" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm init
fm_fake_exit0 "$explicit_fakebin" tmux node chrome-devtools-axi gh gh-axi lavish-axi tasks-axi no-mistakes treehouse
rc=0
out=$(PATH="$explicit_fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
  FM_HOME="$explicit_home" FM_ROOT_OVERRIDE="$explicit_root" FM_BOOTSTRAP_NETWORK=skip \
  FM_SESSION_START_TIMEOUT=10 "$explicit_root/bin/fm-session-start.sh" 2>&1) || rc=$?
expect_code 0 "$rc" "explicit home must pass the crewmate guard"
assert_not_contains "$out" "REFUSED: crewmate" "explicit home was treated as implicit startup"
assert_contains "$out" "NEXT STEP" "normal startup did not produce a post-guard digest"
pass "treehouse workers cannot start an implicit primary home"

# Even a plain primary checkout override cannot authorize this task script.
mkdir -p "$project/state" "$project/bin"
printf '# fixture\n' > "$project/AGENTS.md"
rc=0
out=$(FM_HOME="$project" FM_ROOT_OVERRIDE="$project" "$ROOT/bin/fm-session-start.sh" 2>&1) || rc=$?
expect_code 2 "$rc" "a primary-root override must not bypass the task boundary"
assert_contains "$out" "cross-root FM_ROOT_OVERRIDE" "override refusal missing"
assert_absent "$project/state/.session-start-complete" "override ran primary startup"
