# Does the opt-in live regression fail before the fix?

Yes, after the round-2 redesign of `tests/fm-pi-clear-on-shrink-live-e2e.test.sh` (commit 7c0f004).

Probe: a copy of the shipped test was run against real Pi 0.84.2 changing only the launched value of
`PI_CLEAR_ON_SHRINK` (`1` = post-fix launch env, `0` = pre-fix launch env; Pi compares strictly to `"1"`).
The test grows the render with a wrapped composer draft over a transcript that is already taller than the
pane, clears the draft, waits for the viewport to settle, and asserts no blank region is left below the
last rendered row.

    PI_CLEAR_ON_SHRINK=0 -> not ok - pre-compaction shrink left a 9-row empty region below the last rendered row   (3/3 runs)
    PI_CLEAR_ON_SHRINK=1 -> ok - Pi 0.84.2 regular TUI leaves no stale rows when the render shrinks, before and after compaction   (4/4 runs)

Artifacts:

- `pi-clear-on-shrink-panes.png` / `.html` - side-by-side of the two real tmux viewports at the shrink
  assertion point; the pre-fix pane shows the empty black region under the footer.
- `pane-clear-on-shrink-{0,1}/pre-compaction-shrink.txt` - raw `tmux capture-pane` text behind that image.
- `live-e2e-clear-on-shrink-{0,1}.log` - the two test runs.
- `pi-clear-on-shrink-settings.png` - the launch env really flips Pi's own `terminal.clearOnShrink`, and an
  explicit `settings.json` value still overrides it.

## Superseded round-1 finding

The earlier version of this live test asserted only on blank rows *above* the next visible content after a
Ctrl+O collapse. That assertion passed identically with `PI_CLEAR_ON_SHRINK` set to `0` and `1`, so it guarded
nothing. The captures from that probe remain here as
`pane-clearonshrink-{0,1}-{pre,post}-compaction-collapse.txt` and `collapse-immediate-clearonshrink-{0,1}.txt`.
