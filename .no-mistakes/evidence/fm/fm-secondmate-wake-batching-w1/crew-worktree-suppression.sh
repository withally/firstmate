#!/usr/bin/env bash
# End-user check: a Firstmate session opened from a REGISTERED crew worktree of a
# repository must print exactly one line instead of the primary digest.
set -u
TREE=${1:?usage: crew-worktree-suppression.sh <tree-root>}
T=$(mktemp -d /tmp/fm-crew.XXXXXX)
git init -q "$T/primary"; git -C "$T/primary" commit -q --allow-empty -m init
mkdir -p "$T/primary/state" "$T/home/state" "$T/home/config"
git -C "$T/primary" worktree add -q "$T/wt-task1" -b task1
printf 'worktree=%s\n' "$T/wt-task1" > "$T/primary/state/task1.meta"
echo "--- registered crew worktree ---"
FM_HOME="$T/home" FM_STATE_OVERRIDE="$T/home/state" FM_CONFIG_OVERRIDE="$T/home/config" \
  FM_ROOT_OVERRIDE="$T/wt-task1" timeout 60 "$TREE/bin/fm-session-start.sh" 2>&1 | head -20
echo "--- unregistered worktree (no state/*.meta pointing at it): digest still runs ---"
git -C "$T/primary" worktree add -q "$T/wt-other" -b other
FM_HOME="$T/home" FM_STATE_OVERRIDE="$T/home/state" FM_CONFIG_OVERRIDE="$T/home/config" \
  FM_ROOT_OVERRIDE="$T/wt-other" timeout 60 "$TREE/bin/fm-session-start.sh" 2>&1 | head -8
rm -rf "$T"
