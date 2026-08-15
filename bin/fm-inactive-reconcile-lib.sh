#!/usr/bin/env bash
# Receipt mechanics for bin/fm-inactive-reconcile.sh and fm-wake-drain.sh.
#
# A main-home receipt starts as <fingerprint>.pending with phase=presentation.
# The generation-bound post-handling path in fm-wake-drain.sh is the only caller
# allowed to close it as <fingerprint>.presented. The drain closes the receipt
# before consuming the corresponding wake, so interruption may leave both a
# closed receipt and a queued wake but can never leave neither.

fm_inactive_record_path() { # <state> <fingerprint> <suffix>
  printf '%s/terminal-outcomes/%s.%s\n' "$1" "$2" "$3"
}

fm_inactive_record_value() { # <record> <key>
  local record=$1 key=$2
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { print value }' "$record"
}

fm_inactive_record_ensure() { # <state> <fingerprint> <task> <incarnation> <terminal-state> <phase> <last-status> <pr>
  local state=$1 fingerprint=$2 task=$3 incarnation=$4 terminal_state=$5 phase=$6 last_status=$7 pr=$8
  local dir pending presented reported tmp
  dir="$state/terminal-outcomes"
  pending=$(fm_inactive_record_path "$state" "$fingerprint" pending)
  presented=$(fm_inactive_record_path "$state" "$fingerprint" presented)
  reported=$(fm_inactive_record_path "$state" "$fingerprint" reported)
  FM_INACTIVE_PENDING=
  [ ! -L "$pending" ] && [ ! -L "$presented" ] && [ ! -L "$reported" ] || return 1
  if { [ -f "$presented" ] && [ ! -L "$presented" ]; } \
    || { [ -f "$reported" ] && [ ! -L "$reported" ]; }; then
    return 0
  fi
  [ ! -e "$presented" ] && [ ! -e "$reported" ] || return 1
  if [ -f "$pending" ] && [ ! -L "$pending" ]; then
    FM_INACTIVE_PENDING=$pending
    return 0
  fi
  [ ! -e "$pending" ] || return 1
  [ ! -L "$dir" ] || return 1
  mkdir -p "$dir" || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  tmp=$(mktemp "$dir/.pending.XXXXXX") || return 1
  {
    printf 'schema=fm-terminal-outcome.v1\n'
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'task_id=%s\n' "$task"
    printf 'incarnation=%s\n' "$incarnation"
    printf 'state=%s\n' "$terminal_state"
    printf 'origin=direct\n'
    printf 'phase=%s\n' "$phase"
    printf 'pr=%s\n' "$pr"
    printf 'last_status=%s\n' "$last_status"
    printf 'created_epoch=%s\n' "$(date +%s)"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$pending" || { rm -f "$tmp"; return 1; }
  # shellcheck disable=SC2034 # read by bin/fm-inactive-reconcile.sh after sourcing.
  FM_INACTIVE_PENDING=$pending
}

fm_inactive_receipt_close_presented() { # <state> <fingerprint>
  local state=$1 fingerprint=$2 pending presented phase
  case "$fingerprint" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  pending=$(fm_inactive_record_path "$state" "$fingerprint" pending)
  presented=$(fm_inactive_record_path "$state" "$fingerprint" presented)
  if [ -f "$presented" ] && [ ! -L "$presented" ]; then
    return 0
  fi
  [ ! -e "$presented" ] && [ ! -L "$presented" ] || return 1
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  phase=$(fm_inactive_record_value "$pending" phase)
  [ "$phase" = presentation ] || return 1
  mv -f -- "$pending" "$presented"
}

fm_inactive_receipt_close_reported() { # <state> <fingerprint>
  local state=$1 fingerprint=$2 pending reported phase
  case "$fingerprint" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  pending=$(fm_inactive_record_path "$state" "$fingerprint" pending)
  reported=$(fm_inactive_record_path "$state" "$fingerprint" reported)
  if [ -f "$reported" ] && [ ! -L "$reported" ]; then
    return 0
  fi
  [ ! -e "$reported" ] && [ ! -L "$reported" ] || return 1
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  phase=$(fm_inactive_record_value "$pending" phase)
  [ "$phase" = parent-report ] || return 1
  mv -f -- "$pending" "$reported"
}
