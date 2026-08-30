#!/usr/bin/env bash
# Resolve and enforce a task's recorded merge_authority= tier at a landing gate.
# Legacy metadata maps yolo=on to self and yolo=off/absent to captain.
#
# firstmate authority is meaningful only inside a locally routed secondmate
# home. Its approval record is the existing parent-channel keyed resolution
# written when the main firstmate answers the secondmate through:
#   bin/fm-send.sh <secondmate-id> --resolve-key before-landing-<task-id> ...
# The latest event for that exact key must be resolved. No new approval file or
# transport exists; the established status/fm-send decision contract is reused.

_FM_MERGE_AUTHORITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_MERGE_AUTHORITY_LIB_DIR="."
FM_MERGE_AUTHORITY_SCRIPT_DIR="${FM_MERGE_AUTHORITY_SCRIPT_DIR:-$_FM_MERGE_AUTHORITY_LIB_DIR}"
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-classify-lib.sh"
if ! type fm_merge_outcome_home_id >/dev/null 2>&1; then
  # shellcheck source=bin/fm-merge-outcome-lib.sh
  . "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-merge-outcome-lib.sh"
fi

fm_merge_authority_meta_get() {  # <meta> <key>
  awk -F= -v key="$2" '$1 == key { value=substr($0, index($0, "=") + 1) } END { print value }' "$1"
}

fm_merge_authority_resolve() {  # <meta>
  local meta=$1 authority yolo
  authority=$(fm_merge_authority_meta_get "$meta" merge_authority)
  if [ -z "$authority" ]; then
    yolo=$(fm_merge_authority_meta_get "$meta" yolo)
    if [ "$yolo" = on ]; then authority=self; else authority=captain; fi
  fi
  case "$authority" in captain|firstmate|self) printf '%s\n' "$authority" ;; *) return 1 ;; esac
}

fm_merge_authority_key_is_resolved() {  # <status-file> <key>
  local status=$1 key=$2 resolve
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  [ "$(status_key_closing_verb "$status" "$key")" = "$resolve" ]
}

fm_merge_authority_require_landing() {  # <home> <task-id> <meta>
  local home=$1 id=$2 meta=$3 authority mate parent_record parent_status key
  authority=$(fm_merge_authority_resolve "$meta") || {
    echo "error: task $id has an invalid merge_authority record" >&2
    return 1
  }
  FM_MERGE_AUTHORITY=$authority
  [ "$authority" = firstmate ] || return 0

  if ! mate=$(fm_merge_outcome_home_id "$home"); then
    echo "error: task $id requires parent-firstmate approval, but this home has no valid secondmate identity" >&2
    return 1
  fi
  parent_record="$home/.fm-secondmate-parent"
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "${FM_MERGE_AUTHORITY_SCRIPT_DIR:?}/fm-secondmate-parent-lib.sh"
  fm_secondmate_parent_record_parse "$parent_record" || {
    echo "error: task $id requires parent-firstmate approval, but its parent binding is unavailable" >&2
    return 1
  }
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || {
    echo "error: task $id requires a parent-firstmate approval record, but route=remote has no supported approval-record transport" >&2
    return 1
  }
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "${FM_MERGE_AUTHORITY_SCRIPT_DIR:?}/fm-secondmate-registry-lib.sh"
  secondmate_registry_validate_bindings \
    "$FM_SECONDMATE_PARENT_HOME/data/secondmates.md" \
    secondmate_registry_path_key "$mate" "$home" || {
    echo "error: task $id requires parent-firstmate approval, but the claimed parent does not register this secondmate home" >&2
    return 1
  }
  [ "$SECONDMATE_REGISTRY_MATCH_REMOTE" -eq 0 ] || {
    echo "error: task $id requires parent-firstmate approval, but the parent registry route is not local" >&2
    return 1
  }
  parent_status="$FM_SECONDMATE_PARENT_HOME/state/$mate.status"
  [ -f "$parent_status" ] && [ ! -L "$parent_status" ] || {
    echo "error: parent-firstmate approval is not resolved for task $id (missing parent status)" >&2
    return 1
  }
  key="before-landing-$id"
  fm_merge_authority_key_is_resolved "$parent_status" "$key" || {
    echo "error: parent-firstmate approval is not resolved for task $id; ask with needs-decision [key=$key] and have the parent answer through fm-send --resolve-key $key" >&2
    return 1
  }
}

fm_merge_authority_github_green() {  # <owner/repo> <number>
  local repo=$1 number=$2 checks
  checks=$(gh-axi pr checks "$number" -R "$repo" 2>/dev/null) || {
    echo "error: GitHub PR checks are not readable; refusing before merge" >&2
    return 1
  }
  printf '%s\n' "$checks" | awk '
    function is_uint(value) { return value ~ /^[0-9]+$/ }
    /^summary: "/ {
      if (seen_summary++) { invalid=1; next }
      line=$0
      sub(/^summary: "/, "", line)
      sub(/"$/, "", line)
      n=split(line, a, " ")
      if (n == 6 && a[2] == "passed," && a[4] == "failed," && a[6] == "total" &&
          is_uint(a[1]) && is_uint(a[3]) && is_uint(a[5])) {
        passed=a[1]+0
        failed=a[3]+0
        pending=0
        total=a[5]+0
      } else if (n == 8 && a[2] == "passed," && a[4] == "failed," &&
                 a[6] == "pending," && a[8] == "total" &&
                 is_uint(a[1]) && is_uint(a[3]) && is_uint(a[5]) && is_uint(a[7])) {
        passed=a[1]+0
        failed=a[3]+0
        pending=a[5]+0
        total=a[7]+0
      } else {
        invalid=1
      }
      next
    }
    /^checks\[[0-9][0-9]*\]\{name,conclusion\}:$/ {
      if (seen_checks++) { invalid=1; next }
      header=$0
      sub(/^checks\[/, "", header)
      sub(/\].*$/, "", header)
      if (is_uint(header)) expected=header+0; else invalid=1
      in_checks=1
      next
    }
    in_checks {
      if ($0 !~ /^  .+$/) { invalid=1; next }
      line=$0
      sub(/^  /, "", line)
      comma=0
      for (i=1; i<=length(line); i++) {
        if (substr(line, i, 1) == ",") comma=i
      }
      if (comma <= 1 || comma >= length(line)) { invalid=1; next }
      name=substr(line, 1, comma - 1)
      conclusion=substr(line, comma + 1)
      if (name == "" || conclusion != "pass") invalid=1
      rows++
    }
    END {
      if (!seen_summary || !seen_checks || invalid || expected != rows || total != expected) exit 1
      if (passed + failed + pending != total || failed != 0 || pending != 0 || passed != total) exit 1
      exit 0
    }
  ' || {
    echo "error: GitHub PR checks are not green; refusing before merge" >&2
    return 1
  }
}
