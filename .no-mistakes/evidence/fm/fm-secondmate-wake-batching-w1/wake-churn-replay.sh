#!/usr/bin/env bash
# Investigation replay: how many supervision turns a primary must spend to
# reconcile a fleet of N crew panes whose declared pauses are all due for their
# bounded recheck in the same watcher cycle.
#
# Usage: wake-churn-replay.sh <tree-root> <label> <fleet-size>
# Drives the REAL bin/fm-watch.sh in <tree-root> over a synthetic FM state dir:
#   - N crewmate panes, each with a durable `paused:` declaration and a primed
#     pane hash, all past FM_PAUSE_RESURFACE_SECS.
# Each watcher run ends at its first delivered wake (that IS one supervision
# turn); the replay drains + acknowledges like a primary would and re-arms,
# until a run reaches its heartbeat with nothing left to deliver.
set -u
TREE=$1; LABEL=$2; FLEET=$3
WATCH="$TREE/bin/fm-watch.sh"
DRAIN="$TREE/bin/fm-wake-drain.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/wake-replay.XXXXXX")
state="$work/state"; fakebin="$work/fakebin"
mkdir -p "$state" "$fakebin"
export FM_ROOT_OVERRIDE="$work/notagit"; mkdir -p "$FM_ROOT_OVERRIDE"

cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"; exit 0 ;;
  capture-pane) cat "$FM_FAKE_TMUX_CAPTURE"; exit 0 ;;
esac
exit 1
SH
cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: paused · source: status-log · awaiting upstream\n'
SH
chmod +x "$fakebin/tmux" "$fakebin/fm-crew-state.sh"

pane="$work/pane.txt"; printf 'idle declared wait\n' > "$pane"
if command -v md5 >/dev/null 2>&1; then pane_hash=$(printf '%s' 'idle declared wait' | md5 -q)
else pane_hash=$(printf '%s' 'idle declared wait' | md5sum | cut -d' ' -f1); fi
seen_sig() { if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1"; else stat -c '%s:%Y' "$1"; fi; }
set_mtime() { if stamp=$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null); then touch -t "$stamp" "$2"; else touch -t "$(date -d "@$1" +%Y%m%d%H%M.%S)" "$2"; fi; }

back=$(( $(date +%s) - 500 ))
i=1
while [ "$i" -le "$FLEET" ]; do
  task="crew-$i"; window="fleet:$task"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$window" > "$state/$task.meta"
  printf 'paused: awaiting upstream release for %s\n' "$task" > "$state/$task.status"
  set_mtime "$back" "$state/$task.status"
  printf '%s' "$(seen_sig "$state/$task.status")" > "$state/.seen-${task}_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  i=$((i + 1))
done

turns=0; wakes=0; round=0
printf '=== %s: fleet of %s crew panes, all declared pauses due for recheck ===\n' "$LABEL" "$FLEET"
while [ "$round" -lt $((FLEET + 3)) ]; do
  round=$((round + 1))
  out="$work/watch-$round.out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW='fleet:crew-1' FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=6 "$WATCH" > "$out" 2>&1 &
  pid=$!
  n=0
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 200 ]; do sleep 0.1; n=$((n + 1)); done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  if ! grep -qE '^(stale|signal):' "$out"; then
    printf -- '-- round %s: watcher reached its heartbeat with nothing left to deliver; fleet reconciled\n' "$round"
    break
  fi
  turns=$((turns + 1))
  printf -- '-- supervision turn %s -- watcher exited with:\n' "$turns"
  grep -E '^(stale|signal):' "$out" | sed 's/^/     /'
  err="$work/drain-$round.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$work/drain-$round.out" 2> "$err" || true
  printf '   supervisor drain shows:\n'
  grep -E 'WAKE|stale:|signal:' "$work/drain-$round.out" | sed 's/^/     /'
  wakes=$(( wakes + $(grep -c 'stale:' "$work/drain-$round.out" || true) ))
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -z "$seq" ] || FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 || true
done
printf 'RESULT %s: supervision turns spent = %s; stale wake records presented = %s\n\n' "$LABEL" "$turns" "$wakes"
rm -rf "$work"
