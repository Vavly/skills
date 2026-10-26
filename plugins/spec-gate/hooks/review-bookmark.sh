#!/usr/bin/env bash
# review-bookmark.sh — SubagentStart / SubagentStop hook on the two reviewers.
#
# Maintains the index convention the reviewers depend on, and records the round
# the gate would otherwise have no memory of. Both were prose before, stated four
# times across two SKILL.md files and both agent briefs, and both failed in real
# use — which is this project's own thesis: prompts raise the average, hooks raise
# the minimum, and anything that must *always* happen is a hook.
#
# Two jobs, both bookkeeping, neither a judgment:
#
#   1. Stage. On the way in, so the reviewer's `git diff` is empty and everything
#      it judges is `git diff HEAD`. On the way out, the moment the verdict lands
#      and before the caller can touch anything, so the next round's `git diff` is
#      exactly the response to that verdict.
#
#      Doing this on the way out is the half that kept going wrong, and the
#      failure was silent in the dangerous direction: staging *after* revising
#      folds the fixes into the index, and the reviewer opens `git diff` on what
#      looks like an untouched tree. Observed three times in one week of use —
#      "the index holds the revision, not the version I judged".
#
#   2. Record what the reviewer just saw, when it was `adversary`. The gate writes
#      its marker only when it blocks, and it is suppressed for phases 1-4, so the
#      first Phase 5 round — the one the workflow spawns itself — completed before
#      the gate had ever run. Its first block then reported no delta, which read
#      as "nothing moved since the last round" when the truth was "I have no
#      record of a round that did happen".
#
# Deliberately NOT recorded for `spec-adversary`. It judges the design, at phases
# 2 and 3, and seeding the code reviewer's marker from a Phase 2 tree would make
# Phase 5's first delta list every file written in phases 3 and 4. One marker, one
# subject.
#
# `git add -A` is safe to automate for exactly the reasons the convention relies
# on: it is idempotent, it destroys nothing, and the review fingerprint is built
# from file contents rather than index state, so it can never re-arm the gate or
# cost a review round. What it does do is stage unrelated dirty work you happened
# to have; `git restore --staged <path>` puts that back.
#
# Everything here exits 0. Failing to stage costs a re-read; failing to record
# costs one round with no delta, which is where this started. Neither is worth
# disturbing a turn over.
#
# Install: .claude/hooks/review-bookmark.sh  (chmod +x)

set -uo pipefail

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

PARSER=""
command -v jq      >/dev/null 2>&1 && PARSER=jq
[ -z "$PARSER" ] && command -v python3 >/dev/null 2>&1 && PARSER=python3
[ -n "$PARSER" ] || exit 0

json_get() {
  case "$PARSER" in
    jq)      printf '%s' "$INPUT" | jq -r ".$1 // empty" 2>/dev/null ;;
    python3) printf '%s' "$INPUT" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for k in sys.argv[1].split("."):
    if isinstance(d, dict) and k in d: d = d[k]
    else: sys.exit(0)
if d is None: sys.exit(0)
print(d)
' "$1" 2>/dev/null ;;
  esac
}

EVENT=$(json_get hook_event_name)
AGENT=$(json_get agent_type)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(json_get cwd)}"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# The matcher in settings.json already scopes this to the two reviewers. Checking
# again here means a copy of this hook wired to a wider matcher still cannot stage
# on someone else's subagent.
case "$AGENT" in
  adversary|spec-adversary) ;;
  *) exit 0 ;;
esac

# --- 1. Stage ----------------------------------------------------------------
git add -A >/dev/null 2>&1

# --- 2. Record the round -----------------------------------------------------
# Only on the way out, and only for the code reviewer. A missing agent_type means
# we cannot tell which reviewer this was, so nothing is recorded and the gate
# falls back to writing the marker at its own first block — which is exactly what
# it did before this hook existed.
[ "$EVENT" = "SubagentStop" ] || exit 0
[ "$AGENT" = "adversary" ] || exit 0

[ -r "$HOOK_DIR/phase-policy.sh" ] || exit 0
# shellcheck source=phase-policy.sh
. "$HOOK_DIR/phase-policy.sh"
command -v review_fingerprint >/dev/null 2>&1 || exit 0

write_review_marker "$(review_fingerprint)"

exit 0
