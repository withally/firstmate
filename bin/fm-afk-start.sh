#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: fm-afk-start.sh
#   Sets state/.afk unless FM_AFK_STATE_PREPARED=1, checks
#   state/.supervise-daemon.lock, and:
#     - prints "afk: daemon already running pid=<pid>" then exits 0 when that
#       lock is held by a live daemon (a refresh: no stale-artifact clear);
#     - otherwise, for a direct non-prepared start with no existing state/.afk,
#       clears any prior away session's stale delivery artifacts
#       (fm_afk_clear_stale_artifacts), then execs bin/fm-supervise-daemon.sh in
#       the foreground. A prepared start delegates the same fresh-versus-
#       recovery handling to bin/fm-afk-launch.sh; an existing state/.afk keeps
#       the current session's delivery artifacts for recovery.
#
# This file is sourceable: its BASH_SOURCE guard keeps main from running, while
# exposing the daemon-lock helpers and fm_afk_clear_stale_artifacts. Sourcing it
# enables nounset and errexit; callers that need different shell options must
# restore them explicitly.
#
# This is the COMMON daemon entry for every backend. HOW it becomes a tracked
# background process differs by harness/backend and is owned elsewhere:
#   - Harnesses with a native in-pane tracked-background tool (e.g. claude, grok)
#     run this directly via that tool, so the daemon inherits the captain pane's
#     env and auto-discovers it.
#   - Harnesses with NO native background mechanism (e.g. pi) run this THROUGH
#     bin/fm-afk-launch.sh, which creates a non-visible tracked terminal per
#     backend (herdr tab/workspace, tmux detached session) and passes the
#     captain pane in as FM_SUPERVISOR_TARGET so injection targets it, not the
#     daemon's own new pane.
# Do not wrap this in `nohup ... &`: Codex/herdr can reap fire-and-forget shell
# children after the tool call returns, while a tracked background terminal stays
# attached and has a real lifecycle.
set -eu

FM_AFK_START_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_START_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LOCK="$FM_AFK_STATE/.supervise-daemon.lock"
FM_AFK_DAEMON="$FM_AFK_START_DIR/fm-supervise-daemon.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_AFK_START_DIR/fm-wake-lib.sh"

# The away daemon's delivery store is the single journal state/.subsuper-delivery.jsonl
# (bin/fm-supervise-daemon.sh owns its format) plus the .subsuper-inject-wedged alarm
# marker. The pre-redesign multi-file names remain available to the launch backup
# and return cleanup while the daemon's one-time startup import consumes them.
# This is the ONE owner of the delivery-artifact set for the away-mode scripts.
FM_AFK_FRESH_DELIVERY_ARTIFACTS=(
  .subsuper-delivery.jsonl
  .subsuper-inject-wedged
)

FM_AFK_DELIVERY_ARTIFACTS=(
  .subsuper-delivery.jsonl
  .subsuper-inject-wedged
  .subsuper-escalations
  .subsuper-escalations.since
  .subsuper-escalations.delivery
  .subsuper-escalations.records
  .subsuper-check-ledger
)

fm_afk_start_usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# fm_afk_clear_stale_artifacts: on a FRESH away-session entry (state/.afk is
# absent and the daemon is not already running), drop the previous journal and
# wedge marker. A restart or recovery with state/.afk already present preserves
# the current session's delivery journal and wedge marker for replay-safe
# routing. Legacy multi-file inputs remain available for the daemon's one-time
# startup import. This helper is not called on a refresh or same-session recovery.
fm_afk_clear_stale_artifacts() {  # <state-dir>
  local state=$1 artifact result=0
  for artifact in "${FM_AFK_FRESH_DELIVERY_ARTIFACTS[@]}"; do
    rm -f "$state/$artifact" 2>/dev/null || result=1
  done
  return "$result"
}

daemon_lock_owner() {
  local owner
  if [ -L "$FM_AFK_LOCK" ]; then
    owner=$(readlink "$FM_AFK_LOCK" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$FM_AFK_LOCK")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$FM_AFK_LOCK" ] || return 1
  printf '%s\n' "$FM_AFK_LOCK"
}

daemon_pid_matches() {
  local pid=$1 owner=$2 identity current command
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    current=$(fm_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ]
    return
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$FM_AFK_DAEMON"*|*"fm-supervise-daemon.sh"*) return 0 ;;
  esac
  return 1
}

daemon_lock_pid() {
  local owner
  owner=$(daemon_lock_owner) || return 1
  cat "$owner/pid" 2>/dev/null || true
}

daemon_lock_held_by_live_daemon() {
  local owner pid
  owner=$(daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  daemon_pid_matches "$pid" "$owner"
}

fm_afk_flag_write() {  # <state-dir>
  local state=$1 lock="$1/.cursor-park-owner.lock" pending attempt=0 status=1
  mkdir -p "$state" || return 1
  [ ! -d "$state/.afk" ] || return 1
  pending=$(mktemp "$state/.afk.pending.XXXXXX") || return 1
  date '+%s' > "$pending" || { rm -f "$pending"; return 1; }
  while [ "$attempt" -lt 50 ]; do
    attempt=$((attempt + 1))
    if fm_lock_try_acquire "$lock"; then
      mv "$pending" "$state/.afk" && status=0
      fm_lock_release "$lock"
      rm -f "$pending" 2>/dev/null || true
      return "$status"
    fi
    [ "$attempt" -lt 50 ] && sleep 0.1
  done
  rm -f "$pending" 2>/dev/null || true
  return 1
}

fm_afk_start_main() {
  case "${1:-}" in
    '' ) ;;
    -h|--help) fm_afk_start_usage; return 0 ;;
    * ) echo "usage: $(basename "${BASH_SOURCE[1]:-fm-afk-start.sh}")" >&2; return 2 ;;
  esac

  mkdir -p "$FM_AFK_STATE"
  local pid had_afk=0
  [ -e "$FM_AFK_STATE/.afk" ] && had_afk=1
  if [ "${FM_AFK_STATE_PREPARED:-0}" = 1 ]; then
    [ -f "$FM_AFK_STATE/.afk" ] || { echo "afk: launcher-prepared state is missing" >&2; return 1; }
  elif [ "$had_afk" -eq 1 ]; then
    fm_afk_flag_write "$FM_AFK_STATE" || { echo "afk: failed to write away-mode flag" >&2; return 1; }
  fi

  pid=$(daemon_lock_pid 2>/dev/null || true)
  if daemon_lock_held_by_live_daemon; then
    if [ "${FM_AFK_STATE_PREPARED:-0}" != 1 ] && [ "$had_afk" -eq 0 ]; then
      fm_afk_flag_write "$FM_AFK_STATE" || { echo "afk: failed to write away-mode flag" >&2; return 1; }
    fi
    echo "afk: daemon already running pid=$pid"
    return 0
  fi

  if fm_pid_alive "$pid" && [ -n "$pid" ]; then
    fm_lock_remove_path "$FM_AFK_LOCK" 2>/dev/null || true
  fi

  # Fresh start: clear the previous away session's live delivery artifacts
  # before the new daemon can surface them (fix for the leaked-artifact defect).
  if [ "${FM_AFK_STATE_PREPARED:-0}" != 1 ] && [ "$had_afk" -eq 0 ]; then
    fm_afk_clear_stale_artifacts "$FM_AFK_STATE" || {
      echo "afk: failed to clear stale away-mode artifacts" >&2
      return 1
    }
    fm_afk_flag_write "$FM_AFK_STATE" || { echo "afk: failed to write away-mode flag" >&2; return 1; }
  fi

  echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
  exec "$FM_AFK_DAEMON"
}

# Run only when executed, not when sourced (tests source fm_afk_clear_stale_artifacts
# and the lock helpers directly).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_start_main "$@"
fi
