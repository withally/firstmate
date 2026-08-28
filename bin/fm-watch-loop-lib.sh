#!/usr/bin/env bash

fm_watch_routine_exit_code() {
  printf '75'
}

fm_watch_reason_is_routine() {
  case "$1" in
    stale:*'declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)') return 0 ;;
    stale:*'verified hold transfer, rechecked on a long cadence not a wedge; answer the held decision or release the hold)') return 0 ;;
    *) return 1 ;;
  esac
}

fm_watch_recovery_queue_is_routine() {
  local queue=$1 epoch seq kind key payload
  [ -f "$queue" ] && [ ! -L "$queue" ] && [ -s "$queue" ] || return 1
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
    case "$seq" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$key" ] || return 1
    [ "$kind" = stale ] || return 1
    fm_watch_reason_is_routine "$payload" || return 1
  done < "$queue"
  return 0
}

fm_watch_cycle_class_for_reason() {
  if fm_watch_reason_is_routine "$1"; then
    printf 'routine'
  else
    printf 'actionable'
  fi
}
