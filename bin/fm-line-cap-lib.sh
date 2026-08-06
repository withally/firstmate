#!/usr/bin/env bash
# shellcheck shell=bash
# Per-line cap for agent-facing session-start digest lines.
# Usage: . bin/fm-line-cap-lib.sh; fm_cap_line "<line>" [<max>]

FM_LINE_CAP_DEFAULT=220
FM_LINE_CAP_SUFFIX=' [truncated]'

fm_cap_line_var() {
  local line=$1 max=${2:-$FM_LINE_CAP_DEFAULT} keep
  if [ "${#line}" -le "$max" ]; then
    FM_LINE_CAP_LINE=$line
    return 0
  fi
  keep=$((max - ${#FM_LINE_CAP_SUFFIX}))
  [ "$keep" -ge 0 ] || keep=0
  FM_LINE_CAP_LINE="${line:0:$keep}$FM_LINE_CAP_SUFFIX"
}

fm_cap_line() {
  fm_cap_line_var "$@"
  printf '%s\n' "$FM_LINE_CAP_LINE"
}
