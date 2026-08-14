#!/usr/bin/env bash
# Merge a live task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# A task already torn down through bin/fm-teardown.sh instead requires that
# teardown's private exact-PR receipt; missing metadata alone never authorizes a
# merge, and a receipt for a different PR is refused.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
RECEIPT="$STATE/$ID.teardown-pr"
CONTROL_LOCK="$STATE/.control-$ID.lock"
SPAWN_LOCK="$STATE/.spawn-$ID.lock"
STATE_DEVICE=$(fm_pr_file_device "$STATE") || {
  echo "error: task state is unavailable" >&2
  exit 1
}
CONTROL_LOCK_HELD=0
SPAWN_LOCK_HELD=0
merge_release_locks() {
  local status=$?
  if [ "$SPAWN_LOCK_HELD" = 1 ]; then
    fm_lock_release "$SPAWN_LOCK" || true
    SPAWN_LOCK_HELD=0
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CONTROL_LOCK" || true
    CONTROL_LOCK_HELD=0
  fi
  return "$status"
}
trap merge_release_locks EXIT
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID" >&2
  exit 1
}
CONTROL_LOCK_HELD=1

COMPLETED_TASK=0
if [ -f "$META" ] && [ ! -L "$META" ]; then
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    exit 1
  }
else
  fm_lock_try_acquire "$SPAWN_LOCK" || {
    echo "error: another task launch is already running for task $ID" >&2
    exit 1
  }
  SPAWN_LOCK_HELD=1
  if [ -e "$META" ] || [ -L "$META" ] \
    || ! fm_pr_private_file_valid "$RECEIPT" 600 "$STATE_DEVICE" \
    || ! fm_pr_teardown_receipt_parse "$RECEIPT" "$ID" \
    || [ "$FM_PR_TEARDOWN_URL" != "$URL" ]; then
    echo "error: task metadata is unavailable and no matching completed-task PR receipt exists" >&2
    exit 1
  fi
  COMPLETED_TASK=1
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
if [ "$COMPLETED_TASK" = 1 ]; then
  rm -f -- "$RECEIPT"
fi
