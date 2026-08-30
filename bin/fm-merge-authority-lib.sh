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
  awk -v key="$2" '
    index($0, "[key=" key "]") {
      verb=$1
      sub(/:.*/, "", verb)
      if (verb == "needs-decision" || verb == "blocked") state="open"
      else if (verb == "resolved") state="resolved"
    }
    END { exit state == "resolved" ? 0 : 1 }
  ' "$1"
}

fm_merge_authority_require_landing() {  # <home> <task-id> <meta>
  local home=$1 id=$2 meta=$3 authority mate parent_record parent_status key
  authority=$(fm_merge_authority_resolve "$meta") || {
    echo "error: task $id has an invalid merge_authority record" >&2
    return 1
  }
  FM_MERGE_AUTHORITY=$authority
  [ "$authority" = firstmate ] || return 0

  mate=$(sed -n '1p' "$home/.fm-secondmate-home" 2>/dev/null || true)
  case "$mate" in ''|*[!A-Za-z0-9._-]*)
    echo "error: task $id requires parent-firstmate approval, but this home has no valid secondmate identity" >&2
    return 1 ;;
  esac
  parent_record="$home/.fm-secondmate-parent"
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "${FM_MERGE_AUTHORITY_SCRIPT_DIR:?}/fm-secondmate-parent-lib.sh"
  fm_secondmate_parent_record_parse "$parent_record" || {
    echo "error: task $id requires parent-firstmate approval, but its parent binding is unavailable" >&2
    return 1
  }
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || {
    echo "error: task $id requires a parent-firstmate approval record, but the parent route is not locally readable" >&2
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
    echo "error: firstmate-authority PR checks are not readable; refusing before merge" >&2
    return 1
  }
  printf '%s\n' "$checks" | awk '
    /^summary: "/ {
      line=$0
      sub(/^summary: "/, "", line)
      sub(/"$/, "", line)
      n=split(line, a, " ")
      if (n == 6 && a[2] == "passed," && a[4] == "failed," && a[6] == "total") {
        passed=a[1]+0; failed=a[3]+0; total=a[5]+0; seen=1
      }
    }
    END { exit seen && failed == 0 && passed == total ? 0 : 1 }
  ' || {
    echo "error: firstmate-authority PR checks are not green; refusing before merge" >&2
    return 1
  }
}
