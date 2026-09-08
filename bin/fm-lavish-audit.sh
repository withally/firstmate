#!/usr/bin/env bash
# Audit the Lavish registry against Firstmate lifecycle ownership without mutation.
#
# Usage:
#   fm-lavish-audit.sh [audit] [--freeze <candidate.jsonl>] [--expiry-hours <hours>]
#                         [--preserve-paths <file>]
#   fm-lavish-audit.sh summary
#   fm-lavish-audit.sh guard <task-id> <artifact.html> <key> [--allow-source <source-id>]
#   fm-lavish-audit.sh apply <candidate.jsonl> [--authorized [<authority.json>]]
#                         [--batch-size <1..50>] [--expiry-hours <hours>]
#                         [--preserve-paths <file>]
#
# audit is the default and classifies every registry row as preserve, eligible,
# or ambiguous with evidence.
# --freeze atomically writes only eligible existing-path rows to a mode-0600
# JSONL candidate file, including the audited status and updated_at values.
# apply accepts only that frozen shape, reclassifies every row against current
# state, ends bounded batches through `lavish-axi end <existing-file>`, verifies
# each transition, and recounts after each batch.
# --authorized accepts captain-authorized ambiguous existing-path rows from a
# frozen authority file carrying the 2026-09-08 ruling and three exclusions.
# It never deletes Lavish records, Firstmate state, chat, attachments, or files,
# and it never edits Lavish state.json directly.
#
# Ownership is read across this FM_HOME and every home registered in its
# data/secondmates.md.
# Remote or unreadable homes remain uncertainty rather than permission to end.
# Browser/session keys that cannot be observed from the registry are accepted
# from FM_LAVISH_ATTACHED_KEYS_FILE, one `<key><TAB><client-kind>` row per client;
# registered and live agent poll ownership is discovered directly.
# The default idle expiry is 48 hours.
# A re-serve updates Lavish's updated_at, and an arm records last_polled_at in
# the ownership ledger; an active poll remains a preserve condition regardless
# of age.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
LAVISH_STATE_FILE="${FM_LAVISH_STATE_FILE:-${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json}"
AUTHORIZATION_DEFAULT="$FM_ROOT/data/fm-lavish-session-prune-f1/authorized-2026-09-08.json"
AUTHORIZATION_RULING='Apply only captain-authorized ambiguous existing-path sessions, except the three links mentioned on 2026-09-08.'

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-lavish-lib.sh
. "$SCRIPT_DIR/fm-lavish-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
LAVISH_STATE_DIR=$(fm_lavish_state_dir "$LAVISH_STATE_FILE") \
  || die "FM_LAVISH_STATE_FILE must be an absolute Lavish state.json path"
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

lavish_cli() { LAVISH_AXI_STATE_DIR="$LAVISH_STATE_DIR" command lavish-axi "$@"; }

lavish_axi_port() {
  local port=${LAVISH_AXI_PORT:-4387}
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  printf '%s\n' "$port"
}

make_homes_file() {
  local out=$1 registry="$FM_HOME/data/secondmates.md" line home
  : > "$out" || die "cannot stage home inventory"
  printf '%s\n' "$FM_HOME" >> "$out" || die "cannot stage home inventory"
  if [ -L "$registry" ]; then
    die "secondmate registry is unavailable or unsafe: $registry"
  fi
  if [ -e "$registry" ]; then
    [ -f "$registry" ] || die "secondmate registry is not a regular file: $registry"
    secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key \
      || die "${SECONDMATE_REGISTRY_ERROR:-secondmate registry validation failed}"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "- "*)
          secondmate_registry_parse_line "$line" \
            || die "malformed secondmate registry entry: $line"
          home=$SECONDMATE_REGISTRY_HOME
          printf '%s\n' "$home" >> "$out" || die "cannot stage home inventory"
          ;;
      esac
    done < "$registry" || die "cannot read secondmate registry: $registry"
  fi
  awk '!seen[$0]++' "$out" > "$out.unique" \
    || die "cannot deduplicate home inventory"
  mv -f "$out.unique" "$out" || die "cannot publish home inventory"
}

run_audit_node() {
  local mode=$1 homes_file=$2 freeze=${3-} guard_task=${4-} guard_file=${5-} guard_key=${6-} guard_home=${7-} guard_allow_source=${8-} port
  port=$(lavish_axi_port) || return 1
  AUDIT_MODE="$mode" HOMES_FILE="$homes_file" FREEZE_FILE="$freeze" \
    LAVISH_STATE_FILE="$LAVISH_STATE_FILE" ATTACHED_FILE="${FM_LAVISH_ATTACHED_KEYS_FILE:-}" \
    ACTIVE_PORT="$port" \
    EXPIRY_HOURS="${FM_LAVISH_IDLE_EXPIRY_HOURS:-48}" PRESERVE_PATHS_FILE="${FM_LAVISH_PRESERVE_PATHS_FILE:-}" \
    GUARD_TASK="$guard_task" GUARD_FILE="$guard_file" GUARD_KEY="$guard_key" GUARD_HOME="$guard_home" GUARD_ALLOW_SOURCE="$guard_allow_source" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const cp = require("node:child_process");

const fail = message => { console.error(`error: ${message}`); process.exit(1); };
const isObject = value => value && typeof value === "object" && !Array.isArray(value);
const isString = value => typeof value === "string";
const isSlug = value => isString(value) && /^[A-Za-z0-9._-]+$/.test(value);
let state;
try { state = JSON.parse(fs.readFileSync(process.env.LAVISH_STATE_FILE, "utf8")); }
catch (error) { fail(`cannot read Lavish state: ${error.message}`); }
if (!isObject(state.sessions)) fail("Lavish state has no session registry object");
let homes;
try { homes = fs.readFileSync(process.env.HOMES_FILE, "utf8").split("\n").filter(Boolean); }
catch (error) { fail(`cannot read home inventory: ${error.message}`); }

const meta = [];
const closed = new Set();
const held = new Map();
const ledgers = new Map();
const sources = new Set();
const decisions = new Set();
const unacked = new Set();
const attached = new Map();
const sourceHomes = new Map();
const preservePaths = new Set();
const inventoryErrors = [];
let unreadableHome = false;
let activePollRegistrations = 0;
const addInventoryError = (home, message) => {
  unreadableHome = true;
  inventoryErrors.push(`${home}: ${message}`);
};
const addAttached = (key, kind) => {
  if (!attached.has(key)) attached.set(key, []);
  attached.get(key).push(kind);
};
const addHeld = (key, kind) => {
  if (!held.has(key)) held.set(key, []);
  held.get(key).push(kind);
};
const addLedger = (key, row) => {
  if (!ledgers.has(key)) ledgers.set(key, []);
  ledgers.get(key).push(row);
};
const addSource = (sid, home) => {
  sources.add(sid);
  if (!sourceHomes.has(sid)) sourceHomes.set(sid, []);
  sourceHomes.get(sid).push(home);
};
const sourceId = file => `lavish-${crypto.createHash("sha256").update(file).digest("hex").slice(0,16)}`;

const listDir = (home, dir, label, optional = true) => {
  try {
    const stat = fs.lstatSync(dir);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error("not a safe directory");
    return fs.readdirSync(dir);
  } catch (error) {
    if (error.code === "ENOENT" && optional) return [];
    addInventoryError(home, `${label} is unreadable: ${error.message}`);
    return [];
  }
};
const readInventoryFile = (home, file, label, optional = true) => {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("not a safe regular file");
    return fs.readFileSync(file, "utf8");
  } catch (error) {
    if (optional && error.code === "ENOENT") return null;
    addInventoryError(home, `${label} is unreadable: ${error.message}`);
    return null;
  }
};
const regularArtifact = file => {
  try {
    const stat = fs.lstatSync(file);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch (error) {
    if (error.code === "ENOENT") return false;
    return false;
  }
};
const isUnder = (file, root) => file === root || file.startsWith(root.endsWith(path.sep) ? root : `${root}${path.sep}`);
const ownerKey = (home, task) => `${home}\0${task}`;
const parseFields = (text, file) => {
  const fields = {};
  for (const line of text.split("\n")) {
    if (!line) continue;
    const index = line.indexOf("=");
    if (index <= 0) throw new Error(`malformed line in ${file}`);
    const key = line.slice(0, index);
    if (Object.prototype.hasOwnProperty.call(fields, key)) throw new Error(`duplicate field in ${file}: ${key}`);
    fields[key] = line.slice(index + 1);
  }
  return fields;
};

const normalizedHomes = [];
const seenHomes = new Set();
for (const rawHome of homes) {
  try {
    const home = fs.realpathSync(rawHome);
    const stat = fs.statSync(home);
    if (!stat.isDirectory()) throw new Error("home is not a directory");
    if (seenHomes.has(home)) continue;
    seenHomes.add(home);
    normalizedHomes.push(home);
  } catch (error) {
    addInventoryError(rawHome, `home is unreadable: ${error.message}`);
  }
}

for (const home of normalizedHomes) {
  const stateDir = path.join(home, "state");
  const dataDir = path.join(home, "data");
  const stateNames = listDir(home, stateDir, "state directory", false);
  listDir(home, dataDir, "data directory", false);

  for (const name of stateNames.filter(item => item.endsWith(".meta"))) {
    const task = name.slice(0, -5);
    const file = path.join(stateDir, name);
    if (!isSlug(task)) {
      addInventoryError(home, `task metadata has an unsafe name: ${name}`);
      continue;
    }
    const text = readInventoryFile(home, file, "task metadata", false);
    if (text === null) continue;
    try {
      const fields = parseFields(text, file);
      if (fields.kind === "secondmate") {
        if (!isString(fields.worktree) || !fields.worktree || !path.isAbsolute(fields.worktree) || !isString(fields.home) || !fields.home || !path.isAbsolute(fields.home)) throw new Error("secondmate metadata has no safe absolute home and worktree");
        let secondmateHome;
        try { secondmateHome = fs.realpathSync(fields.home); } catch (error) { throw new Error(`secondmate metadata home is unreadable: ${error.message}`); }
        if (!normalizedHomes.includes(secondmateHome)) throw new Error("secondmate metadata home is not in registered home inventory");
        let worktree = fields.worktree;
        try { worktree = fs.realpathSync(worktree); } catch (error) { if (error.code !== "ENOENT") throw error; }
        meta.push({task,home:secondmateHome,worktree});
        continue;
      }
      if (!isString(fields.worktree) || !fields.worktree) throw new Error("task metadata has no worktree");
      if (!path.isAbsolute(fields.worktree)) throw new Error("task metadata worktree is not absolute");
      let worktree = fields.worktree;
      try { worktree = fs.realpathSync(worktree); } catch (error) { if (error.code !== "ENOENT") throw error; }
      meta.push({task,home,worktree});
    } catch (error) {
      addInventoryError(home, error.message);
    }
  }

  const backlog = path.join(dataDir, "backlog.md");
  const backlogText = readInventoryFile(home, backlog, "backlog", true);
  if (backlogText !== null) {
    for (const line of backlogText.split("\n")) {
      const done = line.match(/^- \[x\] ([A-Za-z0-9._-]+)(?: |$)/);
      if (done) closed.add(ownerKey(home, done[1]));
      const taskMatch = line.match(/^- \[[ x]\] ([A-Za-z0-9._-]+)(?: |$)/);
      const holdMatch = line.match(/\(hold-kind: ([A-Za-z0-9._-]+)\)/);
      if (taskMatch && holdMatch) addHeld(ownerKey(home, taskMatch[1]), holdMatch[1]);
    }
  }

  for (const name of stateNames.filter(item => item.endsWith(".lavish-sessions"))) {
    const task = name.slice(0, -17);
    const file = path.join(stateDir, name);
    if (!isSlug(task)) {
      addInventoryError(home, `Lavish ledger has an unsafe name: ${name}`);
      continue;
    }
    const text = readInventoryFile(home, file, "Lavish ledger", false);
    if (text === null) continue;
    if (!text.trim()) {
      addInventoryError(home, `Lavish ledger is empty: ${file}`);
      continue;
    }
    for (const line of text.split("\n").filter(Boolean)) {
      try {
        const row = JSON.parse(line);
        if (!isObject(row) || !isSlug(row.task_id) || row.task_id !== task || !isString(row.home) || !path.isAbsolute(row.home) || !isString(row.artifact) || !path.isAbsolute(row.artifact) || !isString(row.key) || !["ephemeral-worktree", "durable-review"].includes(row.disposition)) throw new Error(`malformed Lavish ledger row in ${file}`);
        if ((row.url !== undefined && !isString(row.url)) || (row.created_at !== undefined && (!isString(row.created_at) || (row.created_at && !Number.isFinite(Date.parse(row.created_at))))) || (row.last_polled_at !== undefined && (!isString(row.last_polled_at) || (row.last_polled_at && !Number.isFinite(Date.parse(row.last_polled_at))))) || (row.ended_at !== undefined && (!isString(row.ended_at) || (row.ended_at && !Number.isFinite(Date.parse(row.ended_at))))) ) throw new Error(`malformed Lavish ledger timestamps or URL in ${file}`);
        if (state.sessions[row.key] && state.sessions[row.key].status === "ended" && !row.ended_at) throw new Error(`active ledger row points to ended session ${row.key}`);
        if (!state.sessions[row.key]) throw new Error(`active ledger row points to missing session ${row.key}`);
        if (!row.ended_at) addLedger(row.key, row);
      } catch (error) {
        addInventoryError(home, error.message);
      }
    }
  }

  const processEventDir = path.join(stateDir, "procevent");
  for (const name of listDir(home, processEventDir, "process-event directory").filter(item => /^lavish-[^.]+\.source$/.test(item))) {
    const file = path.join(processEventDir, name);
    const text = readInventoryFile(home, file, "process-event source", false);
    if (text === null) continue;
    if (!/^adapter=lavish\n/m.test(text) || !/^argv:\n/m.test(text)) addInventoryError(home, `malformed process-event source: ${file}`);
    addSource(name.slice(0, -7), home);
    activePollRegistrations++;
  }

  const bindingDir = path.join(stateDir, "decision-bindings");
  for (const name of listDir(home, bindingDir, "decision-binding directory").filter(item => /^lavish-[^.]+\.origin$/.test(item))) {
    const file = path.join(bindingDir, name);
    const text = readInventoryFile(home, file, "decision binding", false);
    if (text === null) continue;
    decisions.add(name.slice(0, -7));
  }

  const inbox = path.join(stateDir, "procevent-inbox");
  for (const name of listDir(home, inbox, "process-event inbox").filter(item => /^lavish-[^.]+\.[0-9]+\.result$/.test(item))) {
    const result = path.join(inbox, name);
    const resultText = readInventoryFile(home, result, "process-event result", false);
    if (resultText === null) continue;
    const handled = path.join(inbox, name.replace(/\.result$/, ".handled"));
    try {
      const handledStat = fs.lstatSync(handled);
      if (!handledStat.isFile() || handledStat.isSymbolicLink()) addInventoryError(home, `handled process-event marker is not a safe regular file: ${handled}`);
    } catch (error) {
      if (error.code === "ENOENT") unacked.add(name.replace(/\.[0-9]+\.result$/, ""));
      else addInventoryError(home, `handled process-event marker is unreadable: ${handled}: ${error.message}`);
    }
  }
}

if (process.env.PRESERVE_PATHS_FILE) {
  const text = readInventoryFile("preserve-paths", process.env.PRESERVE_PATHS_FILE, "preserve-path evidence", false);
  if (text === null) fail("cannot read preserve-path evidence");
  for (const line of text.split("\n")) if (line) preservePaths.add(line);
}

const expiryHours = Number(process.env.EXPIRY_HOURS);
if (!Number.isFinite(expiryHours) || expiryHours < 0) fail("idle expiry hours must be a non-negative number");
if (process.env.ATTACHED_FILE) {
  const text = readInventoryFile("attached-client-evidence", process.env.ATTACHED_FILE, "attached-client evidence", false);
  if (text === null) fail("cannot read attached-client evidence");
  for (const line of text.split("\n").filter(Boolean)) {
    const parts = line.split("\t");
    if (!parts[0] || parts.length > 2) fail("attached-client evidence is malformed");
    addAttached(parts[0], parts[1] || "client");
  }
}

let browserConnections = 0;
try {
  let lsof;
  try {
    lsof = cp.execFileSync("lsof", ["-nP", `-iTCP:${process.env.ACTIVE_PORT}`, "-sTCP:ESTABLISHED"], {encoding:"utf8"});
  } catch (error) {
    if (error.status !== 1 || error.stdout === undefined) throw error;
    lsof = String(error.stdout);
  }
  browserConnections = lsof.split("\n").filter(line => /^(Google|Chromium|Chrome)\s/.test(line)).length;
} catch (error) {
  addInventoryError("runtime", `cannot inspect established connections: ${error.message}`);
}
try {
  const ps = cp.execFileSync("ps", ["-axo", "command="], {encoding:"utf8"});
  for (const row of Object.values(state.sessions)) {
    if (isObject(row) && isString(row.file) && isString(row.key) && ps.split("\n").some(line => line.includes("lavish-axi poll") && line.includes(row.file))) addAttached(row.key, "live-poll-process");
  }
} catch (error) {
  addInventoryError("runtime", `cannot inspect live poll processes: ${error.message}`);
}

const dataOwnersFor = file => {
  const owners = [];
  for (const home of normalizedHomes) {
    const dataRoot = path.join(home, "data");
    if (!isUnder(file, dataRoot)) continue;
    const task = path.relative(dataRoot, file).split(path.sep)[0];
    if (isSlug(task)) owners.push({home,task});
  }
  return owners;
};
const ledgerRowsFor = key => ledgers.get(key) || [];
const currentOwnersFor = file => meta.filter(owner => owner.worktree && isUnder(file, owner.worktree));
const lastActivityFor = (row, ledgerRows) => {
  const values = [row.updated_at, ...ledgerRows.map(item => item.last_polled_at)].filter(isString).map(value => Date.parse(value)).filter(Number.isFinite);
  return values.length ? Math.max(...values) : NaN;
};
const homeBoardOwnersFor = file => normalizedHomes.filter(home => file === path.join(home, ".lavish", "bearings-board.html")).map(home => ({home,task:"home"}));
const validSessionRow = (row, registryKey) => {
  if (!isObject(row) || !isString(row.key) || !row.key || /[\r\n]/.test(row.key) || !isString(row.file) || !path.isAbsolute(row.file) || /[\r\n]/.test(row.file)) return false;
  if (registryKey !== undefined && row.key !== registryKey) return false;
  if (row.url !== undefined && !isString(row.url)) return false;
  if (row.updated_at !== undefined && (!isString(row.updated_at) || (row.updated_at && !Number.isFinite(Date.parse(row.updated_at))))) return false;
  if (row.pending_prompts !== undefined && (!Number.isInteger(row.pending_prompts) || row.pending_prompts < 0)) return false;
  for (const field of ["prompts", "pending_deliveries", "layout_warnings"]) if (row[field] !== undefined && !Array.isArray(row[field])) return false;
  for (const field of ["layout_warnings_pending", "layout_warning_repair_open"]) if (row[field] !== undefined && typeof row[field] !== "boolean") return false;
  return ["open", "feedback", "ended"].includes(row.status);
};
for (const [registryKey, row] of Object.entries(state.sessions)) {
  if (!validSessionRow(row, registryKey)) addInventoryError("Lavish state", "malformed Lavish registry row: " + registryKey);
}
const evidenceFor = row => {
  const evidence = [];
  if (!validSessionRow(row)) return {classification:"ambiguous",evidence:["malformed-registry-row"]};
  if (row.status === "ended") return {classification:"preserve", evidence:["historical-ended-registry-row"]};
  let artifactState;
  try {
    const stat = fs.lstatSync(row.file);
    artifactState = stat.isFile() && !stat.isSymbolicLink() ? "regular" : "unsupported";
  } catch (error) {
    if (error.code === "ENOENT") artifactState = "missing";
    else artifactState = "unsupported";
  }
  if (artifactState === "missing") return {classification:"ambiguous", evidence:["unsupported-by-current-Lavish","artifact-missing"]};
  if (artifactState !== "regular") return {classification:"ambiguous", evidence:["unsupported-by-current-Lavish","artifact-not-regular"]};
  if ([...preservePaths].some(item => row.file === item || (item.endsWith(path.sep) && row.file.startsWith(item)))) return {classification:"preserve",evidence:["captain-preserve-path"]};

  const sid = sourceId(row.file);
  const guardTarget = Boolean(process.env.GUARD_KEY) && row.key === process.env.GUARD_KEY && row.file === process.env.GUARD_FILE;
  const guardOwnerAllowed = owner => guardTarget && owner.home === process.env.GUARD_HOME && (owner.task_id || owner.task) === process.env.GUARD_TASK;
  const withoutGuardOwner = owners => owners.filter(owner => !guardOwnerAllowed(owner));
  const currentOwners = withoutGuardOwner(currentOwnersFor(row.file));
  const rowLedgers = withoutGuardOwner(ledgerRowsFor(row.key));
  const dataOwners = withoutGuardOwner(dataOwnersFor(row.file));
  const openDataOwners = dataOwners.filter(owner => !closed.has(ownerKey(owner.home, owner.task)));
  const boardOwners = withoutGuardOwner(homeBoardOwnersFor(row.file));
  const ownerIdentities = new Set();
  for (const owner of currentOwners) ownerIdentities.add(ownerKey(owner.home, owner.task));
  for (const owner of rowLedgers) ownerIdentities.add(ownerKey(owner.home, owner.task_id));
  for (const owner of dataOwners) ownerIdentities.add(ownerKey(owner.home, owner.task));
  for (const owner of boardOwners) ownerIdentities.add(ownerKey(owner.home, owner.task));
  const knownHomes = new Set(normalizedHomes);
  const unlistedLedger = rowLedgers.some(owner => !knownHomes.has(owner.home));
  const duplicateLedger = rowLedgers.length > 1;
  const ambiguousOwnership = ownerIdentities.size > 1 || duplicateLedger || unlistedLedger;
  if (currentOwners.length) for (const owner of currentOwners) evidence.push(`current-task:${owner.task}`);
  for (const owner of rowLedgers) {
    evidence.push(`ledger-owner:${owner.task_id}`);
    if (currentOwners.some(item => item.home === owner.home && item.task === owner.task_id)) evidence.push(`ledger-live-task:${owner.task_id}`);
  }
  for (const owner of openDataOwners) evidence.push(`data-owner:${owner.task}`);
  for (const owner of boardOwners) evidence.push(`home-durable-review:${owner.home}`);
  for (const owner of [...rowLedgers, ...dataOwners]) {
    const key = ownerKey(owner.home, owner.task_id || owner.task);
    const kinds = held.get(key) || [];
    for (const kind of kinds) evidence.push(`retained-backlog-hold:${kind}`);
  }
  if (ambiguousOwnership) evidence.push("ambiguous-ownership");
  if (row.status === "feedback" || Number(row.pending_prompts || 0) > 0 || (row.prompts || []).length > 0) evidence.push("feedback-or-pending-prompts");
  if ((row.pending_deliveries || []).length > 0 || unacked.has(sid)) evidence.push("unacknowledged-delivery");
  if (decisions.has(sid)) evidence.push("open-decision-binding");
  if (attached.has(row.key)) for (const kind of attached.get(row.key)) evidence.push(`attached-${kind}`);
  if ((row.layout_warnings || []).length > 0 || row.layout_warnings_pending || row.layout_warning_repair_open) evidence.push("unresolved-layout-warning-repair");
  const sourceHomesForRow = sourceHomes.get(sid) || [];
  const sourceOwnedByGuard = guardTarget && process.env.GUARD_ALLOW_SOURCE === sid && sourceHomesForRow.length === 1 && sourceHomesForRow[0] === process.env.GUARD_HOME;
  if (!guardTarget && sources.has(sid)) evidence.push("registered-process-event-source");
  if (guardTarget) {
    if (browserConnections > 0) evidence.push(`unmapped-browser-connections:${browserConnections}`);
    if (sources.has(sid) && !sourceOwnedByGuard) evidence.push("registered-process-event-source");
    return {classification:evidence.length ? "blocked" : "ready",evidence};
  }
  if (ambiguousOwnership) return {classification:"ambiguous",evidence};
  if (evidence.some(item => !item.startsWith("retained-backlog-hold:") && !item.startsWith("current-task:") && !item.startsWith("ledger-live-task:") && !item.startsWith("ledger-owner:") && !item.startsWith("data-owner:") && !item.startsWith("home-durable-review:")) || currentOwners.length || rowLedgers.length || openDataOwners.length || boardOwners.length || [...rowLedgers, ...dataOwners].some(owner => held.has(ownerKey(owner.home, owner.task_id || owner.task)))) return {classification:"preserve",evidence};
  if (row.file.includes(`${path.sep}.treehouse${path.sep}`)) return {classification:"preserve",evidence:["retained-worktree-file"]};

  if (unreadableHome) return {classification:"ambiguous",evidence:["ownership-incomplete-unreadable-home"]};
  const lastActivity = lastActivityFor(row, rowLedgers);
  const expired = Number.isFinite(lastActivity) && Date.now() - lastActivity >= expiryHours * 60 * 60 * 1000;
  if (expired && browserConnections > 0) return {classification:"ambiguous",evidence:[`idle-expired:${expiryHours}h`,`unmapped-browser-connections:${browserConnections}`]};

  const closedOwners = [];
  for (const owner of [...rowLedgers, ...dataOwners]) {
    const key = ownerKey(owner.home, owner.task_id || owner.task);
    if (closed.has(key) && !closedOwners.some(item => item === key)) closedOwners.push(key);
  }
  if (closedOwners.length > 1) return {classification:"ambiguous",evidence:["ambiguous-closed-task-ownership",...closedOwners.map(item => `closed-task:${item.replace("\0",":")}`)]};
  if (browserConnections > 0) return {classification:"ambiguous",evidence:[`unmapped-browser-connections:${browserConnections}`]};
  if (expired) return {classification:"eligible",evidence:[`idle-expired:${expiryHours}h`,"existing-artifact","no-review-owner-or-client"]};
  if (closedOwners.length === 1) return {classification:"eligible",evidence:[`closed-task:${closedOwners[0].replace("\0",":")}`,"existing-artifact","no-review-owner-or-client"]};
  return {classification:"ambiguous",evidence:["no-positive-closed-task-owner"]};
};

const rows = Object.values(state.sessions).sort((a,b) => String(a?.key || "").localeCompare(String(b?.key || "")));
const counts = {total:rows.length,open:0,feedback:0,ended:0,missing_file:0,past_expiry:0,with_live_task:0,without_live_task:0,active_poll_registrations:activePollRegistrations,attached_clients:attached.size,unmapped_browser_connections:browserConnections};
const eligible = [];
for (const row of rows) {
  if (isObject(row) && ["open","feedback","ended"].includes(row.status)) counts[row.status]++;
  if (!isObject(row) || !isString(row.file) || !regularArtifact(row.file)) counts.missing_file++;
  const rowLedgers = isObject(row) && isString(row.key) ? ledgerRowsFor(row.key) : [];
  const lastActivity = isObject(row) ? lastActivityFor(row, rowLedgers) : NaN;
  if (row?.status === "open" && Number.isFinite(lastActivity) && Date.now() - lastActivity >= expiryHours * 60 * 60 * 1000) counts.past_expiry++;
  const live = isObject(row) && isString(row.file) && currentOwnersFor(row.file).length > 0;
  if (row?.status !== "ended") counts[live ? "with_live_task" : "without_live_task"]++;
  const verdict = evidenceFor(row);
  if (verdict.classification === "eligible") eligible.push({key:row.key,file:row.file,url:row.url || "",status:row.status,updated_at:row.updated_at || "",evidence:verdict.evidence});
  if (process.env.AUDIT_MODE === "audit") process.stdout.write(`${verdict.classification}\t${row?.key || "<missing-key>"}\t${verdict.evidence.join(",")}\t${row?.file || "<missing-file-field>"}\n`);
}
if (unreadableHome) fail(`home inventory is unreadable or malformed; refusing eligibility: ${inventoryErrors.join("; ")}`);
if (process.env.AUDIT_MODE === "guard") {
  const target = rows.find(row => isObject(row) && row.key === process.env.GUARD_KEY && row.file === process.env.GUARD_FILE);
  if (!target) fail("durable Lavish guard target is absent from the registry");
  const verdict = evidenceFor(target);
  if (verdict.classification !== "ready") fail("durable Lavish end guard refused: " + verdict.evidence.join(","));
  process.stdout.write("durable Lavish end guard: ready\n");
}
if (process.env.AUDIT_MODE === "summary") {
  process.stdout.write(`Lavish registry rows: total=${counts.total} open=${counts.open} feedback=${counts.feedback} ended=${counts.ended} missing_file=${counts.missing_file} past_expiry=${counts.past_expiry} expiry_hours=${expiryHours} with_live_task=${counts.with_live_task} without_live_task=${counts.without_live_task}; live connections: attached_clients=${counts.attached_clients} unmapped_browser_connections=${counts.unmapped_browser_connections}; active_poll_registrations=${counts.active_poll_registrations}\n`);
}
if (process.env.FREEZE_FILE) {
  const dir = path.dirname(process.env.FREEZE_FILE);
  try {
    fs.mkdirSync(dir,{recursive:true,mode:0o700});
    const temp = path.join(dir, `.${path.basename(process.env.FREEZE_FILE)}.${process.pid}`);
    fs.writeFileSync(temp, eligible.map(row => JSON.stringify(row)).join("\n") + (eligible.length ? "\n" : ""), {mode:0o600});
    fs.renameSync(temp,process.env.FREEZE_FILE);
  } catch (error) { fail(`cannot publish frozen candidate: ${error.message}`); }
}
NODE
}

cmd_audit() {
  local freeze='' homes expiry=48 preserve_paths=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --freeze) [ "$#" -ge 2 ] || usage; freeze=$2; shift 2 ;;
      --expiry-hours) [ "$#" -ge 2 ] || usage; expiry=$2; shift 2 ;;
      --preserve-paths) [ "$#" -ge 2 ] || usage; preserve_paths=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  homes=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-homes.XXXXXX") || die "cannot stage home inventory"
  # shellcheck disable=SC2064 # Expand the function-local path while it is in scope.
  trap "rm -f -- '$homes'" EXIT
  make_homes_file "$homes"
  FM_LAVISH_IDLE_EXPIRY_HOURS="$expiry" FM_LAVISH_PRESERVE_PATHS_FILE="$preserve_paths" \
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

canonical_file() {
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null \
    || die "cannot resolve path: $1"
}

cmd_guard() {
  [ "$#" -ge 3 ] || usage
  local task=$1 artifact=$2 key=$3 allow_source='' real homes guard_home
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --allow-source) [ "$#" -ge 2 ] || usage; allow_source=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$task" in ''|*[!A-Za-z0-9._-]*) die "task id must be a privacy-safe slug: $task" ;; esac
  case "$key" in ''|*$'\n'*|*$'\r'*) die "Lavish key is invalid" ;; esac
  real=$(canonical_file "$artifact")
  [ -f "$real" ] && [ ! -L "$real" ] || die "artifact is not a safe regular file: $artifact"
  guard_home=$(canonical_file "$FM_HOME")
  homes=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-homes.XXXXXX") || die "cannot stage home inventory"
  # shellcheck disable=SC2064
  trap "rm -f -- '$homes'" EXIT
  make_homes_file "$homes"
  run_audit_node guard "$homes" '' "$task" "$real" "$key" "$guard_home" "$allow_source" >/dev/null \
    || die "durable Lavish end guard refused: $key"
}

count_registry() {
  # shellcheck disable=SC2016 # The single-quoted program is JavaScript, not shell.
  LAVISH_STATE_FILE="$LAVISH_STATE_FILE" node -e '
    const fs=require("node:fs"); const s=JSON.parse(fs.readFileSync(process.env.LAVISH_STATE_FILE,"utf8"));
    const c={open:0,feedback:0,ended:0}; for(const r of Object.values(s.sessions||{})) if(c[r.status]!==undefined)c[r.status]++;
    process.stdout.write(`open=${c.open} feedback=${c.feedback} ended=${c.ended}`);'
}

build_apply_queue() {
  local candidate=$1 authority=${2-} queue=$3
  CANDIDATE_FILE="$candidate" AUTHORITY_FILE="$authority" AUTHORIZATION_RULING="$AUTHORIZATION_RULING" node <<'NODE' > "$queue" \
    || return 1
const fs = require("node:fs");
const fail = message => { console.error(`error: ${message}`); process.exit(1); };
const isObject = value => value && typeof value === "object" && !Array.isArray(value);
const isString = value => typeof value === "string";
const requiredRow = (row, label) => {
  if (!isObject(row) || !isString(row.key) || !row.key || !isString(row.file) || !row.file || !isString(row.status) || row.status !== "open" || (row.updated_at !== undefined && !isString(row.updated_at)) || (row.url !== undefined && !isString(row.url))) fail(`${label} contains an unsupported row`);
  return {key:row.key,file:row.file,url:row.url || "",status:row.status,updated_at:row.updated_at || ""};
};
const readJsonLines = (file, label) => {
  const rows = [];
  for (const line of fs.readFileSync(file, "utf8").split("\n").filter(Boolean)) {
    let row;
    try { row = JSON.parse(line); } catch { fail(`${label} contains malformed JSON`); }
    rows.push(requiredRow(row,label));
  }
  return rows;
};
const candidate = readJsonLines(process.env.CANDIDATE_FILE, "candidate file");
let authority = null;
if (process.env.AUTHORITY_FILE) {
  try { authority = JSON.parse(fs.readFileSync(process.env.AUTHORITY_FILE, "utf8")); }
  catch (error) { fail(`cannot read authorization file: ${error.message}`); }
  if (!isObject(authority) || authority.schema !== "fm-lavish-session-authority.v1" || authority.ruling_date !== "2026-09-08" || authority.frozen_at !== "2026-09-08" || authority.ruling !== process.env.AUTHORIZATION_RULING || !Array.isArray(authority.authorized) || !Array.isArray(authority.excluded) || authority.excluded.length !== 3) fail("authorization file does not carry the frozen 2026-09-08 ruling and three exclusions");
  const keptBoards = new Map([
    ["7f59a8c16dff9f19", {url:"http://127.0.0.1:4387/session/7f59a8c16dff9f19",file:"/Users/ivan/Projects/firstmate/data/nancy-tennis-directions-board-b2/board/index.html"}],
    ["4ae99e8ad06d4a8c", {url:"http://127.0.0.1:4387/session/4ae99e8ad06d4a8c",file:"/Users/ivan/.treehouse/firstmate-bd0d1d/8/firstmate/data/ally-screener-paid-media/board/index.html"}],
    ["cc73671c247bff78", {url:"http://127.0.0.1:4387/session/cc73671c247bff78",file:"/Users/ivan/Projects/firstmate/data/syd-board-b1/board/index.html"}],
  ]);
  const exclusions = new Set();
  for (const row of authority.excluded) {
    const expected = isObject(row) && keptBoards.get(row.key);
    if (!expected || !isString(row.file) || !isString(row.url) || row.file !== expected.file || row.url !== expected.url || row.reason !== "kept board named in the 2026-09-08 ruling" || exclusions.has(row.key)) fail("authorization exclusions are malformed, duplicated, or do not match the three kept boards");
    exclusions.add(row.key);
  }
  if (exclusions.size !== keptBoards.size) fail("authorization exclusions do not cover the three kept boards");
  const keys = new Set();
  for (const row of authority.authorized) {
    const normalized = requiredRow(row,"authorization file");
    if (row.classification !== "ambiguous" || keys.has(normalized.key) || exclusions.has(normalized.key) || authority.excluded.some(item => item.file === normalized.file || item.url === normalized.url)) fail("authorization rows are malformed, duplicated, or excluded");
    keys.add(normalized.key);
    process.stdout.write(`${JSON.stringify({...normalized,authorization:"captain-authorized"})}\n`);
  }
  for (const row of candidate) if (exclusions.has(row.key) || authority.excluded.some(item => item.file === row.file || item.url === row.url)) fail(`candidate is one of the three kept boards: ${row.key}`);
}
const seen = new Set();
for (const row of candidate) {
  if (["7f59a8c16dff9f19", "4ae99e8ad06d4a8c", "cc73671c247bff78"].includes(row.key)) fail("candidate is one of the three kept boards: " + row.key);
}
for (const row of candidate) {
  if (seen.has(row.key)) fail(`candidate contains duplicate key: ${row.key}`);
  seen.add(row.key);
  process.stdout.write(`${JSON.stringify({...row,authorization:"eligible-candidate"})}\n`);
}
if (authority) {
  const authorizedRows = authority.authorized.map(row => requiredRow(row,"authorization file"));
  for (const row of authorizedRows) {
    if (seen.has(row.key)) fail(`candidate and authorization both contain key: ${row.key}`);
    seen.add(row.key);
  }
}
NODE
}

finalize_key_for_homes() {
  local key=$1 homes_file=$2 home
  while IFS= read -r home || [ -n "$home" ]; do
    [ -n "$home" ] || continue
    [ -d "$home/state" ] || continue
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      "$SCRIPT_DIR/fm-lavish-session.sh" finalize-key "$key" >/dev/null \
      || die "cannot finalize Lavish ledger rows for $key"
  done < "$homes_file"
}

cmd_apply() {
  local candidate=${1-} batch=10 processed=0 line key file expected_status expected_updated expected_url current verdict authorization homes audit_output expiry=48 preserve_paths='' authority='' queue
  [ -n "$candidate" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --authorized)
        if [ "$#" -ge 2 ] && [ "${2#--}" = "$2" ]; then authority=$2; shift 2; else authority=$AUTHORIZATION_DEFAULT; shift; fi
        ;;
      --batch-size) [ "$#" -ge 2 ] || usage; batch=$2; shift 2 ;;
      --expiry-hours) [ "$#" -ge 2 ] || usage; expiry=$2; shift 2 ;;
      --preserve-paths) [ "$#" -ge 2 ] || usage; preserve_paths=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$batch" in ''|*[!0-9]*) die "batch size must be from 1 to 50" ;; esac
  [ "$batch" -ge 1 ] && [ "$batch" -le 50 ] || die "batch size must be from 1 to 50"
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || die "candidate file is not a regular file: $candidate"
  if [ -n "$authority" ]; then
    [ -f "$authority" ] && [ ! -L "$authority" ] || die "authorization file is not a regular file: $authority"
  fi
  homes=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-homes.XXXXXX") || die "cannot stage home inventory"
  queue=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-apply.XXXXXX") || { rm -f "$homes"; die "cannot stage apply queue"; }
  # shellcheck disable=SC2064 # Expand the function-local paths while they are in scope.
  trap "rm -f -- '$homes' '$queue'" EXIT
  make_homes_file "$homes"
  build_apply_queue "$candidate" "$authority" "$queue" \
    || die "cannot validate frozen apply inputs"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=''; file=''; expected_status=''; expected_updated=''; expected_url=''; authorization=''
    IFS=$'\t' read -r key file expected_url expected_status expected_updated authorization <<EOF
$(LINE="$line" node -e 'const r=JSON.parse(process.env.LINE); process.stdout.write([r.key,r.file,r.url||"",r.status,r.updated_at||"",r.authorization||""].join("\t"))')
EOF
    [ -n "$key" ] || die "apply queue contains an unsupported row"
    audit_output=$(FM_LAVISH_IDLE_EXPIRY_HOURS="$expiry" FM_LAVISH_PRESERVE_PATHS_FILE="$preserve_paths" \
      run_audit_node audit "$homes") \
      || die "could not reclassify frozen candidate: $key"
    current=$(KEY="$key" LAVISH_STATE_FILE="$LAVISH_STATE_FILE" node -e 'const fs=require("node:fs");const s=JSON.parse(fs.readFileSync(process.env.LAVISH_STATE_FILE,"utf8"));const r=(s.sessions||{})[process.env.KEY];if(!r)process.exit(1);process.stdout.write([r.file,r.url||"",r.status,r.updated_at||""].join("\t"))') \
      || die "frozen candidate key is absent: $key"
    [ "$current" = "$file"$'\t'"$expected_url"$'\t'"$expected_status"$'\t'"$expected_updated" ] \
      || die "frozen candidate changed since audit: $key"
    verdict=$(printf '%s\n' "$audit_output" | awk -F '\t' -v key="$key" '$2 == key {print $1; exit}')
    if [ "$authorization" = captain-authorized ]; then
      [ "$verdict" = ambiguous ] || die "captain-authorized row is no longer ambiguous: $key ($verdict)"
    else
      [ "$verdict" = eligible ] || die "frozen candidate is no longer eligible: $key ($verdict)"
    fi
    [ -f "$file" ] && [ ! -L "$file" ] || die "unsupported-by-current-Lavish: $key $file"
    command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
    lavish_cli end "$file" >/dev/null || die "lavish-axi could not end candidate $key"
    current=$(KEY="$key" LAVISH_STATE_FILE="$LAVISH_STATE_FILE" node -e 'const fs=require("node:fs");const s=JSON.parse(fs.readFileSync(process.env.LAVISH_STATE_FILE,"utf8"));process.stdout.write((s.sessions||{})[process.env.KEY]?.status||"missing")') \
      || die "cannot verify candidate after end: $key"
    [ "$current" = ended ] || die "candidate did not transition to ended: $key (status=$current)"
    finalize_key_for_homes "$key" "$homes"
    processed=$((processed + 1))
    if [ $((processed % batch)) -eq 0 ]; then printf 'batch-complete: processed=%s %s\n' "$processed" "$(count_registry)"; fi
  done < "$queue"
  if [ $((processed % batch)) -ne 0 ] || [ "$processed" -eq 0 ]; then printf 'batch-complete: processed=%s %s\n' "$processed" "$(count_registry)"; fi
}

case "${1:-audit}" in
  audit) [ "$#" -eq 0 ] || shift; cmd_audit "$@" ;;
  summary) shift; cmd_summary "$@" ;;
  guard) shift; cmd_guard "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
