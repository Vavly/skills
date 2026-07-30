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
  review_pending_paths() { :; }
  slice_status() { printf 'absent\n'; }
  slice_current() { printf '1\n'; }
  slice_total() { printf '1\n'; }
fi

# The state file is written from exactly one place, so a field cannot be dropped
# by a caller that forgot it existed. Adding `slice` to a `printf` in three
# separate branches is how the task name would have gone missing on the fourth.
write_state() { printf 'phase=%s\ntask=%s\nslice=%s\n' "$1" "$2" "$3" > "$STATE"; }

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

# review_pending_paths now lives in phase-policy.sh — phase-guard.sh gates the
# 5 -> 3 slice boundary on it, and the two layers have to agree on what is owed.
# It is still reported by `status` and `off` here, because the surprising part of
# this system is that turning the phase gate OFF makes review fire *more* often,
# not less: with no phase file the Stop gate runs every turn.

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
    case "$(slice_status)" in
      corrupt) echo "  -> slice position is CORRUPT. Recover with: .claude/hooks/phase.sh off" ;;
      # A 1/1 task is the single-pass workflow and says nothing about slices, so
      # nobody who never asked for them pays a line of output for them.
      *) [ "$(slice_total)" -gt 1 ] && echo "  -> slice $(slice_current) of $(slice_total)" ;;
    esac
    case "$P" in
      1) echo "  -> no files may be written"
         echo "  -> next: 2 Spec — Claude may advance" ;;
      2) echo "  -> docs/specs/ only"
         # Said here because status is what the model re-reads after compaction,
         # and the spec review is instructed rather than enforced — the one step
         # a forgetful model can drop without anything noticing.
         echo "  -> the spec goes to the spec-adversary subagent before you are asked"
         echo "  -> next: 3 Plan + tests — Claude may ask you to approve it" ;;
      3) echo "  -> tests only; production code blocked"
         echo "  -> the plan goes to spec-adversary before the tests are written"
         # Same reason as the line above it: status is the post-compaction re-read,
         # and a lost session handle is exactly what compaction causes. Better a
         # cold round declared than a warm one claimed.
         echo "  -> reuse that session if you still hold it; if not, spawn fresh and say the round started cold"
         case "$(red_receipt_status)" in
           valid) echo "  -> RED verified — next: 4 Execute, Claude may ask you to approve it" ;;
           stale) echo "  -> RED receipt STALE: the tests changed since. Re-run '.claude/hooks/phase.sh red'" ;;
           *)     echo "  -> RED not verified — next: run '.claude/hooks/phase.sh red' (Claude may do this)" ;;
         esac ;;
      4) echo "  -> normal permission flow; tests frozen; review gate suppressed"
         echo "  -> next: 5 Review — Claude may advance" ;;
      5) echo "  -> delegate to the adversary subagent; review gate ARMED"
         echo "  -> after a fix, go back to that same session; a new slice gets a new one" ;;
      *) echo "  -> state file is corrupt, and the gate is failing closed."
         echo "  -> recover with: .claude/hooks/phase.sh off" ;;
    esac
    ;;

  start)
    mkdir -p "$STATE_DIR"
    # A newline in the task name would inject extra lines into the state file.
    T=$(printf '%s' "${2:-unnamed}" | tr -d '\n\r')
    write_state 1 "$T" "1/1"
    rm -f "$RECEIPT"
    snapshot_baseline
    echo "spec-driven: started '${T}' at phase 1 (Clarify)"
    ;;

  # Set the number of slices this task lands in. Its own command rather than a
  # flag on a transition: the estimate turns out wrong in the middle of Execute,
  # and deferring the declaration to the next boundary leaves the state file
  # knowingly false in between.
  #
  # The guard decides whether this needs the user — silent while the spec is
  # unapproved, a prompt once it is. Everything here is the arithmetic that
  # holds whoever ran it to a coherent number.
  slices)
    [ -f "$STATE" ] || { echo "spec-driven: not started. Run: phase.sh start <task>"; exit 1; }
    N="${2:-}"
    case "$N" in
      ''|*[!0-9]*) echo "usage: phase.sh slices <n>   (n a positive integer)"; exit 1 ;;
    esac
    [ "$N" -ge 1 ] || { echo "spec-driven: a task lands in at least one slice."; exit 1; }
    if [ "$(slice_status)" = corrupt ]; then
      echo "spec-driven: slice position is corrupt; refusing to build on it."
      echo "  Recover with: .claude/hooks/phase.sh off"
      exit 1
    fi
    CUR=$(slice_current)
    # Slice 3 of 2 is not a state to enter, so this is a refusal rather than a
    # prompt. Descoping remaining work is `slices` down to the current slice.
    if [ "$N" -lt "$CUR" ]; then
      echo "spec-driven: REFUSED — you are on slice $CUR, so the total cannot be $N."
      echo "  Finish or abandon the current slice first."
      exit 1
    fi
    P=$(sed -n 's/^phase=//p' "$STATE" | head -1)
    T=$(sed -n 's/^task=//p' "$STATE" | head -1)
    write_state "$P" "$T" "$CUR/$N"
    echo "spec-driven: slice $CUR of $N"
    if [ "$N" -gt 1 ]; then
      echo "  -> update the slice checklist in docs/specs/ to match, now."
      echo "     The count lives here and the seams live there; after a compaction"
      echo "     whichever is read first is believed."
    fi
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
    FROM=$(sed -n 's/^phase=//p' "$STATE" | head -1)
    CUR=$(slice_current); TOT=$(slice_total)
    # 5 -> 3 is the only transition that moves the slice on. The guard has
    # already established that nothing is owed review and that a next slice
    # exists; this is where the position actually advances.
    if [ "$FROM" = 5 ] && [ "$1" = 3 ] && [ "$CUR" -lt "$TOT" ]; then
      CUR=$((CUR + 1))
      ADVANCED=1
    else
      ADVANCED=0
    fi
    write_state "$1" "$T" "$CUR/$TOT"
    # The receipt describes one Phase 3, and every phase change ends that Phase 3
    # — including a retreat back into it to fix the tests, which must be
    # re-verified rather than riding the old check.
    rm -f "$RECEIPT"
    snapshot_baseline
    echo "spec-driven: -> $(phase_name "$1")"
    if [ "$ADVANCED" = 1 ]; then
      echo "  -> slice $CUR of $TOT — tick the previous one off the checklist in docs/specs/"
    fi
    ;;

  off)
    rm -f "$STATE" "$BASELINE" "$RECEIPT"
    echo "spec-driven: phase gate off"
    echo "  This ends the phase workflow. It does not stop review — with no phase"
    echo "  file the Stop gate returns to its default and runs EVERY turn."
    report_review_state
    ;;

  *)
    echo "usage: phase.sh [status | start <task> | red | slices <n> | 1..5 | off]"
    echo "       phase.sh red         run the Phase 3 tests and record RED if they fail"
    echo "       phase.sh slices <n>  set how many slices this task lands in"
    echo "       phase.sh 4 --force   advance without the RED check"
    exit 1
    ;;
esac
