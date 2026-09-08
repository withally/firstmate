# Lavish session lifecycle and conservative prune report

## Outcome

Firstmate now owns Lavish sessions through an explicit per-task or home ledger, teardown-time ephemeral ending, verified safe-park transfer, a narrow lifecycle-owner `retire-and-end`, a bootstrap registry diagnostic, and a dry-run-first audit/apply helper.
The captain-authorized migration verified 76 ambiguous session transitions to ended before stopping on the first contradictory result, as required.
One already-ended protected review was re-served, so the net registry change was 75 fewer open rows: 372 before and 297 after.
The target of at most 20 genuinely active open sessions was not reached because Lavish reported success without ending one session, the stop-on-contradiction contract left 60 frozen candidates unattempted, and 111 missing-path rows remain unsupported by Lavish 0.1.63.
Every ended board remains on disk and can be re-served because this migration deleted no artifact files.

## Live migration

The migration snapshot contained 417 total rows: 372 open, 18 feedback, and 27 ended.
An early classifier pass incorrectly treated retained Nancy direction key `6aba2ed4c6df33d3` as eligible because it recognized closed backlog rows but not their retained `hold-kind` field.
The supported `lavish-axi end <file>` path temporarily ended that row and verified its transition.
The retained backlog record was then found, the session was restored through supported no-open serve semantics, and the classifier was corrected and regression-tested.
The final classifier preserves that row with `retained-backlog-hold:parked` evidence.

The captain subsequently authorized ending all 136 existing-path ambiguous rows in the frozen set except three review artifacts mentioned that day.
Those kept artifacts were Nancy tennis directions key `7f59a8c16dff9f19`, Ally paid media key `4ae99e8ad06d4a8c`, and the 食·養·打 review under `data/syd-board-b1/board/` key `cc73671c247bff78`.
The apply helper ended and verified 76 rows in batches of ten.
After 70 successful transitions, the eighth batch stopped at key `85cdb2e77ba73904` for `/Users/ivan/Projects/firstmate/data/pilo-university-game-direction-f2/.lavish/location-1-days.html` because `lavish-axi end` exited successfully but the registry row remained open.
The contradictory row was not retried, and the remaining 60 frozen candidates were not attempted.
The protected Nancy tennis directions and Ally paid-media sessions remained open.
The protected 食·養·打 review had already been ended historically, so it was re-served through supported no-open semantics and remains open.

The final snapshot contains 417 total rows: 297 open, 18 feedback, and 102 ended.
Of the open rows, 253 were past the new 48-hour idle expiry.
The snapshot had 23 active poll registrations, ten mapped live poll clients, and three unmapped Chrome connections.
The shared server was not stopped, restarted, signalled, or reconfigured.
No Lavish record, Firstmate state record, chat, attachment, or artifact file was deleted.

## Remaining ambiguous evidence

The final read-only audit classified 245 rows as preserve and 172 as ambiguous.
The ambiguous set contained 61 existing artifacts with `idle-expired:48h,unmapped-browser-connections:3` evidence and 111 missing artifacts with `unsupported-by-current-Lavish,artifact-missing` evidence.
The 61 existing rows include the contradictory key plus the 60 frozen candidates left unattempted after the stop.
The 111 missing-path rows were skipped because Lavish 0.1.63 requires `realpath` of an existing file for its supported one-session end command.
No replacement file was synthesized and `state.json` was not edited.

The final preserve set contained 102 historical ended rows plus current task ownership, retained worktrees, captain holds, decision bindings, registered or live process-event sources, feedback or prompts, unacknowledged delivery, mapped clients, unresolved layout-warning repair, and the three explicit kept boards.
Unreadable or malformed home inventory now refuses eligibility, multiple candidate owners remain ambiguous, and an unkeyed browser connection cannot be bypassed by ordinary apply.

## Implementation and verification

`bin/fm-lavish-session.sh` owns the locked ledger, supported end path, home-owned durable bearings board, real poll activity time, and verified ledger finalization.
`bin/fm-lavish-audit.sh` owns conservative classification, frozen candidates, the explicit 2026-09-08 authorization record, bounded apply, and read-only coverage of the primary and registered secondmate homes.
`bin/fm-procevent-lavish.sh arm` registers ownership and refreshes activity on every poll iteration.
Plain `retire` remains narrow, while `retire-and-end` preflights the durable-end guard before removing any source or binding.
`bin/fm-teardown.sh` ends and verifies task and secondmate-child ephemeral sessions before process reaping or worktree return.
`bin/fm-bootstrap.sh` stays silent below 20 open registry rows and emits one actionable warning from 50 upward while distinguishing historical rows from live connections.
Bootstrap reports the past-expiry count but never ends a session automatically.

Behavior tests execute the public scripts against isolated Firstmate homes and Lavish state directories.
They cover ledger registration and locking, owner ambiguity, home-owned bearings, poll activity, verified end and finalization, safe-park ordering, durable-end preflight, conservative inventory failure, authorized frozen apply, secondmate-child teardown, bootstrap thresholds, and summary counts.

## Upstream custody

The verbatim section 6 note is in `data/fm-lavish-session-prune-f1/upstream-issue-draft.md`.
No issue or pull request was opened against `kunchenguid/lavish-axi`.
Nothing was pushed to that repository.
The draft remains parked for a later captain decision.
