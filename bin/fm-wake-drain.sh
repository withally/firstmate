#!/usr/bin/env bash
# Present durable watcher wake records, optionally acknowledge handled records,
# annotate validated signal status keys, then assert liveness.
#
# Keep sequence-bound row consumption independent from generation-bound episode
# retirement; docs/watcher-continuity.md owns the recovery contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-inactive-reconcile-lib.sh
. "$SCRIPT_DIR/fm-inactive-reconcile-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false
RAW_ROWS=
RECOVERY_MARKER="$STATE/.watcher-down"
RECOVERY_MARKER_TOKEN=
RECOVERY_ACK_REQUIRED=false
RECOVERY_ACK_MOVED=false
ACK_THROUGH=
ACK_GENERATION=
ACK_INACTIVE_FINGERPRINTS=

case "${1:-}" in
  '') ;;
  --ack-through)
    ACK_THROUGH=${2:-}
    case "$ACK_THROUGH" in ''|*[!0-9]*) echo "wake drain: invalid acknowledgement sequence" >&2; exit 2 ;; esac
    [ "${3:-}" = --recovery-generation ] \
      || { echo "wake drain: acknowledgement requires its recovery generation" >&2; exit 2; }
    ACK_GENERATION=${4:-}
    case "$ACK_GENERATION" in ''|*[!A-Za-z0-9._-]*) echo "wake drain: invalid recovery generation" >&2; exit 2 ;; esac
    [ "$#" -eq 4 ] || { echo "wake drain: unexpected acknowledgement arguments" >&2; exit 2; }
    ;;
  *) echo "usage: fm-wake-drain.sh [--ack-through SEQUENCE --recovery-generation GENERATION]" >&2; exit 2 ;;
esac

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert supervision health here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (fm-peek/fm-send/...) happens to run.
# Reuse fm-guard.sh's model-aware alarm and FM_GUARD_GRACE instead of duplicating
# its supervision verdict. Under Claude's between-turns auto-arm model, a normal
# fire leaves a recent beacon well inside grace and stays silent mid-turn. Under
# persistent-watcher models, the guard also requires the live identity-matched
# watcher. Never let a guard hiccup change the drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

print_unread_status_section() {  # <presentation-snapshot>
  local snapshot=$1 unread task line shown=0
  unread=$(scan_unread_surface_snapshot "$STATE" "$snapshot") || return 1
  [ -n "$unread" ] || return 0
  while IFS=$(printf '\t') read -r task line; do
    [ -n "$task" ] && [ -n "$line" ] || continue
    if [ "$shown" -eq 0 ]; then
      printf 'UNREAD STATUS (new since last drain, not re-printed after this presentation):\n' \
        || return 1
    fi
    printf '%s %s\n' "$task" "$line" || return 1
    shown=$((shown + 1))
  done <<EOF
$unread
EOF
}

inactive_outcome_fingerprints() { # <sequence>
  local cutoff=$1 epoch seq kind key payload
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = check ] || continue
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    [ "$seq" -le "$cutoff" ] || continue
    case "$key" in inactive-outcome:*) printf '%s\n' "${key#inactive-outcome:}" ;; esac
  done < "$FM_WAKE_QUEUE"
}

close_inactive_outcome_receipts() { # <newline-separated-fingerprints>
  local fingerprints=$1 fingerprint lock="$STATE/.inactive-outcome-reconcile.lock" rc=0
  [ -n "$fingerprints" ] || return 0
  fm_lock_acquire_wait "$lock" || return 1
  while IFS= read -r fingerprint; do
    [ -n "$fingerprint" ] || continue
    fm_inactive_receipt_close_presented "$STATE" "$fingerprint" || { rc=$?; break; }
  done <<EOF
$fingerprints
EOF
  fm_lock_release "$lock"
  return "$rc"
}

# Print the consolidated OPEN DECISIONS section: every still-open
# needs-decision/blocked, fleet-wide, folded from the durable status logs by
# fm-classify-lib.sh's one fold-line rule through the snapshot-bound incremental
# wrapper rather than from the latest-line annotations above, so a decision
# buried under later unrelated appends cannot be silently missed. The same
# status snapshot feeds annotations, unread presentation, and this scan, while
# each warm decision fold reads only newly appended bytes. Runs on every drain,
# including the empty-queue fast path, because the decision can still be open
# even when nothing new is queued for its task this turn.
# Bounded and silent: prints nothing when no decision is open, which is the
# common case.
print_open_decisions_section() {  # <presentation-snapshot>
  local snapshot=${1:-} open task key verb note line item_bytes=220 global_bytes=4000
  local output='' used=0 shown=0 omitted=0 bytes suffix keep

  if [ -n "$snapshot" ]; then
    open=$(scan_open_decisions_snapshot "$STATE" "$snapshot") || return 1
  else
    open=$(scan_open_decisions_incremental "$STATE") || return 1
  fi
  [ -n "$open" ] || return 0

  while IFS=$(printf '\t') read -r task key verb note; do
    [ -n "$task" ] || continue
    line="$task"
    [ "$key" = default ] || line="$line [key=$key]"
    line="$line $verb: $note"
    if [ $(( ${#line} + 1 )) -gt "$item_bytes" ]; then
      suffix=' [truncated]'
      keep=$((item_bytes - ${#suffix} - 1))
      line="${line:0:$keep}$suffix"
    fi
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes)) -gt "$global_bytes" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$line
"
    used=$((used + bytes))
    shown=$((shown + 1))
  done <<EOF
$open
EOF

  [ "$shown" -gt 0 ] || [ "$omitted" -gt 0 ] || return 0
  printf 'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):\n'
  printf '%s' "$output"
  if [ "$omitted" -gt 0 ]; then
    printf 'OPEN DECISIONS: %d more omitted (byte cap)\n' "$omitted"
  fi
}

print_status_presentation() {  # [<deduped-raw-rows>]
  local rows=${1:-} lock="$STATE/.status-presentation-lock" snapshot manifest fully='' acknowledged rc=0
  fm_lock_acquire_wait "$lock" || return 1
  snapshot=$(status_presentation_snapshot "$STATE") || rc=1
  if [ "$rc" -eq 0 ] && [ -n "$rows" ]; then
    fm_wake_print_annotations "$rows" "$snapshot" || rc=1
    if [ "$rc" -eq 0 ]; then
      manifest=$(fm_wake_annotation_manifest "$rows") || rc=1
      fully=$(printf '%s\n' "$manifest" | awk -F '\t' \
        '$2 == "direct" { sub(/\.status$/, "", $1); print $1 }') || rc=1
    fi
  fi
  if [ "$rc" -eq 0 ] && [ -n "$snapshot" ]; then
    print_unread_status_section "$snapshot" || rc=1
  fi
  print_open_decisions_section "$snapshot" || rc=1
  if [ "$rc" -eq 0 ] && [ -n "$snapshot" ]; then
    acknowledged=$(status_acknowledge_presented_snapshot "$STATE" "$snapshot" "$fully") || rc=1
    [ "$rc" -ne 0 ] || status_commit_presentation_snapshot "$STATE" "$acknowledged" || rc=1
  fi
  fm_lock_release "$lock"
  return "$rc"
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  [ -z "$DRAIN_TMP" ] || rm -f -- "$DRAIN_TMP" 2>/dev/null || true
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=true

if fm_wake_queue_quarantine_invalid_locked "$FM_WAKE_QUEUE"; then
  if [ "$FM_WAKE_QUEUE_QUARANTINED" -gt 0 ]; then
    printf 'wake queue: %s malformed row(s) quarantined to %s (evidence retained; not presentable)\n' \
      "$FM_WAKE_QUEUE_QUARANTINED" "$FM_WAKE_QUEUE_QUARANTINE_DIR" >&2
  fi
else
  echo "wake drain: malformed queue rows could not be quarantined; queue left untouched" >&2
fi

if [ -n "$ACK_THROUGH" ]; then
  fm_recovery_marker_snapshot "$RECOVERY_MARKER" || exit 1
  RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
  case "$RECOVERY_MARKER_TOKEN" in
    pending:*|acked:*) ;;
    *) echo "wake drain: acknowledgement found invalid recovery state; queue left untouched" >&2; exit 1 ;;
  esac
  ACK_INACTIVE_FINGERPRINTS=$(inactive_outcome_fingerprints "$ACK_THROUGH") || exit 1
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  if ! close_inactive_outcome_receipts "$ACK_INACTIVE_FINGERPRINTS"; then
    echo "wake drain: inactive outcome receipt could not be recorded safely" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=true
  fm_recovery_marker_snapshot "$RECOVERY_MARKER" || exit 1
  RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
  case "$RECOVERY_MARKER_TOKEN" in
    pending:*|acked:*) ;;
    *) echo "wake drain: recovery state became invalid while recording inactive outcome receipts; queue left untouched" >&2; exit 1 ;;
  esac
  DRAIN_TMP=$(mktemp "$STATE/.wake-queue.ack.XXXXXX") || exit 1
  chmod 0600 "$DRAIN_TMP" || exit 1
  awk -F '\t' -v cutoff="$ACK_THROUGH" '
    NF < 5 || $2 !~ /^[0-9]+$/ || $2 > cutoff { print }
  ' "$FM_WAKE_QUEUE" > "$DRAIN_TMP" || exit 1
  if [ ! -s "$DRAIN_TMP" ]; then
    fm_recovery_marker_ack "$RECOVERY_MARKER" "$ACK_GENERATION"
    RECOVERY_ACK_STATUS=$?
    case "$RECOVERY_ACK_STATUS" in
      0) ;;
      3)
        fm_recovery_marker_snapshot "$RECOVERY_MARKER" || exit 1
        RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
        case "$RECOVERY_MARKER_TOKEN" in
          pending:*|acked:*)
            [ "${RECOVERY_MARKER_TOKEN##*:}" != "$ACK_GENERATION" ] \
              || { echo "wake drain: matching recovery episode could not be retired safely" >&2; exit 1; }
            RECOVERY_ACK_MOVED=true
            ;;
          *)
            echo "wake drain: recovery state became invalid before episode retirement; queue left untouched" >&2
            exit 1
            ;;
        esac
        ;;
      *)
        echo "wake drain: recovery episode could not be retired safely; re-run bin/fm-wake-drain.sh and use the new WAKE_ACK_REQUIRED command" >&2
        exit 1
        ;;
    esac
  elif [ "${RECOVERY_MARKER_TOKEN##*:}" != "$ACK_GENERATION" ]; then
    RECOVERY_ACK_MOVED=true
  fi
  if ! _fm_atomic_replace "$DRAIN_TMP" "$FM_WAKE_QUEUE"; then
    echo "wake drain: acknowledged wakes could not be consumed safely" >&2
    exit 1
  fi
  DRAIN_TMP=
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  if [ "$RECOVERY_ACK_MOVED" = true ]; then
    printf 'wake drain: acknowledged wakes through %s, but a newer recovery episode is pending; re-run bin/fm-wake-drain.sh and use the new WAKE_ACK_REQUIRED command\n' \
      "$ACK_THROUGH" >&2
  fi
  exit 0
fi

if [ ! -s "$FM_WAKE_QUEUE" ]; then
  : > "$FM_WAKE_QUEUE"
  fm_recovery_marker_snapshot "$RECOVERY_MARKER" || true
  RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
  case "$RECOVERY_MARKER_TOKEN" in
    pending:downtime:*)
      fm_recovery_marker_begin_handling "$RECOVERY_MARKER" || {
        echo "wake drain: decision recovery could not begin handling safely" >&2
        exit 1
      }
      RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
      RECOVERY_ACK_REQUIRED=true
      ;;
    pending:handling:*) RECOVERY_ACK_REQUIRED=true ;;
  esac
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  (print_status_presentation) || true
  if [ "$RECOVERY_ACK_REQUIRED" = true ]; then
    printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 0 --recovery-generation %s\n' \
      "${RECOVERY_MARKER_TOKEN##*:}" >&2
  fi
  assert_watcher_liveness
  exit 0
fi

fm_recovery_marker_snapshot "$RECOVERY_MARKER" || true
RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
if [ -z "$RECOVERY_MARKER_TOKEN" ]; then
  if [ -e "$RECOVERY_MARKER" ] || [ -L "$RECOVERY_MARKER" ]; then
    echo "wake drain: durable wakes have invalid recovery state" >&2
    exit 1
  fi
  fm_recovery_marker_publish "$RECOVERY_MARKER" downtime || {
    echo "wake drain: legacy durable wakes could not be adopted safely" >&2
    exit 1
  }
elif [ "${RECOVERY_MARKER_TOKEN%%:*}" = acked ]; then
  fm_recovery_marker_publish "$RECOVERY_MARKER" downtime || {
    echo "wake drain: durable wakes could not enter a fresh recovery generation" >&2
    exit 1
  }
fi
fm_recovery_marker_begin_handling "$RECOVERY_MARKER" || {
  echo "wake drain: durable wakes could not begin handling safely" >&2
  exit 1
}
RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN

RAW_ROWS=$(fm_wake_print_deduped "$FM_WAKE_QUEUE") || exit "$?"
ACK_THROUGH=$(awk -F '\t' '$2 ~ /^[0-9]+$/ && $2 > max { max=$2 } END { print max + 0 }' "$FM_WAKE_QUEUE") || exit 1
case "${FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT:-0}" in
  0) ;;
  ''|*[!0-9]*) ;;
  *) sleep "$FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT" ;;
esac
if [ -n "$RAW_ROWS" ]; then
  printf '%s\n' "$RAW_ROWS" || exit "$?"
fi
fm_recovery_marker_snapshot "$RECOVERY_MARKER" || exit 1
RECOVERY_MARKER_TOKEN=$FM_RECOVERY_MARKER_TOKEN
case "$RECOVERY_MARKER_TOKEN" in
  pending:*|acked:*) ;;
  *) echo "wake drain: durable wakes have no recovery generation" >&2; exit 1 ;;
esac
fm_lock_release "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=false
printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through %s --recovery-generation %s\n' \
  "$ACK_THROUGH" "${RECOVERY_MARKER_TOKEN##*:}" >&2

(print_status_presentation "$RAW_ROWS") || true
assert_watcher_liveness
exit 0
