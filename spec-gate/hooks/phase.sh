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

case "${1:-status}" in
  status)
    if [ ! -f "$STATE" ]; then
      echo "spec-driven: inactive"
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
    T=$(sed -n 's/^task=//p' "$STATE" | head -1)
    printf 'phase=%s\ntask=%s\n' "$1" "$T" > "$STATE"
    snapshot_baseline
    echo "spec-driven: -> $(phase_name "$1")"
    ;;

  off)
    rm -f "$STATE" "$BASELINE"
    echo "spec-driven: gate off"
    ;;

  *)
    echo "usage: phase.sh [status | start <task> | 1..5 | off]"
    exit 1
    ;;
esac
