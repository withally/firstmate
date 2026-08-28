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
if [ "${MODE:-routine}" = signal ]; then
  printf '%s\n' "$$" > "$STATE/arm-pid"
  trap 'printf terminated > "$STATE/arm-term"; exit 143' HUP TERM INT
  while :; do
    sleep 0.1
  done
fi
if [ "${MODE:-routine}" = custom ]; then
  if [ "$count" -eq 1 ]; then
    FM_WATCH_GROK_LONGRUN=1 FM_STATE_OVERRIDE="$STATE" \
      bash -c '. "$1"; WATCHER_RECOVERY_PENDING=1; resurface_after_downtime' _ "$WATCH_SOURCE"
    exit $?
  fi
  printf 'signal: %s/custom.status\n' "$STATE"
  exit 0
fi
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
  if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
    printf '%s\n' "$FM_WATCH_PREDECESSOR_ARM_PID" > "$STATE/predecessor-arm"
    exit 75
  fi
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
[ -s "$LAB/home/state/predecessor-arm" ] \
  || fail "routine recovery did not hand off the predecessor arm"
case "$(cat "$LAB/home/state/predecessor-arm")" in
  ''|*[!0-9]*) fail "routine recovery handed off an invalid predecessor arm" ;;
esac

routine_queue="$LAB/routine-unterminated.queue"
printf '%s' "$(sed -n '1p' "$LAB/home/state/.wake-queue")" > "$routine_queue"
FM_STATE_OVERRIDE="$LAB/home/state" bash -c \
  '. "$1"; fm_watch_recovery_queue_is_routine "$2"' _ \
  "$ROOT/bin/fm-watch-loop-lib.sh" "$routine_queue" \
  || fail "unterminated routine recovery row was rejected"
mixed_queue="$LAB/mixed-unterminated.queue"
printf '%s\n' "$(sed -n '1p' "$LAB/home/state/.wake-queue")" > "$mixed_queue"
printf '%s' "1710000000\t2\tstale\tfixture:nonroutine\tstale: fixture:nonroutine (possible wedge)" \
  >> "$mixed_queue"
if FM_STATE_OVERRIDE="$LAB/home/state" bash -c \
  '. "$1"; fm_watch_recovery_queue_is_routine "$2"' _ \
  "$ROOT/bin/fm-watch-loop-lib.sh" "$mixed_queue"; then
  fail "unterminated non-routine recovery row was ignored"
fi

FM_STATE_OVERRIDE="$LAB/home/state" bash -c \
  '. "$1"; fm_wake_append stale fixture:w1 "stale: fixture:w1 (possible wedge)"' _ \
  "$ROOT/bin/fm-wake-lib.sh" \
  || fail "could not append a non-routine recovery row"
FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" MODE=nonroutine WATCH_SOURCE="$WATCH_SOURCE" \
  "$LAB/repo/bin/fm-watch-grok-longrun.sh" > "$LAB/nonroutine-output" 2>&1 \
  || fail "non-routine recovery payload caused the long-runner to fail"
grep -Fx 'check: rearm-resurface' "$LAB/nonroutine-output" >/dev/null \
  || fail "non-routine recovery payload was suppressed as routine"

mkdir -p "$LAB/custom/home/state"
custom_queue="$LAB/custom/home/state/custom-wake-queue"
printf '%s\n' "$(sed -n '1p' "$LAB/home/state/.wake-queue")" > "$LAB/custom/home/state/.wake-queue"
FM_STATE_OVERRIDE="$LAB/custom/home/state" FM_WAKE_QUEUE="$custom_queue" bash -c \
  '. "$1"; fm_wake_append stale fixture:custom "stale: fixture:custom (possible wedge)"' _ \
  "$ROOT/bin/fm-wake-lib.sh" \
  || fail "could not append a custom non-routine recovery row"
FM_HOME="$LAB/custom/home" FM_STATE_OVERRIDE="$LAB/custom/home/state" \
  FM_WAKE_QUEUE="$custom_queue" MODE=custom WATCH_SOURCE="$WATCH_SOURCE" \
  "$LAB/repo/bin/fm-watch-grok-longrun.sh" > "$LAB/custom-output" 2>&1 \
  || fail "custom queue recovery caused the long-runner to fail"
grep -Fx 'check: rearm-resurface' "$LAB/custom-output" >/dev/null \
  || fail "custom queue recovery was classified using the default queue"
! grep -q '^signal:' "$LAB/custom-output" \
  || fail "custom queue recovery continued past the actionable wake"

mkdir -p "$LAB/signal/home/state"
FM_HOME="$LAB/signal/home" FM_STATE_OVERRIDE="$LAB/signal/home/state" MODE=signal WATCH_SOURCE="$WATCH_SOURCE" \
  "$LAB/repo/bin/fm-watch-grok-longrun.sh" > "$LAB/signal-output" 2>&1 &
signal_pid=$!
i=0
while [ "$i" -lt 100 ]; do
  [ -s "$LAB/signal/home/state/arm-pid" ] && break
  sleep 0.02
  i=$((i + 1))
done
if [ ! -s "$LAB/signal/home/state/arm-pid" ]; then
  kill "$signal_pid" 2>/dev/null || true
  wait "$signal_pid" 2>/dev/null || true
  fail "signal fixture did not start its arm"
fi
kill -TERM "$signal_pid" 2>/dev/null || fail "could not terminate the long-runner fixture"
wait "$signal_pid" 2>/dev/null || true
[ -s "$LAB/signal/home/state/arm-term" ] \
  || fail "long-runner termination did not reach the active arm"

printf 'ok - routine recovery rows stayed tracked and non-routine recovery surfaced\n'
