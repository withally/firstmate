#!/usr/bin/env bash
# Keep Grok's one tracked supervision task open across routine declared-wait
# rechecks. The task completes only for an actionable watcher result or a
# failure, so Grok does not inject billed task_completed prompts for quiet
# cycles.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARM="$SCRIPT_DIR/fm-watch-arm.sh"
STATE="${FM_STATE_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}/state}"
mkdir -p "$STATE"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
# shellcheck source=bin/fm-watch-loop-lib.sh
. "$SCRIPT_DIR/fm-watch-loop-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
out=
active_arm=
predecessor_arm=
finished_arm=

cleanup() {
  [ -n "$out" ] && rm -f "$out" 2>/dev/null || true
}
handle_signal() {
  local signal=$1 exit_status=$2
  trap - HUP TERM INT
  if [ -n "$active_arm" ]; then
    kill "-$signal" "$active_arm" 2>/dev/null || true
    wait "$active_arm" 2>/dev/null || true
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal TERM 143' TERM
trap 'handle_signal INT 130' INT

routine_declared_wait() {
  local out=$1 count reason open unread
  count=$(grep -Ec '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  reason=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null | head -1 || true)
  case "$reason" in
    'check: rearm-resurface')
      fm_watch_recovery_queue_is_routine "$FM_WAKE_QUEUE" || return 1
      open=$(scan_open_decisions_incremental "$STATE") || return 1
      unread=$(scan_unread_surface_lines "$STATE") || return 1
      [ -z "$open" ] && [ -z "$unread" ]
      ;;
    *)
      fm_watch_reason_is_routine "$reason"
      ;;
  esac
}

while :; do
  out=$(mktemp "$STATE/.grok-watch-longrun.XXXXXX") || {
    echo "watcher: FAILED - Grok long-runner could not allocate cycle output"
    exit 1
  }
  status=0
  if [ -n "$predecessor_arm" ]; then
    FM_WATCH_GROK_LONGRUN=1 FM_WATCH_PREDECESSOR_ARM_PID="$predecessor_arm" \
      "$ARM" >"$out" 2>&1 &
  else
    FM_WATCH_GROK_LONGRUN=1 "$ARM" >"$out" 2>&1 &
  fi
  active_arm=$!
  wait "$active_arm" || status=$?
  finished_arm=$active_arm
  active_arm=
  if [ "$status" -eq "$(fm_watch_routine_exit_code)" ]; then
    predecessor_arm=$finished_arm
    rm -f "$out"
    out=
    continue
  fi
  if [ "$status" -ne 0 ]; then
    cat "$out"
    rm -f "$out"
    out=
    exit "$status"
  fi
  if routine_declared_wait "$out"; then
    predecessor_arm=$finished_arm
    rm -f "$out"
    out=
    continue
  fi
  cat "$out"
  rm -f "$out"
  out=
  exit 0
done
