---
name: spec-phase
description: Inspect or advance the spec-driven phase gate.
argument-hint: "[status | start <task> | red | 1-5 | off]"
disable-model-invocation: true
allowed-tools: Bash
---

Requested: `$ARGUMENTS`

First run `.claude/hooks/phase.sh status` to see the current phase. Then:

**If the request is `status`** — report the output verbatim and stop.

**If the request is `2 → 3`, `3 → 4`, or `off` from phase 4 or 5** — run it. Each
raises a confirmation prompt, and accepting it is the user's approval: of the
spec at 2 → 3, of the test failures at 3 → 4, of ending the task at `off`. Say
what you are asking them to approve before you make the call, so the prompt is
not the first they hear of it. If they decline, stop; do not look for another
route forward.

`3 → 4` additionally needs RED verified first — the guard denies it otherwise and
says so. If it does, run `.claude/hooks/phase.sh red`, show its output in full,
and only then advance.

**If the request is `red`** — run it and report the output verbatim, including the
test output. Do not advance in the same turn: the user reads the failures, then
decides.

**If the transition is reserved to the user's terminal** — do not attempt it.
Print the command for them to run and stop:

```
.claude/hooks/phase.sh <n>
```

| From → to | Why it is the user's |
| --- | --- |
| any forward skip (1→3, 2→4, 2→5, 3→5…) | routes around the two approval gates |
| `off` from phases 1–3 | equivalent to jumping to Phase 4 |
| any move off Phase 5 except `off` | phases 1–4 suppress the review gate, so this escapes a review that is owed |
| `start` while already armed | resets to Phase 1 and discards the current task |
| `4 --force` | advances past the RED check on the user's assertion alone |

`phase-guard.sh` denies these when they arrive as a Bash tool call, so attempting
one only wastes a turn on a denial. It cannot tell a call you chose to make from
one this skill told you to make — which is exactly why that checkpoint has to be
taken outside the tool layer entirely.

**Otherwise** — run `.claude/hooks/phase.sh $ARGUMENTS` and report the output
verbatim. These are yours outright: `status`, `red`, any retreat to a lower phase,
1 → 2, and 4 → 5.

`off` is never something you reach for unasked, even here. This skill only runs
because the user typed it, so running it is fine — but if you arrived at `off`
by your own reasoning rather than their request, you are ending their task for
them. Ask instead.

Do nothing else. No analysis, and no proceeding to the next phase's work in the
same turn: the user is deciding, not asking you to continue.
