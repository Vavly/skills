# Slicing a long task

Read this in Phase 2, when the Execute step would produce a diff too large to
review in one pass. If it would not, skip it — slicing costs one adversarial
review per slice, and a three-step plan is not sliced.

**Judge it on diff size, not on how complicated the task feels.** A task that is
conceptually hard and mechanically small is one slice.

When it applies, the task lands in slices, each one separately tested, approved
and reviewed: Phase 3 → 4 → 5 per slice, then back to Phase 3 for the next.

## Declaring the seams, in Phase 2

The spec declares them, because the user's `2 → 3` approval means something
different for a sliced task — they are accepting N review cycles, N commits, and
a repo that sits half-built in between. Give the spec a checklist and set the
count:

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
approve. Changing it later raises a prompt, because by then they have approved it.

**Keep the checklist and the count in step.** The count lives in the state file
and the seams live in the spec, and after a compaction whichever is read first is
believed.

If the estimate turns out low mid-task, run `phase.sh slices <n>` again. Running
it asserts *more work than expected*. If instead the design turned out wrong, that
is not a slice change — it is the contradiction rule in
[Standing commitments](../SKILL.md#standing-commitments), so stop and ask to
return to Phase 2.

## Phase 3 on slice 2 and after: no live design session

Phase 2 ran once, and each slice closes its reviewers behind it — so from slice 2
on there is no design session to send the plan to.

Spawn a fresh `spec-adversary` with the full Phase 2 preamble, scoped to this
slice's plan steps, and say which slice it is judging. It has to read the approved
spec itself; it was not there.

## Phase 5 as a boundary rather than the end

At `slice n of total` with slices remaining, Phase 5 is where one increment ends
and the next begins:

1. Commit the reviewed work.
2. Tick the slice off the checklist in the spec.
3. Run `.claude/hooks/phase.sh 3` to open the next one.

**The commit is not optional and the guard enforces it.** `5 → 3` is refused while
anything is owed review, because starting the next slice folds this one's diff
into the new baseline, where the review gate stops seeing it forever. If the
transition is denied, the message names what is outstanding — commit that, do not
look for another way forward.

Then Phase 3 again: the next slice's plan steps, its failing tests, its own RED
check, its own `3 → 4` approval. The user re-approves every lap, on that lap's
evidence.

**Both reviewer sessions end at the boundary too.** The next slice spawns its own,
cold, and that is the point rather than an oversight — see
[reviewer-sessions.md](reviewer-sessions.md#why-neither-session-crosses-a-slice-boundary)
for why a reviewer carrying five slices' diffs is the condition slicing exists to
avoid.

Only when the last slice is reviewed does
[Closing out](../SKILL.md#closing-out) apply.
