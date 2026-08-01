#!/usr/bin/env bash
# approval-receipt.sh — PostToolUse hook on AskUserQuestion.
#
# Turns an answer the user gave into a receipt a gate can read. The model asks
# the gate's question with AskUserQuestion; this hook sees both the question it
# asked and the answer that came back, and writes .spec-approval if the two line
# up with a gate. phase-guard.sh then lets the transition through instead of
# raising a second prompt for a decision that was just made.
#
# What makes this a gate rather than decoration:
#
#   - The answer comes from the host, not from the model. It cannot be authored.
#   - The question is matched VERBATIM against phase-policy.sh, so the model
#     cannot ask an easier question and redeem the answer.
#   - .spec-approval is phase state, denied to the model by every write vector.
#
# What it does NOT establish: that the paragraph the model wrote above the
# question was honest, or that the user read anything. Those stay where they
# were — instructed, not enforced.
#
# EVERY failure path here writes nothing and exits 0. That is the whole
# reliability argument. AskUserQuestion's tool_response shape is not a documented
# contract, so this hook is built to notice when it stops recognising one: no
# receipt means phase-guard.sh falls back to the confirmation prompt it raised
# before any of this existed. A payload change costs a keystroke, never a block.
#
# Install: .claude/hooks/approval-receipt.sh  (chmod +x)

set -uo pipefail

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PARSER=""
command -v jq      >/dev/null 2>&1 && PARSER=jq
[ -z "$PARSER" ] && command -v python3 >/dev/null 2>&1 && PARSER=python3
[ -n "$PARSER" ] || exit 0

json_get() {  # scalar, dotted path
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
print(d)
' "$1" 2>/dev/null ;;
  esac
}

# Every question in the call, one per line. Plural because the model may bundle
# the gate's question with others in a single AskUserQuestion, and the gate's
# would not necessarily be first.
questions() {
  case "$PARSER" in
    jq) printf '%s' "$INPUT" | jq -r '[.tool_input.questions[]?.question // empty] | .[]' 2>/dev/null ;;
    python3) printf '%s' "$INPUT" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
qs = (d.get("tool_input") or {}).get("questions") or []
if isinstance(qs, list):
    for q in qs:
        t = q.get("question") if isinstance(q, dict) else None
        if isinstance(t, str): print(t)
' 2>/dev/null ;;
  esac
}

# The whole tool_response, re-serialised as one string.
#
# Deliberately not addressed field by field. The shape of an AskUserQuestion
# result is not documented and is free to change; the option labels are strings
# this project chose, and they are distinctive. Searching the serialised response
# for exactly one of them survives a reshuffle that any field path would break
# on, and it degrades the right way — an unrecognised shape matches nothing,
# writes nothing, and the prompt comes back.
response_text() {
  case "$PARSER" in
    jq) printf '%s' "$INPUT" | jq -c '.tool_response // empty' 2>/dev/null ;;
    python3) printf '%s' "$INPUT" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
r = d.get("tool_response")
if r is not None: print(json.dumps(r))
' 2>/dev/null ;;
  esac
}

[ "$(json_get tool_name)" = "AskUserQuestion" ] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(json_get cwd)}"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"
STATE="$PROJECT_DIR/.claude/.spec-phase"
[ -f "$STATE" ] || exit 0            # workflow not active: nothing to record

[ -r "$HOOK_DIR/phase-policy.sh" ] || exit 0
# shellcheck source=phase-policy.sh
. "$HOOK_DIR/phase-policy.sh"

QS=$(questions)
[ -n "$QS" ] || exit 0

# Which gate was asked. Verbatim match: a question that merely resembles the
# canonical one is not the canonical one, and treating it as such is exactly the
# hole this check exists to close.
GATE=""
for g in spec red close-out; do
  q=$(gate_question "$g")
  [ -n "$q" ] || continue
  case $'\n'"$QS"$'\n' in
    *$'\n'"$q"$'\n'*) GATE="$g"; break ;;
  esac
done
[ -n "$GATE" ] || exit 0

RESP=$(response_text)
[ -n "$RESP" ] || exit 0

# Exactly one label, or nothing. Zero means the user took the free-text "Other"
# option that AskUserQuestion always offers, or declined to answer — neither is a
# choice this can record. More than one means the response echoed the options
# back rather than reporting a selection, which is indistinguishable from an
# answer and must not be guessed at.
VERDICT=""
HITS=0
while IFS=$'\t' read -r v l _d; do
  [ -n "$l" ] || continue
  case "$RESP" in
    *"$l"*) HITS=$((HITS + 1)); VERDICT="$v" ;;
  esac
done <<< "$(gate_options "$GATE")"
[ "$HITS" = 1 ] || exit 0
[ -n "$VERDICT" ] || exit 0

# Written whole or not at all: a half-written receipt read by the guard between
# two of these printfs would be a receipt with no subject, which reads as stale
# rather than as approval — but relying on that is relying on luck.
TMP="$PROJECT_DIR/.claude/.spec-approval.tmp.$$"
{
  printf '# spec-gate approval receipt — written by approval-receipt.sh from the\n'
  printf '# host answer to AskUserQuestion. Never by hand, and never by the model.\n'
  printf 'gate=%s\nverdict=%s\n' "$GATE" "$VERDICT"
  printf 'phase=%s\n' "$(sed -n 's/^phase=//p' "$STATE" | head -1)"
  printf 'task=%s\n'  "$(sed -n 's/^task=//p'  "$STATE" | head -1)"
  printf 'slice=%s\n' "$(sed -n 's/^slice=//p' "$STATE" | head -1)"
  printf 'subject:\n'
  (cd "$PROJECT_DIR" 2>/dev/null && gate_subject "$GATE")
} > "$TMP" 2>/dev/null && mv -f "$TMP" "$(approval_path)" 2>/dev/null
rm -f "$TMP" 2>/dev/null

exit 0
