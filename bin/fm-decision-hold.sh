#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to routed work or to an explicit no-work
# captain answer.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent while that hold is still live. Once the decision is closed, `hold`
# refuses the identity even after retention moves it out of the live backlog, so a
# new decision needs a new decision key. A different decision key creates a
# different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh decline <origin-id> <decision-key> --decision-file <path>
#   fm-decision-hold.sh repair <origin-id> <decision-key> --decision-file <path>
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded. Resolved holds remain authoritative after
# retention moves them to the archive declared by `[markdown].archive`, or to the
# tasks-axi default archive derived from `[markdown].path` when that key is absent.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
# `decline` records a no-follow-up answer and closes only an active hold with no
# remaining dependent work. `repair` records the same bounded answer on a hold
# already closed outside this owner, and refuses any identity without surviving
# captain-hold provenance or any hold that is still open.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

DECISION_META_LOCK=
DECISION_META_LOCK_HELD=0
decision_hold_cleanup() {
  if [ "$DECISION_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$DECISION_META_LOCK" || true
    DECISION_META_LOCK_HELD=0
  fi
}
trap decision_hold_cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

ROUTED_NONE='(none)'
DECISION_TEXT=''
DECISION_DIGEST=''

load_decision() {  # <path>
  local path=$1
  [ -n "$path" ] || fail "--decision-file is required"
  [ -f "$path" ] || fail "decision file does not exist: $path"
  DECISION_TEXT=$(cat "$path")
  [ -n "$DECISION_TEXT" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$DECISION_TEXT" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  DECISION_DIGEST=$(sha256_text "$DECISION_TEXT")
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

# Reads one quoted `[markdown]` key from the active home's tasks-axi config.
# 0 prints the declared value, 1 means the key is absent, 2 means the declaration
# exists but is malformed.
configured_markdown_value() {  # <key>
  local key=$1 config="$FM_HOME/.tasks.toml" value rc=0
  [ -f "$config" ] || return 1
  value=$(awk -v pattern="^[[:space:]]*${key}[[:space:]]*=" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section = $0
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", section)
      next
    }
    section == "markdown" && $0 ~ pattern {
      value = $0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      quote = substr(value, 1, 1)
      if (quote != "\"" && quote != sprintf("%c", 39)) {
        invalid = 1
        exit
      }
      value = substr(value, 2)
      closing = index(value, quote)
      if (closing == 0) {
        invalid = 1
        exit
      }
      rest = trim(substr(value, closing + 1))
      if (rest != "" && substr(rest, 1, 1) != "#") {
        invalid = 1
        exit
      }
      print substr(value, 1, closing - 1)
      found = 1
      exit
    }
    END {
      if (invalid) exit 2
      if (!found) exit 1
    }
  ' "$config") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$value" ] || return 2
  printf '%s\n' "$value"
}

home_relative_path() {  # <path>
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$FM_HOME" "$1" ;;
  esac
}

# Resolves the file tasks-axi retention writes resolved items to. When
# `[markdown].archive` is absent this reproduces tasks-axi's own default:
# `done-archive.md` beside the configured backlog path, which itself defaults to
# `backlog.md` in the home. 0 prints the path, 2 means the declaration is malformed.
configured_archive_path() {
  local archive='' path='' rc=0 dir
  archive=$(configured_markdown_value archive) || rc=$?
  case "$rc" in
    0) home_relative_path "$archive"; return 0 ;;
    2) return 2 ;;
  esac
  rc=0
  path=$(configured_markdown_value path) || rc=$?
  case "$rc" in
    2) return 2 ;;
    1) path=backlog.md ;;
  esac
  case "$path" in
    */*) dir=${path%/*} ;;
    *) dir='.' ;;
  esac
  case "$dir" in
    .) home_relative_path done-archive.md ;;
    *) home_relative_path "$dir/done-archive.md" ;;
  esac
}

ARCHIVED_SHOW=''
ARCHIVED_ARCHIVE=''

# Scans every archived record sharing <id> and keeps the strongest one, so an older
# weaker record cannot shadow a later durable resolution. Record boundaries come
# from the tasks-axi markdown item grammar; every field still comes from tasks-axi
# itself, one isolated record at a time. An archive that holds content but no
# recognizable item is an unreadable archive, not an empty one.
# 0 sets ARCHIVED_SHOW to the strongest record, 1 means the archive holds no record
# for <id>, 2 means the archive declaration is malformed, 3 means the archive could
# not be inspected, 4 means its item grammar was not recognized, either because no
# item was found at all or because no record carrying <id> could be read back.
archived_task_show() {  # <id>
  local id=$1 archive='' rc=0 scratch records parsed items count content field index record output resolved=0
  ARCHIVED_SHOW=''
  ARCHIVED_ARCHIVE=''
  archive=$(configured_archive_path) || rc=$?
  [ "$rc" -eq 0 ] || return 2
  ARCHIVED_ARCHIVE=$archive
  [ -e "$archive" ] || return 1
  [ -r "$archive" ] || return 3
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-decision-archive.XXXXXX") || return 3
  records="$scratch/records"
  if ! mkdir "$records" \
    || ! printf 'backend = "markdown"\n\n[markdown]\narchive = "unused-archive.md"\n' > "$scratch/.tasks.toml"; then
    rm -rf "$scratch"
    return 3
  fi
  rc=0
  parsed=$(awk -v id="$id" -v out="$records" '
    /[^[:space:]]/ { content = 1 }
    /^- \[/ {
      if (file != "") close(file)
      items++
      line = $0
      sub(/^- \[[^]]*\][[:space:]]*/, "", line)
      split(line, parts, /[[:space:]]/)
      file = ""
      if (parts[1] == id) {
        n++
        file = sprintf("%s/record-%06d.md", out, n)
        printf "## Done\n" > file
        print > file
      }
      next
    }
    /^#/ {
      if (file != "") close(file)
      file = ""
      next
    }
    file != "" { print > file }
    END { printf "%d %d %d\n", items + 0, n + 0, content + 0 }
  ' "$archive") || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf "$scratch"
    return 3
  fi
  read -r items count content <<EOF
$parsed
EOF
  for field in "$items" "$count" "$content"; do
    case "$field" in
      ''|*[!0-9]*) rm -rf "$scratch"; return 3 ;;
    esac
  done
  if [ "$content" -ne 0 ] && [ "$items" -eq 0 ]; then
    rm -rf "$scratch"
    return 4
  fi
  index=1
  while [ "$index" -le "$count" ]; do
    record=$(printf '%s/record-%06d.md' "$records" "$index")
    rc=0
    output=$(cd "$scratch" && tasks-axi show "$id" --full --file "$record" 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
      if show_is_resolved "$output"; then
        ARCHIVED_SHOW=$output
        resolved=1
      elif [ "$resolved" = 0 ]; then
        ARCHIVED_SHOW=$output
      fi
    fi
    index=$((index + 1))
  done
  rm -rf "$scratch"
  if [ -z "$ARCHIVED_SHOW" ]; then
    [ "$count" -eq 0 ] || return 4
    return 1
  fi
}

fail_archive_unavailable() {  # <archive-status> <hold-id>
  local status=$1 id=$2
  case "$status" in
    2) fail "the tasks-axi [markdown] archive declaration in $FM_HOME/.tasks.toml is malformed, so captain decision $id could not be verified" ;;
    3) fail "the configured tasks-axi archive could not be inspected, so captain decision $id could not be verified" ;;
    4) fail "the configured tasks-axi archive $ARCHIVED_ARCHIVE holds content but no recognizable tasks-axi item, so captain decision $id could not be verified" ;;
  esac
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

# The single durable-resolution contract. Live and archived records are held to it
# identically.
show_is_resolved() {  # <show-output>
  local output=$1
  [ "$(show_field "$output" state)" = "done" ] || return 1
  [ "$(show_field "$output" kind)" = captain ] || return 1
  case "$(show_field "$output" body)" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

show_is_active_hold() {  # <show-output>
  local output=$1
  [ "$(show_field "$output" state)" = queued ] || return 1
  [ "$(show_field "$output" held)" = yes ] || return 1
  [ "$(show_field "$output" kind)" = captain ] || return 1
  [ "$(show_field "$output" hold_kind)" = captain ] || return 1
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

resolution_body() {  # <mode> <routed-csv> [routed-task-id...]
  local mode=$1 routed_csv=$2 body dep
  shift 2
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\nResolution mode: %s\n\nCaptain decision:\n%s\n\nRouted work:' \
    "$DECISION_DIGEST" "$routed_csv" "$mode" "$DECISION_TEXT")
  body="${body}"$'\n'
  if [ "$#" -eq 0 ]; then
    body="${body}${ROUTED_NONE}"$'\n'
  else
    for dep in "$@"; do body="${body}- ${dep}"$'\n'; done
  fi
  printf '%s' "$body"
}

normalized_blocked_by() {  # <show-output>
  local blocked
  blocked=$(show_field "$1" blocked_by | tr -d '[:space:]')
  blocked=${blocked#\"}
  blocked=${blocked%\"}
  printf '%s' "$blocked"
}

tasks_blocked_by() {  # <hold-id>
  local id=$1 rows row candidate show found=''
  rows=$(tasks_axi list --fields blocked_by) \
    || fail "could not read backlog work while checking what $id still blocks"
  while IFS= read -r row; do
    case "$row" in *"$id"*) ;; *) continue ;; esac
    candidate=${row%%,*}; candidate=${candidate// /}
    case "$candidate" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    [ "$candidate" != "$id" ] || continue
    show=$(task_show "$candidate") || continue
    list_has_key "$(normalized_blocked_by "$show")" "$id" || continue
    found="${found}${found:+ }$candidate"
  done <<EOF
$rows
EOF
  printf '%s' "$found"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show
  show=$(task_show "$id") || return 1
  show_is_resolved "$show"
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show='' rc=0 live_found=0 archive_found=0
  if show=$(task_show "$id"); then
    live_found=1
    show_is_active_hold "$show" && return 0
    show_is_resolved "$show" && return 0
  fi
  archived_task_show "$id" || rc=$?
  fail_archive_unavailable "$rc" "$id"
  if [ "$rc" -eq 0 ]; then
    archive_found=1
    show_is_resolved "$ARCHIVED_SHOW" && return 0
  fi
  if [ "$live_found" = 0 ] && [ "$archive_found" = 0 ]; then
    fail "captain decision $id is absent from the live backlog and configured archive"
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body rc
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    # Retention moves a closed decision out of the live backlog, so a live miss is
    # not proof that this identity is free.
    rc=0
    archived_task_show "$id" || rc=$?
    fail_archive_unavailable "$rc" "$id"
    if [ "$rc" -eq 0 ]; then
      show_is_resolved "$ARCHIVED_SHOW" \
        && fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
      fail "captain decision $id is already closed in the configured archive; use a new decision key for a new decision"
    fi
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0 transfer_rc
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  if [ "$has_meta" = 1 ]; then
    DECISION_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    fm_lock_acquire_wait "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=1
    [ -f "$meta" ] || fail "task metadata disappeared while recording completion"
  fi
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi
    fm_lock_release "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=0

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      transfer_rc=0
      fm_wake_status_append_self_announced "$STATE" "$status_file" \
        "captain-held [key=$key]: tracked by $(hold_id "$origin" "$key")" || transfer_rc=$?
      [ "$transfer_rc" -ne 2 ] || fail "cannot append the captain-held transfer for $origin/$key"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  load_decision "$decision_file"
  [ -n "$routed" ] || fail "at least one --routed-to task is required; use decline when the captain's answer routes no work"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$DECISION_DIGEST" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(normalized_blocked_by "$show")
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  # shellcheck disable=SC2086 # routed is a validated slug list.
  body=$(resolution_body routed "$routed_csv" $routed)
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(normalized_blocked_by "$show")
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

parse_decision_only_flags() {  # <args...>
  local decision_file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  printf '%s' "$decision_file"
}

command_decline() {
  local origin=${1:-} key=${2:-} decision_file id body show state dependents
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  decision_file=$(parse_decision_only_flags "$@") || exit 2
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  load_decision "$decision_file"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    show=$(task_show "$id")
    verify_resolution_identity "$id" "$(show_field "$show" body)" "$DECISION_DIGEST" "$ROUTED_NONE"
    printf 'declined: %s\n' "$id"
    return 0
  fi
  show=$(task_show "$id") || fail "captain hold $id is absent from the live backlog"
  state=$(show_field "$show" state)
  [ "$state" != "done" ] \
    || fail "captain hold $id was closed outside fm-decision-hold; use repair to record the captain decision"
  verify_hold_active "$id"
  dependents=$(tasks_blocked_by "$id")
  [ -z "$dependents" ] \
    || fail "captain hold $id still blocks routed work ($dependents); use resolve to record that work"
  body=$(resolution_body declined "$ROUTED_NONE")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  tasks_axi "done" "$id" >/dev/null || fail "could not close declined captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'declined: %s\n' "$id"
}

command_repair() {
  local origin=${1:-} key=${2:-} decision_file id body show state kind hold_kind
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  decision_file=$(parse_decision_only_flags "$@") || exit 2
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  load_decision "$decision_file"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  show=$(task_show "$id") || fail "captain decision $id is absent from the live backlog"
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] \
    || fail "backlog item $id was never held for the captain; repair records only a bounded captain hold"
  state=$(show_field "$show" state)
  if [ "$state" = "done" ] && show_is_resolved "$show"; then
    verify_resolution_identity "$id" "$(show_field "$show" body)" "$DECISION_DIGEST" "$ROUTED_NONE"
    printf 'repaired: %s\n' "$id"
    return 0
  fi
  [ "$state" = "done" ] \
    || fail "captain hold $id is still open (state=$state); use resolve or decline to close it"
  body=$(resolution_body repaired "$ROUTED_NONE")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  show=$(task_show "$id") || fail "captain decision $id disappeared while recording the repair"
  [ "$(show_field "$show" state)" = "done" ] || fail "repairing $id reopened a closed captain decision"
  show_is_resolved "$show" || fail "captain hold $id did not retain its durable resolution record"
  printf 'repaired: %s\n' "$id"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  decline) shift; command_decline "$@" ;;
  repair) shift; command_repair "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
