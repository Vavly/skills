#!/usr/bin/env bash
# resolve-review-target.sh — decide what an adversarial review is looking at.
#
# Prints exactly one of:
#
#   TARGET: working tree                       ... then the change
#   TARGET: branch <trunk> @ <base>..<tip>     ... then the change
#   STOP: <reason>                             ... and nothing else
#
# The refusal paths exit before `git diff` runs, and that placement is the whole
# guard rather than a nicety. An empty diff is indistinguishable from a change
# with nothing wrong in it, so a reviewer handed one reports `sound` on work it
# never read — the worst outcome available to this role. A warning printed next
# to a diff that runs anyway is worse than no warning, because the transcript
# shows a check that appears to have happened.
#
# Lives beside the SKILL.md that documents it so there is one copy of this
# logic. It used to be a fenced block the reviewer transcribed by hand, and a
# procedure that has to be retyped to be run is a procedure that drifts.

set -uo pipefail

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "STOP: not inside a git work tree — ask what to review; do not diff"
  exit 1
}

# Anything staged, unstaged, or untracked means the work is in front of you.
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "TARGET: working tree"
  echo
  git status --porcelain
  echo
  git diff HEAD
  exit 0
fi

# Nothing there → the work is committed, not absent, and the branch is the unit
# that ships. Every candidate is verified to exist before it is used:
# `git merge-base HEAD main` in a master-trunk repo fails, leaves BASE empty,
# and turns `git diff "$BASE"..HEAD` into `git diff ..HEAD` — which git reads as
# HEAD..HEAD, exit 0, no output.
TRUNK=""; BASE=""; STOP=""; HEADSHA=$(git rev-parse HEAD)
for c in "$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" \
         origin/main origin/master origin/develop main master develop trunk; do
  [ -n "$c" ] || continue
  git rev-parse --verify --quiet "$c^{commit}" >/dev/null || continue
  M=$(git merge-base HEAD "$c" 2>/dev/null) || continue
  [ -n "$M" ] || continue
  # HEAD being the trunk is caught here, not left to prose: merge-base returns
  # HEAD itself, BASE is non-empty, every later guard passes, and the diff is
  # empty with nothing printed at all — strictly quieter than no trunk at all.
  # It is also the likely case, since committing to the trunk and then asking
  # for a review is exactly what branch mode exists for. Break rather than try
  # the next candidate: a base found against some other trunk is not the review
  # anyone wanted.
  if [ "$M" = "$HEADSHA" ]; then
    STOP="HEAD is not ahead of $c, so there is no branch to review"
    break
  fi
  BASE="$M"; TRUNK="$c"; break
done
[ -n "$BASE" ] || STOP="${STOP:-no trunk resolved among the candidates}"

if [ -n "$STOP" ]; then
  echo "STOP: $STOP — ask which ref to review; do not diff"
  exit 1
fi

echo "TARGET: branch $TRUNK @ $(git rev-parse --short "$BASE")..$(git rev-parse --short HEAD)"
echo
git log --oneline "$BASE"..HEAD
echo
git diff "$BASE"..HEAD
