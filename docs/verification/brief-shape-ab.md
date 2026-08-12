# Brief-shape adopt-and-measure A/B

Audience: maintainer verification.

Status: open from 2026-08-12 until one matched pair is complete and its result is recorded here.

This record owns the one-time measurement commissioned with the four-part task shape in `bin/fm-brief.sh`.
The shape stays adopted while the measurement runs.
The measurement decides whether its wording and judgment-budget calibration need another revision.

## Matched pair

Use the next Care & Bloom direction-proof commission that can honestly be run twice against one design or reference family.
Dispatch one k3-class worker and one fable-class worker with the same project, source packet, Purpose, Authorities, The bar, Boundaries, deliverables, and rejection conditions.
Change only the judgment-budget line: the fable-class arm gets broad composition authority with no recipe, while the k3-class arm gets narrower authority bounded by the same measured anchors.
Name the tasks `<family>-brief-ab-k3` and `<family>-brief-ab-fable` so the pair is mechanically discoverable.
Do not substitute unrelated tasks, sequential implementation dependencies, or two families whose difficulty cannot be compared.
If no qualifying direction-proof commission exists by 2026-09-11, use the next pair of independent implementation slices from one feature family and record why the fallback is genuinely like-for-like.

## Counters

This record measures two separate changes, so it keeps two separately named measures in one ledger and never judges one by the other.
**SHAPE** is the headline for the four-part task shape and is made of captain corrections and rework rounds.
**ORDERING** is the headline for the single continuous no-mistakes delivery phase and is made of validation-start steers.
Mid-task steers stay recorded as shared context and decide neither measure.

Count a **captain correction** when the captain changes or adds a requirement after dispatch because the brief misstated, omitted, or ambiguously weighted it.
Do not count a planned approval decision, a new request outside the original purpose, or a choice that the judgment budget explicitly reserved for the captain.

Count a **rework round** each time a delivered result is returned for another implementation or composition pass because it fails a stated authority, rejection condition, or boundary.
Multiple findings returned together are one round; findings returned after the next delivery start another round.

Count a **mid-task steer** for each firstmate message sent after work begins and before the first delivery that is needed to make the original task succeed.
Do not count trust-dialog handling, status requests, lifecycle recovery, a reply to a worker-raised decision that the brief correctly reserved, or the worker's own no-mistakes invocation, which the new definition of done already assigns to the worker.
A firstmate message that has to start validation is never a mid-task steer; it is a validation-start steer.
A captain correction delivered as a steer counts once in each applicable counter because the counters measure different failure channels.

Count a **validation-start steer** for each firstmate message that has to tell a worker to start or resume its no-mistakes run because that worker stopped at its implementation commit instead of driving the pipeline through its CI-ready return point.
Count it under this metric alone so ORDERING stays independently falsifiable from SHAPE.
Do not count the worker's own self-started invocation, which is the behaviour under test, or a gate decision relayed into an already running pipeline.

## Historical baselines

The Mother triad (`carenbloom-mother-k3-p1`, `carenbloom-mother-fable-f1`, and `carenbloom-mother-sol-s1`) used the same 37-line task and produced three review-ready first deliveries.
Its retained artifacts do not contain an event ledger for captain corrections or mid-task steers, so this record does not invent zeroes for those counters.

The 2026-08-07 Care & Bloom codex series (`cnb-footer-motion-fix-f2`, `cnb-values-heading-v1`, `cnb-font-revert-mori-t1`, and `cnb-perf-slow-load-p1`) required four validation-start steers across four tasks because the old scaffold told each worker to stop after its implementation commit.
The same failure was still live in this home on 2026-08-12: firstmate had to send a validation-start steer on at least two further no-mistakes tasks, the composer classifier adaptation and the Care & Bloom applications relay, because each worker stopped at its implementation commit.
The ORDERING baseline is therefore `1.00 per task` across the four measured tasks, recurring on at least two later tasks, with a target of `0` for the new pair.

The sampled `toy-objectives-teaching-specificity-k3` task required eight review rounds after an under-specified eight-line task.
That is the measured SHAPE narrow-budget failure bound; the new k3-class arm must do materially better than eight rounds.

No numeric SHAPE captain-correction baseline survives in the cited sample.
Report the new pair's correction count without claiming a historical reduction, then preserve it as the baseline for the next calibration if another pair is needed.

## Runnable ledger

Run these commands from the active firstmate home before dispatching either arm.
They create private operational evidence rather than tracked project state.

```sh
FM_BRIEF_AB_LEDGER="${FM_HOME:?FM_HOME must name the active firstmate home}/data/brief-shape-ab.tsv"
if [ ! -e "$FM_BRIEF_AB_LEDGER" ]; then
  printf 'pair_id\ttask_id\tmodel_class\tmetric\tcount\tnote\n' > "$FM_BRIEF_AB_LEDGER"
fi
```

Append one row when an event occurs, using `1` as the count and a short evidence pointer as the note.

```sh
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  '<family>-brief-ab' '<task-id>' '<k3|fable>' '<captain-correction|rework-round|mid-task-steer|validation-start-steer>' '1' '<status line, steer, or review pointer>' \
  >> "$FM_BRIEF_AB_LEDGER"
```

At each task's terminal delivery, append an explicit zero row for every one of the four metrics that did not occur, including `validation-start-steer` when the worker drove its own pipeline unaided.
An absent row is missing evidence, not zero.

Summarize the pair with this command.

```sh
awk -F '\t' '
  NR == 1 { next }
  $1 == pair { totals[$3 FS $4] += $5; seen[$3 FS $4] = 1 }
  END {
    model_count = split("k3 fable", models, " ")
    metric_count = split("captain-correction rework-round mid-task-steer validation-start-steer", metrics, " ")
    measure["captain-correction"] = "SHAPE"
    measure["rework-round"] = "SHAPE"
    measure["mid-task-steer"] = "CONTEXT"
    measure["validation-start-steer"] = "ORDERING"
    for (i = 1; i <= model_count; i++) {
      for (j = 1; j <= metric_count; j++) {
        key = models[i] FS metrics[j]
        if (!seen[key]) {
          printf "MISSING\t%s\t%s\t%s\n", measure[metrics[j]], models[i], metrics[j]
        } else {
          printf "RESULT\t%s\t%s\t%s\t%d\n", measure[metrics[j]], models[i], metrics[j], totals[key]
        }
      }
    }
  }
' pair='<family>-brief-ab' "$FM_BRIEF_AB_LEDGER"
```

The run is invalid while any `MISSING` line remains, and SHAPE and ORDERING are each invalid while any `MISSING` line carries their own measure label.
Copy the eight `RESULT` lines, the two first-delivery review verdicts, the exact model and harness identities, and any comparability caveat into this record.

The ledger and summary commands were smoke-tested on 2026-08-12 with explicit zero rows for both model classes.
The summary returned:

```text
RESULT	SHAPE	k3	captain-correction	0
RESULT	SHAPE	k3	rework-round	0
RESULT	CONTEXT	k3	mid-task-steer	0
RESULT	ORDERING	k3	validation-start-steer	0
RESULT	SHAPE	fable	captain-correction	0
RESULT	SHAPE	fable	rework-round	0
RESULT	CONTEXT	fable	mid-task-steer	0
RESULT	ORDERING	fable	validation-start-steer	0
```

Removing one zero row from that smoke ledger returned `MISSING	ORDERING	fable	validation-start-steer`, so an unrecorded ORDERING result fails its own measure rather than reading as a pass.

## Decision rule

Judge each measure only on its own metrics: a failing ORDERING result never fails SHAPE, and a failing SHAPE result never fails ORDERING.

ORDERING passes when both arms record `validation-start-steer 0`, improving on the Care & Bloom baseline of one per task and on the two later steers this home needed before the change.
SHAPE passes its first trial when both arms are review-ready on first delivery, neither needs a captain correction, and the k3-class arm needs materially fewer than eight rework rounds.
If the arms diverge, keep the four-part shape but revise only the judgment-budget guidance supported by the divergence.
If the pair is not comparable or any counter is missing, record the run as invalid and repeat one matched pair rather than treating absence as success.
