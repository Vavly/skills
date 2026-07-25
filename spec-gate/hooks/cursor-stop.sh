#!/usr/bin/env bash
# cursor-stop.sh — Cursor adapter for the Stop-hook work.
#
# Cursor's `stop` hook cannot block: it returns {"followup_message": "..."} to
# submit the next user message automatically. That is a better fit for this than
# Claude Code's exit 2, which can only refuse to end the turn and then hope the
# agent reads stderr. Here the instruction *becomes* the next turn.
#
# The phase scan and the review gate both live in review-gate.sh; this runs it
# and forwards whatever it would have said.
#
# Cursor's loop_count maps onto our stop_hook_active loop guard: once a follow-up
# has been injected, do not demand again in the same chain. Cursor also caps
# follow-ups with loop_limit (default 5) as a second backstop.
#
# Install: .claude/hooks/cursor-stop.sh, referenced from .cursor/hooks.json

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT=$(cat)

quiet() { printf '{}\n'; exit 0; }

command -v python3 >/dev/null 2>&1 || quiet

read -r LOOP ROOT STATUS <<<"$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: d = {}
roots = d.get("workspace_roots") or []
root = roots[0] if isinstance(roots, list) and roots else (d.get("cwd") or ".")
print(d.get("loop_count") or 0, root, d.get("status") or "completed")' 2>/dev/null)"

[ -z "${ROOT:-}" ] && quiet
case "${STATUS:-}" in aborted|error) quiet ;; esac   # nothing to judge
[ "${LOOP:-0}" -gt 0 ] 2>/dev/null && quiet          # already asked this chain

# review-gate.sh reports through stderr and exit 2, the Claude Code contract.
MESSAGE=$(printf '{"stop_hook_active":false}' \
  | CLAUDE_PROJECT_DIR="$ROOT" "$HOOK_DIR/review-gate.sh" 2>&1 >/dev/null)
RC=$?

[ "$RC" -eq 2 ] || quiet
[ -n "$MESSAGE" ] || quiet

printf '%s' "$MESSAGE" | python3 -c '
import json, sys
print(json.dumps({"followup_message": sys.stdin.read()}))'
