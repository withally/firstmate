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
  local state=$1 worktree=$2 excluded=${3:-} excluded_journal=${4:-} physical owner_meta owner_wt owner_real
  local excluded_recovery excluded_publication excluded_primary
  physical=$(cd "$worktree" && pwd -P) || return 1
  excluded_recovery=
  excluded_publication=
  excluded_primary=
  case "$excluded" in
    *.meta)
      excluded_recovery="$excluded.recovery"
      excluded_publication="$excluded.publication"
      ;;
    *.meta.recovery)
      excluded_primary=${excluded%.recovery}
      excluded_publication="$excluded_primary.publication"
      ;;
    *.meta.publication)
      excluded_primary=${excluded%.publication}
      excluded_recovery="$excluded_primary.recovery"
      ;;
  esac
  for owner_meta in "$state"/*.lease-acquisition; do
    [ "$owner_meta" != "$excluded_journal" ] || continue
    [ -e "$owner_meta" ] || [ -L "$owner_meta" ] || continue
    [ -f "$owner_meta" ] && [ ! -L "$owner_meta" ] || return 1
    owner_wt=$(jq -er '.path | select(type == "string" and length > 0)' "$owner_meta") || {
      echo "error: unresolved acquisition intent $owner_meta; reconcile before allocating" >&2; return 1;
    }
    owner_real=$(cd "$owner_wt" 2>/dev/null && pwd -P) || owner_real=$owner_wt
    if [ "$owner_real" = "$physical" ]; then
      echo "error: worktree $worktree is already recorded by $owner_meta" >&2; return 1
    fi
  done
  for owner_meta in "$state"/*.meta "$state"/*.meta.recovery "$state"/*.meta.publication "$state"/*.retiring; do
    [ "$owner_meta" != "$excluded" ] || continue
    [ "$owner_meta" != "$excluded_recovery" ] || continue
    [ "$owner_meta" != "$excluded_publication" ] || continue
    [ "$owner_meta" != "$excluded_primary" ] || continue
    [ -e "$owner_meta" ] || [ -L "$owner_meta" ] || continue
    if [ ! -f "$owner_meta" ] || [ -L "$owner_meta" ]; then
      echo "error: cannot establish worktree ownership from $owner_meta" >&2
      return 1
    fi
    owner_wt=$(fm_meta_get "$owner_meta" worktree)
    [ -n "$owner_wt" ] || {
      echo "error: unresolved task ownership record $owner_meta has no worktree; reconcile before allocating" >&2
      return 1
    }
    owner_real=$(cd "$owner_wt" 2>/dev/null && pwd -P) || owner_real=$owner_wt
    if [ "$owner_real" = "$physical" ]; then
      echo "error: worktree $worktree is already recorded by $owner_meta; refusing duplicate lease" >&2
      return 1
    fi
  done
}

# Acquisition intent is published before calling the provider. Its unique holder
# lets a retry recover an allocation even when get returned no usable response.
# A bound receipt never adopts a different lease. Ambiguous or unlanded work keeps
# the receipt, and therefore ownership, until a later safe reconciliation.
fm_treehouse_acquisition_reconcile() { # <state> <id> <project>
  local state=$1 id=$2 project=$3 journal listing holder receipt old_id wt lease tmp dirty unlanded
  journal="$state/$id.lease-acquisition"
  [ -e "$journal" ] || [ -L "$journal" ] || return 0
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  holder=$(jq -er --arg project "$project" --arg prefix "$state/$id:" '
    select(.schema == "fm-lease-acquisition.v1" and .project == $project)
    | .lease_holder | select(type == "string" and startswith($prefix) and length > ($prefix|length))' "$journal") || return 1
  listing=$(cd "$project" && treehouse status --json) || return 1
  receipt=$(printf '%s' "$listing" | jq -ce --arg holder "$holder" '
    if type != "array" then error("invalid pool") else
    [.[] | select(.status == "leased" and .lease_holder == $holder)]
    | if length > 1 then error("ambiguous holder") else . end end') || return 1
  if [ "$(printf '%s' "$receipt" | jq length)" = 0 ]; then
    rm -f "$journal"
    return
  fi
  wt=$(printf '%s' "$receipt" | jq -er '.[0].path | select(type == "string" and startswith("/"))') || return 1
  lease=$(printf '%s' "$receipt" | jq -er '.[0].lease_id | select(type == "string" and length > 0)') || return 1
  old_id=$(jq -r '.lease_id // empty' "$journal") || return 1
  [ -z "$old_id" ] || [ "$old_id" = "$lease" ] || return 1
  tmp=$(mktemp "$state/.lease-receipt.XXXXXX") || return 1
  if ! jq --arg path "$wt" --arg lease "$lease" '.path=$path | .lease_id=$lease' "$journal" > "$tmp" \
    || ! mv -f "$tmp" "$journal"; then
    rm -f "$tmp"; return 1
  fi
  fm_treehouse_worktree_unowned "$state" "$wt" "" "$journal" || return 1
  [ "$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" = "$wt" ] || return 1
  [ "$(cd "$project" && pwd -P)" != "$wt" ] || return 1
  dirty=$(git -C "$wt" status --porcelain --untracked-files=all --ignored) || return 1
  [ -z "$dirty" ] || return 1
  git -C "$wt" fetch --all --quiet || return 1
  unlanded=$(git -C "$wt" rev-list HEAD --not --remotes) || return 1
  [ -z "$unlanded" ] || return 1
  fm_treehouse_lease_return "$project" "$wt" "$lease" "$holder" || return 1
  rm -f "$journal"
}
