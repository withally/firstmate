---
name: running-gauntlet-loops
description: >-
  Use when a crewmate must run a Gauntlet Loop or bounded quality loop inside its assigned task.
user-invocable: false
metadata:
  internal: true
---

# Running Gauntlet Loops

Matt Shumer named the Gauntlet Loop: split an ambitious artifact into independently judgeable parts, have separate builders and fresh critics compare the real work with a concrete bar, then repeat.
Loop engineering is broader; this skill is an in-task pattern.

## Set the loop card

- **Objective:** the exact outcome that must become true.
- **Metric:** inspectable evidence of improvement and success.
- **Boundary:** allowed changes, approval gates, budgets, risks, and stop conditions.

Do not use "until perfect" as a boundary.
The task brief remains authoritative.
This skill does not authorize untracked subagents; Firstmate primaries keep using fleet dispatch, and a crewmate delegates only when its brief and harness permit it.

## Run the gauntlet

Inspect the artifact and bar, then split only independently buildable and judgeable parts.
Use different fresh critics, show them the card and real artifact without the builder's explanation, and return the largest evidenced gap for a changed strategy.
Stop on success, diminishing returns, a boundary, or required human judgment; use a fresh integration critic when separate parts must work together.

## Universal Gauntlet prompt

```text
Run a Gauntlet Loop inside this assigned task.

OBJECTIVE: Create <DELIVERABLE> so that <EXACT OUTCOME>.
METRIC: Judge it against <CONCRETE REFERENCE OR MEASURABLE BAR>; success is <PASS CONDITION>.
BOUNDARY: <ALLOWED CHANGES>; stop on <TIME / COST / ATTEMPT / PERMISSION / SAFETY LIMITS>.

Choose the approach.
Split only the smallest important parts that can be built and judged independently; keep tightly coupled work with one owner.
Use separate builders and fresh-context critics only within the task's delegation authority.

Each critic must inspect the real artifact, not the builder's summary, and compare it with the bar, using blind A/B when practical.
When our result loses, name the largest evidenced gap and return it to the builder for another round with a changed strategy.

Stop when the metric passes, another round is not worth its cost, or a boundary fires.
Escalate blockers requiring human judgment.
Finish with a fresh integration critic for the complete artifact.
```

## Objective, metric, boundary card

```text
OBJECTIVE
<The exact outcome that must become true.>

INPUTS AND STATE
Inspect: <artifact, references, sources, tools, progress>.
Record each round: change, evidence, failed approach, next target, remaining budget.

METRIC
Success requires:
- <objective test, benchmark, or factual check>
- <quality rubric or direct reference comparison>
- <integration or safety check>

PROCESS
Inspect the current artifact.
Choose the highest-impact unmet criterion.
Make one coherent improvement.
Run the real verifier with a fresh critic where judgment matters.
On failure, use the evidence to change strategy and repeat.
On success, run a fresh final review.

BOUNDARY
Allowed: <read, draft, edit, test, render>.
Needs approval: <deploy, delete, spend, publish, message, use secrets>.
Stop and report on: success; <N> attempts; <TIME/COST>; repeated blocker; permission or safety limit; or required human judgment.
```
