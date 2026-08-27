# Worker brief template

Firstmate scaffolds with `bin/fm-brief.sh <task-id> firstmate --mode no-mistakes`, adding `--herdr-lab` when the tier is `monthly` or the sync is already known to touch Herdr backend or lab code, and replaces `{TASK}` with the block below.
Fill exactly five values; every other line is fixed text.

| Placeholder | Value |
| --- | --- |
| `UPSTREAM_BASE` | `git rev-parse --short=12 upstream/main` at intake |
| `SNAPSHOT` | short hash of the latest `chore: snapshot upstream main` first-parent commit on `origin/main`, or the last adjudicated fork commit when a newer catch-up log row names one; take it from the skill's intake command block, not by hand |
| `SETTLED` | last adjudicated fork commit from the newest catch-up log row, empty when no row names one; the worker cannot re-derive it after branching at `upstream/main` |
| `TIER` | `weekly` or `monthly`, from the skill's tier rule |
| `DATE` | the sync date, `YYYY-MM-DD` |

```markdown
## Task: weekly upstream sync of withally/firstmate onto kunchenguid/firstmate

This is SHARED TRACKED firstmate material: load `firstmate-coding-guidelines` before editing anything.
Then load `upstream-sync` and follow its "Worker checklist" step by step; it owns every command.
`docs/upstream-sync.md` owns the rules those commands implement.

Recorded values:

- UPSTREAM_BASE: `{UPSTREAM_BASE}`
- SNAPSHOT: `{SNAPSHOT}`
- SETTLED: `{SETTLED}`
- TIER: `{TIER}`
- DATE: `{DATE}`

Fixed rules:

- Bind UPSTREAM_BASE, SNAPSHOT, and SETTLED as shell variables from the recorded values above before running any checklist command, and stop if UPSTREAM_BASE or SNAPSHOT is empty.
- Branch at UPSTREAM_BASE; never merge origin/main into it.
- Audit only the first-parent commits in SNAPSHOT..origin/main.
- Decide every keep by the doc's keep rule yourself; no mid-flight approval.
- Cherry-pick kept PRs with `-x`; upstream wins every conflict.
- Run only the TIER's validation from the skill; CI's portable shards and its required Herdr lane on the PR are the weekly full gate.
- Unrelated breakage is a `Follow-ups` entry in the PR, never a fix on this branch.
- If the kept diff selects the `real-herdr-gated` family per the skill's `comm -12` check against `bin/fm-test-run.sh --list`, and this brief was not scaffolded with `--herdr-lab`, stop with `blocked: sync touches Herdr, brief needs --herdr-lab` and wait.
- If that check selects the family and this brief does carry the lab contract, run the family locally per the skill's step 10; do not block a second time.
- PR title: `chore: snapshot upstream main for {DATE}`; PR body carries the verdict table, `Tier: {TIER}`, the validation commands run, and `Follow-ups`.
- Append the catch-up log row; on a monthly tier advance the `Next monthly full run` line.
- Never push to `upstream`; never merge.
```
