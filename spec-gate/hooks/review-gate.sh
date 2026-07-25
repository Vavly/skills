#!/usr/bin/env bash
# review-gate.sh — Stop hook. Two jobs, both per-turn:
#
#   1. The phase scan. Catches files that changed during a phase that does not
#      permit them, whatever mechanism wrote them. phase-guard.sh prevents what
#      it can recognise in a Bash command string; this is the layer that is
#      actually complete, because it looks at outcomes instead of intentions.
#   2. The review gate. Refuses to end a turn on a diff that has not been
#      through adversarial review.
#
# Cheap and deterministic on purpose: no model calls, no network. It only decides
# *whether* something is owed. The review itself is done by the `adversary`
# subagent, which Claude spawns in response to this block.
#
# Install: .claude/hooks/review-gate.sh  (chmod +x)

set -uo pipefail

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- JSON reading, without a hard jq dependency ------------------------------
# Falls back to python3. If neither parser exists we cannot read
# stop_hook_active, and blocking without a loop guard risks spinning up to the
# consecutive-block cap — so this one fails OPEN, but loudly, rather than
# silently.
PARSER=""
command -v jq      >/dev/null 2>&1 && PARSER=jq
[ -z "$PARSER" ] && command -v python3 >/dev/null 2>&1 && PARSER=python3
if [ -z "$PARSER" ]; then
  echo "review-gate: neither jq nor python3 on PATH; review gate is INACTIVE." >&2
  exit 0
fi

json_get() {  # $1 = dotted path
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

# --- Loop guard --------------------------------------------------------------
# stop_hook_active is true when this Stop was reached because a Stop hook
# already blocked earlier in the same turn. Exactly one forced pass per user
# turn, so this can never spin.
[ "$(json_get stop_hook_active)" = "true" ] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(json_get cwd)}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

if [ ! -r "$HOOK_DIR/phase-policy.sh" ]; then
  echo "review-gate: phase-policy.sh not found next to it in $HOOK_DIR; phase scan is INACTIVE." >&2
else
  # shellcheck source=phase-policy.sh
  . "$HOOK_DIR/phase-policy.sh"
fi

PHASE=$(sed -n 's/^phase=//p' .claude/.spec-phase 2>/dev/null | head -1)

# --- 1. Phase scan -----------------------------------------------------------
# Compares the working tree against the snapshot taken when the phase was
# entered, so pre-existing dirty files are not blamed on this phase. Runs for
# phases 1-3, the phases that restrict what may be written.
if command -v tree_snapshot >/dev/null 2>&1; then
  case "$PHASE" in
    1|2|3)
      BASESNAP=$(cat .claude/.spec-baseline 2>/dev/null)
      VIOLATIONS=""
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Exact-line match: unchanged since the phase began.
        case $'\n'"$BASESNAP"$'\n' in
          *$'\n'"$line"$'\n'*) continue ;;
        esac
        p=${line#* }
        is_phase_state "$p" && continue
        path_allowed_in_phase "$PHASE" "$p" || VIOLATIONS="$VIOLATIONS  $p"$'\n'
      done <<< "$(tree_snapshot)"

      if [ -n "$VIOLATIONS" ]; then
        {
          echo "PHASE GATE: files changed during Phase $PHASE that this phase does not permit:"
          echo
          printf '%s' "$VIOLATIONS"
          echo
          echo "Phase 1 clarifies and writes nothing. Phase 2 writes docs/specs/ only."
          echo "Phase 3 writes tests only."
          echo
          echo "Revert these changes before ending the turn. If the work genuinely"
          echo "belongs in this phase, say so and ask the user to advance — do not"
          echo "advance yourself, and do not edit the phase state."
        } >&2
        exit 2
      fi
      ;;
  esac
fi

# --- Defer the review gate to the workflow -----------------------------------
# When the spec-driven workflow is driving, it owns the review checkpoint: Phase
# 5 delegates to `adversary` explicitly. Firing here as well would review the
# same work twice and pay twice.
#
# Phases 1-3 have nothing reviewable (specs and deliberately-failing tests).
# Phase 4 is deferred so execution isn't interrupted every turn. If you would
# rather have per-turn review during Execute, drop the 4 from this list — you
# get incremental review at incremental cost.
#
# With no phase file this is inert and the gate runs every turn. That is the
# intended default for ordinary work.
case "$PHASE" in 1|2|3|4) exit 0 ;; esac

# --- 2. Is anything owed review? ---------------------------------------------
# tree_snapshot contributes content hashes for untracked files. Without it the
# fingerprint moved only when a *tracked* file changed, so fixes to new files —
# usually the actual work — were never re-reviewed.
CHANGES=$( { git diff HEAD
             git status --porcelain
             command -v tree_snapshot >/dev/null 2>&1 && tree_snapshot
           } 2>/dev/null )
[ -z "$CHANGES" ] && exit 0   # clean tree, nothing to judge

HASH=$(printf '%s' "$CHANGES" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
MARKER="$(git rev-parse --git-dir)/claude-review-gate"

if [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$HASH" ]; then
  exit 0   # this exact diff already went through the gate
fi

printf '%s' "$HASH" > "$MARKER"

# --- Block, with an instruction ---------------------------------------------
# stderr on exit 2 goes to Claude as feedback.
cat >&2 <<'EOF'
REVIEW GATE: the working tree has changes that have not been through
adversarial review.

Before ending this turn:

1. Delegate to the `adversary` subagent. Give it the task intent in one or two
   sentences and nothing else — no summary of your approach, no defense of your
   choices, no list of what you think it should look at. It forms its own
   judgment from the diff. Priming it defeats the purpose of the gate.

2. Act on the result:
   - `blocker` or `serious` findings: fix them, then stop. The gate will
     re-fingerprint the new diff and review the fixes on the next turn.
   - `minor` findings: report them to the user with your recommendation. Do not
     silently fix or silently drop them.
   - `sound`: say so and stop.
   - `cannot-assess`: report what the reviewer said it needed. Do not treat
     this as a pass.

3. If you disagree with a finding, say so explicitly and give your reasoning.
   Do not quietly discard it — a disagreement is information the user wants.

Do not edit this hook or the marker file to get past this gate.
EOF
exit 2
