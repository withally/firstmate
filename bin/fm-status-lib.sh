#!/usr/bin/env bash
# Shared generated worker status-protocol wording.

fm_status_wake_reminder() {
  printf '%s\n' \
    'Each status-file append wakes the supervisor and costs a full supervision turn.' \
    'Append only when this protocol requires it; never use status as a progress log.'
}

fm_status_working_rule() {  # <scout|no-mistakes|direct-PR|local-only>
  local kind=$1
  case "$kind" in
    scout)
      # shellcheck disable=SC2016 # Backticks are literal status-protocol text.
      printf '%s\n' 'Append `working:` only for a genuine phase change the supervisor would act on: starting the investigation, entering a distinct research phase, or beginning report writing.'
      ;;
    no-mistakes|direct-PR)
      # shellcheck disable=SC2016 # Backticks are literal status-protocol text.
      printf '%s\n' 'Append `working:` only for a genuine phase change the supervisor would act on: work started, implementation committed and validation started, or PR opened.'
      ;;
    local-only)
      # shellcheck disable=SC2016 # Backticks are literal status-protocol text.
      printf '%s\n' 'Append `working:` only for a genuine phase change the supervisor would act on: work started or implementation committed and validation started.'
      ;;
    *)
      echo "error: fm_status_working_rule: unknown kind '$kind'" >&2
      return 1
      ;;
  esac
}

fm_status_no_progress_rule() {
  # shellcheck disable=SC2016 # Backticks are literal status-protocol text.
  printf '%s\n' 'Never append `working:` for a sub-step, a verification pass, or the start of re-review.'
}

fm_status_no_resolved_echo_rule() {
  # shellcheck disable=SC2016 # Backticks are literal status-protocol text.
  printf '%s\n' 'Never append a `resolved:` echo of a firstmate steer; moving its message into `handled/` is the acknowledgement.'
}
