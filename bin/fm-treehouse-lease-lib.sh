#!/usr/bin/env bash
# Identity-checked treehouse lease operations shared by spawn and teardown.
# A lease is the exact project, physical worktree path, id, and holder tuple.
# Legacy records without a lease tuple are handled by their caller; a partial
# tuple is never accepted. treehouse v2.1.1 or newer supplies these interfaces.
fm_treehouse_lease_verify() { # <project> <worktree> <lease-id> <holder>
  local project=$1 worktree=$2 lease_id=$3 holder=$4 listing
  [ -n "$lease_id" ] && [ -n "$holder" ] || return 1
  listing=$(cd "$project" && treehouse status --json) || return 1
  printf '%s' "$listing" | jq -e --arg path "$worktree" \
    --arg id "$lease_id" --arg holder "$holder" \
    '[.[] | select(.path == $path)] | length == 1 and
      (.[0] | .status == "leased" and .lease_id == $id and .lease_holder == $holder)' >/dev/null
}

fm_treehouse_lease_identity_from_pool() { # <project> <worktree> [holder]
  local project=$1 worktree=$2 expected_holder=${3:-} listing
  [ -n "$project" ] && [ -n "$worktree" ] || return 1
  listing=$(cd "$project" && treehouse status --json) || return 1
  printf '%s' "$listing" | jq -er --arg path "$worktree" --arg expected "$expected_holder" '
    [ .[] | select(.path == $path
      and .status == "leased"
      and (.lease_id | type) == "string" and (.lease_id | length) > 0
      and (.lease_holder | type) == "string" and (.lease_holder | length) > 0
      and ($expected == "" or .lease_holder == $expected)) ]
    | if length == 1 then .[0] | [.lease_id, .lease_holder] | @tsv else empty end'
}

fm_treehouse_lease_return() { # <project> <worktree> <lease-id> <holder>
  local project=$1 worktree=$2 lease_id=$3 holder=$4
  [ -n "$lease_id" ] && [ -n "$holder" ] || return 1
  (cd "$project" && treehouse return --force --if-lease-id "$lease_id" \
    --if-lease-holder "$holder" "$worktree")
}

fm_treehouse_worktree_unowned() { # <state> <worktree> [excluded-meta]
  local state=$1 worktree=$2 excluded=${3:-} physical owner_meta owner_wt owner_real
  local excluded_recovery excluded_primary
  physical=$(cd "$worktree" && pwd -P) || return 1
  excluded_recovery=
  excluded_primary=
  case "$excluded" in
    *.meta) excluded_recovery="$excluded.recovery" ;;
    *.meta.recovery) excluded_primary=${excluded%.recovery} ;;
  esac
  for owner_meta in "$state"/*.meta "$state"/*.meta.recovery; do
    [ "$owner_meta" != "$excluded" ] || continue
    [ "$owner_meta" != "$excluded_recovery" ] || continue
    [ "$owner_meta" != "$excluded_primary" ] || continue
    [ -e "$owner_meta" ] || [ -L "$owner_meta" ] || continue
    if [ ! -f "$owner_meta" ] || [ -L "$owner_meta" ]; then
      echo "error: cannot establish worktree ownership from $owner_meta" >&2
      return 1
    fi
    owner_wt=$(fm_meta_get "$owner_meta" worktree)
    [ -n "$owner_wt" ] || continue
    owner_real=$(cd "$owner_wt" 2>/dev/null && pwd -P) || owner_real=$owner_wt
    if [ "$owner_real" = "$physical" ]; then
      echo "error: worktree $worktree is already recorded by $owner_meta; refusing duplicate lease" >&2
      return 1
    fi
  done
}
