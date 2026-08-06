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

# --- The gate's own configuration --------------------------------------------
# The exact opposite of is_phase_state, and the mirror image of the reason: phase
# state records decisions, so the model may never write it; this records how to
# run the tests, so the model must always be able to write it.
#
# Always, in every phase, is the load-bearing word. Without it the workflow
# deadlocked: `phase.sh red` with no test command configured tells the model to
# create .claude/spec-gate-test-cmd, and Phase 3 then refused that write as
# "production code" — the gate instructing an action the same gate forbids. The
# only way out was the force gate, so a repo that had simply never been
# configured had to unlock production code on the user's assertion rather than on
# a test run. That is the exact evidence Phase 3 exists to produce, lost to a
# path heuristic.
#
# Two exact names, not a hole in .claude/. The rest of that directory is
# settings.json and the hook scripts themselves, and a Phase 3 that could write
# those could unlock production code by disarming the thing refusing it.
#
# One list, because these paths are also what the review gate ignores, and the
# two answers must be the same one: a file the gate refuses to review is a file
# the gate must let you write, or writing it owes a review that never comes.
gate_config_list() {
  printf '%s\n' \
    '.claude/spec-gate-test-cmd' \
    '.claude/spec-gate-review-exclude'
}

is_gate_config() {
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    case "$1" in "$c"|*/"$c") return 0 ;; esac
  done <<< "$(gate_config_list)"
  return 1
}

# Phase state is never the model's to touch, in any phase. .spec-red is in here
# for the same reason as the other two: the model runs the RED check through
# phase.sh, which writes the receipt only when the tests actually failed. A model
# that could write the receipt directly could assert RED without running anything.
#
# .spec-approval is in here for the sharpest version of that reason. It records
# an answer the *user* gave, and a model that could write it could approve its
# own spec — which is bug #1 from the review list arriving through a new door.
#
# .spec-validation is the same shape as .spec-red one phase later: it is what
# 4 -> 5 rests on, and a marker the model could touch is a marker that asserts
# the repo's own checks passed without any of them having run. Note the asymmetry
# with the journal, which is NOT here — the journal holds prose the model wrote
# itself, so denying it would protect the model's notes from their own author.
# What must not be forgeable is the thing a *gate* reads, and that is this file.
is_phase_state() {
  case "$1" in
    *.spec-phase|*.spec-baseline|*.spec-red|*.spec-approval|*.spec-scaffold|*.spec-validation) return 0 ;;
  esac
  return 1
}

# --- Scaffold mode -----------------------------------------------------------
# The hole this closes: `phase.sh red` has exactly one detector for a vacuous
# test — the test passes. Against a module that does not exist, a careful test
# and an `assert True` both fail with ModuleNotFoundError, identically, so the
# detector is blind for precisely the new feature work the five phases exist
# for. It works only where the code already exists, i.e. bug fixes, which is
# where the ceremony is least needed.
#
# An import error is not a failing test. It is evidence that a prerequisite is
# missing, and says nothing about what the test asserts — unless the thing being
# delivered IS the module surface, which is the one case where "does it import
# and export parse" is the assertion. Scaffold is that case, made explicit.
#
# It is a MODE on Phase 2 rather than a phase of its own, and that is load
# bearing. Any phase numbered below 3 that may write production code would be
# reachable through the guard's retreat rule — `[ "$ARG" -lt "$PHASE" ]` passes
# unchecked, because lower has always meant stricter — so Phase 3 could drop
# into it and write production code with nothing asked. A mode has no number to
# retreat into.
#
# It sits after the 2 -> 3 approval so the surface being created is one the user
# has already read in the spec. Scaffolding before Clarify would mean guessing
# the module boundary before the design exists, and committing that guess as the
# frontier every later test imports from.
scaffold_path() { printf '%s/.claude/.spec-scaffold' "${PROJECT_DIR%/}"; }
scaffold_armed() { [ -f "$(scaffold_path)" ]; }

# "New" means NOT IN HEAD. The two layers have to agree about the same file at
# any point in the turn, and by the time the Stop scan runs, the file the guard
# just permitted DOES exist — an existence test would have prevention and
# detection contradicting each other about the same write.
#
# `git ls-files --error-unmatch` was the first answer and it was wrong: it also
# matches STAGED files, so the verdict flipped the moment the work was staged —
# and review-bookmark.sh stages on every review round. A scaffolded file went
# ALLOW, then DENY after `git add`, with the Stop scan calling it a phase
# violation and advising a revert that would destroy the work. HEAD does not move
# when you stage, so this is the predicate that is actually stable.
#
# The pathspec is literal: `git ls-files -- src/foo?.ts` glob-matches
# src/foo1.ts, and a path is not a pattern.
is_tracked_path() {
  ( cd "$PROJECT_DIR" 2>/dev/null || exit 1
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 1
    p=${1#"${PROJECT_DIR%/}/"}
    git cat-file -e "HEAD:$p" >/dev/null 2>&1 )
}

# --- One tree per task -------------------------------------------------------
# The gate's state lives in one worktree; the work can be in another the moment
# someone runs `git worktree add`. Nothing here spans that. PROJECT_DIR decides
# where .spec-phase is read from and in_project decides which paths are the
# gate's business, and on a split those two answers come from different trees.
#
# What that produced, observed: the gate armed at Phase 3 in the main checkout,
# `phase.sh status` reporting "inactive" from the worktree, and phase-guard
# ALLOWING a production write to <worktree>/src because the path was not under
# PROJECT_DIR. The gate reported itself armed and enforced nothing. That is a
# fail-open, and the same one from two directions.
#
# Failing closed rather than picking a tree. Widening the gate to cover every
# linked worktree would keep it enforcing, but it would make one task's state
# authoritative over a tree the user may have created for something unrelated,
# and it would put the review gate's fingerprint across trees that never share a
# working state. Refusing is the only answer that cannot silently under-enforce.
#
# Reconciling is deliberately the user's, by hand, in a shell: `.spec-phase` is
# denied to the model through every write vector, so a command that relocated it
# would be a command that rewrites phase state — the exact door is_phase_state
# exists to close.

# Absolute physical path, so a comparison is not defeated by /tmp -> /private/tmp
# or by any other symlinked parent.
spec_realpath() { ( cd "$1" 2>/dev/null && pwd -P ) 2>/dev/null; }

# The same, for a path that does not exist yet — which is every path worth
# gating, since the interesting case is a file about to be created. Resolves the
# deepest existing ancestor and re-attaches the rest.
#
# Without this the whole worktree comparison is decoration on macOS: a tool
# payload names /var/folders/../wt/src/x.ts while git names
# /private/var/folders/../wt, and a prefix test between those two is false for
# reasons that have nothing to do with which tree the file is in. The unit tests
# passed because they had already normalised both sides by hand; the end-to-end
# reproduction is what caught it.
spec_norm_path() {   # $1 = an absolute path
  local p=$1 tail='' r
  case "$p" in /*) ;; *) printf '%s\n' "$p"; return 0 ;; esac
  while [ -n "$p" ] && [ "$p" != / ]; do
    if [ -d "$p" ]; then
      r=$(spec_realpath "$p")
      [ -n "$r" ] && { printf '%s%s\n' "$r" "$tail"; return 0; }
      break
    fi
    tail="/${p##*/}$tail"
    p=${p%/*}
    [ -z "$p" ] && p=/
  done
  printf '%s\n' "$1"
}

# Every worktree of the repo containing $1, one absolute path per line.
spec_worktrees() {
  ( cd "$1" 2>/dev/null || exit 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
    git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' )
}

# The worktree holding an armed gate, when it is NOT the tree $1 is in. Empty
# means no split: either this tree is the armed one, or nothing is armed
# anywhere, or this is not a repo at all.
#
# A tree armed in its own right is never a split, so two worktrees each running
# their own task is a supported shape — the tasks simply do not know about each
# other, which is what separate state files already mean.

# Does this repo have linked worktrees at all? Answered in stats, not processes.
# A linked worktree has a .git FILE; the main checkout records them under
# .git/worktrees. This exists so the split check costs nothing on the repos that
# have never run `git worktree add`, which is most of them — otherwise every tool
# call in every dormant repo would spawn git rev-parse, and "inactive costs
# nothing" would stop being true.
spec_worktrees_exist() {   # $1 = a directory; 0 = maybe, 1 = definitely not
  local e
  [ -f "$1/.git" ] && return 0              # we are in a linked worktree
  if [ -d "$1/.git/worktrees" ]; then
    for e in "$1"/.git/worktrees/*; do
      [ -e "$e" ] && return 0
      break
    done
  fi
  [ -e "$1/.git" ] && return 1              # a repo root, and no linked worktrees
  return 0                                  # not a repo root: ask git properly
}

spec_foreign_state() {   # $1 = the directory the work is happening in
  local top w wr
  spec_worktrees_exist "$1" || return 0
  top=$( cd "$1" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null )
  [ -n "$top" ] || return 0
  top=$(spec_realpath "$top")
  [ -n "$top" ] || return 0
  [ -f "$top/.claude/.spec-phase" ] && return 0
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    wr=$(spec_realpath "$w")
    [ -n "$wr" ] && [ "$wr" != "$top" ] && [ -f "$wr/.claude/.spec-phase" ] \
      && { printf '%s\n' "$wr"; return 0; }
  done <<< "$(spec_worktrees "$top")"
  return 0
}

# The mirror question, and the one the Stop gate has to ask: the state is here,
# but is there work somewhere this scan will never look? The scan compares
# PROJECT_DIR's tree against its baseline, so a sibling holding this task's work
# is a turn it passes without having examined anything.
#
# "Another worktree is dirty" is NOT that question, and answering it as though it
# were made every repo with a scratch worktree unusable: one permanently-dirty
# spare tree would block every turn, forever, over work that has nothing to do
# with the task. Someone else's branch is someone else's business.
#
# So relatedness is required, and the signal for it is the task's own spec
# document. Phase 2 writes docs/specs/<task>.md on the task's branch, so a tree
# that predates the task does not have it and a tree carrying the task's work
# does. Two conditions, both necessary: the sibling holds this task's spec, and
# it has uncommitted work — a clean tree is hiding nothing whatever it holds.
spec_related_siblings() {   # $1 = the tree the gate is armed in
  local base task w wr
  spec_worktrees_exist "$1" || return 0
  base=$(spec_realpath "$1")
  [ -n "$base" ] || return 0
  task=$(sed -n 's/^task=//p' "$base/.claude/.spec-phase" 2>/dev/null | head -1)
  [ -n "$task" ] || return 0
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    wr=$(spec_realpath "$w")
    { [ -n "$wr" ] && [ "$wr" != "$base" ]; } || continue
    [ -f "$wr/docs/specs/$task.md" ] || continue
    ( cd "$wr" 2>/dev/null || exit 0
      d=$( { git diff HEAD --name-only
             git ls-files --others --exclude-standard
           } 2>/dev/null | head -1 )
      [ -n "$d" ] && printf '%s\n' "$wr" )
  done <<< "$(spec_worktrees "$base")"
  return 0
}

# One wording, because three layers refuse on this and a user who reads three
# different accounts of the same condition learns that none of them is the whole
# story.
spec_split_message() {   # $1 = tree holding the state, $2 = tree holding the work
  printf '%s' "spec-driven is armed in a different worktree. The gate state is in $1 and this work is in $2, and nothing in spec-gate spans two trees — so it would report itself armed while enforcing nothing on the files you are actually editing. Pick one tree: work from $1, or run 'phase.sh off' there and start the task again here. Moving .spec-phase by hand is not a route; it is phase state, and a receipt you relocate is a receipt nobody gave."
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
#
# The gate's own state files are excluded on the same terms and for a sharper
# reason. The documented install gitignores every one of them, which would make
# this redundant — but a name missing from the target repo's .gitignore is
# exactly the failure this has to survive, and that is not hypothetical: this
# repo shipped two releases with .spec-scaffold absent from its own. An
# untracked state file counts as work owed review, so the gate arms itself on
# having recorded that it was armed, and nothing clears it: the paths are
# gitignored-by-intent, so there is no commit a human can make to satisfy the
# 5 -> 3 boundary or the close-out. Correctness here cannot rest on an install
# step having been done properly.
spec_state_list() {
  printf '%s\n' \
    '.claude/.spec-phase' \
    '.claude/.spec-baseline' \
    '.claude/.spec-red' \
    '.claude/.spec-approval' \
    '.claude/.spec-scaffold' \
    '.claude/.spec-validation' \
    '.claude/spec-journal.md' \
    '.claude/review-log.jsonl'
}

review_exclude_list() {
  gate_config_list
  spec_state_list

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

# 0 = this is a boundary, not the end. Three callers ask the same question and
# used to each spell it out: the close-out wording, the close-out options, and
# the guard's `off` warning. The third had it right and the first two did not,
# which is exactly the drift one predicate prevents. A 1/1 task answers no, so
# nobody who never sliced anything sees a word about slices.
slices_remain() { [ "$(slice_current)" -lt "$(slice_total)" ]; }

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
#
# Lines are "<content-hash>[x] <path>", the `x` marking an executable file. The
# flag rides on the hash field rather than becoming a third column so that every
# consumer's `${line#* }` still yields the path. It exists because a mode change
# is a reviewable change with no content to hash: the review fingerprint carries
# tracked-file mode changes from `git diff HEAD --summary`, but a *new* file's
# mode appears there only once it is staged, and the fingerprint has to be blind
# to staging. Without this flag, `chmod +x` on a new file was invisible.
#
# Changing this format invalidates the two things that compare snapshot lines
# literally: an in-flight RED receipt goes stale once (re-run `phase.sh red`) and
# a phase baseline written by an older version reads as "everything changed" until
# the next phase transition re-snapshots it. Both self-heal; neither is silent.
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

  # One hash-object process for the whole list, not one per file. The exec flag
  # is a shell builtin test, so it adds no process per file either.
  paste -d' ' <(printf '%s' "$existing" | git hash-object --stdin-paths 2>/dev/null) \
              <(printf '%s' "$existing") 2>/dev/null \
  | while IFS= read -r line; do
      p=${line#* }
      if [ -x "$p" ]; then printf '%sx %s\n' "${line%% *}" "$p"
      else                 printf '%s\n' "$line"
      fi
    done
}

# The path out of a snapshot line, whatever kind of line it is: a hashed file, a
# deletion, or a mode change. Used by the review gate to report which paths moved
# between one review round and the next.
snapshot_line_path() {
  case "$1" in
    "mode "*) printf '%s\n' "${1#mode * => * }" ;;
    *)        printf '%s\n' "${1#* }" ;;
  esac
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

# --- What kind of red is this? -----------------------------------------------
# `phase.sh red` used to treat any non-zero exit as "the tests failed", which
# certifies two things that are not a failing test.
#
# A runner that never ran. A typo'd or uninstalled test command exits 127 and the
# receipt recorded RED for a suite that produced no evidence at all — observed
# twice while writing these very tests, with no pipeline involved.
#
# A missing module. Every test against code that does not exist yet fails
# identically whatever it asserts, so the one detector this check has for a
# vacuous test — the test passes — is disarmed for all new feature work. Scaffold
# makes assertion-red reachable; refusing import-red here is what makes it
# required. The exception is scaffold mode itself, where the module's existence
# IS what the step delivers, so the import error is the assertion.
#
# Anything unrecognised is `assertion`, i.e. exactly the old behaviour. A runner
# whose wording is not in these lists behaves as it always did rather than being
# newly blocked, which is the only safe direction for a pattern list that cannot
# be complete.
red_failure_kind() {   # $1 = exit status, $2 = combined output -> green|harness|import|assertion
  [ "$1" = 0 ] && { printf 'green\n'; return 0; }
  # 126 and 127 are the shell's own codes for "cannot execute" and "not found",
  # so they are about the command rather than about any test.
  case "$1" in 126|127) printf 'harness\n'; return 0 ;; esac
  case "$2" in
    *"command not found"*) printf 'harness\n'; return 0 ;;
  esac
  case "$2" in
    *ModuleNotFoundError*|*"No module named"*|*ImportError*|\
    *"Cannot find module"*|*"cannot find module"*|*ERR_MODULE_NOT_FOUND*|*TS2307*|\
    *"Could not resolve"*|*"cannot find package"*|*"no required module provides package"*|\
    *"unresolved import"*|*E0432*|\
    *package*"does not exist"*|*"cannot load such file"*)
      printf 'import\n'; return 0 ;;
  esac
  printf 'assertion\n'
}

# --- The review fingerprint and its marker ------------------------------------
# What the review gate considers "this diff", and where it records the round it
# last saw. Both live here rather than in review-gate.sh because there are now two
# writers: the Stop gate, and review-bookmark.sh at the moment a verdict lands. A
# second implementation of the fingerprint would not fail loudly — it would make
# every between-rounds delta garbage, which is the one part of the block message
# that claims to be fact.
#
# Must run from the project root, inside a work tree.
review_marker_path() {
  d=$(git rev-parse --git-dir 2>/dev/null) || return 1
  [ -n "$d" ] || return 1
  printf '%s/claude-review-gate\n' "$d"
}

# Content hashes of everything dirty or untracked, minus the excluded paths.
# Excluded paths are kept out rather than filtered afterwards, so they cannot move
# the fingerprint at all.
review_snapshot() {
  command -v tree_snapshot >/dev/null 2>&1 || return 0
  tree_snapshot | while IFS= read -r line; do
    [ -z "$line" ] && continue
    is_review_excluded "${line#* }" || printf '%s\n' "$line"
  done
}

# The full fingerprint: content hashes, plus the two things tree_snapshot cannot
# carry — deletions (it only hashes files that exist) and tracked-file mode
# changes. Built only from things `git add` cannot move, which is what lets the
# workflow stage before a round without paying for a review of having staged.
review_fingerprint() {
  command -v tree_snapshot >/dev/null 2>&1 || return 0
  local exc=() pspec=()
  while IFS= read -r e; do
    [ -n "$e" ] && exc+=(":(exclude)$e")
  done <<< "$(review_exclude_list 2>/dev/null || true)"
  if [ "${#exc[@]}" -gt 0 ]; then pspec=(-- . "${exc[@]}"); else pspec=(--); fi
  { review_snapshot
    git diff HEAD --name-only --diff-filter=D "${pspec[@]}" | sed 's/^/deleted /'
    git diff HEAD --summary "${pspec[@]}" | sed -n 's/^ *mode change /mode /p'
  } 2>/dev/null
}

# Line 1 is the hash, the rest is the snapshot it came from. The hash alone
# answers "is this the same diff?"; the snapshot also answers "what moved since?",
# which is the question the next round asks. An empty fingerprint deletes the
# marker: a round is only in flight while something is owed.
write_review_marker() {   # $1 = fingerprint text
  m=$(review_marker_path) || return 0
  if [ -z "$1" ]; then rm -f "$m" 2>/dev/null; return 0; fi
  h=$(printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  { printf '%s\n' "$h"; printf '%s\n' "$1"; } > "$m" 2>/dev/null
}

# --- The approval questions --------------------------------------------------
# The three decisions that are the user's arrive as a real question rather than
# as a permission prompt on a shell command. The model asks them with
# AskUserQuestion; `phase.sh ask <gate>` hands it the wording.
#
# The wording lives here, in one copy, for a reason that is not tidiness.
# approval-receipt.sh identifies which gate was answered by matching the question
# text *verbatim*, so the model cannot ask a softball question and cash the
# answer against a gate. If the skill carried its own copy, a drifting copy would
# not fail loudly — it would fail as a question nobody could redeem, which looks
# exactly like the user never being asked.
#
# Nothing here may contain a double quote, a backslash or a tab: the strings are
# emitted into hand-built JSON by phase.sh and split on tabs by both readers.
# test.sh pins that.
# Every gate name, in one place. Three consumers iterate this — phase.sh `ask`
# validation, phase.sh `status`, and approval-receipt.sh's matcher — and a gate
# missing from any one of them is a question whose answer nothing redeems, which
# looks exactly like a user who was never asked. Adding a gate means adding it
# here and nowhere else.
gate_list() { printf 'spec red close-out skip abandon leave-review restart force force-validation\n'; }

# The last five replaced a terminal. They existed as "go run this in your own
# shell" for one stated reason: a PreToolUse hook cannot tell a Bash call the
# model chose from one a slash command made. The receipt answers that — it does
# not reveal who called, but it proves the *user* answered, because the answer
# came back through the host and was recorded by a hook the model cannot write
# to. That is the property the terminal was standing in for.
#
# What the terminal also bought was friction: leaving the session to type a path
# is a moment of attention. A question has to carry that in its wording instead,
# so each of these names what is being given up rather than just asking to
# proceed.
gate_header() {
  case "$1" in
    spec)         printf 'Spec approval' ;;
    red)          printf 'Unlock code' ;;
    close-out)    printf 'Close out' ;;
    skip)         printf 'Skip ahead' ;;
    abandon)      printf 'Abandon task' ;;
    leave-review) printf 'Leave review' ;;
    restart)      printf 'Discard task' ;;
    force)        printf 'Force unlock' ;;
    force-validation) printf 'Skip checks' ;;
  esac
}

gate_question() {
  case "$1" in
    spec)      printf 'Approve the spec, and move on to the plan and its failing tests?' ;;
    red)       printf 'Those tests failed. Unlock production code?' ;;
    # Slice-aware, because at slice 1 of 8 the flat wording is simply false:
    # review of ONE slice is done and seven are unbuilt. It was asked anyway —
    # nothing here consulted the slice position — so the model got three options
    # that all ended the task and had to write the real next move into a
    # paragraph underneath. A question whose own contract needs a caveat is the
    # bug; the caveat is the symptom.
    close-out) if slices_remain; then
                 printf 'Slice %s of %s is reviewed. What happens next?' \
                   "$(slice_current)" "$(slice_total)"
               else
                 printf 'Review is done. What happens to this work?'
               fi ;;
    skip)         printf 'Jump forward past a phase, skipping the approvals in between?' ;;
    abandon)      printf 'Turn the gate off before any code has been written?' ;;
    leave-review) printf 'Leave Phase 5 with a diff that is still owed review?' ;;
    restart)      printf 'Discard the task in progress and re-arm at Phase 1?' ;;
    force)        printf 'Unlock production code without verified failing tests?' ;;
    # Deliberately not the `force` wording. Both flags are called --force and
    # both skip a check, but they skip different ones at different costs: `force`
    # unlocks production code on nothing having been shown to fail, while this
    # one enters review with the repo's own checks unrun. Routing both to one
    # question meant the user was asked about unlocking production code at a
    # point where production code was already written — an answer given about
    # the wrong risk, and one the receipt would then honour.
    force-validation) printf 'Enter adversarial review with no validation report recorded?' ;;
  esac
}

# <verdict>\t<label>\t<description>, one choice per line.
#
# The label is what approval-receipt.sh looks for in the user's answer, so each
# one has to be a distinctive phrase rather than Yes / No — a bare "Yes" would
# match half of anything.
gate_options() {
  case "$1" in
    spec) printf '%s\n' \
      'approve	Approve the spec	You have read the spec in docs/specs/ and accept the approach, the types and the out-of-scope list. Phase 3 writes tests only; production code stays blocked until you have seen them fail.' \
      'approve-scaffold	Approve, and create the files first	Same approval, plus one step before Phase 3: the new files this spec names get created empty, so the tests written next fail on an assertion instead of on a missing import. Nothing already tracked can be edited. Choose this when the spec introduces modules that do not exist yet.' \
      'decline	Send the spec back	Something is wrong or missing. Say what, and it gets revised before you are asked again. Choose this if the spec-adversary verdict is not in this conversation.' ;;
    red) printf '%s\n' \
      'approve	Accept these failures	Each failure above is the one the spec expects, not an import error or a broken fixture. Phase 4 unlocks production code and freezes the tests.' \
      'decline	One of them is broken	A test failed for the wrong reason. It gets fixed and RED re-verified before you are asked again.' ;;
    # The next-slice option comes first and only exists while slices remain. It
    # is the move slicing.md already called the normal one at a boundary, and
    # leaving it off the list did not make it unavailable — it made it something
    # the model announced in prose beside a question that contradicted it.
    #
    # The other three stay answerable here on purpose. A user who types `off` at
    # slice 1 wants out, and a boundary that offered only "carry on" would trade
    # a missing option for a missing exit.
    close-out) if slices_remain; then printf '%s\n' \
      "slice	Commit and open slice $(( $(slice_current) + 1 ))	This slice is finished, not the task. Its reviewed work is committed, the checklist in docs/specs/ is ticked, and Phase 3 opens the next slice with its own plan, its own failing tests and its own approvals. $(( $(slice_total) - $(slice_current) )) slices remain after this one. The gate stays on."
                 fi
               printf '%s\n' \
      'pr	Open a pull request	The PR is opened first, then the gate is disarmed. That order is load-bearing: disarming on an uncommitted tree makes the review gate fire on every turn.' \
      'continue	Keep iterating	Stay in Phase 5. Anything that changes from here gets reviewed exactly like the last round did.' \
      'disarm	Disarm and leave it	The phase gate stops and the working tree is what you are left with. The review gate goes back to firing every turn while anything is uncommitted, and the journal is deleted along with the rest of the state.' ;;
    skip) printf '%s\n' \
      'approve	Skip the phases between	You are giving up the approvals in the phases being jumped over — spec approval, or reading the tests fail, or both. Nothing later asks for them again. Choose this only if you already know what those phases would have shown you.' \
      'decline	Go one phase at a time	The workflow advances normally and each gate is asked in its turn.' ;;
    abandon) printf '%s\n' \
      'approve	Turn the gate off	Before Phase 4 the gate is what blocks production code, so turning it off here is the same as unlocking Phase 4 without a spec or a failing test. The review gate then fires on every turn while the tree is dirty, and the journal is deleted — it is gitignored, so it does not come back.' \
      'decline	Keep the gate on	The task stays where it is. Retreating to an earlier phase is always available and does not need this.' ;;
    leave-review) printf '%s\n' \
      'approve	Leave the review behind	Phases 1 to 4 suppress the review gate, so moving there parks a diff nothing will look at again — it gets folded into the next baseline as though it had been reviewed.' \
      'decline	Stay in Phase 5	The diff keeps being owed review until it is reviewed and committed.' ;;
    restart) printf '%s\n' \
      'approve	Discard it and restart	The task in progress is thrown away: phase, slice position, every approval already given, and the journal — the validation report, which findings were acted on, and how far Execute got. The journal is gitignored, so that part is gone for good rather than recoverable from git. The working tree is untouched, so whatever was built stays, unreviewed and no longer tracked by the gate.' \
      'decline	Keep the current task	The task continues from where it is.' ;;
    force) printf '%s\n' \
      'approve	Unlock without RED	The check refused: the new tests either passed with no implementation written, or no test files changed at all. Either way nothing has been shown to fail, so Phase 4 unlocks production code on your word rather than on evidence.' \
      'decline	Fix the tests first	Phase 3 continues. Run the RED check again once the tests fail for the reason the spec expects.' ;;
    force-validation) printf '%s\n' \
      'approve	Review it unvalidated	No report of this repo checks passing exists for the work Phase 4 just finished. Phase 5 hands the reviewer a diff whose build and test status nobody has established, and the session that resumes after this one has nothing to hand over either.' \
      'decline	Run the checks first	Phase 4 continues. Run what this repo gates on, record it with phase.sh validation, and 4 -> 5 clears on its own.' ;;
  esac
}

# --- The approval receipt ----------------------------------------------------
# What the user answered, recorded where a hook can read it. Written only by
# approval-receipt.sh from a PostToolUse payload — the answer comes from the
# host, so the model cannot forge one, and .spec-approval is denied to it by
# is_phase_state above.
#
# This is the same shape as the RED receipt and exists for the same reason: the
# asking and the acting are separate acts, and something has to survive between
# them without being the model's word for it.
#
# Two things pin a receipt to the moment it was given. Every receipt carries the
# task, phase and slice it was answered in, so an answer cannot be spent on a
# later question. On top of that, the two gates that approve a *document* carry a
# content fingerprint of what was approved, so editing the thing after the answer
# voids it — the same attack `.spec-red` exists to close.
#
# close-out carries no fingerprint, deliberately. The tree moves between the
# answer and the act on the `pr` path, because opening the PR is the commit; a
# content pin there would void every approval it was meant to carry. What guards
# that path instead is review_pending_paths, checked at the point of use.
approval_path() { printf '%s/.claude/.spec-approval' "${PROJECT_DIR%/}"; }

# Content hashes of the spec documents, in the tree_snapshot format. Untracked
# specs are hashed too: the first spec of a task is always untracked, and a
# fingerprint blind to it would approve a document and then not notice it being
# rewritten — bug #2, in a new place.
spec_snapshot() {
  files=$( { git ls-files -- docs/specs
             git ls-files --others --exclude-standard -- docs/specs
           } 2>/dev/null | sort -u )
  [ -z "$files" ] && return 0
  existing=""
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && existing="$existing$f"$'\n'
  done <<< "$files"
  [ -z "$existing" ] && return 0
  paste -d' ' <(printf '%s' "$existing" | git hash-object --stdin-paths 2>/dev/null) \
              <(printf '%s' "$existing") 2>/dev/null
}

# What a receipt for this gate is pinned to. Must run from the project root.
gate_subject() {
  case "$1" in
    spec) spec_snapshot ;;
    # The RED receipt already pins the test contents, so pinning the receipt
    # itself inherits that and costs one hash instead of a re-walk.
    red)  git hash-object "${PROJECT_DIR%/}/.claude/.spec-red" 2>/dev/null ;;
    # These pin no content, for close-out's reason: there is no document being
    # approved, so there is nothing whose edit should void the answer. What holds
    # them is the phase/task/slice pin every receipt carries — an answer about
    # skipping ahead from Phase 2 is spent in Phase 2 and nowhere else — plus a
    # re-check at the point of use, which is where `force` re-reads the RED
    # receipt and `leave-review` re-reads what is owed.
    # force-validation is here rather than left to fall through the case. An
    # unlisted gate produces the same empty subject and would behave correctly by
    # accident, which is the kind of correct that stops being true the moment a
    # default is added below.
    close-out|skip|abandon|leave-review|restart|force|force-validation) : ;;
  esac
}

# <verdict> | expired | stale | none | unverifiable. The verdict *is* the status
# when the receipt is good, the same split as red_receipt_status: a caller that
# only wants to know whether it may proceed compares against the verdict it
# needs, and a caller that must distinguish "not asked" from "asked and refused"
# can.
#
# The two failure states are separate because they are different events and the
# user is told which one happened. `expired` means the answer was given at a
# different point in the task — another phase, another slice — so it is about
# something else. `stale` means the answer was about this moment but not about
# what is now on disk. Collapsing them was the first version, and it produced a
# denial telling the user a spec had changed when what had actually happened was
# that there was never a spec to approve. A gate that misreports why it refused
# teaches people to stop reading its refusals.
approval_status() {
  (
    g="$1"
    a=$(approval_path)
    [ -r "$a" ] || { printf 'none\n'; exit 0; }
    [ "$(sed -n 's/^gate=//p' "$a" | head -1)" = "$g" ] || { printf 'none\n'; exit 0; }
    v=$(sed -n 's/^verdict=//p' "$a" | head -1)
    [ -n "$v" ] || { printf 'stale\n'; exit 0; }

    s="${PROJECT_DIR%/}/.claude/.spec-phase"
    [ -r "$s" ] || { printf 'expired\n'; exit 0; }
    for k in phase task slice; do
      [ "$(sed -n "s/^$k=//p" "$a" | head -1)" = "$(sed -n "s/^$k=//p" "$s" | head -1)" ] \
        || { printf 'expired\n'; exit 0; }
    done

    cd "$PROJECT_DIR" 2>/dev/null || { printf 'unverifiable\n'; exit 0; }
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf 'unverifiable\n'; exit 0; }
    want=$(sed -n '/^subject:$/,$p' "$a" | sed '1d')
    case "$g" in
      # An empty fingerprint on a gate that approves a document means there was
      # no document. Refusing rather than passing is the same call as an empty
      # `tests:` block in the RED receipt: nothing was pinned, so nothing is
      # covered, and the approval would silently cover whatever appeared later.
      spec|red) [ -n "$want" ] || { printf 'stale\n'; exit 0; } ;;
    esac
    [ "$want" = "$(gate_subject "$g")" ] || { printf 'stale\n'; exit 0; }
    printf '%s\n' "$v"
  )
}

# --- The policy --------------------------------------------------------------
# path_allowed_in_phase <phase> <path> -> 0 allowed, 1 denied (DENY_REASON set)
path_allowed_in_phase() {
  phase="$1"; p="$2"
  DENY_REASON=""

  is_spec_path "$p" && return 0
  is_gate_config "$p" && return 0

  case "$phase" in
    2)
      # Scaffold mode: new module surface only, so Phase 3's tests can fail on
      # an assertion instead of on an import. Tests are permitted too, because
      # the surface test is what makes the creation a TDD step rather than a
      # licence to write code.
      if scaffold_armed; then
        is_test_path "$p" && return 0
        if is_tracked_path "$p"; then
          DENY_REASON="Scaffold creates new files; it never edits one that already exists. '$p' is tracked, so changing it is implementation, not scaffolding — that is Phase 4. Blocked path: $p"
          return 1
        fi
        return 0
      fi
      DENY_REASON="Phase 2 of spec-driven: no code yet. Phase 2 writes docs/specs/ only. Blocked path: $p"
      return 1
      ;;
    1)
      DENY_REASON="Phase 1 of spec-driven: no code yet. Phase 1 clarifies and writes nothing. Blocked path: $p"
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
