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
`bin/fm-operational-input.sh` owns exact U+2063 watcher and turn-end envelopes and the `0x1f` plus typed-inner-envelope away form.
Quoted markers, ASCII-only markers, embedded markers, malformed envelopes, broad prose substrings, and image-bearing messages remain ordinary visible user rows.
Built-in tool hiding uses the seven built-in factories and their supported render slots.
Pi exposes no supported global renderer for arbitrary transcript rows, custom tools, images, or notices.

## Pi 0.83.0 verification record

The final implementation records the exact strict typecheck and real TUI commands and outputs here before delivery.
