#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 only when <root> is a linked worktree registered as a live crew task
# in the primary checkout that owns its git common directory.
fm_root_is_registered_crew_worktree() {  # <root>
  local root=$1 git_dir git_common primary meta recorded resolved_root
  fm_root_is_secondmate_home "$root" && return 1
  git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
  git_common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" != "$git_common" ] || return 1
  case "$git_common" in
    /*) ;;
    *) git_common=$(cd "$root" && cd "$git_common" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  case "$git_common" in */.git) primary=${git_common%/.git} ;; *) return 1 ;; esac
  resolved_root=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  for meta in "$primary"/state/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    recorded=$(awk -F= '$1 == "worktree" { sub(/^[^=]*=/, ""); print; exit }' "$meta" 2>/dev/null) || continue
    [ -n "$recorded" ] || continue
    [ -d "$recorded" ] || continue
    recorded=$(cd "$recorded" 2>/dev/null && pwd -P) || continue
    [ "$recorded" = "$resolved_root" ] && return 0
  done
  return 1
}

fm_print_crew_worktree_suppression() {
  printf '%s\n' 'crew worktree - digest suppressed'
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}
