#!/usr/bin/env bash
# Identity-checked treehouse lease operations shared by spawn and teardown.
# A lease is the exact project, physical worktree path, id, and holder tuple.
# Legacy records without a lease tuple are handled by their caller; a partial
# tuple is never accepted. treehouse v2.1.1 or newer supplies these interfaces.
fm_treehouse_lease_verify() { # <project> <worktree> <lease-id> <holder>
  local project=$1 worktree=$2 lease_id=$3 holder=$4
  fm_treehouse_lease_status "$project" "$worktree" "$lease_id" "$holder" \
    && [ "$FM_TREEHOUSE_LEASE_STATUS" = held ]
}

fm_treehouse_lease_identity_from_pool() { # <project> <worktree> [holder]
  local project=$1 worktree=$2 expected_holder=${3:-} result
  [ -n "$project" ] && [ -n "$worktree" ] || return 1
  fm_treehouse_pool_listing "$project" || return 1
  result=$(printf '%s' "$FM_TREEHOUSE_POOL_LISTING" | jq -er \
    --arg path "$worktree" --arg expected "$expected_holder" '
      [.[] | select(.status == "leased" and .path == $path
        and ($expected == "" or .lease_holder == $expected))]
      | if length == 1 then .[0] | [.lease_id, .lease_holder] | @tsv else empty end') || return 1
  printf '%s\n' "$result"
}

fm_treehouse_lease_return() { # <project> <worktree> <lease-id> <holder>
  local project=$1 worktree=$2 lease_id=$3 holder=$4
  [ -n "$lease_id" ] && [ -n "$holder" ] || return 1
  (cd "$project" && treehouse return --force --if-lease-id "$lease_id" \
    --if-lease-holder "$holder" "$worktree")
}

fm_treehouse_lease_record_field() { # <record> <field>
  local record=$1 field=$2
  awk -v field="$field" '
    index($0, field "=") == 1 {
      count++
      value = substr($0, length(field) + 2)
    }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$record"
}

fm_treehouse_lease_receipt_read() { # <record> [project] [worktree] [lease-id] [holder]
  local record=$1 expected_project=${2:-} expected_worktree=${3:-}
  local expected_lease_id=${4:-} expected_holder=${5:-}
  local schema project worktree lease_id holder line
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*|project=*|worktree=*|treehouse_lease_id=*|treehouse_lease_holder=*) ;;
      *) return 1 ;;
    esac
  done < "$record" || return 1
  schema=$(fm_treehouse_lease_record_field "$record" schema) || return 1
  project=$(fm_treehouse_lease_record_field "$record" project) || return 1
  worktree=$(fm_treehouse_lease_record_field "$record" worktree) || return 1
  lease_id=$(fm_treehouse_lease_record_field "$record" treehouse_lease_id) || return 1
  holder=$(fm_treehouse_lease_record_field "$record" treehouse_lease_holder) || return 1
  [ "$schema" = fm-secondmate-treehouse-lease.v1 ] || return 1
  [ -n "$project" ] && [ -n "$lease_id" ] && [ -n "$holder" ] || return 1
  case "$worktree" in /*) ;; *) return 1 ;; esac
  [ -z "$expected_project" ] || [ "$project" = "$expected_project" ] || return 1
  [ -z "$expected_worktree" ] || [ "$worktree" = "$expected_worktree" ] || return 1
  [ -z "$expected_lease_id" ] || [ "$lease_id" = "$expected_lease_id" ] || return 1
  [ -z "$expected_holder" ] || [ "$holder" = "$expected_holder" ] || return 1
  # shellcheck disable=SC2034 # Public receipt outputs consumed by lifecycle callers.
  FM_TREEHOUSE_RECORD_PROJECT=$project
  # shellcheck disable=SC2034 # Public receipt outputs consumed by lifecycle callers.
  FM_TREEHOUSE_RECORD_WORKTREE=$worktree
  # shellcheck disable=SC2034 # Public receipt outputs consumed by lifecycle callers.
  FM_TREEHOUSE_RECORD_LEASE_ID=$lease_id
  # shellcheck disable=SC2034 # Public receipt outputs consumed by lifecycle callers.
  FM_TREEHOUSE_RECORD_HOLDER=$holder
}

fm_treehouse_pool_listing() { # <project>
  local project=$1
  FM_TREEHOUSE_POOL_LISTING=$(cd "$project" && treehouse status --json) || return 1
  printf '%s' "$FM_TREEHOUSE_POOL_LISTING" | jq -e '
    type == "array" and all(.[];
      type == "object" and
      (.path | type) == "string" and (.path | length) > 0 and
      (.status | type) == "string" and
      (.status != "leased" or
        ((.lease_id | type) == "string" and (.lease_id | length) > 0 and
         (.lease_holder | type) == "string" and (.lease_holder | length) > 0)))
  ' >/dev/null
}

# Absence of inline lease fields is not proof of an unpooled worktree.
# Even an available slot belongs to the provider and must never be raw-deleted.
fm_treehouse_worktree_unpooled() { # <project> <worktree>
  local project=$1 worktree=$2 path physical pool_physical
  [ -n "$project" ] && [ -n "$worktree" ] || return 1
  physical=$(cd "$worktree" && pwd -P) || return 1
  fm_treehouse_pool_listing "$project" || return 1
  while IFS= read -r path; do
    [ "$path" != "$worktree" ] && [ "$path" != "$physical" ] || return 1
    if [ -d "$path" ]; then
      pool_physical=$(cd "$path" && pwd -P) || return 1
      [ "$pool_physical" != "$physical" ] || return 1
    fi
  done < <(printf '%s' "$FM_TREEHOUSE_POOL_LISTING" | jq -r '.[].path')
}

fm_treehouse_lease_status() { # <project> <worktree> <lease-id> <holder>
  local project=$1 worktree=$2 lease_id=$3 holder=$4 result
  [ -n "$project" ] && [ -n "$worktree" ] && [ -n "$lease_id" ] && [ -n "$holder" ] || return 1
  fm_treehouse_pool_listing "$project" || return 1
  result=$(printf '%s' "$FM_TREEHOUSE_POOL_LISTING" | jq -er \
    --arg path "$worktree" --arg id "$lease_id" --arg holder "$holder" '
      ([.[] | select(.status == "leased" and .path == $path and .lease_id == $id and .lease_holder == $holder)] | length) as $full_count |
      ([.[] | select(.status == "leased" and .path == $path)] | length) as $path_count |
      ([.[] | select(.status == "leased" and .lease_id == $id)] | length) as $lease_count |
      ([.[] | select(.status == "leased" and .lease_holder == $holder)] | length) as $holder_count |
      if $full_count == 1 and $path_count == 1 and $lease_count == 1 and $holder_count == 1 then "held"
      elif $path_count == 0 and $lease_count == 0 and $holder_count == 0 then "released"
      else "conflict"
      end') || return 1
  FM_TREEHOUSE_LEASE_STATUS=$result
}

fm_treehouse_lease_holder_status() { # <project> <holder>
  local project=$1 holder=$2 result
  [ -n "$project" ] && [ -n "$holder" ] || return 1
  fm_treehouse_pool_listing "$project" || return 1
  result=$(printf '%s' "$FM_TREEHOUSE_POOL_LISTING" | jq -cer \
    --arg holder "$holder" '
      [.[] | select(.status == "leased" and .lease_holder == $holder)]
      | if length == 0 then {status:"released"}
        elif length == 1 then
          .[0] | {status:"held",path:.path,lease_id:.lease_id,holder:.lease_holder}
        else {status:"conflict"}
        end') || return 1
  FM_TREEHOUSE_HOLDER_STATUS=$(printf '%s' "$result" | jq -r '.status') || return 1
  FM_TREEHOUSE_HOLDER_WORKTREE=$(printf '%s' "$result" | jq -r '.path // empty') || return 1
  FM_TREEHOUSE_HOLDER_LEASE_ID=$(printf '%s' "$result" | jq -r '.lease_id // empty') || return 1
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
  local state=$1 id=$2 project=$3 journal holder old_id old_path wt lease tmp dirty unlanded
  journal="$state/$id.lease-acquisition"
  [ -e "$journal" ] || [ -L "$journal" ] || return 0
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  jq -e --arg project "$project" --arg prefix "$state/$id:" '
    .schema == "fm-lease-acquisition.v1" and
    (.project | type) == "string" and .project == $project and
    (.lease_holder | type) == "string" and (.lease_holder | startswith($prefix)) and
    ((.path // "") == "" or ((.path | type) == "string" and (.path | startswith("/")))) and
    ((.lease_id // "") == "" or ((.lease_id | type) == "string" and (.lease_id | length) > 0)) and
    ((.path // "") == "" or (.lease_id // "") != "") and
    ((.lease_id // "") == "" or (.path // "") != "")
  ' "$journal" >/dev/null || return 1
  holder=$(jq -er --arg project "$project" --arg prefix "$state/$id:" '
    select(.schema == "fm-lease-acquisition.v1" and .project == $project)
    | .lease_holder | select(type == "string" and startswith($prefix) and length > ($prefix|length))' "$journal") || return 1
  old_path=$(jq -r '.path // empty' "$journal") || return 1
  old_id=$(jq -r '.lease_id // empty' "$journal") || return 1
  if [ -n "$old_path" ] || [ -n "$old_id" ]; then
    [ -n "$old_path" ] && [ -n "$old_id" ] || return 1
    case "$old_path" in /*) ;; *) return 1 ;; esac
    fm_treehouse_lease_status "$project" "$old_path" "$old_id" "$holder" || return 1
    case "$FM_TREEHOUSE_LEASE_STATUS" in
      released) rm -f "$journal"; return 0 ;;
      conflict) return 1 ;;
    esac
    wt=$old_path
    lease=$old_id
  else
    fm_treehouse_lease_holder_status "$project" "$holder" || return 1
    case "$FM_TREEHOUSE_HOLDER_STATUS" in
      released) rm -f "$journal"; return 0 ;;
      conflict) return 1 ;;
    esac
    wt=$FM_TREEHOUSE_HOLDER_WORKTREE
    lease=$FM_TREEHOUSE_HOLDER_LEASE_ID
    case "$wt" in /*) ;; *) return 1 ;; esac
    [ -n "$lease" ] || return 1
    tmp=$(mktemp "$state/.lease-receipt.XXXXXX") || return 1
    if ! jq --arg path "$wt" --arg lease "$lease" '.path=$path | .lease_id=$lease' "$journal" > "$tmp" \
      || ! mv -f "$tmp" "$journal"; then
      rm -f "$tmp"; return 1
    fi
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
