# GSD method in Firstmate

This document is Firstmate's adaptation of the GSD method from [open-gsd/gsd-core](https://github.com/open-gsd/gsd-core): the approach without the tool.
It is a running document: the rules above the log are the current contract, and the dated log at the bottom is the evidence that shaped them.

## 1. Purpose

Phase-sized builds fail in one recurring way: a fact is assumed, never checked, and a subsystem that an engine already provides gets hand-rolled on top of that assumption.
The GSD method's research-first discipline catches that failure before code exists, and Blockvalley Phase 0 proved it does (see the log).

Why not the tool: gsd-core ships an installer, `/gsd-*` slash commands, `STATE.md` and milestone/phase file bookkeeping, git hooks that prompt the user, and an executor framework that runs plans in parallel fresh-context waves.
Firstmate already provides each of those needs differently - the backlog, generated briefs, scouts and ship workers in isolated worktrees, keyed check-ins, captain-held tasks, and guarded merges - so installing the tool would add a second orchestrator beside the one this repo is.
The captain's ruling is explicit: "GSD is a method here, not a tool: no gsd-core, no gsd-pi, no extra hooks."
Section 6 names, for every dropped piece, the Firstmate piece that covers it.

## 2. When it applies

- Use the method for phase-sized builds: a new subsystem, an engine or runtime choice, or a multi-week slice whose shape is not yet known.
- Do not use it for bug fixes, one-file features, or clearly specified changes; those take the ordinary ship path in `AGENTS.md` section 7.
- The test is uncertainty that could materially change whether or what to build; that is the same threshold section 7 uses to justify a scout over a ship.

## 3. The six kept parts

Each part is stated as the rule, the Firstmate mechanism that enforces it, and the artifact with its owner.
The mechanisms are referenced, not restated; their owners are `AGENTS.md` sections 7 and 10, `bin/fm-brief.sh --help`, and `.agents/skills/captain-hold-lifecycle/SKILL.md`.

### 3.1 Research before planning

- Rule: every phase starts with research in fresh-context researchers, one per stream, and one synthesizer that reads the researcher reports plus the authoritative CONTEXT/rulings document, nothing else.
- Mechanism: each researcher and the synthesizer is a scout spawned from a `bin/fm-brief.sh --scout` brief in its own worktree, so no researcher inherits another's context or the planner's sunk cost.
- Artifact and owner: each researcher leaves one `data/<task>/report.md`, and the synthesizer scout's single `data/<task>/report.md` is the durable synthesis artifact; the Blockvalley `RESEARCH-0.md` was a verbatim copy of that report, and the governing firstmate or secondmate owns the phase plan that names the streams.

### 3.2 Claim provenance

- Rule: every factual claim in research and plans carries `[VERIFIED: source]`, `[CITED: url]`, or `[ASSUMED]`, and an ASSUMED claim never becomes a locked decision without the captain's word.
- Rule detail: an API or engine capability is VERIFIED only by official documentation read that session or a working probe; a blog post or training memory is ASSUMED.
- Mechanism: the plan-check fails a load-bearing claim whose tag is false, and every ASSUMED item that gates the build is registered as a captain-held task through `captain-hold-lifecycle` before the research or plan is treated as complete.
- Artifact and owner: the provenance tags live in the report or plan that makes the claim; the held task in the owning home's backlog carries the captain's answer, closed only with his actual words.

### 3.3 The CONTEXT document

- Rule: research is bounded by one document of locked decisions, discretion areas, and deferred ideas, and researchers investigate the locked decisions rather than alternatives to them.
- Mechanism: Firstmate already has this document as the captain's rulings files, written by the governing firstmate from confirmed captain answers and quoted verbatim into every brief, because rules a task depends on go inline in the brief.
- Artifact and owner: a dated rulings file under `data/` (for example a `UX-RULINGS` file or the phase plan's CONTEXT section); the governing firstmate or secondmate owns it and the captain owns its locked entries.

### 3.4 The Don't-Hand-Roll list

- Rule: research names the problems that must use an engine or library rather than custom code, and a plan that hand-rolls one of them fails plan-check.
- Mechanism: the plan-check brief carries the list as a mandatory dimension, and the ship brief for each execution task carries the entries that task touches.
- Artifact and owner: a `Don't Hand-Roll` section in the synthesis document, owned by the synthesizer and frozen by the captain's engine ruling.

### 3.5 Prescriptive research output

- Rule: the synthesizer's report says "use X", never "consider X or Y", and a survey without a recommendation is an incomplete deliverable.
- Mechanism: the synthesizer's scout brief fixes the output sections in order, with a single-stack recommendation and a scorecard with provenance, so a report without them fails its definition of done.
- Artifact and owner: the synthesizer scout's single `data/<task>/report.md` carries the Recommendation section, owned by the synthesizer; the captain rules on it as one decision with the ASSUMED list attached.

### 3.6 Plan-check before any code

- Rule: no execution task is dispatched from a plan that has not passed one adversarial plan-check whose only question is whether the plan is executable as written.
- Mechanism: the plan-check is a separate scout with its own brief, its verdict is BLOCKER or WARNING per finding, and the governing firstmate refuses dispatch on an unchecked plan; `AGENTS.md` section 7 already treats a report as evidence, not authorization.
- Artifact and owner: `data/<plancheck-task>/report.md` with a verdict, a finding table, and an explicit dispatch judgment, owned by the checker.

## 4. The plan cycle and its hard cap

- The cycle is WRITE once, CHECK once, PATCH once.
- WRITE: the synthesizer produces the phase plan from the research and the CONTEXT document.
- CHECK: one adversarial plan-check returns BLOCKER and WARNING findings with a concrete fix per finding.
- PATCH: one scoped patch applies exactly the named fixes and nothing else, and the checker re-verifies the changed lines, the new claims, and every untouched section that consumes a changed contract.
- If blockers remain after the patch, the governing secondmate stops and posts one keyed check-in to the parent firstmate with the remaining blockers and two options.
- No second rewrite happens on the worker's or the secondmate's own authority; the parent firstmate decides between the options or escalates to the captain.
- A gate that depends only on already-closed findings may be dispatched while an unrelated blocker is escalated, when the checker's dispatch judgment says so explicitly.

Roles:

- Researcher -> report.
- Synthesizer -> plan.
- Checker -> verdict, BLOCKER or WARNING, on the single question "is it executable".
- Parent firstmate -> the escalation decision when the cap is reached, and quota confirmation for the Fable seat.
- Captain -> locked decisions only, reached through captain-held tasks.

## 5. Model seats

This is the current setting as the captain set it on 2026-08-29; the captain's preference file (`data/captain.md`, or the governing secondmate's copy) wins whenever it differs from this section.

- Round 1 synthesis and plan writing: Claude Fable 5 at HIGH effort, never xhigh or max; this is the only Fable seat, and the parent firstmate confirms Fable quota before each Round 1 dispatch.
- If the Fable seat is unavailable, Round 1 waits; the parent firstmate reports the seat unavailable and the captain decides whether that round runs on Codex gpt-5.6-sol HIGH instead.
- Round 1 never downgrades on a worker or secondmate authority.
- Plan-check and every later patch: Codex gpt-5.6-sol HIGH; Fable does not re-enter to rewrite.
- Researchers: Codex gpt-5.6-sol HIGH.
- Execution workers: Codex gpt-5.6-sol medium by default, high when the task is genuinely hard, and every task names the slice element it unblocks.

## 6. Explicitly out

- Installer: Firstmate's scaffolded briefs and `bin/` scripts are already installed in every home and secondmate home.
- Slash commands (`/gsd-new-project`, `/gsd-onboard`, and the phase commands): the governing firstmate dispatches each phase step as a scout or ship task from the backlog.
- Milestone and phase file bookkeeping (`STATE.md`, phase archives): `data/backlog.md` and the dated rulings files under `data/` are the durable state, and this document's log is the method's own record.
- Hook-driven user prompts: keyed `needs-decision` check-ins and captain-held tasks carry every question to the parent firstmate and, only when genuinely his, to the captain.
- Executor framework: `bin/fm-spawn.sh` launches each execution task in its own isolated worktree with a fresh context; `bin/fm-pr-merge.sh` owns PR merges, and `bin/fm-merge-local.sh` owns approved local-only landing.

## 7. Success signals

- The plan survives one check with a bounded blocker count and reaches dispatch after the single patch.
- The build hits the phase's named proof, for example "the slice on the captain's phone", without a re-plan.
- Fable spend per phase is at most one HIGH-effort Round 1 seat; zero is valid only under the captain-approved fallback in section 5.

## 8. How we review our use of it

- After each phase's named proof lands, the governing secondmate posts one keyed check-in as a usage retrospective: what the method caught, what it cost, and what this document got wrong.
- The parent firstmate folds accepted changes into the sections above and records the retrospective as a log entry below.
- The log is the record; it is evidence-backed, dated, and pruned rather than appended forever, under the same contract as `data/learnings.md`.

## Log

Entries are dated, cite their evidence by path, and are rewritten or removed when superseded.

- 2026-08-28 - Blockvalley Phase 0 ran the method by hand from a plan with a CONTEXT section, three researchers, and one synthesizer (`data/blockvalley-research-plan-phase0-2026-08-28.md`, `data/blockvalley-p0-synth-s/RESEARCH-0.md`, both in the Blockvalley home).
  It caught the real failure: the earlier substitution program had assumed a renderer could be hand-rolled from repainted photos, and the research named y-sort, autotile, and shadows as Don't-Hand-Roll items with provenance.
  The synthesis was prescriptive (Flutter + Flame, runner-up Godot 4) and its open ASSUMED items became one captain-held engine decision, which the captain answered the same day.
  The learnings entry that seeded this document is the GSD METHOD line in `data/learnings.md`.
- 2026-08-28 to 2026-08-29 - Blockvalley Phase 1 planning ran four plan rounds before a cap existed.
  The Round 1 plan was written on Claude Fable 5 at xhigh (`data/blockvalley-p1-plan/report.md`) and failed its first check on nine dimensions, including a false `[VERIFIED]` Tiled command and locked UX behaviour reduced to Phase 2 (`data/blockvalley-p1-plancheck/report.md`).
  Revision 4 on Fable still carried one blocker after the round-4 check, an argument-count mismatch in one task's Tiled contract, while Gate 0 was judged dispatchable (`data/blockvalley-p1-planrev3/report.md`, `data/blockvalley-p1-plancheck-r4/report.md`).
  The cost was roughly a week of Fable quota with no Fable or Opus seats available until the 2026-08-30 reset (`data/blockvalley-p1-scope-cut-2026-08-29.md`).
  Consequence recorded in section 4 and section 5: write once, check once, patch once on Codex, escalate on the third failure, Fable only at HIGH and only for Round 1.
- 2026-08-29 - The captain set the planning and model rules that sections 4 and 5 state, in the Blockvalley steering protocol (`data/steering-protocol.md`, "Planning and model rules"); the Phase 1 scope cut restated the plan-round cap and the slice-element rule for every task (`data/blockvalley-p1-scope-cut-2026-08-29.md`).
  The captain's UX rulings file is the worked example of a CONTEXT document that bounds behaviour without ruling on looks (`data/blockvalley-ux-v1/UX-RULINGS-v1.md`).
