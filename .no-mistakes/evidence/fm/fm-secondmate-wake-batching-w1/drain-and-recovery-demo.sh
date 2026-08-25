#!/usr/bin/env bash
# What a Firstmate primary actually sees at the wake drain and after a compaction.
# Runs the real bin/fm-wake-drain.sh and bin/fm-session-start.sh against a throwaway FM_HOME.
set -u
W=${1:?usage: drain-and-recovery-demo.sh <worktree-root>}
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-drain-demo.XXXXXX")
home="$T/home"; mkdir -p "$home/state" "$home/config"
export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config"
printf 'needs-decision [key=api-shape]: pick REST or RPC before the crew continues\n' > "$home/state/task-api.status"
printf 'window=fleet:crew-api\nkind=ship\nharness=claude\nbackend=tmux\n' > "$home/state/task-api.meta"
printf 'window=fleet:crew-db\nkind=ship\nharness=codex\nbackend=tmux\n' > "$home/state/task-db.meta"
printf 'working: migrating schema\n' > "$home/state/task-db.status"

ack() {  # <stderr-file>
  local seq gen
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$1")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$1")
  [ -z "$seq" ] || "$W/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 || true
}

queue() {  # <key> <payload>
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append stale "$2" "$3"' _ "$W/bin/fm-wake-lib.sh" "$1" "$2"
}

echo "================================================================"
echo "1. First wake drain of the session - the open decision is presented in full"
echo "================================================================"
queue paused-fleet 'stale: paused fleet recheck (3 due): fleet:crew-api (paused 512s, awaiting external); fleet:crew-db (paused 512s, awaiting external); fleet:crew-web (paused 513s, awaiting external)'
"$W/bin/fm-wake-drain.sh" 2> "$T/e1" | grep -v '^●' || true
ack "$T/e1"
echo
echo "================================================================"
echo "2. Next wake drain in the SAME session, decision set unchanged - the block collapses to a marker"
echo "================================================================"
queue w1 'stale: fleet:crew-db'
"$W/bin/fm-wake-drain.sh" 2> "$T/e2" | grep -v '^●' || true
ack "$T/e2"
echo
echo "================================================================"
echo "3. After a compaction: fm-session-start.sh --compact re-presents the decisions in full,"
echo "   with no status tails or unchanged context files, and carries its own acknowledgement command"
echo "================================================================"
queue w2 'stale: fleet:crew-api (paused 900s, awaiting external)'
timeout 120 "$W/bin/fm-session-start.sh" --compact 2>&1 | grep -v '^●' || true
echo
echo "================================================================"
echo "4. A crewmate session starting inside a registered crew worktree"
echo "================================================================"
primary="$T/primary"
git init -q "$primary"
( cd "$primary" && git commit -q --allow-empty -m init )
mkdir -p "$primary/state"
git -C "$primary" worktree add -q -b crew-branch "$T/crewtree" >/dev/null 2>&1
printf 'window=fleet:crew-api\nkind=ship\nworktree=%s\n' "$T/crewtree" > "$primary/state/task-api.meta"
echo "\$ FM_ROOT_OVERRIDE=$T/crewtree bin/fm-session-start.sh"
FM_ROOT_OVERRIDE="$T/crewtree" FM_HOME="$T/crewtree" timeout 120 "$W/bin/fm-session-start.sh" 2>&1 | head -5
rm -rf "$T"
