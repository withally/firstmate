# Pi Calm mode

Calm is an optional Pi-only conversation-presentation toggle.
It is off by default, and the last `/calm` choice persists for the effective Firstmate home across Pi session starts and resumes.

While Calm is active and an agent run is under way, Calm hides Pi's stock `Working...` row and shows a small two-row animated boat in its place.
The boat moves one column every 880ms while the water ripples every 220ms.
It preserves position, direction, water phase, and cadence between working periods in one extension lifetime, without advancing during hidden elapsed time.
A fresh Pi session or extension lifetime resets it to the normal initial position.
Every resize recomputes and clamps its track, and narrow terminals use a deterministic smaller sprite.

Calm hides collapsed thinking labels, the shell and text-result rows for Pi's seven built-in tools, the `fm_watch_arm_pi` shell, and exactly classified Firstmate watcher, turn-end guard, and away-supervisor user rows.
Those operational inputs remain ordinary user-role messages available to the model and serialized session.
Away-mode input retains `0x1f` as its first byte and carries an exact typed inner envelope only for presentation classification.
Calm adds no separate status row: toggling, exporting, and sharing redraw the transcript in place without appending Pi's tool-expansion status line.
When Calm is off, Pi's stock working row and ordinary controlled transcript rendering return.

Calm changes presentation only.
It does not alter tool execution, message delivery, ordering, model context, session storage, diagnostics, exports, sharing, or the user's `Ctrl+O` expansion choice.
Export and share temporarily rebuild controlled rows with stock rendering, then restore Calm while preserving the prior expansion choice.

Pi exposes no supported global transcript filter.
Expanded reasoning, built-in tool images, user-bash rows, skill and summary rows, generic notices, and arbitrary extension or custom-tool rows may remain visible.

## Activation

Calm is an optional third tracked Pi extension alongside the two required supervision extensions, and it is not part of supervision-health checks.
Approving Pi's project trust prompt once per clone auto-loads every tracked `.pi/extensions/*.ts` file, including this one.
After updating Firstmate, restart Pi or run `/reload`, then run `/calm` to toggle the persisted presentation choice.
When trusted auto-load is unavailable, launch from the Firstmate repository root and add `-e .pi/extensions/fm-calm.ts` to the explicit watcher and guard launch in [`supervision-protocols/pi.md`](supervision-protocols/pi.md), only when Calm is wanted.

## Pi compatibility

Calm has no numeric Pi minimum or maximum and never refuses Pi solely because its version is newer than previously verified evidence.
Each private presentation adapter probes the exact Pi seam it patches.
If Pi removes one of those seams, Calm logs a diagnostic naming that adapter and skips only that adapter.
The `/calm` command, other Calm adapters, and unrelated Pi extensions remain available.

[`calm-mode-feasibility.md`](calm-mode-feasibility.md) owns version-scoped evidence.
[`configuration.md`](configuration.md#pi-calm-preference-configcalm) owns persistence and resolution.
