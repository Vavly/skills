#!/usr/bin/env bash
# cursor-guard.sh — Cursor adapter for the phase guard.
#
# Cursor has its own hook system (1.7+) with its own payload and response
# shapes. Reimplementing the policy here would give two copies that drift, which
# is the failure this project keeps circling back to. So this translates
# Cursor's payload into the Claude Code shape, runs phase-guard.sh, and
# translates the answer back. The decision lives in exactly one place.
#
# Registered on two events, because they differ in what they may return:
#   beforeShellExecution — allow/deny/ask.   Handles shell commands.
#   preToolUse           — allow/deny only.  Handles file writes.
# A shell command arriving via preToolUse is passed through untouched, so the
# 2->3 `ask` is never silently downgraded to a deny by being seen on the event
# that cannot express it.
#
# Tools are matched on the *shape* of tool_input rather than on tool_name,
# because Cursor's tool names are not something this has been tested against and
# a name that failed to match would fail open.
#
# The python programs are passed with -c, never as `python3 - <<HEREDOC`: a
# heredoc claims stdin, so the payload being piped in would never arrive and
# every decision would fall through to "allow". That bug shipped once here.
#
# Needs python3: building a JSON string containing a multi-line reason needs a
# real encoder. With failClosed:true in hooks.json, a missing python3 blocks
# rather than waving calls through.
#
# Install: .claude/hooks/cursor-guard.sh, referenced from .cursor/hooks.json

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INPUT=$(cat)

if ! command -v python3 >/dev/null 2>&1; then
  echo "cursor-guard: python3 not on PATH; cannot translate the hook payload." >&2
  exit 1
fi

allow() { printf '{"permission":"allow"}\n'; exit 0; }

READ_EVENT='
import json, sys
try: print(json.load(sys.stdin).get("hook_event_name") or "")
except Exception: print("")
'

# Cursor payload -> Claude Code payload, or SKIP when there is nothing to judge.
TO_CLAUDE='
import json, sys
event = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print("SKIP"); sys.exit(0)

# workspace_roots[0] is the project root; cwd may be a subdirectory, and the
# guard needs the root to find .claude/.spec-phase.
roots = d.get("workspace_roots") or []
root = roots[0] if isinstance(roots, list) and roots else (d.get("cwd") or "")

if event == "beforeShellExecution":
    print(json.dumps({"tool_name": "Bash",
                      "tool_input": {"command": d.get("command") or ""},
                      "cwd": root}))
    sys.exit(0)

ti = d.get("tool_input")
if not isinstance(ti, dict):
    print("SKIP"); sys.exit(0)

if ti.get("command"):          # a shell call: beforeShellExecution owns it
    print("SKIP"); sys.exit(0)

# preToolUse fires for every tool, reads included, and a read carries a path just
# like a write does. Keying on "has a path" would deny reading production code
# during Phase 3 and make the host unusable. So a write needs positive evidence:
# content in the input, or a tool name that says so.
#
# When the evidence is absent this allows the call — deliberately. Per-call
# interception has always been best-effort here; the per-turn scan in
# review-gate.sh is what makes the guarantee, and it sees writes by any means.
import re
name = d.get("tool_name") or ""
CONTENT = ("content", "contents", "new_string", "new_str", "text", "code",
           "patch", "diff", "edits", "replacement", "instructions")
WRITE = r"(write|edit|create|apply|patch|append|insert|replace|delete|remove|move|rename|mkdir|touch)"
READ = r"(read|view|open|grep|search|glob|list|find|cat|fetch|lint|test)"

has_content = any(k in ti for k in CONTENT)
named_write = bool(re.search(WRITE, name, re.I)) and not re.search(READ, name, re.I)
if not (has_content or named_write):
    print("SKIP"); sys.exit(0)

for key in ("file_path", "path", "target_file", "filePath", "absolute_path", "file"):
    value = ti.get(key)
    if isinstance(value, str) and value:
        print(json.dumps({"tool_name": "Write",
                          "tool_input": {"file_path": value},
                          "cwd": root}))
        sys.exit(0)

print("SKIP")
'

# Claude Code decision -> Cursor response.
TO_CURSOR='
import json, sys
event = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    # An unparseable decision must not become a silent allow: that is exactly
    # how the Claude Code side used to drop denials.
    print(json.dumps({"permission": "deny",
                      "user_message": "spec-gate: unreadable decision from phase-guard; blocking.",
                      "agent_message": "spec-gate could not be evaluated. Ask the user to check the hook."}))
    sys.exit(0)

out = d.get("hookSpecificOutput") or {}
decision = (out.get("permissionDecision") or "allow").lower()
reason = out.get("permissionDecisionReason") or ""

# preToolUse has no ask. Downgrading to deny keeps the gate closed rather than
# letting the decision evaporate on an event that cannot express it.
if decision == "ask" and event != "beforeShellExecution":
    decision = "deny"

response = {"permission": decision}
if reason and decision != "allow":
    response["agent_message"] = reason
    response["user_message"] = reason
print(json.dumps(response))
'

EVENT=$(printf '%s' "$INPUT" | python3 -c "$READ_EVENT" 2>/dev/null)

PAYLOAD=$(printf '%s' "$INPUT" | python3 -c "$TO_CLAUDE" "$EVENT" 2>/dev/null)
[ -z "$PAYLOAD" ] && allow
[ "$PAYLOAD" = "SKIP" ] && allow

DECISION=$(printf '%s' "$PAYLOAD" | "$HOOK_DIR/phase-guard.sh" 2>/dev/null)
[ -z "$DECISION" ] && allow          # no output = nothing to enforce

printf '%s' "$DECISION" | python3 -c "$TO_CURSOR" "$EVENT"
