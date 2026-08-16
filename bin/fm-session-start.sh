#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# fm-bootstrap.sh, then separately inspect data/projects.md, data/secondmates.md,
# data/captain.md, data/captain-shared.md, data/learnings.md, then run
# fm-lock.sh, fm-wake-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status.
# Startup now prints must-trust live facts plus bounded representations of stable
# context, so repeated historical and curated bodies move to targeted reads.
# A linked disposable task worktree is not a Firstmate session: before any
# stage runs, the script identifies that worker plainly and exits without
# acquiring the lock or emitting fleet state. The primary checkout and marked
# secondmate homes keep the full behavior below.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-bootstrap.sh,
# fm-inactive-reconcile.sh, fm-wake-drain.sh, and fm-startup-network.sh as real
# subprocesses and prints their real output. It
# never re-implements their logic; all sequencing/formatting logic added here
# stays local to this file. Those five scripts remain fully working
# standalone with unchanged default behavior - other flows (fm-bootstrap.sh
# install <tools> after consent, /updatefirstmate, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its six mutating
# sweeps - is an opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag on fm-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only
#                       when this session actually holds the lock. Detect-only
#                       diagnostics always run. Bootstrap's six MUTATING sweeps
#                       (legacy PR-check migration, secondmate convergence,
#                       secondmate liveness, pending remote handoff retry,
#                       X-mode artifact writes, fleet sync) also run only when
#                       locked; network sweeps run in the deferred stage.
#   3. reconcile/drain - performs one bounded local inactive-terminal scan,
#                       then presents durable wakes and advances recovery
#                       handling state; both run only when locked.
#   4. supervision    - emit the operating block for the detected harness.
#   5. read-once      - state the contract governing all digest sources before
#                       any bulk data.
#   6. fleet digest   - a recovery-focused data/backlog.md listing, every
#                       state/*.meta, the latest per-line-capped active status event,
#                       an archived-status count, state/.afk, and a cheap per-task endpoint-liveness read:
#                       read-only, always runs.
#   7. network checks - harvest the deferred result without waiting.
#   8. context digest - a bounded prefix of data/projects.md, data/secondmates.md,
#                       data/captain.md, data/captain-shared.md, and data/learnings.md,
#                       with exact omission counts, paths, and content identities:
#                       read-only, always safe, always runs after live fleet identity.
#   9. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - converging
# secondmate homes, retrying pending handoff outboxes, writing X-mode artifacts,
# and fetching or fast-forwarding every project clone - before ever discovering
# another session already holds the lock. Two sessions racing those sweeps is
# exactly the hazard the lock exists to prevent, so locking first closes the
# hole outright: only the session that actually wins the lock ever touches
# shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in FM_BOOTSTRAP_DETECT_ONLY=1
# mode) for its local read-only detect lines - missing tools, the
# worktree-tangle check, the harness override, crew-dispatch validation,
# tasks-axi and quota-axi tool checks, and tasks-axi availability - none of
# which mutate shared state and all of which are safe to compute without
# verified lock ownership.
# Only projection cleanup, the six bootstrap mutating sweeps, and wake-queue
# presentation are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# BACKLOG DIGEST: startup is a recovery surface, so done rows are omitted,
# every in-flight, held, and blocked row is retained, and only ready queued
# work is bounded by FM_SESSION_START_QUEUED_LIMIT (default 20).
# When compatible tasks-axi is selected and available, the shared tasks-axi
# backend probe remains the compatibility owner and this script asks
# `tasks-axi list` for the compact identity fields plus blocked_by, hold_kind,
# and hold_reason, never body.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# this script prints only backlog section headings and item title lines, so
# title-line hold and blocked-by metadata remain visible while indented bodies
# stay out of the startup digest.
# Full bodies are targeted follow-up only: `tasks-axi show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
# Session-start asks fm-wake-drain.sh for only the latest historical annotation
# per signaled status file; the durable raw-wake presentation and folded OPEN
# DECISIONS are unchanged, and the omitted annotation count is explicit.
# Active-task status tails default to one line and are capped by
# bin/fm-line-cap-lib.sh, while the full status-log path remains beside each tail.
# Status files without live metadata are counted without re-reading their bodies;
# folded OPEN DECISIONS preserves unresolved choices and blockers from those logs.
# Each stable context file prints at most FM_SESSION_START_CONTEXT_LINES lines
# (default 12), also line-capped, and identifies an omitted suffix by exact line
# count, full path, and content digest for a targeted read when relevant.
#
# The whole digest is bounded by FM_SESSION_START_TIMEOUT (default 120s).
# When the bound is hit, the parent names the incomplete stage and all stages
# that were not reached while preserving output already emitted by the child.
#
# Usage: fm-session-start.sh [--reemit]
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
#
#   --reemit re-verifies lock ownership, reruns detect-only bootstrap, drains
#   queued wakes, and reprints the same bounded startup/recovery digest without
#   repeating startup's mutating bootstrap sweeps or stale Herdr projection cleanup.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
COMPLETION_FILE="$STATE/.session-start-complete"

REEMIT=0
for arg in "$@"; do
  case "$arg" in
    --reemit) REEMIT=1 ;;
    -h|--help)
      sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-session-start.sh" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf 'fm-session-start: unknown argument: %s\n' "$arg" >&2
      printf 'usage: fm-session-start.sh [--reemit]\n' >&2
      exit 2
      ;;
  esac
done

# A linked worktree that is not this repository's main checkout is a disposable
# crewmate task worktree, not a Firstmate operational home. Stop before the
# lock or any digest stage so inherited Firstmate instructions cannot make a
# worker adopt primary-session duties. Registered secondmate homes carry their
# own durable identity marker and remain legitimate Firstmate homes.
#
# Both halves of that judgement have one owner, bin/fm-primary-scope-lib.sh,
# and are reused rather than re-derived here: fm_root_is_secondmate_home is the
# marker predicate (a symlinked, empty, or malformed marker is NOT a home), and
# fm_root_worktree_kind is how the fleet distinguishes a plain checkout from a
# linked worktree.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

fm_session_start_is_task_worktree() {
  local root_real home_real
  ! fm_root_is_secondmate_home "$FM_HOME" || return 1
  root_real=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || return 1
  home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  # An explicitly distinct operational home may legitimately execute tracked
  # code from a linked checkout (including tests and isolated installations).
  # A task worker is the self-home shape: its code root is also its FM_HOME.
  [ "$root_real" = "$home_real" ] || return 1
  [ "$(fm_root_worktree_kind "$FM_ROOT")" = linked ]
}

if fm_session_start_is_task_worktree; then
  printf '%s\n' 'CREWMATE TASK WORKTREE - SESSION START DOES NOT APPLY'
  printf '%s\n' 'You are a crewmate in a disposable task worktree, not the lock-owning Firstmate session.'
  printf '%s\n' 'Do not acquire the fleet lock or inspect the fleet digest; execute the assigned brief in this worktree.'
  exit 0
fi

SESSION_START_STAGES='lock bootstrap wake-queue supervision-instructions read-once fleet-state network-checks context next-step'

stage() {
  [ -n "${STAGE_MARKER_FILE:-}" ] || return 0
  printf '%s\n' "$1" > "$STAGE_MARKER_FILE" 2>/dev/null || true
}

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

if [ -z "${FM_SESSION_START_STAGE_FILE:-}" ]; then
  SESSION_START_BUDGET=${FM_SESSION_START_TIMEOUT:-120}
  case "$SESSION_START_BUDGET" in ''|*[!0-9]*|0) SESSION_START_BUDGET=120 ;; esac
  SESSION_START_STAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-session-start-stage.XXXXXX" 2>/dev/null) || SESSION_START_STAGE_FILE=
  [ -n "$SESSION_START_STAGE_FILE" ] || SESSION_START_STAGE_FILE=/dev/null
  fm_run_timed "$SESSION_START_BUDGET" \
    env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
    "$SCRIPT_DIR/fm-session-start.sh" "$@"
  SESSION_START_RC=$?
  if [ "$SESSION_START_RC" -eq 124 ]; then
    SESSION_START_LAST_STAGE=$(cat "$SESSION_START_STAGE_FILE" 2>/dev/null) || SESSION_START_LAST_STAGE=
    [ -n "$SESSION_START_LAST_STAGE" ] || SESSION_START_LAST_STAGE=unknown
    SESSION_START_PENDING=$(
      printf '%s\n' "$SESSION_START_STAGES" | tr ' ' '\n' |
        awk -v from="$SESSION_START_LAST_STAGE" '$0 == from { seen = 1 } seen' | tr '\n' ' '
    )
    [ -n "${SESSION_START_PENDING# }" ] || SESSION_START_PENDING='(unknown - the digest may be incomplete anywhere)'
    BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '\n%s\n' "$BAR"
    printf '●  STARTUP TRUNCATED - SESSION START HIT ITS %ss RUNTIME BOUND\n' "$SESSION_START_BUDGET"
    printf '●  It stopped during the "%s" stage, so everything above is complete only up to that point.\n' "$SESSION_START_LAST_STAGE"
    printf '●  RECONCILE these stages before acting on anything they would have shown:\n'
    printf '●    %s\n' "${SESSION_START_PENDING% }"
    printf '●  Rerun bin/fm-session-start.sh now. If it truncates again, raise\n'
    printf '●  FM_SESSION_START_TIMEOUT and report the slow stage.\n'
    printf '%s\n' "$BAR"
  fi
  if [ "$SESSION_START_STAGE_FILE" != /dev/null ]; then
    rm -f "$SESSION_START_STAGE_FILE" 2>/dev/null || true
  fi
  exit 0
fi

STAGE_MARKER_FILE="$FM_SESSION_START_STAGE_FILE"
unset FM_SESSION_START_STAGE_FILE

PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

STATUS_TAIL=${FM_SESSION_START_STATUS_TAIL:-1}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=1 ;; esac
CONTEXT_LINES=${FM_SESSION_START_CONTEXT_LINES:-12}
case "$CONTEXT_LINES" in ''|*[!0-9]*|0) CONTEXT_LINES=12 ;; esac
QUEUED_LIMIT=${FM_SESSION_START_QUEUED_LIMIT:-20}
case "$QUEUED_LIMIT" in ''|*[!0-9]*|0) QUEUED_LIMIT=20 ;; esac
BACKLOG_FIELDS=blocked_by,hold_kind,hold_reason

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# print_file_bounded_or_absent <path> <label>: a bounded, line-capped prefix
# under a labeled subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (captain.md absent = firstmate
# repo built-in defaults, projects.md absent = rebuild from clones, etc. -
# AGENTS.md section 3) and must never be confused with an empty-but-present file.
# An omitted suffix is identified by its exact line count, full path, and digest
# so the primary can target the source when this turn actually needs it.
print_file_bounded_or_absent() {
  local path=$1 label=$2 line total omitted digest
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        fm_cap_line "$line"
      done < <(head -n "$CONTEXT_LINES" "$path")
      total=$(awk 'END { print NR + 0 }' "$path")
      if [ "$total" -gt "$CONTEXT_LINES" ]; then
        omitted=$((total - CONTEXT_LINES))
        digest=$(hash_file "$path" 2>/dev/null || printf unavailable)
        printf '(%s more line(s) omitted; full file: %s; content %s)\n' \
          "$omitted" "$path" "$digest"
      fi
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_backlog_pointer() {
  printf 'Full task bodies remain available on demand: tasks-axi show <id> --full when compatible tasks-axi is available, or data/backlog.md.\n'
}

MANUAL_KEEP_RE='[(]hold|blocked-by:'

print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; done rows omitted; every in-flight, held, and blocked title line kept; other queued bounded to %s; indented task bodies omitted)\n' \
    "$reason" "$QUEUED_LIMIT"
  awk -v max="$QUEUED_LIMIT" -v keep_re="$MANUAL_KEEP_RE" '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      if (state != "" && state != "done") print $0
      next
    }
    state == "in_flight" && /^[-*][[:space:]]+/ { in_flight++; print $0; next }
    state == "done" && /^[-*][[:space:]]+/ { done_total++; next }
    state == "queued" && /^[-*][[:space:]]+/ {
      queued_total++
      if ($0 ~ keep_re) { gated++; print $0; next }
      if (plain_shown < max) { plain_shown++; print $0 }
      next
    }
    END {
      plain_total = queued_total - gated
      if (in_flight + queued_total + done_total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d in-flight, %d held or blocked queued, %d of %d other queued title line(s); %d done row(s) omitted)\n", \
          in_flight, gated, plain_shown, plain_total, done_total
        if (plain_total > plain_shown) {
          printf "(%d more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)\n", plain_total - plain_shown
        }
      }
    }
  ' "$path"
}

strip_axi_help() {
  awk '/^help\[/ { exit } { print }'
}

print_ready_queued_bounded() {
  local ready=$1 path=$2
  printf '%s\n' "$ready" | awk -v max="$QUEUED_LIMIT" -v path="$path" '
    /^help\[/ { exit }
    /^ready\[/ { rows = 1; print; next }
    rows && /^[[:space:]]/ {
      total++
      if (shown < max) { print; shown++ }
      next
    }
    { rows = 0; print }
    END {
      if (total > 0) {
        printf "(shown %d of %d ready queued item(s))\n", shown, total
        if (total > shown) {
          printf "(%d more queued - tasks-axi ready --file %s)\n", total - shown, path
        }
      }
    }
  '
}

print_backlog_tasks_axi_compact() {
  local path=$1 in_flight held blocked ready err
  if ! in_flight=$(tasks-axi list --file "$path" --state in_flight --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$in_flight
  elif ! held=$(tasks-axi list --file "$path" --state held --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$held
  elif ! blocked=$(tasks-axi list --file "$path" --state queued --blocked --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$blocked
  elif ! ready=$(tasks-axi ready --file "$path" 2>&1); then
    err=$ready
  else
    printf 'compact backlog listing (tasks-axi; done rows omitted; every in-flight, held, and blocked row shown in full; ready queued bounded to %s; task bodies omitted)\n' \
      "$QUEUED_LIMIT"
    printf '\nin flight:\n'
    printf '%s\n' "$in_flight" | strip_axi_help
    printf '\nheld (captain- or time-gated; an in-flight item that is also held appears in both groups):\n'
    printf '%s\n' "$held" | strip_axi_help
    printf '\nblocked queued:\n'
    printf '%s\n' "$blocked" | strip_axi_help
    printf '\nready queued (dispatchable now):\n'
    print_ready_queued_bounded "$ready" "$path"
    return 0
  fi
  printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
  printf '%s\n' "$err"
  print_backlog_manual_compact "$path" "fallback"
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if fm_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact "$path"
      elif fm_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact "$path" "manual backend"
      else
        print_backlog_manual_compact "$path" "tasks-axi unavailable or incompatible"
      fi
      print_backlog_pointer
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1 line
  printf 'status tail (last %s line(s), each capped at %s characters, wake-EVENT history, not current state; full log: %s):\n' \
    "$STATUS_TAIL" "$FM_LINE_CAP_DEFAULT" "$status"
  while IFS= read -r line || [ -n "$line" ]; do
    fm_cap_line "$line"
  done < <(tail -n "$STATUS_TAIL" "$status")
}

hash_file() {
  local file=$1
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

pi_extension_loaded() {
  local marker=$1 expected_version=$2 lock=$3 marker_version marker_pid lock_pid
  [ -f "$marker" ] && [ -f "$lock" ] && [ -n "$expected_version" ] || return 1
  marker_version=$(sed -n '1p' "$marker")
  marker_pid=$(sed -n '2p' "$marker")
  lock_pid=$(sed -n '1p' "$lock")
  [ -n "$marker_pid" ] || return 1
  [ "$marker_version" = "$expected_version" ] && [ "$marker_pid" = "$lock_pid" ]
}

if [ "$REEMIT" -eq 1 ]; then
  section "SESSION START (CONTEXT RE-EMIT) - $FM_HOME"
  printf 'This session already took the helm at startup and has only lost context.\n'
  printf 'Lock ownership is re-verified, durable records are reprinted, and queued\n'
  printf 'wakes are presented for handling, but startup mutation sweeps are not repeated.\n'
else
  section "SESSION START - $FM_HOME"
fi

# --- 1. lock -----------------------------------------------------------
stage lock
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: PR-check migration, stale Herdr child cleanup,\n'
    printf '●  secondmate convergence, secondmate liveness, pending remote handoff retry,\n'
    printf '●  X-mode artifacts, fleet sync, and wake-queue presentation. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi
if [ "$READ_ONLY" -eq 0 ]; then
  if [ "$REEMIT" -eq 0 ]; then
    rm -f "$COMPLETION_FILE" 2>/dev/null || true
  fi
  fm_trace_context_session_start "$CONFIG" "$STATE/.trace-context-effective"
  NETWORK_STAGE_LOCKED=1
  [ "$REEMIT" -eq 0 ] || NETWORK_STAGE_LOCKED=0
  NETWORK_LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  "$SCRIPT_DIR/fm-startup-network.sh" start \
    --locked "$NETWORK_STAGE_LOCKED" --lock-pid "$NETWORK_LOCK_PID" \
    --harvest-pid $$ >/dev/null 2>&1 || true
fi

# --- 2. bootstrap --------------------------------------------------------
stage bootstrap
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
elif [ "$REEMIT" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_LOCKED=1 FM_BOOTSTRAP_NETWORK=skip \
    "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$(
    "$SCRIPT_DIR/fm-herdr-session-cleanup.sh" 2>&1 || true
    FM_BOOTSTRAP_NETWORK=skip "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1
  )
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

# --- 3. wake-drain -------------------------------------------------------
# Presented records are this turn's first work queue and remain durable until
# post-handling acknowledgement. The drain's separate OPEN DECISIONS section
# remains actionable even when that queue is empty (AGENTS.md sections 3 and 8).
# The drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue because it lacks mutation
# authority, and another session may be actively handling it. It still runs
# fm-guard.sh directly with non-mutating advisory text, so the same alarms
# surface without repair commands.
stage wake-queue
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified fleet-lock ownership.\n' "$QLEN"
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  INACTIVE_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-inactive-reconcile.sh" scan --startup 2>&1) || INACTIVE_OUT=
  if [ -n "$INACTIVE_OUT" ]; then
    printf 'inactive outcome reconciliation: %s\n' "$INACTIVE_OUT"
  fi
  DRAIN_OUT=$(FM_WAKE_ANNOTATION_LIMIT=1 "$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi

# --- 4. supervision operating instructions ----------------------------------
stage supervision-instructions
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
AFK_SUPERVISOR_ALIVE=0
# bin/fm-wake-lib.sh owns daemon-lock identity validation, shared with
# bin/fm-afk-start.sh and bin/fm-turnend-guard.sh.
if [ "$AFK_PRESENT" -eq 1 ] && fm_daemon_lock_alive "$STATE" "$SCRIPT_DIR/fm-supervise-daemon.sh"; then
  AFK_SUPERVISOR_ALIVE=1
fi
# A live daemon still owns away supervision when its watcher beacon has gone
# stale, but pane-level staleness detection stops meanwhile, so the digest names
# that degraded half instead of reporting plain health. bin/fm-guard.sh reads the
# same beacon predicate for its degraded banner.
AFK_GRACE=${FM_GUARD_GRACE:-300}
AFK_WATCHER_FRESH=false
AFK_BEACON_DESC=never
if [ "$AFK_SUPERVISOR_ALIVE" -eq 1 ]; then
  fm_supervision_status "$STATE" "$AFK_GRACE"
  AFK_WATCHER_FRESH=$FM_SUP_WATCHER_FRESH
  AFK_BEACON_DESC=$FM_SUP_BEACON_DESC
fi
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
  PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_RESTART_COMMAND=$PRIMARY_HARNESS
  [ "$PRIMARY_HARNESS" != pi ] || PI_RESTART_COMMAND='plain pi'
  PI_WATCH_VERSION=$(hash_file "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(hash_file "$PI_TURNEND_EXT" || printf '')
  if ! pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" \
    || ! pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
"$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --x-mode "$X_MODE_PRESENT"

# --- 5. read-once contract -------------------------------------------------
stage read-once
section "READ-ONCE CONTRACT"
cat <<'EOF'
Everything this turn must trust is represented below: every live state/*.meta,
a compact data/backlog.md listing, the latest bounded status event for each live
task, archived-status counts, AFK state, endpoint liveness, and bounded prefixes
of data/projects.md, data/secondmates.md, data/captain.md,
data/captain-shared.md, and data/learnings.md.

Read a source directly only when this digest marked it ABSENT or corrupt, a
specific full task body or older status history is needed, a capped line's tail
matters, this turn needs context beyond a file's disclosed bounded prefix,
omitted queued work is needed, NETWORK CHECKS remains in progress, or STARTUP
TRUNCATED named the stage that would have emitted it.

If a later context compaction drops this digest, restore it once with
`bin/fm-session-start.sh --reemit` and resume this trust, rather than re-reading
these files individually.
EOF

# --- 6. fleet-state digest ---------------------------------------------
# Fleet identity precedes stable context so tail truncation cannot hide current
# task endpoints behind curated memory that is recoverable with a targeted read.
stage fleet-state
section "FLEET STATE"
print_backlog_compact "$DATA/backlog.md" "data/backlog.md"

subsection "Work under way (state/*.meta)"
META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  printf '\n--- %s ---\n' "$id"
  cat "$meta"

  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$window" ]; then
    backend=$(fm_backend_of_meta "$meta")
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
      printf 'endpoint: alive (backend=%s window=%s)\n' "$backend" "$window"
    else
      printf 'endpoint: dead (backend=%s window=%s)\n' "$backend" "$window"
    fi
  else
    printf 'endpoint: unknown (no window recorded)\n'
  fi

  status="$STATE/$id.status"
  if [ -f "$status" ]; then
    print_status_tail "$status"
  else
    printf 'status tail: (no status file yet: %s)\n' "$status"
  fi
done
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Archived status logs (state/*.status without matching .meta)"
ORPHAN_STATUS_FOUND=0
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  ORPHAN_STATUS_FOUND=$((ORPHAN_STATUS_FOUND + 1))
done
if [ "$ORPHAN_STATUS_FOUND" -gt 0 ]; then
  printf '%s archived status log(s) omitted; durable status logs retain unresolved blockers and choices; read %s/*.status only when a targeted decision or older history is needed.\n' \
    "$ORPHAN_STATUS_FOUND" "$STATE"
else
  printf '(none)\n'
fi

subsection "AFK"
if [ -e "$STATE/.afk" ]; then
  if [ "$AFK_SUPERVISOR_ALIVE" -eq 1 ] && [ "$AFK_WATCHER_FRESH" = true ]; then
    printf 'present - away-mode supervision is active; the daemon owns the watcher.\n'
  elif [ "$AFK_SUPERVISOR_ALIVE" -eq 1 ]; then
    printf 'present - away-mode supervision is active but DEGRADED; the daemon owns the watcher and keeps its marker rechecks and status-file catch-all scan running, but its watcher has no fresh beacon (last beat: %s, grace %ss), so pane-level staleness detection is not running; read state/.supervise-daemon.log for the watcher exit reason.\n' \
      "$AFK_BEACON_DESC" "$AFK_GRACE"
  else
    printf 'present - away-mode flag is present, but the supervisor is missing; load /afk and ensure the daemon is running.\n'
  fi
else
  printf 'absent\n'
fi

# Public commitments made through the myfirstmate relay. A promise to reply in a
# public thread must survive compaction and restart, so it is surfaced from disk
# here rather than from conversation memory. fm-public-followup-lib.sh owns both
# gates: a home that never opted into the relay runs one [ -f ] test, prints no
# subsection, and never reaches fm-public-followup.sh.
if fm_pf_relay_active "$FM_HOME" \
  && { fm_pf_has_registrations "$STATE" || fm_pf_has_events "$STATE"; }; then
  PUBLIC_FOLLOWUP=$("$SCRIPT_DIR/fm-public-followup.sh" pending 2>/dev/null) || PUBLIC_FOLLOWUP=
  if [ -n "$PUBLIC_FOLLOWUP" ]; then
    subsection "Public commitments awaiting delivery"
    printf '%s\n' "$PUBLIC_FOLLOWUP"
    printf '\nEach line is a public reply this home still owes. Reconcile terminal results with\n'
    printf '%s/bin/fm-public-followup.sh consume, then deliver a ready one with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh deliver <id>. Load fmx-respond for the procedure.\n' "$FM_ROOT"
  fi
fi

# --- 7. deferred network result ---------------------------------------------
stage network-checks
section "NETWORK CHECKS"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - GitHub authentication, project clone refresh,\n'
  printf 'secondmate liveness and convergence, and pending handoff delivery were not run.\n'
  printf 'The session holding the fleet lock owns those checks and their mutations.\n'
else
  "$SCRIPT_DIR/fm-startup-network.sh" harvest --pid $$ 2>&1 || true
fi

# --- 8. context digest -----------------------------------------------------
stage context
section "CONTEXT"
print_file_bounded_or_absent "$DATA/projects.md" "data/projects.md"
print_file_bounded_or_absent "$DATA/secondmates.md" "data/secondmates.md"
print_file_bounded_or_absent "$DATA/captain.md" "data/captain.md"
print_file_bounded_or_absent "$DATA/captain-shared.md" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)"
print_file_bounded_or_absent "$DATA/learnings.md" "data/learnings.md"

# --- 9. closing reminder -----------------------------------------------
stage next-step
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
elif [ -f "$CONFIG/x-mode.env" ]; then
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The bounded digest above is complete. The READ-ONCE CONTRACT near its top
governs any targeted follow-up reads.
EOF

if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  COMPLETION_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$COMPLETION_PID" in ''|*[!0-9]*) COMPLETION_PID= ;; esac
  COMPLETION_TMP=$(mktemp "$STATE/.session-start-complete.XXXXXX" 2>/dev/null || true)
  if [ -n "$COMPLETION_PID" ] && [ -n "$COMPLETION_TMP" ] \
    && printf '%s\n' "$COMPLETION_PID" > "$COMPLETION_TMP" 2>/dev/null \
    && mv -f "$COMPLETION_TMP" "$COMPLETION_FILE" 2>/dev/null; then
    :
  else
    [ -z "$COMPLETION_TMP" ] || rm -f "$COMPLETION_TMP" 2>/dev/null || true
    printf '\nSESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.\n'
  fi
fi

exit 0
