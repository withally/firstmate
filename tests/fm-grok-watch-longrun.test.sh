#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LONGRUN="$ROOT/bin/fm-watch-grok-longrun.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-watch-grok-longrun.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
WATCH_SOURCE="$ROOT/bin/fm-watch.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

mkdir -p "$LAB/repo/bin" "$LAB/home/state"
cp "$LONGRUN" "$LAB/repo/bin/fm-watch-grok-longrun.sh"
cp "$ROOT/bin/fm-watch-loop-lib.sh" "$LAB/repo/bin/fm-watch-loop-lib.sh"
cp "$ROOT/bin/fm-classify-lib.sh" "$LAB/repo/bin/fm-classify-lib.sh"
cp "$ROOT/bin/fm-timeout-lib.sh" "$LAB/repo/bin/fm-timeout-lib.sh"
cat > "$LAB/repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
count_file="$STATE/cycle-count"
count=$(cat "$count_file" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "${MODE:-routine}" = nonroutine ]; then
  FM_WATCH_GROK_LONGRUN=1 FM_STATE_OVERRIDE="$STATE" \
    bash -c '. "$1"; WATCHER_RECOVERY_PENDING=1; resurface_after_downtime' _ "$WATCH_SOURCE"
  exit $?
fi
if [ "$count" -eq 1 ]; then
  printf 'paused: fixture wait\n' > "$STATE/fixture.status"
  FM_WATCH_GROK_LONGRUN=1 FM_STATE_OVERRIDE="$STATE" \
    bash -c '. "$1"; PAUSE_RESURFACE_SECS=0; handle_paused_stale "fixture:w1" fixture fixture-hash' _ "$WATCH_SOURCE"
  exit $?
fi
if [ "$count" -le 5 ]; then
  FM_WATCH_GROK_LONGRUN=1 FM_STATE_OVERRIDE="$STATE" \
    bash -c '. "$1"; WATCHER_RECOVERY_PENDING=1; resurface_after_downtime' _ "$WATCH_SOURCE"
  exit $?
fi
printf 'signal: %s/actionable.status\n' "$STATE"
SH
chmod +x "$LAB/repo/bin/fm-watch-arm.sh" "$LAB/repo/bin/fm-watch-grok-longrun.sh"

FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" WATCH_SOURCE="$WATCH_SOURCE" \
  "$LAB/repo/bin/fm-watch-grok-longrun.sh" > "$LAB/output" 2>&1 &
pid=$!
i=0
while [ "$i" -lt 100 ]; do
  [ "$(cat "$LAB/home/state/cycle-count" 2>/dev/null || true)" = 6 ] && break
  sleep 0.02
  i=$((i + 1))
done
wait "$pid" || fail "long-runner failed while handing over the actionable cycle"
[ "$(cat "$LAB/home/state/cycle-count")" = 6 ] \
  || fail "fixture did not reproduce five routine closes before the actionable cycle"
[ "$(grep -c '^signal:' "$LAB/output")" -eq 1 ] \
  || fail "actionable wake did not surface exactly once"
! grep -qE '^(stale:|check:)' "$LAB/output" \
  || fail "a routine declared-wait cycle escaped the long-runner"
[ -s "$LAB/home/state/.wake-queue" ] \
  || fail "routine producer did not leave its durable queue row for recovery"

FM_STATE_OVERRIDE="$LAB/home/state" bash -c \
  '. "$1"; fm_wake_append stale fixture:w1 "stale: fixture:w1 (possible wedge)"' _ \
  "$ROOT/bin/fm-wake-lib.sh" \
  || fail "could not append a non-routine recovery row"
FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" MODE=nonroutine WATCH_SOURCE="$WATCH_SOURCE" \
  "$LAB/repo/bin/fm-watch-grok-longrun.sh" > "$LAB/nonroutine-output" 2>&1 \
  || fail "non-routine recovery payload caused the long-runner to fail"
grep -Fx 'check: rearm-resurface' "$LAB/nonroutine-output" >/dev/null \
  || fail "non-routine recovery payload was suppressed as routine"

printf 'ok - routine recovery rows stayed tracked and non-routine recovery surfaced\n'
