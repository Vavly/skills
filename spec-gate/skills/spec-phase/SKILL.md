---
name: spec-phase
description: Inspect or advance the spec-driven phase gate.
argument-hint: "[status | start <task> | 1-5 | off]"
disable-model-invocation: true
allowed-tools: Bash
---

Requested: `$ARGUMENTS`

First run `.claude/hooks/phase.sh status` to see the current phase. Then:

**If the request is `status`** — report the output verbatim and stop.

**If the request is `2 → 3`** — run it. It will raise a confirmation prompt, which
is the user approving the spec. Say what you are asking them to approve before
you make the call, so the prompt is not the first they hear of it. If they
decline, stop; do not look for another route to Phase 3.

**If the transition is reserved to the user's terminal** — do not attempt it.
Print the command for them to run and stop:

```
.claude/hooks/phase.sh <n>
```

| From → to | Why it is the user's |
| --- | --- |
| 3 → 4 | unlocks production code, and asserts RED was observed — a prompt is too easy to click through for that |
| any forward skip (1→3, 2→4, 2→5, 3→5…) | routes around the gates above |
| `off` from phases 1–3 | equivalent to jumping to Phase 4 |
| any move off Phase 5 except `off` | phases 1–4 suppress the review gate, so this escapes a review that is owed |
| `start` while already armed | resets to Phase 1 and discards the current task |

`phase-guard.sh` denies these when they arrive as a Bash tool call, so attempting
one only wastes a turn on a denial. It cannot tell a call you chose to make from
one this skill told you to make — which is exactly why that checkpoint has to be
taken outside the tool layer entirely.

**Otherwise** — run `.claude/hooks/phase.sh $ARGUMENTS` and report the output
verbatim. These are yours outright: `status`, any retreat to a lower phase, 1 → 2,
4 → 5, and `off` from phases 4 or 5.

Do nothing else. No analysis, and no proceeding to the next phase's work in the
same turn: the user is deciding, not asking you to continue.
