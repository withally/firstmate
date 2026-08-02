# Away-mode injection wedge alarm

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into Firstmate's own pane.
`inject_wedge_alarm` raises a loud alarm through this channel for both ways a digest can fail to reach the captain, so neither stays invisible:

- **Wedged** - nothing was typed and delivery stayed deferred past `FM_MAX_DEFER_SECS`.
  The buffer is still deliverable, and the alarm re-arms at most once per max-defer window while the wedge persists.
- **Delivery uncertain** - the digest was typed and its submit could not be confirmed, so it may already have been accepted.
  Automatic retyping of that logical digest is suppressed for the rest of the away session, and this alarm fires exactly once for the digest identity the marker records.
  Being bounded per digest rather than per window, it is deliberately exempt from the marker-age throttle, so a still-fresh wedge marker cannot swallow a new incident.
  [`herdr-backend.md`](herdr-backend.md#current-transport-behavior) owns that no-retype invariant.

The active alert is pane-independent because a tmux status-line flash has no cross-backend equivalent and cannot reach an unattended captain reliably.
The durable marker and tmux flash remain as additional signals.
The ERROR log line and the active alert are additionally limited to once per max-defer window per daemon process, while the durable marker is always rewritten.

## Channels

`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive for focused testing.

- `off` disables every active alert while retaining the durable marker and tmux flash.
- `auto` or `default` resolves to `osascript` on macOS.
  Other platforms have no built-in OS channel, so configure `command:` when a durable marker alone is insufficient.
- `osascript` posts a macOS Notification Center banner outside the terminal pane.
- `herdr` calls `herdr notification show` outside the supervised pane.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alarm summary as `$1` and on stdin, allowing delivery to a phone or pager service.

An absent `config/wedge-alarm` behaves as `auto`, which is default-on on macOS.
This is deliberate because the alarm fires only after a genuine max-defer wedge or an unconfirmed submit, and each incident is bounded as described above.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without crashing the daemon loop.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, `herdr`, and the test seam.
On timeout the notifier process group is terminated and the next configured channel may run.
Daemon shutdown terminates a running notifier and starts no new active alert, so the shutdown flush cannot hold the stop path open for a timeout per channel; the durable marker carries that incident to return catch-up instead.
AppleScript receives the summary as an argv item rather than interpolated source, so summary text cannot alter the script.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Test safety

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`.
When the daemon is sourced as a library, that seam defaults to `discard`, so a test cannot accidentally post a real notification.
`tests/wake-helpers.sh` replaces it with a recorder when a suite needs to assert channel selection and summary propagation.
Production leaves the seam unset and uses the configured real channels.

`tests/fm-daemon.test.sh` covers directive parsing, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, safe `command:` summary delivery, the exactly-one delivery-uncertain alarm per logical digest, and the shutdown active-alert suppression.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the bounded manual macOS and Herdr channel proof.
