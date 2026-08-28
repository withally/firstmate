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

# The tracked catch-up log records the adopted upstream base first and may name
# a later origin/main landing hash in the same cell. Extracting the last hash
# instead of the first resolves a commit that is by construction not on
# upstream/main, which fails the ancestor guard and silently disables the
# tripwire, so the real row shape is exercised directly.
test_base_is_read_from_a_row_that_also_names_a_landing_hash() {
  local repo out report commit base landed
  repo=$(make_fixture_repo landing-hash)
  base=$(git -C "$repo" rev-parse HEAD~1)
  landed=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' \
    '# Upstream sync' \
    '' \
    '| Catch-up date | Catch-up commit or adopted upstream base | Window end commit | Tier | Local PR interval and final verdict |' \
    '| --- | --- | --- | --- | --- |' \
    "| 2026-08-27 | \`$base\` (\`upstream/main\`), landed on \`origin/main\` as \`$landed\` (\`#78\`) | \`$landed\` | full | fixture |" \
    > "$repo/docs/upstream-sync.md"
  commit=$(publish_upstream_commit "$repo" landing-hash 'fix: patch a security hole' 'Body.')
  out="$TMP_ROOT/landing-hash/report.txt"
  run_check "$repo" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'urgent upstream commits:' \
    'a catch-up row naming a landing hash disabled the tripwire'
  assert_contains "$report" "$(printf '%s' "$commit" | cut -c1-12)" \
    'report did not name the commit found from the adopted base'
  pass 'the adopted base is read past a later origin/main landing hash'
}

test_unchanged_match_set_is_reported_once() {
  local repo first second third fourth
  repo=$(make_fixture_repo report-once)
  publish_upstream_commit "$repo" report-once 'security: rotate the signing key' 'Body.' >/dev/null
  first="$TMP_ROOT/report-once/first.txt"
  second="$TMP_ROOT/report-once/second.txt"
  run_check "$repo" "$first"
  [ -s "$first" ] || fail 'the first sweep did not report the matching commit'
  run_check "$repo" "$second"
  [ ! -s "$second" ] \
    || fail "an unchanged match set was reported again: $(cat "$second")"

  # A new matching commit is still news, so suppression is per match set rather
  # than a latch that silences the tripwire for good.
  publish_upstream_commit "$repo" report-once-more 'fix: revert the bad migration' 'Body.' >/dev/null
  third="$TMP_ROOT/report-once/third.txt"
  run_check "$repo" "$third"
  [ -s "$third" ] || fail 'a newly matching upstream commit was suppressed'
  fourth="$TMP_ROOT/report-once/fourth.txt"
  run_check "$repo" "$fourth"
  [ ! -s "$fourth" ] || fail "the grown match set was reported twice: $(cat "$fourth")"
  pass 'one match set wakes once and a new match is still news'
}

test_disarm_removes_the_report_record() {
  local repo out
  repo=$(make_fixture_repo record-disarm)
  publish_upstream_commit "$repo" record-disarm 'security: rotate the signing key' 'Body.' >/dev/null
  out="$TMP_ROOT/record-disarm/report.txt"
  run_check "$repo" "$out"
  [ -f "$repo/state/.upstream-urgent" ] || fail 'the check wrote no report record'
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" disarm >/dev/null
  [ ! -e "$repo/state/.upstream-urgent" ] || fail 'disarm left the report record behind'
  run_check "$repo" "$out"
  [ -s "$out" ] || fail 'a disarmed and re-run check did not report again'
  pass 'disarm drops the report record so the next run reports again'
}

# The watcher redirects a check's stderr to /dev/null and ignores its exit
# status (bin/fm-watch.sh), so only stdout can tell it the tripwire stopped
# working. An inspection failure that never reaches stdout is indistinguishable
# from a clean all-clear for as long as the check stays armed.
test_inspection_failure_is_reported_on_stdout_once() {
  local repo stray out err second_out status=0
  repo=$(make_fixture_repo unreachable-base)
  # A base commit that exists in this clone but is not on upstream/main is the
  # shape a catch-up row takes when it names an origin/main snapshot squash.
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m 'chore: snapshot upstream main for the fixture'
  stray=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' \
    '# Upstream sync' \
    '' \
    '| Catch-up date | Catch-up commit or adopted upstream base | Window end commit | Tier | Local PR interval and final verdict |' \
    '| --- | --- | --- | --- | --- |' \
    "| 2026-08-29 | \`$stray\` (\`#65\`, \`chore: snapshot upstream main\`) | \`$stray\` | full | fixture |" \
    > "$repo/docs/upstream-sync.md"
  out="$TMP_ROOT/unreachable-base/out.txt"
  err="$TMP_ROOT/unreachable-base/err.txt"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" check >"$out" 2>"$err" || status=$?
  [ "$status" -ne 0 ] || fail 'a failed inspection exited zero'
  assert_contains "$(cat "$out")" 'upstream urgent check failed:' \
    'a failed inspection produced no stdout line, so the watcher would read it as all-clear'
  assert_contains "$(cat "$out")" 'is not an ancestor of upstream/main' \
    'the stdout failure line did not name the condition'
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] \
    || fail "the failure report must be exactly one line: $(cat "$out")"

  second_out="$TMP_ROOT/unreachable-base/out2.txt"
  status=0
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" check >"$second_out" 2>/dev/null || status=$?
  [ "$status" -ne 0 ] || fail 'the second failed inspection exited zero'
  [ ! -s "$second_out" ] \
    || fail "an unchanged failure was reported again: $(cat "$second_out")"
  pass 'an inspection failure reaches stdout, exits non-zero, and wakes once'
}

test_a_recovered_inspection_reports_a_later_hit() {
  local repo out status=0
  repo=$(make_fixture_repo failure-recovery)
  git -C "$repo" remote set-url upstream "file://$TMP_ROOT/failure-recovery/absent.git"
  out="$TMP_ROOT/failure-recovery/out.txt"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" check >"$out" 2>/dev/null || status=$?
  [ "$status" -ne 0 ] || fail 'a fetch against an absent remote exited zero'
  [ -s "$out" ] || fail 'a fetch failure produced no stdout report'

  # A failure must not latch the record against a real hit that follows.
  git -C "$repo" remote set-url upstream "file://$TMP_ROOT/failure-recovery/upstream.git"
  publish_upstream_commit "$repo" failure-recovery 'security: rotate the signing key' 'Body.' >/dev/null
  run_check "$repo" "$out"
  assert_contains "$(cat "$out")" 'urgent upstream commits:' \
    'a hit after a reported failure was suppressed'
  pass 'a recovered inspection still reports the hit that follows'
}

# An unregistered shim is not inert: bin/fm-watch.sh rejects it on every sweep
# and wakes firstmate about unauthenticated state checks until someone deletes
# it by hand, so a home that could not be armed has to come back to the state
# it was in.
test_a_failed_registration_leaves_no_unregistered_shim() {
  local repo target status=0
  repo=$(make_fixture_repo arm-register-fail)
  mkdir -p "$repo/state"
  target="$TMP_ROOT/arm-register-fail/not-the-trust.txt"
  printf 'a file the trust binding must not touch\n' > "$target"
  ln -s "$target" "$repo/state/upstream-urgent.check-trust"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" 'arm with an unusable trust path exit'
  [ ! -e "$repo/state/upstream-urgent.check.sh" ] \
    || fail 'a failed registration left an unregistered check shim behind'
  [ "$(cat "$target")" = 'a file the trust binding must not touch' ] \
    || fail 'arm wrote through the trust symlink'

  printf '#!/usr/bin/env bash\n# a shim armed earlier\nexit 0\n' \
    > "$repo/state/upstream-urgent.check.sh"
  chmod 0700 "$repo/state/upstream-urgent.check.sh"
  status=0
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" 'arm over an existing shim with an unusable trust path exit'
  [ ! -e "$repo/state/upstream-urgent.check.sh" ] \
    || fail 'a failed arm left a shim behind that no trust binding covers'
  pass 'a failed registration never leaves a shim without a matching trust binding'
}

test_a_failed_rearm_restores_the_armed_shim() {
  local repo bindir f before status=0
  repo=$(make_fixture_repo arm-rearm-restore)
  # The register runs as a separate program, so a failure that leaves the
  # existing binding intact is staged by standing in for that program alone.
  bindir="$TMP_ROOT/arm-rearm-restore/bin"
  mkdir -p "$bindir"
  for f in "$ROOT"/bin/*; do
    ln -s "$f" "$bindir/$(basename "$f")"
  done
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$bindir/fm-upstream-urgent-check.sh" arm >/dev/null \
    || fail 'the first arm failed'
  before=$(cat "$repo/state/upstream-urgent.check.sh")

  rm -f "$bindir/fm-check-register.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bindir/fm-check-register.sh"
  chmod 0755 "$bindir/fm-check-register.sh"
  env FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" "$bindir/fm-upstream-urgent-check.sh" arm \
    >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" 're-arm with a failing register exit'
  [ "$(cat "$repo/state/upstream-urgent.check.sh")" = "$before" ] \
    || fail 'a failed re-arm did not restore the shim the home was armed with'
  FM_HOME="$repo" "$ROOT/bin/fm-check-register.sh" upstream-urgent >/dev/null \
    || fail 'a failed re-arm left the previously armed home unbound'
  pass 'a failed re-arm restores the shim a working home was armed with'
}

test_matching_upstream_commit_is_reported
test_matching_upstream_body_is_reported
test_nonmatching_upstream_commit_is_silent
test_recorded_base_is_excluded_from_the_range
test_check_uses_one_fetch_and_finishes_quickly
test_slow_fetch_is_bounded_before_ten_seconds
test_arm_registers_and_disarm_removes_the_check
test_base_is_read_from_a_row_that_also_names_a_landing_hash
test_unchanged_match_set_is_reported_once
test_disarm_removes_the_report_record
test_inspection_failure_is_reported_on_stdout_once
test_a_recovered_inspection_reports_a_later_hit
test_a_failed_registration_leaves_no_unregistered_shim
test_a_failed_rearm_restores_the_armed_shim
