Mode: Grok monitor-owned successor-first supervision.

When this session owns supervision and away mode is not active:

1. Drain first with `bin/fm-wake-drain.sh`.
   If Grok automatically moves that drain to the background, do not end the same initiating turn.
   Immediately call `get_command_or_subagent_output(<task_id>, timeout_ms=30000)` for that exact drain task and wait for it to complete.
   Treat the returned output as the drain's real output: handle every emitted wake and preserve its `WAKE_ACK_REQUIRED` instruction.
   After handling all emitted wakes and reconciling open decisions, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle or explicit repair: use Grok's persistent `monitor` tool exactly once on this command:

   `exec bin/fm-grok-watch-coordinator.mjs`

   Give the monitor a short watcher-continuity description and keep it persistent for the session.
   This exact persistent monitor is the sole command-scoped exception to the primary delegation guard; any altered monitor command remains denied.
   The coordinator sources the effective `config/x-mode.env` for every arm child when X mode is active.
3. Trust only the coordinator's typed one-line events.
4. `FIRSTMATE_GROK_WATCH_READY {"coordinator_pid":...,"arm_pid":...,"watcher_pid":...}` means the coordinator verified the first live watcher.
   This is setup confirmation, not actionable work; do not drain or start another coordinator because of it.
5. `FIRSTMATE_GROK_COORDINATOR_DUPLICATE {"owner_pid":...}` means another identity-matched coordinator already owns this home's continuous wait.
   The duplicate is finished and must not drain, re-arm, or invent work.
6. `FIRSTMATE_GROK_FAILURE {...}` means the automatic mechanism is down or could not restore continuity.
   Preserve the strict turn-end guard, inspect the typed reason, and repair through one new persistent coordinator only after reconciling the recorded owner.
7. Waiting is silent.
   Quiet recovery and successor rotation remain inside the same monitor-owned coordinator and create no primary turn.
8. Never use shell `&` for firstmate supervision.
9. Never bundle the coordinator onto another command.
10. Never intentionally start another coordinator while its identity-matched owner is live.

When Grok delivers a `FIRSTMATE_GROK_WAKE` monitor notification:

1. Read the JSON fields as one typed event.
2. A non-null `successor_watcher_pid` and `recovery_generation` prove that the predecessor closed and exactly one verified successor is already live.
3. Immediately confirm the accepted notification with `bin/fm-watch-arm.sh --handling-delivered <recovery_generation> --watcher-pid <successor_watcher_pid>`.
   A failed confirmation is a continuity failure; do not pretend the recovery generation entered handling.
4. Run `bin/fm-wake-drain.sh`, handling Grok's automatic background move with the same bounded same-turn wait above.
5. Handle the reported `reason`, every durable wake row, and every open decision through the harness-neutral contract in `AGENTS.md`.
6. Run the exact generation-bound `WAKE_ACK_REQUIRED` command only after handling completes.
7. Do not re-arm after an ordinary wake.
   The coordinator already owns the successor and will deliver its later actionable close through the same path.
8. When `continuity_failure` is non-null, the coordinator still emits the original actionable reason exactly once with one typed restoration failure.
   A retained unready successor owns the only attempt and no overlapping retry is allowed; a null successor keeps the strict guard truthful.

The persistent coordinator is not expected to complete during ordinary supervision.
A `synthetic_reason: task_completed` reminder for that monitor process is therefore an abnormal coordinator close, not an ordinary watcher wake.
The primary project Stop hook runs `bin/fm-turnend-guard-grok.sh` as a strict backstop rather than the normal wake path.
[`turnend-guard.md`](../turnend-guard.md) owns its running-payload capability selection between native same-process blocking and the pre-native bounded resume fallback.
After any forced continuation, repair the persistent coordinator through the first-cycle procedure above.

Interactive TUI primary sessions are the supported supervision host.
Headless `grok -p` does not provide the persistent monitor-owned notification path required by this protocol.
