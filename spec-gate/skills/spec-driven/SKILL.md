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

**The two approval gates are the user's.** You run both commands; each raises a
confirmation prompt, and the user accepting it *is* the approval. Say what you
are asking them to approve **before** you make the call, so the prompt is never
the first they hear of it. If they decline, stop — do not look for another route.

- `2 → 3` — `.claude/hooks/phase.sh 3`. They are approving the spec.
- `3 → 4` — `.claude/hooks/phase.sh red` first, then `.claude/hooks/phase.sh 4`.
  The guard refuses the second until the first has passed, so this is two calls,
  not one, and the failure output belongs between them.

When a phase's exit criteria are met, **state that, say what you need from the
user, and stop.** Do not carry on into the next phase's work.

Two transitions are yours outright, and you should take them: `1 → 2` once the
blocking unknowns are answered, and `4 → 5` once the plan is complete and the
suite is green. Retreating to a lower phase is also always yours — use it when
the spec turns out to be wrong.

**`off` is never yours.** It ends the task, and how a task ends is the user's to
decide. See [Closing out](#closing-out).

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

Then — this is the phase's actual point — **run them and show the failure
output.** Not a summary of the failure. The output. Use:

```
.claude/hooks/phase.sh red
```

It runs exactly the test files this phase changed, refuses if any of them pass,
and records that RED was verified. Running it through your own test command
instead proves the same thing to you and nothing to the gate.

If a test passes before the implementation exists, it is testing nothing. Fix
the test before continuing. Do not proceed until every new test fails for the
reason you expect.

"Verified RED" is a weaker claim than the one this phase makes. The check proves
the tests are *not green*; it cannot tell an assertion failure from an import
error or a typo in a fixture. **Read the output and say, per test, what it
asserts and why this failure is the expected one.** A test that fails with
`ReferenceError` when you expected a wrong return value is not red for the right
reason — it is broken, and you fix it here rather than discovering it in Phase 4.

**Exit:** plan approved, every new test failing for the right reason, output
shown and accounted for — then run `.claude/hooks/phase.sh 4`. The prompt it
raises is the user's assertion that they read the failures and accept them.
Do not make that call in the same breath as `red`: show the output, say what it
means, and let them see it before the prompt appears.

Once RED is recorded, **do not touch the test files again before advancing.** Any
edit to them voids the verification and the guard will send you back to `red`.

## Phase 4 — Execute

Work the plan in order. Production code only — the tests are frozen.

If a test needs to change, that is a Phase 3 decision: stop and say so. Editing
a test to match code you just wrote inverts the whole workflow.

Small functions, names that don't need comments. Comments explain *why*, never
*what*.

Run the suite after each step. Report failures with output, not paraphrase.

### Validate the repo, not just your tests

The plan being finished is not the same as the repo being healthy. Before
advancing, run the validations this repo expects of a change — linting, type
checking, the full suite rather than the files you touched, and whatever else it
gates on.

**Work out what those are. Do not assume, and do not invent a list.** Every repo
has already decided what "valid" means and encoded it somewhere: in what its
pre-commit hook runs, what CI runs, what its contributor docs tell a human to run
before pushing, or in an aggregate script that exists for exactly this purpose.
Go find that, and run what it says. Your own approximation of a repo's checks is
how a diff passes review and fails CI ten minutes later.

Say which commands you settled on and where you got them. That one sentence is
what makes a wrong guess visible instead of silent — and if the repo genuinely
defines nothing, say that too, then assemble the minimum for the language and
flag that you chose it.

Show the output. **Every failure is yours to account for, including ones in files
you did not touch** — a type error elsewhere that your change surfaced is your
change's problem. If a failure genuinely predates your work, prove it rather than
asserting it: stash the change, run the check, restore, and show both results.

**Exit:** plan complete, repo validations green, output shown — then run
`.claude/hooks/phase.sh 5` **yourself**. This transition is yours: advancing
submits your work for adversarial review, so taking it costs you nothing and
gains you scrutiny. Do not ask the user to run it, and do not ask them to approve
it — only 2 → 3 and 3 → 4 raise prompts.

## Phase 5 — Adversarial review

**You do not review your own work here.** Delegate to the `adversary` subagent.

**Open with the stance, not with the task.** A bare intent sentence — *"Message
banners should appear below the header, not above it"* — reads as *check that
this works*, and you get a confirmation instead of a review. Say what the
reviewer is for before you say what the change was for:

> You are adversarially reviewing an unreviewed diff in the working tree. Assume
> it is wrong and find where. Your job is to break this change, not to approve it.
>
> The intent of the change, which is the only thing I am telling you:
> **&lt;one or two sentences&gt;**
>
> I am deliberately not describing my approach, my reasoning, or where I think
> you should look. Judge the diff and the surrounding code on their own terms.
> If it holds up, say `sound` and stop — that is a normal outcome, not a failure
> to find something.

Everything after the intent line stays fixed. **The intent line is the only part
you write**, and it stays at one or two sentences: no summary of your approach,
no defense of your choices, no list of what to look at. Priming it is the
difference between a review and a rubber stamp.

That closing sentence is not softening the brief — it is load-bearing. Push a
reviewer to be adversarial without it and you get manufactured findings, which
cost you the same reading time and train you to skim the real ones.

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

### Closing out

The findings being handled does not end the task. **Ask what happens to the
work:**

> Review is done and the log is above. Open a pull request?

- **Yes** — open it. Then, and only then, run `.claude/hooks/phase.sh off`.
  The order is load-bearing: `off` returns the review gate to firing every turn
  on any dirty tree, so disarming before the work is committed leaves you
  tripping the gate on your own finished diff.
- **No** — **stay in Phase 5.** Do not disarm, do not commit, do not decide on
  their behalf what the work was for. Say what is outstanding and wait. Further
  changes get reviewed exactly like the last ones did, which is the point of
  still being here.

**Never run `phase.sh off` on your own initiative**, in any phase. Ending the
workflow is the one decision that disposes of the whole task, and it is not
yours. The guard raises a confirmation prompt as a backstop — treat that as the
safety net it is, not as the asking. A prompt the user did not see coming is a
worse conversation than the question above.
