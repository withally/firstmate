# CI trigger reliability verification

Audience: maintainer verification.

This record supports the `on:` triggers and `concurrency` group in `.github/workflows/ci.yml`.
It records only the facts that must be re-established when GitHub's event delivery or the no-mistakes PR-creation flow changes.
Task chronology and incident transcripts stay in private reports or PR evidence.

## The guarantee

Every firstmate PR head that should run CI gets a CI run without a manual empty-commit re-trigger.
CI reaches that head through the reliable git-push webhook, not only through the `pull_request` `opened`/`reopened` events.

## Why the push trigger is load-bearing

A no-mistakes PR arrives as a rapid push + open + amend/force-push (and sometimes an automated close/reopen) sequence.
GitHub intermittently creates zero workflow runs for the `pull_request` `opened` and `reopened` events in that flow, and the drop hits every `pull_request`-triggered workflow equally, so only the git push that raises `synchronize` fires reliably.

Confirmed 2026-08-14 against PR 30 (`withally/firstmate`, branch `fm/fm-watcher-lock-test-flake-f1`).
The `opened` head `e5005ca6` and the 06:54:28Z `reopened` event each produced zero runs for both `CI` (ci.yml) and `Require no-mistakes` (no-mistakes-required.yml); the automated close/reopen one second apart was a failed re-trigger.
Only the git-push (`synchronize`) events created runs:

```
2026-08-14T06:56:14Z | CI  | ev=pull_request(synchronize) | sha=50bd34ae | failure
2026-08-14T06:56:14Z | NMR | ev=pull_request(synchronize) | sha=50bd34ae | success
2026-08-14T08:06:35Z | CI  | ev=pull_request(synchronize) | sha=92580121 | success
2026-08-14T08:06:35Z | NMR | ev=pull_request(synchronize) | sha=92580121 | success
```

Because the drop is at the GitHub event-delivery level, no `pull_request`-only config change removes it.
The fix triggers CI on the working-branch push (`push: branches: ['fm/**']`), which rides the same reliable webhook as `synchronize`, so the head is validated even when its `opened`/`reopened` runs are dropped.
`no-mistakes-required.yml` needs the pull request body and cannot run on `push`; it stays on `pull_request` and recovers on the same reliable `synchronize`, so the required-signature gate is unchanged.

## Why it does not double-run or weaken main coverage

The `concurrency` group collapses the `push` run and the `pull_request` run for the same feature-branch head into one run, and supersedes an in-flight feature-branch run when a newer commit is pushed.
`main` pushes resolve to a unique per-commit group (`ci-<sha>`), so every landed commit is still validated on its own exactly as before.

## How to re-verify

For a recent `fm/**` PR, confirm its head has a CI run and inspect the triggering events.
The push trigger is working when a `fm/**` head has a `CI` run under the `push` event (or has a `CI` run at all even when its `opened` event produced none):

```
gh-axi api "repos/withally/firstmate/actions/runs?head_sha=<HEAD_SHA>" \
  --jq '.workflow_runs[] | "\(.name) | ev=\(.event) | \(.conclusion)"'
```

A head that shows zero `CI` runs after a completed no-mistakes run is a regression of this guarantee.
