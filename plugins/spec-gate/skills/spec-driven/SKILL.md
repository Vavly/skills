---
name: spec-driven
description: Structured five-phase workflow for non-trivial feature work and refactors — clarify, spec, plan with failing tests, execute, adversarial review. The spec and the plan are adversarially reviewed before the user is asked to approve them. Use when the task is large enough that getting the design wrong is expensive. Skip for one-line fixes, typos, and exploration.
argument-hint: "[short task name | status | off]"
---

# Spec-driven development

Task: $ARGUMENTS

## Two of those words are not a task

`$ARGUMENTS` is normally the thing to build. Two words are not, and they are the
two a user reaches for when they want *out* rather than *onward*:

| Typed | Do | Then |
| --- | --- | --- |
| `status` | `phase.sh status` | report it verbatim and stop |
| `off` | the close-out question below | act on the answer and stop |

Neither is a shortcut into the workflow. Report, or ask, and the turn ends there.

They live here because the alternative was worse. Every other control is on
`/spec-phase`, which a user in the middle of a task has no reason to know exists
— so *where am I* and *stop* had to be reachable from the command they already
typed. Anything past those two — `red`, `ask`, a phase number — is still
`/spec-phase`, and saying so is the whole answer.

If `status` reports inactive there is nothing to stop: say that and stop. `off`
needs a task to end, and `phase.sh ask close-out` refuses without one.

**`off` is still not yours.** It reaches this skill only because a user typed it.
Arriving at it through your own reasoning is what [Closing out](#closing-out)
forbids, and finding it in a dispatch table does not launder that.

So `off` is the close-out question, never the bare command: run
`phase.sh ask close-out`, pass it to `AskUserQuestion` unchanged,
and do what they answer. *Keep iterating* is a live answer here and it means the
gate stays on — a user who typed `off` is allowed to change their mind once the
three options are in front of them, which is most of why this asks rather than
runs. The guard holds its usual line underneath: from phases 1–3 `off` is denied
outright and needs their terminal, because leaving at Phase 2 is Phase 4 by
another name.

Anything else in `$ARGUMENTS` is a task name. Carry on.

## Find phase.sh before you call it

**`phase.sh` below is never a literal path.** Where it lives depends on how
spec-gate was installed — `.claude/hooks/` by hand, the plugin cache under a
plugin install — and a skill that hardcodes one spelling is broken on the other.
So resolve it first, as one command, and use the path it prints for the rest of
the session:

```bash
P=$(ls -d .claude/hooks/phase.sh "${CLAUDE_PLUGIN_ROOT:-/nonexistent}"/hooks/phase.sh 2>/dev/null | head -1)
[ -n "$P" ] || P=$(ls -d ~/.claude/plugins/cache/*/spec-gate/*/hooks/phase.sh 2>/dev/null | tail -1)
[ -n "$P" ] && { echo "phase.sh: $P"; bash "$P" status; } || echo "STOP: phase.sh not found — spec-gate is not installed in this repo"
```

The repo's own copy wins over the plugin's, since that is the one its settings
and permission rules name. Shell variables do not survive between calls, so `$P`
is gone by your next command — **read the path out of the output and write it in
full every time.**

If it prints `STOP`, say so and stop. The gate is not installed here, and a
five-phase workflow narrated over hooks that do not exist enforces nothing while
looking exactly like one that does.

That call has already given you `status`, which is where the workflow starts. If
it reports inactive, run `phase.sh start <short-task-name>` to arm the gate at
Phase 1. Arming is yours to do — Phase 1 is the most restrictive state, so there
is no risk in it.

## Arm the gate in the tree you will actually work in

**The gate covers one worktree, and it is the one holding `.claude/.spec-phase`.**
Nothing here spans two. So decide where the work happens *before* you arm it:

- Going to use a worktree — `git worktree add`, `EnterWorktree`, a harness rule
  that isolates background sessions? **Create it first, move into it, and arm the
  gate there.**
- Already armed, and only now moving to a worktree? The task does not come with
  you. Close it out where it is, or stay put.

Arming in the main checkout and then working in a worktree is the one arrangement
this cannot enforce, and it fails in the direction that costs you: `status` reads
`inactive` from the worktree while the task sits armed next door, and the guard
has no opinion on files outside the tree it was armed in. A gate that reports
itself armed and permits everything is worse than no gate, because you stop
checking.

The hooks now refuse rather than let that happen — `status` names both trees and
every other command declines — but a refusal mid-task is a worse outcome than
never splitting, and only you can prevent that, at the start. **If a refusal does
land, do not try to route around it**: `.spec-phase` is phase state, so moving,
copying or recreating it is denied through every vector, and a receipt you
relocated is a receipt nobody gave. Report which tree holds the task and let the
user pick one.

**Three decisions are the user's, and each one is a question you ask them.** Not
a sentence in your message hoping they answer it, and not a permission prompt on
a shell command they never asked to see. The pattern is the same all three times:

1. Say what you are asking them to decide, and put the evidence on screen.
2. Run `phase.sh ask <gate>` — it prints the question as an
   `AskUserQuestion` payload.
3. Pass that payload to `AskUserQuestion` **unchanged**, and let them answer.
4. Act on the answer. The transition they approved now goes through.

| Gate | Ask this | Then |
| --- | --- | --- |
| `2 → 3` | `phase.sh ask spec` | `phase.sh 3` |
| `3 → 4` | `phase.sh red`, show the failures, `phase.sh ask red` | `phase.sh 4` |
| close-out | `phase.sh ask close-out` | what they chose — see [Closing out](#closing-out) |

**Do not reword the question.** The gate recognises its own wording, and that is
what lets your answer stand in for the confirmation prompt. Reword it and the
answer records nothing, so the user gets asked twice — once by you and once by
the guard. Everything you want to say about the decision goes in your own message
*above* the question, which is where it belongs anyway.

**Never ask the user to run a hook.** They should not have to know that
`phase.sh` exists. You run it; they answer questions.

If they decline, stop — do not look for another route, and do not ask again until
something has actually changed. Re-asking until the answer changes is not
consent.

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

## The two reviewer sessions

Both reviewers are long-lived. You spawn each one **once** and every later round
goes back to that same session with `SendMessage`, instead of spawning a second
reviewer that has to start from nothing:

| Session | Agent | Opened | Reused for |
| --- | --- | --- | --- |
| design | `spec-adversary` | Phase 2 on the spec — or Phase 3 on the plan, from slice 2 on | the Phase 3 plan, and every re-read after you change either |
| code | `adversary` | Phase 5, on the diff | every re-review after you fix a finding |

**The two never merge**, and neither crosses a slice boundary. A design reviewer
that has read the diff stops judging the design; a code reviewer that has read
the spec starts checking the code against the author's stated intent, which is
the one thing this workflow withholds from it. Separate subjects, separate
sessions.

Keep the name or id each spawn returns — it is the only handle you have on the
session. If you have lost it, most likely to a compaction, spawn a fresh one and
record in the log that this round started cold: a reviewer that has forgotten its
own findings cannot tell you whether a fix landed, and a verdict that quietly
claims otherwise is worse than an honest re-read.

**The index is the reviewer's bookmark**, and you do not maintain it.
`review-bookmark.sh` runs `git add -A` when either reviewer is spawned and again
the moment its verdict lands, which keeps one invariant true: **staged is what the
reviewer has already judged, unstaged is what has moved since.**

So: **do not run `git add` during a review round, at all.** Not before spawning,
not after a verdict, not to "make sure". Every ordering that breaks the bookmark
requires you to have staged something, and the one that breaks it silently is the
one you would reach for. `git restore --staged <path>` is fine if the hook picked
up something you want out of the index.

Staging is not a change — the review gate fingerprints file *contents*, not index
state, so a `git add` never re-arms it and never costs a review round.

**Read [references/reviewer-sessions.md](references/reviewer-sessions.md) when any
of this looks like overhead**, or before you decide a round can skip it. It holds
why reuse beats respawning, why the two sessions must not meet, the three times
the bookmark broke in real use and what that bought, and what reuse costs you in
reviewer independence.

That last one has a half you own: **keep the argument out.** The follow-up message
points at the change and stops.

> The **&lt;spec | working tree&gt;** has changed since your verdict. Everything you
> had already judged is staged, so `git diff` is exactly what moved.
>
> Findings I acted on: **&lt;list&gt;**. Findings I left: **&lt;list&gt;**. Check that
> against the code rather than taking it from me — anything you still consider
> open, report again, and anything I broke is new. If it holds up now, say
> `sound` and stop.

At Phase 5 the message carries two more things. One is the validation delta —
*"same commands, same result"* is a complete version of it — since the fixes are
code the checks had not seen when you last ran them.

The other is the gate's own list. When the review gate blocked the turn it printed
*"Changed since the last review round: …"*, computed from its fingerprint.
**Paste that in verbatim and say it came from the gate.** It is the one part of the
message that is a fact rather than a claim: it does not depend on your having
staged in the right order, and if it disagrees with your own account of what you
changed, it is right and something is unaccounted for. Say that rather than
quietly reconciling the two.

Naming which findings you touched is fine, and so is pointing at the diff. **What
stays out is the argument** — no explanation of why the fix is right, no case for
a finding you declined. That case goes to the user, in the evidence log, where
they can weigh it.

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
`phase.sh 2` **yourself**. This transition is yours. Do not ask the
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

**Ask once, here: would Execute produce a diff too large to review in one pass?**
Judge it on diff size, not on how complicated the task feels. If yes, the task
lands in slices — each separately tested, approved and reviewed — and the spec has
to declare the seams before the user approves it, because a sliced `2 → 3`
approval accepts N review cycles and a repo that sits half-built in between.

Read [references/slicing.md](references/slicing.md) and follow it. It covers the
checklist, `phase.sh slices <n>`, what Phase 3 does from slice 2 on, and how a
slice boundary closes at Phase 5.

If the answer is no, skip it — slicing costs one adversarial review per slice, and
a three-step plan is not sliced.

### If this feature needs files that do not exist yet

**An import error is not a failing test.** It says a prerequisite is missing; it
says nothing about what the test asserts. And `phase.sh red` has exactly one
detector for a test that asserts nothing — *the test passes*. Against a module
that does not exist, a careful test and an empty one both fail with
`ModuleNotFoundError`, identically, so that detector is blind for precisely the
new feature work this workflow exists for. It only works where the code already
exists, which is bug fixes.

So when the spec introduces modules that are not there yet, the surface gets
created **before** Phase 3 writes tests against it. Declare it in the spec:

```markdown
## Scaffold

- src/parser.py — `parse(text) -> Result`
- src/emitter.py — `emit(node) -> str`
```

The user authorises it in the same answer that approves the spec — *Approve, and
create the files first* — because the surface being created is the one the spec
describes. Then:

1. `phase.sh scaffold`. Still Phase 2; the gate now permits **creating** files
   that do not exist, and tests. Anything already tracked stays untouchable —
   editing existing code is Phase 4, and the gate will refuse it here.
2. Write the surface test: it imports the module and names the export. Run
   `phase.sh red` and show it failing. **This is the one place an import error
   is the assertion**, because existence is what the step delivers.
3. Create the files, with the surface and nothing behind it — signatures that
   raise `NotImplementedError` or return nothing. Stop at the frontier. The
   surface test goes green.
4. `phase.sh 3` as normal. Scaffold mode ends with the phase change.

Phase 3 then writes behavioural tests against a module that exists, so they fail
on an assertion — which is the only failure that proves a test asserts anything.

**Skip all of this when the work touches code that is already there.** A bug fix
or a change to an existing module needs no scaffold: the import already resolves,
so Phase 3 gets assertion-red for free and the plain *Approve the spec* is the
answer you want.

### Have it reviewed before you ask

**You do not review your own spec.** When it is written, delegate to the
`spec-adversary` subagent — a design is cheapest to break here, before tests are
written against it and code against those tests. Do this *before* you ask the
user for anything.

Just delegate — the spawn stages for you, so each revision you make afterwards is
a `git diff` the reviewer can read rather than a document it has to re-scan. That
spawn opens the design session, and Phase 3 sends the plan back to it, so **keep
its handle**. See [The two reviewer sessions](#the-two-reviewer-sessions).

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

Re-read goes back to the same session, with the follow-up message from [The two
reviewer sessions](#the-two-reviewer-sessions) — not a second spawn. Ask for one
only if the approach changed. A wording fix does not need another pass, and a
pass you did not need trains you to skip the one that mattered.

**Exit:** the spec has been reviewed and the findings are handled, then the user
approves it. The verdict, what you changed in response, and what you declined all
go to them **before** you ask — they are approving the spec as it now stands, so
say what moved. "Reviewer found nothing, spec unchanged" is a complete report.

Then `phase.sh ask spec`, pass it to `AskUserQuestion`, and run
`phase.sh 3` once they approve. *Send the spec back* means the spec
is not finished: ask what is wrong, revise it, and ask again — editing it is what
clears the answer, so a spec you have not changed is one the gate still refuses.

*Approve, and create the files first* is the same approval plus the scaffold step
above; it also clears `2 → 3`, so you do not ask twice. If the spec declares a
`## Scaffold` list, say so when you put the question, because that is the answer
you are asking them to consider.

## Phase 3 — Plan and failing tests

Two artifacts, in this order.

The plan: ordered steps, each small enough to verify on its own, each naming
the files it touches. Append it to the spec document.

Then send it back to `spec-adversary` — **the session from Phase 2, by
`SendMessage`**, not a new spawn. It has already read the spec and the code the
spec makes claims about, so it starts on the plan instead of on the ground the
plan stands on. It keeps the stance it was given; do not restate the preamble,
and do not summarise the spec back to a reviewer that read it:

> The spec you reviewed is approved as it stands, and I have appended a plan to
> it. Judge the plan against the spec above it: the spec is settled, the plan is
> not.

**On slice 2 and after there is no live design session** — Phase 2 ran once, and
each slice closes its reviewers behind it, so this is a fresh spawn rather than a
`SendMessage`. See [references/slicing.md](references/slicing.md#phase-3-on-slice-2-and-after-no-live-design-session).

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
phase.sh red
```

It runs exactly the test files this phase changed, refuses if any of them pass,
and records that RED was verified. Running it through your own test command
instead proves the same thing to you and nothing to the gate.

**It also refuses two failures that are not failing tests**, and both refusals
tell you what to do:

- *the test command did not run* — a missing or broken runner exits non-zero
  exactly like a real failure does. Fix the command in
  `.claude/spec-gate-test-cmd`, taken from `package.json`, `pyproject.toml`, the
  Makefile or CI rather than guessed.
- *a module could not be resolved* — the code under test does not exist yet, so
  every test fails this way whatever it asserts. That is the [scaffold
  step](#if-this-feature-needs-files-that-do-not-exist-yet): retreat to Phase 2,
  put the files in a `## Scaffold` list, and ask for *Approve, and create the
  files first*. If the module *should* already exist, this is a broken import
  path or a missing dependency — fix that instead.

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
right reason, output shown and accounted for — then `phase.sh ask
red`, and `phase.sh 4` once they accept the failures.

Do not ask in the same breath as `red`. Show the output, say per test what it
asserts and why that failure is the expected one, and only then put the question.
What they are accepting is the half the machine cannot check, and they can only
accept it if they have read something first.

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
has already encoded what "valid" means — in an aggregate check script, in CI, in a
pre-commit hook, in its contributor docs. Go find that and run what it says. Your
own approximation of a repo's checks is how a diff passes review and fails CI ten
minutes later.

Show the output. **Every failure is yours to account for, including ones in files
you did not touch.** Then write it down in the shape Phase 5 hands to the reviewer,
so the work of finding this repo's checks is done once rather than twice:

```
VALIDATION REPORT
Commands: <exactly what you ran>
Source:   <where you got them>
Result:   <per command: pass, plus its summary line>
Not covered: <what this repo does not check at all>
```

**Read [references/validation.md](references/validation.md) before you fill this
in.** It has where to look and in what order of authority, how to prove a failure
predates your change rather than asserting it, and what each report line buys the
reviewer — including `Not covered`, which is the line the reviewer reads first and
the one you will be tempted to leave blank.

**Exit:** plan complete, repo validations green, output shown, report written —
then run
`phase.sh 5` **yourself**. This transition is yours: advancing
submits your work for adversarial review, so taking it costs you nothing and
gains you scrutiny. Do not ask the user to run it, and do not ask them to approve
it — only 2 → 3 and 3 → 4 raise prompts.

## Phase 5 — Adversarial review

**You do not review your own work here.** Delegate to the `adversary` subagent —
that one, not the `spec-adversary` from Phases 2 and 3. Different subject: this
one attacks the code that got written, and it is told nothing about the spec it
was written from. Do not point the design reviewer at a diff to save a spawn.

**The reviewer's procedure is not yours to write.** It lives in the
[adversarial-review](../adversarial-review/SKILL.md) skill, which the subagent
loads for itself. Your side is the four steps below, and the third one is a
pointer rather than a briefing.

### 1. The validations are already green

Phase 4 cannot exit without them, so you are holding the report it wrote. Nothing
to re-run here — hand it over in step 3. From the second round on, re-run whatever
a fix could have broken, because a fix is code the validations have not seen.

### 2. Staging — not yours

`review-bookmark.sh` handles it at both ends of the spawn, which is what makes
round two legible. **Do not run `git add` yourself** — see [The two reviewer
sessions](#the-two-reviewer-sessions).

### 3. Spawn, with a pointer and nothing else

**Name the skill first, the intent second, and stop.** The order is load-bearing:
the reviewer reads the stance it is meant to take before it reads what the change
was for. Lead with the intent instead and a bare sentence — *"Message banners
should appear below the header, not above it"* — reads as *check that this works*,
and you get a confirmation back.

> Use the `adversarial-review` skill and follow it. You are reviewing the working
> tree.
>
> The intent of the change, which is the only thing I am telling you:
> **&lt;one or two sentences&gt;**
>
> The repo's validations pass on this change:
>
> ```
> &lt;the Phase 4 validation report&gt;
> ```

**The intent line is the only part you write.** No summary of your approach, no
defense of your choices, no list of what to look at, and **no restating the
skill's own instructions back at it** — a spawn message that re-explains the
procedure is the copy that drifts. Priming it is the difference between a review
and a rubber stamp.

**The intent line comes from Phase 1, not from the spec.** The spec is the
reasoning behind the change, and the reviewer does not get the reasoning; pasting
the spec's summary in is how the withholding quietly stops happening while still
looking like it is in force.

Keep the handle the spawn returns. Every round after the first goes back to that
session, **including the rounds the review gate asks for** — fixing a finding
changes the diff, and a changed diff is owed review again.

### 4. Act on the verdict

**The staging already happened**, on the way out of the reviewer and before you
could touch anything. The tree as it stands is now *what the reviewer has seen*,
and everything you do next is the next round's `git diff`.

- `blocker` / `serious` — fix, then note that the fix itself is unreviewed until
  the next round closes it. The reviewer that found it is the one that says so.
- `minor` — report with your recommendation. Do not silently fix or drop.
- `sound` — say so and stop.
- `cannot-assess` — report what it said it needed. It is not a pass.
- Disagree with a finding? Say so with reasoning, **to the user**. Never discard
  quietly, and never take the argument back to the reviewer — a reviewer talked
  round to your position has stopped being one.

Complexity and performance: only problems that bite at the scale established in
Phase 1. If Phase 1 recorded no scale, you may not make complexity claims — say
the scale was never established.

Close with an evidence log: what the reviewer found, what you changed, what you
declined and why. **"Reviewer found nothing, no changes made" is a complete and
unremarkable entry.** Do not pad it. A log that always shows improvements is a log
that trains the reader to skim.

One entry per round, so the sequence is visible: what it found, what you changed,
what it said about that change. The last round's verdict is not a summary of the
review — **a finding the reviewer closed and a finding it never re-checked look
identical in a log that only records the end**, and only one of them is done.

### If the task is sliced, this is a boundary, not the end

At `slice n of total` with slices remaining, Phase 5 is where one increment ends
and the next begins: commit the reviewed work, tick the slice off the checklist in
the spec, then `phase.sh 3` opens the next one. **The commit is not
optional and the guard enforces it** — `5 → 3` is refused while anything is owed
review. If the transition is denied, the message names what is outstanding; commit
that, do not look for another way forward.

**Both reviewer sessions end at the boundary too.** The next slice spawns its own,
cold, and that is the point rather than an oversight.

[references/slicing.md](references/slicing.md#phase-5-as-a-boundary-rather-than-the-end)
has the full boundary procedure and why the sessions reset. Only when the last
slice is reviewed does the close-out below apply.

### Closing out

The findings being handled does not end the task. Put the review log on screen,
then **ask what happens to the work**: `phase.sh ask close-out`,
passed to `AskUserQuestion`. Three answers, three different next moves:

- **Open a pull request** — open it, *then* run `phase.sh off`.
  The order is load-bearing and the gate now holds you to it: until the work is
  committed, `off` is denied on this answer, because disarming on a dirty tree
  returns the review gate to firing every turn against your own finished diff.
- **Keep iterating** — **stay in Phase 5.** Do not disarm, do not commit, do not
  decide on their behalf what the work was for. Say what is outstanding and wait.
  Further changes get reviewed exactly like the last ones did, which is the point
  of still being here. `off` is denied outright on this answer; do not re-ask
  until something has actually changed.
- **Disarm and leave it** — run `phase.sh off`. They have said the
  tree is theirs to deal with.

**Never run `phase.sh off` on your own initiative**, in any phase. Ending the
workflow is the one decision that disposes of the whole task, and it is not
yours. The guard still raises a confirmation prompt if you reach `off` without
having asked — treat that as the backstop it is, not as the asking. A prompt the
user did not see coming is a worse conversation than the question above.
