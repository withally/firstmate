Mode: Grok background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   If Grok automatically moves that drain to the background, do not end the same initiating turn.
   Immediately call `get_command_or_subagent_output(<task_id>, timeout_ms=30000)` for that exact drain task and wait for it to complete.
   Treat the returned output as the drain's real output: handle every emitted wake and preserve its `WAKE_ACK_REQUIRED` instruction.
   After handling all emitted wakes and reconciling open decisions, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: arm with Grok's tracked background tool, as its own call:

   `run_terminal_command` with `background: true` on:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh`

4. Trust only the arm's one-line status.
5. `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   `watcher: attached ...` is recovery when no identity-matched tracked arm owner is known for the live watcher; it is not permission to stack another waiter.
   On attach, that recovery owner follows verified identity-matched successors instead of exiting when the first cycle ends.
   `watcher: owner verified ... (duplicate returned)` means another identity-matched tracked arm already owns this home's wait, so this duplicate is finished and must not drain, re-arm, or invent work.
6. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
7. After a successful start or attach status, end the turn.
   The background arm remains the live wait until it returns an actionable wake or failure.
8. Waiting is silent.
   An empty recovery episode and an identity-matched successor rotation remain inside that same tracked arm and create no completion prompt or primary turn.
   `check: rearm-resurface` completes the arm only when an unacknowledged queue row or open decision requires handling.
9. Never use shell `&` for firstmate supervision.
10. Never bundle the arm onto another command.
    A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) whenever this project's Grok hooks are trusted.
11. Never intentionally start another arm while an identity-matched tracked arm is known live.

Grok injects a synthetic user message with `synthetic_reason: task_completed` when the background arm completes.
Quiet recovery and successor continuity do not complete it.
When you see a background-task-completed system reminder for the arm:
1. Run `bin/fm-wake-drain.sh` first.
2. Optionally fetch arm output with `get_command_or_subagent_output(<task_id>)` for the reason line.
3. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
4. Ordinary actionable close: say “the watcher delivered work; restoring the next cycle,” then re-arm with the same background `bin/fm-watch-arm.sh` call if work remains in flight or X mode still needs polling.
   Reserve “supervision dropped” for `watcher: FAILED`, an unexplained close, or a guard finding with no typed actionable predecessor.
5. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` entries, or a real watcher reason line.
   Re-arm attaches only when a healthy watcher has no known identity-matched tracked arm owner, then follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close contract.

The primary project Stop hook runs `bin/fm-turnend-guard-grok.sh` as a backstop, not the normal wake path.
[`turnend-guard.md`](../turnend-guard.md) owns its running-payload capability selection between native same-process blocking and the pre-native bounded resume fallback.
After any forced continuation, arm the watcher with the background protocol above.

Interactive TUI primary sessions are the supported supervision host.
Headless `grok -p` may wait for background process exit but does not reliably surface full auto-wake model output; do not run the primary firstmate as a one-shot headless process.
