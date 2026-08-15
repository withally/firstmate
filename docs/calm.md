# Pi Calm mode

Calm is a Pi-only conversation presentation toggle.
It is off by default, and the last `/calm` choice persists for the effective Firstmate home across Pi session starts and resumes.

While Calm is active and an agent run is under way, Calm hides Pi's built-in `Working...` row and shows a small two-row animated boat in its place, and no separate Calm status row is added.
The water fills the usable width in standard ANSI blue and the complete boat is standard ANSI yellow.
The boat is deliberately calm: it moves one column every 880ms, while the water ripples on its own faster cadence so the surface stays alive between boat steps.
Its mainsail is directional, showing `<|` while travelling right and `|>` while travelling left, and it flips on the exact frame the boat turns at either edge.
Every resize reflows the sprite without wrapping, and it disappears when the run settles, aborts, or fails.
Within one Pi session and Calm extension lifetime, the next working period resumes the boat from its last rendered column and travel direction rather than restarting at the left edge.
Hidden elapsed time does not advance the animation, and a resize while hidden clamps the frozen boat to the new width without changing its valid travel direction.
A fresh Pi session or new Calm extension lifetime starts at the normal initial position.
Very narrow terminals fall back to a smaller deterministic sprite.
While Calm is off, Pi's stock working row is left exactly as Pi renders it.
Calm hides collapsed thinking labels, mid-turn assistant working notes, the shells for Pi's seven built-in tools, the `fm_watch_arm_pi` tool shell, and canonically classified Firstmate operational user rows.
A mid-turn working note is assistant text in a message whose own `stopReason` is `toolUse`, or is `length` with a tool call present.
Text remains visible while its stop reason is `pending`, because Pi cannot yet distinguish a working note from a genuine final reply.
The text is removed only from a shallow presentation copy, while the message, model context, session storage, export, and share data remain unchanged.
The operational inputs remain ordinary user-role messages, while Pi's transcript layout renders their complete rows at zero height.
Calm also hides the exact whole assistant text `Captain, shipshape.` only when the assistant component belongs to an agent run whose every Firstmate input is canonically classified operational.
A genuine captain message anywhere in that run, including one steered in while the run is still under way, keeps every later reply in the run visible.
The same text after a genuine captain message, any near match, any tool-calling response, any interrupted or failed response, and every substantive operational response remain visible.
During streaming, Calm holds only text that is still a prefix of the exact acknowledgement and renders it immediately if the stream diverges, preventing an acknowledgement flash without withholding a disambiguated reply.
A transcript replay or rebuild, including the rebuild Pi performs when it compacts inside a run, scores each replayed row against its own preceding input and leaves the surrounding run unchanged, so an acknowledgement hidden before the rebuild stays hidden after it.
The session-start nudge remains on its existing non-displayed custom-message path.

Calm changes presentation only, including when another extension owns a Pi built-in tool name.
Tool execution ownership, input delivery, ordering, model context, session storage, diagnostics, and `/export` and `/share` operation remain unchanged.
Every hidden Firstmate input remains available to the model and in serialized session data and exported artifacts.
Legacy operational custom messages remain in session data and Pi's sidebar tree, although the main HTML transcript may omit them.
Toggling Calm off restores ordinary rendering, and `Ctrl+O` expansion state is preserved.

Pi's supported presentation API does not expose a global transcript filter.
Expanded reasoning and its reserved spacing, built-in tool images, user-bash rows, skill and summary rows, generic status notices, and arbitrary custom-tool or extension rows remain visible.
These are supported-API boundaries rather than hidden-content failures.

## Pi compatibility

Calm has no numeric Pi version minimum or maximum and never refuses Pi solely because its version is newer than a previously verified version.
The collapsed-thinking, built-in-tool-row, operational-user-row, transcript-replay, and transcript-redraw presentation adapters each probe the exact Pi API seam they patch when Calm loads.
If Pi removes one of those seams, Calm logs a diagnostic naming the unavailable adapter and skips only that adapter; `/calm`, the other adapters, and unrelated Pi extensions remain available.
The transcript-redraw adapter probes its seam per session in Pi's `tui` mode only, because Pi supplies a no-op `setWidget()` outside the TUI by design; if a TUI Pi stops invoking the documented widget factory or stops exposing a forcible render, that diagnostic names the Pi version rather than silently losing the forced redraw.
Losing only the transcript-replay adapter keeps operational user rows, acknowledgement origin, and every other Calm rule active, and a rebuild inside a run then only makes more replies visible.

Pi gives each extension one complete registration slot per tool name and rejects duplicate extension registrations during initial load.
Calm therefore registers no built-in wrapper while extensions load.
When a session starts with Calm already on, or when `/calm` first turns on, Calm reads Pi's live ownership registry, claims only uncontested built-in names, leaves every foreign definition intact, and warns with each contested name.
If the ownership registry is unavailable, Calm leaves every definition unchanged and warns instead of guessing.
The built-in-tool-row adapter keeps already-mounted and replayed built-in rows controllable without changing their captured execution definition, so the Pi 0.84.1 forced-redraw guarantee survives the ownership gate.

[`calm-mode-feasibility.md`](calm-mode-feasibility.md) owns the renderer taxonomy and mechanism rationale.
[`verification/runtime-backends.md`](verification/runtime-backends.md#pi-calm-transcript-redraw) owns the current dated per-harness rendering evidence.
[`configuration.md`](configuration.md#pi-calm-preference-configcalm) owns the persisted preference file and resolution rules.
`.pi/extensions/lib/fm-calm-visibility.ts` owns the visibility policy, `.pi/extensions/lib/fm-calm-operational-user-layout.ts` owns the zero-height operational-user row, the assistant-origin association, and the separately probed transcript replay window, `.pi/extensions/lib/fm-calm-assistant-layout.ts` owns collapsed-thinking, working-note, and exact-acknowledgement layout, `.pi/extensions/fm-calm.ts` owns built-in tool registration and the already-mounted row adapter, and `.pi/extensions/lib/fm-calm-working-ship.ts` owns the animated working presentation.

Regression entry points:

```sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-primary-types.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_PI_LIVE_E2E=1 FM_PI_CALM_LIVE_ONLY=1 tests/fm-pi-primary-live-e2e.test.sh
```
