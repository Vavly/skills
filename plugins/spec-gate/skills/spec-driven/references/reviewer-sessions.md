# Why the reviewer sessions work the way they do

Background for [The two reviewer sessions](../SKILL.md#the-two-reviewer-sessions).
The operative rules are in SKILL.md; this is the reasoning behind them, and the
failures that produced each one. Read it when a session rule looks like overhead
and you are about to route around it — every rule here is the scar of a round that
was paid for and bought nothing.

## Why reuse rather than respawn

The second round is where review usually goes wrong. A fresh reviewer re-reads
everything blind, does not know that a line exists to close a finding it never
saw, and so cannot say whether the fix worked — only what it thinks of the code
now. That is a different and much weaker claim, and it arrives in the same shape
as the one you wanted, which is what makes it easy to accept.

The session that made the finding can answer *did the fix work?* Nothing else in
the system can.

## Why the two sessions never merge

A design reviewer that has read the diff stops judging the design: it starts
grading the implementation it can see against the spec it already knows, which is
a code review with worse inputs.

A code reviewer that has read the spec is the more expensive failure. It starts
checking the code against the author's stated intent — and withholding exactly
that is what makes `adversary` a review rather than a confirmation. Pointing the
design reviewer at a diff to save a spawn buys one spawn and costs the property
the whole role exists for.

## Why neither session crosses a slice boundary

A code reviewer still holding the previous slice's diff re-reports work that is
already committed and reviewed, and grades the new diff on credit the last one
earned. By slice five it is carrying five diffs — which is the exact condition
slicing exists to avoid, reassembled inside the reviewer.

It also keeps `adversary` ignorant of the slice structure, which it should be.
Tell it "this is slice 2 of 5" and it starts excusing a gap as *coming later*;
refusing to grant that is most of what it is for.

`spec-adversary` is the opposite case. It judges plans, and *"slice 2 needs the
types slice 3 introduces"* is only findable by a reviewer that can see the
ordering — which is why the design session spans a slice's own phases 2 and 3 and
still stops at its boundary.

## Why the index is the bookmark, and why you no longer maintain it

Round two has a problem round one does not: the reviewer has to find the fixes
inside a diff it has already read. Git answers that for free, if one invariant
holds — **staged is what the reviewer has already judged, unstaged is what has
moved since.** Then `git diff` is exactly the response to the verdict, and
`git diff HEAD` is still the whole change.

Two `git add` calls maintain it: one before the first round, one the moment each
verdict lands and *before* anything is touched in response.

**Both are made by `review-bookmark.sh`, on `SubagentStart` and `SubagentStop`.**
That was the caller's job first — stated in this workflow, in the review gate's
block message, and in what both reviewers are told about reading the index, four
copies of one instruction — and it broke three times in the first week of real
use, always the same way and always silently:

> `git diff` was empty — the spec is staged as a whole new file, so the index
> holds the *revision*, not the version I judged — `spec-adversary`
>
> the index is stale, so the diff wasn't usable as a bookmark — `spec-adversary`

Nothing shipped wrong, because both reviewers refuse a `sound` verdict reasoned
from an empty diff and re-read `git diff HEAD` instead. But that is the failure
being *survived*, not avoided: every one of those rounds paid the full re-read the
convention exists to save. Four copies of an instruction is what it looks like
when something that must always happen was left to a prompt.

**Why the ban is total rather than aimed at the one bad ordering.** Staging
between fixing and messaging is what destroys the signal, and it destroys it in
the dangerous direction: the fixes go into the index, the reviewer opens
`git diff` on what looks like an untouched tree, and *nothing moved since my
verdict* reads as *nothing to re-review*. Every ordering that breaks the bookmark
begins with a `git add` the hook did not make — so *never run `git add` during a
review round* is the superset, and the earlier, narrower *never stage between
fixing and messaging* is the version that shipped while the convention was
breaking weekly.

`git restore --staged <path>` is still fine and still worth doing. Pulling
something back out of the index breaks nothing.

## Why `git add -A` is not a widening of scope, and costs no review round

`review-bookmark.sh` stages whatever else is dirty. That is the same set the
review gate is already treating as the subject of review, so nothing enters scope
by being staged.

And staging is not a change: the review gate fingerprints file *contents* plus
deletions and mode changes, never index state, so a `git add` cannot re-arm it.
That property is load-bearing rather than incidental — without it the workflow
would pay for a review of having run `git add` on every round.

## Why the reviewers keep a backstop for a hook that should not fail

The hook can be absent: a partial install, no `jq` or `python3`, or Cursor, which
has no equivalent event. So both reviewers also carry the rule directly — **an
empty `git diff` is not evidence that nothing changed.** It is equally consistent
with the convention having been broken, and only one of the two makes `sound` an
honest verdict. They re-read `git diff HEAD` and say which of the two they
concluded.

It lives in [adversarial-review](../../adversarial-review/SKILL.md) for the code
side and in `spec-adversary`'s brief for the design side.

## What reuse costs, and what pays for it

A reviewer holding its own findings is inclined to accept a fix *because the fix
is what it asked for*. Round two hands it your account of those fixes on top of
that, which is a second thumb on the same scale.

Three things push back. Two are in the reviewers' briefs: the list you send is a
claim to check rather than a report to accept, and a fix is judged as new code
rather than as compliance with a request. The third is yours — **keep the argument
out.** No explanation of why the fix is right, no case for a finding you declined.
That case goes to the user, in the evidence log, where they can weigh it. Telling
a reviewer why you were right buys agreement, not a review, and a reviewer talked
round to your position has stopped being one.

Naming which findings you touched is fine, and so is pointing at the diff: the
reviewer already holds the findings, so there is no independent judgment left to
protect, and making it hunt for your edits buys nothing but a re-read.
