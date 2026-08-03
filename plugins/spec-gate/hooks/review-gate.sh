#!/usr/bin/env bash
# review-gate.sh — Stop hook. Two jobs, both per-turn:
#
#   1. The phase scan. Catches files that changed during a phase that does not
#      permit them, whatever mechanism wrote them. phase-guard.sh prevents what
#      it can recognise in a Bash command string; this is the layer that is
#      actually complete, because it looks at outcomes instead of intentions.
#   2. The review gate. Refuses to end a turn on a diff that has not been
#      through adversarial review.
#
# Cheap and deterministic on purpose: no model calls, no network. It only decides
# *whether* something is owed. The review itself is done by the `adversary`
# subagent, which Claude spawns — or, on a second pass over the same work,
# resumes — in response to this block. The gate cannot tell those two apart; the
# block message is the only thing asking for the resume.
#
# What the block message does NOT contain is the reviewer's procedure. That lives
# in the `adversarial-review` skill and the subagent loads it itself, so the spawn
# text here is a pointer. Everything this message does spell out is caller-side —
# validate, stage, spawn, act on the verdict — because a read-only reviewer cannot
# do any of it.
#
# Install: .claude/hooks/review-gate.sh  (chmod +x)

set -uo pipefail

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- JSON reading, without a hard jq dependency ------------------------------
# Falls back to python3. If neither parser exists we cannot read
# stop_hook_active, and blocking without a loop guard risks spinning up to the
# consecutive-block cap — so this one fails OPEN, but loudly, rather than
# silently.
PARSER=""
command -v jq      >/dev/null 2>&1 && PARSER=jq
[ -z "$PARSER" ] && command -v python3 >/dev/null 2>&1 && PARSER=python3
if [ -z "$PARSER" ]; then
  echo "review-gate: neither jq nor python3 on PATH; review gate is INACTIVE." >&2
  exit 0
fi

json_get() {  # $1 = dotted path
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
print(str(d).lower() if isinstance(d, bool) else d)
' "$1" 2>/dev/null ;;
  esac
}

# --- Loop guard --------------------------------------------------------------
# stop_hook_active is true when this Stop was reached because a Stop hook
# already blocked earlier in the same turn. Exactly one forced pass per user
# turn, so this can never spin.
[ "$(json_get stop_hook_active)" = "true" ] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(json_get cwd)}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

if [ ! -r "$HOOK_DIR/phase-policy.sh" ]; then
  echo "review-gate: phase-policy.sh not found next to it in $HOOK_DIR; phase scan is INACTIVE." >&2
else
  # shellcheck source=phase-policy.sh
  . "$HOOK_DIR/phase-policy.sh"
fi

PHASE=$(sed -n 's/^phase=//p' .claude/.spec-phase 2>/dev/null | head -1)

# --- 0. One tree per task ----------------------------------------------------
# This scan compares PROJECT_DIR's tree against PROJECT_DIR's baseline. On a
# split that is the wrong tree, and being the completeness layer, it fails the
# quietest way there is: it looks at a clean checkout, finds nothing owed, and
# passes a turn whose work it never saw. Both directions of the split end here.
if command -v spec_foreign_state >/dev/null 2>&1; then
  SPLIT=""
  if [ -z "$PHASE" ]; then
    F=$(spec_foreign_state "$PROJECT_DIR")
    [ -n "$F" ] && SPLIT=$(spec_split_message "$F" "$(spec_realpath "$PROJECT_DIR")")
  else
    D=$(spec_related_siblings "$PROJECT_DIR" | tr '\n' ' ')
    [ -n "$D" ] && SPLIT="spec-driven is armed in $(spec_realpath "$PROJECT_DIR"), and this task's own spec document is in another worktree that has uncommitted work: $D. This scan only ever looks at the armed tree, so ending the turn here would pass work it has not examined. Commit or clear that tree, or move the task to it — spec-gate enforces one tree at a time and cannot vouch for the other. Worktrees that do not carry this task's spec are not affected."
  fi
  if [ -n "$SPLIT" ]; then
    { echo "TREE SPLIT: the gate and the work are not in the same worktree."
      echo
      echo "$SPLIT"
    } >&2
    exit 2
  fi
fi

# --- 1. Phase scan -----------------------------------------------------------
# Compares the working tree against the snapshot taken when the phase was
# entered, so pre-existing dirty files are not blamed on this phase. Runs for
# phases 1-3, the phases that restrict what may be written.
if command -v tree_snapshot >/dev/null 2>&1; then
  case "$PHASE" in
    1|2|3)
      BASESNAP=$(cat .claude/.spec-baseline 2>/dev/null)
      VIOLATIONS=""
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Exact-line match: unchanged since the phase began.
        case $'\n'"$BASESNAP"$'\n' in
          *$'\n'"$line"$'\n'*) continue ;;
        esac
        p=${line#* }
        is_phase_state "$p" && continue
        path_allowed_in_phase "$PHASE" "$p" || VIOLATIONS="$VIOLATIONS  $p"$'\n'
      done <<< "$(tree_snapshot)"

      if [ -n "$VIOLATIONS" ]; then
        {
          echo "PHASE GATE: files changed during Phase $PHASE that this phase does not permit:"
          echo
          printf '%s' "$VIOLATIONS"
          echo
          echo "Phase 1 clarifies and writes nothing. Phase 2 writes docs/specs/ only."
          echo "Phase 3 writes tests only."
          echo
          echo "Revert these changes before ending the turn. If the work genuinely"
          echo "belongs in this phase, say so and ask the user to advance — do not"
          echo "advance yourself, and do not edit the phase state."
        } >&2
        exit 2
      fi
      ;;
  esac
fi

# --- Defer the review gate to the workflow -----------------------------------
# When the spec-driven workflow is driving, it owns the review checkpoint: Phase
# 5 delegates to `adversary` explicitly. Firing here as well would review the
# same work twice and pay twice.
#
# Phases 1-3 have nothing reviewable (specs and deliberately-failing tests).
# Phase 4 is deferred so execution isn't interrupted every turn. If you would
# rather have per-turn review during Execute, drop the 4 from this list — you
# get incremental review at incremental cost.
#
# With no phase file this is inert and the gate runs every turn. That is the
# intended default for ordinary work.
case "$PHASE" in 1|2|3|4) exit 0 ;; esac

# --- 2. Is anything owed review? ---------------------------------------------
# tree_snapshot contributes content hashes for untracked files. Without it the
# fingerprint moved only when a *tracked* file changed, so fixes to new files —
# usually the actual work — were never re-reviewed.
#
# Excluded paths are kept out of the fingerprint entirely rather than filtered
# afterwards, so they cannot move it. Otherwise a spec doc left uncommitted after
# the code shipped keeps the gate armed forever, and committing finished work
# re-arms it: `git diff HEAD` empties as HEAD moves, changing the fingerprint
# even though the content is byte-identical.
# --- The fingerprint is index-invariant, deliberately -------------------------
# `git add` must not read as a change, because the workflow stages the work
# before the first review round: from then on `git diff` is exactly what moved
# since the reviewer's last verdict, which is the cheapest possible way to show a
# reviewer where the fixes are. Staging is bookkeeping, not work.
#
# The two obvious sources are both index-sensitive and were both in here:
# `git status --porcelain` rewrites its status codes when a file is staged
# (`?? f` becomes `A  f`), and `git diff HEAD` starts including a new file the
# moment it is added, having ignored it while untracked. Either one moves the
# fingerprint on byte-identical content, which is the "committing re-armed the
# gate" failure arriving through a different door — and this door is one the
# workflow now walks through on every task.
#
# So the fingerprint is built only from things `git add` cannot move:
#   - content hashes of every dirty or untracked file, from tree_snapshot
#   - paths HEAD has that the working tree does not, i.e. deletions, which
#     tree_snapshot drops because it only hashes files that exist
#   - mode changes on tracked files, from `git diff HEAD --summary`. A *new*
#     file's mode shows up there only once it is staged, so it is carried instead
#     by the `x` flag tree_snapshot puts on the hash field — same reason, one
#     source each side of the tracked/untracked line.
#
# It is computed in phase-policy.sh, because review-bookmark.sh records a round
# with the same function. Two copies would diverge into a delta that reports
# nonsense while looking authoritative.
if command -v review_fingerprint >/dev/null 2>&1; then
  CHANGES=$(review_fingerprint)
else
  # phase-policy.sh is gone, so the shared snapshot this fingerprint is built on
  # is gone with it. Fall back to the index-sensitive pair instead of to nothing:
  # a spurious review round after a `git add` costs tokens, while a gate that
  # quietly stopped firing costs the whole guarantee. Duplicating tree_snapshot
  # here would be the other kind of mistake — one copy of that logic, by design.
  echo "review-gate: no tree_snapshot; the fingerprint is index-sensitive, so staging may cost one extra review round." >&2
  CHANGES=$( { git diff HEAD
               git status --porcelain
             } 2>/dev/null )
fi

# --- The marker: one review round's snapshot, not just its hash ---------------
# Line 1 is the fingerprint, the rest is the snapshot it was computed from. The
# hash alone answered "is this the same diff?"; keeping the snapshot also answers
# "what moved since?", which is the question the *next* round asks and the one
# thing here a hook can settle instead of a prompt. Whether the author staged in
# the right order, and whether their account of the fixes is complete, are both
# claims; this list is a fact.
#
# A marker written by an older version holds the hash alone. That still compares
# correctly on line 1, and the empty snapshot below simply means no delta is
# reported for one round — the same as any first round.
#
# The gate is no longer the only writer. review-bookmark.sh records a round the
# moment `adversary` returns a verdict, which is what the delta message has always
# claimed to be measuring — the gate can only see rounds it mediated, and it never
# mediates the first one in Phase 5, where the workflow spawns the reviewer
# itself. Before that, the first block after a completed review round reported no
# delta at all, correctly and uselessly.
MARKER=$(review_marker_path 2>/dev/null) || MARKER="$(git rev-parse --git-dir)/claude-review-gate"

if [ -z "$CHANGES" ]; then
  # Clean tree: nothing is owed, and no round is in flight. Dropping the marker
  # keeps the next task's first round from reporting the last task's committed
  # work as "no longer differs from HEAD", which is true and useless.
  rm -f "$MARKER"
  exit 0
fi

HASH=$(printf '%s' "$CHANGES" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
PREV_HASH=""; PREV_SNAP=""
if [ -f "$MARKER" ]; then
  PREV_HASH=$(head -1 "$MARKER" 2>/dev/null)
  PREV_SNAP=$(tail -n +2 "$MARKER" 2>/dev/null)
fi

[ "$PREV_HASH" = "$HASH" ] && exit 0   # this exact diff already went through the gate

{ printf '%s\n' "$HASH"; printf '%s\n' "$CHANGES"; } > "$MARKER"

# --- What moved since the last round ------------------------------------------
# Exact-line comparison, the same idiom the phase scan uses against its baseline:
# a path whose snapshot line is byte-identical has not moved, whatever the index
# says about it. Paths are reported, not hunks — the reviewer has git for hunks.
DELTA=""
# The fallback fingerprint is raw diff text rather than snapshot lines, so there
# is nothing to extract paths from and no helper to do it with. No delta then.
if [ -n "$PREV_SNAP" ] && command -v snapshot_line_path >/dev/null 2>&1; then
  CHANGED=""; GONE=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case $'\n'"$PREV_SNAP"$'\n' in
      *$'\n'"$line"$'\n'*) continue ;;
    esac
    CHANGED="$CHANGED  $(snapshot_line_path "$line")"$'\n'
  done <<< "$CHANGES"

  # The reverse direction has to compare *paths*: a file that changed appears in
  # both snapshots under different lines, and reporting it as gone as well would
  # be a lie in the one place the message is claiming to state facts.
  cur_paths=$(printf '%s\n' "$CHANGES" | while IFS= read -r l; do
                [ -n "$l" ] && snapshot_line_path "$l"; done)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    p=$(snapshot_line_path "$line")
    case $'\n'"$cur_paths"$'\n' in
      *$'\n'"$p"$'\n'*) continue ;;
    esac
    GONE="$GONE  $p"$'\n'
  done <<< "$PREV_SNAP"

  [ -n "$CHANGED" ] && DELTA="${DELTA}Changed since the last review round:"$'\n'"$CHANGED"
  [ -n "$GONE" ]    && DELTA="${DELTA}No longer differs from HEAD (reverted or committed):"$'\n'"$GONE"
fi

# --- Block, with an instruction ---------------------------------------------
# stderr on exit 2 goes to Claude as feedback.
cat >&2 <<'EOF'
REVIEW GATE: the working tree has changes that have not been through
adversarial review.
EOF

if [ -n "$DELTA" ]; then
  printf '\n%s' "$DELTA" >&2
  cat >&2 <<'EOF'

This list is the gate's, not yours: it is what the fingerprint says moved since
the round it last recorded. Give it to the reviewer verbatim. If it disagrees
with what you believe you changed, the list is right and something is unaccounted
for — say so rather than reconciling it silently.
EOF
fi

cat >&2 <<'EOF'

Before ending this turn:

1. **Already reviewed this work once? Go back to the same `adversary` session**
   — send it a message, do not spawn a second reviewer. That session made the
   findings you just fixed, so it is the only one that can tell you whether the
   fix landed; a fresh one re-reads the diff blind and cannot.

   ---
   The working tree has changed since your verdict. These paths moved since the
   round you last saw: <paste the gate's list from above>. Everything you had
   already judged is staged, so `git diff` should show the same set.

   Validations still pass: <the delta, or "same commands, same result">.

   Findings I acted on: <list>. Findings I left: <list>. Check all of that
   against the code rather than taking it from me — anything you still consider
   open, report again, and anything I broke is new. If it holds up now, say
   `sound` and stop.
   ---

   The path list is the gate's and is not negotiable. My list of findings is a
   claim, and so is the staging: if `git diff` and the path list disagree, the
   path list is the one that is right.

   Do not explain why the fix is right, and do not argue a finding you declined —
   that argument goes to the user, not back to the reviewer. A reviewer talked
   round to your position has stopped being one.

2. Otherwise, this is round one, and it starts with two things before any
   reviewer exists.

   **Run what this repo validates a change with, and get it green.** Find what it
   already uses — its pre-commit hook, its CI workflow, what CONTRIBUTING tells a
   human to run — do not invent a list. A reviewer spawned onto a red tree spends
   its read on breakage you already knew about.

   Then write the report, with these labels exactly — the reviewer is told to
   read `Not covered` first and looks for it by name:

   ```
   VALIDATION REPORT
   Commands: <exactly what you ran>
   Source:   <where you got them>
   Result:   <per command: pass, plus its summary line>
   Not covered: <what this repo checks nothing about at all>
   ```

   `Not covered` is the one the reviewer cannot work out for itself and the one
   you will be tempted to leave blank. It is where the mechanical net has holes —
   no type checker, no integration tests, a suite that never runs the concurrent
   path — which is exactly where a defect survives everything downstream too.

   **Do not run `git add` — the gate stages for you**, on the way into the
   reviewer and again the moment its verdict lands. From then on the index holds
   what the reviewer has seen and `git diff` holds your response to it, which is
   what step 1 relies on. This used to be your job and it went wrong silently:
   staging after fixing folds the fixes into the index and the reviewer opens
   `git diff` on what looks like an untouched tree.

3. Now spawn the `adversary` subagent. **It loads its own procedure from the
   `adversarial-review` skill**, so your message is a pointer, not a briefing —
   name the skill first, the intent second, and stop:

   ---
   Use the `adversarial-review` skill and follow it. You are reviewing the
   working tree.

   The intent of the change, which is the only thing I am telling you:
   <one or two sentences>

   The repo's validations pass on this change:
   ```
   <the report from step 2>
   ```
   ---

   No summary of your approach, no defense of your choices, no list of what you
   think it should look at, and no restating the skill's instructions back at it.
   Priming it defeats the purpose of the gate.

   Keep the handle the spawn returns. It is what step 1 needs next turn.

4. Act on the result. The staging is already done — the gate ran `git add -A` the
   moment the verdict landed, before you could touch anything, so the tree as it
   stands is what the reviewer has seen and everything you do from here is the
   next round's `git diff`. Never stage between fixing and messaging; you have no
   reason to run `git add` at all during a review round.
   - `blocker` or `serious` findings: fix them, then stop. The gate will
     re-fingerprint the new diff, and the reviewer that found them judges the
     fixes on the next turn.
   - `minor` findings: report them to the user with your recommendation. Do not
     silently fix or silently drop them.
   - `sound`: say so and stop.
   - `cannot-assess`: report what the reviewer said it needed. Do not treat
     this as a pass.

5. If you disagree with a finding, say so explicitly and give your reasoning.
   Do not quietly discard it — a disagreement is information the user wants.

Do not edit this hook or the marker file to get past this gate.
EOF
exit 2
