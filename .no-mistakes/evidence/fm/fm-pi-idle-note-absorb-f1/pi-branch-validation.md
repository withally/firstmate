# Pi supervision branch validation evidence

Date: 2026-08-29.

Target: `2e617d9215a4d6bb74ca887996c94ce0252b7fd7`.

## Real Pi SDK behavior

Command: `FM_PI_BRANCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh`.

Observed output:

```text
ok - real Pi SDK 0.84.2 accepts the branch session construction and preserves an unpromptable wake
ok - real Pi SDK 0.84.2 applies an explicit branch model on create and over a reopened session's recorded model
ok - real Pi SDK 0.84.2 reports its own supported effort levels and applies an explicit branch effort over a reopened session's recorded level
ok - real Pi SDK 0.84.2 delivers a custom message to the provider as user text carrying only content, so the captain outcome's typed envelope is what reaches the model
FM_TEST_END 2026-08-29T14:24:08Z tests/fm-pi-branch-live-e2e.test.sh exit=0 duration_ms=3409 gate_skip=false
```

## Focused branch behavior

The extension test was copied to a disposable `/private/tmp` tree and only the separate stock-consumer invocation was isolated so the remaining executable behavior checks could run.

Observed branch behavior includes same-text routine flood coalescing with urgent bypass, durable store-only routine outcomes, typed captain delivery, bounded searchable picker behavior, pre-drain eligibility rechecks, shutdown-safe wake replay, stale-generation side-effect suppression, nonblocking status-tail dispatch, and persisted branch model and effort pins.

The disposable focused run exited 0 and emitted these behavior assertions:

```text
ok - a captain outcome reaches main's model as typed, self-describing input while routine outcomes stay store-only
ok - Pi branch coalesces same-text routine floods and bypasses the delay for urgent work
ok - a heartbeat review survives a check row arriving before its drain
ok - pre-drain eligibility re-check excludes a newly main-owned row without deferring eligible work
ok - stale reports, shells, mirrors, cursors, leases, and prompts perform no side effects
ok - a Pi session that does not own the lock accepts nothing and mutates no branch state
ok - an extension rebind re-mirrors undelivered dialog instead of dropping it
```

## Reproducible blocker

Command: `bash tests/fm-pi-branch-extension.test.sh`.

Observed output:

```text
not ok - Pi outcomes rendering consumers must preserve stock behavior: file:///private/var/folders/3n/3wfcplrn3clf44hjjkfgq8t00000gn/T/fm-pi-branch-extension.Rvr1tz/stock-render-consumers/[eval1]:53
Error: Calm-off ToolExecutionComponent rendering differs from Pi stock
Node.js v24.19.0: expected exit 0, got 1
```

## Pi 0.84.2 documentation consistency note

The target documentation at `docs/verification/runtime-backends.md:971-977` preserves the required historical no-model live-guard limitation and names upstream fixes `#3158` and `#3261`.

The current target command above passes that no-model probe against the installed Pi 0.84.2 package, so the preserved documentation and the current live result do not agree and need a captain decision about whether the recorded failure is intentionally baseline-specific.
