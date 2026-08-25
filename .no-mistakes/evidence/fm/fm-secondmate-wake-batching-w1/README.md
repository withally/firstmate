# Wake-churn batching - end-to-end evidence

All transcripts were produced by driving the real production scripts
(`bin/fm-watch.sh`, `bin/fm-wake-drain.sh`, `bin/fm-session-start.sh`,
`bin/backends/herdr.sh`, `.pi/extensions/fm-primary-pi-watch.ts`) against
throwaway FM homes.
Each `*.sh` here regenerates its `*.txt` neighbour.

## 1. Watcher fleet batching - `wake-churn-replay.txt`

A fleet whose declared pauses all come due in the same watcher cycle.
Every watcher exit is one supervision turn for the primary; the replay drains
and acknowledges like a primary would, then re-arms, until nothing is left.

| fleet | supervision turns BEFORE (d982d45) | AFTER (bf53bf0) |
|-------|------------------------------------|-----------------|
| 6 panes | 6 | 2 |
| 9 panes | 9 | 2 |

The single remaining non-batched turn is the live pane's own first stale
surface, which stays immediate by design.
Paused-recheck turns alone collapse 8 -> 1 on the report-shaped fleet: an 87.5%
reduction, inside the investigation report's expected 85-90% (report line 350).
Each pane is still named individually inside the one batched reason, so per-pane
bookkeeping is preserved.

## 2. Pi follow-up aggregator - `pi-wake-aggregator-demo.txt`

`config/wake-batch-seconds` set to 3 (production default 60).
Scenario A: four routine watcher closes, one duplicate status path, delivered as
one `FIRSTMATE WATCHER WAKE: batched 3 watcher wakes` follow-up at t+3.8s with
the duplicate deduplicated and exactly one delivery acknowledgement.
Scenario B: the same closes plus one `blocked [key=deploy-window]` status is
delivered at t+1.5s - the urgent class bypasses the configured window.

## 3. Drain and compact recovery - `drain-and-recovery-demo.txt`

First drain of a session prints OPEN DECISIONS in full; the next drain in the
same session, with an unchanged decision set, collapses to
`OPEN DECISIONS: unchanged, 1 open`; `fm-session-start.sh --compact` re-presents
them in full and emits only lock/watcher ownership, the actionable queue and
open decisions, active task identities, and the exact next supervision
instruction - with its `WAKE_ACK_REQUIRED` command on stdout and no status
tails or context files.
A session started inside a registered crew worktree prints exactly
`crew worktree - digest suppressed`.

## 4. Herdr submit hardening - `herdr-submit-repro.txt`

A steer whose post-Enter surface is momentarily unreadable:
BEFORE reports `unknown` after one Enter (delivery silently unconfirmed);
AFTER rechecks boundedly, retries the submit once, and confirms delivery.

## 5. Runtime bound under a hung git - `session-start-hung-git-repro.txt`

Round 1 found a regression: the registered-crew-worktree check ran `git rev-parse`
BEFORE the runtime-bound wrapper, so with a hung `git` session start produced NO
digest and never returned inside its bound (killed at 25s, exit 124).
Fixed in cc2dc20 - the predicate now runs under its own bounded parent check.
Re-measured on HEAD: exit 0 at 6s wall with a 3s bound, digest printed up to
BOOTSTRAP followed by the full STARTUP TRUNCATED banner naming the stages to
reconcile. `tests/fm-session-start.test.sh` passes end to end again (~4 min,
down from ~22 min while the hang was present).

## 6. Crew worktree suppression - `crew-worktree-suppression.txt`

A session opened from a worktree registered in the primary's `state/*.meta`
prints exactly `crew worktree - digest suppressed`; an unregistered linked
worktree still gets the full digest.
