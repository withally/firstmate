# Native session-start adapters

AGENTS.md section 3 is the authoritative behavioral contract for session start.
This file owns how tracked session-open adapters deliver that contract.

Claude and Codex exec use the run tier: `bin/fm-sessionstart-run.sh` executes the digest and lets hook stdout enter model context before the first turn.
Harnesses without a compatible stdout transport keep the nudge tier and ask the agent to run the same digest.
The two tiers share one behavioral owner in `bin/fm-session-start.sh`.

## Source routing

The run wrapper reads a Claude/Codex-shaped `source` field from hook input, or accepts `--source <name>` for direct adapter calls.

| Source | Action |
| --- | --- |
| `startup`, `new` | Run the full digest. |
| `clear`, `compact` | Re-emit after a completion record proves this lock owner finished startup; otherwise run the full digest. |
| `resume`, `reload`, `fork` | Delegate to the nudge wrapper because prior context is restored. |
| Missing, unreadable, or unknown | Run the full digest so an adapter change cannot silently skip startup. |

The full digest removes stale completion proof after acquiring the lock and publishes `state/.session-start-complete` only after every stage finishes.
The record contains the verified lock owner's pid, so a clear or compaction cannot trust another session's startup.
`--reemit` re-verifies lock ownership, skips the already-completed mutating bootstrap sweeps, and still presents queued wakes, which stay durable until the handling turn acknowledges them.

## Runtime bound

The run tier blocks session initialization while the digest executes.
`bin/fm-session-start.sh` therefore applies one whole-digest bound through `bin/fm-timeout-lib.sh`, defaulting to 120 seconds through `FM_SESSION_START_TIMEOUT`.
External-network work is outside that blocking path and runs under the independent bounded, durable contract owned by `bin/fm-startup-network.sh`.
If the bound is reached, output already emitted remains visible and a `STARTUP TRUNCATED` banner names the incomplete stage and every stage not reached.
The tracked hook timeouts are 180 seconds so the digest can emit its own diagnosis before the harness stops it.

## Shared wrappers and safety

The run and nudge wrappers both source `bin/fm-gate-refuse-lib.sh` and stay silent for a no-mistakes gate agent identified by `NO_MISTAKES_GATE` or a `.no-mistakes/repos/*.git` git-common-dir.
They share `bin/fm-primary-scope-lib.sh` with `bin/fm-turnend-guard.sh`, so every hook uses one primary-detection owner.
The Guard Predicates section of [`turnend-guard.md`](turnend-guard.md#guard-predicates) owns marker validation, plain-checkout detection, and required Firstmate-shaped paths.

The nudge payload starts with U+2063 and the stable `FIRSTMATE_OP: ` label, carries the current `session-start` protocol kind, and retains exactly ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` as its body.
The Ahoy skill owns the rule that this marked operational input is never a captain-authored session boundary, including its narrow legacy compatibility cases.
Before printing, the nudge wrapper reads `state/.lock` and walks at most eight parents from its own pid.
If the lock names a live pid in that ancestry, session start already ran in this harness session and the wrapper stays silent.

Every wrapper path exits 0, including malformed state and adapter errors, because a Claude SessionStart exit 2 blocks session initialization.
Lock refusal, bootstrap diagnostics, and truncation therefore arrive as model-visible digest text instead of blocking the session.

## Harness transports

| Harness | Tier | Tracked transport | Current compatibility |
| --- | --- | --- | --- |
| Claude | Run | `.claude/settings.json` registers one unmatched `SessionStart` hook and invokes the run wrapper through `CLAUDE_PROJECT_DIR` with a 180-second timeout. | Native stdout context injection is supported. |
| Codex exec | Run | `.codex/hooks.json` anchors to the hook working directory, verifies a Firstmate-shaped hook-bearing root, and pipes the payload into the run wrapper with a 180-second timeout. | Native stdout context injection is supported under `codex exec`. |
| Codex interactive TUI | Nudge | The tracked AGENTS.md instruction remains the fallback when the project hook does not fire. | The interactive TUI does not currently provide the tracked project SessionStart hook used by Codex exec. |
| OpenCode | Nudge | `.opencode/plugins/fm-primary-sessionstart-nudge.js` listens for `session.created`, runs once per session id, and calls `client.session.promptAsync` only when the wrapper prints a nudge. | Interactive TUI delivery is supported; headless `opencode run` is intentionally fail-open because the process can exit before the queued turn. |
| Pi / pi-signed | Nudge | `.pi/extensions/fm-primary-turnend-guard.ts` handles `session_start` reasons `startup`, `new`, and `resume`, then injects the nudge wrapper output with `pi.sendMessage`. | The existing custom-message delivery remains unchanged by this adaptation. |
| Grok | Nudge | `.grok/hooks/fm-primary-sessionstart-nudge.json` registers a project `SessionStart` hook and invokes the nudge wrapper through inline-defaulted `${GROK_WORKSPACE_ROOT:-}`. | The project hook runs when the checkout is trusted, but Grok currently discards hook stdout from model context, so this path is intentionally fail-open. |

The OpenCode nudge runs only on `session.created`.
The watcher-arm and turn-end plugins run later on `session.idle`, and the guard lets the watcher coordinator act first, so the plugins do not race for one lifecycle event.

Grok's guaranteed-loading alternative is a global token-guarded hook like the pattern used by `bin/fm-spawn.sh`.
That alternative expands trust and writes outside this repository, so Firstmate never installs it or grants folder trust automatically.

## Compaction restore

A run-tier harness (Claude, Codex exec) re-emits the digest automatically when its session-open hook fires with a `clear` or `compact` source, so the read-once dump returns to context and the primary never re-reads `data/captain.md`, `data/learnings.md`, or the other startup sources file by file.
Grok has no such path: its in-session auto-compaction (the common case) fires no session-open hook at all, and its `SessionStart` event reports `source=new` with stdout discarded from model context, so a compaction cannot be intercepted to push a re-emit.
The Grok primary therefore restores context the same way the read-once contract in `AGENTS.md` section 3 directs any harness whose compaction dropped the digest: run `bin/fm-session-start.sh --reemit` once and resume read-once trust.
`--reemit` re-verifies lock ownership, skips the already-completed mutating bootstrap sweeps, presents the durable wake queue, and reprints the fleet state and the five context files, so one bounded command replaces the ad-hoc repeated re-reads that a compaction otherwise provokes.

## Regression coverage

`tests/fm-sessionstart-nudge.test.sh` proves exact nudge output, gate and scope silence, full-run routing, completion-gated clear and compaction re-emission, and resume delegation.
`tests/fm-session-start.test.sh` proves lock-refusal delivery, the crewmate task-worktree no-op that runs before any lock or digest stage, whole-digest timeout reporting, stage truncation, status-line caps, and recovery-preserving backlog bounds.
`tests/fm-pi-primary-live-e2e.test.sh` and `tests/fm-opencode-primary-live-e2e.test.sh` exercise the unchanged native nudge paths with first-message and later-message Ahoy regressions.
`tests/fm-turnend-guard.test.sh`, `tests/fm-pi-watch-extension.test.sh`, and `tests/fm-daemon.test.sh` cover marked guard, monitoring, and away-mode delivery.

[`verification/supervision.md`](verification/supervision.md#native-session-start-delivery) records the active version-scoped transport evidence.
