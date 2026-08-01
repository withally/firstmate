#!/usr/bin/env bash
# fm-operational-input.sh - exact Firstmate operational-input protocol owner.
#
# Current generic wire form:
#   U+2063 FIRSTMATE_OP: v1 <kind>: <body>
#
# Current away-mode wire form:
#   0x1f + the generic away-supervisor envelope above
#
# The leading 0x1f remains the away-return sentinel.
# The inner typed envelope exists only for presentation classification.
# This source-safe Bash 3.2 library also provides the cross-language CLI.

FM_OPERATIONAL_MARK=$'\xE2\x81\xA3'
FM_AFK_SENTINEL=$'\x1f'
FM_OPERATIONAL_PREFIX="${FM_OPERATIONAL_MARK}FIRSTMATE_OP: "
FM_OPERATIONAL_VERSION=v1
FM_OPERATIONAL_HEADER_PREFIX="${FM_OPERATIONAL_PREFIX}${FM_OPERATIONAL_VERSION} "
FM_OPERATIONAL_KINDS='watcher turn-end-guard away-supervisor'

fm_operational_kind_is_current() {  # <kind>
  case " $FM_OPERATIONAL_KINDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

fm_operational_input_encode() {  # <kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] || return 2
  fm_operational_kind_is_current "$kind" || return 2
  [ -n "$body" ] || return 2
  printf -v "$result_var" '%s%s: %s' "$FM_OPERATIONAL_HEADER_PREFIX" "$kind" "$body"
}

fm_operational_generic_kind() {  # <generic-message> <result-var>
  local message=${1-} result_var=${2-} remainder candidate body
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$FM_OPERATIONAL_HEADER_PREFIX"*': '?*) ;;
    *) return 1 ;;
  esac
  remainder=${message#"$FM_OPERATIONAL_HEADER_PREFIX"}
  candidate=${remainder%%': '*}
  fm_operational_kind_is_current "$candidate" || return 1
  body=${remainder#"${candidate}: "}
  [ "$body" != "$remainder" ] && [ -n "$body" ] || return 1
  printf -v "$result_var" '%s' "$candidate"
}

fm_operational_input_kind() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} inner found_kind
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$FM_AFK_SENTINEL"*)
      inner=${message#"$FM_AFK_SENTINEL"}
      fm_operational_generic_kind "$inner" found_kind || return 1
      [ "$found_kind" = away-supervisor ] || return 1
      ;;
    *)
      fm_operational_generic_kind "$message" found_kind || return 1
      [ "$found_kind" != away-supervisor ] || return 1
      ;;
  esac
  printf -v "$result_var" '%s' "$found_kind"
}

fm_operational_input_body() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} inner parsed_kind parsed_body
  [ -n "$result_var" ] || return 2
  inner=$message
  case "$inner" in
    "$FM_AFK_SENTINEL"*) inner=${inner#"$FM_AFK_SENTINEL"} ;;
  esac
  fm_operational_input_kind "$message" parsed_kind || return 1
  parsed_body=${inner#"${FM_OPERATIONAL_HEADER_PREFIX}${parsed_kind}: "}
  [ "$parsed_body" != "$inner" ] && [ -n "$parsed_body" ] || return 1
  printf -v "$result_var" '%s' "$parsed_body"
}

# Historical payloads are isolated here and are never accepted by the current parser.
FM_LEGACY_WATCHER_PREFIX='FIRSTMATE WATCHER WAKE: '
FM_LEGACY_WATCHER_SUFFIX=$'\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.'
FM_LEGACY_TURNEND_PREFIX=$'TURN WOULD END BLIND - supervision is off. Resume supervision according to the session-start operating block before ending the turn.\n\n'
FM_LEGACY_AWAY_PREFIX="${FM_AFK_SENTINEL}Supervisor escalate ("

fm_legacy_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-}
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$FM_LEGACY_AWAY_PREFIX"*)
      printf -v "$result_var" '%s' away-supervisor
      return 0
      ;;
    "$FM_LEGACY_WATCHER_PREFIX"*"$FM_LEGACY_WATCHER_SUFFIX")
      [ "${#message}" -gt "$(( ${#FM_LEGACY_WATCHER_PREFIX} + ${#FM_LEGACY_WATCHER_SUFFIX} ))" ] || return 1
      printf -v "$result_var" '%s' watcher
      return 0
      ;;
    "$FM_LEGACY_TURNEND_PREFIX"?*)
      printf -v "$result_var" '%s' turn-end-guard
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_classify() {  # <message> <result-var>
  local message=${1-} result_var=${2-} classified_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_input_kind "$message" classified_kind ||
     fm_legacy_operational_input_kind "$message" classified_kind; then
    printf -v "$result_var" '%s' "$classified_kind"
    return 0
  fi
  return 1
}

fm_operational_read_stdin() {  # <result-var>
  local result_var=${1-} value
  [ -n "$result_var" ] || return 2
  value=$(cat; printf x)
  value=${value%x}
  printf -v "$result_var" '%s' "$value"
}

fm_operational_usage() {
  cat <<'EOF'
Usage:
  bin/fm-operational-input.sh encode <kind>  # body on stdin
  bin/fm-operational-input.sh kind           # current input on stdin
  bin/fm-operational-input.sh classify       # current or exact legacy input on stdin
  bin/fm-operational-input.sh body           # current input on stdin

Current kinds:
  watcher turn-end-guard away-supervisor

Away-mode callers prepend the existing 0x1f sentinel to the encoded envelope.
EOF
}

fm_operational_main() {
  local command=${1-} argument=${2-} input output
  case "$command" in
    -h|--help|help)
      fm_operational_usage
      ;;
    encode)
      [ "$#" -eq 2 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_encode "$argument" "$input" output || return 2
      printf '%s' "$output"
      ;;
    kind)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_kind "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    classify)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_classify "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    body)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_body "$input" output || return 1
      printf '%s' "$output"
      ;;
    *)
      fm_operational_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_operational_main "$@"
  exit $?
fi
