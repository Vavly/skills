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

# Phase state is never the model's to touch, in any phase.
is_phase_state() {
  case "$1" in
    *.spec-phase|*.spec-baseline) return 0 ;;
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
