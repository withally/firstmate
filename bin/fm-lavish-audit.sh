#!/usr/bin/env bash
# Audit the Lavish registry against Firstmate lifecycle ownership without mutation.
#
# Usage:
#   fm-lavish-audit.sh [audit] [--freeze <candidate.jsonl>]
#   fm-lavish-audit.sh summary
#   fm-lavish-audit.sh apply <candidate.jsonl> [--batch-size <1..50>]
#
# audit is the default and classifies every registry row as preserve, eligible,
# or ambiguous with evidence.
# --freeze atomically writes only eligible existing-path rows to a mode-0600
# JSONL candidate file, including the audited status and updated_at values.
# apply accepts only that frozen shape, reclassifies every row against current
# state, ends bounded batches through `lavish-axi end <existing-file>`, verifies
# each transition, and recounts after each batch.
# It never deletes Lavish records, Firstmate state, chat, attachments, or files,
# and it never edits Lavish state.json.
#
# Ownership is read across this FM_HOME and every local home registered in its
# data/secondmates.md.
# Remote or unreadable homes remain uncertainty rather than permission to end.
# Browser/session keys that cannot be observed from the registry are accepted
# from FM_LAVISH_ATTACHED_KEYS_FILE, one `<key><TAB><client-kind>` row per client;
# registered and live agent poll ownership is discovered directly.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
LAVISH_STATE_FILE="${FM_LAVISH_STATE_FILE:-${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

make_homes_file() {
  local out=$1 registry="$FM_HOME/data/secondmates.md" home
  : > "$out"
  printf '%s\n' "$FM_HOME" >> "$out"
  if [ -f "$registry" ] && [ ! -L "$registry" ]; then
    sed -n 's/.*(home: \([^;)]*\).*/\1/p' "$registry" | while IFS= read -r home; do
      [ -n "$home" ] && printf '%s\n' "$home"
    done >> "$out"
  fi
  awk '!seen[$0]++' "$out" > "$out.unique" && mv "$out.unique" "$out"
}

run_audit_node() {
  local mode=$1 homes_file=$2 freeze=${3-}
  AUDIT_MODE="$mode" HOMES_FILE="$homes_file" FREEZE_FILE="$freeze" \
    LAVISH_STATE_FILE="$LAVISH_STATE_FILE" ATTACHED_FILE="${FM_LAVISH_ATTACHED_KEYS_FILE:-}" \
    LSOF_FILE="${FM_LAVISH_LSOF_FILE:-}" LAVISH_PORT="${LAVISH_AXI_PORT:-4387}" node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const cp = require("node:child_process");

const fail = message => { console.error(`error: ${message}`); process.exit(1); };
let state;
try { state = JSON.parse(fs.readFileSync(process.env.LAVISH_STATE_FILE, "utf8")); }
catch (error) { fail(`cannot read Lavish state: ${error.message}`); }
if (!state.sessions || typeof state.sessions !== "object" || Array.isArray(state.sessions)) fail("Lavish state has no session registry object");
const homes = fs.readFileSync(process.env.HOMES_FILE, "utf8").split("\n").filter(Boolean);
const meta = [];
const closed = new Set();
const ledgers = new Map();
const sources = new Set();
const decisions = new Set();
const unacked = new Set();
let unreadableHome = false;
let activePollRegistrations = 0;
const sourceId = file => `lavish-${crypto.createHash("sha256").update(file).digest("hex").slice(0,16)}`;
const readLines = file => fs.readFileSync(file, "utf8").split("\n");
const safeFiles = dir => { try { return fs.readdirSync(dir); } catch { return []; } };

for (const home of homes) {
  if (!fs.existsSync(home)) { unreadableHome = true; continue; }
  const stateDir = path.join(home, "state");
  const dataDir = path.join(home, "data");
  for (const name of safeFiles(stateDir).filter(name => name.endsWith(".meta"))) {
    const task = name.slice(0, -5);
    try {
      const fields = Object.fromEntries(readLines(path.join(stateDir, name)).filter(line => line.includes("=")).map(line => [line.slice(0,line.indexOf("=")), line.slice(line.indexOf("=")+1)]));
      if (fields.kind !== "secondmate") meta.push({task,home,worktree:fields.worktree || ""});
    } catch { unreadableHome = true; }
  }
  const backlog = path.join(dataDir, "backlog.md");
  if (fs.existsSync(backlog)) {
    try {
      for (const line of readLines(backlog)) {
        const match = line.match(/^- \[x\] ([A-Za-z0-9._-]+)(?: |$)/);
        if (match) closed.add(`${home}\0${match[1]}`);
      }
    } catch { unreadableHome = true; }
  }
  for (const name of safeFiles(stateDir).filter(name => name.endsWith(".lavish-sessions"))) {
    try {
      for (const line of readLines(path.join(stateDir,name)).filter(Boolean)) {
        const row = JSON.parse(line);
        if (!row.ended_at && row.key) ledgers.set(row.key, row);
      }
    } catch { unreadableHome = true; }
  }
  const pe = path.join(stateDir, "procevent");
  for (const name of safeFiles(pe).filter(name => name.startsWith("lavish-") && name.endsWith(".source"))) {
    sources.add(name.slice(0,-7)); activePollRegistrations++;
  }
  const bindings = path.join(stateDir, "decision-bindings");
  for (const name of safeFiles(bindings).filter(name => name.startsWith("lavish-") && name.endsWith(".origin"))) decisions.add(name.slice(0,-7));
  const inbox = path.join(stateDir, "procevent-inbox");
  for (const name of safeFiles(inbox).filter(name => /^lavish-[^.]+\.[0-9]+\.result$/.test(name))) {
    if (!fs.existsSync(path.join(inbox, name.replace(/\.result$/, ".handled")))) unacked.add(name.replace(/\.[0-9]+\.result$/, ""));
  }
}

const attached = new Map();
if (process.env.ATTACHED_FILE) {
  try {
    for (const line of readLines(process.env.ATTACHED_FILE)) {
      if (!line) continue;
      const [key,kind="client"] = line.split("\t");
      if (key) attached.set(key, kind);
    }
  } catch (error) { fail(`cannot read attached-client evidence: ${error.message}`); }
}
let browserConnections = 0;
try {
  const lsof = process.env.LSOF_FILE
    ? fs.readFileSync(process.env.LSOF_FILE,"utf8")
    : cp.execFileSync("lsof", ["-nP", `-iTCP:${process.env.LAVISH_PORT}`, "-sTCP:ESTABLISHED"], {encoding:"utf8"});
  browserConnections = lsof.split("\n").filter(line => /^(Google|Chromium|Chrome)\s/.test(line)).length;
} catch { unreadableHome = true; }
try {
  const ps = cp.execFileSync("ps", ["-axo", "command="], {encoding:"utf8"});
  for (const row of Object.values(state.sessions)) {
    if (row?.file && ps.split("\n").some(line => line.includes("lavish-axi poll") && line.includes(row.file))) attached.set(row.key, "live-poll-process");
  }
} catch { unreadableHome = true; }

const isUnder = (file, root) => file === root || file.startsWith(root.endsWith(path.sep) ? root : `${root}${path.sep}`);
const evidenceFor = row => {
  const evidence = [];
  let classification = "ambiguous";
  if (!row || !row.key || !row.file) return {classification,evidence:["malformed-registry-row"]};
  if (row.status === "ended") return {classification:"preserve", evidence:["historical-ended-registry-row"]};
  const exists = fs.existsSync(row.file);
  if (!exists) return {classification:"ambiguous", evidence:["unsupported-by-current-Lavish","artifact-missing"]};
  const sid = sourceId(row.file);
  if (row.status === "feedback" || Number(row.pending_prompts || 0) > 0 || (row.prompts || []).length > 0) evidence.push("feedback-or-pending-prompts");
  if ((row.pending_deliveries || []).length > 0 || unacked.has(sid)) evidence.push("unacknowledged-delivery");
  if (sources.has(sid)) evidence.push("registered-process-event-source");
  if (decisions.has(sid)) evidence.push("open-decision-binding");
  if (attached.has(row.key)) evidence.push(`attached-${attached.get(row.key)}`);
  const current = meta.find(owner => owner.worktree && isUnder(row.file, owner.worktree));
  if (current) evidence.push(`current-task:${current.task}`);
  const ledger = ledgers.get(row.key);
  if (ledger) {
    const ledgerHome = ledger.home;
    const live = meta.some(owner => owner.home === ledgerHome && owner.task === ledger.task_id);
    if (live) evidence.push(`ledger-live-task:${ledger.task_id}`);
  }
  if ((row.layout_warnings || []).length > 0 || row.layout_warnings_pending || row.layout_warning_repair_open) evidence.push("unresolved-layout-warning-repair");
  if (evidence.length) return {classification:"preserve",evidence};

  if (row.file.includes(`${path.sep}.treehouse${path.sep}`)) return {classification:"preserve",evidence:["retained-worktree-file"]};

  let closedOwner = null;
  if (ledger && closed.has(`${ledger.home}\0${ledger.task_id}`)) closedOwner = `${ledger.home}:${ledger.task_id}`;
  if (!closedOwner) {
    for (const home of homes) {
      const dataRoot = path.join(home,"data");
      if (!isUnder(row.file,dataRoot)) continue;
      const rel = path.relative(dataRoot,row.file);
      const task = rel.split(path.sep)[0];
      if (task && closed.has(`${home}\0${task}`)) { closedOwner = `${home}:${task}`; break; }
    }
  }
  if (closedOwner && unreadableHome) return {classification:"ambiguous",evidence:[`closed-task:${closedOwner}`,"ownership-incomplete-unreadable-home"]};
  if (closedOwner && row.status === "open" && browserConnections > 0) return {classification:"ambiguous",evidence:[`closed-task:${closedOwner}`,`unmapped-browser-connections:${browserConnections}`]};
  if (closedOwner && row.status === "open") return {classification:"eligible",evidence:[`closed-task:${closedOwner}`,"existing-artifact","no-review-owner-or-client"]};
  if (unreadableHome) return {classification:"ambiguous",evidence:["ownership-incomplete-unreadable-home"]};
  return {classification:"ambiguous",evidence:["no-positive-closed-task-owner"]};
};

const rows = Object.values(state.sessions).sort((a,b) => String(a.key).localeCompare(String(b.key)));
const counts = {total:rows.length,open:0,feedback:0,ended:0,missing_file:0,with_live_task:0,without_live_task:0,active_poll_registrations:activePollRegistrations,attached_clients:attached.size,unmapped_browser_connections:browserConnections};
const eligible = [];
for (const row of rows) {
  if (["open","feedback","ended"].includes(row.status)) counts[row.status]++;
  if (row.status !== "ended" && !fs.existsSync(row.file || "")) counts.missing_file++;
  const live = meta.some(owner => owner.worktree && row.file && isUnder(row.file, owner.worktree));
  if (row.status !== "ended") counts[live ? "with_live_task" : "without_live_task"]++;
  const verdict = evidenceFor(row);
  if (verdict.classification === "eligible") eligible.push({key:row.key,file:row.file,url:row.url,status:row.status,updated_at:row.updated_at || "",evidence:verdict.evidence});
  if (process.env.AUDIT_MODE === "audit") process.stdout.write(`${verdict.classification}\t${row.key}\t${verdict.evidence.join(",")}\t${row.file || "<missing-file-field>"}\n`);
}
if (process.env.AUDIT_MODE === "summary") {
  process.stdout.write(`Lavish registry rows: total=${counts.total} open=${counts.open} feedback=${counts.feedback} ended=${counts.ended} missing_file=${counts.missing_file} with_live_task=${counts.with_live_task} without_live_task=${counts.without_live_task}; live connections: attached_clients=${counts.attached_clients} unmapped_browser_connections=${counts.unmapped_browser_connections}; active_poll_registrations=${counts.active_poll_registrations}\n`);
}
if (process.env.FREEZE_FILE) {
  const dir = path.dirname(process.env.FREEZE_FILE);
  fs.mkdirSync(dir,{recursive:true,mode:0o700});
  const temp = path.join(dir, `.${path.basename(process.env.FREEZE_FILE)}.${process.pid}`);
  fs.writeFileSync(temp, eligible.map(row => JSON.stringify(row)).join("\n") + (eligible.length ? "\n" : ""), {mode:0o600});
  fs.renameSync(temp,process.env.FREEZE_FILE);
}
NODE
}

cmd_audit() {
  local freeze='' homes
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --freeze) [ "$#" -ge 2 ] || usage; freeze=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  homes=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-homes.XXXXXX") || die "cannot stage home inventory"
  # shellcheck disable=SC2064 # Expand the function-local path while it is in scope.
  trap "rm -f -- '$homes'" EXIT
  make_homes_file "$homes"
  run_audit_node audit "$homes" "$freeze"
}

cmd_summary() {
  local homes
  [ "$#" -eq 0 ] || usage
  homes=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-homes.XXXXXX") || die "cannot stage home inventory"
  # shellcheck disable=SC2064 # Expand the function-local path while it is in scope.
  trap "rm -f -- '$homes'" EXIT
  make_homes_file "$homes"
  run_audit_node summary "$homes"
}

count_registry() {
  # shellcheck disable=SC2016 # The single-quoted program is JavaScript, not shell.
  LAVISH_STATE_FILE="$LAVISH_STATE_FILE" node -e '
    const fs=require("node:fs"); const s=JSON.parse(fs.readFileSync(process.env.LAVISH_STATE_FILE,"utf8"));
    const c={open:0,feedback:0,ended:0}; for(const r of Object.values(s.sessions||{})) if(c[r.status]!==undefined)c[r.status]++;
    process.stdout.write(`open=${c.open} feedback=${c.feedback} ended=${c.ended}`);'
}

cmd_apply() {
  local candidate=${1-} batch=10 processed=0 line key file expected_status expected_updated current verdict homes audit_output
  [ -n "$candidate" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --batch-size) [ "$#" -ge 2 ] || usage; batch=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$batch" in ''|*[!0-9]*) die "batch size must be from 1 to 50" ;; esac
  [ "$batch" -ge 1 ] && [ "$batch" -le 50 ] || die "batch size must be from 1 to 50"
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || die "candidate file is not a regular file: $candidate"
  homes=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-homes.XXXXXX") || die "cannot stage home inventory"
  # shellcheck disable=SC2064 # Expand the function-local path while it is in scope.
  trap "rm -f -- '$homes'" EXIT
  make_homes_file "$homes"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r key file expected_status expected_updated <<EOF
$(LINE="$line" node -e 'const r=JSON.parse(process.env.LINE); if(!r.key||!r.file||r.status!=="open")process.exit(1); process.stdout.write([r.key,r.file,r.status,r.updated_at||""].join("\t"))')
EOF
    [ -n "${key:-}" ] || die "candidate file contains an unsupported row"
    current=$(KEY="$key" LAVISH_STATE_FILE="$LAVISH_STATE_FILE" node -e 'const fs=require("node:fs");const s=JSON.parse(fs.readFileSync(process.env.LAVISH_STATE_FILE,"utf8"));const r=(s.sessions||{})[process.env.KEY];if(!r)process.exit(1);process.stdout.write([r.file,r.status,r.updated_at||""].join("\t"))') \
      || die "frozen candidate key is absent: $key"
    [ "$current" = "$file"$'\t'"$expected_status"$'\t'"$expected_updated" ] \
      || die "frozen candidate changed since audit: $key"
    audit_output=$(run_audit_node audit "$homes") || die "could not reclassify frozen candidate: $key"
    verdict=$(printf '%s\n' "$audit_output" | awk -F '\t' -v key="$key" '$2 == key {print $1; exit}')
    [ "$verdict" = eligible ] || die "frozen candidate is no longer eligible: $key ($verdict)"
    [ -f "$file" ] && [ ! -L "$file" ] || die "unsupported-by-current-Lavish: $key $file"
    command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
    lavish-axi end "$file" >/dev/null || die "lavish-axi could not end candidate $key"
    current=$(KEY="$key" LAVISH_STATE_FILE="$LAVISH_STATE_FILE" node -e 'const fs=require("node:fs");const s=JSON.parse(fs.readFileSync(process.env.LAVISH_STATE_FILE,"utf8"));process.stdout.write((s.sessions||{})[process.env.KEY]?.status||"missing")') \
      || die "cannot verify candidate after end: $key"
    [ "$current" = ended ] || die "candidate did not transition to ended: $key (status=$current)"
    processed=$((processed + 1))
    if [ $((processed % batch)) -eq 0 ]; then printf 'batch-complete: processed=%s %s\n' "$processed" "$(count_registry)"; fi
  done < "$candidate"
  if [ $((processed % batch)) -ne 0 ] || [ "$processed" -eq 0 ]; then printf 'batch-complete: processed=%s %s\n' "$processed" "$(count_registry)"; fi
}

case "${1:-audit}" in
  audit) [ "$#" -eq 0 ] || shift; cmd_audit "$@" ;;
  summary) shift; cmd_summary "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
