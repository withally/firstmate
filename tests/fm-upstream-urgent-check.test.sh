#!/usr/bin/env bash
# Behavior tests for the upstream urgent tripwire.
#
# Each case uses a fixture repository and a local bare upstream remote, so the
# check exercises its real fetch and commit-range behavior without contacting a
# network or depending on the host repository's history.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-upstream-urgent-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-urgent-check)

make_fixture_repo() {
  local name=$1 initial_subject=${2:-initial} repo remote base
  repo="$TMP_ROOT/$name/repo"
  remote="$TMP_ROOT/$name/upstream.git"
  fm_git_init_commit "$repo"
  git -C "$repo" commit --amend -qm "$initial_subject"
  git -C "$repo" branch -M main
  base=$(git -C "$repo" rev-parse HEAD)
  mkdir -p "$repo/docs"
  printf '%s\n' \
    '# Upstream sync' \
    '' \
    '| Catch-up date | Catch-up commit or adopted upstream base | Window end commit | Tier | Local PR interval and final verdict |' \
    '| --- | --- | --- | --- | --- |' \
    "| 2026-08-27 | \`$base\` (\`upstream/main\`) | \`$base\` | weekly | fixture |" \
    > "$repo/docs/upstream-sync.md"
  git -C "$repo" add docs/upstream-sync.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'docs: record fixture catch-up'
  git clone --quiet --bare "$repo" "$remote"
  git -C "$repo" remote add upstream "file://$remote"
  printf '%s\n' "$repo"
}

publish_upstream_commit() {
  local repo=$1 name=$2 subject=$3 body=$4 work commit
  work="$TMP_ROOT/$name/work"
  git clone --quiet "$(git -C "$repo" remote get-url upstream)" "$work"
  git -C "$work" config user.name 'Firstmate Tests'
  git -C "$work" config user.email 'tests@example.invalid'
  printf '%s\n%s\n' "$subject" "$body" > "$work/change.txt"
  git -C "$work" add change.txt
  git -C "$work" commit -qm "$subject" -m "$body"
  commit=$(git -C "$work" rev-parse HEAD)
  git -C "$work" push --quiet origin main
  printf '%s\n' "$commit"
}

run_check() {
  local repo=$1 out=$2 status=0
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    "$CHECK" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "upstream urgent check exit"
}

test_check_uses_one_fetch_and_finishes_quickly() {
  local repo out fakebin real_git fetches elapsed
  repo=$(make_fixture_repo fetch-budget)
  publish_upstream_commit "$repo" fetch-budget 'docs: refresh examples' 'Routine wording cleanup.' >/dev/null
  fakebin="$TMP_ROOT/fetch-budget/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *' fetch '*) printf '%s\n' fetch >> '$TMP_ROOT/fetch-budget/fetches.log' ;;
esac
exec '$real_git' "\$@"
SH
  chmod 0755 "$fakebin/git"
  out="$TMP_ROOT/fetch-budget/report.txt"
  SECONDS=0
  env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    "$CHECK" check >"$out" 2>&1
  elapsed=$SECONDS
  fetches=$(wc -l < "$TMP_ROOT/fetch-budget/fetches.log" | tr -d '[:space:]')
  [ "$fetches" = 1 ] || fail "tripwire used $fetches fetches instead of one"
  [ "$elapsed" -lt 10 ] || fail "tripwire took ${elapsed}s, expected under 10s"
  pass 'tripwire uses one fetch and stays under the ten-second budget'
}

test_slow_fetch_is_bounded_before_ten_seconds() {
  local repo out fakebin real_git elapsed status
  repo=$(make_fixture_repo slow-fetch)
  fakebin="$TMP_ROOT/slow-fetch/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *' fetch '*) sleep 11; exit 1 ;;
esac
exec '$real_git' "\$@"
SH
  chmod 0755 "$fakebin/git"
  out="$TMP_ROOT/slow-fetch/report.txt"
  status=0
  SECONDS=0
  env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" \
    "$CHECK" check >"$out" 2>&1 || status=$?
  elapsed=$SECONDS
  [ "$status" -ne 0 ] || fail 'a failed fetch was reported as a clean check'
  [ "$elapsed" -lt 10 ] || fail "slow fetch took ${elapsed}s, expected a sub-ten-second bound"
  pass 'slow fetch is bounded before ten seconds'
}

test_arm_registers_and_disarm_removes_the_check() {
  local repo shim out
  repo=$(make_fixture_repo arm)
  out="$TMP_ROOT/arm/arm.txt"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" arm >"$out"
  assert_contains "$(cat "$out")" 'armed: state/upstream-urgent.check.sh' \
    'arm did not report the registered check'
  shim="$repo/state/upstream-urgent.check.sh"
  [ -x "$shim" ] || fail 'arm did not create an executable check shim'
  FM_HOME="$repo" "$ROOT/bin/fm-check-register.sh" upstream-urgent >/dev/null \
    || fail 'arm left a check whose trust binding does not validate'
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" disarm >"$out"
  [ ! -e "$shim" ] || fail 'disarm left the check shim in place'
  [ ! -e "$repo/state/upstream-urgent.check-trust" ] \
    || fail 'disarm left the check trust binding in place'
  pass 'arm registers and disarm removes the tripwire check'
}

test_matching_upstream_commit_is_reported() {
  local repo out report commit
  repo=$(make_fixture_repo hit)
  commit=$(publish_upstream_commit "$repo" hit 'security: rotate the signing key' 'Routine key rotation after the security review.')
  out="$TMP_ROOT/hit/report.txt"
  run_check "$repo" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'urgent upstream commits:' 'matching upstream commit did not wake the check'
  assert_contains "$report" "$(printf '%s' "$commit" | cut -c1-12)" 'report did not name the matching commit'
  assert_contains "$report" 'security: rotate the signing key' 'report did not include the matching subject'
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] \
    || fail "urgent report must be exactly one line: $(cat "$out")"
  pass 'matching upstream subject is reported in one line'
}

test_matching_upstream_body_is_reported() {
  local repo out report commit
  repo=$(make_fixture_repo body-hit)
  commit=$(publish_upstream_commit "$repo" body-hit 'chore: refresh dependency notes' 'The credential rotation procedure is documented here.')
  out="$TMP_ROOT/body-hit/report.txt"
  run_check "$repo" "$out"
  report=$(cat "$out")
  assert_contains "$report" "$(printf '%s' "$commit" | cut -c1-12)" 'report did not name a body-only match'
  assert_contains "$report" 'chore: refresh dependency notes' 'report did not include the body-only match subject'
  pass 'matching upstream body is reported'
}

test_nonmatching_upstream_commit_is_silent() {
  local repo out
  repo=$(make_fixture_repo no-hit)
  publish_upstream_commit "$repo" no-hit 'docs: clarify the sync example' 'Routine wording cleanup.' >/dev/null
  out="$TMP_ROOT/no-hit/report.txt"
  run_check "$repo" "$out"
  [ ! -s "$out" ] || fail "nonmatching upstream commit produced a wake: $(cat "$out")"
  pass 'nonmatching upstream subject and body are silent'
}

test_recorded_base_is_excluded_from_the_range() {
  local repo out
  repo=$(make_fixture_repo base-excluded 'security: already handled')
  publish_upstream_commit "$repo" base-excluded 'docs: refresh examples' 'Routine wording cleanup.' >/dev/null
  out="$TMP_ROOT/base-excluded/report.txt"
  run_check "$repo" "$out"
  [ ! -s "$out" ] || fail "the recorded base was re-reported: $(cat "$out")"
  pass 'the recorded sync base is excluded from the urgent range'
}

test_matching_upstream_commit_is_reported
test_matching_upstream_body_is_reported
test_nonmatching_upstream_commit_is_silent
test_recorded_base_is_excluded_from_the_range
test_check_uses_one_fetch_and_finishes_quickly
test_slow_fetch_is_bounded_before_ten_seconds
test_arm_registers_and_disarm_removes_the_check
