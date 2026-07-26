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

[ -f "$STATE" ] || exit 0            # workflow not active: nothing to enforce

if [ -z "$PARSER" ]; then
  deny "phase-guard cannot read the tool call: neither jq nor python3 is on PATH. Failing closed. Install jq, or ask the user to run .claude/hooks/phase.sh off to disable the phase gate."
fi

if [ ! -r "$HOOK_DIR/phase-policy.sh" ]; then
  deny "phase-guard cannot read phase-policy.sh next to it in $HOOK_DIR. Failing closed rather than guessing at the policy."
fi
# shellcheck source=phase-policy.sh
. "$HOOK_DIR/phase-policy.sh"

# A corrupt state file used to fall through to exit 0, silently disabling the
# gate — the same fail-open bug as a missing parser. It now fails closed, with a
# reason that says how to recover.
PHASE=$(sed -n 's/^phase=//p' "$STATE" | head -1)
case "$PHASE" in
  1|2|3|4|5) ;;
  *) deny "phase-guard: .claude/.spec-phase is corrupt (phase=$PHASE). Failing closed, because a broken state file must not silently disable the gate. Ask the user to run .claude/hooks/phase.sh off in their own terminal, or to repair the file." ;;
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
    *.spec-phase*|*.spec-baseline*|*.spec-red*)
      deny "The phase state is not yours to edit, move or remove — .spec-red included, because a receipt you could write by hand would assert RED without running anything. Change phases with .claude/hooks/phase.sh <n>, verify RED with .claude/hooks/phase.sh red, and read the current phase with .claude/hooks/phase.sh status." ;;
  esac
fi
if [ -n "$PATHS" ] && is_phase_state "$PATHS"; then
  deny "The phase state is not yours to edit. Only the user changes phases, by running .claude/hooks/phase.sh <n> in their own terminal."
fi

# --- Who may advance a phase -------------------------------------------------
# Each phase widens what may be written, so the user is required exactly where
# write access expands, and nowhere else. Everything the model may do either
# restricts it or increases scrutiny.
#
# A PreToolUse hook cannot tell a Bash call the model chose to make from one a
# user's slash command told it to make — both arrive identically. So "the user
# decides" cannot be expressed as an allow; it has to be an `ask`, or a denial
# pointing at a terminal. The two approval gates use `ask`. Everything that would
# route around them — forward skips, moves off Phase 5, `off` from 1-3 — is
# denied here and needs a terminal, since a prompt for those would just be the
# gate asking permission to skip itself.
if [ -n "$CMD" ] && printf '%s' "$CMD" | grep -qE '(^|[^[:alnum:]_.+-])phase\.sh([[:space:]]|$)'; then
  ARG=$(printf '%s' "$CMD" | sed -nE 's|.*phase\.sh[[:space:]]+([^[:space:];&|]+).*|\1|p' | head -1)
  ARG=${ARG#[\"\']}; ARG=${ARG%[\"\']}

  advance_deny() {
    deny "Only the user advances phases. Ask them to run:  .claude/hooks/phase.sh $1  — in their own terminal, not through Claude. A PreToolUse hook cannot distinguish your Bash call from one a slash command made, so this checkpoint has to live outside the tool layer. Current phase: $PHASE."
  }

  # --force is the user's override for a refused RED check, and it exists
  # precisely because the check is the thing standing between the model and
  # production writes. Denied in every phase, before ARG is even considered.
  case "$CMD" in
    *--force*)
      deny "--force is the user's override, not yours. It advances past the RED check on their assertion alone. If the check is refusing, fix the tests: run .claude/hooks/phase.sh red and read what it says." ;;
  esac

  case "$ARG" in
    status|"") ;;                       # read-only, always fine
    red) ;;                             # verification, not advancement — see below
    start)
      deny "The phase gate is already armed at phase $PHASE. Re-arming resets to Phase 1 and is the user's call: .claude/hooks/phase.sh start <task> in their own terminal." ;;
    off)
      # `off` from phases 1-3 grants production writes: same as jumping to 4.
      [ "$PHASE" -le 3 ] && advance_deny off
      # From 4 or 5 it expands nothing, which is why this used to be the model's
      # to take freely. That was wrong for a reason that has nothing to do with
      # write access: `off` ends the task, and the end of a task is the one
      # moment the user decides what happens to the work — ship it, keep
      # iterating, throw it away. A model that disarms on its own has skipped
      # that conversation and presented the outcome as settled.
      ask "End the spec-driven workflow for this task? This is the close-out decision: the phase gate stops, and whatever is in the working tree is what you are left with. If the work should become a pull request, say so instead of accepting — that happens before disarming, not after. Note that turning the gate off makes the review gate fire on EVERY turn while the tree is dirty, so decline this if the diff is not committed yet." ;;
    "$PHASE") ;;                        # no-op
    1|2|3|4|5)
      if [ "$PHASE" = 5 ]; then
        # Phases 1-4 suppress the Stop gate, so any move off 5 escapes the
        # review that is currently owed. Only `off` is safe, handled above.
        advance_deny "$ARG"
      elif [ "$ARG" -lt "$PHASE" ]; then
        :                               # retreat: strictly more restrictive
      elif [ "$PHASE" = 1 ] && [ "$ARG" = 2 ]; then
        :                               # writing a spec is harmless; 2->3 is the gate
      elif [ "$PHASE" = 4 ] && [ "$ARG" = 5 ]; then
        :                               # self-submits to review
      elif [ "$PHASE" = 2 ] && [ "$ARG" = 3 ]; then
        # Spec approval, in band. The user is reading the spec in the
        # conversation anyway, so one confirmation is proportionate.
        ask "Approve the spec and advance to Phase 3 (Plan + failing tests)? Approving asserts that you have read docs/specs/ and accept the approach, the types, and the out-of-scope list. Phase 3 writes tests only; production code stays blocked until Phase 4."
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
        case "$(red_receipt_status)" in
          valid)
            ask "Advance to Phase 4 (Execute) and unlock production code? RED is mechanically verified: the tests this phase added were run and failed, and none of them has changed since. What that does NOT prove is that they failed for the reason the spec expects — that is the part you are approving. Read the failure output above before accepting." ;;
          stale)
            deny "The RED verification is stale: the test files have changed since they were checked. Run .claude/hooks/phase.sh red again, show the output, and then ask to advance. Current phase: $PHASE." ;;
          *)
            deny "RED has not been verified yet, so Phase 4 stays locked. Run .claude/hooks/phase.sh red — it runs the tests this phase changed and refuses if they pass. Show the failure output, say why each failure is the expected one, then advance. If this repo has no test command configured (.claude/spec-gate-test-cmd), the check cannot run and the user must advance from their own terminal: .claude/hooks/phase.sh 4" ;;
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
unquote() {
  v=$1
  v=${v#[\"\']}; v=${v%[\"\']}
  printf '%s' "$v"
}

if [ -n "$CMD" ]; then
  # In-place editors: the target is genuinely ambiguous to parse (BSD `sed -i ''`
  # versus GNU `sed -i`, script arguments that look like paths). Denying is the
  # honest answer, and Edit is the better tool anyway.
  if printf '%s' "$CMD" | grep -qE '(^|[[:space:];|&])(sed[^;|&]*[[:space:]]-i|perl[[:space:]]+-[[:alnum:]]*i|patch([[:space:]]|$)|ex[[:space:]]+-s|awk[^;|&]*-i[[:space:]]*inplace)'; then
    deny "Phase $PHASE of spec-driven: in-place editing (sed -i, perl -i, patch, awk -i inplace) is blocked because phase-guard cannot reliably tell which file it targets. Use Edit instead — the gate can evaluate that exactly."
  fi

  CAND=""
  # Redirections, anywhere in the command. `2>&1` and `>&2` are excluded by the
  # character class, since their target starts with &.
  RED=$(printf '%s' "$CMD" | grep -oE '>>?[[:space:]]*[^[:space:]|&;<>()]+' | sed -E 's/^>>?[[:space:]]*//')
  [ -n "$RED" ] && CAND="$RED"$'\n'

  # Verb-specific targets, per pipeline segment.
  set -f
  SEGS=$(printf '%s' "$CMD" | sed -E 's/\|\||&&|[;|&]/\n/g')
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    # shellcheck disable=SC2086
    set -- $seg
    while [ $# -gt 0 ]; do              # strip env assignments and wrappers
      case "${1##*/}" in
        *=*|sudo|env|command|nohup|time) shift ;;
        *) break ;;
      esac
    done
    [ $# -eq 0 ] && continue
    verb=${1##*/}
    shift
    case "$verb" in
      tee|touch)
        for t in "$@"; do
          case "$t" in -*) continue ;; esac
          CAND="$CAND$(unquote "$t")"$'\n'
        done ;;
      cp|mv|install|ln|rsync)           # destination is the last non-flag token
        last=""
        for t in "$@"; do
          case "$t" in -*) continue ;; esac
          last=$t
        done
        [ -n "$last" ] && CAND="$CAND$(unquote "$last")"$'\n' ;;
      dd)
        for t in "$@"; do
          case "$t" in of=*) CAND="$CAND$(unquote "${t#of=}")"$'\n' ;; esac
        done ;;
    esac
  done <<< "$SEGS"
  set +f
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

  in_project "$P" || continue           # /dev/null, /tmp scratch: not repo work
  is_phase_state "$P" && deny "The phase state is not yours to write."
  path_allowed_in_phase "$PHASE" "$P" || deny "$DENY_REASON"
done <<< "$PATHS"

exit 0
