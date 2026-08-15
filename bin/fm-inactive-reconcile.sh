#!/usr/bin/env bash
# Bounded local reconciliation for inactive direct reports with terminal state.
#
# Usage: fm-inactive-reconcile.sh scan [--startup]
#
# scan is interval-gated unless --startup is passed. It reads only local task
# metadata/status/turn-ended files plus bin/fm-crew-state.sh, the current-state
# authority. Only ordinary direct reports confirmed as done or failed qualify.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CREW_STATE_BIN="${FM_INACTIVE_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
SCAN_MARKER="$STATE/.inactive-outcome-reconcile"
SCAN_LOCK="$STATE/.inactive-outcome-reconcile.lock"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-inactive-reconcile-lib.sh
. "$SCRIPT_DIR/fm-inactive-reconcile-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"

FM_INACTIVE_RECONCILE_SECS=${FM_INACTIVE_RECONCILE_SECS:-900}
FM_INACTIVE_RECONCILE_BUDGET_SECS=${FM_INACTIVE_RECONCILE_BUDGET_SECS:-10}
case "$FM_INACTIVE_RECONCILE_SECS" in
  ''|*[!0-9]*) printf 'fm-inactive-reconcile: cadence must be 60..1800 seconds\n' >&2; exit 2 ;;
esac
if [ "$FM_INACTIVE_RECONCILE_SECS" -lt 60 ] || [ "$FM_INACTIVE_RECONCILE_SECS" -gt 1800 ]; then
  printf 'fm-inactive-reconcile: cadence must be 60..1800 seconds\n' >&2
  exit 2
fi
case "$FM_INACTIVE_RECONCILE_BUDGET_SECS" in
  ''|*[!0-9]*|0) printf 'fm-inactive-reconcile: budget must be 1..30 seconds\n' >&2; exit 2 ;;
esac
if [ "$FM_INACTIVE_RECONCILE_BUDGET_SECS" -gt 30 ]; then
  printf 'fm-inactive-reconcile: budget must be 1..30 seconds\n' >&2
  exit 2
fi

if [ "$(uname)" = Darwin ]; then
  file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

valid_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-1200
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 32)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 32)}'
  else
    printf '%s' "$1" | cksum | awk '{printf "%08x%08x%08x%08x\n", $1, $2, $1, $2}'
  fi
}

meta_value() { # <meta> <key>
  awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { print value }' "$1" 2>/dev/null
}

incarnation_for() { # <meta>
  local meta=$1 value identity
  value=$(meta_value "$meta" spawn_gen)
  if valid_id "$value"; then
    printf '%s\n' "$value"
    return
  fi
  identity=$(meta_value "$meta" tasktmp)
  [ -n "$identity" ] || identity="$(meta_value "$meta" window)|$(meta_value "$meta" worktree)"
  printf 'legacy-%s\n' "$(sha256_text "$identity")"
}

newest_activity_age() { # <path>...
  local newest=0 m path now
  now=$(date +%s)
  for path in "$@"; do
    [ -e "$path" ] || continue
    m=$(file_mtime "$path" 2>/dev/null || true)
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -le "$newest" ] || newest=$m
  done
  [ "$newest" -gt 0 ] || { printf '0\n'; return; }
  [ "$newest" -le "$now" ] || { printf '0\n'; return; }
  printf '%s\n' "$((now - newest))"
}

queue_has_key() { # <key>
  fm_wake_queued_keys check 2>/dev/null | grep -Fx -- "$1" >/dev/null 2>&1
}

secondmate_home_id() {
  local marker="$FM_HOME/.fm-secondmate-home" id
  [ -e "$marker" ] || [ -L "$marker" ] || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  [ "$(wc -c < "$marker")" -eq "$(tr -d '\0' < "$marker" | wc -c)" ] || return 2
  id=$(cat "$marker" 2>/dev/null) || return 2
  valid_id "$id" || return 2
  printf '%s\n' "$id"
}

append_status_once() { # <path> <line>
  local path=$1 line=$2 dir
  [ ! -L "$path" ] || return 1
  dir=$(dirname "$path")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  grep -Fqx -- "$line" "$path" 2>/dev/null && return 0
  printf '%s\n' "$line" >> "$path"
}

pr_for() { # <meta> <last-status>
  local pr last_status=$2
  pr=$(meta_value "$1" pr)
  if [ -z "$pr" ]; then
    pr=$(printf '%s\n' "$last_status" | grep -Eo 'https://[^[:space:]]+/(pull|merge_requests)/[0-9]+' | head -n 1)
  fi
  clean_field "$pr"
}

report_to_parent() { # <self> <task> <terminal-state> <fingerprint> <pr>
  local self=$1 task=$2 terminal_state=$3 fingerprint=$4 pr=$5 record destination key line
  record="$FM_HOME/.fm-secondmate-parent"
  fm_secondmate_parent_record_parse "$record" || return 1
  case "$FM_SECONDMATE_PARENT_ROUTE" in
    local) destination="$FM_SECONDMATE_PARENT_HOME/state/$self.status" ;;
    remote) destination="$STATE/parent-replies.status" ;;
    *) return 1 ;;
  esac
  key="inactive-outcome-$self-$task-$terminal_state"
  line="$terminal_state [key=$key]: inactive terminal child=$task fingerprint=$fingerprint"
  [ -z "$pr" ] || line="$line pr=$pr"
  append_status_once "$destination" "$line"
}

reconcile_child_locked() { # <id> <meta> <timeout> <secondmate-id-or-empty>
  local id=$1 meta=$2 timeout=$3 self=${4:-} kind status turn last age current terminal_state pr incarnation fingerprint key payload phase rc=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(meta_value "$meta" kind)
  [ "$kind" != secondmate ] || return 0
  status="$STATE/$id.status"
  turn="$STATE/$id.turn-ended"
  last=$(last_status_line "$status")
  [ "$(status_line_verb "$last")" != captain-held ] || return 0
  age=$(newest_activity_age "$meta" "$status" "$turn")
  [ "$age" -ge "$FM_INACTIVE_RECONCILE_SECS" ] || return 0
  current=$(fm_run_timed "$timeout" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$CREW_STATE_BIN" "$id" 2>/dev/null) || rc=$?
  [ "$rc" -ne 124 ] || return 3
  case "$current" in
    'state: done '*) terminal_state='done' ;;
    'state: failed '*) terminal_state='failed' ;;
    *) return 0 ;;
  esac
  pr=$(pr_for "$meta" "$last")
  incarnation=$(incarnation_for "$meta")
  last=$(clean_field "$last")
  fingerprint=$(sha256_text "$incarnation|$id|$terminal_state|$pr|$last")
  phase=presentation
  [ -z "$self" ] || phase=parent-report
  fm_inactive_record_ensure "$STATE" "$fingerprint" "$id" "$incarnation" \
    "$terminal_state" "$phase" "$last" "$pr" || return 1
  [ -n "$FM_INACTIVE_PENDING" ] || return 0
  if [ -n "$self" ]; then
    if report_to_parent "$self" "$id" "$terminal_state" "$fingerprint" "$pr"; then
      fm_inactive_receipt_close_reported "$STATE" "$fingerprint"
      return
    fi
    key="inactive-reconcile:$fingerprint"
    queue_has_key "$key" && return 0
    payload="inactive terminal outcome needs parent-route repair: child=$id state=$terminal_state"
    fm_wake_append check "$key" "$payload" || return 1
    printf 'actionable: %s\n' "$payload"
    return 0
  fi
  key="inactive-outcome:$fingerprint"
  queue_has_key "$key" && return 0
  payload="inactive terminal outcome awaiting captain presentation: child=$id state=$terminal_state"
  [ -z "$pr" ] || payload="$payload pr=$pr"
  fm_wake_append check "$key" "$payload" || return 1
  printf 'actionable: %s\n' "$payload"
}

reconcile_child() { # <id> <meta> <timeout> <secondmate-id-or-empty>
  local id=$1 meta=$2 timeout=$3 self=${4:-} lock rc=0
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  reconcile_child_locked "$id" "$meta" "$timeout" "$self" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

scan_marker_cursor() {
  [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || return 0
  awk -F= '$1 == "cursor" { value=$2 } END { print value }' "$SCAN_MARKER" 2>/dev/null
}

write_scan_marker() { # <cursor>
  local cursor=$1 tmp
  tmp=$(mktemp "$STATE/.inactive-outcome-reconcile.XXXXXX") || return 1
  {
    printf 'epoch=%s\n' "$(date +%s)"
    printf 'cursor=%s\n' "$cursor"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$SCAN_MARKER" || { rm -f "$tmp"; return 1; }
}

scan_range() { # <cursor> <after|through> <deadline> <secondmate-id-or-empty>
  local cursor=$1 range=$2 deadline=$3 self=${4:-} meta id remaining rc=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    case "$range" in
      after) [ -z "$cursor" ] || [[ "$id" > "$cursor" ]] || continue ;;
      through) [ -n "$cursor" ] && [[ "$id" > "$cursor" ]] && continue ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || return 3
    write_scan_marker "$id" || return 1
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || return 3
    reconcile_child "$id" "$meta" "$remaining" "$self" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
  done
}

scan_locked() { # <startup:0|1>
  local startup=$1 cursor deadline self='' marker_rc=0 rc=0 age
  [ ! -L "$STATE" ] && [ ! -L "$STATE/terminal-outcomes" ] || return 1
  mkdir -p "$STATE" "$STATE/terminal-outcomes" || return 1
  [ -d "$STATE/terminal-outcomes" ] && [ ! -L "$STATE/terminal-outcomes" ] || return 1
  if [ "$startup" != 1 ] && [ -e "$SCAN_MARKER" ]; then
    age=$(newest_activity_age "$SCAN_MARKER")
    [ "$age" -ge "$FM_INACTIVE_RECONCILE_SECS" ] || return 0
  fi
  cursor=$(scan_marker_cursor)
  valid_id "$cursor" || cursor=''
  write_scan_marker "$cursor" || return 1
  if self=$(secondmate_home_id); then
    :
  else
    marker_rc=$?
    self=''
    if [ "$marker_rc" -ne 1 ]; then
      printf 'actionable: inactive terminal outcomes remain unreconciled: invalid secondmate identity\n'
      return 0
    fi
  fi
  deadline=$(( $(date +%s) + FM_INACTIVE_RECONCILE_BUDGET_SECS ))
  scan_range "$cursor" after "$deadline" "$self" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$cursor" ]; then
    scan_range "$cursor" through "$deadline" "$self" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    write_scan_marker ''
  elif [ "$rc" -eq 3 ]; then
    return 0
  else
    return "$rc"
  fi
}

mode=${1:-scan}
case "$mode" in
  scan)
    startup=0
    case "${2:-}" in '') ;; --startup) startup=1 ;; *) exit 2 ;; esac
    fm_run_timed "$FM_INACTIVE_RECONCILE_BUDGET_SECS" "$0" _scan-locked "$startup"
    rc=$?
    [ "$rc" -eq 124 ] || exit "$rc"
    ;;
  _scan-locked)
    [ "$#" -eq 2 ] || exit 2
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    scan_locked "$2"
    ;;
  -h|--help)
    sed -n '2,9{s/^# \{0,1\}//;p;}' "$0"
    ;;
  *)
    printf 'usage: fm-inactive-reconcile.sh scan [--startup]\n' >&2
    exit 2
    ;;
esac
