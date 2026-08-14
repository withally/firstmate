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

# Echo $1's checkout shape: 'plain' when its git-dir is the common dir,
# 'linked' for a linked worktree, and nothing when git cannot answer for the
# path. This comparison is how the fleet distinguishes a plain checkout from
# a linked task worktree; every consumer reuses it from here.
fm_root_worktree_kind() {  # <root> -> plain|linked|''
  local git_dir git_common_dir
  git_dir=$(git -C "$1" rev-parse --git-dir 2>/dev/null) || return 0
  git_common_dir=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 0
  if [ "$git_dir" = "$git_common_dir" ]; then printf 'plain'; else printf 'linked'; fi
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2
  if ! fm_root_is_secondmate_home "$root"; then
    [ "$(fm_root_worktree_kind "$root")" = plain ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}
