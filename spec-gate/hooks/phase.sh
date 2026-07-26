#!/usr/bin/env bash
# phase.sh — read and set spec-driven phase state.
#
# The user's control surface. The two transitions that widen the model's write
# access (2->3 and 3->4) are theirs: phase-guard.sh turns both into confirmation
# prompts rather than letting the model take them silently. Forward skips, which
# would route around either gate, are denied outright and need a real terminal.
#
# Install: .claude/hooks/phase.sh  (chmod +x)
# Add .claude/.spec-phase, .claude/.spec-baseline and .claude/.spec-red to
# .gitignore

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
STATE_DIR="$PROJECT_DIR/.claude"
STATE="$STATE_DIR/.spec-phase"
BASELINE="$STATE_DIR/.spec-baseline"
RECEIPT="$STATE_DIR/.spec-red"
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
  # Stubs, so a missing policy file degrades to a refusal rather than to
  # "command not found" and an advance nobody checked.
  changed_test_snapshot() { :; }
  changed_test_files() { :; }
  red_receipt_status() { printf 'unverifiable\n'; }
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

# --- RED verification ---------------------------------------------------------
# Phase 3 -> 4 is the one transition that rests on a claim no hook can check:
# "I saw the new tests fail for the reason I expect."
#
# The cheap half is checkable. Run the tests Phase 3 changed: if they PASS with
# no implementation written, they are testing nothing, and advancing would carry
# that mistake into Execute. This converts "trust me, they are red" into
# "verified not-green" — narrower than "failing for the right reason", which
# stays human, but it catches the vacuous-test failure mode outright.
#
# `phase.sh red` is the model's to run, deliberately. Running it in the user's
# terminal put the failure output in the one place the model could not read, so
# the evidence Phase 3 exists to produce never entered the conversation. Run as a
# tool call it lands in the transcript, where the user reads it before approving.
#
# What it leaves behind is a receipt pinning the content of every test file it
# verified — see phase-policy.sh. The guard offers 3 -> 4 as a confirmation
# prompt only while that receipt matches the tests on disk.

# 0 = verified RED (receipt written), 1 = refused, 2 = cannot verify
verify_red() {
  if [ ! -r "$TEST_CMD_FILE" ]; then
    echo "spec-driven: no test command configured, so RED cannot be verified here."
    echo "  Put a command in $TEST_CMD_FILE — it runs from the project root with"
    echo "  \$SPEC_GATE_TEST_FILES set to the test files this phase changed. e.g."
    echo "      printf 'yarn jest \$SPEC_GATE_TEST_FILES\\n' > .claude/spec-gate-test-cmd"
    echo "  Until then 3 -> 4 stays a terminal-only transition: .claude/hooks/phase.sh 4"
    return 2
  fi

  files=$(cd "$PROJECT_DIR" 2>/dev/null && changed_test_files | tr '\n' ' ')
  if [ -z "${files// /}" ]; then
    echo "spec-driven: REFUSED — no test files changed during Phase 3."
    echo "  Phase 3 exists to produce failing tests. Write them first."
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
    rm -f "$RECEIPT"
    echo "spec-driven: REFUSED — those tests PASSED."
    echo "  A test that passes before the implementation exists is testing nothing."
    echo "  Fix the tests so they fail for the reason you expect, then run"
    echo "  .claude/hooks/phase.sh red again."
    return 1
  fi

  T=$(sed -n 's/^task=//p' "$STATE" | head -1)
  { printf '# spec-gate RED receipt — written by phase.sh red, never by hand\n'
    printf 'task=%s\nrc=%s\n' "$T" "$rc"
    printf 'tests:\n'
    (cd "$PROJECT_DIR" 2>/dev/null && changed_test_snapshot)
  } > "$RECEIPT"

  echo "spec-driven: tests failed as required — RED verified (exit $rc)."
  echo "  Note: this proves not-green, not that they failed for the right reason."
  echo "  That part is yours to establish from the output above, and the user's to"
  echo "  accept — say what each test asserts and why its failure is the expected"
  echo "  one before you ask them to advance."
  echo
  echo "  Receipt recorded. It is void the moment any of those test files changes,"
  echo "  so advance before editing them further:  .claude/hooks/phase.sh 4"
  return 0
}

# 0 = go ahead, 1 = refuse. Consulted by `phase.sh 4`.
red_tripwire() {
  cur=$(sed -n 's/^phase=//p' "$STATE" | head -1)
  [ "$cur" = "3" ] || return 0          # only 3 -> 4 asserts RED

  case "$(red_receipt_status)" in
    valid)
      echo "spec-driven: RED receipt verified — the tests it saw fail are unchanged."
      return 0 ;;
    stale)
      echo "spec-driven: the RED receipt is stale — the test files have changed since"
      echo "  they were verified. Re-running the check rather than trusting it."
      echo ;;
  esac

  verify_red
  case $? in
    0) return 0 ;;
    2) return 0 ;;                      # unverifiable: advance on the assertion
    *) echo "  Override with: phase.sh 4 --force"
       return 1 ;;
  esac
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
         case "$(red_receipt_status)" in
           valid) echo "  -> RED verified — next: 4 Execute, Claude may ask you to approve it" ;;
           stale) echo "  -> RED receipt STALE: the tests changed since. Re-run '.claude/hooks/phase.sh red'" ;;
           *)     echo "  -> RED not verified — next: run '.claude/hooks/phase.sh red' (Claude may do this)" ;;
         esac ;;
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
    rm -f "$RECEIPT"
    snapshot_baseline
    echo "spec-driven: started '${T}' at phase 1 (Clarify)"
    ;;

  red)
    [ -f "$STATE" ] || { echo "spec-driven: not started. Run: phase.sh start <task>"; exit 1; }
    P=$(sed -n 's/^phase=//p' "$STATE" | head -1)
    if [ "$P" != 3 ]; then
      echo "spec-driven: RED verification belongs to Phase 3, and you are at $(phase_name "$P")."
      echo "  Phase 3 is where the failing tests are written. Nothing to verify here."
      exit 1
    fi
    verify_red
    case $? in
      0) exit 0 ;;
      *) exit 1 ;;
    esac
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
    # The receipt describes one Phase 3, and every phase change ends that Phase 3
    # — including a retreat back into it to fix the tests, which must be
    # re-verified rather than riding the old check.
    rm -f "$RECEIPT"
    snapshot_baseline
    echo "spec-driven: -> $(phase_name "$1")"
    ;;

  off)
    rm -f "$STATE" "$BASELINE" "$RECEIPT"
    echo "spec-driven: phase gate off"
    echo "  This ends the phase workflow. It does not stop review — with no phase"
    echo "  file the Stop gate returns to its default and runs EVERY turn."
    report_review_state
    ;;

  *)
    echo "usage: phase.sh [status | start <task> | red | 1..5 | off]"
    echo "       phase.sh red         run the Phase 3 tests and record RED if they fail"
    echo "       phase.sh 4 --force   advance without the RED check"
    exit 1
    ;;
esac
