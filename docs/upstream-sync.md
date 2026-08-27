# Upstream sync

This repository is the `withally/firstmate` fork of the canonical parent at `kunchenguid/firstmate`.
The fork contributes changes upstream and stays close to the parent by adopting `upstream/main` wholesale, then carrying only the smallest behaviorally necessary local delta.

## Weekly procedure

1. Fetch both remotes and record the exact `upstream/main` commit that will become the new base.
2. Create the sync branch directly at that upstream commit.
   Do not merge `origin/main` into it and do not start from the fork's divergent tip.
3. Locate the most recent full catch-up on `origin/main` by finding the latest first-parent commit whose subject starts with `chore: snapshot upstream main`.

   ```sh
   git log origin/main --first-parent --grep='^chore: snapshot upstream main' -1 --format='%H %cs %s'
   ```

4. Audit only the fork PRs after that catch-up commit.

   ```sh
   git log --reverse --first-parent --format='%h%x09%cs%x09%s' <catch-up-commit>..origin/main
   ```

5. Do not derive the audit set from `origin/main ^upstream/main` or from the merge base.
   Those ranges overcount older fork commits that a prior snapshot already reconciled and that current upstream has since absorbed or superseded.
6. Compare each post-catch-up PR by behavior and current content, not by commit hash alone.
   Classify it as already upstream, superseded, no longer needed, or genuinely still local.
7. Default to upstream.
   Keep a local behavior only when current upstream lacks it and the fork still has a concrete need for it.
8. Decide the keep-list by that rule without a mid-flight captain gate.
   Every audited PR and its verdict (already-upstream, superseded, no-longer-needed, or kept) goes in a table in the PR description, and the captain rules once at merge.
9. Re-apply only the kept behaviors on top of the recorded upstream base.
   Resolve conflicts in favor of upstream and preserve newer upstream architecture, wording, tests, and safety contracts.
10. Validate by tier, then ship through no-mistakes to the fork's PR path.
    A weekly sync runs `bin/fm-lint.sh` plus only the test files colocated with the files the kept commits touch, derived from the diff of the kept commits against the upstream base; Herdr lifecycle tests run only when a kept commit touches the Herdr backend or lab code; CI's portable shards on the PR are the full gate.
    A monthly sync, the first sync on or after the 1st of a month named by the `Next monthly full run` line below, runs the full `bin/fm-test-run.sh` suite locally, including the Herdr lab.
    Unrelated breakage found during either tier is noted in the PR and filed as separate follow-up work, never fixed on the sync branch.
    The `upstream-sync` skill owns the exact commands, the tier decision, the worker brief, and the Herdr lab setup.
    Never push to the canonical upstream remote and never merge without explicit captain approval.
11. Append one row to the catch-up log below.
    Record the date, adopted base, tier, post-catch-up PR audit set, and final verdict for every audited PR.
    After a monthly sync, advance the `Next monthly full run` line to the first day of the following month.

Next monthly full run: 2026-10-01 (set by the captain on 2026-08-27; September is deliberately skipped).

## Catch-up log

Append one row after every weekly catch-up.
Do not rewrite an older row merely because upstream later absorbs one of its retained changes.

| Catch-up date | Catch-up commit or adopted upstream base | Tier | Local PR interval and final verdict |
| --- | --- | --- | --- |
| 2026-08-22 | `9e0374a` (`#65`, `chore: snapshot upstream main for 2026-08-22`) | full | Established the full-catch-up boundary. The local PRs that followed were #66 through #76, adjudicated in the next row. |
| 2026-08-27 | `d63b0e2` (`upstream/main`) | full (predates the two-tier rule) | PRs following `9e0374a`: #66 dropped because upstream #2846 already carries it; #67 kept; #68 kept; #69 kept; #70 kept; #71 kept; #72 kept; #73 kept; #74 superseded by upstream #2953 and #3093; #75 kept; #76 superseded by upstream #2953 and #3093. |
