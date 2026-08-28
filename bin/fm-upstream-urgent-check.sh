#!/usr/bin/env bash
# Fetch upstream/main once and report new commits whose subject or body carries
# an urgent-upstream keyword.
#
# Usage:
#   fm-upstream-urgent-check.sh check
#   fm-upstream-urgent-check.sh arm
#   fm-upstream-urgent-check.sh disarm
#   fm-upstream-urgent-check.sh --help
#
# `check` is silent when no matching commit exists, so it is safe to run as a
# registered watcher check.
# `arm` writes and registers state/upstream-urgent.check.sh.
# `disarm` removes that shim, its trust binding, and the report record.
#
# The report record state/.upstream-urgent carries the report the last line was
# made from, uncut, so one urgent commit is reported once rather than on every
# watcher poll while the recorded sync base still trails it.
#
# Every condition that stops the inspection is reported on stdout through that
# same record, never on stderr alone. The watcher discards a check's stderr and
# its exit status, so a tripwire that can no longer read its base, reach its
# remote, or fetch would otherwise be indistinguishable from a clean all-clear
# for as long as it stays armed. It still exits non-zero, so a hand run and the
# test suite can tell a failed inspection from a silent one.
set -u
export LC_ALL=C
# The upstream probe must never stop to ask for credentials; an unauthenticated
# fetch has to fail inside its bound instead of waiting for an answer.
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SYNC_LOG="$FM_ROOT/docs/upstream-sync.md"
CHECK_ID=upstream-urgent
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.$CHECK_ID"
RECORD_SCHEMA=fm-upstream-urgent-v1
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
# Wider than the digest default because one finding names a 12-character hash
# and a full commit subject, and a window can carry several of them.
MAX_LINE=1000

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

FETCH_TIMEOUT=8

usage() {
  cat <<'EOF'
Usage:
  fm-upstream-urgent-check.sh check    fetch upstream/main and report urgent commits
  fm-upstream-urgent-check.sh arm      write and register the watcher check shim
  fm-upstream-urgent-check.sh disarm   remove the check shim, its trust binding, and the record
  fm-upstream-urgent-check.sh --help   print this help

The check reads the latest adopted upstream base from docs/upstream-sync.md.
It is silent unless a commit since that base matches security, CVE, breaking,
revert, data loss, or credential, or the inspection itself could not run.
Either report is printed once per distinct report, on stdout.
EOF
}

die_usage() {
  printf 'fm-upstream-urgent-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

latest_sync_base() {
  local field tick=$'\140'
  [ -f "$SYNC_LOG" ] || return 1
  field=$(awk -F'|' '
    $0 ~ /^\| [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] \|/ { value=$3 }
    END { print value }
  ' "$SYNC_LOG") || return 1
  # The column carries the adopted upstream base first and may name a later
  # origin/main landing hash after it, so take the FIRST backticked bare hex
  # token rather than letting a greedy match walk to the last one.
  printf '%s\n' "$field" \
    | grep -o "${tick}[0-9a-f]\{7,40\}${tick}" \
    | head -n 1 \
    | tr -d "$tick"
}

urgent_commits() {
  awk -v RS='\036' '
    {
      text=tolower($0)
      if (text !~ /(^|[^[:alnum:]])(security|cve|breaking|revert|data[[:space:]-]+loss|credential(s)?)([^[:alnum:]]|$)/) next
      sub(/^[[:space:]]+/, "", $0)
      split($0, fields, "\t")
      subject=fields[2]
      gsub(/[[:space:]]+/, " ", subject)
      if (subject == "") subject="(no subject)"
      if (found++) printf "; "
      printf "%s \"%s\"", substr(fields[1], 1, 12), subject
    }
  '
}

RECORD_REPORTED=

record_read() {
  local line first=1
  RECORD_REPORTED=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      reported=*) RECORD_REPORTED=${line#reported=} ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() {
  local reported=$1 tmp
  [ -e "$STATE" ] || mkdir -p "$STATE" 2>/dev/null || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'reported=%s\n' "$reported"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

report_once() {
  local payload=$1
  record_read
  fm_cap_line_var "$payload" "$MAX_LINE"
  # The cut line is what gets printed, but the whole payload decides whether
  # this is news, because a commit that lands past the cut leaves the printed
  # line unchanged and would otherwise be suppressed for good.
  #
  # Report before recording, so a record that cannot be written costs a repeated
  # report rather than a lost one.
  if [ "$payload" != "$RECORD_REPORTED" ]; then
    printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  record_write "$payload" || true
}

report_clear() {
  record_read
  [ -z "$RECORD_REPORTED" ] || record_write '' || true
}

check_failed() {
  report_once "upstream urgent check failed: $1"
  return 1
}

action_check() {
  local base base_commit upstream_tip remote_url matches log
  base=$(latest_sync_base) || {
    check_failed 'latest sync base is unavailable'
    return 1
  }
  [ -n "$base" ] || {
    check_failed 'latest sync base is unavailable'
    return 1
  }
  remote_url=$(git -C "$FM_ROOT" remote get-url upstream 2>/dev/null) || {
    check_failed 'upstream remote is unavailable'
    return 1
  }
  [ -n "$remote_url" ] || {
    check_failed 'upstream remote is unavailable'
    return 1
  }
  # This is the only network operation in the tripwire.
  fm_run_timed "$FETCH_TIMEOUT" git -C "$FM_ROOT" fetch --quiet --no-tags upstream \
    +main:refs/remotes/upstream/main >/dev/null 2>&1 || {
    check_failed 'fetch failed'
    return 1
  }
  upstream_tip=$(git -C "$FM_ROOT" rev-parse --verify --quiet \
    'refs/remotes/upstream/main^{commit}') || {
    check_failed 'upstream/main is unavailable after fetch'
    return 1
  }
  base_commit=$(git -C "$FM_ROOT" rev-parse --verify --quiet "$base^{commit}") || {
    check_failed "recorded base $base is not a commit in this clone"
    return 1
  }
  git -C "$FM_ROOT" merge-base --is-ancestor "$base_commit" "$upstream_tip" || {
    check_failed "recorded base $base is not an ancestor of upstream/main"
    return 1
  }
  # The log is captured before it is matched, because a pipeline would take its
  # status from awk alone and report a failed inspection as a clean check.
  log=$(git -C "$FM_ROOT" log --reverse \
    --format='%H%x09%s%x09%b%x1e' "$base_commit..$upstream_tip") || {
    check_failed 'could not inspect upstream commits'
    return 1
  }
  matches=$(printf '%s' "$log" | urgent_commits) || {
    check_failed 'could not inspect upstream commits'
    return 1
  }
  [ -n "$matches" ] || {
    # A clean window clears the record, so the same commit set or the same
    # failure is news again if either comes back.
    report_clear
    return 0
  }
  report_once "urgent upstream commits: $matches"
  return 0
}

shim_content() {
  local home=$1 root=$2
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# Generated by fm-upstream-urgent-check.sh.'
  printf 'export FM_ROOT_OVERRIDE=%q\n' "$root"
  printf 'export FM_HOME=%q\n' "$home"
  printf 'exec %q check\n' "$SCRIPT_DIR/fm-upstream-urgent-check.sh"
}

SHIM_WRITE_TMP=

write_shim() {
  local content=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-upstream-urgent-check.XXXXXX") || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-upstream-urgent-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So the one rule after a
# failed or interrupted arm is that the home never holds a shim without a
# matching trust binding. The shim a working home had is put back and kept only
# when it is still bound; otherwise the shim goes, so the home is plainly not
# armed and the failure is the only thing the operator has to act on.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-upstream-urgent-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local home root content
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    printf 'fm-upstream-urgent-check: FM_HOME cannot be resolved\n' >&2
    return 1
  }
  root=$(CDPATH='' cd -- "$FM_ROOT" 2>/dev/null && pwd -P) || {
    printf 'fm-upstream-urgent-check: FM_ROOT cannot be resolved\n' >&2
    return 1
  }
  content=$(shim_content "$home" "$root") || return 1
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-upstream-urgent-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! write_shim "$content"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-upstream-urgent-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-upstream-urgent-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) [ "$#" -eq 1 ] || die_usage 'check takes no additional arguments'; action_check ;;
  arm) [ "$#" -eq 1 ] || die_usage 'arm takes no additional arguments'; action_arm ;;
  disarm) [ "$#" -eq 1 ] || die_usage 'disarm takes no additional arguments'; action_disarm ;;
  -h|--help) [ "$#" -eq 1 ] || die_usage '--help takes no additional arguments'; usage ;;
  *) die_usage "unknown action: $1" ;;
esac
