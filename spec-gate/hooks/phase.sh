#!/usr/bin/env bash
# phase.sh — read and set spec-driven phase state.
#
# The user's control surface. Advancing into a phase that widens write access
# (2->3 and 3->4) has to be run from a real terminal: phase-guard.sh denies
# those transitions when they arrive as a Bash tool call, because a PreToolUse
# hook cannot tell a call the model chose to make from one a slash command made.
#
# Install: .claude/hooks/phase.sh  (chmod +x)
# Add .claude/.spec-phase and .claude/.spec-baseline to .gitignore

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
STATE_DIR="$PROJECT_DIR/.claude"
STATE="$STATE_DIR/.spec-phase"
BASELINE="$STATE_DIR/.spec-baseline"
TEST_CMD_FILE="$STATE_DIR/spec-gate-test-cmd"

# tree_snapshot comes from phase-policy.sh, shared with review-gate.sh so the
# baseline and the scan that reads it are computed the same way. Without it this
# script still reports and clears state; only the baseline is skipped.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$HOOK_DIR/phase-policy.sh" ]; then
  # shellcheck source=phase-policy.sh
  . "$HOOK_DIR/phase-policy.sh"
else
  echo "phase.sh: warning — phase-policy.sh not found; no baseline will be recorded." >&2
  tree_snapshot() { :; }
fi

# Indexing an array with an unvalidated value out of the state file used to
# abort this script with "unbound variable" under set -u. A case is total.
phase_name() {
  case "$1" in
    1) printf '1 Clarify' ;;
    2) printf '2 Spec' ;;
    3) printf '3 Plan + failing tests' ;;
    4) printf '4 Execute' ;;
    5) printf '5 Adversarial review' ;;
    *) printf 'corrupt (phase=%s)' "$1" ;;
  esac
}

# Records a content fingerprint of everything already dirty at phase entry, so
# the Stop scan in review-gate.sh can separate files this phase changed from
# files that were already dirty when it began. Without a baseline the scan
# blames the model for the user's own uncommitted work.
snapshot_baseline() {
  : > "$BASELINE" 2>/dev/null || return 0
  (
    cd "$PROJECT_DIR" 2>/dev/null || exit 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
    tree_snapshot > "$BASELINE" 2>/dev/null
  )
}

# --- RED tripwire -------------------------------------------------------------
# Phase 3 -> 4 is the one transition that rests on a claim no hook can check:
# "I saw the new tests fail for the reason I expect." Requiring a terminal makes
# the claim deliberate; it does not make it true.
#
# So check the cheap half mechanically. Run the tests Phase 3 changed: if they
# PASS with no implementation written, they are testing nothing, and advancing
# would carry that mistake into Execute. This converts "trust me, they are red"
# into "verified not-green" — narrower than "failing for the right reason", which
# stays human, but it catches the vacuous-test failure mode outright.
#
# This runs in the user's own terminal, so it has no hook timeout to respect and
# can take as long as the tests take. Its output is also exactly the failure
# output Phase 3 asks to see.

# Test files changed since the phase began, from the same snapshot the Stop scan
# uses. One line per file, space separated.
changed_test_files() {
  (
    cd "$PROJECT_DIR" 2>/dev/null || exit 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
    base=$(cat "$BASELINE" 2>/dev/null)
    tree_snapshot | while IFS= read -r line; do
      [ -z "$line" ] && continue
      case $'\n'"$base"$'\n' in
        *$'\n'"$line"$'\n'*) continue ;;   # unchanged since phase entry
      esac
      p=${line#* }
      is_test_path "$p" && printf '%s ' "$p"
    done
  )
}

# 0 = go ahead, 1 = refuse
red_tripwire() {
  cur=$(sed -n 's/^phase=//p' "$STATE" | head -1)
  [ "$cur" = "3" ] || return 0          # only 3 -> 4 asserts RED

  if [ ! -r "$TEST_CMD_FILE" ]; then
    echo "spec-driven: no RED tripwire configured, advancing on your assertion alone."
    echo "  To verify it automatically, put a command in $TEST_CMD_FILE"
    echo "  It runs with \$SPEC_GATE_TEST_FILES set to the tests this phase changed."
    return 0
  fi

  files=$(changed_test_files)
  if [ -z "$files" ]; then
    echo "spec-driven: REFUSED — no test files changed during Phase 3."
    echo "  Phase 3 exists to produce failing tests. Write them first."
    echo "  Override with: phase.sh 4 --force"
    return 1
  fi

  echo "spec-driven: verifying the new tests fail before unlocking production code"
  echo "  tests: $files"
  echo
  (
    cd "$PROJECT_DIR" 2>/dev/null || exit 0
    SPEC_GATE_TEST_FILES="$files" sh -c "$(cat "$TEST_CMD_FILE")"
  )
  rc=$?
  echo
  if [ $rc -eq 0 ]; then
    echo "spec-driven: REFUSED — those tests PASSED."
    echo "  A test that passes before the implementation exists is testing nothing."
    echo "  Fix the tests so they fail for the reason you expect, then advance again."
    echo "  Override with: phase.sh 4 --force"
    return 1
  fi
  echo "spec-driven: tests failed as required — RED verified (exit $rc)."
  echo "  Note: this proves not-green, not that they failed for the right reason."
  echo "  That part is still yours to have checked in the output above."
  return 0
}

# Files the review gate would consider owed review — i.e. excluding the paths it
# ignores. Reported by `status` and `off` because the surprising part of this
# system is that turning the phase gate OFF makes review fire *more* often, not
# less: with no phase file the Stop gate runs every turn.
review_pending_paths() {
  (
    cd "$PROJECT_DIR" 2>/dev/null || exit 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
    { git diff HEAD --name-only
      git ls-files --others --exclude-standard
    } 2>/dev/null | sort -u | while IFS= read -r p; do
      [ -z "$p" ] && continue
      is_review_excluded "$p" || printf '%s\n' "$p"
    done
  )
}

report_review_state() {
  pending=$(review_pending_paths)
  if [ -z "$pending" ]; then
    echo "  review gate: quiet — nothing is owed review"
  else
    echo "  review gate: ARMED — owed review every turn until these are committed:"
    printf '%s\n' "$pending" | sed 's/^/      /'
  fi
}

case "${1:-status}" in
  status)
    if [ ! -f "$STATE" ]; then
      echo "spec-driven: inactive"
      report_review_state
      exit 0
    fi
    P=$(sed -n 's/^phase=//p' "$STATE" | head -1)
    T=$(sed -n 's/^task=//p' "$STATE" | head -1)
    echo "spec-driven: phase $(phase_name "$P")  (task: ${T:-unnamed})"
    case "$P" in
      1) echo "  -> no files may be written"
         echo "  -> next: 2 Spec — Claude may advance" ;;
      2) echo "  -> docs/specs/ only"
         echo "  -> next: 3 Plan + tests — USER ONLY: run '.claude/hooks/phase.sh 3' in a terminal" ;;
      3) echo "  -> tests only; production code blocked"
         echo "  -> next: 4 Execute — USER ONLY: run '.claude/hooks/phase.sh 4' in a terminal" ;;
      4) echo "  -> normal permission flow; tests frozen; review gate suppressed"
         echo "  -> next: 5 Review — Claude may advance" ;;
      5) echo "  -> delegate to the adversary subagent; review gate ARMED" ;;
      *) echo "  -> state file is corrupt, and the gate is failing closed."
         echo "  -> recover with: .claude/hooks/phase.sh off" ;;
    esac
    ;;

  start)
    mkdir -p "$STATE_DIR"
    # A newline in the task name would inject extra lines into the state file.
    T=$(printf '%s' "${2:-unnamed}" | tr -d '\n\r')
    printf 'phase=1\ntask=%s\n' "$T" > "$STATE"
    snapshot_baseline
    echo "spec-driven: started '${T}' at phase 1 (Clarify)"
    ;;

  1|2|3|4|5)
    [ -f "$STATE" ] || { echo "spec-driven: not started. Run: phase.sh start <task>"; exit 1; }
    if [ "$1" = 4 ]; then
      case "${2:-}" in
        --force)
          echo "spec-driven: --force — skipping the RED tripwire on your assertion." ;;
        *)
          red_tripwire || exit 1 ;;
      esac
    fi
    T=$(sed -n 's/^task=//p' "$STATE" | head -1)
    printf 'phase=%s\ntask=%s\n' "$1" "$T" > "$STATE"
    snapshot_baseline
    echo "spec-driven: -> $(phase_name "$1")"
    ;;

  off)
    rm -f "$STATE" "$BASELINE"
    echo "spec-driven: phase gate off"
    echo "  This ends the phase workflow. It does not stop review — with no phase"
    echo "  file the Stop gate returns to its default and runs EVERY turn."
    report_review_state
    ;;

  *)
    echo "usage: phase.sh [status | start <task> | 1..5 | off]"
    echo "       phase.sh 4 --force   skip the RED tripwire"
    exit 1
    ;;
esac
