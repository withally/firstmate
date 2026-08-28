#!/usr/bin/env bash

fm_watch_routine_exit_code() {
  printf '75'
}

fm_watch_routine_handoff_marker() {
  printf '%s\n' 'watcher: routine-handoff-ok'
}

fm_watch_output_has_routine_handoff() {
  local output=$1
  grep -qFx "$(fm_watch_routine_handoff_marker)" "$output" 2>/dev/null
}

fm_watch_reason_is_routine() {
  case "$1" in
    stale:*'declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)') return 0 ;;
    stale:*'verified hold transfer, rechecked on a long cadence not a wedge; answer the held decision or release the hold)') return 0 ;;
    *) return 1 ;;
  esac
}

fm_watch_recovery_queue_boundary() {
  local state=$1 seq_file="$1/.wake-queue.seq" seq
  if [ ! -e "$seq_file" ] && [ ! -L "$seq_file" ]; then
    printf '0'
    return 0
  fi
  [ -f "$seq_file" ] && [ ! -L "$seq_file" ] || return 1
  seq=$(cat "$seq_file" 2>/dev/null) || return 1
  case "$seq" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s' "$seq" ;;
  esac
}

fm_watch_recovery_queue_class_after() {
  local queue=$1 boundary=$2 line epoch seq kind key payload found=0 class=routine
  case "$boundary" in ''|*[!0-9]*) return 1 ;; esac
  if [ ! -e "$queue" ] && [ ! -L "$queue" ]; then
    printf 'none'
    return 0
  fi
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 1
  if [ ! -s "$queue" ]; then
    printf 'none'
    return 0
  fi
  while :; do
    line=
    if ! IFS= read -r line; then
      [ -n "$line" ] || break
    fi
    epoch=
    seq=
    kind=
    key=
    payload=
    IFS=$(printf '\t') read -r epoch seq kind key payload <<< "$line"
    case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
    case "$seq" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$key" ] || return 1
    if [ "$seq" -le "$boundary" ]; then
      continue
    fi
    found=1
    if [ "$kind" != stale ] || ! fm_watch_reason_is_routine "$payload"; then
      class=actionable
    fi
  done < "$queue" || return 1
  [ "$found" -eq 1 ] || class=none
  printf '%s' "$class"
}

fm_watch_recovery_queue_is_routine() {
  local class
  class=$(fm_watch_recovery_queue_class_after "$1" 0) || return 1
  [ "$class" = routine ]
}

fm_watch_cycle_class_for_reason() {
  if fm_watch_reason_is_routine "$1"; then
    printf 'routine'
  else
    printf 'actionable'
  fi
}
