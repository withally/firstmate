#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
# Resolved once at source time: fm_pid_identity and fm_path_mtime run inside 0.2s
# confirm and 0.5s attach polls, and forking uname per call is a measurable cost on
# the platform (Git Bash/MSYS) that already pays the highest fork price.
_FM_UNAME=$(uname 2>/dev/null || echo unknown)
mkdir -p "$STATE"

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

fm_pid_identity() {
  local pid=$1 out proc_root stat_line starttime cmdline_hex identity_key
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  # Prefer a Linux-compatible /proc when present: stat field 22 (starttime, clock ticks since boot) is
  # immune to the wall-clock steps that re-render the ps lstart fallback's date
  # (observed as WSL2 btime drift) and would evict a live watcher; combining the
  # full NUL-separated cmdline keeps PID reuse a mismatch even on a tick collision.
  # Git Bash/MSYS exposes these compatible files but its Cygwin ps rejects the
  # portable fallback's -o fields, so capability detection must not key on uname.
  if [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    identity_key=proc-starttime
    [ "$_FM_UNAME" != Linux ] || identity_key=linux-starttime
    printf '%s=%s cmdline-hex=%s\n' "$identity_key" "$starttime" "$cmdline_hex"
    return 0
  fi
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

fm_path_mtime() {
  if [ "$_FM_UNAME" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

FM_WATCHER_MATCHED_IDENTITY=
fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity current_identity
  FM_WATCHER_MATCHED_IDENTITY=
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ] || return 1
  FM_WATCHER_MATCHED_IDENTITY=$lock_identity
}

FM_WATCHER_HEALTHY_PID=
FM_WATCHER_HEALTHY_IDENTITY=
fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir beat pid identity age
  FM_WATCHER_HEALTHY_PID=
  FM_WATCHER_HEALTHY_IDENTITY=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home" || return 1
  identity=$FM_WATCHER_MATCHED_IDENTITY
  age=$(fm_path_age "$beat")
  [ "$age" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_IDENTITY=$identity
  return 0
}

# fm_watcher_healthy above is the PID-STRICT primitive: true only when a live,
# identity-matched watcher PROCESS holds this home's lock with a fresh beacon. The
# arm layer (bin/fm-watch-arm.sh, bin/fm-claude-stop-autoarm.sh) needs exactly
# that - it decides whether to start, attach to, or replace a real watcher
# process, so a leftover beacon must never satisfy it. bin/fm-turnend-guard.sh
# also keeps this strict check because it fires at the turn boundary where the
# auto-arm brings a fresh watcher up. The pull warning (bin/fm-guard.sh) fires
# mid-turn, where the auto-arm model runs no watcher at all, so it wants a
# different, model-aware question:

# fm_supervision_model
# Print the supervision model of this home's PRIMARY harness:
#   autoarm     Claude Stop-hook auto-arm: the watcher is armed at each turn end
#               and exits on its wake, so it runs only BETWEEN turns. Mid-turn a
#               fresh beacon with no live watcher process is the healthy state.
#   persistent  every other harness (codex foreground checkpoint, opencode/pi/grok
#               background arm, tmux, unknown): the watcher runs as a tracked live
#               process, so a live identity-matched pid is the real liveness signal.
# FM_SUPERVISION_MODEL overrides detection (tests, and callers that already know
# the harness). Otherwise bin/fm-harness.sh is the single detection owner, so this
# stays consistent with the harness-specific repair line the guards already emit.
fm_supervision_model() {
  local harness
  case "${FM_SUPERVISION_MODEL:-}" in
    autoarm|persistent) printf '%s\n' "$FM_SUPERVISION_MODEL"; return 0 ;;
  esac
  harness=$("$FM_WAKE_LIB_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
  case "$harness" in
    claude) printf 'autoarm\n' ;;
    *) printf 'persistent\n' ;;
  esac
}

# fm_watcher_supervision_verdict <state> <watch-path> [grace] [home]
# Model-aware "is supervision healthy right now" verdict for the pull warning
# guard (bin/fm-guard.sh), NOT the arm layer or the turn-end guard. Sets:
#   FM_WATCHER_VERDICT_OK      true when supervision is healthy for this model
#   FM_WATCHER_VERDICT_REASON  when not ok, the true failing condition:
#                              no-watcher   - a live watcher process is the real
#                                             signal for this model but none holds
#                                             the lock (the beacon is still fresh)
#                              stale-beacon - the beacon is stale beyond grace or
#                                             absent (a genuine supervision lapse)
# autoarm: a fresh beacon within grace is healthy even with no live watcher,
# because the watcher only runs between turns; only a stale beacon is a lapse.
# persistent: require a live identity-matched watcher with a fresh beacon
# (fm_watcher_healthy); a fresh leftover beacon with no live watcher is still down.
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_OK=false
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_REASON=stale-beacon
fm_watcher_supervision_verdict() {
  local state=$1 watch=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME}
  local beat age fresh=false
  FM_WATCHER_VERDICT_OK=false
  FM_WATCHER_VERDICT_REASON=stale-beacon
  beat="$state/.last-watcher-beat"
  age=$(fm_path_age "$beat")
  case "$age" in
    ''|*[!0-9]*) ;;
    *) [ "$age" -lt "$grace" ] && fresh=true ;;
  esac
  if [ "$(fm_supervision_model)" = autoarm ]; then
    [ "$fresh" = true ] && FM_WATCHER_VERDICT_OK=true
    return 0
  fi
  if fm_watcher_healthy "$state" "$watch" "$grace" "$home"; then
    # shellcheck disable=SC2034 # Read by callers after the function returns.
    FM_WATCHER_VERDICT_OK=true
  elif [ "$fresh" = true ]; then
    # shellcheck disable=SC2034 # Read by callers after the function returns.
    FM_WATCHER_VERDICT_REASON=no-watcher
  fi
  return 0
}

# Away-mode supervisor lock (state/.supervise-daemon.lock). This is the single
# owner of "an identity-matched away daemon is alive for this home", shared by
# bin/fm-afk-start.sh (and through it bin/fm-afk-launch.sh and
# bin/fm-session-start.sh) and bin/fm-turnend-guard.sh. The lock is either a
# directory or a symlink to one, matching the watcher lock's shape.
fm_daemon_lock_owner() {  # <state-dir>
  local lock=$1/.supervise-daemon.lock owner
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$lock")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$lock" ] || return 1
  printf '%s\n' "$lock"
}

fm_daemon_lock_pid() {  # <state-dir>
  local owner
  owner=$(fm_daemon_lock_owner "$1") || return 1
  cat "$owner/pid" 2>/dev/null || true
}

# 0 only when the lock exists, its recorded pid is alive, and that process is
# provably the daemon: a recorded pid-identity must match exactly, and the
# command-name fallback applies only to locks written before identities existed.
fm_daemon_lock_alive() {  # <state-dir> [daemon-path]
  local daemon=${2:-$FM_WAKE_LIB_DIR/fm-supervise-daemon.sh} owner pid identity current command
  owner=$(fm_daemon_lock_owner "$1") || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    current=$(fm_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ]
    return
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$daemon"*|*"fm-supervise-daemon.sh"*) return 0 ;;
  esac
  return 1
}

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/role" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

fm_lock_set_role() {
  local lockdir=$1 role=$2 current pid back
  case "$role" in
    autoarm|terminal-check) : ;;
    *) return 1 ;;
  esac
  current=${BASHPID:-$$}
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 1
  printf '%s\n' "$role" > "$lockdir/role" 2>/dev/null || return 1
  back=$(cat "$lockdir/role" 2>/dev/null || true)
  [ "$back" = "$role" ]
}

fm_lock_role() {
  cat "$1/role" 2>/dev/null
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

fm_lock_link_owner() {
  local lockdir=$1 owner
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

fm_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  fm_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerdir
  FM_LOCK_OWNER_DIR=
  ownerdir=$(fm_lock_owner_dir "$lockdir") || return 1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_prepare_owner "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_pid_alive "$actual_pid"; then
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

FM_RECOVERY_MARKER_TOKEN=
FM_RECOVERY_MARKER_ACTION=none

fm_recovery_marker_read() {
  local marker=$1 line count
  FM_RECOVERY_MARKER_TOKEN=
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  count=$(wc -l < "$marker" 2>/dev/null | tr -d '[:space:]') || return 1
  [ "$count" = 1 ] || return 1
  IFS= read -r line < "$marker" || return 1
  case "$line" in
    pending:handling:*|pending:downtime:*|acked:handling:*|acked:downtime:*) ;;
    *) return 1 ;;
  esac
  case "${line##*:}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  FM_RECOVERY_MARKER_TOKEN=$line
}

_fm_atomic_replace() {
  mv -f -- "$1" "$2"
}

_fm_recovery_marker_write_locked() {
  local marker=$1 kind=$2 generation=${3:-} tmp
  case "$kind" in handling|downtime) ;; *) return 1 ;; esac
  tmp=$(mktemp "${marker}.tmp.XXXXXX") || return 1
  [ -n "$generation" ] || generation="$(fm_current_pid).$(date +%s).${tmp##*.}"
  if ! printf 'pending:%s:%s\n' "$kind" "$generation" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! _fm_atomic_replace "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

_fm_recovery_marker_publish() {
  local marker=$1 kind=${2:-downtime} lock
  case "$kind" in handling|downtime) ;; *) return 1 ;; esac
  lock="${marker}.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if [ -d "$marker" ] && [ ! -L "$marker" ]; then
    fm_lock_release "$lock"
    return 1
  fi
  if ! _fm_recovery_marker_write_locked "$marker" "$kind"; then
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
}

_fm_recovery_marker_begin_handling() {
  local marker=$1 expected_generation=${2:-} lock line generation
  lock="${marker}.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if ! fm_recovery_marker_read "$marker"; then
    fm_lock_release "$lock"
    return 1
  fi
  line=$FM_RECOVERY_MARKER_TOKEN
  generation=${line##*:}
  if [ -n "$expected_generation" ] && [ "$generation" != "$expected_generation" ]; then
    fm_lock_release "$lock"
    return 3
  fi
  case "$line" in
    pending:handling:*) ;;
    pending:downtime:*)
      if ! _fm_recovery_marker_write_locked "$marker" handling "$generation"; then
        fm_lock_release "$lock"
        return 1
      fi
      FM_RECOVERY_MARKER_TOKEN="pending:handling:$generation"
      ;;
    *) fm_lock_release "$lock"; return 1 ;;
  esac
  fm_lock_release "$lock"
}

fm_recovery_marker_snapshot() {
  local marker=$1 lock
  FM_RECOVERY_MARKER_TOKEN=
  lock="${marker}.lock"
  fm_lock_acquire_wait "$lock" || return 1
  fm_recovery_marker_read "$marker" || true
  fm_lock_release "$lock"
}

_fm_recovery_marker_ack() {
  local marker=$1 expected_generation=$2 lock tmp line
  [ -n "$expected_generation" ] || return 2
  lock="${marker}.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if ! fm_recovery_marker_read "$marker" \
    || [ "${FM_RECOVERY_MARKER_TOKEN##*:}" != "$expected_generation" ]; then
    fm_lock_release "$lock"
    return 3
  fi
  line=$FM_RECOVERY_MARKER_TOKEN
  case "$line" in
    pending:*) line="acked:${line#pending:}" ;;
    acked:*) fm_lock_release "$lock"; return 0 ;;
  esac
  tmp=$(mktemp "${marker}.tmp.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  if ! printf '%s\n' "$line" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! _fm_atomic_replace "$tmp" "$marker"; then
    rm -f -- "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
}

_fm_recovery_marker_arm_check() {
  local marker=$1 lock line quarantine
  FM_RECOVERY_MARKER_ACTION=none
  lock="${marker}.lock"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if ! fm_lock_acquire_wait "$lock"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  fi
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    if [ -s "$FM_WAKE_QUEUE" ]; then
      if ! _fm_recovery_marker_write_locked "$marker" downtime; then
        fm_lock_release "$lock"
        fm_lock_release "$FM_WAKE_QUEUE_LOCK"
        return 1
      fi
      FM_RECOVERY_MARKER_ACTION=recover
    fi
    fm_lock_release "$lock"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  if ! fm_recovery_marker_read "$marker"; then
    quarantine=$(mktemp -d "${marker}.invalid.XXXXXX") || {
      fm_lock_release "$lock"
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 1
    }
    if ! mv -- "$marker" "$quarantine/marker" \
      || ! _fm_recovery_marker_write_locked "$marker" downtime; then
      rmdir "$quarantine" 2>/dev/null || true
      fm_lock_release "$lock"
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 1
    fi
    FM_RECOVERY_MARKER_ACTION=recover
    fm_lock_release "$lock"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  line=$FM_RECOVERY_MARKER_TOKEN
  case "$line" in
    pending:handling:*)
      FM_RECOVERY_MARKER_ACTION="wait"
      fm_lock_release "$lock"
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 0
      ;;
    pending:downtime:*) FM_RECOVERY_MARKER_ACTION=recover ;;
    acked:*)
      if [ -s "$FM_WAKE_QUEUE" ]; then
        if ! _fm_recovery_marker_write_locked "$marker" downtime; then
          fm_lock_release "$lock"
          fm_lock_release "$FM_WAKE_QUEUE_LOCK"
          return 1
        fi
        # shellcheck disable=SC2034 # Read by the watcher after this sourced helper returns.
        FM_RECOVERY_MARKER_ACTION=recover
      fi
      ;;
  esac
  fm_lock_release "$lock"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
}

fm_recovery_transition() {
  local marker=$1 action=$2 target=${3:-} value=${4:-}
  case "$action" in
    publish) _fm_recovery_marker_publish "$marker" "${target:-downtime}" ;;
    acknowledge) _fm_recovery_marker_ack "$marker" "$target" ;;
    arm-check) _fm_recovery_marker_arm_check "$marker" ;;
    release-lock)
      [ -n "$target" ] || return 1
      _fm_recovery_marker_publish "$marker" "${value:-downtime}" || return 1
      fm_lock_release "$target"
      ;;
    release-lock-existing)
      [ -n "$target" ] || return 1
      local lock="${marker}.lock"
      fm_lock_acquire_wait "$lock" || return 1
      if ! fm_recovery_marker_read "$marker"; then
        fm_lock_release "$lock"
        return 1
      fi
      fm_lock_release "$target"
      fm_lock_release "$lock"
      ;;
    clear-stale-lock)
      [ -n "$target" ] || return 1
      _fm_recovery_marker_publish "$marker" "${value:-downtime}" || return 1
      fm_lock_remove_path "$target"
      ;;
    *) return 2 ;;
  esac
}

fm_recovery_marker_publish() {
  fm_recovery_transition "$1" publish "${2:-downtime}"
}

fm_recovery_marker_ack() {
  fm_recovery_transition "$1" acknowledge "$2"
}

fm_recovery_marker_begin_handling() {
  _fm_recovery_marker_begin_handling "$1" "${2:-}"
}

fm_recovery_marker_arm_check() {
  fm_recovery_transition "$1" arm-check
}

fm_lock_try_acquire() {
  local lockdir=$1 pid steal cur rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=
  FM_LOCK_RECOVERED_PID=

  if fm_lock_try_create "$lockdir"; then
    return 0
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! fm_lock_try_acquire "$steal"; then
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  if [ "$lockdir" = "$STATE/.watch.lock" ] \
    && ! _fm_recovery_marker_publish "$STATE/.watcher-down" downtime; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  fm_lock_remove_path "$lockdir" || true
  rc=1
  if fm_lock_try_create "$lockdir" "$steal_owner"; then
    rc=0
    # shellcheck disable=SC2034 # Read by lock-recovery callers after acquisition returns.
    FM_LOCK_RECOVERED_PID=$cur
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release "$steal"
  return "$rc"
}

fm_lock_acquire_wait() {
  local lockdir=$1
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

fm_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

fm_meta_lock_path() {
  local meta=$1 dir base id
  dir=${meta%/*}
  base=${meta##*/}
  [ "$dir" != "$meta" ] || dir=.
  case "$base" in
    *.meta) id=${base%.meta} ;;
    *) return 1 ;;
  esac
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s/.meta-%s.lock\n' "$dir" "$id"
}

# fm_task_set_lock_path: the per-home lock guarding WHICH tasks exist in a home,
# as opposed to fm_meta_lock_path, which guards one task's record.
#
# A per-task lock cannot protect a task that does not exist yet. Forced
# secondmate teardown enumerates a home's task set, locks what it found, and
# then re-enumerates while removing; a fresh spawn publishing a record inside
# that window is invisible to the first enumeration and visible to the second,
# so it gets destructively processed while never lifecycle-locked (reproduced
# with real agents: a record published 0.249s after teardown began was removed
# and its worktree returned to the pool, with both commands reporting success).
#
# The two roles are asymmetric, so the guard is a shared/exclusive pair rather
# than one mutex. Destructive owners (forced teardown) take this lock
# EXCLUSIVELY from enumeration through cleanup. Fresh spawns are SHARED: several
# of them may publish different tasks into one home at once - concurrent spawns
# are ordinary fleet behavior - so each registers itself with
# fm_task_set_publish_begin instead of taking this lock, and holds that
# registration until its record is published.
#
# Registration is published before the exclusive lock is read, and the exclusive
# lock is created before registrations are read, so neither side can slip
# through the other's window: either the spawn sees the teardown's lock and
# refuses, or the teardown sees the spawn's registration and refuses (or both
# refuse). Every direction fails closed, and spawns never exclude each other.
fm_task_set_lock_path() {  # <state-dir>
  local state=$1
  [ -n "$state" ] || return 1
  case "$state" in *[$'\n\r\t']*) return 1 ;; esac
  printf '%s/.task-set.lock\n' "$state"
}

# fm_task_set_publishers_dir: where shared publication registrations live, one
# file per in-flight fresh spawn. Entries are named by mktemp rather than by
# pid, so two spawns can never contend over one name and a recycled pid can
# never land on an existing entry.
fm_task_set_publishers_dir() {  # <state-dir>
  local state=$1
  [ -n "$state" ] || return 1
  case "$state" in *[$'\n\r\t']*) return 1 ;; esac
  printf '%s/.task-set-publishers\n' "$state"
}

# fm_task_set_lock_is_owned: is the exclusive task-set lock held by a live owner?
# Observation only - a spawn must never steal a teardown's lock, so this reads
# the lock rather than acquiring it, and applies the same liveness and
# mid-acquire freshness rules fm_lock_try_acquire uses before reclaiming.
fm_task_set_lock_is_owned() {  # <state-dir>
  local state=$1 lock pid
  lock=$(fm_task_set_lock_path "$state") || return 0
  [ -e "$lock" ] || [ -L "$lock" ] || return 1
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" && return 0
  fm_lock_mid_acquire_is_fresh "$lock" "$pid" && return 0
  return 1
}

# fm_task_set_publish_begin: register this process as publishing a task into the
# home. On success FM_TASK_SET_PUBLISH_ENTRY holds the registration to release
# later with fm_task_set_publish_end; on failure FM_TASK_SET_PUBLISH_REASON says
# whether a destructive owner holds the exclusive lock (owned) or the
# registration itself could not be established (error).
#
# The result is returned in variables rather than on stdout because the
# registration records the CALLER's pid: read through a command substitution it
# would record a subshell that exits immediately, leaving a registration nothing
# is actually publishing behind. Call it directly.
FM_TASK_SET_PUBLISH_REASON=
FM_TASK_SET_PUBLISH_ENTRY=
fm_task_set_publish_begin() {  # <state-dir>
  local state=$1 dir entry pid
  FM_TASK_SET_PUBLISH_REASON=error
  FM_TASK_SET_PUBLISH_ENTRY=
  dir=$(fm_task_set_publishers_dir "$state") || return 1
  [ ! -L "$dir" ] || return 1
  mkdir -p -- "$dir" 2>/dev/null || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  pid=${BASHPID:-$$}
  entry=$(mktemp "$dir/publisher.XXXXXX" 2>/dev/null) || return 1
  if ! { printf '%s\n' "$pid" > "$entry"; } 2>/dev/null; then
    rm -f -- "$entry" 2>/dev/null || true
    return 1
  fi
  # Publish first, then look: an exclusive owner that started before this point
  # is visible here, and one that starts after this point sees this entry.
  if fm_task_set_lock_is_owned "$state"; then
    rm -f -- "$entry" 2>/dev/null || true
    FM_TASK_SET_PUBLISH_REASON=owned
    return 1
  fi
  # shellcheck disable=SC2034 # Both are read by callers after this returns.
  FM_TASK_SET_PUBLISH_REASON=
  # shellcheck disable=SC2034 # Read by callers as the registration to release.
  FM_TASK_SET_PUBLISH_ENTRY=$entry
}

fm_task_set_publish_end() {  # <registration-path>
  local entry=$1
  [ -n "$entry" ] || return 0
  rm -f -- "$entry" 2>/dev/null || true
}

# fm_task_set_publish_in_flight: 0 when a fresh spawn may be publishing into the
# home, 1 only when that is definitively not the case. Called by the exclusive
# owner after it holds the lock, so anything unreadable answers 0 - a
# destructive operation must not proceed on an unproven task set. Registrations
# left behind by a killed spawn are reclaimed once their pid is gone.
fm_task_set_publish_in_flight() {  # <state-dir>
  local state=$1 dir entry pid write_window
  dir=$(fm_task_set_publishers_dir "$state") || return 0
  [ ! -L "$dir" ] || return 0
  [ -d "$dir" ] || return 1
  write_window=$FM_LOCK_STALE_AFTER
  [ "$write_window" -ge 2 ] || write_window=2
  for entry in "$dir"/publisher.*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ -f "$entry" ] && [ ! -L "$entry" ] || return 0
    pid=$(cat "$entry" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*)
        # Caught between the registration's creation and its pid write: fail
        # closed while it is fresh, and only reclaim it once it is older than
        # any real write window.
        [ "$(fm_path_age "$entry")" -lt "$write_window" ] && return 0
        rm -f -- "$entry" 2>/dev/null || true
        continue
        ;;
    esac
    fm_pid_alive "$pid" && return 0
    rm -f -- "$entry" 2>/dev/null || true
  done
  return 1
}

fm_failure_episode_reset() {
  local state=$1 mode=${2:-acquire} lock current pid acquired=0 path
  lock="$state/.turnend-claude-blocks.lock"
  case "$mode" in
    acquire)
      fm_lock_try_acquire "$lock" || return 1
      acquired=1
      ;;
    held)
      current=${BASHPID:-$$}
      pid=$(cat "$lock/pid" 2>/dev/null || true)
      [ "$pid" = "$current" ] || return 1
      ;;
    *) return 1 ;;
  esac
  for path in \
    "$state/.turnend-claude-blocks" \
    "$state/.claude-autoarm-failure-notified" \
    "$state/.claude-autoarm-failure-alarmed"
  do
    if [ -d "$path" ] && [ ! -L "$path" ]; then
      [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
      return 1
    fi
  done
  if ! rm -f \
    "$state/.turnend-claude-blocks" \
    "$state/.claude-autoarm-failure-notified" \
    "$state/.claude-autoarm-failure-alarmed" \
    2>/dev/null; then
    [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
    return 1
  fi
  [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
  return 0
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status recovery_marker
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  recovery_marker="$STATE/.watcher-down"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  _fm_recovery_marker_publish "$recovery_marker" downtime || status=$?
  if [ "$status" -eq 0 ]; then
    seq=$(cat "$seq_file" 2>/dev/null || echo 0)
    case "$seq" in
      ''|*[!0-9]*) seq=0 ;;
    esac
    seq=$((seq + 1))
    printf '%s\n' "$seq" > "$seq_file" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# fm_wake_queued_keys <kind>
# Print the distinct keys currently queued for <kind>, oldest first. Read under
# the append lock so a concurrent append is never observed half-written. The
# durable queue stays the authority: a key appears here exactly while a record
# for it is queued and unacknowledged, and disappears only after post-handling
# acknowledgement consumes it.
fm_wake_queued_keys() {
  local kind=$1
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_queued_keys: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  fm_wake_queued_keys_locked "$kind"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
}

fm_wake_queued_keys_locked() {
  local kind=$1
  awk -F '\t' -v kind="$kind" 'NF >= 5 && $3 == kind && !seen[$4]++ { print $4 }' \
    "$FM_WAKE_QUEUE" 2>/dev/null || true
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

# Quarantine structurally invalid queue rows (fewer than five fields, or a
# non-numeric sequence) under the queue's append lock, mirroring the invalid
# recovery-marker quarantine: evidence is retained beside the queue instead of
# deleted, and the surviving queue holds only presentable rows so an
# empty-queue acknowledgement can still finalize a recovery generation.
# Caller must hold FM_WAKE_QUEUE_LOCK. On failure the queue is left untouched.
FM_WAKE_QUEUE_QUARANTINED=0
FM_WAKE_QUEUE_QUARANTINE_DIR=
fm_wake_queue_quarantine_invalid_locked() {  # <queue-path>
  local queue=$1 bad quarantine tmp
  FM_WAKE_QUEUE_QUARANTINED=0
  FM_WAKE_QUEUE_QUARANTINE_DIR=
  [ -f "$queue" ] && [ -s "$queue" ] || return 0
  bad=$(awk -F '\t' 'NF < 5 || $2 !~ /^[0-9]+$/ { n++ } END { print n + 0 }' "$queue") || return 1
  [ "$bad" -gt 0 ] || return 0
  quarantine=$(mktemp -d "${queue}.invalid.XXXXXX") || return 1
  if ! awk -F '\t' 'NF < 5 || $2 !~ /^[0-9]+$/' "$queue" > "$quarantine/rows" \
    || ! chmod 0600 "$quarantine/rows"; then
    rm -rf -- "$quarantine" 2>/dev/null || true
    return 1
  fi
  tmp=$(mktemp "${queue}.valid.XXXXXX") || {
    rm -rf -- "$quarantine" 2>/dev/null || true
    return 1
  }
  if ! awk -F '\t' 'NF >= 5 && $2 ~ /^[0-9]+$/' "$queue" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! _fm_atomic_replace "$tmp" "$queue"; then
    rm -f -- "$tmp" 2>/dev/null || true
    rm -rf -- "$quarantine" 2>/dev/null || true
    return 1
  fi
  # shellcheck disable=SC2034 # Read by callers after the function returns.
  FM_WAKE_QUEUE_QUARANTINED=$bad
  # shellcheck disable=SC2034 # Read by callers after the function returns.
  FM_WAKE_QUEUE_QUARANTINE_DIR=$quarantine
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}

# Guarded append for bookkeeping lines this home has already presented.
# The seen marker advances only when it covered every pre-existing byte and no
# other writer interleaved with this append. Every uncertainty leaves the new
# line for the ordinary watcher, so a later foreign append cannot be swallowed.
fm_wake_signal_sig() {  # <file>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%z:%Fm' "$1" 2>/dev/null
  else
    stat -c '%s:%Y' "$1" 2>/dev/null
  fi
}

fm_wake_signal_seen_path() {  # <state> <file>
  printf '%s/.seen-%s' "$1" "$(basename "$2" | tr '.' '_')"
}

fm_wake_status_append_self_announced() {  # <state> <status-file> <line>
  local state=$1 file=$2 line=$3 marker pre_sig='' post_sig pre_size post_size line_bytes
  marker=$(fm_wake_signal_seen_path "$state" "$file")
  if [ -e "$file" ]; then
    pre_sig=$(fm_wake_signal_sig "$file") || pre_sig=''
  fi
  printf '%s\n' "$line" >> "$file" || return 2
  [ -n "$pre_sig" ] && [ "$(cat "$marker" 2>/dev/null)" = "$pre_sig" ] || return 1
  post_sig=$(fm_wake_signal_sig "$file") || return 1
  pre_size=${pre_sig%%:*}
  post_size=${post_sig%%:*}
  case "$pre_size$post_size" in ''|*[!0-9]*) return 1 ;; esac
  line_bytes=$(printf '%s' "$line" | LC_ALL=C wc -c 2>/dev/null | tr -d '[:space:]')
  case "$line_bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$post_size" -eq $((pre_size + line_bytes + 1)) ] || return 1
  printf '%s' "$post_sig" > "$marker" 2>/dev/null || return 1
}

# Map one structurally valid signal key to its home-local status filename.
# Queue payload text is intentionally ignored: it is display data, not a path
# authority. The caller still verifies the resulting regular file immediately
# before its bounded read.
FM_WAKE_STATUS_KEY=
FM_WAKE_STATUS_HISTORICAL=false
fm_wake_status_key_map() {  # <queue-key>
  local key=$1 id
  FM_WAKE_STATUS_KEY=
  FM_WAKE_STATUS_HISTORICAL=false
  case "$key" in
    *.status)
      id=${key%.status}
      ;;
    *.turn-ended)
      id=${key%.turn-ended}
      FM_WAKE_STATUS_HISTORICAL=true
      ;;
    *)
      return 1
      ;;
  esac
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ] || return 1
  FM_WAKE_STATUS_KEY="$id.status"
}

fm_wake_annotation_manifest() {  # <deduped-raw-rows>
  local rows=$1 epoch seq kind key payload
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = signal ] || continue
    fm_wake_status_key_map "$key" || continue
    if [ "$FM_WAKE_STATUS_HISTORICAL" = true ]; then
      printf '%s\thistorical\n' "$FM_WAKE_STATUS_KEY"
    else
      printf '%s\tdirect\n' "$FM_WAKE_STATUS_KEY"
    fi
  done <<EOF
$rows
EOF
}

fm_wake_print_annotations() {  # <deduped-raw-rows> <presentation-snapshot>
  local rows=$1 snapshot=$2 manifest status_key mode path prefix line task endpoint
  local snapshot_task snapshot_endpoint snapshot_ident lines last
  local LC_ALL=C

  manifest=$(fm_wake_annotation_manifest "$rows" | awk -F '\t' '
    {
      key = $1
      if (!(key in seen)) {
        order[++count] = key
        seen[key] = 1
        mode[key] = $2
      } else if ($2 == "direct") {
        mode[key] = "direct"
      }
    }
    END {
      for (i = 1; i <= count; i++) print order[i] "\t" mode[order[i]]
    }
  ') || return 0

  # Test-only latency seam for proving that queue appends remain independent of
  # a slow best-effort annotation phase.
  case "${FM_WAKE_ENRICH_TEST_DELAY:-0}" in
    0) ;;
    ''|*[!0-9]*) ;;
    *) sleep "$FM_WAKE_ENRICH_TEST_DELAY" ;;
  esac

  while IFS=$(printf '\t') read -r status_key mode; do
    [ -n "$status_key" ] || continue
    path="$STATE/$status_key"
    task=${status_key%.status}
    endpoint=
    while IFS=$(printf '\t') read -r snapshot_task snapshot_endpoint snapshot_ident; do
      if [ "$snapshot_task" = "$task" ]; then endpoint=$snapshot_endpoint; break; fi
    done <<EOF
$snapshot
EOF
    [ -n "$endpoint" ] || continue
    lines=$(status_new_lines_since_cursor "$path" "$endpoint") || return 1
    [ -n "$lines" ] || continue
    last=$(printf '%s\n' "$lines" | tail -1)
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      prefix="wake annotation: unread wake-EVENT since last drain, not current state"
      [ "$line" = "$last" ] \
        && prefix="wake annotation: latest wake-EVENT observed at drain, not current state"
      [ "$mode" != historical ] \
        || prefix="$prefix; historical / not necessarily the triggering event"
      printf '%s: %s: %s\n' "$prefix" "$status_key" \
        "$(printf '%s' "$line" | LC_ALL=C tr '\t\r' '  ')" || return 1
    done <<EOF
$lines
EOF
  done <<EOF
$manifest
EOF
}
