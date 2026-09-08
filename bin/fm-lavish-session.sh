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
#   fm-lavish-session.sh end-ephemeral <task-id>
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

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

validate_task_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) die "task id must be a privacy-safe slug: $1" ;; esac
}

canonical_file() {
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null \
    || die "cannot resolve the artifact path: $1"
}

ledger_path() { printf '%s/%s.lavish-sessions\n' "$STATE" "$1"; }

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
  local task=$1 real=$2 disposition=$3 session_json=$4 ledger tmp
  ledger=$(ledger_path "$task")
  mkdir -p "$STATE" || die "cannot create state directory: $STATE"
  tmp=$(umask 077; mktemp "$STATE/.${task}.lavish-sessions.XXXXXX") \
    || die "cannot stage the Lavish ledger"
  TASK_ID="$task" HOME_REAL="$(canonical_file "$FM_HOME")" ARTIFACT_REAL="$real" \
    DISPOSITION="$disposition" SESSION_JSON="$session_json" LEDGER="$ledger" node <<'NODE' > "$tmp" \
    || { rm -f "$tmp"; die "cannot update the Lavish ledger"; }
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
    try { rows.push(JSON.parse(line)); } catch { console.error("existing Lavish ledger is malformed"); process.exit(1); }
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
  disposition: process.env.DISPOSITION,
};
const next = rows.filter(item => item.key !== session.key);
next.push(row);
for (const item of next) process.stdout.write(`${JSON.stringify(item)}\n`);
NODE
  chmod 0600 "$tmp" || { rm -f "$tmp"; die "cannot protect the Lavish ledger"; }
  mv -f "$tmp" "$ledger" || { rm -f "$tmp"; die "cannot publish the Lavish ledger"; }
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
  local artifact=$1 explicit=${2-} real meta task worktree matches=0 owner='' disposition=''
  real=$(canonical_file "$artifact")
  if [ -n "$explicit" ]; then
    validate_task_id "$explicit"
    owner=$explicit
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}; task=${task%.meta}
    [ -z "$owner" ] || [ "$task" = "$owner" ] || continue
    worktree=$(sed -n 's/^worktree=//p' "$meta" | tail -1)
    if [ -n "$worktree" ] && { [ "$real" = "$worktree" ] || [[ "$real" == "$worktree"/* ]]; }; then
      owner=$task; disposition=ephemeral-worktree; matches=$((matches + 1))
    fi
  done
  if [ -n "$owner" ] && { [ "$real" = "$FM_HOME/data/$owner" ] || [[ "$real" == "$FM_HOME/data/$owner"/* ]]; }; then
    disposition='durable-review'
    matches=$((matches + 1))
  fi
  [ -n "$owner" ] || die "cannot establish a task owner for Lavish artifact: $real"
  [ -n "$disposition" ] || die "artifact is outside task $owner's worktree and durable data directory: $real"
  [ "$matches" -eq 1 ] || die "Lavish artifact ownership is ambiguous for task $owner: $real"
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
  local task=$1 key=$2 ledger tmp
  ledger=$(ledger_path "$task")
  tmp=$(umask 077; mktemp "$STATE/.${task}.lavish-sessions.XXXXXX") \
    || die "cannot stage the Lavish ledger"
  KEY="$key" LEDGER="$ledger" node <<'NODE' > "$tmp" \
    || { rm -f "$tmp"; die "cannot record the ended Lavish session"; }
const fs = require("node:fs");
const rows = fs.readFileSync(process.env.LEDGER, "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
let found = false;
for (const row of rows) {
  if (row.key === process.env.KEY) { row.ended_at = new Date().toISOString(); found = true; }
  process.stdout.write(`${JSON.stringify(row)}\n`);
}
if (!found) process.exit(1);
NODE
  if ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$ledger"; then
    rm -f "$tmp"
    die "cannot publish the ended Lavish ledger"
  fi
}

end_recorded_file() {
  local task=$1 real=$2 key=$3 status
  [ -f "$real" ] && [ ! -L "$real" ] || die "cannot end missing Lavish artifact through supported CLI semantics: $real"
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  lavish-axi end "$real" >/dev/null || die "lavish-axi could not end $real"
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

ledger_rows() {
  local task=$1 disposition=${2-} ledger
  ledger=$(ledger_path "$task")
  [ -f "$ledger" ] && [ ! -L "$ledger" ] || return 0
  DISPOSITION="$disposition" LEDGER="$ledger" node <<'NODE'
const fs = require("node:fs");
for (const line of fs.readFileSync(process.env.LEDGER, "utf8").split("\n")) {
  if (!line) continue;
  const row = JSON.parse(line);
  if (row.ended_at) continue;
  if (process.env.DISPOSITION && row.disposition !== process.env.DISPOSITION) continue;
  process.stdout.write(`${row.artifact}\t${row.key}\t${row.disposition}\n`);
}
NODE
}

guard_durable_end() {
  local task=$1 real=$2 key=$3 source_id result hold_status=0 session_json
  source_id=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$real") || return 1
  [ ! -e "$STATE/procevent/$source_id.source" ] \
    || die "durable Lavish review still has a registered process-event source: $source_id"
  [ ! -e "$STATE/decision-bindings/$source_id.origin" ] \
    || die "durable Lavish review still has an open decision binding: $source_id"
  for result in "$STATE/procevent-inbox/$source_id".*.result; do
    [ -e "$result" ] || continue
    [ -e "${result%.result}.handled" ] \
      || die "durable Lavish review still has an unacknowledged delivery: $source_id"
  done
  session_json=$(session_json_for_file "$real") || return 1
  SESSION_JSON="$session_json" KEY="$key" node <<'NODE' \
    || die "durable Lavish review still has feedback, prompts, or unresolved layout warnings: $key"
const row = JSON.parse(process.env.SESSION_JSON);
if (row.key !== process.env.KEY || row.status !== "open") process.exit(1);
if (Number(row.pending_prompts || 0) > 0 || (row.prompts || []).length > 0 || (row.layout_warnings || []).length > 0) process.exit(1);
NODE
  if [ -f "$FM_HOME/data/backlog.md" ] && command -v tasks-axi >/dev/null 2>&1; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" >/dev/null 2>&1 || hold_status=$?
    case "$hold_status" in
      0) die "durable Lavish review belongs to a task still held for the captain: $task" ;;
      1) ;;
      *) die "cannot determine whether task $task is still held for the captain" ;;
    esac
  fi
}

cmd_end() {
  local task=${1-} artifact=${2-} real row key disposition
  [ "$#" -eq 2 ] || usage
  validate_task_id "$task"
  real=$(canonical_file "$artifact")
  row=$(ledger_rows "$task" | awk -F '\t' -v file="$real" '$1 == file { print; exit }')
  [ -n "$row" ] || die "artifact is not an active recorded session for task $task: $real"
  key=${row#*$'\t'}; key=${key%%$'\t'*}
  disposition=${row##*$'\t'}
  if [ "$disposition" = durable-review ]; then
    guard_durable_end "$task" "$real" "$key"
  fi
  end_recorded_file "$task" "$real" "$key"
}

cmd_end_ephemeral() {
  local task=${1-} rows real key disposition
  [ "$#" -eq 1 ] || usage
  validate_task_id "$task"
  rows=$(ledger_rows "$task" ephemeral-worktree) || die "cannot read the Lavish ledger for $task"
  while IFS=$'\t' read -r real key disposition; do
    [ -n "$real" ] || continue
    end_recorded_file "$task" "$real" "$key" || exit 1
  done <<EOF
$rows
EOF
}

cmd_remove_ledger() {
  local task=${1-} ledger remaining
  [ "$#" -eq 1 ] || usage
  validate_task_id "$task"
  ledger=$(ledger_path "$task")
  [ -e "$ledger" ] || return 0
  remaining=$(ledger_rows "$task") || die "cannot read the Lavish ledger for $task"
  [ -z "$remaining" ] || die "cannot remove a ledger with active Lavish sessions for task $task"
  rm -f "$ledger"
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
  lavish-axi "$durable_real" >/dev/null || die "cannot serve the durable Lavish artifact"
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
  end) shift; cmd_end "$@" ;;
  end-ephemeral) shift; cmd_end_ephemeral "$@" ;;
  remove-ledger) shift; cmd_remove_ledger "$@" ;;
  -h|--help|help|'') usage ;;
  *) usage ;;
esac
