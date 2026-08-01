# Calm-mode Pi feasibility

This document owns version-scoped evidence and supported presentation boundaries for Calm.
[`calm.md`](calm.md) owns the current user-facing behavior.

## Upstream evidence

The selective port was based on current `kunchenguid/firstmate` `main` at `a805766622afb291681a15a80c5135517f1cb5ed`, read through `gh-axi` on 2026-08-01.
The latest Calm path change was PR 1356 at merge `621299ab0cc5ed307951f1d924e15a92b0978c8a`.
Only the Calm owners and narrow local integration seams are ported.
The fork's watcher, guard, away daemon, queue, dispatch, spawn, and secondmate implementations are not replaced with upstream versions.

## Baseline on this fork

Before tracked changes, `/opt/homebrew/bin/pi --version` printed `0.83.0`.
The watcher, turn-end guard, watch triage, daemon, and wake-queue test owners all passed.
`tests/fm-pi-primary-types.test.sh` skipped because no global `tsc` was found.
`tests/fm-pi-primary-live-e2e.test.sh` skipped because `FM_PI_LIVE_E2E=1` was not set.
Those skips are recorded as unverified boundaries, not passes.

## Presentation seams

The working boat uses Pi's public `setWorkingVisible()` and `setWidget()` APIs and owns no transcript or model data.
The collapsed-thinking adapter probes `AssistantMessageComponent.updateContent` and changes only the shallow presentation copy used for layout.
The operational-user-row adapter probes `InteractiveMode.addMessageToChat` and changes only the component's rendered height.
The transcript-redraw adapter probes `InteractiveMode.setToolsExpanded` and `InteractiveMode.showStatus`, the only supported seam that re-invokes already-mounted row renderers.
It re-invokes them under the caller's unchanged expansion value and suppresses just the trailing status append, which Pi implements as a permanent `chatContainer` row rather than a transient footer, while keeping its render request.
`bin/fm-operational-input.sh` owns exact U+2063 watcher and turn-end envelopes and the `0x1f` plus typed-inner-envelope away form.
`.pi/extensions/lib/fm-operational-input.ts` mirrors that owner in-process, because classification runs for every user message on Pi's chat mount path and construction feeds the two supervision-critical follow-ups; `tests/fm-operational-input.test.sh` pins the mirror against the owner on every accept and reject so the two cannot drift.
Pi's terminal input layer removes the non-printing `0x1f` before transcript layout, so the presentation parser also recognizes the exact typed inner away envelope while daemon and away-return tests continue to require `0x1f` as the injected first byte.
Quoted markers, ASCII-only markers, embedded markers, malformed envelopes, broad prose substrings, and image-bearing messages remain ordinary visible user rows.
Built-in tool hiding uses the seven built-in factories and their supported render slots.
Pi exposes no supported global renderer for arbitrary transcript rows, custom tools, images, or notices.

## Pi 0.83.0 verification record

Verification ran on 2026-08-01 with `/opt/homebrew/bin/pi --version` reporting exactly `0.83.0`.
Both records below were reproduced against the current tracked sources, after the transcript-redraw adapter, the Calm-active export and share guard, and the in-process operational-input mirror replaced their earlier implementations.

Strict installed-type command:

```sh
tests/fm-pi-primary-types.test.sh
```

Observed output:

```text
ok - Pi primary extensions pass strict no-emit typecheck against Pi 0.83.0
```

The owner used the TypeScript 5.9.3 dependency declared by the installed Pi package.
It fails closed on any `error TS` output and on any non-zero `npm exec` status, and a failed compile exits the script rather than falling through to the `ok` line, so an offline runner or unusable Node cannot report a pass the compiler never produced.

Real TUI command:

```sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```

Observed output:

```text
ok - Pi 0.83.0 live E2E toggled and persisted Calm, animated and resized the boat, hid watcher/guard/away rows, preserved wake and away semantics, exported, survived share, restored stock rendering, restarted, and cleaned up
```

The command ran twice in a row on the current sources and exited `0` both times, with no `skip:` line.
The isolated TUI run exercised Calm on and off, persisted restart state, a live resize, supported built-in tools, one bounded turn-end follow-up, one watcher wake and re-arm, an away escalation whose injected first byte remained `0x1f`, HTML export payload preservation, Pi sharing, and clean watcher-child shutdown.
It also asserted that neither the `/calm` toggle nor the `/export` and `/share` redraws leave a `Tool output:` status row in the live transcript, which is the exact string Pi 0.83.0 emits only from `showStatus` inside `setToolsExpanded`.
Each of those pane assertions runs after a settled marker turn, not immediately after the preference file changes, so it observes a painted frame instead of racing the render timer.
Pi 0.83.0 embeds export session data as base64 inside the HTML artifact, so the regression decodes that payload before asserting that hidden operational messages remain serialized.
The live share command completed and returned a Pi share URL before the test submitted its continuity prompt.

Focused deterministic owners also passed for malformed and unreadable preference fallback, atomic-write failure, stock-off presentation, boat cadence and geometry, export redraw, `Ctrl+O`, exact operational near misses, queue exactly-once delivery, and non-inheritance of `config/calm`.
The deterministic owner additionally pins that a Calm redraw re-invokes mounted rows once, requests a repaint, and appends no status row, while a stock `setToolsExpanded` outside a redraw still appends its own.

The Pi-dependent owners (`tests/fm-calm-pi-extension.test.sh`, the node checks in `tests/fm-pi-watch-extension.test.sh`, `tests/fm-pi-primary-types.test.sh`, and the live regression) mount real Pi components, so they skip cleanly where the package is absent, such as CI.
A skip is an unverified boundary, not a pass.
