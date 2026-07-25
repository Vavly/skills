---
name: spec-driven
description: Structured five-phase workflow for non-trivial feature work and refactors — clarify, spec, plan with failing tests, execute, adversarial review. Use when the task is large enough that getting the design wrong is expensive. Skip for one-line fixes, typos, and exploration.
argument-hint: "[short task name]"
---

# Spec-driven development

Task: $ARGUMENTS

**Before anything else**, run `.claude/hooks/phase.sh status`. If it reports
inactive, run `.claude/hooks/phase.sh start <short-task-name>` to arm the gate at
Phase 1. Arming is yours to do — Phase 1 is the most restrictive state, so there
is no risk in it.

**The two approval gates are the user's**, and they work differently:

- `2 → 3` — **run it.** `.claude/hooks/phase.sh 3` raises a confirmation prompt,
  and the user approving it *is* the spec approval. Say what you are asking them
  to approve before you make the call. If they decline, stop.
- `3 → 4` — **do not run it.** The guard refuses this one however it is spelled,
  because approving it asserts the user saw the tests fail, and that assertion is
  too important to satisfy with a click. Tell them to run it themselves:

  ```
  .claude/hooks/phase.sh 4
  ```

When a phase's exit criteria are met, **state that, say what you need from the
user, and stop.** Do not carry on into the next phase's work.

Two transitions are yours outright, and you should take them: `1 → 2` once the
blocking unknowns are answered, and `4 → 5` once the plan is complete and the
suite is green. Retreating to a lower phase is also always yours — use it when
the spec turns out to be wrong.

Phase state lives in `.claude/.spec-phase`, not in your context. Re-read it with
`phase.sh status` whenever you are unsure where you are — after compaction,
assume you are unsure. `status` also tells you who owns the next transition. Never
edit the state file: every command that names it is denied, in every phase.

## Standing commitments

These hold in every phase:

- You do not write production code before a spec exists on disk.
- You do not answer a design question with a guess. State the uncertainty and
  what would resolve it.
- Every claim about behavior is backed by output you actually ran, or is
  labeled as an expectation.
- Simplest thing that satisfies the spec. No speculative abstraction, no
  configurability nobody asked for.
- **On contradiction, stop.** If Phase 4 reveals the spec is wrong, do not
  improvise a new design. Say what contradicts it and ask to return to Phase 2.
  Silent mid-execution redesign is the failure this workflow exists to prevent.

## Phase 1 — Clarify

Read the relevant code first. Ambiguity that the codebase already answers is
not ambiguity.

Produce two lists:

- **Blocking unknowns** — things you cannot spec without. Ask only these. If
  there are none, say "no blocking unknowns" and move on. Do not manufacture
  questions to look thorough.
- **Assumptions** — everything else you had to decide. These go in the spec as
  assumptions, not to the user as questions.

Explicitly establish, or record as an assumption: expected scale (rows,
requests, concurrency), failure tolerance, and who else depends on what you're
touching. The scale figure is load-bearing later — Phase 5 cannot make
complexity arguments without it.

**Exit:** blocking unknowns answered, or none exist — then run
`.claude/hooks/phase.sh 2` **yourself**. This transition is yours. Do not ask the
user to run it.

## Phase 2 — Spec

Write to `docs/specs/<task>.md`. This is the only file you may create in this
phase.

- The problem, in two sentences.
- Technical approach and why, plus one alternative considered and rejected.
- Inputs, outputs, and exact type definitions. Include error and empty cases in
  the types, not just the happy path.
- Data structures and where state lives.
- Dependencies. **Any new dependency gets a one-line justification and an
  alternative considered.** Adding a library is the most common form of silent
  scope creep.
- Assumptions from Phase 1.
- Out of scope — what you are deliberately not doing.

**Exit:** the user approves the spec. Say what you are asking them to accept, then
run `.claude/hooks/phase.sh 3` — the confirmation prompt is their approval. A
declined prompt means the spec is not finished; ask what is wrong rather than
retrying.

## Phase 3 — Plan and failing tests

Two artifacts, in this order.

The plan: ordered steps, each small enough to verify on its own, each naming
the files it touches. Append it to the spec document.

Then the tests. Cover, at minimum: empty and null inputs, boundary values,
the failure modes named in the spec, and the concurrency case if there is one.

Then — this is the phase's actual point — **run them and paste the failure
output.** Not a summary of the failure. The output.

If a test passes before the implementation exists, it is testing nothing. Fix
the test before continuing. Do not proceed until every new test fails for the
reason you expect.

**Exit:** plan approved, every new test failing for the right reason, output
shown — then the user runs `.claude/hooks/phase.sh 4` in their own terminal. That
command is their assertion that they saw RED, which is why it is not yours.

## Phase 4 — Execute

Work the plan in order. Production code only — the tests are frozen.

If a test needs to change, that is a Phase 3 decision: stop and say so. Editing
a test to match code you just wrote inverts the whole workflow.

Small functions, names that don't need comments. Comments explain *why*, never
*what*.

Run the suite after each step. Report failures with output, not paraphrase.

**Exit:** plan complete, suite green, output shown — then run
`.claude/hooks/phase.sh 5` **yourself**. This transition is yours: advancing
submits your work for adversarial review, so taking it costs you nothing and
gains you scrutiny. Do not ask the user to run it, and do not ask them to approve
it. Only 2 → 3 raises a prompt, and only 3 → 4 needs their terminal.

## Phase 5 — Adversarial review

**You do not review your own work here.** Delegate to the `adversary` subagent.

Give it the task intent in one or two sentences and nothing else. No summary of
your approach, no defense of your choices, no list of what to look at. It forms
its own judgment from the diff. Priming it is the difference between a review
and a rubber stamp.

Then handle findings:

- `blocker` / `serious` — fix, then note that the fix itself is unreviewed.
- `minor` — report with your recommendation. Do not silently fix or drop.
- Disagree with a finding? Say so with reasoning. Never discard quietly.

Complexity and performance: only problems that bite at the scale established
in Phase 1. If Phase 1 recorded no scale, you may not make complexity claims —
say the scale was never established.

Close with an evidence log: what the reviewer found, what you changed, what you
declined and why. **"Reviewer found nothing, no changes made" is a complete and
unremarkable entry.** Do not pad it. A log that always shows improvements is
a log that trains the reader to skim.
