#!/usr/bin/env bash
# phase-policy.sh — the shared phase/path policy for spec-gate.
#
# Sourced by both enforcement layers:
#   phase-guard.sh  (PreToolUse) — prevents a write before it happens
#   review-gate.sh  (Stop)       — catches writes that got through anyway
#
# The two layers must agree on what a phase permits. If they drift, one of them
# is wrong and the gate is worse than useless, so the rules live here once.
#
# Not executable and not a hook. Sourced only.

# --- What counts as a test ---------------------------------------------------
# Adjust to the repo's layout. A false negative here means production code
# slips through Phase 3 — the one failure that makes the whole gate pointless.
is_test_path() {
  case "$1" in
    */tests/*|tests/*|*/test/*|test/*|*/spec/*|spec/*|*/__tests__/*) return 0 ;;
    *_test.*|*.test.*|*_spec.*|*.spec.*|test_*.py|*Test.java|*Tests.cs)  return 0 ;;
    # A whole suite in one shell script, which is how most tool repos test
    # themselves — including this one. Without it the repo's only test file
    # scores as production and Phase 3 denies every edit to it, which locks the
    # workflow out of exactly the repos spec-gate is written in. Matched by exact
    # basename rather than a *test*.sh glob so that deploy-test.sh and the like
    # keep scoring as production: the dangerous direction here is calling
    # production code a test, since that is what opens Phase 3 up to it.
    test.sh|*/test.sh|tests.sh|*/tests.sh|run-tests.sh|*/run-tests.sh) return 0 ;;
  esac
  return 1
}

# Spec documents are writable in every phase — Phase 2's whole job.
is_spec_path() {
  case "$1" in
    docs/specs/*|*/docs/specs/*) return 0 ;;
  esac
  return 1
}

# Phase state is never the model's to touch, in any phase. .spec-red is in here
# for the same reason as the other two: the model runs the RED check through
# phase.sh, which writes the receipt only when the tests actually failed. A model
# that could write the receipt directly could assert RED without running anything.
is_phase_state() {
  case "$1" in
    *.spec-phase|*.spec-baseline|*.spec-red) return 0 ;;
  esac
  return 1
}

# --- Scope -------------------------------------------------------------------
# Only paths inside the project are this gate's business. An absolute path
# somewhere else is not repo work: /dev/null, /tmp scratch, ~/.config. This is
# what stops `pytest > /dev/null` from being denied during Phase 3, which was
# the friction most likely to make someone switch the gate off.
#
# Relative paths are treated as inside the project, which assumes the command
# runs from the project root. A `cd /elsewhere && echo x > y` is scored as
# in-project and may be denied; erring that way keeps the gate closed.
in_project() {
  case "$1" in
    /*) case "$1" in "${PROJECT_DIR%/}"/*) return 0 ;; *) return 1 ;; esac ;;
    *)  return 0 ;;
  esac
}

# --- What the review gate ignores --------------------------------------------
# Paths excluded from the *review* fingerprint only. Spec documents are approved
# by the user at the 2->3 gate and contain no runtime behaviour, so an
# adversarial code review has nothing to say about them.
#
# Leaving them in had two costs, both observed in real use: a one-line doc
# correction cost a full review cycle, which argues for leaving docs imprecise;
# and a spec doc left uncommitted after the code shipped kept the gate armed
# indefinitely, re-firing every time the fingerprint moved.
#
# Override the *default* by listing pathspecs, one per line, in
# .claude/spec-gate-review-exclude. An empty file means "exclude nothing extra".
#
# spec-gate's own config files are excluded unconditionally, and a user list adds
# to them rather than replacing them. They are configuration for the gate, not
# work the gate should judge — and left uncommitted they arm it, so writing a
# config file would otherwise demand a review of having written a config file.
review_exclude_list() {
  printf '%s\n' \
    '.claude/spec-gate-test-cmd' \
    '.claude/spec-gate-review-exclude'

  f="${PROJECT_DIR%/}/.claude/spec-gate-review-exclude"
  if [ -r "$f" ]; then
    while IFS= read -r l; do
      case "$l" in ''|\#*) continue ;; esac
      printf '%s\n' "$l"
    done < "$f"
  else
    printf 'docs/specs\n'
  fi
}

is_review_excluded() {
  p="$1"
  while IFS= read -r e; do
    [ -z "$e" ] && continue
    case "$p" in "$e"|"$e"/*) return 0 ;; esac
  done <<< "$(review_exclude_list)"
  return 1
}

# Files the review gate would consider owed review — i.e. excluding the paths it
# ignores. Lives here rather than in phase.sh because both layers now read it:
# phase.sh reports it from `status` and `off`, and phase-guard.sh gates 5 -> 3 on
# it being empty. Two implementations of "what is owed" would let the guard
# permit a slice boundary the Stop gate still considers unreviewed.
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

# --- Slice position ----------------------------------------------------------
# A task lands in one or more slices, each separately reviewed. Position lives on
# disk beside the phase, for the reason the phase does: compaction eats context,
# and a model would slide from slice 1 to slice 4 without noticing.
#
# Absent reads as 1/1 — that is both a state file written before slices existed
# and the single-slice shape every task starts in, and neither is an error.
# Malformed is different and fails closed: .spec-phase is denied to the model in
# every phase, so a bad value is not a user's choice, it is something that should
# not have been able to write the file at all.
slice_raw() {
  sed -n 's/^slice=//p' "${PROJECT_DIR%/}/.claude/.spec-phase" 2>/dev/null | head -1
}

# ok | absent | corrupt
slice_status() {
  raw=$(slice_raw)
  [ -z "$raw" ] && { printf 'absent\n'; return 0; }
  case "$raw" in */*) ;; *) printf 'corrupt\n'; return 0 ;; esac
  cur=${raw%%/*}; tot=${raw#*/}
  case "$tot" in */*) printf 'corrupt\n'; return 0 ;; esac   # more than one slash
  case "$cur" in ''|*[!0-9]*) printf 'corrupt\n'; return 0 ;; esac
  case "$tot" in ''|*[!0-9]*) printf 'corrupt\n'; return 0 ;; esac
  { [ "$cur" -ge 1 ] && [ "$tot" -ge 1 ] && [ "$cur" -le "$tot" ]; } \
    || { printf 'corrupt\n'; return 0; }
  printf 'ok\n'
}

# Both report 1 for anything that is not `ok`, so a caller that does not care
# about slices reads a single-slice task and is right. A caller that must refuse
# on corruption asks slice_status directly — same split as red_receipt_status.
slice_current() {
  case "$(slice_status)" in ok) raw=$(slice_raw); printf '%s\n' "${raw%%/*}" ;;
                            *)  printf '1\n' ;; esac
}
slice_total() {
  case "$(slice_status)" in ok) raw=$(slice_raw); printf '%s\n' "${raw#*/}" ;;
                            *)  printf '1\n' ;; esac
}

# --- Working-tree snapshot ---------------------------------------------------
# One "<content-hash> <path>" line per dirty or untracked file. Must be run from
# the project root, inside a work tree.
#
# Shared because two callers have to agree exactly: phase.sh writes it as the
# phase-entry baseline, review-gate.sh recomputes it to find what changed since.
# Two implementations of "the same" snapshot would make that comparison garbage.
#
# It hashes untracked *contents*, which is also what makes the review
# fingerprint honest: `git status --porcelain` lists untracked file names but
# never their contents, so rewriting a new file used to leave the fingerprint
# unchanged and the fix shipped without a second review.
tree_snapshot() {
  files=$( { git diff HEAD --name-only
             git ls-files --others --exclude-standard
           } 2>/dev/null | sort -u )
  [ -z "$files" ] && return 0

  existing=""
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && existing="$existing$f"$'\n'
  done <<< "$files"
  [ -z "$existing" ] && return 0

  # One hash-object process for the whole list, not one per file.
  paste -d' ' <(printf '%s' "$existing" | git hash-object --stdin-paths 2>/dev/null) \
              <(printf '%s' "$existing") 2>/dev/null
}

# --- The RED receipt ---------------------------------------------------------
# Phase 3 -> 4 rests on a claim no hook can check: "the new tests fail for the
# reason I expect." The mechanical half of that — they are not green — is
# checkable, and `phase.sh red` checks it. What it leaves behind is this receipt.
#
# The receipt exists because the check and the advance are separate acts by
# separate parties: the model verifies, the user approves. Between the two, the
# tests could change. So the receipt pins the exact *content* of every test file
# it verified; if any of them moves afterwards the receipt goes stale and the
# approval prompt is not offered. Verifying RED and then quietly editing a test
# green is the one attack this design has to answer.
#
# Sourced by phase.sh (writes it) and phase-guard.sh (reads it to decide whether
# 3 -> 4 may be offered as a prompt). Both need PROJECT_DIR set.
red_receipt_path() { printf '%s/.claude/.spec-red' "${PROJECT_DIR%/}"; }

# "<content-hash> <path>" lines for the test files changed since the phase began,
# from the same snapshot the Stop scan uses. Must run from the project root.
changed_test_snapshot() {
  base=$(cat "${PROJECT_DIR%/}/.claude/.spec-baseline" 2>/dev/null)
  tree_snapshot | while IFS= read -r line; do
    [ -z "$line" ] && continue
    case $'\n'"$base"$'\n' in
      *$'\n'"$line"$'\n'*) continue ;;   # unchanged since phase entry
    esac
    is_test_path "${line#* }" && printf '%s\n' "$line"
  done
}

changed_test_files() { changed_test_snapshot | sed 's/^[^ ]* //'; }

# valid | stale | none | unverifiable. Runs in a subshell so callers do not need
# to be in the project root, and so a failed cd cannot strand them elsewhere.
red_receipt_status() {
  (
    r=$(red_receipt_path)
    [ -r "$r" ] || { printf 'none\n'; exit 0; }
    cd "$PROJECT_DIR" 2>/dev/null || { printf 'unverifiable\n'; exit 0; }
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf 'unverifiable\n'; exit 0; }
    want=$(sed -n '/^tests:$/,$p' "$r" | sed '1d')
    [ -n "$want" ] || { printf 'stale\n'; exit 0; }
    if [ "$want" = "$(changed_test_snapshot)" ]; then printf 'valid\n'; else printf 'stale\n'; fi
  )
}

# --- The policy --------------------------------------------------------------
# path_allowed_in_phase <phase> <path> -> 0 allowed, 1 denied (DENY_REASON set)
path_allowed_in_phase() {
  phase="$1"; p="$2"
  DENY_REASON=""

  is_spec_path "$p" && return 0

  case "$phase" in
    1|2)
      DENY_REASON="Phase $phase of spec-driven: no code yet. Phase 1 clarifies, Phase 2 writes docs/specs/ only. Blocked path: $p"
      return 1
      ;;
    3)
      is_test_path "$p" && return 0
      DENY_REASON="Phase 3 of spec-driven: tests only. Path '$p' looks like production code. Write the failing tests first, show their real failure output, then ask the user to advance to Phase 4."
      return 1
      ;;
  esac
  return 0   # phases 4 and 5: normal permission flow
}
