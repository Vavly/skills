#!/usr/bin/env bash
# phase-guard.sh — PreToolUse hook for the spec-driven workflow.
#
# Enforces "no code before spec" as a tool-level block rather than an
# instruction. PreToolUse hooks fire before the permission-mode check, in every
# mode including bypassPermissions, and a deny blocks the call regardless. That
# is what makes this a gate and not a suggestion.
#
# Prevention only. It is precise for Edit/Write/NotebookEdit, where the path is
# a structured field, and best-effort for Bash, where it has to read intent out
# of a command string. Completeness is not this layer's job — the Stop scan in
# review-gate.sh catches whatever gets through.
#
# Inactive unless .claude/.spec-phase exists, so it costs nothing on normal work.
#
# Install: .claude/hooks/phase-guard.sh  (chmod +x)

set -uo pipefail

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- JSON reading, without a hard jq dependency ------------------------------
# A missing parser used to make this hook exit 0 silently, i.e. fail open, which
# is worse than not having a gate at all. It now falls back to python3 and, if
# neither exists, fails CLOSED with a visible reason.
PARSER=""
command -v jq      >/dev/null 2>&1 && PARSER=jq
[ -z "$PARSER" ] && command -v python3 >/dev/null 2>&1 && PARSER=python3

json_get() {  # $1 = dotted path, e.g. tool_input.file_path
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

# Decisions are built with printf so that emitting one needs no parser at all.
# The reason is stripped of the characters that would break hand-built JSON: a
# path containing a double quote used to produce malformed JSON, which Claude
# Code treats as "no decision" — so the deny was silently dropped and the call
# proceeded. Sanitising here covers every call site at once.
decide() {  # $1 = allow|deny|ask, $2 = reason
  reason=$(printf '%s' "$2" | tr -d '"\\' | tr '\n\r\t' '   ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$reason"
  exit 0
}

deny() { decide deny "$1"; }

# `ask` forces a confirmation prompt instead of refusing outright. Used for the
# one checkpoint where in-band approval is proportionate — see the advance policy
# below. Note that a hook's `ask` is NOT documented to survive
# bypassPermissions, unlike a `deny` and unlike an explicit `ask` rule in
# settings; settings.json carries a matching ask rule to cover that mode.
ask() { decide ask "$1"; }

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(json_get cwd)}"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"
STATE="$PROJECT_DIR/.claude/.spec-phase"

# The policy file is read before the "is anything armed here" check, because the
# answer to that question now lives in it: a tree with no state of its own may
# still be the wrong half of a split.
if [ ! -r "$HOOK_DIR/phase-policy.sh" ]; then
  [ -f "$STATE" ] && deny "phase-guard cannot read phase-policy.sh next to it in $HOOK_DIR. Failing closed rather than guessing at the policy."
  exit 0
fi
# shellcheck source=phase-policy.sh
. "$HOOK_DIR/phase-policy.sh"

# No state HERE is not the same as no state. It also describes a session standing
# in a worktree while the task is armed next door, and that used to exit 0 — the
# gate silently absent in exactly the tree the work was happening in. Checked
# before the early exit, because the early exit is the bug.
if [ ! -f "$STATE" ]; then
  FOREIGN=$(spec_foreign_state "$PROJECT_DIR")
  [ -n "$FOREIGN" ] && deny "$(spec_split_message "$FOREIGN" "$(spec_realpath "$PROJECT_DIR")")"
  exit 0                             # workflow not active anywhere: nothing to enforce
fi

if [ -z "$PARSER" ]; then
  deny "phase-guard cannot read the tool call: neither jq nor python3 is on PATH. Failing closed. Install jq, or ask the user to run phase.sh off to disable the phase gate."
fi

# A corrupt state file used to fall through to exit 0, silently disabling the
# gate — the same fail-open bug as a missing parser. It now fails closed, with a
# reason that says how to recover.
PHASE=$(sed -n 's/^phase=//p' "$STATE" | head -1)
case "$PHASE" in
  1|2|3|4|5) ;;
  *) deny "phase-guard: .claude/.spec-phase is corrupt (phase=$PHASE). Failing closed, because a broken state file must not silently disable the gate. Ask the user with 'phase.sh ask abandon', or repair the file." ;;
esac

TOOL=$(json_get tool_name)
CMD=""
PATHS=""
case "$TOOL" in
  Edit|Write|NotebookEdit) PATHS=$(json_get tool_input.file_path) ;;
  Bash)                    CMD=$(json_get tool_input.command) ;;
  *) exit 0 ;;
esac

# --- Phase state is off limits, in every phase -------------------------------
# Checked before the phase>=4 early exit below. Otherwise at Phase 5 the model
# could write phase=4 and suppress the review gate, and at any phase it could
# `rm` the state file to unlock production writes. Denying every command that
# so much as mentions the file is blunt but breaks nothing: the model reads
# phase state through `phase.sh status`, never through the file.
if [ -n "$CMD" ]; then
  case "$CMD" in
    *.spec-phase*|*.spec-baseline*|*.spec-red*|*.spec-approval*)
      deny "The phase state is not yours to edit, move or remove — .spec-red and .spec-approval included, because a receipt you could write by hand would assert RED without running anything, or record an approval the user never gave. Change phases with phase.sh <n>, verify RED with phase.sh red, ask the user with phase.sh ask <gate>, and read the current phase with phase.sh status." ;;
  esac
fi
if [ -n "$PATHS" ] && is_phase_state "$PATHS"; then
  deny "The phase state is not yours to edit. Phases change by running phase.sh <n>, and the ones that are the user's change on an answer they gave — never by writing this file."
fi

# --- Who may advance a phase -------------------------------------------------
# Each phase widens what may be written, so the user is required exactly where
# write access expands, and nowhere else. Everything the model may do either
# restricts it or increases scrutiny.
#
# A PreToolUse hook cannot tell a Bash call the model chose to make from one a
# user's slash command told it to make — both arrive identically. That used to
# mean "the user decides" could not be expressed as an allow at all: it had to be
# an `ask`, or a denial pointing at a terminal.
#
# The approval receipt changes what this hook can know. It cannot see who made
# the call, but it can see whether the user answered the gate's question, because
# that answer came back through the host and was recorded by a PostToolUse hook
# the model has no way to write to. So the three approval gates now read a
# receipt first and allow on it, and fall back to the `ask` they always raised
# when there is no receipt to read. The fallback is not a leftover — it is what
# makes it safe to build on AskUserQuestion's undocumented result shape, since
# every way of failing to recognise an answer lands on the old behaviour.
#
# Everything that would route *around* those gates — forward skips, moves off
# Phase 5, `off` from 1-3, re-arming, --force — reads a receipt of its own. They
# were terminal-only for the same limitation, and they stop being terminal-only
# for the same reason: an answer through the host is evidence the user decided,
# which a permission prompt on a shell command never was.
if [ -n "$CMD" ] && printf '%s' "$CMD" | grep -qE '(^|[^[:alnum:]_.+-])phase\.sh([[:space:]]|$)'; then
  ARG=$(printf '%s' "$CMD" | sed -nE 's|.*phase\.sh[[:space:]]+([^[:space:];&|]+).*|\1|p' | head -1)
  ARG=${ARG#[\"\']}; ARG=${ARG%[\"\']}

  # These five used to be "go run it in your own terminal", because a PreToolUse
  # hook cannot tell a Bash call the model chose from one a slash command made.
  # The receipt closes that: it does not say who called, but it proves the user
  # answered, because the answer came back through the host and was written by a
  # hook the model has no way to reach. So each one is now a question the model
  # may put, and the transition goes through on the answer.
  #
  # The fallback is the safety property and is deliberately today's behaviour: no
  # receipt, a stale one, or an answer nothing recognised all land on a denial.
  # What changed is what the denial tells you to do — ask, rather than leave the
  # session. Nothing here can proceed on the model's own say-so.
  gated_advance() {
    # $1 = gate name, $2 = what is being attempted, for the message
    case "$(approval_status "$1")" in
      approve)
        decide allow "The user was asked and approved this: $2. The answer was recorded from their reply, not from Claude." ;;
      decline)
        deny "The user was asked and declined this: $2. Do not look for another route, and do not ask again until something has actually changed — re-asking an answered question until the answer changes is not consent." ;;
      expired)
        deny "That answer was given at a different point in this task — another phase or slice — so it does not decide this one. Ask again: phase.sh ask $1" ;;
      *)
        deny "This needs the user, and they have not been asked yet: $2. Put the question to them — run 'phase.sh ask $1' and pass the JSON it prints to AskUserQuestion unchanged, then act on their answer. Current phase: $PHASE." ;;
    esac
  }

  # Deliberately not one helper for every caller. The three sites that used to
  # share advance_deny are three different decisions — skipping ahead, walking
  # away from an owed review, and abandoning before any code exists — and one
  # question standing for all three would be answered once and spent on whichever
  # came up. Each names its own gate.
  advance_deny() {
    gated_advance skip "advancing from phase $PHASE to phase $1, which skips the approval gates in between"
  }

  # --force is the user's override for a refused RED check, and it exists
  # precisely because the check is the thing standing between the model and
  # production writes. Denied in every phase, before ARG is even considered.
  # --force advances past the RED check on an assertion rather than on evidence,
  # which is why it is the one flag the model may never supply on its own. It is
  # still not the model's: what changed is that the user can now answer for it
  # here instead of leaving the session, and the answer is what allows it.
  case "$CMD" in
    *--force*)
      gated_advance force "advancing to Phase 4 with --force, which skips the RED check entirely and unlocks production code without anything having been shown to fail" ;;
  esac

  case "$ARG" in
    status|"") ;;                       # read-only, always fine
    red) ;;                             # verification, not advancement — see below
    # Printing a question changes nothing, in any phase. Asking is not
    # approving: the answer arrives through the host, and only an answer moves a
    # gate. Allowing this freely is what makes the question the normal way to
    # reach a checkpoint rather than a step worth skipping.
    ask) ;;
    slices)
      # Before the spec is approved the count is not approved either: the seams
      # are declared in the spec and the 2 -> 3 prompt covers them, so asking
      # separately would put the same question twice seconds apart.
      #
      # After that the total is something the user accepted, and changing it is
      # theirs. Nothing here asks *why* it changed, because the model has already
      # answered that by running this command at all: `slices` asserts more work
      # than estimated, and a design that turned out wrong routes to the 4 -> 2
      # contradiction path instead. The prompt's job is to surface the claim so
      # it can be rejected.
      if [ "$PHASE" -ge 3 ]; then
        ask "Change the number of slices this task lands in? It is currently slice $(slice_current) of $(slice_total), and that total is part of what you approved at 2 -> 3. Claude is asserting this is MORE WORK than estimated — not that the design is wrong. If you think the spec itself no longer holds, decline and ask it to retreat to Phase 2 for a re-approved spec. Whatever you accept, the slice checklist in docs/specs/ must be updated to match."
      fi ;;
    start)
      gated_advance restart "re-arming at Phase 1, which discards the task currently at phase $PHASE along with every approval already given" ;;
    off)
      # `off` from phases 1-3 grants production writes: same as jumping to 4.
      [ "$PHASE" -le 3 ] && gated_advance abandon "turning the gate off at phase $PHASE, before any production code has been written or any spec approved"
      # From 4 or 5 it expands nothing, which is why this used to be the model's
      # to take freely. That was wrong for a reason that has nothing to do with
      # write access: `off` ends the task, and the end of a task is the one
      # moment the user decides what happens to the work — ship it, keep
      # iterating, throw it away. A model that disarms on its own has skipped
      # that conversation and presented the outcome as settled.
      # Completion is checked here, on the way out, and never at Phase 5 —
      # `adversary` has to stay ignorant of the other slices, because telling it
      # "this is slice 2 of 5" invites it to excuse a gap as coming later, which
      # is the one thing a reviewer must refuse to grant.
      OFF_SLICES=""
      if slices_remain; then
        OFF_SLICES=" You are on slice $(slice_current) of $(slice_total), so $(( $(slice_total) - $(slice_current) )) more are unimplemented — ending now leaves the task half-built, and nothing afterwards remembers that it was sliced."
      fi
      # This is the gate the question buys the most on, because the decision was
      # never binary. A confirmation prompt can only offer yes or no, so the old
      # reason string had to ask in prose for a third answer — "if the work should
      # become a pull request, say so instead of accepting" — and hope. Three
      # options make each outcome something the guard can act on, and `continue`
      # becomes a refusal rather than a prompt the user declined for reasons
      # nothing recorded.
      case "$(approval_status close-out)" in
        pr)
          # Chosen "open a PR", so the PR comes first and disarming follows it.
          # Committing is how the review gate goes quiet, which makes a clean
          # tree the observable half of "the PR exists" — the same test the slice
          # boundary already uses, rather than a second idea of done.
          if [ -n "$(review_pending_paths)" ]; then
            deny "The user chose to open a pull request, and this work is not committed yet: $(review_pending_paths | tr '\n' ' '). Open the PR first, then disarm — that order is the whole point of the answer they gave. Disarming now would arm the review gate on every turn against this same diff."
          fi
          # OFF_SLICES rides on both allows, not just the fallback prompt. It
          # used to appear only when the model reached `off` WITHOUT asking —
          # i.e. on the path the workflow forbids — so an eight-slice task
          # answered through the gate disarmed after slice one with nothing on
          # screen about the other seven. The warning was there; it was wired to
          # the branch nobody takes.
          decide allow "The user chose to open a pull request and nothing is left uncommitted, so the work has shipped. Disarming is what they asked for next.${OFF_SLICES}" ;;
        disarm)
          decide allow "The user chose to disarm and keep the working tree as it stands. They were told the review gate returns to firing every turn while anything is uncommitted.${OFF_SLICES}" ;;
        continue)
          deny "The user chose to keep iterating in Phase 5, so the gate stays on and this task is not over. Say what is still outstanding and wait for them. Do not ask again until something has actually changed — re-asking an answered question until the answer changes is not consent." ;;
        slice)
          # They picked the boundary, not the end. Same shape as `continue`: an
          # answer that keeps the task alive can never be redeemed for `off`.
          deny "The user chose to commit this slice and open slice $(( $(slice_current) + 1 )) of $(slice_total), which is not a close-out — the task continues and the gate stays on. Commit the reviewed work, tick this slice off the checklist in docs/specs/, then run phase.sh 3 to open the next one." ;;
        expired)
          deny "That close-out answer was given at a different point in this task — a different phase or slice — so it does not decide this one. Ask again: phase.sh ask close-out" ;;
        *)
          ask "End the spec-driven workflow for this task?${OFF_SLICES} This is the close-out decision: the phase gate stops, and whatever is in the working tree is what you are left with. If the work should become a pull request, say so instead of accepting — that happens before disarming, not after. Note that turning the gate off makes the review gate fire on EVERY turn while the tree is dirty, so decline this if the diff is not committed yet." ;;
      esac ;;
    "$PHASE") ;;                        # no-op
    1|2|3|4|5)
      if [ "$PHASE" = 5 ]; then
        # Phases 1-4 suppress the Stop gate, so a move off 5 escapes the review
        # currently owed — it would launder an unreviewed diff into the next
        # slice's baseline, where nothing would look at it again.
        #
        # 5 -> 3 is the one exception, and only once that escape is closed: the
        # condition is that nothing is owed review, which is exactly what
        # review_pending_paths reports. That puts every slice boundary on a
        # commit, since committing is how the gate goes quiet. It stays the
        # model's move because it expands no write access — Phase 3 is stricter
        # than Phase 5, and the 3 -> 4 prompt is still ahead of it.
        if [ "$ARG" = 3 ] && [ "$(slice_current)" -lt "$(slice_total)" ]; then
          if [ -n "$(review_pending_paths)" ]; then
            deny "Slice $(slice_current) of $(slice_total) is not finished: its diff has not been reviewed and committed, and starting the next slice now would fold it into the new baseline where the review gate stops seeing it. Commit this slice, then advance. Outstanding: $(review_pending_paths | tr '\n' ' ')"
          fi
          :                               # next slice: this one is clean
        else
          gated_advance leave-review "moving from Phase 5 to phase $ARG while a diff is still owed review — phases 1 to 4 suppress the review gate, so nothing looks at it again"
        fi
      elif [ "$ARG" -lt "$PHASE" ]; then
        :                               # retreat: strictly more restrictive
      elif [ "$PHASE" = 1 ] && [ "$ARG" = 2 ]; then
        :                               # writing a spec is harmless; 2->3 is the gate
      elif [ "$PHASE" = 4 ] && [ "$ARG" = 5 ]; then
        :                               # self-submits to review
      elif [ "$PHASE" = 2 ] && [ "$ARG" = 3 ]; then
        # Spec approval, in band. The user is reading the spec in the
        # conversation anyway, so one confirmation is proportionate.
        #
        # The spec review this mentions is instructed, not enforced: no hook can
        # judge whether a subagent actually read the spec, and gating this
        # transition on a SubagentStop receipt would hand the workflow a hard
        # block whenever that payload shape changed. So the prompt does the one
        # thing it can — tell the user what should already be on screen, and
        # what its absence means.
        #
        # The prompt is now the fallback rather than the asking. If the model put
        # the question to the user properly, an approval receipt exists and this
        # transition is already decided — raising a second confirmation for a
        # decision made seconds ago is how a checkpoint becomes a reflex.
        #
        # Every unrecognised receipt state lands on that fallback, which is the
        # whole safety argument for building on an undocumented payload shape:
        # the worst case is the prompt this gate has always raised.
        case "$(approval_status spec)" in
          approve)
            decide allow "The user approved this spec through the gate's own question, and no spec document has changed since they answered." ;;
          decline)
            deny "The user was asked and sent the spec back, and nothing in docs/specs/ has changed since. Revise the spec against what they said, then ask again: phase.sh ask spec" ;;
          stale)
            deny "The user's approval does not match what is in docs/specs/ now: either a document moved since they answered, or there was nothing there to approve when they did. Either way it does not cover the spec on disk. Show them the spec as it stands and ask again: phase.sh ask spec" ;;
          expired)
            deny "That approval was given at a different point in this task, so it is an answer about something else. Ask again: phase.sh ask spec" ;;
          *)
            ask "Approve the spec and advance to Phase 3 (Plan + failing tests)? Approving asserts that you have read docs/specs/ and accept the approach, the types, and the out-of-scope list. The spec should have been through the spec-adversary reviewer first: if you have not seen its verdict in this conversation, decline and ask for it. Phase 3 writes tests only; production code stays blocked until Phase 4." ;;
        esac
      elif [ "$PHASE" = 3 ] && [ "$ARG" = 4 ]; then
        # Unlocking production code. This used to be terminal-only, on the
        # grounds that a permission prompt is a low-attention action and the RED
        # claim was pure assertion — a reflex click would have hollowed it out.
        #
        # The receipt is what changes that. `phase.sh red` has run the tests as a
        # tool call, so the failure output is in the transcript the user is
        # already reading, and the receipt pins the content of every test file it
        # saw fail. Approving is now a judgment on visible evidence rather than a
        # click standing in for a check nobody did.
        #
        # Without a valid receipt this stays a denial. The prompt is only worth
        # offering when there is something on screen to approve.
        # Two receipts, and both are required. The RED receipt says the machine
        # checked something; the approval receipt says the user judged it. Neither
        # substitutes for the other, and the order is fixed — there is nothing to
        # ask about until the failures are on screen.
        case "$(red_receipt_status)" in
          valid)
            case "$(approval_status red)" in
              approve)
                decide allow "The user read the failures and accepted them through the gate's own question, and the RED receipt they were shown is unchanged." ;;
              decline)
                deny "The user was asked and said one of those tests failed for the wrong reason. Fix it, re-run phase.sh red, and ask again: phase.sh ask red" ;;
              stale)
                deny "The RED receipt has been rewritten since the user answered, so they accepted a different set of failures from the one on disk. Show the new output and ask again: phase.sh ask red" ;;
              expired)
                deny "That answer was given at a different point in this task, so it is an answer about other failures. Re-run phase.sh red and ask again: phase.sh ask red" ;;
              *)
                ask "Advance to Phase 4 (Execute) and unlock production code? RED is mechanically verified: the tests this phase added were run and failed, and none of them has changed since. What that does NOT prove is that they failed for the reason the spec expects — that is the part you are approving. Read the failure output above before accepting." ;;
            esac ;;
          stale)
            deny "The RED verification is stale: the test files have changed since they were checked. Run phase.sh red again, show the output, and then ask to advance. Current phase: $PHASE." ;;
          *)
            deny "RED has not been verified yet, so Phase 4 stays locked. Run phase.sh red — it runs the tests this phase changed and refuses if they pass. Show the failure output, say why each failure is the expected one, then advance. If this repo has no test command configured, write one to .claude/spec-gate-test-cmd — that path is gate config, not production code, and is writable in every phase — then run the check. Work out the command from package.json, pyproject.toml, the Makefile or CI rather than guessing. Only ask the force gate if nothing in the repo says how its tests run: forcing spends the user's approval in place of evidence you could have produced." ;;
        esac
      else
        advance_deny "$ARG"
      fi ;;
  esac
fi

[ "$PHASE" -ge 4 ] && exit 0            # execute onward: normal permission flow

# --- What would this Bash command write? -------------------------------------
# Parse the forms whose target is unambiguous. Refuse the write-ish forms whose
# target cannot be parsed, rather than allowing them — the earlier version
# matched tee/sed -i/dd and then allowed them all, because it only ever
# extracted redirect targets. Anything still missed is caught by the Stop scan.
#
# This reads a token stream rather than the raw command text. The raw-text
# version asked "is there a > in this string?", which is not the question it
# meant to ask, and the gap between the two refused a steady stream of commands
# that wrote nothing. The expensive one is the JS arrow function: `c => {d+=c}`
# was read as a redirect and denied as a write to a production file named
# `{d+=c}`. So were a comparison inside a quoted jq or awk program, a `>` in a
# grep pattern, and an arrow in a commit message.
#
# Worst of all was the heredoc, because Phase 3 is where the plan document gets
# written and a plan names the files it touches. The body was scanned as though
# it were shell, so an arrow in a sentence or a mermaid diagram made authoring
# the plan through Bash impossible — the gate blocking the workflow it exists to
# enforce, with no way around it but rewording prose until the regex lost
# interest.
#
# Quoting and heredoc bodies are therefore tracked properly: a `>` is an operator
# only where the shell would treat it as one, and a heredoc body is data. What
# does NOT change is what happens once a target is found — an unparseable target
# is still denied, and every case the old scanner caught it still catches.

# One token per line: "OP<TAB>>", "OP<TAB>>>", "SEP", or "WORD<TAB><text>".
# Quotes are consumed rather than stripped afterwards, so a quoted redirect
# target survives as a single word: the target of `> "src/a b.ts"` is
# `src/a b.ts`, not the `"src/a` the regex used to report.
#
# Newlines inside a word become spaces. A path containing one is beyond what
# this can evaluate, and collapsing it keeps one word on one line — the reader
# below is line-oriented, and a word that split across lines would have its tail
# silently dropped, which for a redirect target means dropped from the check.
_LEXW=''; _LEXH=0
_lex_flush() {
  [ "$_LEXH" = 1 ] && printf 'WORD\t%s\n' "${_LEXW//$'\n'/ }"
  _LEXW=''; _LEXH=0
  return 0
}

lex_command() {
  # Two statements, not one: `local s=$1 n=${#s}` localises every name before it
  # assigns any, so ${#s} read an unset s and `set -u` killed the hook outright.
  # A dead hook emits no decision, which Claude Code reads as "no opinion" — so
  # the whole Bash gate failed OPEN. Exactly the shape of the fail-open the
  # parser and the corrupt-state branches were written to avoid.
  local s=$1
  local n=${#s} i=0 c op delim strip line rest hdocs='' entry
  _LEXW=''; _LEXH=0
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    case $c in
      "'")                              # single quotes: everything is literal
        i=$((i+1))
        while [ "$i" -lt "$n" ] && [ "${s:i:1}" != "'" ]; do
          _LEXW="$_LEXW${s:i:1}"; i=$((i+1))
        done
        i=$((i+1)); _LEXH=1 ;;
      '"')
        i=$((i+1))
        while [ "$i" -lt "$n" ] && [ "${s:i:1}" != '"' ]; do
          if [ "${s:i:1}" = '\' ] && [ $((i+1)) -lt "$n" ]; then
            _LEXW="$_LEXW${s:i+1:1}"; i=$((i+2))
          else
            _LEXW="$_LEXW${s:i:1}"; i=$((i+1))
          fi
        done
        i=$((i+1)); _LEXH=1 ;;
      '\')
        _LEXW="$_LEXW${s:i+1:1}"; i=$((i+2)); _LEXH=1 ;;
      ' '|$'\t')
        _lex_flush; i=$((i+1)) ;;
      $'\n')
        _lex_flush; printf 'SEP\n'; i=$((i+1))
        # A heredoc body begins on the line after its operator, so this is where
        # the pending ones get consumed. Skipped whole: nothing inside is shell.
        while [ -n "$hdocs" ]; do
          entry=${hdocs%%$'\n'*}; hdocs=${hdocs#*$'\n'}
          strip=${entry%%:*}; delim=${entry#*:}
          while [ "$i" -lt "$n" ]; do
            rest=${s:i}; line=${rest%%$'\n'*}
            i=$((i + ${#line} + 1))
            if [ "$strip" = 1 ]; then
              while case $line in $'\t'*) true ;; *) false ;; esac; do line=${line#?}; done
            fi
            [ "$line" = "$delim" ] && break
          done
        done ;;
      '<')
        if [ "${s:i+1:1}" = '<' ] && [ "${s:i+2:1}" = '<' ]; then
          _lex_flush; printf 'SEP\n'; i=$((i+3))   # herestring: what follows is data
        elif [ "${s:i+1:1}" = '<' ]; then
          _lex_flush; i=$((i+2)); strip=0
          [ "${s:i:1}" = '-' ] && { strip=1; i=$((i+1)); }
          while [ "$i" -lt "$n" ] && case ${s:i:1} in ' '|$'\t') true ;; *) false ;; esac; do
            i=$((i+1))
          done
          delim=''
          while [ "$i" -lt "$n" ]; do
            c=${s:i:1}
            case $c in
              ' '|$'\t'|$'\n'|';'|'|'|'&'|'>'|'<') break ;;
              "'"|'"')
                i=$((i+1))
                while [ "$i" -lt "$n" ] && [ "${s:i:1}" != "$c" ]; do
                  delim="$delim${s:i:1}"; i=$((i+1))
                done
                i=$((i+1)) ;;
              '\') delim="$delim${s:i+1:1}"; i=$((i+2)) ;;
              *)   delim="$delim$c"; i=$((i+1)) ;;
            esac
          done
          hdocs="$hdocs$strip:$delim"$'\n'
        else
          _lex_flush; i=$((i+1))          # plain input redirect: reads, never writes
        fi ;;
      '>')
        _lex_flush
        i=$((i+1)); op='>'
        [ "${s:i:1}" = '>' ] && { op='>>'; i=$((i+1)); }
        # `>|` overrides noclobber and is still a redirect. Left unconsumed the
        # `|` read as a pipe, which ended the segment and took the pending target
        # with it — a write that parsed as nothing at all.
        [ "${s:i:1}" = '|' ] && i=$((i+1))
        if [ "${s:i:1}" = '&' ]; then
          # `>&2` and `2>&1` duplicate a descriptor. No path is written.
          i=$((i+1))
          while [ "$i" -lt "$n" ] && case ${s:i:1} in [0-9]|'-') true ;; *) false ;; esac; do
            i=$((i+1))
          done
        else
          printf 'OP\t%s\n' "$op"
        fi ;;
      ';'|'|'|'&')
        _lex_flush; printf 'SEP\n'; i=$((i+1)) ;;
      *)
        _LEXW="$_LEXW$c"; _LEXH=1; i=$((i+1)) ;;
    esac
  done
  _lex_flush
}

if [ -n "$CMD" ]; then
  CAND=""
  SEGW=""        # the current pipeline segment's words, one per line

  # In-place editors: the target is genuinely ambiguous to parse (BSD `sed -i ''`
  # versus GNU `sed -i`, script arguments that look like paths). Denying is the
  # honest answer, and Edit is the better tool anyway.
  #
  # Checked against words rather than raw text, so naming one in a string —
  # `git commit -m "stop using sed -i here"` — is no longer the same as running
  # one. Every word is checked for the editor name, not just the segment's verb,
  # because `find . -exec sed -i` and `xargs sed -i` are how it usually arrives.
  finish_segment() {
    local seg=$SEGW t verb='' last='' ed='' ipe=''
    SEGW=''
    [ -z "$seg" ] && return 0
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      case "${t##*/}" in
        sed|perl|ex|awk) ed=${t##*/} ;;
        patch)           ipe=patch ;;
      esac
      case "$ed" in
        sed|perl) case "$t" in -i|-i[!-]*|-[!-]*i*|--in-place*) ipe=$ed ;; esac ;;
        ex)       case "$t" in -s|-[!-]*s*) ipe=ex ;; esac ;;
        awk)      case "$t" in -i|--in-place*|inplace) ipe=awk ;; esac ;;
      esac
      if [ -z "$verb" ]; then           # strip env assignments and wrappers
        case "${t##*/}" in
          *=*|sudo|env|command|nohup|time) continue ;;
        esac
        verb=${t##*/}
        continue
      fi
      case "$verb" in
        tee|touch)              case "$t" in -*) ;; *) CAND="$CAND$t"$'\n' ;; esac ;;
        cp|mv|install|ln|rsync) case "$t" in -*) ;; *) last=$t ;; esac ;;
        dd)                     case "$t" in of=*) CAND="$CAND${t#of=}"$'\n' ;; esac ;;
      esac
    done <<< "$seg"
    # cp/mv/install/ln/rsync: the destination is the last non-flag token.
    [ -n "$last" ] && CAND="$CAND$last"$'\n'
    [ -n "$ipe" ] && deny "Phase $PHASE of spec-driven: in-place editing (sed -i, perl -i, patch, awk -i inplace) is blocked because phase-guard cannot reliably tell which file it targets. Use Edit instead — the gate can evaluate that exactly."
    return 0
  }

  WANT_TARGET=0
  while IFS=$'\t' read -r KIND VAL; do
    case "$KIND" in
      OP)   WANT_TARGET=1 ;;
      SEP)  finish_segment; WANT_TARGET=0 ;;
      WORD)
        if [ "$WANT_TARGET" = 1 ]; then
          CAND="$CAND$VAL"$'\n'
          WANT_TARGET=0
        else
          SEGW="$SEGW$VAL"$'\n'
        fi ;;
    esac
  done <<< "$(lex_command "$CMD")"
  finish_segment
  PATHS=$CAND
fi

[ -z "$PATHS" ] && exit 0

while IFS= read -r P; do
  [ -z "$P" ] && continue

  # A target the shell would compute at runtime cannot be judged here. Only
  # write targets reach this point, so denying is narrow: a read-only command
  # like `grep foo $(git ls-files)` produces no target and never gets here.
  case "$P" in
    *'$'*|*'`'*)
      deny "Phase $PHASE of spec-driven: this command writes to a target the shell computes at runtime ($P), which phase-guard cannot evaluate. Use Write or Edit for file changes during phases 1-3." ;;
  esac

  # /dev/null, /tmp scratch, ~/.config: not repo work, and never were.
  #
  # But "outside PROJECT_DIR" also describes a path in another worktree of this
  # same repo, and that is repo work — in a tree this gate cannot judge. Skipping
  # it was the second half of the split fail-open: armed in the main checkout,
  # writing production code into the worktree, allowed because the path did not
  # start with PROJECT_DIR.
  if ! in_project "$P"; then
    case "$P" in
      /*) ;;
      *)  continue ;;                   # relative: already scored as in-project
    esac
    PN=$(spec_norm_path "$P")
    PROOT=$(spec_realpath "${PROJECT_DIR%/}")
    case "$PN" in
      "$PROOT"/*) : ;;                  # the same tree once symlinks are resolved
      *)
        while IFS= read -r WTREE; do
          [ -n "$WTREE" ] || continue
          WTREE=$(spec_realpath "$WTREE")
          { [ -n "$WTREE" ] && [ "$WTREE" != "$PROOT" ]; } || continue
          case "$PN" in
            "$WTREE"/*) deny "$(spec_split_message "$PROOT" "$WTREE")" ;;
          esac
        done <<< "$(spec_worktrees "$PROJECT_DIR")"
        continue ;;
    esac
  fi
  is_phase_state "$P" && deny "The phase state is not yours to write."
  path_allowed_in_phase "$PHASE" "$P" || deny "$DENY_REASON"
done <<< "$PATHS"

exit 0
