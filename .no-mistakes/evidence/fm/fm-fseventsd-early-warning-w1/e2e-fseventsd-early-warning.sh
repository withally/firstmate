#!/usr/bin/env bash
# End-to-end operator walkthrough of the fseventsd footprint early warning.
#
# Each scenario stands up a fresh Firstmate home, seeds the durable sample
# history under state/telemetry/ as if the fleet had already been sampling for
# the last few minutes, then runs the REAL bin/fm-watch.sh once and drains the
# wake with the REAL bin/fm-wake-drain.sh. Only the host samplers
# (pgrep/top/sysctl) are faked, so an fseventsd footprint that would take hours
# to leak can be presented to the unmodified watcher path in one run.
set -u
ROOT=${FM_EVIDENCE_ROOT:?set FM_EVIDENCE_ROOT to the repo root}
# shellcheck source=/dev/null
. "$ROOT/tests/wake-helpers.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-fseventsd-evidence)
NOW=$(date '+%s')
MIB=1048576

scenario() { # <label> <mem-top-string> <pressure> <swap-top-string> <seed-lines...>
  local label=$1 mem=$2 pressure=$3 swap=$4
  shift 4
  local dir state fake out line
  dir=$(make_case "$(printf '%s' "$label" | tr -cs 'A-Za-z0-9' '-')")
  state="$dir/state"
  fake="$dir/fakebin"
  out="$dir/watch.out"
  printf 'fm-pr-check-migration-scan-v1\n' > "$state/.pr-check-migration-scan-v1"
  printf 'fm-pr-check-migration-v1\n' > "$state/.pr-check-migration-v1"
  chmod 0600 "$state"/.pr-check-migration*

  cat > "$fake/pgrep" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -x ] && [ "${2:-}" = fseventsd ] || exit 1
printf '342\n'
SH
  cat > "$fake/top" <<SH
#!/usr/bin/env bash
printf 'PID COMMAND MEM RPRVT CMPRS %%CPU TIME #TH\n'
printf '342 fseventsd $mem $mem 2M 0.4 00:31.00 17\n'
SH
  cat > "$fake/sysctl" <<SH
#!/usr/bin/env bash
case "\$*" in
  '-n kern.memorystatus_vm_pressure_level') printf '$pressure\n' ;;
  '-n vm.swapusage') printf 'total = 16384.00M  used = $swap  free = 8192.00M  (encrypted)\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fake/pgrep" "$fake/top" "$fake/sysctl"

  mkdir -p "$state/telemetry"
  : > "$state/telemetry/fseventsd-samples"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$state/telemetry/fseventsd-samples"
  done

  printf '\n================================================================\n'
  printf '%s\n' "$label"
  printf '================================================================\n'
  printf 'live sample the watcher will take: fseventsd MEM=%s, kern pressure level=%s, swap used=%s\n' \
    "$mem" "$pressure" "$swap"
  printf '$ cat state/telemetry/fseventsd-samples   # history already on disk (epoch mem_bytes pressure swap_bytes)\n'
  sed "s/^/  /" "$state/telemetry/fseventsd-samples"
  printf '$ bin/fm-watch.sh\n'
  PATH="$fake:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_TELEMETRY_FSEVENTSD_DISABLE=0 \
    FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
  local wpid=$! i=0
  while [ "$i" -lt 150 ]; do
    grep -q fseventsd "$out" 2>/dev/null && break
    kill -0 "$wpid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  if grep -q fseventsd "$out"; then
    grep -F fseventsd "$out" | sed 's/^/  /'
    printf '$ bin/fm-wake-drain.sh   # what the fleet operator/agent is actually handed\n'
    FM_STATE_OVERRIDE="$state" "$DRAIN" 2>/dev/null | grep -F fseventsd | sed 's/^/  /'
  else
    printf '  (watcher raised no fseventsd wake)\n'
  fi
  printf '$ cat state/telemetry/fseventsd-samples   # history after this cycle\n'
  sed 's/^/  /' "$state/telemetry/fseventsd-samples"
  if [ -f "$state/telemetry/fseventsd-alert" ]; then
    printf '$ cat state/telemetry/fseventsd-alert     # highest level of the live episode\n'
    sed 's/^/  /' "$state/telemetry/fseventsd-alert"
  else
    printf '$ cat state/telemetry/fseventsd-alert     # (absent: no episode open)\n'
  fi
}

printf 'fseventsd footprint early warning - end-to-end fleet walkthrough\n'
printf 'repo:    %s\n' "$ROOT"
printf 'real:    bin/fm-watch.sh (fleet watcher) + bin/fm-wake-drain.sh (wake delivery)\n'
printf 'faked:   pgrep / top / sysctl only\n'
printf 'clock:   real; sample history is pre-seeded with recent epochs\n'
printf 'accepted thresholds: warning >512 MiB twice or >256 MiB/h for 2h; action >2 GiB,\n'
printf '                     doubling within 1h, or warning + pressure/swap; emergency is\n'
printf '                     sustained growth toward 4 GiB with worsening pressure.\n'

scenario "1. HEALTHY - the ~5 MiB daemon this Mac actually runs right now" \
  5M 1 0.00M \
  "$((NOW - 720)) $((5 * MIB)) 1 0" \
  "$((NOW - 360)) $((5 * MIB)) 1 0"

scenario "2. WARNING - two consecutive samples above 512 MiB" \
  640M 1 0.00M \
  "$((NOW - 360)) $((600 * MIB)) 1 0"

scenario "3. WARNING - growth above 256 MiB/hour sustained for two hours" \
  800M 1 0.00M \
  "$((NOW - 9000)) $((100 * MIB)) 1 0" \
  "$((NOW - 360)) $((790 * MIB)) 1 0"

scenario "4. ACTION - past 2 GiB, doubled within the hour, yellow memory pressure" \
  2500M 2 0.00M \
  "$((NOW - 360)) $((600 * MIB)) 1 0"

scenario "5. ACTION - warning episode plus more than 8 GiB of swap in use" \
  700M 1 9000M \
  "$((NOW - 360)) $((600 * MIB)) 1 0"

scenario "6. EMERGENCY - sustained climb toward 4 GiB with worsening pressure" \
  3500M 4 9000M \
  "$((NOW - 690)) $((2600 * MIB)) 1 0" \
  "$((NOW - 345)) $((3000 * MIB)) 2 0"
