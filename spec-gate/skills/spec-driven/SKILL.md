---
name: spec-driven
description: Structured five-phase workflow for non-trivial feature work and refactors — clarify, spec, plan with failing tests, execute, adversarial review. The spec and the plan are adversarially reviewed before the user is asked to approve them. Use when the task is large enough that getting the design wrong is expensive. Skip for one-line fixes, typos, and exploration.
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

- `2 → 3` — `.claude/hooks/phase.sh 3`. They are approving the spec — which by
  then has been through `spec-adversary`, not just through you.
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

### Slicing a long task

If Execute would produce a diff too large to review in one pass, the task lands
in slices — each one separately tested, approved and reviewed. Judge this on
diff size, not on how complicated the task feels: a three-step plan is not
sliced, and slicing costs one adversarial review per slice.

When it applies, the spec declares the seams, because the user's `2 → 3`
approval means something different for a sliced task — they are accepting N
review cycles, N commits, and a repo that sits half-built in between. Give the
spec a checklist and set the count:

```markdown
## Slices

- [ ] 1 — Extract the banner position into a layout prop
- [ ] 2 — Move the existing call sites onto it
- [ ] 3 — Delete the old absolute-positioning path
```

```
.claude/hooks/phase.sh slices 3
```

Setting it here is silent — the count is part of the spec they are about to
approve. Changing it later raises a prompt, because by then they have approved
it. **Keep the checklist and the count in step**: the count lives in the state
file and the seams live in the spec, and after a compaction whichever is read
first is believed.

If the estimate turns out low mid-task, `phase.sh slices <n>` again. Running it
asserts *more work than expected*. If instead the design turned out wrong, that
is not a slice change — it is the contradiction rule in [Standing
commitments](#standing-commitments), so stop and ask to return to Phase 2.

### Have it reviewed before you ask

**You do not review your own spec.** When it is written, delegate to the
`spec-adversary` subagent — a design is cheapest to break here, before tests are
written against it and code against those tests. Do this *before* you ask the
user for anything.

Same rule as Phase 5: **open with the stance, not the task.** The difference is
what you are withholding. A spec *is* your reasoning written down, so the
reviewer gets all of it; what you keep back is which parts you are unsure about
and where you think it should look.

> You are adversarially reviewing a spec that has not been approved yet:
> `docs/specs/<task>.md`. Assume the design is wrong and find where. Your job is
> to break it on paper, not to approve it.
>
> The task intent, which is the only framing I am giving you:
> **&lt;one or two sentences&gt;**
>
> The spec is my reasoning in full — read it against the repo and check what it
> claims. I am not telling you which parts I am unsure about, or where to look.
> If it holds up, say `sound` and stop — that is a normal outcome, not a failure
> to find something.

Everything after the intent line stays fixed, for the reason it does in Phase 5:
a reviewer told where to look reports back on where you sent it.

Then handle the verdict:

- `blocker` / `serious` — fix the spec. If a finding takes out the approach
  rather than a detail, that is a rewrite of the spec, not a footnote added to
  it.
- `minor` — fold it into the spec or report it with your recommendation. Do not
  silently fix or silently drop it.
- Disagree with a finding? Say so with reasoning, and put the reasoning in the
  spec if it changes an assumption. Never discard one quietly.
- `cannot-assess` — report what it said it needed. It is not a pass.

Re-run the reviewer only if the approach changed. A wording fix does not need a
second pass, and a second pass you did not need trains you to skip the first.

**Exit:** the spec has been reviewed and the findings are handled, then the user
approves it. The verdict, what you changed in response, and what you declined all
go to them **before** the prompt appears — they are approving the spec as it now
stands, so say what moved. "Reviewer found nothing, spec unchanged" is a complete
report. Then run `.claude/hooks/phase.sh 3` — the confirmation prompt is their
approval. A declined prompt means the spec is not finished; ask what is wrong
rather than retrying.

## Phase 3 — Plan and failing tests

Two artifacts, in this order.

The plan: ordered steps, each small enough to verify on its own, each naming
the files it touches. Append it to the spec document.

Then send it back to `spec-adversary` — the same preamble as Phase 2, with the
scope narrowed to the new material:

> …judge the plan appended to `docs/specs/<task>.md` against the spec above it.
> The spec is approved; the plan is not.

**Before the tests, not after.** Tests written against a plan that then gets
restructured are paid for twice, once in writing them and once in unpicking them.
Handle the findings exactly as in Phase 2. If one lands on the spec rather than
the plan, that is the contradiction rule in [Standing
commitments](#standing-commitments) — stop and ask to return to Phase 2 rather
than patching the plan around an approved spec you no longer believe.

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

**Exit:** plan reviewed and its findings handled, every new test failing for the
right reason, output shown and accounted for — then run
`.claude/hooks/phase.sh 4`. The prompt it raises is the user's assertion that they
read the failures and accept them. Do not make that call in the same breath as
`red`: show the output, say what it means, and let them see it before the prompt
appears.

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

**You do not review your own work here.** Delegate to the `adversary` subagent —
that one, not the `spec-adversary` from Phases 2 and 3. Different subject,
different brief: this one attacks the code that got written, and it is told
nothing about the spec it was written from.

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

### If the task is sliced, this is a boundary, not the end

At `slice n of total` with slices remaining, Phase 5 is where one increment ends
and the next begins. Commit the reviewed work, tick the slice off the checklist
in the spec, then run `.claude/hooks/phase.sh 3` to open the next one.

**The commit is not optional and the guard enforces it.** `5 → 3` is refused
while anything is owed review, because starting the next slice folds this one's
diff into the new baseline, where the review gate stops seeing it forever. If
the transition is denied, the message names what is outstanding — commit that,
do not look for another way forward.

Then Phase 3 again: the next slice's plan steps, its failing tests, its own RED
check, its own `3 → 4` approval. The user re-approves every lap, on that lap's
evidence.

Only when the last slice is reviewed does the close-out below apply.

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
