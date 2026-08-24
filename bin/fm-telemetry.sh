#!/usr/bin/env bash
# fm-telemetry.sh - durable, low-overhead host resource snapshots.
#
# Usage:
#   fm-telemetry.sh arm
#   fm-telemetry.sh disarm
#   fm-telemetry.sh status
#   fm-telemetry.sh record [owner-token]   internal detached recorder mode
#
# The recorder writes append-only daily logs under state/telemetry/.
# Each bounded snapshot contains macOS memory pressure, VM and swap summaries,
# one process-table sample reused for RSS/CPU rankings and parent/PGID counts,
# and root-volume free space.
# After every append, `sync -f` makes that log durable before the loop sleeps.
# Oldest daily logs are pruned until their total size is no more than
# FM_TELEMETRY_MAX_BYTES (default 209715200, or 200 MiB).
#
# `arm` is idempotent and starts one detached recorder per FM_HOME.
# A directory lock contains both a PID and a unique launch token,
# so stale PID reuse is not trusted by status or disarm.
# `disarm` sends TERM and waits for the recorder's trap to release that lock.
# Nothing auto-arms this tool and it never installs a launch agent.
#
# FM_TELEMETRY_INTERVAL controls the cadence in whole seconds from 15 through
# 3600 (default 20).
# FM_HOME and FM_STATE_OVERRIDE select the home and state root normally used by
# Firstmate scripts.
# FM_TELEMETRY_RECORD_ONCE=1 is a test seam that makes internal record mode take
# one snapshot and exit.
#
# Steady-state overhead is one sleeping Bash process.
# Each tick launches samplers sequentially, never recursively or on overlapping
# schedules, and reuses one `ps` result for every process-derived section.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TELEMETRY_DIR="$STATE/telemetry"
LOCK_DIR="$TELEMETRY_DIR/.record.lock"
INTERVAL=${FM_TELEMETRY_INTERVAL:-20}
MAX_BYTES=${FM_TELEMETRY_MAX_BYTES:-209715200}
TOP_COUNT=15
SNAPSHOT_SCHEMA=fm-telemetry-v1
SNAPSHOT_TMP=
SAMPLE_TMP=
PROCESS_TMP=
OWNER_TOKEN=

usage() {
  cat <<'EOF'
Usage:
  fm-telemetry.sh arm       start one detached recorder for this FM_HOME
  fm-telemetry.sh disarm    stop this home's recorder cleanly
  fm-telemetry.sh status    report running state and newest snapshot age

Configuration:
  FM_TELEMETRY_INTERVAL     seconds between snapshots (15..3600, default 20)
  FM_TELEMETRY_MAX_BYTES    total daily-log cap (default 209715200)
  FM_HOME                   Firstmate home (defaults to this repository)

This command never auto-arms itself or installs a launch agent.
EOF
}

fail() {
  printf 'fm-telemetry: %s\n' "$1" >&2
  exit 1
}

validate_configuration() {
  case "$INTERVAL" in
    ''|*[!0-9]*) fail "FM_TELEMETRY_INTERVAL must be a whole number from 15 to 3600" ;;
  esac
  if [ "$INTERVAL" -lt 15 ] || [ "$INTERVAL" -gt 3600 ]; then
    fail "FM_TELEMETRY_INTERVAL must be a whole number from 15 to 3600"
  fi
  case "$MAX_BYTES" in
    ''|*[!0-9]*|0) fail "FM_TELEMETRY_MAX_BYTES must be a positive whole number" ;;
  esac
}

read_lock_owner() {
  LOCK_PID=
  LOCK_TOKEN=
  LOCK_INTERVAL=
  [ -r "$LOCK_DIR/pid" ] && IFS= read -r LOCK_PID < "$LOCK_DIR/pid"
  [ -r "$LOCK_DIR/token" ] && IFS= read -r LOCK_TOKEN < "$LOCK_DIR/token"
  [ -r "$LOCK_DIR/interval" ] && IFS= read -r LOCK_INTERVAL < "$LOCK_DIR/interval"
  [ -n "$LOCK_INTERVAL" ] || LOCK_INTERVAL=unknown
}

lock_owner_is_live() {
  local command_line
  read_lock_owner
  case "$LOCK_PID" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -n "$LOCK_TOKEN" ] || return 1
  kill -0 "$LOCK_PID" 2>/dev/null || return 1
  command_line=$(ps -p "$LOCK_PID" -o command= 2>/dev/null) || return 1
  case "$command_line" in
    *fm-telemetry.sh*record*"$LOCK_TOKEN"*) return 0 ;;
    *) return 1 ;;
  esac
}

remove_stale_lock() {
  rm -f "$LOCK_DIR/pid" "$LOCK_DIR/token" "$LOCK_DIR/interval" 2>/dev/null || return 1
  rmdir "$LOCK_DIR" 2>/dev/null
}

acquire_lock() {
  local attempt=0
  while [ "$attempt" -lt 2 ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      if ! printf '%s\n' "$OWNER_TOKEN" > "$LOCK_DIR/token" ||
        ! printf '%s\n' "$INTERVAL" > "$LOCK_DIR/interval" ||
        ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
        remove_stale_lock >/dev/null 2>&1 || true
        return 1
      fi
      return 0
    fi
    lock_owner_is_live && return 2
    remove_stale_lock || return 1
    attempt=$((attempt + 1))
  done
  return 1
}

release_lock() {
  local pid token
  [ -d "$LOCK_DIR" ] || return 0
  pid=
  token=
  [ -r "$LOCK_DIR/pid" ] && IFS= read -r pid < "$LOCK_DIR/pid"
  [ -r "$LOCK_DIR/token" ] && IFS= read -r token < "$LOCK_DIR/token"
  if [ "$pid" = "$$" ] && [ "$token" = "$OWNER_TOKEN" ]; then
    remove_stale_lock >/dev/null 2>&1 || true
  fi
}

cleanup_snapshot_temps() {
  [ -n "$SNAPSHOT_TMP" ] && rm -f "$SNAPSHOT_TMP"
  [ -n "$SAMPLE_TMP" ] && rm -f "$SAMPLE_TMP"
  [ -n "$PROCESS_TMP" ] && rm -f "$PROCESS_TMP"
  SNAPSHOT_TMP=
  SAMPLE_TMP=
  PROCESS_TMP=
}

cleanup_record() {
  cleanup_snapshot_temps
  release_lock
}

capture_bounded() {
  local label=$1 lines=$2 command_name=$3
  shift 3
  printf '%s\n' "$label" >> "$SNAPSHOT_TMP"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'unavailable: %s not found\n' "$command_name" >> "$SNAPSHOT_TMP"
    return 0
  fi
  if "$command_name" "$@" > "$SAMPLE_TMP" 2>&1; then
    sed -n "1,${lines}p" "$SAMPLE_TMP" >> "$SNAPSHOT_TMP"
  else
    printf 'sampler_failed: %s\n' "$command_name" >> "$SNAPSHOT_TMP"
    sed -n "1,${lines}p" "$SAMPLE_TMP" >> "$SNAPSHOT_TMP"
  fi
}

capture_processes() {
  printf 'PROCESS_TABLE\n' >> "$SNAPSHOT_TMP"
  if ! command -v ps >/dev/null 2>&1 ||
    ! ps -axo pid=,ppid=,pgid=,%cpu=,rss=,etime=,comm= > "$PROCESS_TMP" 2> "$SAMPLE_TMP"; then
    printf 'sampler_failed: ps\n' >> "$SNAPSHOT_TMP"
    sed -n '1,5p' "$SAMPLE_TMP" >> "$SNAPSHOT_TMP"
    return 0
  fi

  {
    awk 'NF { count++ } END { print "PROCESS_TOTAL " count + 0 }' "$PROCESS_TMP"
    printf 'TOP_RSS_KIB pid ppid pgid cpu rss_kib etime command\n'
    sort -k5,5nr -k1,1n "$PROCESS_TMP" | head -n "$TOP_COUNT"
    printf 'TOP_CPU_PERCENT pid ppid pgid cpu rss_kib etime command\n'
    sort -k4,4nr -k1,1n "$PROCESS_TMP" | head -n "$TOP_COUNT"
    printf 'PROCESS_COUNTS_BY_PARENT count ppid\n'
    awk 'NF { count[$2]++ } END { for (id in count) print count[id], id }' "$PROCESS_TMP" \
      | sort -k1,1nr -k2,2n | head -n "$TOP_COUNT"
    printf 'PROCESS_COUNTS_BY_PGID_COALITION_APPROX count pgid\n'
    awk 'NF { count[$3]++ } END { for (id in count) print count[id], id }' "$PROCESS_TMP" \
      | sort -k1,1nr -k2,2n | head -n "$TOP_COUNT"
  } >> "$SNAPSHOT_TMP"
}

append_snapshot() {
  local timestamp epoch day log_file
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
  epoch=$(date '+%s') || return 1
  day=$(date '+%Y-%m-%d') || return 1
  log_file="$TELEMETRY_DIR/telemetry-$day.log"
  SNAPSHOT_TMP=$(mktemp "$TELEMETRY_DIR/.snapshot.XXXXXX") || return 1
  SAMPLE_TMP=$(mktemp "$TELEMETRY_DIR/.sample.XXXXXX") || return 1
  PROCESS_TMP=$(mktemp "$TELEMETRY_DIR/.processes.XXXXXX") || return 1

  printf 'SNAPSHOT_BEGIN schema=%s timestamp=%s epoch=%s recorder_pid=%s\n' \
    "$SNAPSHOT_SCHEMA" "$timestamp" "$epoch" "$$" > "$SNAPSHOT_TMP"
  capture_bounded MEMORY_PRESSURE 20 memory_pressure -Q
  capture_bounded VM_STAT 80 vm_stat
  capture_bounded SWAP_USAGE 10 sysctl vm.swapusage
  capture_processes
  capture_bounded DISK_FREE_KIB 10 df -k /
  printf 'SNAPSHOT_END timestamp=%s\n\n' "$timestamp" >> "$SNAPSHOT_TMP"

  if ! cat "$SNAPSHOT_TMP" >> "$log_file"; then
    cleanup_snapshot_temps
    return 1
  fi
  if ! sync -f "$log_file" >/dev/null 2>&1; then
    printf 'fm-telemetry: sync -f failed for %s\n' "$log_file" >&2
    cleanup_snapshot_temps
    return 1
  fi
  cleanup_snapshot_temps
}

daily_log_bytes() {
  local file total=0 bytes
  for file in "$TELEMETRY_DIR"/telemetry-*.log; do
    [ -f "$file" ] || continue
    bytes=$(wc -c < "$file") || return 1
    total=$((total + bytes))
  done
  printf '%s\n' "$total"
}

prune_daily_logs() {
  local total file removed current_log
  total=$(daily_log_bytes) || return 1
  current_log="telemetry-$(date '+%Y-%m-%d').log"
  while [ "$total" -gt "$MAX_BYTES" ]; do
    removed=0
    for file in "$TELEMETRY_DIR"/telemetry-*.log; do
      [ -f "$file" ] || continue
      if [ "${file##*/}" = "$current_log" ]; then
        continue
      fi
      rm -f "$file" || return 1
      removed=1
      break
    done
    [ "$removed" -eq 1 ] || break
    total=$(daily_log_bytes) || return 1
  done
}

record() {
  local tick_rc
  validate_configuration
  mkdir -p "$TELEMETRY_DIR" || fail "could not create $TELEMETRY_DIR"
  OWNER_TOKEN=${1:-"manual-$(date '+%s')-$$"}
  acquire_lock
  case $? in
    0) ;;
    2) fail "recorder already running" ;;
    *) fail "could not acquire $LOCK_DIR" ;;
  esac
  trap 'cleanup_record; exit 0' TERM INT
  trap cleanup_record EXIT

  while :; do
    tick_rc=0
    if ! append_snapshot; then
      printf 'fm-telemetry: snapshot failed\n' >&2
      tick_rc=1
    fi
    if ! prune_daily_logs; then
      printf 'fm-telemetry: rotation failed\n' >&2
      tick_rc=1
    fi
    if [ "${FM_TELEMETRY_RECORD_ONCE:-0}" = 1 ]; then
      return "$tick_rc"
    fi
    sleep "$INTERVAL" &
    wait "$!" || break
  done
}

arm() {
  local token child_pid tries=0
  validate_configuration
  mkdir -p "$TELEMETRY_DIR" || fail "could not create $TELEMETRY_DIR"
  if lock_owner_is_live; then
    printf 'fm-telemetry: already running pid=%s interval=%ss\n' "$LOCK_PID" "$LOCK_INTERVAL"
    return 0
  fi
  [ ! -d "$LOCK_DIR" ] || remove_stale_lock || fail "could not remove stale lock $LOCK_DIR"
  token="fmtelemetry-$(date '+%s')-$$"
  nohup "$SCRIPT_PATH" record "$token" </dev/null >/dev/null 2>&1 &
  child_pid=$!
  while [ "$tries" -lt 30 ]; do
    if lock_owner_is_live; then
      printf 'fm-telemetry: running pid=%s interval=%ss directory=%s\n' \
        "$LOCK_PID" "$LOCK_INTERVAL" "$TELEMETRY_DIR"
      return 0
    fi
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 0.1
    tries=$((tries + 1))
  done
  wait "$child_pid" 2>/dev/null || true
  fail "recorder did not acquire its lock"
}

disarm() {
  local pid tries=0
  mkdir -p "$TELEMETRY_DIR" || fail "could not create $TELEMETRY_DIR"
  if ! lock_owner_is_live; then
    [ ! -d "$LOCK_DIR" ] || remove_stale_lock || fail "could not remove stale lock $LOCK_DIR"
    printf 'fm-telemetry: not running\n'
    return 0
  fi
  pid=$LOCK_PID
  kill -TERM "$pid" 2>/dev/null || fail "could not signal recorder pid $pid"
  while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    fail "recorder pid $pid did not stop cleanly"
  fi
  [ ! -d "$LOCK_DIR" ] || remove_stale_lock || fail "could not retire $LOCK_DIR"
  printf 'fm-telemetry: stopped pid=%s\n' "$pid"
}

newest_snapshot_age() {
  local newest newest_mtime file mtime now
  newest=
  newest_mtime=0
  for file in "$TELEMETRY_DIR"/telemetry-*.log; do
    [ -f "$file" ] || continue
    mtime=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null) || continue
    if [ "$mtime" -gt "$newest_mtime" ]; then
      newest=$file
      newest_mtime=$mtime
    fi
  done
  [ -n "$newest" ] || {
    printf 'none'
    return 0
  }
  now=$(date '+%s') || {
    printf 'unknown'
    return 0
  }
  printf '%ss' "$((now - newest_mtime))"
}

status() {
  local age
  age=$(newest_snapshot_age)
  if lock_owner_is_live; then
    printf 'fm-telemetry: running pid=%s interval=%ss newest_snapshot_age=%s directory=%s\n' \
      "$LOCK_PID" "$LOCK_INTERVAL" "$age" "$TELEMETRY_DIR"
    return 0
  fi
  printf 'fm-telemetry: not running newest_snapshot_age=%s directory=%s\n' "$age" "$TELEMETRY_DIR"
  return 1
}

case "${1:-}" in
  arm) arm ;;
  disarm) disarm ;;
  status) status ;;
  record) shift; record "${1:-}" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
