#!/usr/bin/env bash
# Detect an unprompted high-rate Pi secondmate episode from its persisted
# session transcript and publish one signal wake for the episode.
#
# Usage: fm-secondmate-turn-rate.sh <secondmate-task-id>
#
# The parent home's state/<id>.meta supplies the local secondmate home and
# harness. config/secondmate-turn-rate-threshold sets the maximum assistant
# message events allowed in the trailing 15 minutes without a user transcript
# row or a newly written durable inbox record. The default is 60.
#
# Quiet/no-op cases exit 0. A newly published episode prints its signal reason
# and exits 10 so the attended watcher can surface it. Invalid or unavailable
# evidence stays quiet; a wake publication failure exits 2.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
WINDOW_SECS=900
DEFAULT_THRESHOLD=60
TAIL_BYTES=16777216

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

ID=${1:-}
case "$ID" in
  ''|*[!A-Za-z0-9._-]*)
    echo "usage: fm-secondmate-turn-rate.sh <secondmate-task-id>" >&2
    exit 2
    ;;
esac

META="$STATE/$ID.meta"
MARKER="$STATE/.secondmate-turn-rate-$ID"
[ -f "$META" ] || exit 0

meta_value() {  # <key>
  sed -n "s/^$1=//p" "$META" 2>/dev/null | tail -1
}

KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
MATE_HOME=$(meta_value home)
REMOTE_HOST=$(meta_value remote_host)
[ "$KIND" = secondmate ] || exit 0
case "$HARNESS" in pi|pi-signed) ;; *) exit 0 ;; esac
[ -z "$REMOTE_HOST" ] && [ -d "$MATE_HOME" ] || exit 0
MATE_HOME=$(cd "$MATE_HOME" 2>/dev/null && pwd -P) || exit 0

THRESHOLD=$DEFAULT_THRESHOLD
if [ -f "$CONFIG/secondmate-turn-rate-threshold" ]; then
  configured=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
    "$CONFIG/secondmate-turn-rate-threshold" 2>/dev/null | head -1 | tr -d '[:space:]')
  case "$configured" in
    ''|*[!0-9]*|0) ;;
    *) THRESHOLD=$configured ;;
  esac
fi

if [ -n "${PI_CODING_AGENT_SESSION_DIR:-}" ]; then
  case "$PI_CODING_AGENT_SESSION_DIR" in /*) SESSION_DIR=$PI_CODING_AGENT_SESSION_DIR ;; *) exit 0 ;; esac
else
  AGENT_DIR=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
  case "$AGENT_DIR" in /*) ;; *) AGENT_DIR=$HOME/.pi/agent ;; esac
  slug=${MATE_HOME#/}
  slug=${slug//\//-}
  SESSION_DIR="$AGENT_DIR/sessions/--$slug--"
fi
[ -d "$SESSION_DIR" ] || exit 0

file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

TRANSCRIPT=
newest_mtime=0
for candidate in "$SESSION_DIR"/*.jsonl; do
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
  sed -n '1p' "$candidate" | jq -e --arg cwd "$MATE_HOME" \
    '.type == "session" and .cwd == $cwd' >/dev/null 2>&1 \
    || continue
  mtime=$(file_mtime "$candidate") || continue
  case "$mtime" in ''|*[!0-9]*) continue ;; esac
  if [ "$mtime" -ge "$newest_mtime" ]; then
    TRANSCRIPT=$candidate
    newest_mtime=$mtime
  fi
done
[ -n "$TRANSCRIPT" ] || exit 0

now=$(date +%s)
cutoff=$((now - WINDOW_SECS))
counts=$(tail -c "$TAIL_BYTES" "$TRANSCRIPT" 2>/dev/null | jq -Rnr --argjson cutoff "$cutoff" '
  def event_epoch:
    (.timestamp // .message.timestamp // empty) as $timestamp
    | if ($timestamp | type) == "number" then
        if $timestamp > 100000000000 then ($timestamp / 1000 | floor) else ($timestamp | floor) end
      elif ($timestamp | type) == "string" then
        ($timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?)
      else empty end;
  [inputs | fromjson? | select(event_epoch >= $cutoff)] as $events
  | ([ $events[] | select(.type == "message" and .message.role == "assistant") ] | length) as $assistant
  | ([ $events[] | select(.type == "message" and .message.role == "user") ] | length) as $inbound
  | "\($assistant)\t\($inbound)"
' 2>/dev/null) || exit 0
IFS=$(printf '\t') read -r assistant_events inbound_events <<EOF
$counts
EOF
case "$assistant_events:$inbound_events" in *[!0-9:]*) exit 0 ;; esac

inbox_events=0
for record in "$STATE/$ID.inbox"/*.msg "$STATE/$ID.inbox/handled"/*.msg; do
  [ -f "$record" ] || continue
  mtime=$(file_mtime "$record") || continue
  case "$mtime" in ''|*[!0-9]*) continue ;; esac
  [ "$mtime" -lt "$cutoff" ] || inbox_events=$((inbox_events + 1))
done
inbound_events=$((inbound_events + inbox_events))

if [ "$assistant_events" -le "$THRESHOLD" ] || [ "$inbound_events" -gt 0 ]; then
  rm -f "$MARKER"
  exit 0
fi

[ -e "$MARKER" ] && exit 0
tmp="$MARKER.tmp.$$"
if ! printf 'transcript=%s\nevents=%s\nstarted=%s\n' "$TRANSCRIPT" "$assistant_events" "$now" > "$tmp" \
  || ! mv "$tmp" "$MARKER"; then
  rm -f "$tmp"
  exit 2
fi
reason="signal: secondmate turn-rate exceeded: mate=$ID assistant-events=$assistant_events window=${WINDOW_SECS}s inbound-events=0 threshold=$THRESHOLD"
if ! fm_wake_append signal "secondmate-turn-rate:$ID" "$reason"; then
  rm -f "$MARKER"
  exit 2
fi
printf '%s\n' "$reason"
exit 10
