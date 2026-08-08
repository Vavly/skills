---
name: spec-phase
description: Inspect or advance the spec-driven phase gate.
argument-hint: "[status | brief | start <task> | red | ask <gate> | slices <n> | journal | validation | 1-5 | 4 --force | 5 --force | off]"
disable-model-invocation: true
allowed-tools: Bash
---

Requested: `$ARGUMENTS`

First run `.claude/hooks/phase.sh status` to see the current phase. Then:

**If the request is `status`** — report the output verbatim and stop.

**If the request is `2 → 3`, `3 → 4`, or `off` from phase 4 or 5** — these are the
three decisions that are the user's, so put the question to them rather than
running straight at the transition. Typing `/spec-phase 3` says they want to
advance; it does not say they have read the spec, and that is the part being
approved.

Run `.claude/hooks/phase.sh ask <spec | red | close-out>`, pass the JSON it
prints to `AskUserQuestion` **unchanged**, and then make the transition their
answer calls for. Say what you are asking them to decide before you ask it. If
they decline, stop; do not look for another route forward.

Reworded questions record nothing, which costs them a second prompt for a
decision they just made.

At `2 → 3`, if the spec has not been through the `spec-adversary` reviewer in this
conversation, say so before you ask. The question's own wording tells them to
decline in that case, and hearing it from you first is the difference between a
choice and a surprise. They may still want to advance — that is theirs to decide,
not yours to withhold.

`3 → 4` additionally needs RED verified first — the guard denies it otherwise and
says so. If it does, run `.claude/hooks/phase.sh red`, show its output in full,
and only then advance.

**If the request is `red`** — run it and report the output verbatim, including the
test output. Do not advance in the same turn: the user reads the failures, then
decides.

**If the transition routes around a gate** — it is still the user's, and it is
still a question. Six of them, each with its own gate, and none of them needs a
terminal any more:

| From → to | Gate | What the answer is accepting |
| --- | --- | --- |
| any forward skip (1→3, 2→4, 2→5, 3→5…) | `skip` | the approvals in the phases being jumped over, given up |
| `off` from phases 1–3 | `abandon` | the same as unlocking Phase 4 with no spec and no failing test |
| any move off Phase 5 except `off` | `leave-review` | a diff parked where the review gate cannot see it |
| `start` while already armed | `restart` | the current task discarded, approvals and all |
| `4 --force` | `force` | production code unlocked with nothing shown to fail |
| `5 --force` | `force-validation` | review entered with this repo's own checks unrun |

Same procedure as the three above: `.claude/hooks/phase.sh ask <gate>`, pass the
JSON to `AskUserQuestion` unchanged, act on the answer. **Say what they are giving
up before you ask** — these used to cost a trip to a terminal, and that trip was
doing work: it was a moment of attention this question now has to carry on its
own.

The two `--force` flags are spelled the same and are not the same decision, which
is why they have separate gates. `force` unlocks production code on nothing having
been shown to fail; `force-validation` enters review with the code already
written and its build and tests unrun. Do not reach for the wrong one — an answer
about one is not an answer about the other, and the guard will not accept it as
one.

The guard denies every one of them until the receipt exists, so there is no route
forward that skips the asking. What it can never do is tell your Bash call from
one the user's slash command made — which is why the answer, not the call, is what
moves anything.

**If the request is `brief`** — run it and report the output verbatim. It
reconstructs an active task from disk for a session that has lost it, which is
also what the `SessionStart` hook runs by itself after compaction or `/clear`.
Typing it changes nothing; it only reads.

**If the request is `journal` or `validation`** — these two do **not** take their
content as an argument. They read it from stdin, so forwarding `$ARGUMENTS` at
them sends nothing and the command refuses. Write the entry yourself as a
heredoc, because you are the only thing in the room that knows what happened:

```bash
.claude/hooks/phase.sh validation <<'EOF'
Commands: <exactly what you ran>
Source:   <where you got them — package.json, the Makefile, CI>
Result:   <per command: pass, plus its summary line>
Not covered: <what this repo does not check at all>
EOF
```

`journal` takes an optional one-word label as its argument and the entry on
stdin: `phase.sh journal findings <<'EOF' … EOF`.

Both refuse an empty body rather than recording a stamped header with nothing
under it. For `validation` that refusal is load-bearing — the marker it writes is
what clears 4 → 5, so an empty report would be the gate certifying that nothing
had been run.

**Otherwise** — run `.claude/hooks/phase.sh $ARGUMENTS` and report the output
verbatim. These are yours outright: `status`, `brief`, `red`, `ask`, any retreat
to a lower phase, 1 → 2, and 4 → 5 once the validation report is recorded. `ask`
only prints a question; the answer is what moves anything, and the answer is the
user's.

`off` is never something you reach for unasked, even here. This skill only runs
because the user typed it, so running it is fine — but if you arrived at `off`
by your own reasoning rather than their request, you are ending their task for
them. Ask instead.

Do nothing else. No analysis, and no proceeding to the next phase's work in the
same turn: the user is deciding, not asking you to continue.
