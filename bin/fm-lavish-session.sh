#!/usr/bin/env bash
# Own Firstmate's private task-to-Lavish session ledger and supported end path.
#
# Ledger: state/<task-id>.lavish-sessions, newline-delimited JSON, mode 0600.
# One current row per Lavish key binds task_id, home, canonical artifact path,
# key, URL, creation time, disposition (ephemeral-worktree or durable-review),
# and the verified ended_at time when Firstmate ended it.
#
# Usage:
#   fm-lavish-session.sh register <task-id> <artifact.html> <ephemeral-worktree|durable-review>
#   fm-lavish-session.sh register-auto <artifact.html> [<task-id>]
#   fm-lavish-session.sh safe-park <task-id> <worktree-artifact.html> <durable-artifact.html>
#   fm-lavish-session.sh end <task-id> <artifact.html>
#   fm-lavish-session.sh end-with-source <task-id> <artifact.html> <source-id>
#   fm-lavish-session.sh preflight-end <task-id> <artifact.html>
#   fm-lavish-session.sh end-ephemeral <task-id>
#   fm-lavish-session.sh poll-activity <artifact.html> [<task-id>]
#   fm-lavish-session.sh finalize-key <key>
#   fm-lavish-session.sh remove-ledger <task-id>
#
# register reads the installed Lavish state after the session has been served;
# it never invents a key or URL from a path.
# end and end-ephemeral use `lavish-axi end <existing-file>` and then verify the
# same key changed to `ended` in Lavish's state before recording ended_at.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LAVISH_STATE_FILE="${FM_LAVISH_STATE_FILE:-${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lavish-lib.sh
. "$SCRIPT_DIR/fm-lavish-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
LAVISH_STATE_DIR=$(fm_lavish_state_dir "$LAVISH_STATE_FILE") \
  || die "FM_LAVISH_STATE_FILE must be an absolute Lavish state.json path"
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

validate_task_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) die "task id must be a privacy-safe slug: $1" ;; esac
}

canonical_file() {
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null \
    || die "cannot resolve the artifact path: $1"
}

ledger_path() { printf '%s/%s.lavish-sessions\n' "$STATE" "$1"; }
ledger_lock_path() { printf '%s/.%s.lavish-sessions.lock\n' "$STATE" "$1"; }
lavish_cli() { LAVISH_AXI_STATE_DIR="$LAVISH_STATE_DIR" command lavish-axi "$@"; }

ledger_is_safe() {
  local ledger=$1
  if [ -e "$ledger" ] || [ -L "$ledger" ]; then
    [ -f "$ledger" ] && [ ! -L "$ledger" ] || return 1
  fi
  return 0
}

session_json_for_file() {
  ARTIFACT_REAL="$1" LAVISH_STATE_FILE="$LAVISH_STATE_FILE" node <<'NODE'
const fs = require("node:fs");
let state;
try { state = JSON.parse(fs.readFileSync(process.env.LAVISH_STATE_FILE, "utf8")); }
catch (error) { console.error(`error: cannot read Lavish state: ${error.message}`); process.exit(1); }
const matches = Object.values(state.sessions || {}).filter(row => row && row.file === process.env.ARTIFACT_REAL);
if (matches.length !== 1) {
  console.error(`error: expected one Lavish session for ${process.env.ARTIFACT_REAL}, found ${matches.length}`);
  process.exit(1);
}
process.stdout.write(JSON.stringify(matches[0]));
NODE
}

write_registration() {
  local task=$1 real=$2 disposition=$3 session_json=$4 ledger tmp lock home_real
  ledger=$(ledger_path "$task")
  lock=$(ledger_lock_path "$task")
  home_real=$(canonical_file "$FM_HOME")
  mkdir -p "$STATE" || die "cannot create state directory: $STATE"
  ledger_is_safe "$ledger" || die "Lavish ledger is not a safe regular file: $ledger"
  fm_lock_acquire_wait "$lock" || die "cannot lock the Lavish ledger for $task"
  tmp=$(umask 077; mktemp "$STATE/.${task}.lavish-sessions.XXXXXX") \
    || { fm_lock_release "$lock"; die "cannot stage the Lavish ledger"; }
  TASK_ID="$task" HOME_REAL="$home_real" ARTIFACT_REAL="$real" \
    DISPOSITION="$disposition" SESSION_JSON="$session_json" LEDGER="$ledger" node <<'NODE' > "$tmp" \
    || { rm -f "$tmp"; fm_lock_release "$lock"; die "cannot update the Lavish ledger"; }
const fs = require("node:fs");
const session = JSON.parse(process.env.SESSION_JSON);
if (!session.key || !session.url || !["open", "feedback"].includes(session.status)) {
  console.error("served Lavish session is missing an open key or URL");
  process.exit(1);
}
const rows = [];
if (fs.existsSync(process.env.LEDGER)) {
  for (const line of fs.readFileSync(process.env.LEDGER, "utf8").split("\n")) {
    if (!line) continue;
    let row;
    try { row = JSON.parse(line); } catch { console.error("existing Lavish ledger is malformed"); process.exit(1); }
    if (!row || typeof row !== "object" || Array.isArray(row) || typeof row.key !== "string" || typeof row.artifact !== "string" || typeof row.task_id !== "string" || typeof row.home !== "string" || !["ephemeral-worktree", "durable-review"].includes(row.disposition)) {
      console.error("existing Lavish ledger has an invalid row");
      process.exit(1);
    }
    rows.push(row);
  }
}
const prior = rows.find(row => row.key === session.key);
const row = {
  task_id: process.env.TASK_ID,
  home: process.env.HOME_REAL,
  artifact: process.env.ARTIFACT_REAL,
  key: session.key,
  url: session.url,
  created_at: prior?.created_at || new Date().toISOString(),
  last_polled_at: new Date().toISOString(),
  disposition: process.env.DISPOSITION,
};
const next = rows.filter(item => item.key !== session.key);
next.push(row);
for (const item of next) process.stdout.write(`${JSON.stringify(item)}\n`);
NODE
  chmod 0600 "$tmp" || { rm -f "$tmp"; fm_lock_release "$lock"; die "cannot protect the Lavish ledger"; }
  mv -f "$tmp" "$ledger" || { rm -f "$tmp"; fm_lock_release "$lock"; die "cannot publish the Lavish ledger"; }
  fm_lock_release "$lock" || die "cannot release the Lavish ledger lock"
}

cmd_register() {
  local task=${1-} artifact=${2-} disposition=${3-} real session_json
  [ "$#" -eq 3 ] || usage
  validate_task_id "$task"
  case "$disposition" in ephemeral-worktree|durable-review) ;; *) die "invalid disposition: $disposition" ;; esac
  [ -f "$artifact" ] && [ ! -L "$artifact" ] || die "artifact is not a regular file: $artifact"
  real=$(canonical_file "$artifact")
  session_json=$(session_json_for_file "$real") || exit 1
  write_registration "$task" "$real" "$disposition" "$session_json"
  printf 'registered: %s %s\n' "$task" "$real"
}

resolve_owner() {
  local artifact=$1 explicit=${2-} real home_real meta task worktree relative owner='' disposition='' found_explicit=0 matches owners_text
  local -a owners=() dispositions=()
  real=$(canonical_file "$artifact")
  home_real=$(canonical_file "$FM_HOME")
  if [ -n "$explicit" ]; then
    validate_task_id "$explicit"
  fi
  if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "task state is not a safe directory: $STATE"
    [ -r "$STATE" ] || die "task state is unreadable: $STATE"
  fi
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || die "task metadata is not a safe regular file: $meta"
    task=${meta##*/}; task=${task%.meta}
    validate_task_id "$task"
    worktree=$(awk '/^worktree=/{value=substr($0,10)} END{if (value != "") print value}' "$meta") || die "cannot read task metadata: $meta"
    case "$worktree" in
      ''|/*) ;;
      *) die "task metadata has an unsafe worktree path: $meta" ;;
    esac
    if [ -d "$worktree" ]; then
      worktree=$(canonical_file "$worktree")
    fi
    if [ -n "$worktree" ] && { [ "$real" = "$worktree" ] || [[ "$real" == "$worktree"/* ]]; }; then
      owners+=("$task"); dispositions+=(ephemeral-worktree)
    fi
  done

  case "$real" in
    "$home_real/data"/*)
      relative=${real#"$home_real/data/"}
      owner=${relative%%/*}
      validate_task_id "$owner"
      owners+=("$owner"); dispositions+=(durable-review)
      ;;
    "$home_real/.lavish/bearings-board.html")
      owners+=(home); dispositions+=(durable-review)
      ;;
  esac

  matches=${#owners[@]}
  if [ -n "$explicit" ]; then
    for task in "${owners[@]}"; do
      [ "$task" = "$explicit" ] || continue
      found_explicit=1
      break
    done
  fi
  [ "$matches" -gt 0 ] || die "cannot establish a task owner for Lavish artifact: $real"
  [ -z "$explicit" ] || [ "$found_explicit" -eq 1 ] || die "artifact is not owned by task $explicit: $real"
  if [ "$matches" -ne 1 ]; then
    owners_text=$(IFS=,; printf '%s' "${owners[*]}")
    die "Lavish artifact ownership is ambiguous for $real: $owners_text"
  fi
  owner=${owners[0]}
  disposition=${dispositions[0]}
  [ -z "$explicit" ] || [ "$owner" = "$explicit" ] || die "artifact ownership resolved to $owner, not $explicit: $real"
  printf '%s\t%s\n' "$owner" "$disposition"
}

cmd_register_auto() {
  local artifact=${1-} explicit=${2-} owner disposition resolved
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
  resolved=$(resolve_owner "$artifact" "$explicit") || exit 1
  owner=${resolved%%$'\t'*}
  disposition=${resolved#*$'\t'}
  cmd_register "$owner" "$artifact" "$disposition"
}

mark_ended() {
  local task=$1 key=$2 ledger tmp lock
  ledger=$(ledger_path "$task")
  lock=$(ledger_lock_path "$task")
  [ -f "$ledger" ] && [ ! -L "$ledger" ] || die "cannot find the Lavish ledger for $task"
  fm_lock_acquire_wait "$lock" || die "cannot lock the Lavish ledger for $task"
  tmp=$(umask 077; mktemp "$STATE/.${task}.lavish-sessions.XXXXXX") \
    || { fm_lock_release "$lock"; die "cannot stage the Lavish ledger"; }
  KEY="$key" LEDGER="$ledger" node <<'NODE' > "$tmp" \
    || { rm -f "$tmp"; fm_lock_release "$lock"; die "cannot record the ended Lavish session"; }
const fs = require("node:fs");
const rows = fs.readFileSync(process.env.LEDGER, "utf8").split("\n").filter(Boolean).map(line => JSON.parse(line));
let found = false;
for (const row of rows) {
  if (row.key === process.env.KEY) { row.ended_at = new Date().toISOString(); found = true; }
  process.stdout.write(`${JSON.stringify(row)}\n`);
}
if (!found) process.exit(1);
NODE
  if ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$ledger"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    die "cannot publish the ended Lavish ledger"
  fi
  fm_lock_release "$lock" || die "cannot release the Lavish ledger lock"
}

end_recorded_file() {
  local task=$1 real=$2 key=$3 status
  [ -f "$real" ] && [ ! -L "$real" ] || die "cannot end missing Lavish artifact through supported CLI semantics: $real"
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  lavish_cli end "$real" >/dev/null || die "lavish-axi could not end $real"
  status=$(KEY="$key" LAVISH_STATE_FILE="$LAVISH_STATE_FILE" node <<'NODE'
const fs = require("node:fs");
const state = JSON.parse(fs.readFileSync(process.env.LAVISH_STATE_FILE, "utf8"));
const row = (state.sessions || {})[process.env.KEY];
process.stdout.write(row?.status || "missing");
NODE
  ) || die "cannot verify Lavish state after ending $real"
  [ "$status" = ended ] || die "Lavish key $key did not transition to ended (status=$status)"
  mark_ended "$task" "$key"
  printf 'ended: %s %s\n' "$key" "$real"
}

ledger_rows_unlocked() {
  local task=$1 disposition=${2-} ledger
  ledger=$(ledger_path "$task")
  ledger_is_safe "$ledger" || return 1
  [ -f "$ledger" ] || return 0
  TASK_ID="$task" DISPOSITION="$disposition" LEDGER="$ledger" node <<'NODE'
const fs = require("node:fs");
for (const line of fs.readFileSync(process.env.LEDGER, "utf8").split("\n")) {
  if (!line) continue;
  const row = JSON.parse(line);
  if (!row || typeof row !== "object" || Array.isArray(row) || typeof row.task_id !== "string" || row.task_id !== process.env.TASK_ID || typeof row.home !== "string" || typeof row.artifact !== "string" || typeof row.key !== "string" || !["ephemeral-worktree", "durable-review"].includes(row.disposition) || (row.ended_at !== undefined && typeof row.ended_at !== "string")) {
    console.error("Lavish ledger has an invalid row");
    process.exit(1);
  }
  if (row.ended_at) continue;
  if (process.env.DISPOSITION && row.disposition !== process.env.DISPOSITION) continue;
  process.stdout.write(`${row.artifact}\t${row.key}\t${row.disposition}\n`);
  }
NODE
}

ledger_rows() {
  local task=$1 disposition=${2-} lock ledger rows rc
  lock=$(ledger_lock_path "$task")
  ledger=$(ledger_path "$task")
  ledger_is_safe "$ledger" || return 1
  [ -f "$ledger" ] || return 0
  fm_lock_acquire_wait "$lock" || return $?
  rows=$(ledger_rows_unlocked "$task" "$disposition") || {
    rc=$?
    fm_lock_release "$lock"
    return "$rc"
  }
  fm_lock_release "$lock" || return $?
  printf '%s\n' "$rows"
}

touch_ledger_poll() {
  local task=$1 real=$2 ledger lock tmp rc
  ledger=$(ledger_path "$task")
  ledger_is_safe "$ledger" || return 1
  [ -f "$ledger" ] || return 0
  lock=$(ledger_lock_path "$task")
  fm_lock_acquire_wait "$lock" || return $?
  tmp=$(umask 077; mktemp "$STATE/.${task}.lavish-sessions.XXXXXX") || {
    fm_lock_release "$lock"
    return 1
  }
  ARTIFACT_REAL="$real" LEDGER="$ledger" node <<'NODE' > "$tmp"
const fs = require("node:fs");
const rows = fs.readFileSync(process.env.LEDGER, "utf8").split("\n").filter(Boolean).map(line => JSON.parse(line));
for (const row of rows) if (!row.ended_at && row.artifact === process.env.ARTIFACT_REAL) row.last_polled_at = new Date().toISOString();
for (const row of rows) process.stdout.write(`${JSON.stringify(row)}\n`);
NODE
  rc=$?
  if [ "$rc" -ne 0 ] || ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$ledger"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock" || return 1
}

cmd_poll_activity() {
  local artifact=${1-} task=${2-} real ledger name
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
  [ -f "$artifact" ] && [ ! -L "$artifact" ] || return 0
  real=$(canonical_file "$artifact") || return 0
  if [ -n "$task" ]; then
    validate_task_id "$task"
    touch_ledger_poll "$task" "$real" || die "cannot refresh the Lavish poll activity ledger"
    return 0
  fi
  for ledger in "$STATE"/*.lavish-sessions; do
    [ -e "$ledger" ] || [ -L "$ledger" ] || continue
    ledger_is_safe "$ledger" || die "Lavish ledger is not a safe regular file: $ledger"
    name=${ledger##*/}; name=${name%.lavish-sessions}
    validate_task_id "$name"
    touch_ledger_poll "$name" "$real" || die "cannot refresh the Lavish poll activity ledger"
  done
}

guard_durable_end() {
  local task=$1 real=$2 key=$3 allow_source=${4-} source_id result hold_status=0 session_json source_path origin_path handled_path data_override
  source_id=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$real") || return 1
  source_path="$STATE/procevent/$source_id.source"
  if [ -e "$source_path" ] || [ -L "$source_path" ]; then
    [ -f "$source_path" ] && [ ! -L "$source_path" ] \
      || die "durable Lavish review has an unsafe process-event source: $source_id"
    [ "$source_id" = "$allow_source" ] \
      || die "durable Lavish review still has a registered process-event source: $source_id"
  fi
  origin_path="$STATE/decision-bindings/$source_id.origin"
  if [ -e "$origin_path" ] || [ -L "$origin_path" ]; then
    [ -f "$origin_path" ] && [ ! -L "$origin_path" ] \
      || die "durable Lavish review has an unsafe decision binding: $source_id"
    die "durable Lavish review still has an open decision binding: $source_id"
  fi
  for result in "$STATE/procevent-inbox/$source_id".*.result; do
    [ -e "$result" ] || [ -L "$result" ] || continue
    [ -f "$result" ] && [ ! -L "$result" ] \
      || die "durable Lavish review has an unsafe delivery result: $source_id"
    handled_path="${result%.result}.handled"
    if [ -e "$handled_path" ] || [ -L "$handled_path" ]; then
      [ -f "$handled_path" ] && [ ! -L "$handled_path" ] \
        || die "durable Lavish review has an unsafe delivery marker: $source_id"
    else
      die "durable Lavish review still has an unacknowledged delivery: $source_id"
    fi
  done
  session_json=$(session_json_for_file "$real") || return 1
  SESSION_JSON="$session_json" KEY="$key" node <<'NODE' \
    || die "durable Lavish review still has feedback, prompts, or unresolved layout warnings: $key"
const row = JSON.parse(process.env.SESSION_JSON);
if (row.key !== process.env.KEY || row.status !== "open") process.exit(1);
if (row.pending_prompts !== undefined && (!Number.isInteger(row.pending_prompts) || row.pending_prompts < 0)) process.exit(1);
if (row.prompts !== undefined && (!Array.isArray(row.prompts) || row.prompts.length > 0)) process.exit(1);
if (row.pending_deliveries !== undefined && (!Array.isArray(row.pending_deliveries) || row.pending_deliveries.length > 0)) process.exit(1);
if (row.layout_warnings !== undefined && (!Array.isArray(row.layout_warnings) || row.layout_warnings.length > 0)) process.exit(1);
if (row.layout_warnings_pending !== undefined && typeof row.layout_warnings_pending !== "boolean") process.exit(1);
if (row.layout_warning_repair_open !== undefined && typeof row.layout_warning_repair_open !== "boolean") process.exit(1);
if (row.layout_warnings_pending === true || row.layout_warning_repair_open === true) process.exit(1);
NODE
  data_override="${FM_DATA_OVERRIDE-$FM_HOME/data}"
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$data_override" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" >/dev/null 2>&1 || hold_status=$?
  case "$hold_status" in
    0) die "durable Lavish review belongs to a task still held for the captain: $task" ;;
    1) ;;
    *) die "cannot determine whether task $task is still held for the captain" ;;
  esac
  local -a audit_args=(guard "$task" "$real" "$key")
  if [ -n "$allow_source" ]; then audit_args+=(--allow-source "$allow_source"); fi
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$data_override" \
    "$SCRIPT_DIR/fm-lavish-audit.sh" "${audit_args[@]}" >/dev/null \
    || die "durable Lavish end guard refused: $key"
}

find_active_row() {
  local task=$1 real=$2 row ledger_text
  ledger_text=$(ledger_rows "$task") || die "cannot read the Lavish ledger for $task"
  row=$(printf '%s\n' "$ledger_text" | awk -F '\t' -v file="$real" '$1 == file { print; exit }')
  [ -n "$row" ] || die "artifact is not an active recorded session for task $task: $real"
  printf '%s\n' "$row"
}

cmd_preflight_end() {
  local task=${1-} artifact=${2-} real row key disposition source_id
  [ "$#" -eq 2 ] || usage
  validate_task_id "$task"
  real=$(canonical_file "$artifact")
  row=$(find_active_row "$task" "$real")
  key=${row#*$'\t'}; key=${key%%$'\t'*}
  disposition=${row##*$'\t'}
  if [ "$disposition" = durable-review ]; then
    source_id=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$real") || exit 1
    guard_durable_end "$task" "$real" "$key" "$source_id" || exit 1
  fi
}

cmd_end() {
  local task=${1-} artifact=${2-} real row key disposition
  [ "$#" -eq 2 ] || usage
  validate_task_id "$task"
  real=$(canonical_file "$artifact")
  row=$(find_active_row "$task" "$real")
  key=${row#*$'\t'}; key=${key%%$'\t'*}
  disposition=${row##*$'\t'}
  if [ "$disposition" = durable-review ]; then
    guard_durable_end "$task" "$real" "$key" || exit 1
  fi
  end_recorded_file "$task" "$real" "$key"
}

cmd_end_with_source() {
  [ "$#" -eq 3 ] || usage
  local task=$1 artifact=$2 allow_source=$3 real row key disposition source_id
  validate_task_id "$task"
  [ -n "$allow_source" ] || die "a process-event source id is required"
  real=$(canonical_file "$artifact")
  row=$(find_active_row "$task" "$real")
  key=${row#*$'\t'}; key=${key%%$'\t'*}
  disposition=${row##*$'\t'}
  source_id=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$real") || exit 1
  [ "$source_id" = "$allow_source" ] || die "process-event source does not match the Lavish artifact"
  if [ "$disposition" = durable-review ]; then
    guard_durable_end "$task" "$real" "$key" "$allow_source" || exit 1
  fi
  end_recorded_file "$task" "$real" "$key"
}

cmd_end_ephemeral() {
  local task=${1-} rows real key disposition
  [ "$#" -eq 1 ] || usage
  validate_task_id "$task"
  while :; do
    rows=$(ledger_rows "$task" ephemeral-worktree) || die "cannot read the Lavish ledger for $task"
    [ -n "$rows" ] || break
    while IFS=$'\t' read -r real key disposition; do
      [ -n "$real" ] || continue
      end_recorded_file "$task" "$real" "$key" || exit 1
    done <<EOF
$rows
EOF
  done
}

cmd_remove_ledger() {
  local task=${1-} ledger remaining lock
  [ "$#" -eq 1 ] || usage
  validate_task_id "$task"
  ledger=$(ledger_path "$task")
  [ -e "$ledger" ] || [ -L "$ledger" ] || return 0
  ledger_is_safe "$ledger" || die "Lavish ledger is not a safe regular file: $ledger"
  lock=$(ledger_lock_path "$task")
  fm_lock_acquire_wait "$lock" || die "cannot lock the Lavish ledger for $task"
  remaining=$(ledger_rows_unlocked "$task") || {
    fm_lock_release "$lock"
    die "cannot read the Lavish ledger for $task"
  }
  if [ -n "$remaining" ]; then
    fm_lock_release "$lock"
    die "cannot remove a ledger with active Lavish sessions for task $task"
  fi
  rm -f "$ledger" || {
    fm_lock_release "$lock"
    die "cannot remove the Lavish ledger for task $task"
  }
  fm_lock_release "$lock" || die "cannot release the Lavish ledger lock"
}

finalize_key_in_ledger() {
  local task=$1 key=$2 ledger lock tmp rc
  ledger=$(ledger_path "$task")
  ledger_is_safe "$ledger" || return 1
  [ -f "$ledger" ] || return 0
  lock=$(ledger_lock_path "$task")
  fm_lock_acquire_wait "$lock" || return $?
  tmp=$(umask 077; mktemp "$STATE/.${task}.lavish-sessions.XXXXXX") || {
    fm_lock_release "$lock"
    return 1
  }
  KEY="$key" LEDGER="$ledger" node <<'NODE' > "$tmp"
const fs = require("node:fs");
const rows = fs.readFileSync(process.env.LEDGER, "utf8").split("\n").filter(Boolean).map(line => JSON.parse(line));
for (const row of rows) if (row.key === process.env.KEY && !row.ended_at) row.ended_at = new Date().toISOString();
for (const row of rows) process.stdout.write(`${JSON.stringify(row)}\n`);
NODE
  rc=$?
  if [ "$rc" -ne 0 ] || ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$ledger"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock" || return 1
}

cmd_finalize_key() {
  local key=${1-} ledger task
  [ "$#" -eq 1 ] || usage
  [ -n "$key" ] && [[ "$key" != *$'\n'* ]] || die "Lavish key is invalid"
  for ledger in "$STATE"/*.lavish-sessions; do
    [ -e "$ledger" ] || [ -L "$ledger" ] || continue
    ledger_is_safe "$ledger" || die "Lavish ledger is not a safe regular file: $ledger"
    task=${ledger##*/}; task=${task%.lavish-sessions}
    validate_task_id "$task"
    finalize_key_in_ledger "$task" "$key" || die "cannot finalize Lavish ledger rows for $key"
  done
}

cmd_safe_park() {
  local task=${1-} source=${2-} durable=${3-} source_real durable_real old_id new_id origin='' url
  [ "$#" -eq 3 ] || usage
  validate_task_id "$task"
  source_real=$(canonical_file "$source")
  [ -f "$source_real" ] && [ ! -L "$source_real" ] || die "source artifact is not a regular file: $source"
  case "$durable" in "$FM_HOME/data/$task"/*) ;; *) die "durable artifact must be under $FM_HOME/data/$task" ;; esac
  mkdir -p "$(dirname "$durable")" || die "cannot create the durable artifact directory"
  if [ -e "$durable" ]; then
    [ -f "$durable" ] && [ ! -L "$durable" ] || die "durable artifact target is unsafe: $durable"
    cmp -s "$source_real" "$durable" || die "durable artifact already exists with different contents: $durable"
  else
    cp -p "$source_real" "$durable" || die "cannot copy the artifact to durable storage"
  fi
  durable_real=$(canonical_file "$durable")
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  lavish_cli "$durable_real" >/dev/null || die "cannot serve the durable Lavish artifact"
  cmd_register "$task" "$durable_real" durable-review >/dev/null || exit 1
  url=$(session_json_for_file "$durable_real" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).url||""))')
  [ -n "$url" ] || die "durable Lavish session has no live URL"
  curl -fsS --max-time 5 "$url" >/dev/null || die "durable Lavish URL is not live: $url"
  old_id=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$source_real") || exit 1
  new_id=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$durable_real") || exit 1
  if [ -f "$STATE/procevent/$old_id.source" ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$durable_real" --task-id "$task" >/dev/null || exit 1
  fi
  if [ -f "$STATE/decision-bindings/$old_id.origin" ]; then
    origin=$("$SCRIPT_DIR/fm-captain-hold.sh" binding "$old_id") || die "cannot read the old decision binding"
    if [ "$origin" = '(any)' ]; then
      "$SCRIPT_DIR/fm-captain-hold.sh" bind "$new_id" --any-origin >/dev/null || exit 1
    else
      "$SCRIPT_DIR/fm-captain-hold.sh" bind "$new_id" "$origin" >/dev/null || exit 1
    fi
  fi
  if [ -f "$STATE/procevent/$old_id.source" ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" retire "$source_real" >/dev/null || exit 1
  fi
  if [ -n "$origin" ]; then
    "$SCRIPT_DIR/fm-captain-hold.sh" unbind "$old_id" >/dev/null || exit 1
  fi
  cmd_end "$task" "$source_real" >/dev/null || exit 1
  printf 'safe-parked: %s\nurl: %s\n' "$durable_real" "$url"
}

case "${1:-}" in
  register) shift; cmd_register "$@" ;;
  register-auto) shift; cmd_register_auto "$@" ;;
  safe-park) shift; cmd_safe_park "$@" ;;
  preflight-end) shift; cmd_preflight_end "$@" ;;
  end) shift; cmd_end "$@" ;;
  end-with-source) shift; cmd_end_with_source "$@" ;;
  end-ephemeral) shift; cmd_end_ephemeral "$@" ;;
  poll-activity) shift; cmd_poll_activity "$@" ;;
  finalize-key) shift; cmd_finalize_key "$@" ;;
  remove-ledger) shift; cmd_remove_ledger "$@" ;;
  -h|--help|help|'') usage ;;
  *) usage ;;
esac
