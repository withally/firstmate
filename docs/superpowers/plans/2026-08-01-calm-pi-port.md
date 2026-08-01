# Pi Calm Mode Selective Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the approved optional Pi-only `/calm` presentation toggle without changing this fork's supervision, delivery, queue, away-mode, dispatch, or secondmate semantics.

**Architecture:** The Calm extension owns persistence, built-in renderer wrappers, export redraws, collapsed-thinking layout, and the working boat.
An exact shared operational envelope identifies only Firstmate-produced rows, while the local watcher, guard, and away-mode paths keep their existing bodies, roles, ordering, counts, and authority.
Each unsupported Pi layout seam probes and degrades independently with a named diagnostic.

**Tech Stack:** Pi extension TypeScript, Bash 3.2-compatible protocol helpers, shell test owners, Pi 0.83.0 declarations and TUI.

---

## File ownership

- Create `.pi/extensions/fm-calm.ts` as the sole toggle, preference, working-row, built-in-renderer, and export-redraw owner.
- Create `.pi/extensions/lib/fm-calm-visibility.ts` as the sole transcript-class visibility owner.
- Create `.pi/extensions/lib/fm-calm-assistant-layout.ts` as the independently probed collapsed-thinking layout adapter.
- Create `.pi/extensions/lib/fm-calm-working-ship.ts` as the deterministic boat geometry, cadence, continuity, resize, and widget owner.
- Create `.pi/extensions/lib/fm-calm-operational-user-layout.ts` as the independently probed zero-height operational-user-row adapter.
- Create `.pi/extensions/lib/fm-operational-input.ts` as the thin TypeScript adapter over the shell protocol owner.
- Create `bin/fm-operational-input.sh` as the single exact envelope constructor and parser.
- Modify `.pi/extensions/fm-primary-pi-watch.ts` only for exact operational encoding and Calm-aware render slots.
- Modify `.pi/extensions/fm-primary-turnend-guard.ts` only for exact operational encoding.
- Modify `bin/fm-supervise-daemon.sh` only to place the exact operational envelope after the existing leading `0x1f` away sentinel and to strip it before semantic delivery.
- Modify `.gitignore`, `README.md`, `docs/configuration.md`, and `docs/supervision-protocols/pi.md` for optional activation and test inventory.
- Create or extend only the focused owners under `tests/` for Calm, operational input, watcher, guard, daemon, queue, config inheritance, Pi types, and live Pi behavior.
- Do not change watcher child lifecycle, arm policy, wake queue code, pause or stale classification, dispatch selection, spawn behavior, secondmate launch behavior, or inherited-config lists.

## Baseline evidence

- Pi reports exactly `0.83.0` from `/opt/homebrew/bin/pi --version`.
- `tests/fm-pi-watch-extension.test.sh`, `tests/fm-turnend-guard.test.sh`, `tests/fm-watch-triage.test.sh`, `tests/fm-daemon.test.sh`, and `tests/fm-wake-queue.test.sh` passed before tracked changes.
- The baseline type owner reported `skip: tsc not found for Pi extension typecheck`, so type compatibility is unverified until this plan supplies a non-skipping Pi-local compiler path.
- The baseline live owner reported `skip: set FM_PI_LIVE_E2E=1 to run the isolated interactive Pi regression`, so live behavior is unverified until the opt-in run completes.
- Current upstream evidence was read through `gh-axi` at `a805766622afb291681a15a80c5135517f1cb5ed`, with the latest Calm path change at merge `621299ab0cc5ed307951f1d924e15a92b0978c8a`.

### Task 1: Freeze the approved design and baseline

**Files:**

- Create: `docs/superpowers/plans/2026-08-01-calm-pi-port.md`

- [ ] **Step 1: Record the exact baseline commands and outcomes above.**

Run:

```sh
/opt/homebrew/bin/pi --version
tests/fm-pi-watch-extension.test.sh
tests/fm-turnend-guard.test.sh
tests/fm-watch-triage.test.sh
tests/fm-daemon.test.sh
tests/fm-wake-queue.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-pi-primary-live-e2e.test.sh
```

Expected: the five protected owners pass, Pi reports `0.83.0`, and the two Pi compatibility owners explicitly report their baseline skip boundaries.

- [ ] **Step 2: Self-review this plan.**

Run:

```sh
rg -n '[T]BD|[T]ODO|implement[ ]later|fill[ ]in|appropriate[ ]error|similar[ ]to' docs/superpowers/plans/2026-08-01-calm-pi-port.md
git diff --check
```

Expected: no placeholder matches and no whitespace errors.

- [ ] **Step 3: Commit the evidence-only rollback boundary.**

```sh
git add docs/superpowers/plans/2026-08-01-calm-pi-port.md
git commit -m "docs: plan selective Pi Calm port"
```

### Task 2: Add the isolated Calm presentation core

**Files:**

- Create: `.pi/extensions/fm-calm.ts`
- Create: `.pi/extensions/lib/fm-calm-visibility.ts`
- Create: `.pi/extensions/lib/fm-calm-assistant-layout.ts`
- Create: `.pi/extensions/lib/fm-calm-working-ship.ts`
- Create: `tests/fm-calm-pi-extension.test.sh`
- Modify: `.gitignore`
- Modify: `docs/configuration.md`
- Create: `docs/calm.md`
- Create: `docs/calm-mode-feasibility.md`

- [ ] **Step 1: Write focused tests before production files exist.**

The tests must instantiate the real extension against deterministic Pi-compatible fixtures and assert:

```text
absent, unreadable, malformed => off
/calm writes on\n or off\n atomically before live state changes
rename or write failure leaves live state and prior preference unchanged
off => stock built-in rows and stock Working row
on => hidden supported built-in rows and collapsed-thinking zero geometry
boat => 220ms water, 880ms movement, bounce heading, freeze/resume continuity
resize => exact width with clamped valid direction
narrow width => deterministic one-row fallback
export/share => temporary stock render then redraw
Ctrl+O => original expansion state restored
missing layout seam => named adapter diagnostic and remaining Calm behavior available
```

- [ ] **Step 2: Run the focused test and verify RED.**

Run: `tests/fm-calm-pi-extension.test.sh`.

Expected: FAIL because `.pi/extensions/fm-calm.ts` and its helpers do not exist.

- [ ] **Step 3: Add the minimal presentation core and preference contract.**

Use the approved upstream owners at current `main` and preserve this state transition order:

```ts
persistCalmPreference(next);
setCalmPresentation(next);
publishPresentationState();
applyWorkingPresentation(ctx.ui, true);
```

The preference path is `FM_CONFIG_OVERRIDE`, otherwise `FM_HOME`, otherwise `FM_ROOT_OVERRIDE`, otherwise the tracked root.
The file accepts only exact trimmed `on` as enabled and otherwise defaults off.
The write uses a mode `0600` exclusive temporary file plus same-directory rename and guaranteed temporary cleanup.

- [ ] **Step 4: Run the focused test and verify GREEN.**

Run: `tests/fm-calm-pi-extension.test.sh`.

Expected: all isolated persistence, layout, rendering, lifecycle, export, and degradation assertions pass.

- [ ] **Step 5: Commit the additive core rollback boundary.**

```sh
git add .gitignore .pi/extensions/fm-calm.ts .pi/extensions/lib/fm-calm-visibility.ts .pi/extensions/lib/fm-calm-assistant-layout.ts .pi/extensions/lib/fm-calm-working-ship.ts tests/fm-calm-pi-extension.test.sh docs/calm.md docs/calm-mode-feasibility.md docs/configuration.md
git commit -m "feat(pi): add isolated Calm presentation core"
```

### Task 3: Integrate the watcher presentation only

**Files:**

- Modify: `.pi/extensions/fm-primary-pi-watch.ts`
- Modify: `tests/fm-pi-watch-extension.test.sh`

- [ ] **Step 1: Add failing watcher renderer tests.**

Assert the same `execute()` result, one child, one wake, and one queue record with Calm on and off.
Assert `renderCall` and `renderResult` return zero-height `Container` instances only when Calm is active and not exporting.
Assert export rendering uses the same text as stock presentation.

- [ ] **Step 2: Run the watcher owner and verify RED.**

Run: `tests/fm-pi-watch-extension.test.sh`.

Expected: FAIL because the local tool has no `renderShell`, `renderCall`, `renderResult`, or Calm event state.

- [ ] **Step 3: Add only the narrow render integration.**

Subscribe to `FIRSTMATE_CALM_PRESENTATION_EVENT`, retain the event state locally, set `renderShell: "self"`, and wrap only the call and result render slots.
Do not modify `startArm`, child cleanup, sequence numbering, lock ownership, wake delivery, retry behavior, or tool execution.

- [ ] **Step 4: Run watcher and queue owners and verify GREEN.**

Run:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-wake-queue.test.sh
```

Expected: all assertions pass and two atomic drains still cannot consume one record twice.

- [ ] **Step 5: Commit the watcher rollback boundary.**

```sh
git add .pi/extensions/fm-primary-pi-watch.ts tests/fm-pi-watch-extension.test.sh
git commit -m "feat(pi): hide watcher tool rows in Calm"
```

### Task 4: Add exact operational-row classification

**Files:**

- Create: `bin/fm-operational-input.sh`
- Create: `.pi/extensions/lib/fm-operational-input.ts`
- Create: `.pi/extensions/lib/fm-calm-operational-user-layout.ts`
- Create: `tests/fm-operational-input.test.sh`
- Modify: `.pi/extensions/fm-calm.ts`
- Modify: `.pi/extensions/fm-primary-pi-watch.ts`
- Modify: `.pi/extensions/fm-primary-turnend-guard.ts`
- Modify: `bin/fm-supervise-daemon.sh`
- Modify: `tests/fm-pi-watch-extension.test.sh`
- Modify: `tests/fm-turnend-guard.test.sh`
- Modify: `tests/fm-daemon.test.sh`

- [ ] **Step 1: Write the exact protocol and row-geometry tests first.**

The current generic envelope is exact U+2063 plus `FIRSTMATE_OP: v1 <kind>: <body>` for watcher and turn-end guard.
The away form is exact leading `0x1f` plus an inner current `away-supervisor` envelope, so the sentinel remains the first byte.
Near misses with quoted markers, ASCII-only labels, prefixed prose, invalid kinds, empty bodies, images, or broad watcher and supervisor substrings remain genuine visible user rows.

- [ ] **Step 2: Run protocol, watcher, guard, and daemon owners and verify RED.**

Run:

```sh
tests/fm-operational-input.test.sh
tests/fm-pi-watch-extension.test.sh
tests/fm-turnend-guard.test.sh
tests/fm-daemon.test.sh
```

Expected: FAIL because the exact owner, producers, and zero-height adapter do not exist.

- [ ] **Step 3: Implement exact construction and presentation-only classification.**

The TypeScript adapter shells out only to the canonical Bash parser.
The layout adapter patches only `InteractiveMode.addMessageToChat`, preserves user role, content, history, model input, storage, and ordering, and changes only `render()` height.
The watcher and guard encode their existing bodies before the same `sendUserMessage(..., { deliverAs: "followUp" })` calls.
The daemon preserves `0x1f` byte zero, adds the exact inner envelope, and strips both markers only at the existing semantic-return boundary.

- [ ] **Step 4: Run all protected owners and verify GREEN.**

Run:

```sh
tests/fm-operational-input.test.sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-watch-extension.test.sh
tests/fm-turnend-guard.test.sh
tests/fm-daemon.test.sh
tests/fm-wake-queue.test.sh
tests/fm-watch-triage.test.sh
```

Expected: one watcher wake delivers once and queues once, one guard follow-up stays bounded, away injection keeps leading `0x1f` and remains model-readable without exiting away mode, and queue drain remains exactly once.

- [ ] **Step 5: Commit the protocol rollback boundary.**

```sh
git add bin/fm-operational-input.sh .pi/extensions/lib/fm-operational-input.ts .pi/extensions/lib/fm-calm-operational-user-layout.ts .pi/extensions/fm-calm.ts .pi/extensions/fm-primary-pi-watch.ts .pi/extensions/fm-primary-turnend-guard.ts bin/fm-supervise-daemon.sh tests/fm-operational-input.test.sh tests/fm-pi-watch-extension.test.sh tests/fm-turnend-guard.test.sh tests/fm-daemon.test.sh
git commit -m "feat(pi): classify exact Calm operational rows"
```

### Task 5: Activate optionally and prove Pi 0.83.0

**Files:**

- Modify: `README.md`
- Modify: `docs/supervision-protocols/pi.md`
- Modify: `docs/calm-mode-feasibility.md`
- Modify: `tests/fm-pi-primary-types.test.sh`
- Modify: `tests/fm-pi-primary-live-e2e.test.sh`
- Modify: `tests/fm-secondmate-harness.test.sh` as the existing config-inheritance owner.

- [ ] **Step 1: Add failing activation, type-fixture, live-flow, and non-inheritance assertions.**

The type fixture must copy all Calm imports and invoke Pi 0.83.0's own TypeScript compiler dependency rather than skipping when global `tsc` is absent.
The live fixture must explicitly load Calm alongside the two required supervision extensions and exercise on, off, restart or reload, resize, watcher wake, one turn-end follow-up, away escalation where supported, export, and share.
The config inheritance test must prove `config/calm` is neither copied nor removed in secondmate homes.

- [ ] **Step 2: Run the new assertions and verify RED.**

Run:

```sh
tests/fm-pi-primary-types.test.sh
tests/fm-pi-primary-live-e2e.test.sh
tests/fm-secondmate-harness.test.sh
```

Expected: type or fixture assertions fail until Calm files and optional activation wiring are included, while the live owner remains explicitly opt-in without the environment flag.

- [ ] **Step 3: Add optional activation docs and fixture wiring.**

Document trusted auto-load, Pi reload or restart, `/calm`, and the optional explicit `-e <root>/.pi/extensions/fm-calm.ts` path.
Keep watcher and turn-end guard as the only required session-health extensions.
Do not add `config/calm` to `bin/fm-config-inherit-lib.sh` or any secondmate launch.

- [ ] **Step 4: Run empirical Pi 0.83.0 verification.**

Run:

```sh
tests/fm-pi-primary-types.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```

Expected: strict no-emit typecheck names Pi `0.83.0`, and the real TUI owner reports the exercised Calm and supervision behaviors without a skip.

- [ ] **Step 5: Run the complete practical suite and shell lint.**

Run:

```sh
for test_file in tests/*.test.sh; do "$test_file"; done
shellcheck bin/*.sh bin/backends/*.sh tests/*.sh
git diff --check
```

Expected: all practical tests and shellcheck pass with no skipped required Pi type or live evidence.

- [ ] **Step 6: Record exact empirical facts and commit the final rollback boundary.**

Add the date, exact Pi version, exact commands, exact outputs, and supported seam results to `docs/calm-mode-feasibility.md`.

```sh
git add README.md docs/supervision-protocols/pi.md docs/calm-mode-feasibility.md tests/fm-pi-primary-types.test.sh tests/fm-pi-primary-live-e2e.test.sh tests/fm-secondmate-harness.test.sh
git commit -m "docs(pi): verify Calm on Pi 0.83.0"
```

### Task 6: Validate and deliver one focused PR

- [ ] **Step 1: Ensure project instructions remain durable without duplicating the Calm contract.**

Run: `/Users/ivan/Projects/firstmate/bin/fm-ensure-agents-md.sh .`.

Expected: existing `AGENTS.md` remains authoritative and no broad Calm restatement is added.

- [ ] **Step 2: Run the no-mistakes pipeline and respond only through its gates.**

Run: `no-mistakes axi run --help`, then start the version-matched pipeline without `--yes`.

Expected: CI-ready green with all pipeline-applied fixes committed.

- [ ] **Step 3: Push only `fm/calm-pi-port-h4` and open one PR to `withally/firstmate`.**

The PR body must explain that an untracked local extension would not survive updates or provide shared tests and docs.
It must list preserved watcher, guard, arm-seatbelt, queue, stale/pause, away-sentinel, submission, dispatch, quota, secondmate, and authority contracts.
It must summarize exact Pi 0.83.0 evidence and state the activation path: update, restart or reload Pi, then run `/calm`.

Expected: exactly one focused unmerged PR targeting the fork's default branch.
