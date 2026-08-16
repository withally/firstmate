---
name: lavish-review
description: >-
  Agent-only procedure for opening, updating, and arming a durable Lavish review without losing it to a disposable worktree or launching duplicate browser tabs.
user-invocable: false
metadata:
  internal: true
---

# Durable Lavish reviews

Load this skill before opening, updating, or arming a Lavish review.

Create the review at one stable path under `data/<review-id>/.lavish/<name>.html` in the effective `FM_HOME`.
If content began in a crewmate worktree or scratch directory, copy it into that durable path before opening it.
Do not open the scratch copy.

Open or re-ensure the review through the Firstmate wrapper:

```sh
bin/fm-lavish.sh open <durable-artifact.html>
```

The first successful call opens the browser and records that this exact durable artifact has been opened.
Every later call for the same artifact uses Lavish's `--no-open` path, so the existing session is re-ensured without another browser launch.

Write every revision to the same durable HTML file.
Lavish live-reloads that file in the existing tab, so an update needs no open command at all while the session is healthy.
Never create a new filename for a revision and never invoke plain `lavish-axi <file>` to show an update.

Before arming feedback, load `process-event-sources` and use its Lavish adapter command with the same durable artifact.
The open wrapper and the arming adapter both refuse temporary, scratch, and out-of-home paths before reaching Lavish or registering a poll.

[`docs/configuration.md`](../../../docs/configuration.md#durable-lavish-reviews) owns the durable-path and tab-reuse contract.
`bin/fm-lavish.sh --help` and `bin/fm-procevent-lavish.sh --help` own exact command syntax.
