#!/usr/bin/env bash
# phase.sh — read and set spec-driven phase state.
#
# The user's control surface, reached as /spec-phase rather than by path. Every
# transition that is the user's — the two that widen write access, and the five
# that route around them — is a question phase-guard.sh reads an answer to. None
# of them requires leaving the session any more; what none of them accepts is the
# model's own say-so, which is what the receipt is for.
#
# Install: .claude/hooks/phase.sh  (chmod +x), or via the spec-gate-install skill
# Add .claude/.spec-phase, .claude/.spec-baseline, .claude/.spec-red,
# .claude/.spec-approval*, .claude/.spec-scaffold, .claude/.spec-validation
# and .claude/spec-journal.md to .gitignore

set -uo pipefail

# CLAUDE_PROJECT_DIR is set for hooks but NOT for Bash tool calls, so a bare
# $PWD fallback put the state wherever the caller happened to be standing: run
# from a subdirectory, this wrote a second .spec-phase there while every hook
# went on reading the one at the repo root. The git toplevel is the same answer
# the hooks get, from any depth. $PWD stays as the last resort for a non-repo,
# where the gate is inert anyway.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")}"
STATE_DIR="$PROJECT_DIR/.claude"
STATE="$STATE_DIR/.spec-phase"
BASELINE="$STATE_DIR/.spec-baseline"
RECEIPT="$STATE_DIR/.spec-red"
APPROVAL="$STATE_DIR/.spec-approval"
SCAFFOLD="$STATE_DIR/.spec-scaffold"
VALIDATION="$STATE_DIR/.spec-validation"
JOURNAL="$STATE_DIR/spec-journal.md"
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
  red_failure_kind() { printf 'assertion\n'; }
  review_pending_paths() { :; }
  slice_status() { printf 'absent\n'; }
  slice_current() { printf '1\n'; }
  slice_total() { printf '1\n'; }
  # No policy file means no canonical wording, and a question this script made up
  # is a question approval-receipt.sh will not recognise. Refusing to print one
  # is better than printing one whose answer can never be redeemed.
  gate_list() { :; }
  gate_header() { :; }
  gate_question() { :; }
  gate_options() { :; }
  approval_status() { printf 'unverifiable\n'; }
  scaffold_armed() { false; }
  is_tracked_path() { return 0; }
fi

# The state file is written from exactly one place, so a field cannot be dropped
# by a caller that forgot it existed. Adding `slice` to a `printf` in three
# separate branches is how the task name would have gone missing on the fourth.
#
# `started` is carried forward rather than passed in, for the same reason: every
# transition rewrites this file, and a caller that had to re-supply the stamp
# would eventually reset it and silently re-date the task. `start` deletes the
# file first, which is what makes a new task get a new stamp. An older install
# has no stamp at all, and everything reading it treats absent as "unknown" and
# falls back to today's behaviour.
write_state() {
  local S=''
  [ -f "$STATE" ] && S=$(sed -n 's/^started=//p' "$STATE" 2>/dev/null | head -1)
  [ -n "$S" ] || S=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  printf 'phase=%s\ntask=%s\nslice=%s\nstarted=%s\n' "$1" "$2" "$3" "$S" > "$STATE"
}

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
    echo "  Write it now — that path is gate config, not production code, so it is"
    echo "  writable in this phase. Take the command from package.json, pyproject.toml,"
    echo "  the Makefile or CI rather than guessing, then run 'phase.sh red' again."
    echo "  The force gate is for when nothing in the repo says how its tests run:"
    echo "  it spends the user's approval in place of evidence you could produce."
    return 2
  fi

  files=$(cd "$PROJECT_DIR" 2>/dev/null && changed_test_files | tr '\n' ' ')
  if [ -z "${files// /}" ]; then
    echo "spec-driven: REFUSED — no test files changed during Phase 3."
    echo "  Phase 3 exists to produce failing tests. Write them first."
    return 1
  fi

  # Echoed, not just run. The test command is the model's to write — it has to
  # be, or a repo that never configured one cannot verify RED at all — and what
  # it contains decides what "verified" means. A command of `exit 1` produces a
  # receipt indistinguishable from a real failing suite, so the command belongs
  # on screen next to the failures the user is being asked to accept.
  cmd=$(cat "$TEST_CMD_FILE")
  echo "spec-driven: verifying the new tests fail before unlocking production code"
  echo "  tests:   $files"
  echo "  command: $cmd"
  case "$cmd" in
    *\|*) echo "  note:    that command contains a pipeline. pipefail is set, so a failure"
           echo "           in any stage counts — but a final stage that returns non-zero"
           echo "           when all is well would read as a failing suite." ;;
  esac
  echo
  # Captured rather than streamed, because the classification below reads it.
  # bash rather than sh, for pipefail: `pytest | tail` returned the tail's zero,
  # so a genuinely failing suite was reported as PASSED.
  # The gate's own state is put aside before the command runs and checked back
  # afterwards. This command is model-authored shell that the guard deliberately
  # allows in every phase, so without this the shortest route out of the workflow
  # was to write `rm -f .claude/.spec-phase` here and run the verifier.
  spec_state_save
  out=$(
    cd "$PROJECT_DIR" 2>/dev/null || exit 0
    SPEC_GATE_TEST_FILES="$files" bash -c "set -o pipefail; $cmd" 2>&1
  )
  rc=$?
  if ! spec_state_restore; then
    printf '%s\n' "$out"
    echo
    rm -f "$RECEIPT"
    echo "spec-driven: REFUSED — the configured test command changed this gate's own"
    echo "  state while it ran. Whatever it did to $STATE_DIR_REL has been undone."
    echo "  A test command runs the repo's tests; one that rewrites the phase, the"
    echo "  receipts or the approval is doing something else, and nothing it printed"
    echo "  is evidence about anything."
    echo "  Fix the command in $TEST_CMD_FILE, then run phase.sh red again."
    return 1
  fi
  printf '%s\n' "$out"
  echo
  kind=$(red_failure_kind "$rc" "$out")

  # Scaffold mode is the one place a missing module is the assertion rather than
  # a missing prerequisite: existence is what that step delivers.
  if [ "$kind" = import ] && scaffold_armed; then
    kind=assertion
  fi

  case "$kind" in
    green)
      rm -f "$RECEIPT"
      echo "spec-driven: REFUSED — those tests PASSED."
      echo "  A test that passes before the implementation exists is testing nothing."
      echo "  Fix the tests so they fail for the reason you expect, then run"
      echo "  phase.sh red again."
      return 1 ;;
    harness)
      rm -f "$RECEIPT"
      echo "spec-driven: REFUSED — the test command did not run (exit $rc)."
      echo "  That is not a failing test, it is a missing or broken runner, and it"
      echo "  produces the same non-zero exit a real failure would. Nothing here is"
      echo "  evidence about the tests."
      echo "  Fix the command in $TEST_CMD_FILE — take it from package.json,"
      echo "  pyproject.toml, the Makefile or CI — then run phase.sh red again."
      return 1 ;;
    import)
      rm -f "$RECEIPT"
      echo "spec-driven: REFUSED — those tests failed because a module could not be"
      echo "  resolved, not because anything they assert is wrong."
      echo "  An import error is not a failing test. Every test against code that"
      echo "  does not exist yet fails exactly this way whatever it asserts, so this"
      echo "  proves nothing about the tests you just wrote."
      echo "  The surface has to exist first: retreat to Phase 2, put the new files"
      echo "  in a '## Scaffold' list in the spec, and ask for 'Approve, and create"
      echo "  the files first'. Then Phase 3 tests fail on an assertion instead."
      echo "  If the module SHOULD already exist, this is a broken import path or a"
      echo "  missing dependency — fix that and run phase.sh red again."
      return 1 ;;
  esac

  T=$(sed -n 's/^task=//p' "$STATE" | head -1)
  # `cmd` rides above the `tests:` block, which is the only part read back —
  # red_receipt_status parses from `^tests:$` down. It is here so the receipt
  # says what produced the failures, and because approval_status pins this file
  # by content hash: swapping the command after the user accepted it voids their
  # approval instead of silently inheriting it.
  { printf '# spec-gate RED receipt — written by phase.sh red, never by hand\n'
    printf 'task=%s\nrc=%s\nkind=%s\ncmd=%s\n' "$T" "$rc" "$kind" "$cmd"
    printf 'tests:\n'
    (cd "$PROJECT_DIR" 2>/dev/null && changed_test_snapshot)
  } > "$RECEIPT"

  echo "spec-driven: tests failed as required — RED verified (exit $rc, $kind)."
  echo "  Note: this proves not-green, and that the failure was neither a broken"
  echo "  runner nor an unresolved import. It does NOT prove they failed for the"
  echo "  reason the spec expects."
  echo "  That part is yours to establish from the output above, and the user's to"
  echo "  accept — say what each test asserts and why its failure is the expected"
  echo "  one before you ask them to advance."
  echo
  echo "  Receipt recorded. It is void the moment any of those test files changes,"
  echo "  so advance before editing them further:  phase.sh 4"
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

# --- The journal --------------------------------------------------------------
# Almost everything this workflow produces already survives a lost session: the
# phase is in the state file, the spec and the plan are on disk, every reviewer
# verdict is in review-log.jsonl, and what shipped is in git. Exactly three
# things were only ever said out loud — the validation report, which findings
# were acted on and which were declined, and how far through the plan Execute
# had got. Those are what a resuming session cannot reconstruct unless they were
# written down, so this is the whole of what the journal is for.
#
# It lives in .claude/ and is gitignored for a reason beyond tidiness. The review
# gate collects what is owed from `git diff HEAD` and `git status --porcelain`,
# so a journal kept in the spec — or anywhere else tracked — would dirty the tree
# every time it was written, re-arm the gate, and demand a review round whose
# only finding would be the entry describing the previous one.
# Both journal-writing commands take their body on stdin, and both had the same
# two ways of silently getting nothing. Run with no redirection — which is what
# the documented /spec-phase path does, since it forwards arguments and never a
# heredoc — `cat` returns empty against /dev/null and the entry is a stamped
# header with nothing under it. Run from a terminal, `cat` blocks instead, and a
# command invoked by a hook that waits forever on stdin is worse than one that
# fails.
#
# An empty body is refused rather than recorded, for the reason an empty `tests:`
# block voids a RED receipt: a header with no content is indistinguishable from
# work that was done, and it is the *validation* report that this matters most
# for — an empty one still wrote the marker that clears 4 -> 5, so the gate
# certified that nothing had been run. A gate that produces evidence of a check
# nobody performed is worse than no gate, because the next session reads it and
# stops asking.
#
# The check lives in the function that writes rather than in its callers, and
# that placement is the point. Guarding at each call site leaves the next caller
# free to forget, and what it would silently produce is the empty entry this
# refusal exists to prevent — the same bug back through a new door. Reading
# stdin and refusing an empty body are one act here, so there is no way to
# append without having passed it.
journal_append() {  # $1 = command name, for the messages; $2 = optional label
  # 1 = refused, and the reason is already on stderr. 2 = could not write, which
  # the caller reports itself. Collapsing the two made a refusal print a
  # "could not write" line on top of a precise explanation of why nothing was.
  if [ -t 0 ]; then
    echo "spec-driven: '$1' reads its entry from stdin, and stdin is a terminal." >&2
    echo "  Nothing was recorded. Pass the text as a heredoc:" >&2
    echo "      phase.sh $1 <<'EOF'" >&2
    echo "      ..." >&2
    echo "      EOF" >&2
    return 1
  fi
  BODY=$(cat)
  if [ -z "$(printf '%s' "$BODY" | tr -d '[:space:]')" ]; then
    echo "spec-driven: REFUSED — nothing arrived on stdin, so there is no entry." >&2
    echo "  This command does not take its content as an argument. It reads stdin," >&2
    echo "  so it needs a heredoc:" >&2
    echo "      phase.sh $1 <<'EOF'" >&2
    echo "      ..." >&2
    echo "      EOF" >&2
    return 1
  fi

  mkdir -p "$STATE_DIR" 2>/dev/null || return 2
  JP=$(sed -n 's/^phase=//p' "$STATE" 2>/dev/null | head -1)
  { printf '\n## %s — phase %s, slice %s/%s%s\n\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${JP:-?}" \
      "$(slice_current)" "$(slice_total)" "${2:+ — $2}"
    printf '%s\n' "$BODY"
    printf '\n'
  } >> "$JOURNAL" || return 2
  return 0
}

# 0 = go ahead, 1 = refuse. Consulted by `phase.sh 5`.
#
# The mirror of red_tripwire, for the mirror reason. Phase 4 cannot exit without
# the repo's own checks passing, and Phase 5's first act is handing that report
# to a reviewer — so a report that exists only in the conversation is one the
# next session cannot hand over and nobody can check was ever run. The marker is
# cleared by every phase change, exactly like the RED receipt, so it can only
# describe the Phase 4 that just ended.
validation_tripwire() {
  cur=$(sed -n 's/^phase=//p' "$STATE" | head -1)
  [ "$cur" = "4" ] || return 0          # only 4 -> 5 asserts a report
  st=$(sed -n 's/^task=//p' "$STATE" | head -1)
  # The marker carries the task and slice it was written for, and those fields
  # are read rather than merely recorded — data nothing consults is data that
  # drifts unnoticed until it is wrong. Deleting the marker on every phase
  # change covers most of this already, but `phase.sh slices` moves the slice
  # position with no phase change at all, so without this a report written for
  # slice 1 of 2 would still clear 4 -> 5 after the task was re-sliced.
  #
  # Exact match on the whole `slice` field, matching approval_status rather
  # than being cleverer than it. Re-sliced work has had its scope redrawn, and
  # re-running the repo's checks against the new shape is cheap next to
  # reasoning about which halves of a stale report still apply.
  case "$(validation_marker_status "$VALIDATION" "$st" "$(slice_current)/$(slice_total)")" in
    valid) return 0 ;;
    forged)
      echo "spec-driven: REFUSED — the validation marker could not be authenticated."
      echo "  It was not written by phase.sh validation: the marker carries a keyed"
      echo "  hash of its own fields, and this one does not verify. A marker that can"
      echo "  be written by hand certifies nothing, which is the whole reason 4 -> 5"
      echo "  asks for one. (A marker made before this version has no hash and lands"
      echo "  here too — re-record and it will be accepted.)"
      echo "  Run the repo's checks, then record them:"
      echo "    phase.sh validation <<'EOF'"
      echo "    ..."
      echo "    EOF"
      echo "  Override with: phase.sh 5 --force"
      return 1 ;;
    stale)
    vt=$(sed -n 's/^task=//p' "$VALIDATION" | head -1)
    vs=$(sed -n 's/^slice=//p' "$VALIDATION" | head -1)
    echo "spec-driven: REFUSED — the validation report on record was written for a"
    echo "  different point in this task (task '${vt:-?}', slice ${vs:-?}; you are on"
    echo "  task '${st:-?}', slice $(slice_current)/$(slice_total))."
    echo "  It describes work of a different shape, so it says nothing about what"
    echo "  Phase 4 is finishing now. Re-run the checks and record them again:"
    echo "    phase.sh validation <<'EOF'"
    echo "    ..."
    echo "    EOF"
    echo "  Override with: phase.sh 5 --force"
      return 1 ;;
  esac
  echo "spec-driven: REFUSED — no validation report on record for this Phase 4."
  echo "  Phase 5 hands the repo's own checks to the reviewer. A report that"
  echo "  exists only in this conversation cannot be handed over by the session"
  echo "  that resumes after this one, and nobody can check it was ever run."
  echo "  Run what this repo gates on, then record it:"
  echo "    phase.sh validation <<'EOF'"
  echo "    Commands: <exactly what you ran>"
  echo "    Source:   <where you got them>"
  echo "    Result:   <per command: pass, plus its summary line>"
  echo "    Not covered: <what this repo does not check at all>"
  echo "    EOF"
  echo "  Override with: phase.sh 5 --force"
  return 1
}

# review_pending_paths now lives in phase-policy.sh — phase-guard.sh gates the
# 5 -> 3 slice boundary on it, and the two layers have to agree on what is owed.
# It is still reported by `status` and `off` here, because the surprising part of
# this system is that turning the phase gate OFF makes review fire *more* often,
# not less: with no phase file the Stop gate runs every turn.

# --- Asking the user ----------------------------------------------------------
# The three decisions that are the user's are questions, not permission prompts
# on a shell command. `phase.sh ask <gate>` prints the question as an
# AskUserQuestion payload; the model passes it through verbatim and the user
# picks an option. approval-receipt.sh records the answer, and phase-guard.sh
# reads that instead of raising a prompt of its own.
#
# Emitting it here rather than writing it into the skill is the point. The
# receipt hook recognises a gate by matching the question text against
# phase-policy.sh, so a second copy in a SKILL.md would not drift into a wrong
# answer — it would drift into an answer nothing accepts, and a gate that
# silently stopped being redeemable looks exactly like a user who was never
# asked.
#
# stdout is JSON and nothing else, so it can be handed straight to the tool.
# Everything a human needs to read goes to stderr.
json_str() { printf '%s' "$1" | tr -d '"\\' | tr '\n\r\t' '   '; }

emit_question() {
  g="$1"
  q=$(gate_question "$g")
  if [ -z "$q" ]; then
    echo "spec-driven: no question is defined for gate '$g'." >&2
    return 1
  fi
  printf '{"questions":[{"header":"%s","question":"%s","multiSelect":false,"options":[' \
    "$(json_str "$(gate_header "$g")")" "$(json_str "$q")"
  first=1
  while IFS=$'\t' read -r _v l d; do
    [ -n "$l" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"label":"%s","description":"%s"}' "$(json_str "$l")" "$(json_str "$d")"
  done <<< "$(gate_options "$g")"
  printf ']}]}\n'
  [ "$first" = 0 ] || return 1
  return 0
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

# "Inactive" was the old answer from a worktree while the task was armed next
# door, and it is the wrong one in the most expensive way: the model reads it,
# concludes there is no gate, and carries on writing production code. Something
# IS started — just not here. Reported by `status` and refused by everything
# else, since no command can act on state in a tree this process is not in.
FOREIGN=""
if [ ! -f "$STATE" ] && command -v spec_foreign_state >/dev/null 2>&1; then
  FOREIGN=$(spec_foreign_state "$PROJECT_DIR")
fi
# `brief` joins `status` in being answerable from the wrong tree, and for a
# stronger reason than symmetry. It is the SessionStart hook, so it runs before
# the model has done anything — which is the one moment where "a task is armed,
# but not here" is still cheap to act on. Refusing it instead, as every other
# command is refused, printed that refusal on stdout, and stdout from this event
# goes into the model's context: the briefing slot would have been spent on an
# error message about the briefing.
if [ -n "$FOREIGN" ] && [ "${1:-status}" != status ] && [ "${1:-status}" != brief ]; then
  echo "spec-driven: REFUSED — $(spec_split_message "$FOREIGN" "$(spec_realpath "$PROJECT_DIR")")"
  exit 1
fi

case "${1:-status}" in
  status)
    if [ -n "$FOREIGN" ]; then
      echo "spec-driven: armed in ANOTHER WORKTREE, not here"
      echo "  -> gate state: $FOREIGN"
      echo "  -> this tree:  $(spec_realpath "$PROJECT_DIR")"
      echo "  -> nothing spec-gate does spans two trees, so the gate would report"
      echo "     itself armed while enforcing nothing on the files edited here."
      echo "  -> pick one tree: work from the first, or run 'phase.sh off' there"
      echo "     and start the task again here. Do not move .spec-phase by hand."
      report_review_state
      exit 0
    fi
    if [ ! -f "$STATE" ]; then
      echo "spec-driven: inactive"
      report_review_state
      exit 0
    fi
    P=$(sed -n 's/^phase=//p' "$STATE" | head -1)
    T=$(sed -n 's/^task=//p' "$STATE" | head -1)
    echo "spec-driven: phase $(phase_name "$P")  (task: ${T:-unnamed})"
    case "$(slice_status)" in
      corrupt) echo "  -> slice position is CORRUPT. Recover with: phase.sh off" ;;
      # A 1/1 task is the single-pass workflow and says nothing about slices, so
      # nobody who never asked for them pays a line of output for them.
      *) [ "$(slice_total)" -gt 1 ] && echo "  -> slice $(slice_current) of $(slice_total)" ;;
    esac
    # An answer already given and not yet spent. Reported because status is the
    # post-compaction re-read, and asking again a question the user has already
    # answered is precisely the friction this mechanism exists to remove.
    for g in $(gate_list); do
      A=$(approval_status "$g")
      case "$A" in
        none|stale|unverifiable) ;;
        *) echo "  -> the user has already answered the '$g' gate: $A" ;;
      esac
    done
    case "$P" in
      1) echo "  -> no files may be written"
         echo "  -> next: 2 Spec — Claude may advance" ;;
      2) if scaffold_armed; then
           echo "  -> SCAFFOLD MODE: docs/specs/, tests, and files that do not exist yet"
           echo "  -> nothing already tracked may be edited — that is Phase 4"
           echo "  -> show the surface test red first, then create the files"
           echo "  -> next: 3 Plan + tests — run 'phase.sh 3' when the surface exists"
         else
         echo "  -> docs/specs/ only"
         # Said here because status is what the model re-reads after compaction,
         # and the spec review is instructed rather than enforced — the one step
         # a forgetful model can drop without anything noticing.
         echo "  -> the spec goes to the spec-adversary subagent before you are asked"
         echo "  -> next: 3 Plan + tests — ask with 'phase.sh ask spec', then advance"
         fi ;;
      3) echo "  -> tests only; production code blocked"
         echo "  -> the plan goes to spec-adversary before the tests are written"
         # Same reason as the line above it: status is the post-compaction re-read,
         # and a lost session handle is exactly what compaction causes. Better a
         # cold round declared than a warm one claimed.
         echo "  -> reuse that session if you still hold it; if not, spawn fresh and say the round started cold"
         case "$(red_receipt_status)" in
           valid) echo "  -> RED verified — next: 4 Execute, ask with 'phase.sh ask red'" ;;
           stale) echo "  -> RED receipt STALE: the tests changed since. Re-run 'phase.sh red'" ;;
           *)     echo "  -> RED not verified — next: run 'phase.sh red' (Claude may do this)" ;;
         esac ;;
      4) echo "  -> normal permission flow; tests frozen; review gate suppressed"
         echo "  -> next: 5 Review — Claude may advance" ;;
      5) echo "  -> delegate to the adversary subagent; review gate ARMED"
         echo "  -> after a fix, go back to that same session; a new slice gets a new one"
         echo "  -> to close out, ask with 'phase.sh ask close-out' — never disarm on your own" ;;
      *) echo "  -> state file is corrupt, and the gate is failing closed."
         echo "  -> recover with: phase.sh off" ;;
    esac
    ;;

  start)
    mkdir -p "$STATE_DIR"
    # A newline in the task name would inject extra lines into the state file.
    T=$(printf '%s' "${2:-unnamed}" | tr -d '\n\r')
    # Removed rather than overwritten, so write_state stamps a new `started`
    # instead of carrying the previous task's forward. That stamp is what scopes
    # the reviewer verdicts in `brief` to this task.
    rm -f "$STATE"
    write_state 1 "$T" "1/1"
    # The journal goes too: a new task inheriting the last one's validation report
    # and findings is a briefing that lies, and it lies most convincingly to the
    # session that was not here for either task.
    rm -f "$RECEIPT" "$APPROVAL" "$SCAFFOLD" "$VALIDATION" "$JOURNAL"
    snapshot_baseline
    echo "spec-driven: started '${T}' at phase 1 (Clarify)"
    echo "  Any previous journal was deleted with the rest of that task's state."
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
      echo "  Recover with: phase.sh off"
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

  # Hand the model the question for a gate. Read-only: it prints wording and
  # changes nothing, which is why phase-guard.sh lets it through in every phase.
  # Asking is not approving — the answer is what moves anything, and the answer
  # arrives through the host.
  ask)
    [ -f "$STATE" ] || { echo "spec-driven: not started. Run: phase.sh start <task>" >&2; exit 1; }
    G="${2:-}"
    if ! printf '%s' " $(gate_list) " | grep -q " $G "; then
      echo "usage: phase.sh ask <$(gate_list | tr ' ' '|')>" >&2; exit 1
    fi
    emit_question "$G" || exit 1
    {
      echo
      echo "spec-driven: pass the JSON above to AskUserQuestion unchanged."
      echo "  The question text is what identifies this gate to the receipt hook."
      echo "  Reword it and the answer records nothing, so you would be asking twice."
      echo "  Everything you want to say about the decision goes in your own message"
      echo "  above the question, where it belongs — not in the question."
      echo "  This turn ends waiting on them, not with the task finished. If your"
      echo "  harness reads your message text to tell those apart — a background"
      echo "  job does — say which one it is there. 'needs input:', not 'result:'."
    } >&2
    ;;

  # Widen Phase 2 to create files that do not exist yet, so Phase 3's tests can
  # fail on an assertion instead of on a missing import. Its own command rather
  # than a phase number: a phase below 3 that wrote production code would be
  # reachable through the guard's retreat rule, which lets any move to a LOWER
  # number through unchecked on the grounds that lower has always meant stricter.
  scaffold)
    [ -f "$STATE" ] || { echo "spec-driven: not started. Run: phase.sh start <task>"; exit 1; }
    P=$(sed -n 's/^phase=//p' "$STATE" | head -1)
    if [ "$P" != 2 ]; then
      echo "spec-driven: scaffolding belongs to Phase 2, and you are at $(phase_name "$P")."
      echo "  It runs after the spec is approved and before Phase 3 writes tests,"
      echo "  so that the surface created is one the user has already read."
      exit 1
    fi
    T=$(sed -n 's/^task=//p' "$STATE" | head -1)
    printf '# spec-gate scaffold mode - written by phase.sh scaffold, never by hand\ntask=%s\n' "$T" > "$SCAFFOLD"
    echo "spec-driven: scaffold mode ON (still Phase 2)"
    echo "  -> you may CREATE files that do not exist yet, and tests"
    echo "  -> you may NOT edit anything already tracked; that is Phase 4"
    echo "  -> show the surface test failing first: phase.sh red"
    echo "  -> then create the files, and advance with: phase.sh 3"
    ;;

  red)
    [ -f "$STATE" ] || { echo "spec-driven: not started. Run: phase.sh start <task>"; exit 1; }
    P=$(sed -n 's/^phase=//p' "$STATE" | head -1)
    if [ "$P" != 3 ] && ! { [ "$P" = 2 ] && scaffold_armed; }; then
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

  journal)
    [ -f "$STATE" ] || { echo "spec-driven: not started. Run: phase.sh start <task>" >&2; exit 1; }
    journal_append journal "${2:-}"
    case $? in
      0) ;;
      1) exit 1 ;;                      # refused; journal_append said why
      *) echo "spec-driven: could not write $JOURNAL" >&2; exit 1 ;;
    esac
    echo "spec-driven: recorded in .claude/spec-journal.md"
    ;;

  validation)
    [ -f "$STATE" ] || { echo "spec-driven: not started. Run: phase.sh start <task>" >&2; exit 1; }
    P=$(sed -n 's/^phase=//p' "$STATE" | head -1)
    if [ "$P" != 4 ]; then
      echo "spec-driven: the validation report belongs to Phase 4, and you are at $(phase_name "$P")."
      echo "  It records the repo's own checks passing on the finished plan, which"
      echo "  is what Phase 4 cannot exit without."
      exit 1
    fi
    # The marker below is written only after this succeeds. That order is what
    # makes the refusal mean anything: a marker written first would clear 4 -> 5
    # on a report the journal never received.
    journal_append validation "VALIDATION REPORT"
    case $? in
      0) ;;
      1) exit 1 ;;                      # refused; journal_append said why
      *) echo "spec-driven: could not write $JOURNAL" >&2; exit 1 ;;
    esac
    T=$(sed -n 's/^task=//p' "$STATE" | head -1)
    { printf '# spec-gate validation marker — written by phase.sh validation, never by hand\n'
      printf 'task=%s\nslice=%s/%s\n' "$T" "$(slice_current)" "$(slice_total)"
    } > "$VALIDATION"
    # The authenticator, over the fields just written. Without it the marker is
    # a plain file the model can recreate, so every deletion route the guard
    # misses becomes a way to clear 4 -> 5 rather than merely to re-arm it.
    if ! spec_mac_write "$VALIDATION"; then
      rm -f "$VALIDATION"
      echo "spec-driven: could not authenticate the validation marker — no key could be" >&2
      echo "  written under .git/, or this host has no sha256 tool. The report is in the" >&2
      echo "  journal, but 4 -> 5 will refuse until this is fixed." >&2
      exit 1
    fi
    echo "spec-driven: validation report recorded — 4 -> 5 is clear."
    echo "  It is in .claude/spec-journal.md, which is where Phase 5 hands it to the"
    echo "  reviewer from, and where the next session finds it if this one ends first."
    ;;

  brief)
    # The read side of all of the above, and the only command here written to be
    # run by a hook rather than by a person. SessionStart calls it on startup,
    # resume, clear and compact, and for those events stdout is added to the
    # model's context — so it says nothing at all when no task is armed, and stays
    # bounded when one is. A briefing that grew without limit would spend exactly
    # the context it exists to save.
    # FOREIGN is only ever set when there is no state file here, so this has to
    # come before the exit that quietly says "nothing is armed" — which is the
    # bug the ordering used to have: the branch below was unreachable, and the
    # one case it existed for exited 0 in silence.
    if [ -n "$FOREIGN" ]; then
      echo "spec-driven: a task is armed in ANOTHER WORKTREE ($FOREIGN), not this one."
      echo "  Run 'phase.sh status' before writing anything you expect the gate to see."
      exit 0
    fi
    [ -f "$STATE" ] || exit 0
    BP=$(sed -n 's/^phase=//p' "$STATE" | head -1)
    BT=$(sed -n 's/^task=//p' "$STATE" | head -1)
    echo "spec-driven: this repo has an ACTIVE spec-driven task."
    echo "You did not start this conversation with it, so everything below was read"
    echo "off disk rather than remembered."
    echo
    echo "  task:  ${BT:-unnamed}"
    echo "  phase: $(phase_name "$BP")"
    [ "$(slice_total)" -gt 1 ] && echo "  slice: $(slice_current) of $(slice_total)"
    # Phase 1 has no spec yet — writing one is what Phase 2 is — so "NOT FOUND"
    # there reports the workflow working correctly as though it were damage. The
    # same holds at Phase 2 itself, where an absent spec means the phase is
    # unfinished rather than that something went missing: the line stays, because
    # a resuming session needs to know there is nothing written yet, but it says
    # which of the two it is.
    if [ "$BP" != 1 ]; then
      if [ -n "$BT" ] && [ -f "$PROJECT_DIR/docs/specs/$BT.md" ]; then
        echo "  spec:  docs/specs/$BT.md"
      elif [ "$BP" = 2 ]; then
        echo "  spec:  docs/specs/${BT:-<task>}.md — NOT FOUND; writing it is what Phase 2 is for"
      else
        echo "  spec:  docs/specs/${BT:-<task>}.md — NOT FOUND; find it before trusting the rest"
      fi
    fi
    # Each of these is reported only where it can be true, which is narrower than
    # where it bears on the next move — and the difference is the whole point.
    # Every phase transition deletes both receipts, so at Phase 4 the RED receipt
    # is gone by construction and "RED: not verified" is not a finding about the
    # tests, it is a description of the transition that just happened. Printing
    # it there told a resuming session its verified tests were unverified, which
    # is the one thing a briefing must never do. Same for the checks line at
    # Phase 5: the marker that cleared 4 -> 5 was deleted by 4 -> 5.
    if [ "$BP" = 3 ]; then
      case "$(red_receipt_status)" in
        valid) echo "  RED:   verified" ;;
        stale) echo "  RED:   receipt STALE — the tests changed since; re-run 'phase.sh red'" ;;
        *)     echo "  RED:   not verified — run 'phase.sh red'" ;;
      esac
    fi
    if [ "$BP" = 4 ]; then
      # The same predicate 4 -> 5 reads, not `[ -f ]`. Testing existence alone
      # announced a stale or unauthenticated marker as a recorded report, and the
      # transition then refused the very thing the briefing had just promised.
      BT=$(sed -n 's/^task=//p' "$STATE" | head -1)
      case "$(validation_marker_status "$VALIDATION" "$BT" "$(slice_current)/$(slice_total)")" in
        valid)  echo "  checks: a validation report is recorded for this Phase 4" ;;
        stale)  echo "  checks: the report on record was written for a different task or slice —" ;
                echo "          4 -> 5 will refuse until 'phase.sh validation' runs again" ;;
        forged) echo "  checks: the marker on record does not authenticate and will not be" ;
                echo "          accepted — re-run 'phase.sh validation'" ;;
        *)      echo "  checks: none recorded — 4 -> 5 will refuse until 'phase.sh validation' runs" ;;
      esac
    fi
    for g in $(gate_list); do
      A=$(approval_status "$g")
      case "$A" in
        none|stale|unverifiable) ;;
        *) echo "  answered: the user has already answered the '$g' gate: $A" ;;
      esac
    done
    echo
    # Where Execute got to is the one part of "where was I" that git answers
    # better than any journal, so it is read live rather than recorded.
    # Read once and reused. This is a SessionStart hook with a timeout, and the
    # second identical `git status` bought nothing but another chance to be the
    # call that runs long on a large repo and takes the whole briefing with it.
    PORC=$( (cd "$PROJECT_DIR" 2>/dev/null && git status --porcelain 2>/dev/null) )
    if [ -n "$PORC" ]; then
      N=$(printf '%s\n' "$PORC" | wc -l | tr -d ' ')
      echo "Uncommitted right now — $N path(s), first 10:"
      printf '%s\n' "$PORC" | head -10 | sed 's/^/  /'
      echo
    fi
    if [ -s "$JOURNAL" ]; then
      # Deliberately not "the state of the work". Everything above this line was
      # written by a hook the model cannot reach; the journal is prose a previous
      # session wrote about itself, and it is the only thing here that can be
      # confidently wrong. Saying so is cheaper than making it unforgeable —
      # denying the model write access would only protect its own notes from
      # their author — and a briefing that flattens the two into one register
      # teaches the reader to trust the weaker half as much as the stronger.
      echo "Journal tail — the last 40 lines of .claude/spec-journal.md, which is longer."
      echo "These are a previous session's own notes, not verified state: what they claim"
      echo "was run or decided is testimony. Read the file in full, and re-check anything"
      echo "you are about to build on."
      tail -40 "$JOURNAL" | sed 's/^/  /'
      echo
    else
      echo "Journal: empty. Nothing has been recorded for this task yet."
      echo
    fi
    # The log is append-only and spans the repo, not the task. Printed whole, a
    # brand-new task's briefing opened with a verdict about work it has nothing
    # to do with — in the register this briefing reserves for facts read off
    # disk. It is filtered rather than deleted: it is the only durable record
    # that a review ever happened, and `start` throwing it away would destroy
    # the audit trail to fix a display bug.
    #
    # SINCE empty (an install predating the stamp) means unfiltered, which is
    # today's behaviour rather than an empty section.
    SINCE=$(sed -n 's/^started=//p' "$STATE" 2>/dev/null | head -1)
    if [ -s "$STATE_DIR/review-log.jsonl" ]; then
      # Filtered first, THEN the last 5: taking the tail first meant five old
      # entries hid two current ones. And the header is printed from the result
      # rather than ahead of it — jq aborts the whole stream on the first
      # malformed line, so a log torn by a killed hook produced the sentence
      # "Reviewer verdicts on record" with nothing underneath it.
      VERD=''
      if command -v jq >/dev/null 2>&1; then
        # -R with fromjson? skips a torn line instead of ending the stream.
        VERD=$(jq -Rr --arg since "$SINCE" '
          fromjson? // empty
          | select($since == "" or (.t // "") >= $since)
          | "  \(.t) \(.agent): \(((.msg // "") | split("\n") | map(select(length > 0)) | first // "")[0:160])"' \
          "$STATE_DIR/review-log.jsonl" 2>/dev/null | tail -5)
      elif command -v python3 >/dev/null 2>&1; then
        # Same fallback phase-guard.sh already relies on. Silently skipping this
        # section on a machine without jq made a briefing with no reviewer
        # history look like a task that had never been reviewed.
        VERD=$(python3 -c '
import sys, json
since = sys.argv[1]
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if since and (d.get("t") or "") < since: continue
    msg = (d.get("msg") or "").split("\n")
    first = next((s for s in msg if s), "")
    print("  %s %s: %s" % (d.get("t"), d.get("agent"), first[:160]))' \
          "$SINCE" < "$STATE_DIR/review-log.jsonl" 2>/dev/null | tail -5)
      else
        VERD="  (neither jq nor python3 is installed, so the verdicts could not be read;
   they are in .claude/review-log.jsonl)"
      fi
      if [ -n "$VERD" ]; then
        echo "Reviewer verdicts on record for this task — the last 5, oldest first."
        echo "Like the journal, these are a reviewer's claims about the work, not"
        echo "verified state: a verdict of 'sound' is one agent's reading, and the"
        echo "fixes it describes are only as done as the diff says they are."
        printf '%s\n' "$VERD"
        echo
      fi
    fi
    # Only Phase 5 has reviewer sessions to have lost. Said at Phase 1 it is a
    # warning about something that does not exist yet, and the reader who learns
    # to skim it here is the reader who skims it where it matters.
    if [ "$BP" = 5 ]; then
      echo "Your reviewer sessions did NOT survive. Spawn fresh ones and record in the"
      echo "evidence log that the round started cold — a reviewer that has forgotten its"
      echo "own findings cannot tell you whether a fix landed."
    fi
    echo "Run 'phase.sh status' for what you may write and who owns the next move."
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
    if [ "$1" = 5 ]; then
      case "${2:-}" in
        --force)
          echo "spec-driven: --force — advancing with no validation report recorded." ;;
        *)
          validation_tripwire || exit 1 ;;
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
    #
    # The approval receipt goes for the mirror reason: an answer is given about
    # one phase and spent in it. It is also pinned to the phase it was answered
    # in, so this delete is the second of two locks — cheap, and the kind of
    # redundancy worth having on the file that says the user said yes.
    # The validation marker rides with the RED receipt for the same reason: it
    # describes one Phase 4, and every phase change ends that Phase 4 — including
    # a retreat back into it. The journal itself survives; it is the history, and
    # the history is what a resuming session has instead of a memory.
    rm -f "$RECEIPT" "$APPROVAL" "$SCAFFOLD" "$VALIDATION"
    snapshot_baseline
    echo "spec-driven: -> $(phase_name "$1")"
    if [ "$ADVANCED" = 1 ]; then
      echo "  -> slice $CUR of $TOT — tick the previous one off the checklist in docs/specs/"
    fi
    ;;

  off)
    rm -f "$STATE" "$BASELINE" "$RECEIPT" "$APPROVAL" "$SCAFFOLD" "$VALIDATION" "$JOURNAL"
    echo "spec-driven: phase gate off"
    echo "  This ends the phase workflow. It does not stop review — with no phase"
    echo "  file the Stop gate returns to its default and runs EVERY turn."
    # Said out loud because it is the one thing here that git cannot give back.
    # The phase is re-declarable and the code is committed or in the tree; the
    # journal is gitignored by design, so `off` is the only destructive act in
    # this script that has no undo.
    echo "  The journal went with it: .claude/spec-journal.md is deleted, and it is"
    echo "  gitignored, so nothing in git has a copy. The validation report, which"
    echo "  findings were acted on and which declined, and how far Execute got are"
    echo "  gone. Copy anything you still need into the PR or the spec before now."
    report_review_state
    ;;

  *)
    echo "usage: phase.sh [status | brief | start <task> | ask <gate> | red | scaffold |"
    echo "                slices <n> | journal | validation | 1..5 | off]"
    # Derived, not retyped. This line said "spec | red | close-out" while
    # gate_list had grown to nine, and the `ask` command a few hundred lines up
    # already builds its own error from gate_list — so the usage was the only
    # copy that could drift, and had.
    echo "       phase.sh ask <gate>  print the question for a gate as an"
    echo "                            AskUserQuestion payload:"
    echo "                            $(gate_list | tr ' ' '|')"
    echo "       phase.sh red         run the Phase 3 tests and record RED if they fail"
    echo "       phase.sh slices <n>  set how many slices this task lands in"
    echo "       phase.sh brief       reconstruct the task from disk, for a session"
    echo "                            that has lost it — run by the SessionStart hook"
    echo "       phase.sh journal [label] < entry"
    echo "                            append a stamped entry to .claude/spec-journal.md"
    echo "       phase.sh validation < report"
    echo "                            record the Phase 4 validation report; 4 -> 5 needs it"
    echo "       phase.sh 4 --force   advance without the RED check"
    echo "       phase.sh 5 --force   advance without a recorded validation report"
    exit 1
    ;;
esac
