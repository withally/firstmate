#!/usr/bin/env bash
# Real Pi/Herdr regression for ambiguous away-digest acknowledgement.
#
# The test launches a real Pi primary in a guarded non-default Herdr lab, then
# hides Herdr's native working edge from the daemon after Pi accepts one
# operational message.
# Multiple housekeeping ticks and a daemon crash/restart must never cause the
# logical digest text to be sent again.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"

if [ "${FM_AFK_DIGEST_REPLAY_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AFK_DIGEST_REPLAY_HERDR_E2E=1 to run the real Pi/Herdr digest replay regression"
  exit 0
fi

for tool in herdr jq pi python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=${HERDR_LAB_SESSION:-$("$LAB_HELPER" name fm-afk-digest-replay-e2e)}
TMP_ROOT=$(fm_test_tmproot fm-afk-digest-replay-e2e)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PROJECT="$TMP_ROOT/project"
PI_DIR="$TMP_ROOT/pi-agent"
FAKEBIN="$TMP_ROOT/fakebin"
SESSION_DIR="$TMP_ROOT/pi-sessions"
KEEPALIVE_ACTIVE="$TMP_ROOT/pi-keepalive-active"
SEND_LOG="$TMP_ROOT/send-text.log"
NOTIFY_LOG="$TMP_ROOT/wedge-notify.log"
ORIGINAL_PATH=$PATH
PRIMARY_TARGET=
DAEMON_STARTED=0

persisted_operational_count() {
  find "$SESSION_DIR" -type f -name '*.jsonl' \
    -exec jq -r 'select(.type == "message" and .message.role == "user" and any(.message.content[]?; .type == "text" and (.text | startswith("⁣FIRSTMATE_OP: v1 away-supervisor")))) | 1' {} + 2>/dev/null \
    | wc -l | tr -d ' '
}

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$DAEMON_STARTED" -eq 1 ]; then
    PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
      FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" \
      "$ROOT/bin/fm-afk-launch.sh" stop >/dev/null 2>&1 || true
  fi
  if [ "${FM_HERDR_LAB_PREPROVISIONED:-0}" != 1 ]; then
    "$LAB_HELPER" teardown "$SESSION" || rc=1
  fi
  if [ "${FM_TEST_KEEP_TMP:-0}" = 1 ]; then
    printf 'kept fixture evidence: %s\n' "$TMP_ROOT" >&2
  else
    rm -rf "$TMP_ROOT"
  fi
  exit "$rc"
}
trap cleanup EXIT
if [ "${FM_HERDR_LAB_PREPROVISIONED:-0}" != 1 ]; then
  "$LAB_HELPER" provision "$SESSION"
fi

mkdir -p "$HOME_DIR"/{state,data,config,projects} "$PROJECT" "$PI_DIR" "$FAKEBIN" "$SESSION_DIR"
printf '# Synthetic isolated Firstmate primary\n' > "$PROJECT/AGENTS.md"
printf 'on\n' > "$HOME_DIR/config/calm"
: > "$SEND_LOG"
: > "$NOTIFY_LOG"

CAPTURE_EXT="$TMP_ROOT/capture-extension.ts"
cat > "$CAPTURE_EXT" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { writeFileSync, unlinkSync } from "node:fs";
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("input", async (event) => {
    if (event.source === "interactive" && event.text.startsWith("⁣FIRSTMATE_OP: v1 away-supervisor")) {
      await pi.sendUserMessage(event.text, { deliverAs: "followUp" });
      pi.abort();
      return { action: "handled" } as const;
    }
    return { action: "continue" } as const;
  });
  pi.on("before_agent_start", async (event, ctx) => {
    if (event.prompt === "fixture keepalive") {
      const activePath = process.env.FM_PI_KEEPALIVE_PATH!;
      writeFileSync(activePath, "active\n");
      // The daemon is already ready before this turn starts, so this bounded
      // window is ample for its next housekeeping injection.
      await new Promise((resolve) => setTimeout(resolve, 15000));
      try { unlinkSync(activePath); } catch {}
      return;
    }
    ctx.abort();
  });
}
EOF

# Route every production-adapter Herdr call through the guarded lab helper.
# While the force-idle marker exists, only the daemon's supported agent-get
# seam is replaced with an idle result, reproducing accepted-but-unconfirmed.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
state='$STATE'
send_log='$SEND_LOG'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || exit 97
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || exit 98
fi
if [ -e "\$state/.force-idle-ack" ] && [ "\${args[0]:-}" = agent ] && [ "\${args[1]:-}" = get ]; then
  printf '%s\n' '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}'
  exit 0
fi
if [ "\${args[0]:-}" = pane ] && [ "\${args[1]:-}" = send-text ]; then
  printf '%s\n' "\${args[3]:-}" >> "\$send_log"
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

cat > "$TMP_ROOT/wedge-recorder" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$2" >> '$NOTIFY_LOG'
EOF
chmod +x "$TMP_ROOT/wedge-recorder"

cat > "$TMP_ROOT/daemon-entry" <<EOF
#!/usr/bin/env bash
export PATH='$FAKEBIN:$ORIGINAL_PATH'
export HERDR_SESSION='$SESSION'
export FM_STATE_OVERRIDE='$STATE'
export FM_ESCALATE_BATCH_SECS=0
export FM_HOUSEKEEPING_TICK=1
export FM_POLL=1
export FM_SIGNAL_GRACE=1
export FM_HEARTBEAT=999999
export FM_CHECK_INTERVAL=999999
export FM_MAX_DEFER_SECS=3
export FM_INJECT_CONFIRM_SLEEP=0.2
export FM_INJECT_CONFIRM_RETRIES=2
export FM_STALE_ESCALATE_SECS=999999
export FM_WEDGE_ALARM_EXEC='$TMP_ROOT/wedge-recorder'
exec '$ROOT/bin/fm-afk-start.sh'
EOF
chmod +x "$TMP_ROOT/daemon-entry"

PRIMARY_OUT=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label synthetic-digest-primary --no-focus)
PRIMARY_PANE=$(printf '%s' "$PRIMARY_OUT" | jq -r '.result.root_pane.pane_id')
PRIMARY_TARGET="$SESSION:$PRIMARY_PANE"
PI_CMD=$(printf 'exec env PI_CODING_AGENT_DIR=%q FM_HOME=%q FM_PI_KEEPALIVE_PATH=%q pi -e %q -e %q --no-context-files --session-dir %q' \
  "$PI_DIR" "$HOME_DIR" "$KEEPALIVE_ACTIVE" "$ROOT/.pi/extensions/fm-calm.ts" "$CAPTURE_EXT" "$SESSION_DIR")
"$LAB_HELPER" run "$SESSION" pane run "$PRIMARY_PANE" "$PI_CMD" >/dev/null

for _ in $(seq 1 240); do
  status=$("$LAB_HELPER" run "$SESSION" agent get "$PRIMARY_PANE" 2>/dev/null \
    | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  case "$status" in idle|done|blocked) break ;; esac
  sleep 0.25
done
case "${status:-}" in idle|done|blocked) ;; *) fail "real Pi primary did not become idle" ;; esac

composer_stable=0
for _ in $(seq 1 160); do
  composer=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" \
    fm_backend_composer_state herdr "$PRIMARY_TARGET")
  if [ "$composer" = empty ]; then
    composer_stable=$((composer_stable + 1))
    [ "$composer_stable" -ge 4 ] && break
  else
    composer_stable=0
  fi
  sleep 0.1
done
[ "$composer_stable" -ge 4 ] || fail "real Pi Calm composer did not become stably empty"

PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" FM_AFK_LAUNCH_ENTRY="$TMP_ROOT/daemon-entry" \
  "$ROOT/bin/fm-afk-launch.sh" start >/dev/null
DAEMON_STARTED=1
for _ in $(seq 1 100); do [ -s "$STATE/.supervise-daemon.pid" ] && break; sleep 0.1; done
[ -s "$STATE/.supervise-daemon.pid" ] || fail "away daemon did not start"

# Start the real Pi turn only after the daemon is ready, then inject during its
# bounded active window through the supported interactive-input to
# sendUserMessage(..., followUp) path.
"$LAB_HELPER" run "$SESSION" pane send-text "$PRIMARY_PANE" 'fixture keepalive' >/dev/null
"$LAB_HELPER" run "$SESSION" pane send-keys "$PRIMARY_PANE" enter >/dev/null
for _ in $(seq 1 80); do
  [ -e "$KEEPALIVE_ACTIVE" ] && break
  sleep 0.05
done
[ -e "$KEEPALIVE_ACTIVE" ] || fail "real Pi keepalive turn did not reach before_agent_start"

touch "$STATE/.force-idle-ack"
printf 'done: synthetic review is ready\n' > "$STATE/replay-task.status"

# Wait through multiple flushes and max-defer, then crash and restart the daemon
# while the away flag remains present.
for _ in $(seq 1 600); do
  persisted=$(persisted_operational_count)
  [ "$persisted" -ge 1 ] && break
  sleep 0.1
done
[ "${persisted:-0}" -ge 1 ] || fail "Pi did not persist the operational digest"
sleep 7

old_pid=$(cat "$STATE/.supervise-daemon.pid")
kill -KILL "$old_pid" 2>/dev/null || fail "could not crash the isolated daemon"
for _ in $(seq 1 100); do kill -0 "$old_pid" 2>/dev/null || break; sleep 0.1; done
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" FM_AFK_LAUNCH_ENTRY="$TMP_ROOT/daemon-entry" \
  "$ROOT/bin/fm-afk-launch.sh" start >/dev/null
for _ in $(seq 1 100); do
  new_pid=$(cat "$STATE/.supervise-daemon.pid" 2>/dev/null || true)
  [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] && break
  sleep 0.1
done
[ -n "${new_pid:-}" ] && [ "$new_pid" != "$old_pid" ] || fail "away daemon did not restart"
sleep 7

literal_count=$(grep -c '^⁣FIRSTMATE_OP: v1 away-supervisor' "$SEND_LOG" 2>/dev/null || true)
persisted_count=$(persisted_operational_count)
[ "$literal_count" -eq 1 ] || fail "ambiguous digest was typed $literal_count times across housekeeping/restart"
[ "$persisted_count" -eq 1 ] || fail "Pi persisted $persisted_count copies of one logical operational digest"
[ -s "$STATE/.subsuper-escalations" ] || fail "ambiguous digest lost its unresolved escalation buffer"
[ -s "$STATE/.subsuper-digest-inflight" ] || fail "ambiguous digest lost its durable in-flight identity"
[ -s "$STATE/.subsuper-inject-wedged" ] || fail "ambiguous digest did not raise a durable uncertainty alarm"
[ "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" -eq 1 ] || fail "ambiguous digest uncertainty alarm was not bounded to one notification"
prefix_occurrences=$(awk -F 'FIRSTMATE_OP: v1 away-supervisor' '{ total += NF - 1 } END { print total + 0 }' "$SEND_LOG")
[ "$prefix_occurrences" -eq 1 ] || fail "operational text was concatenated or repeated ($prefix_occurrences prefix occurrences)"

pass "real Pi/Herdr ambiguous acknowledgement types and persists one digest across housekeeping and restart"
