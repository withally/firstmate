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
cp "$ROOT/bin/fm-wake-lib.sh" "$LAB/repo/bin/fm-wake-lib.sh"
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
WATCH_ROOT=${WATCH_SOURCE%/bin/fm-watch.sh}
if [ "${MODE:-routine}" = signal ]; then
  printf '%s\n' "$$" > "$STATE/arm-pid"
  trap 'printf terminated > "$STATE/arm-term"; exit 143' HUP TERM INT
  while :; do
    sleep 0.1
  done
fi
if [ "${MODE:-routine}" = spawn-race ]; then
  target=$PPID
  ( sleep 0.05; kill -TERM "$target" 2>/dev/null || true; sleep 0.05; kill -CONT "$target" 2>/dev/null || true ) &
  kill -STOP "$target"
  sleep 0.2
  printf '%s\n' child-survived > "$STATE/child-survived"
  exit 0
fi
if [ "${MODE:-routine}" = missing-marker ]; then
  printf '%s\n' 'check: rearm-resurface' 'watcher: recovery state could not be persisted'
  exit 75
fi
if [ "${MODE:-routine}" = boundary ]; then
  if [ "$count" -eq 1 ]; then
    FM_STATE_OVERRIDE="$STATE" bash -c \
      '. "$1"; fm_wake_append stale fixture:boundary "stale: fixture:boundary (paused, declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"' _ \
      "$WATCH_ROOT/bin/fm-wake-lib.sh"
    printf '%s\n' 'watcher: routine-handoff-ok'
    exit 75
  fi
  FM_STATE_OVERRIDE="$STATE" bash -c \
    '. "$1"; fm_wake_append check fixture:action "check: fixture action"' _ \
    "$WATCH_ROOT/bin/fm-wake-lib.sh"
  printf '%s\n' 'watcher: routine-handoff-ok'
  exit 75
fi
if [ "${MODE:-routine}" = throttle-failure ]; then
  printf 'paused: fixture wait\n' > "$STATE/fixture.status"
  mkdir "$STATE/.paused-resurfaced-fixture_w1"
  FM_WATCH_GROK_LONGRUN=1 FM_STATE_OVERRIDE="$STATE" \
    bash -c '. "$1"; PAUSE_RESURFACE_SECS=0; handle_paused_stale "fixture:w1" fixture fixture-hash' _ "$WATCH_SOURCE"
  exit $?
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
  rc=$?
  [ "$rc" -eq 75 ] && printf '%s\n' 'watcher: routine-handoff-ok'
  exit "$rc"
fi
if [ "$count" -le 5 ]; then
  if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
    printf '%s\n' "$FM_WATCH_PREDECESSOR_ARM_PID" > "$STATE/predecessor-arm"
    printf '%s\n' 'watcher: routine-handoff-ok'
    exit 75
  fi
  FM_WATCH_GROK_LONGRUN=1 FM_STATE_OVERRIDE="$STATE" \
    bash -c '. "$1"; WATCHER_RECOVERY_PENDING=1; resurface_after_downtime' _ "$WATCH_SOURCE"
  rc=$?
  [ "$rc" -eq 75 ] && printf '%s\n' 'watcher: routine-handoff-ok'
  exit "$rc"
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

mkdir -p "$LAB/boundary/home/state"
FM_HOME="$LAB/boundary/home" FM_STATE_OVERRIDE="$LAB/boundary/home/state" MODE=boundary WATCH_SOURCE="$WATCH_SOURCE" \
  "$LAB/repo/bin/fm-watch-grok-longrun.sh" > "$LAB/boundary-output" 2>&1 \
  || fail "actionable queue work beyond the successor boundary failed"
grep -Fx 'check: rearm-resurface' "$LAB/boundary-output" >/dev/null \
  || fail "actionable queue work beyond the successor boundary was suppressed"
! grep -q '^watcher: routine-handoff-ok' "$LAB/boundary-output" \
  || fail "routine handoff marker escaped with actionable queue work"

mkdir -p "$LAB/missing-marker/home/state"
if FM_HOME="$LAB/missing-marker/home" FM_STATE_OVERRIDE="$LAB/missing-marker/home/state" MODE=missing-marker WATCH_SOURCE="$WATCH_SOURCE" \
  "$LAB/repo/bin/fm-watch-grok-longrun.sh" > "$LAB/missing-marker-output" 2>&1; then
  fail "an unconfirmed routine handoff was accepted"
fi
grep -q '^watcher: FAILED' "$LAB/missing-marker-output" \
  || fail "an unconfirmed routine handoff did not surface a failure"

mkdir -p "$LAB/throttle/home/state"
if FM_HOME="$LAB/throttle/home" FM_STATE_OVERRIDE="$LAB/throttle/home/state" MODE=throttle-failure WATCH_SOURCE="$WATCH_SOURCE" \
  "$LAB/repo/bin/fm-watch-grok-longrun.sh" > "$LAB/throttle-output" 2>&1; then
  fail "a throttle persistence failure was accepted"
fi
grep -F 'watcher: FAILED - stale wake throttle could not be persisted' "$LAB/throttle-output" >/dev/null \
  || fail "a throttle persistence failure was not propagated"

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

mkdir -p "$LAB/spawn-race/home/state"
FM_HOME="$LAB/spawn-race/home" FM_STATE_OVERRIDE="$LAB/spawn-race/home/state" MODE=spawn-race WATCH_SOURCE="$WATCH_SOURCE" \
  "$LAB/repo/bin/fm-watch-grok-longrun.sh" > "$LAB/spawn-race-output" 2>&1 &
spawn_pid=$!
i=0
while [ "$i" -lt 100 ] && kill -0 "$spawn_pid" 2>/dev/null; do
  sleep 0.02
  i=$((i + 1))
done
if kill -0 "$spawn_pid" 2>/dev/null; then
  kill -TERM "$spawn_pid" 2>/dev/null || true
  wait "$spawn_pid" 2>/dev/null || true
  fail "spawn-race long-runner did not terminate"
fi
wait "$spawn_pid" 2>/dev/null || true
[ ! -e "$LAB/spawn-race/home/state/child-survived" ] \
  || fail "spawn-race termination left the arm alive"

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
