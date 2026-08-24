#!/usr/bin/env bash
# tests/fm-telemetry.test.sh - public recorder, rotation, and singleton behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TELEMETRY="$ROOT/bin/fm-telemetry.sh"
TMP_ROOT=$(fm_test_tmproot fm-telemetry-tests)
DAEMON_HOME=

cleanup_telemetry_test() {
  if [ -n "$DAEMON_HOME" ] && [ -x "$TELEMETRY" ]; then
    FM_HOME="$DAEMON_HOME" "$TELEMETRY" disarm >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup_telemetry_test EXIT
trap 'cleanup_telemetry_test; exit 130' INT
trap 'cleanup_telemetry_test; exit 143' TERM

write_fake_samplers() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/memory_pressure" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -Q ] || {
  printf 'expected summary-only -Q mode\n' >&2
  exit 1
}
printf 'System-wide memory free percentage: 42%%\n'
SH
  cat > "$fakebin/vm_stat" <<'SH'
#!/usr/bin/env bash
printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 123.\n'
SH
  cat > "$fakebin/sysctl" <<'SH'
#!/usr/bin/env bash
printf 'vm.swapusage: total = 4096.00M  used = 1024.00M  free = 3072.00M\n'
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
cat <<'OUT'
101 1 101 7.5 9000 01:00 alpha
102 1 102 1.5 3000 00:30 beta
103 101 101 0.5 5000 00:10 gamma
OUT
SH
  cat > "$fakebin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fake 100000 25000 75000 25%% /\n'
SH
  cat > "$fakebin/sync" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_SYNC_FAIL:-0}" = 1 ] && exit 1
[ "${1:-}" = -f ] && [ -f "${2:-}" ] || exit 2
[ -z "${FM_TEST_SYNC_RECEIPT:-}" ] || printf '%s\n' "$2" > "$FM_TEST_SYNC_RECEIPT"
exit 0
SH
  chmod +x "$fakebin"/*
}

record_once() {
  local home=$1 fakebin=$2
  FM_HOME="$home" FM_TELEMETRY_RECORD_ONCE=1 FM_TEST_SYNC_RECEIPT="$home/sync.receipt" \
    PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" record
}

test_record_writes_parseable_durable_snapshot() {
  local home fakebin log
  home="$TMP_ROOT/record-home"
  fakebin="$TMP_ROOT/record-fakebin"
  mkdir -p "$home/state"
  write_fake_samplers "$fakebin"

  record_once "$home" "$fakebin" || fail "record mode failed"
  log=$(find "$home/state/telemetry" -name 'telemetry-*.log' -type f | head -1)
  [ -n "$log" ] || fail "record mode did not create a daily log"
  assert_contains "$(cat "$log")" 'SNAPSHOT_BEGIN schema=fm-telemetry-v1' "snapshot begin marker is missing"
  assert_contains "$(cat "$log")" 'MEMORY_PRESSURE' "memory-pressure section is missing"
  assert_contains "$(cat "$log")" 'System-wide memory free percentage: 42%' "memory-pressure summary mode was not captured"
  assert_contains "$(cat "$log")" 'vm.swapusage: total = 4096.00M' "swap sampler output is missing"
  assert_contains "$(cat "$log")" 'PROCESS_TOTAL 3' "process total was not derived from the sampled table"
  assert_contains "$(cat "$log")" 'TOP_RSS_KIB' "RSS ranking is missing"
  assert_contains "$(cat "$log")" 'TOP_CPU_PERCENT' "CPU ranking is missing"
  assert_contains "$(cat "$log")" 'PROCESS_COUNTS_BY_PARENT' "per-parent counts are missing"
  assert_contains "$(cat "$log")" 'PROCESS_COUNTS_BY_PGID_COALITION_APPROX' "coalition approximation is missing"
  assert_contains "$(cat "$log")" 'SNAPSHOT_END' "snapshot end marker is missing"
  assert_contains "$(cat "$home/sync.receipt")" "$log" "record mode did not file-sync the appended daily log"
  case "$(FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" status 2>&1)" in
    *'not running newest_snapshot_age='[0-9]*s*) ;;
    *) fail "status did not report the newest completed snapshot age" ;;
  esac
  [ ! -d "$home/state/telemetry/.record.lock" ] || fail "one-shot record left its lock behind"
  pass "record writes one bounded, parseable snapshot and releases its lock"
}

test_record_surfaces_durability_failure() {
  local home fakebin out rc
  home="$TMP_ROOT/sync-failure-home"
  fakebin="$TMP_ROOT/sync-failure-fakebin"
  mkdir -p "$home/state"
  write_fake_samplers "$fakebin"

  out=$(FM_HOME="$home" FM_TELEMETRY_RECORD_ONCE=1 FM_TEST_SYNC_FAIL=1 \
    PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" record 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "one-shot record hid a failed durability sync"
  assert_contains "$out" 'sync -f failed' "one-shot record did not identify the durability failure"
  [ ! -d "$home/state/telemetry/.record.lock" ] || fail "failed one-shot record left its lock behind"
  pass "one-shot record returns failure when its durability sync fails"
}

test_rotation_prunes_oldest_daily_logs_to_cap() {
  local home fakebin telemetry total
  home="$TMP_ROOT/rotation-home"
  fakebin="$TMP_ROOT/rotation-fakebin"
  telemetry="$home/state/telemetry"
  mkdir -p "$telemetry"
  write_fake_samplers "$fakebin"
  head -c 1200 /dev/zero | tr '\0' a > "$telemetry/telemetry-2026-01-01.log"
  head -c 1200 /dev/zero | tr '\0' b > "$telemetry/telemetry-2026-01-02.log"

  FM_HOME="$home" FM_TELEMETRY_RECORD_ONCE=1 FM_TELEMETRY_MAX_BYTES=3000 \
    PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" record || fail "rotation record failed"

  assert_absent "$telemetry/telemetry-2026-01-01.log" "rotation did not prune the oldest daily log"
  total=$(find "$telemetry" -name 'telemetry-*.log' -type f -exec wc -c {} + | awk 'END { print $1 + 0 }')
  [ "$total" -le 3000 ] || fail "rotation retained $total bytes above the 3000-byte cap"
  pass "rotation prunes oldest daily logs until total bytes are within the cap"
}

test_arm_is_idempotent_and_disarm_stops_singleton() {
  local home fakebin first_pid second_pid out tries
  home="$TMP_ROOT/daemon-home"
  fakebin="$TMP_ROOT/daemon-fakebin"
  mkdir -p "$home/state"
  write_fake_samplers "$fakebin"
  rm -f "$fakebin/ps"
  DAEMON_HOME=$home

  FM_HOME="$home" FM_TELEMETRY_INTERVAL=15 PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" arm >/dev/null || fail "first arm failed"
  tries=0
  while [ ! -s "$home/state/telemetry/.record.lock/pid" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -s "$home/state/telemetry/.record.lock/pid" ] || fail "arm did not publish its singleton owner"
  first_pid=$(cat "$home/state/telemetry/.record.lock/pid")

  FM_HOME="$home" FM_TELEMETRY_INTERVAL=15 PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" arm >/dev/null || fail "idempotent arm failed"
  second_pid=$(cat "$home/state/telemetry/.record.lock/pid")
  [ "$first_pid" = "$second_pid" ] || fail "second arm replaced the live recorder ($first_pid -> $second_pid)"

  out=$(FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" status) || fail "status did not report the live recorder"
  assert_contains "$out" "running pid=$first_pid" "status did not identify the singleton owner"
  assert_contains "$out" 'interval=15s' "status did not report the live recorder's configured cadence"

  FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" disarm >/dev/null || fail "disarm failed"
  kill -0 "$first_pid" 2>/dev/null && fail "disarm left recorder pid $first_pid alive"
  out=$(FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" status 2>&1)
  assert_contains "$out" 'not running' "status did not report the stopped recorder"
  DAEMON_HOME=
  pass "arm is idempotent and disarm cleanly stops the one per-home recorder"
}

test_record_writes_parseable_durable_snapshot
test_record_surfaces_durability_failure
test_rotation_prunes_oldest_daily_logs_to_cap
test_arm_is_idempotent_and_disarm_stops_singleton
