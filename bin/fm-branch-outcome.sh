#!/usr/bin/env bash
# fm-branch-outcome.sh - the durable outcome store for the Pi supervision
# branch (docs/pi-supervision-branch.md).
#
# CONTRACT (this header is the one owner of the store's format).
#   - Store: $STATE/branch-outcomes.jsonl, strictly APPEND-ONLY. One JSON
#     object per line: {"seq":N,"epoch":N,"task":"...","wake":"...",
#     "verdict":"routine"|"captain"|"firstmate-action",
#     "summary":"...","silent":true|false}.
#     Legacy rows without `silent` remain valid and are treated as visible.
#     Existing lines are never rewritten, reordered, or deleted by any
#     subcommand; the read state lives
#     entirely in the cursor sidecar so marking outcomes read cannot disturb
#     the log. Retention: the log is small (one line per handled fleet event)
#     and truncation, if ever needed, is a captain-approved manual act.
#   - Cursor: $STATE/.branch-outcomes-cursor holds the highest seq consumed
#     after branch delivery, routine store-only handling, or locked session-start
#     replay. Records above the cursor are "unread": the branch stored them but
#     did not complete its delivery or replay path. Firstmate-action rows also
#     have a durable per-wake marker under $STATE/branch-action; the marker is
#     pending until main's hidden turn starts and started after that handoff.
#     A pending action is replayed as its operational action envelope, never as
#     raw JSON.
#   - Every mutation runs under $STATE/.branch-outcomes.lock so the branch
#     extension and a concurrent session-start replay cannot interleave.
#   - The store is written BEFORE any captain or firstmate-action outcome is
#     delivered to main (store-first durability): routine outcomes have no
#     main handoff, and nothing about a handled event depends on conversation
#     memory.
#
# Usage:
#   fm-branch-outcome.sh append --task <id> --verdict routine|captain|firstmate-action \
#       --summary <text> [--wake <text>] [--silent true|false]
#     Append one outcome record; prints the assigned seq.
#   fm-branch-outcome.sh append-action --task <id> --wake-seq <seq> \
#       --summary <text> [--wake <text>]
#     Append or recover one firstmate-action row and its per-wake marker.
#   fm-branch-outcome.sh action-prepare --seq <seq>
#     Ensure the firstmate-action marker exists and print pending|started.
#   fm-branch-outcome.sh action-status --seq <seq>
#     Print pending|started|none for a firstmate-action row.
#   fm-branch-outcome.sh action-started --seq <seq>
#     Mark the hidden main turn as started.
#   fm-branch-outcome.sh render --seq <seq>
#     Render a main-bound outcome as its operational input envelope.
#   fm-branch-outcome.sh unread
#     Print every unread record (raw JSONL). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-read --through <seq>
#     Advance the cursor (never backwards) after handing the records to Pi.
#   fm-branch-outcome.sh list [--recent <n>]
#     Print the last n records (default 20), read or not.
#   fm-branch-outcome.sh startup-replay
#     Session-start recovery: print unread records whose `silent` field is not
#     true under a labeled header into the locked startup digest, skip routine
#     store-only rows, and mark every unread row read. Prints nothing when
#     nothing visible is unread, so a home that never ran the branch stays
#     silent. Run it only when the session holds the lock (fm-session-start.sh
#     owns the call site).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
CURSOR="$STATE/.branch-outcomes-cursor"
LOCK="$STATE/.branch-outcomes.lock"
ACTION_DIR="$STATE/branch-action"

usage() {
  echo "usage: fm-branch-outcome.sh append|append-action|action-prepare|action-status|action-started|render ... | unread | mark-read --through <seq> | list [--recent <n>] | startup-replay" >&2
  exit 2
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

read_cursor() {
  local value
  value=$(head -n 1 "$CURSOR" 2>/dev/null | tr -cd '0-9' || true)
  printf '%s\n' "${value:-0}"
}

last_seq() {
  local value
  [ -s "$STORE" ] || { printf '0\n'; return 0; }
  value=$(tail -n 1 "$STORE" 2>/dev/null | jq -er '
    select(type == "object")
    | select(
        keys == ["epoch", "seq", "summary", "task", "verdict", "wake"]
        or (keys == ["epoch", "seq", "silent", "summary", "task", "verdict", "wake"] and (.silent | type) == "boolean")
      )
    | select((.seq | type) == "number" and .seq >= 1 and .seq == (.seq | floor))
    | select((.epoch | type) == "number" and .epoch >= 0 and .epoch == (.epoch | floor))
    | select((.task | type) == "string" and (.wake | type) == "string")
    | select((.summary | type) == "string" and (.verdict == "routine" or .verdict == "captain" or .verdict == "firstmate-action"))
    | .seq
  ') || return 1
  printf '%s\n' "$value"
}

record_seq() { # <jsonl-line>
  printf '%s\n' "$1" | sed -n 's/^{"seq":\([0-9]*\),.*/\1/p'
}

record_for_seq() { # <seq>
  local wanted=$1 line seq
  [ -s "$STORE" ] || return 1
  while IFS= read -r line; do
    seq=$(record_seq "$line")
    [ "$seq" = "$wanted" ] || continue
    printf '%s\n' "$line"
    return 0
  done < "$STORE"
  return 1
}

append_record_locked() { # <task> <verdict> <summary> <wake> <silent> <seq>
  local task=$1 verdict=$2 summary=$3 wake=$4 silent=$5 seq=$6
  printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s}\n' \
    "$seq" "$(date +%s)" "$(json_escape "$task")" "$(json_escape "$wake")" \
    "$verdict" "$(json_escape "$summary")" "$silent" >> "$STORE"
}

action_marker_path_for_wake() { # <wake-seq>
  printf '%s/wake-%s.json\n' "$ACTION_DIR" "$1"
}

action_marker_path_for_outcome() { # <outcome-seq>
  local outcome=$1 candidate
  [ -d "$ACTION_DIR" ] || return 1
  for candidate in "$ACTION_DIR"/wake-*.json "$ACTION_DIR"/outcome-*.json; do
    [ -f "$candidate" ] || continue
    if jq -e --argjson seq "$outcome" 'type == "object" and .outcome_seq == $seq' "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

write_action_marker() { # <path> <wake-seq-or-empty> <outcome-seq-or-empty> <state> <task> <summary> <wake>
  local path=$1 wake_seq=$2 outcome_seq=$3 marker_state=$4 task=$5 summary=$6 wake=$7 tmp
  mkdir -p "$ACTION_DIR"
  tmp=$(mktemp "$ACTION_DIR/.marker.tmp.XXXXXX")
  if [ -n "$wake_seq" ]; then
    jq -cn \
      --arg wake_seq "$wake_seq" \
      --arg task "$task" \
      --arg summary "$summary" \
      --arg wake "$wake" \
      --arg state "$marker_state" \
      --arg outcome_seq "$outcome_seq" \
      '{version:"fm-branch-action-v1",wake_seq:($wake_seq|tonumber),outcome_seq:(if $outcome_seq == "" then null else ($outcome_seq|tonumber) end),state:$state,task:$task,verdict:"firstmate-action",summary:$summary,wake:$wake,silent:false}' > "$tmp"
  else
    jq -cn \
      --arg task "$task" \
      --arg summary "$summary" \
      --arg wake "$wake" \
      --arg state "$marker_state" \
      --arg outcome_seq "$outcome_seq" \
      '{version:"fm-branch-action-v1",wake_seq:null,outcome_seq:(if $outcome_seq == "" then null else ($outcome_seq|tonumber) end),state:$state,task:$task,verdict:"firstmate-action",summary:$summary,wake:$wake,silent:false}' > "$tmp"
  fi
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path"
}

update_action_marker() { # <path> <jq-filter>
  local path=$1 filter=$2 tmp
  tmp=$(mktemp "$ACTION_DIR/.marker.tmp.XXXXXX")
  jq "$filter" "$path" > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path"
}

action_marker_state() { # <path>
  jq -er 'select(type == "object" and .version == "fm-branch-action-v1" and (.state == "pending" or .state == "started")) | .state' "$1"
}

find_matching_action_record() { # <task> <summary> <wake>
  local task=$1 summary=$2 wake=$3 line seq
  [ -s "$STORE" ] || return 1
  while IFS= read -r line; do
    if printf '%s\n' "$line" | jq -e \
      --arg task "$task" --arg summary "$summary" --arg wake "$wake" \
      'type == "object" and .verdict == "firstmate-action" and .task == $task and .summary == $summary and .wake == $wake' \
      >/dev/null 2>&1; then
      seq=$(record_seq "$line")
      [ -n "$seq" ] || return 1
      printf '%s\n' "$seq"
      return 0
    fi
  done < "$STORE"
  return 1
}

action_marker_for_seq() { # <outcome-seq>
  local outcome=$1 path
  path=$(action_marker_path_for_outcome "$outcome" 2>/dev/null || true)
  if [ -n "$path" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  return 1
}

ensure_action_marker_for_record_locked() { # <record-line>
  local line=$1 seq task summary wake path
  seq=$(record_seq "$line") || return 1
  task=$(printf '%s\n' "$line" | jq -er '.task') || return 1
  summary=$(printf '%s\n' "$line" | jq -er '.summary') || return 1
  wake=$(printf '%s\n' "$line" | jq -er '.wake') || return 1
  path=$(action_marker_for_seq "$seq" 2>/dev/null || true)
  if [ -z "$path" ]; then
    path="$ACTION_DIR/outcome-$seq.json"
    write_action_marker "$path" "" "$seq" pending "$task" "$summary" "$wake" || return 1
  fi
  printf '%s\n' "$path"
}

reconcile_action_markers_locked() {
  local path task summary wake seq existing
  [ -d "$ACTION_DIR" ] || return 0
  for path in "$ACTION_DIR"/wake-*.json; do
    [ -f "$path" ] || continue
    jq -e 'type == "object" and .version == "fm-branch-action-v1" and (.state == "pending" or .state == "started") and (.wake_seq | type == "number") and .verdict == "firstmate-action" and (.task | type == "string") and (.summary | type == "string") and (.wake | type == "string")' "$path" >/dev/null 2>&1 || return 1
    seq=$(jq -r '.outcome_seq // empty' "$path") || return 1
    if [ -z "$seq" ]; then
      task=$(jq -er '.task' "$path") || return 1
      summary=$(jq -er '.summary' "$path") || return 1
      wake=$(jq -er '.wake' "$path") || return 1
      existing=$(find_matching_action_record "$task" "$summary" "$wake" 2>/dev/null || true)
      if [ -z "$existing" ]; then
        if ! LAST_SEQ=$(last_seq); then return 1; fi
        existing=$(( LAST_SEQ + 1 ))
        append_record_locked "$task" firstmate-action "$summary" "$wake" false "$existing" || return 1
      fi
      update_action_marker "$path" ".outcome_seq = $existing" || return 1
    fi
  done
}

render_record() { # <record-line>
  local line=$1 verdict task summary body encoded encoder
  verdict=$(printf '%s\n' "$line" | jq -er '.verdict') || return 1
  case "$verdict" in
    captain)
      body='This is a supervision outcome delivered automatically by the supervision branch. It was not typed by the captain. The fleet event is already handled: do not re-drain, re-run, or acknowledge it. Do not take another fleet action from this delivery. This outcome is captain-facing: give the captain a visible response now. Use your judgment over the wording and how to incorporate it, not whether to surface it. An outcome that directly answers an explicit captain request is captain-facing, regardless of whether it is healthy, routine, measured, actionable, or requires a decision.'
      ;;
    firstmate-action)
      body='This is a supervision outcome delivered automatically by the supervision branch. It was not typed by the captain. The wake is already acknowledged: do not re-drain, re-run, or acknowledge it. The downstream authorized action is not done. Perform that action now, then report the result. Do not merely relay this worker outcome. Use the standing authority and contracted next step already in fleet context; stop only if the action reaches a genuine captain-only boundary.'
      ;;
    *) return 1 ;;
  esac
  task=$(printf '%s\n' "$line" | jq -er '.task') || return 1
  summary=$(printf '%s\n' "$line" | jq -er '.summary') || return 1
  body=$(printf '%s\n\n%s: %s' "$body" "$task" "$summary")
  encoder=${FM_OPERATIONAL_INPUT_SCRIPT-}
  [ -n "$encoder" ] || encoder="$SCRIPT_DIR/fm-operational-input.sh"
  if encoded=$(printf '%s' "$body" | "$encoder" encode branch-outcome 2>/dev/null); then
    printf '%s\n' "$encoded"
  else
    printf '%s\n' "$body"
  fi
}

print_unread() {
  local cursor seq line
  cursor=$(read_cursor)
  [ -s "$STORE" ] || return 0
  while IFS= read -r line; do
    seq=$(record_seq "$line")
    [ -n "$seq" ] || continue
    [ "$seq" -gt "$cursor" ] || continue
    printf '%s\n' "$line"
  done < "$STORE"
}

advance_cursor() { # <seq>
  local through=$1 cursor tmp
  cursor=$(read_cursor)
  [ "$through" -gt "$cursor" ] || return 0
  tmp=$(mktemp "$STATE/.branch-outcomes-cursor.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$CURSOR"
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    TASK=''
    VERDICT=''
    SUMMARY=''
    WAKE=''
    SILENT=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --verdict) VERDICT=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --silent) SILENT=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    [ -n "$SUMMARY" ] || usage
    case "$VERDICT" in routine|captain|firstmate-action) ;; *) usage ;; esac
    case "$SILENT" in true|false) ;; *) usage ;; esac
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome store has a malformed final record" >&2
      exit 1
    fi
    SEQ=$(( LAST_SEQ + 1 ))
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s}\n' \
      "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
      "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" >> "$STORE"
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    ;;
  append-action)
    TASK=''
    SUMMARY=''
    WAKE=''
    WAKE_SEQ=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --wake-seq) WAKE_SEQ=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    [ -n "$SUMMARY" ] || usage
    case "$WAKE_SEQ" in ''|*[!0-9]*) usage ;; esac
    fm_lock_acquire_wait "$LOCK"
    mkdir -p "$ACTION_DIR"
    MARKER=$(action_marker_path_for_wake "$WAKE_SEQ")
    if [ -f "$MARKER" ]; then
      if ! jq -e \
        --arg wake_seq "$WAKE_SEQ" --arg task "$TASK" --arg summary "$SUMMARY" --arg wake "$WAKE" \
        'type == "object" and .version == "fm-branch-action-v1" and .wake_seq == ($wake_seq|tonumber) and .task == $task and .verdict == "firstmate-action" and .summary == $summary and .wake == $wake and (.state == "pending" or .state == "started")' \
        "$MARKER" >/dev/null 2>&1; then
        fm_lock_release "$LOCK"
        echo "error: firstmate-action wake marker does not match the repeated report" >&2
        exit 1
      fi
      SEQ=$(jq -r '.outcome_seq // empty' "$MARKER")
      if [ -z "$SEQ" ]; then
        SEQ=$(find_matching_action_record "$TASK" "$SUMMARY" "$WAKE" 2>/dev/null || true)
        if [ -z "$SEQ" ]; then
          if ! LAST_SEQ=$(last_seq); then
            fm_lock_release "$LOCK"
            echo "error: refusing action append because the outcome store has a malformed final record" >&2
            exit 1
          fi
          SEQ=$(( LAST_SEQ + 1 ))
          if ! append_record_locked "$TASK" firstmate-action "$SUMMARY" "$WAKE" false "$SEQ"; then
            fm_lock_release "$LOCK"
            exit 1
          fi
        fi
        if ! update_action_marker "$MARKER" ".outcome_seq = $SEQ"; then
          fm_lock_release "$LOCK"
          exit 1
        fi
      fi
      fm_lock_release "$LOCK"
      printf '%s\n' "$SEQ"
    else
      write_action_marker "$MARKER" "$WAKE_SEQ" "" pending "$TASK" "$SUMMARY" "$WAKE" || {
        fm_lock_release "$LOCK"
        exit 1
      }
      if ! LAST_SEQ=$(last_seq); then
        fm_lock_release "$LOCK"
        echo "error: refusing action append because the outcome store has a malformed final record" >&2
        exit 1
      fi
      SEQ=$(( LAST_SEQ + 1 ))
      if ! append_record_locked "$TASK" firstmate-action "$SUMMARY" "$WAKE" false "$SEQ"; then
        fm_lock_release "$LOCK"
        exit 1
      fi
      if ! update_action_marker "$MARKER" ".outcome_seq = $SEQ"; then
        fm_lock_release "$LOCK"
        exit 1
      fi
      fm_lock_release "$LOCK"
      printf '%s\n' "$SEQ"
    fi
    ;;
  action-prepare)
    [ "${1:-}" = --seq ] || usage
    SEQ=${2:-}
    case "$SEQ" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    RECORD=$(record_for_seq "$SEQ" 2>/dev/null || true)
    if [ -z "$RECORD" ] || ! printf '%s\n' "$RECORD" | jq -e '.verdict == "firstmate-action"' >/dev/null 2>&1; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    MARKER=$(ensure_action_marker_for_record_locked "$RECORD") || {
      fm_lock_release "$LOCK"
      exit 1
    }
    ACTION_STATE=$(action_marker_state "$MARKER" 2>/dev/null || true)
    case "$ACTION_STATE" in pending|started) ;;
      *) fm_lock_release "$LOCK"; exit 1 ;;
    esac
    fm_lock_release "$LOCK"
    printf '%s\n' "$ACTION_STATE"
    ;;
  action-status)
    [ "${1:-}" = --seq ] || usage
    SEQ=${2:-}
    case "$SEQ" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    MARKER=$(action_marker_for_seq "$SEQ" 2>/dev/null || true)
    if [ -z "$MARKER" ]; then
      ACTION_STATE=none
    else
      ACTION_STATE=$(action_marker_state "$MARKER" 2>/dev/null || true)
      [ -n "$ACTION_STATE" ] || { fm_lock_release "$LOCK"; exit 1; }
    fi
    fm_lock_release "$LOCK"
    printf '%s\n' "$ACTION_STATE"
    ;;
  action-started)
    [ "${1:-}" = --seq ] || usage
    SEQ=${2:-}
    case "$SEQ" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    RECORD=$(record_for_seq "$SEQ" 2>/dev/null || true)
    if [ -z "$RECORD" ] || ! printf '%s\n' "$RECORD" | jq -e '.verdict == "firstmate-action"' >/dev/null 2>&1; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    MARKER=$(ensure_action_marker_for_record_locked "$RECORD") || {
      fm_lock_release "$LOCK"
      exit 1
    }
    ACTION_STATE=$(action_marker_state "$MARKER" 2>/dev/null || true)
    if [ "$ACTION_STATE" = pending ]; then
      update_action_marker "$MARKER" '.state = "started"' || {
        fm_lock_release "$LOCK"
        exit 1
      }
    elif [ "$ACTION_STATE" != started ]; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    fm_lock_release "$LOCK"
    printf 'started\n'
    ;;
  render)
    [ "${1:-}" = --seq ] || usage
    SEQ=${2:-}
    case "$SEQ" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    RECORD=$(record_for_seq "$SEQ" 2>/dev/null || true)
    if [ -z "$RECORD" ]; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if ! render_record "$RECORD"; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    fm_lock_release "$LOCK"
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    print_unread
    fm_lock_release "$LOCK"
    ;;
  mark-read)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    case "$THROUGH" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    advance_cursor "$THROUGH"
    fm_lock_release "$LOCK"
    ;;
  list)
    RECENT=20
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    [ -s "$STORE" ] || exit 0
    tail -n "$RECENT" "$STORE"
    ;;
  startup-replay)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    reconcile_action_markers_locked || {
      fm_lock_release "$LOCK"
      exit 1
    }
    UNREAD=$(print_unread)
    if [ -n "$UNREAD" ]; then
      VISIBLE_FOUND=false
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        verdict=$(printf '%s\n' "$line" | jq -er '.verdict') || {
          fm_lock_release "$LOCK"
          exit 1
        }
        case "$verdict" in
          routine|captain)
            if printf '%s\n' "$line" | jq -e '.silent != true' >/dev/null 2>&1; then
              if [ "$VISIBLE_FOUND" = false ]; then
                printf 'BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):\n'
                VISIBLE_FOUND=true
              fi
              printf '%s\n' "$line"
            fi
            ;;
          firstmate-action)
            seq=$(record_seq "$line")
            marker=$(ensure_action_marker_for_record_locked "$line") || {
              fm_lock_release "$LOCK"
              exit 1
            }
            action_state=$(action_marker_state "$marker" 2>/dev/null || true)
            case "$action_state" in
              started) ;;
              pending)
                if [ "$VISIBLE_FOUND" = false ]; then
                  printf 'BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):\n'
                  VISIBLE_FOUND=true
                fi
                render_record "$line" || {
                  fm_lock_release "$LOCK"
                  exit 1
                }
                update_action_marker "$marker" '.state = "started"' || {
                  fm_lock_release "$LOCK"
                  exit 1
                }
                ;;
              *) fm_lock_release "$LOCK"; exit 1 ;;
            esac
            ;;
          *) fm_lock_release "$LOCK"; exit 1 ;;
        esac
      done <<EOF
$UNREAD
EOF
      LAST=$(record_seq "$(printf '%s\n' "$UNREAD" | tail -n 1)")
      [ -z "$LAST" ] || advance_cursor "$LAST"
    fi
    fm_lock_release "$LOCK"
    ;;
  *) usage ;;
esac
