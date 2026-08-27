---
name: upstream-sync
description: >-
  Agent-only checklist for the weekly catch-up of the withally/firstmate fork with kunchenguid/firstmate.
  Use when the captain asks to sync, catch up, snapshot, or rebase onto upstream, or when the weekly upstream sync is due.
  Owns the tier decision (weekly or monthly validation), the fixed worker brief, the PR verdict table, and the isolated Herdr lab setup, so the sync is a follow-the-checklist job rather than a re-authored brief.
user-invocable: false
metadata:
  internal: true
---

# upstream-sync

The procedural spine is [`docs/upstream-sync.md`](../../../docs/upstream-sync.md).
That document owns the remotes, the branch-at-upstream rule, the snapshot-commit audit window, the keep rule, and the catch-up log.
This skill does not restate it; it adds only what the standing procedure needs to run without a re-authored brief: the tier decision, the fixed worker brief, the exact commands, the PR verdict table, and the Herdr lab setup.

Standing captain rulings (2026-08-27), each implemented below:

1. The keep-list is decided by the worker under the doc's keep rule and reviewed once, at the PR, with no mid-flight captain gate.
2. Validation is two-tier: weekly runs lint plus the tests colocated with the kept diff, monthly runs the full suite including the Herdr lab.
3. Unrelated breakage found during a sync is filed as follow-up work, never fixed on the sync branch.
4. The instructions are standing: this skill and the doc, never a re-authored brief.
5. The Herdr lab setup is documented once, in [`references/herdr-lab.md`](references/herdr-lab.md).

## Firstmate intake (dispatcher)

Firstmate resolves four values and nothing else; the brief is fixed text.

1. Fetch and record the base.

   ```sh
   git remote get-url upstream >/dev/null 2>&1 || git remote add upstream git@github.com:kunchenguid/firstmate.git
   case "$(git remote get-url upstream)" in
     *kunchenguid/firstmate*) ;;
     *) echo 'blocked: upstream remote does not point at kunchenguid/firstmate'; exit 1 ;;
   esac
   git remote set-url --push upstream DISABLED
   git fetch upstream --prune && git fetch origin --prune
   UPSTREAM_BASE=$(git rev-parse --short=12 upstream/main)
   SNAPSHOT=$(git log origin/main --first-parent --grep='^chore: snapshot upstream main' -1 --format='%h')
   [ -n "$UPSTREAM_BASE" ] && [ -n "$SNAPSHOT" ] || { echo 'blocked: no upstream tip or no snapshot commit'; exit 1; }
   ```

   Run these from the firstmate code root; a fetch updates remote-tracking refs only and touches no checkout, and the worker repeats it in its own worktree.
2. Determine the tier from the `Next monthly full run` line in [`docs/upstream-sync.md`](../../../docs/upstream-sync.md).
   The sync is `monthly` when today's date is on or after that line's date and no catch-up log row already records a `monthly` tier on or after it; otherwise it is `weekly`.
   The captain set the next monthly full run to 2026-10-01 and deliberately skipped September, so a September Saturday is `weekly` even though it falls after the 1st.
   Do not ask; the line plus the log answer the question.
3. Scaffold the brief with the tier-matched flags.
   The delivery mode is `no-mistakes`, the doc's standing PR path; its Test step is intent-targeted, so it does not re-run the full suite and stays inside the weekly tier.

   ```sh
   bin/fm-brief.sh <task-id> firstmate --mode no-mistakes                # weekly, no Herdr expected
   bin/fm-brief.sh <task-id> firstmate --mode no-mistakes --herdr-lab   # weekly known to touch Herdr, or after a blocked: regeneration
   bin/fm-brief.sh <task-id> firstmate --mode no-mistakes --herdr-lab   # monthly, always
   ```

   A monthly tier always needs `--herdr-lab` because the full suite drives Herdr lifecycle behavior through the lab.
   A weekly tier normally does not; if the kept diff later turns out to select the `real-herdr-gated` family, the worker stops with `blocked: sync touches Herdr, brief needs --herdr-lab`, and Firstmate reissues the same brief with `--herdr-lab` rather than letting the worker add lab commands by hand.
   The regenerated weekly brief is what lets the worker run the Herdr family locally in step 10; regenerating it and then skipping that run leaves the lab contract unused.
4. Replace `{TASK}` with [`references/worker-brief.md`](references/worker-brief.md), filling only `UPSTREAM_BASE`, `SNAPSHOT`, `TIER`, and `DATE`.
5. Spawn per `AGENTS.md` section 7, record the sync as work under way, and supervise as usual.
6. At the PR, relay the verdict table to the captain with the full PR URL; the captain rules once at merge.
7. After the merge, refresh the clone through the guarded fleet-sync path, and when the tier was `monthly`, confirm the worker advanced the `Next monthly full run` line to the first day of the following month.

## Worker checklist

Each numbered step maps onto the same-numbered step of the doc's weekly procedure where one exists; the doc owns the rule, this list owns the command.

1. Verify isolation per the brief, bind the brief's recorded values into this shell, ensure both remotes, and confirm the recorded base still equals `upstream/main`.
   Every later step consumes `$UPSTREAM_BASE` and `$SNAPSHOT`, so bind them before anything else and keep working in the same shell; an unset `SNAPSHOT` makes step 4's range silently mean `HEAD..origin/main`, which is the over-wide set step 5 forbids.
   Compare the recorded base against `upstream/main` by resolved commit, not by abbreviation, because `--short=12` widens on ambiguity.
   The `upstream` remote setup is the doc's step 1; a clone that never ran it has `origin` only, and a clone where someone pointed `upstream` at some other fork must fail rather than record that fork's tip as the base.

   ```sh
   UPSTREAM_BASE=<UPSTREAM_BASE from the brief>
   SNAPSHOT=<SNAPSHOT from the brief>
   [ -n "$UPSTREAM_BASE" ] && [ -n "$SNAPSHOT" ] || { echo 'blocked: brief is missing UPSTREAM_BASE or SNAPSHOT'; exit 1; }
   git remote get-url upstream >/dev/null 2>&1 || git remote add upstream git@github.com:kunchenguid/firstmate.git
   case "$(git remote get-url upstream)" in
     *kunchenguid/firstmate*) ;;
     *) echo 'blocked: upstream remote does not point at kunchenguid/firstmate'; exit 1 ;;
   esac
   git remote set-url --push upstream DISABLED
   git fetch upstream --prune && git fetch origin --prune
   git rev-parse --verify --quiet "$SNAPSHOT^{commit}" >/dev/null || { echo 'blocked: SNAPSHOT is not a commit in this clone'; exit 1; }
   [ "$(git rev-parse "$UPSTREAM_BASE^{commit}" 2>/dev/null)" = "$(git rev-parse 'upstream/main^{commit}')" ] || { echo 'blocked: upstream/main moved since intake; brief needs a fresh UPSTREAM_BASE'; exit 1; }
   ```

2. Branch directly at the upstream tip.

   ```sh
   git checkout -b fm/<task-id> "$UPSTREAM_BASE"
   ```

3. Confirm the audit window from the recorded snapshot commit.
   Step 1 only proves `SNAPSHOT` is a commit in this clone; this step proves it is still the latest snapshot on `origin/main`, because another sync merging first would make the brief's value stale and widen step 4's range.

   ```sh
   git log origin/main --first-parent --grep='^chore: snapshot upstream main' -1 --format='%H %cs %s'
   [ "$(git rev-parse "$SNAPSHOT^{commit}")" = "$(git log origin/main --first-parent --grep='^chore: snapshot upstream main' -1 --format='%H')" ] || { echo 'blocked: a newer snapshot commit landed on origin/main; brief needs a fresh SNAPSHOT'; exit 1; }
   ```

4. List the fork PRs after that snapshot; this is the complete audit set.

   ```sh
   [ -n "$SNAPSHOT" ] || { echo 'blocked: SNAPSHOT unset; an empty range endpoint silently means HEAD'; exit 1; }
   git log --reverse --first-parent --format='%h%x09%cs%x09%s' "$SNAPSHOT"..origin/main
   ```

5. Never widen the set with `origin/main ^upstream/main` or the merge base; the doc explains why.
6. Compare each audited PR against current upstream by behavior, using `git show <sha>` and a search of `upstream/main` for the same change.
   Record one verdict per PR: `already-upstream` (with the upstream PR number), `superseded` (with the upstream PR number), `no-longer-needed` (with the reason), or `kept`.
7. Apply the keep rule from the doc without asking: default to upstream, keep only when current upstream lacks the behavior and the fork still has a concrete need for it.
8. Do not present the keep-list for approval; the PR verdict table is the review surface.
9. Cherry-pick each `kept` PR in order, letting upstream win every conflict.

   ```sh
   git cherry-pick -x <sha>
   # on conflict: keep upstream's architecture, wording, tests, and safety contracts; resolve; git cherry-pick --continue
   ```

   If a kept PR no longer applies meaningfully on top of upstream, downgrade its verdict to `superseded` or `no-longer-needed` and say why in the table.
10. Run the tier's validation.

    Weekly:

    ```sh
    bin/fm-lint.sh
    bin/fm-test-run.sh --changed --base "$UPSTREAM_BASE" --exclude-family real-herdr-gated
    ```

    Never hand-roll the selection from `git diff --name-only`.
    The branch starts at `UPSTREAM_BASE`, so `--changed --base "$UPSTREAM_BASE"` resolves the kept diff through `families_for_changed_path` in `bin/fm-test-run.sh`, the repo's maintained changed-file-to-test map, and a diff that maps to nothing logs `no tests selected` instead of failing the tier.
    If the run stops with `no changed-test mapping for source path: <path>`, a kept commit brought in a file the map does not know: give it a family in `families_for_changed_path`, or add it to that function's no-test exemption arm if it is pure documentation, in the same sync commit, then re-run.

    Run the `real-herdr-gated` family too only when the kept diff selects it, which the same map decides:

    ```bash
    [ -n "$UPSTREAM_BASE" ] || { echo 'blocked: UPSTREAM_BASE unset in this shell; re-bind it from the brief'; exit 1; }
    changed=$(bin/fm-test-run.sh --list --changed --base "$UPSTREAM_BASE") || { echo 'blocked: changed-test selection failed'; exit 1; }
    gated=$(bin/fm-test-run.sh --list --family real-herdr-gated) || { echo 'blocked: real-herdr-gated listing failed'; exit 1; }
    overlap=$(comm -12 \
      <(printf '%s\n' "$changed" | grep -v '^$' | sort -u) \
      <(printf '%s\n' "$gated" | grep -v '^$' | sort -u))
    ```

    Capture each list and check its status; never inline the two runs into `comm` through process substitution.
    Process substitution and the pipe into `sort` both discard the exit status, so a failed selection — an unset `UPSTREAM_BASE` in a fresh shell is the usual one — would produce empty output that reads as a clean "not Herdr-affecting" verdict.
    Do not judge this from a hand-written path list: the map also routes `bin/fm-backend.sh`, `bin/fm-afk*`, `bin/fm-supervisor-target-lib.sh`, and several install and CI files to `real-herdr-gated`.

    An empty `$overlap` means the sync is not Herdr-affecting and the weekly tier is done.
    A non-empty `$overlap` means it is, and the next move depends on the brief.
    If this brief was not scaffolded with `--herdr-lab`, stop with `blocked: sync touches Herdr, brief needs --herdr-lab` and wait for the regenerated brief; never add lab commands to a brief that declares `NOT ENABLED`.
    If it was, the lab contract is live, so run the family now:

    ```sh
    bin/fm-test-run.sh --family real-herdr-gated --fail-on-gate-skip 'herdr not found'
    ```

    See [`references/herdr-lab.md`](references/herdr-lab.md) for the preconditions that run needs.
    CI's portable shards and its required Herdr lane on the PR are the weekly full gate; do not run `--all` locally.

    Monthly:

    ```sh
    bin/fm-lint.sh
    bin/fm-test-run.sh --all --fail-on-gate-skip 'herdr not found'
    ```

    The full run includes the `real-herdr-gated` family, which needs a running default Herdr server and the lab contract from `--herdr-lab`; [`references/herdr-lab.md`](references/herdr-lab.md) owns that setup.
    `--fail-on-gate-skip` is not optional here: a gate skip is otherwise a success, so a clone without `herdr` on `PATH` would report the whole monthly suite green having run none of the Herdr lifecycle tests the tier exists to cover.
11. Treat any failure not caused by a kept commit as unrelated breakage: note it in the PR description under `Follow-ups`, and leave the code untouched on the sync branch.
    Firstmate files each one as separate work after the PR is open.
12. Ship through no-mistakes to the fork's PR path.
    Title the PR `chore: snapshot upstream main for <DATE>` so the next sync's snapshot-commit search (step 3) finds this merge.
    The PR description must contain the verdict table:

    ```markdown
    | Fork PR | Verdict | Evidence |
    | --- | --- | --- |
    | #NN | already-upstream | upstream #MMMM |
    | #NN | superseded | upstream #MMMM |
    | #NN | no-longer-needed | <reason> |
    | #NN | kept | <what upstream still lacks and why the fork needs it> |
    ```

    followed by `Tier: weekly|monthly`, the validation commands actually run, and a `Follow-ups` list (possibly empty).
    Never push to `upstream` and never merge.
13. Append the catch-up log row to `docs/upstream-sync.md` on the sync branch, recording the date, adopted base, tier, and every verdict, and on a monthly tier advance the `Next monthly full run` line to the first day of the following month.
14. Hand back with `done: PR <url> checks green` per the brief; the captain rules on the keep-list at merge.
