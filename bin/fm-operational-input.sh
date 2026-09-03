#!/usr/bin/env bash
# fm-operational-input.sh - canonical Firstmate operational-input protocol.
#
# This file is both a source-safe shell library and the cross-language CLI used
# by JavaScript and TypeScript integrations. It is the single owner of current
# construction, current parsing, and narrow pre-protocol transcript parsing.
#
# Current generic wire form:
#   U+2063 FIRSTMATE_OP: v1 <kind>: <body> [<worker-recipient-mark><silent-reply-carrier>]
#
# The landed U+2063 + "FIRSTMATE_OP: " prefix is permanent compatibility.
# The version and kind header make current inputs structurally typed without
# deriving provenance from body prose. The established from-firstmate routing
# marker remains a current compatibility carrier because already-running
# secondmates have its leading label in their charter context.
#
# CLI:
#   fm-operational-input.sh encode <kind> [recipient]  # body on stdin
#   fm-operational-input.sh kind           # current input on stdin, kind stdout
#   fm-operational-input.sh classify       # current or legacy input on stdin
#   fm-operational-input.sh body           # current generic input on stdin
#   fm-operational-input.sh --help
#
# All successful data commands print exactly one value and no diagnostics.
# A non-match exits 1 silently. Invalid use exits 2. Bash 3.2 compatible.

FM_OPERATIONAL_MARK=$'\xE2\x81\xA3'
FM_OPERATIONAL_PREFIX="${FM_OPERATIONAL_MARK}FIRSTMATE_OP: "
FM_OPERATIONAL_VERSION=v1
FM_OPERATIONAL_HEADER_PREFIX="${FM_OPERATIONAL_PREFIX}${FM_OPERATIONAL_VERSION} "
FM_OPERATIONAL_KINDS='session-start watcher turn-end-guard away-supervisor launch-brief branch-outcome'
FM_OPERATIONAL_WORKER_RECIPIENT_MARK=$'\xE2\x81\xA4'
FM_OPERATIONAL_SILENT_REPLY_RULE='Handle FIRSTMATE_OP digests, doorbells, steers, and marked from-firstmate requests silently: never emit assistant or chat text, including acknowledgements, summaries, or idle notices; after the required status-file append, or no action, end with an empty assistant response; "captain" is reserved for the main firstmate.'
FM_OPERATIONAL_SILENT_REPLY_CARRIER=" ${FM_OPERATIONAL_MARK}${FM_OPERATIONAL_SILENT_REPLY_RULE}"
FM_OPERATIONAL_WORKER_CARRIER="${FM_OPERATIONAL_WORKER_RECIPIENT_MARK}${FM_OPERATIONAL_SILENT_REPLY_CARRIER}"

# Compatibility name retained for the away-mode owner and its tests.
# shellcheck disable=SC2034 # Public source-library variable used by callers.
FM_INJECT_MARK=$FM_OPERATIONAL_MARK

# The from-firstmate carrier stays byte-compatible with live secondmate charter
# context while this owner supplies its construction and structural kind.
FM_FROMFIRST_LABEL='[fm-from-firstmate]'
FM_FROMFIRST_SEPARATOR=$FM_OPERATIONAL_MARK
FM_FROMFIRST_MARK="${FM_FROMFIRST_LABEL}${FM_FROMFIRST_SEPARATOR}"

fm_operational_kind_is_current() {  # <kind>
  case " $FM_OPERATIONAL_KINDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

fm_operational_input_carrier_for_recipient() {  # <recipient> <result-var>
  local recipient=${1:-main} result_var=${2-}
  [ -n "$result_var" ] || return 2
  case "$recipient" in
    crewmate|secondmate)
      printf -v "$result_var" '%s' "$FM_OPERATIONAL_WORKER_CARRIER"
      ;;
    main)
      printf -v "$result_var" '%s' ''
      ;;
    *) return 2 ;;
  esac
}

fm_operational_input_encode() {  # <generic-kind> <body> <result-var> [recipient]
  local kind=${1-} body=${2-} result_var=${3-} recipient=${4:-main} carrier
  [ -n "$result_var" ] || return 2
  fm_operational_kind_is_current "$kind" || return 2
  [ -n "$body" ] || return 2
  fm_operational_input_carrier_for_recipient "$recipient" carrier || return 2
  printf -v "$result_var" '%s%s: %s%s' "$FM_OPERATIONAL_HEADER_PREFIX" "$kind" "$body" "$carrier"
}

fm_operational_input_construct() {  # <kind> <body> <result-var> [recipient]
  local kind=${1-} body=${2-} result_var=${3-} recipient=${4:-main}
  [ -n "$result_var" ] && [ -n "$body" ] || return 2
  if [ "$kind" = from-firstmate ]; then
    fm_message_mark_from_firstmate "$body" "$result_var" "$recipient"
    return
  fi
  fm_operational_input_encode "$kind" "$body" "$result_var" "$recipient"
}

fm_operational_generic_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} remainder parsed_kind body
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$FM_OPERATIONAL_HEADER_PREFIX"*': '?*) ;;
    *) return 1 ;;
  esac
  remainder=${message#"$FM_OPERATIONAL_HEADER_PREFIX"}
  parsed_kind=${remainder%%': '*}
  fm_operational_kind_is_current "$parsed_kind" || return 1
  body=${remainder#"${parsed_kind}: "}
  [ "$body" != "$remainder" ] && [ -n "$body" ] || return 1
  printf -v "$result_var" '%s' "$parsed_kind"
}

fm_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} current_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_generic_kind "$message" current_kind; then
    printf -v "$result_var" '%s' "$current_kind"
    return 0
  fi
  case "$message" in
    "$FM_FROMFIRST_MARK"?*)
      printf -v "$result_var" '%s' from-firstmate
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_body() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} current_kind parsed_body
  [ -n "$result_var" ] || return 2
  if fm_operational_generic_kind "$message" current_kind; then
    parsed_body=${message#"${FM_OPERATIONAL_HEADER_PREFIX}${current_kind}: "}
    case "$parsed_body" in
      *"$FM_OPERATIONAL_WORKER_CARRIER")
        parsed_body=${parsed_body%"$FM_OPERATIONAL_WORKER_CARRIER"}
        ;;
    esac
    printf -v "$result_var" '%s' "$parsed_body"
    return 0
  fi
  case "$message" in
    "$FM_FROMFIRST_MARK"?*)
      parsed_body=${message#"$FM_FROMFIRST_MARK"}
      case "$parsed_body" in
        *"$FM_OPERATIONAL_WORKER_CARRIER")
          parsed_body=${parsed_body%"$FM_OPERATIONAL_WORKER_CARRIER"}
          ;;
      esac
      printf -v "$result_var" '%s' "$parsed_body"
      return 0
      ;;
  esac
  return 1
}

# Historical payload literals are intentionally isolated below this line.
# They exist only for persisted pre-protocol transcripts and must never be used
# by current producers or current-path tests.
# shellcheck disable=SC2016 # Backticks are literal historical prompt markup.
FM_LEGACY_SESSIONSTART='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
FM_LEGACY_WATCHER_PREFIX='FIRSTMATE WATCHER WAKE: '
FM_LEGACY_WATCHER_SUFFIX=$'\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.'
FM_LEGACY_TURNEND_PREFIX=$'TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n'
FM_LEGACY_AWAY_PREFIX="${FM_OPERATIONAL_MARK}Supervisor escalate ("

fm_legacy_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-}
  [ -n "$result_var" ] || return 2

  # PR 899 landed an untyped FIRSTMATE_OP prefix. Its subtype cannot be
  # recovered without body prose, so it is explicitly generic.
  case "$message" in
    "$FM_OPERATIONAL_PREFIX"?*)
      printf -v "$result_var" '%s' legacy-operational
      return 0
      ;;
  esac

  if [ "$message" = "$FM_LEGACY_SESSIONSTART" ]; then
    printf -v "$result_var" '%s' session-start
    return 0
  fi
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

fm_message_from_firstmate() {  # <message>
  local kind
  fm_operational_input_kind "${1-}" kind && [ "$kind" = from-firstmate ]
}

fm_message_mark_from_firstmate() {  # <message> <result-var> [recipient]
  local message=${1-} result_var=${2-} recipient=${3:-main} carrier transformed
  [ -n "$result_var" ] || return 2
  fm_operational_input_carrier_for_recipient "$recipient" carrier || return 2
  if fm_message_from_firstmate "$message"; then
    if [ -n "$carrier" ]; then
      case "$message" in
        *"$FM_OPERATIONAL_WORKER_CARRIER") transformed=$message ;;
        *) transformed="${message}${carrier}" ;;
      esac
    else
      case "$message" in
        *"$FM_OPERATIONAL_WORKER_CARRIER") transformed=${message%"$FM_OPERATIONAL_WORKER_CARRIER"} ;;
        *) transformed=$message ;;
      esac
    fi
  else
    transformed="${FM_FROMFIRST_MARK}${message}${carrier}"
  fi
  printf -v "$result_var" '%s' "$transformed"
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
  bin/fm-operational-input.sh encode <kind> [recipient]  # body on stdin
  bin/fm-operational-input.sh kind           # current input on stdin
  bin/fm-operational-input.sh classify       # current or legacy input on stdin
  bin/fm-operational-input.sh body           # current input on stdin

Current construction kinds:
  session-start watcher turn-end-guard away-supervisor from-firstmate launch-brief
  branch-outcome

The from-firstmate kind uses its established live-charter-compatible carrier.
Recipients are main (the default), crewmate, or secondmate.
EOF
}

fm_operational_main() {
  local command=${1-} argument=${2-} recipient=${3:-main} input output
  case "$command" in
    -h|--help|help)
      fm_operational_usage
      ;;
    encode)
      [ "$#" -ge 2 ] && [ "$#" -le 3 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_construct "$argument" "$input" output "$recipient" || return 2
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
