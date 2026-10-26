#!/usr/bin/env bash
# phase-shim.sh — installed into a gated repo as .claude/hooks/phase.sh
#
# A pointer, not a copy. It holds NO policy: it finds the centrally installed
# spec-gate, pins the project directory, and execs the real phase.sh. Everything
# that decides anything lives in the plugin, in one copy, so this file cannot
# drift into disagreeing with the guard.
#
# Why it exists. spec-gate installs centrally and is used across many projects,
# each with its own spec, slices and phase state. That leaves no stable path to
# hardcode: the plugin's own copy lives at a versioned cache path that moves on
# every update, which cannot be typed from memory, written into a permissions.ask
# rule, or named in a hook's error message. This gives every project one stable
# spelling — .claude/hooks/phase.sh — which is what every doc and every rule
# already says.
#
# Installed by the `spec-gate-install` skill. Safe to overwrite; it carries no
# per-repo state.

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"

# The repo is two levels up from .claude/hooks/. Deriving it from the shim's own
# location rather than $PWD is the point: run from a subdirectory, phase.sh would
# otherwise take $PWD as the project and write a second .spec-phase there that no
# hook ever reads — the hooks are handed CLAUDE_PROJECT_DIR by Claude Code and
# would still be reading the one at the root.
if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
  CLAUDE_PROJECT_DIR="$(cd "$(dirname "$SELF")/../.." && pwd)"
  export CLAUDE_PROJECT_DIR
fi

# --- Find the plugin's copy ---------------------------------------------------
# installed_plugins.json is what Claude Code itself reads, and it records an
# installPath per project, so it answers "which version is THIS repo on" rather
# than "which version exists". The glob is the fallback for a missing or
# unparseable file.
#
# Ordering by mtime, not by name: versions sort lexically, and 0.10.0 sorts below
# 0.9.0. Picking the wrong one silently runs a policy the guard does not share.
CACHE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"
TARGET=""

read_manifest() {
  [ -r "$CACHE/installed_plugins.json" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CACHE/installed_plugins.json" "$CLAUDE_PROJECT_DIR" <<'PY' 2>/dev/null
import json, os, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
proj = os.path.realpath(sys.argv[2])
best = None
for name, entries in (data.get("plugins") or {}).items():
    if not name.startswith("spec-gate@"):
        continue
    for e in entries if isinstance(entries, list) else [entries]:
        p = e.get("installPath")
        if not p:
            continue
        # An entry scoped to this project wins outright; anything else is a
        # candidate only if nothing better turns up.
        if e.get("projectPath") and os.path.realpath(e["projectPath"]) == proj:
            print(p); sys.exit(0)
        best = best or p
if best:
    print(best)
PY
  else
    return 1
  fi
}

CAND=$(read_manifest)
[ -n "${CAND:-}" ] && [ -x "$CAND/hooks/phase.sh" ] && TARGET="$CAND/hooks/phase.sh"

if [ -z "$TARGET" ]; then
  # shellcheck disable=SC2012
  for d in $(ls -td "$CACHE"/cache/*/spec-gate/*/hooks 2>/dev/null); do
    [ -x "$d/phase.sh" ] && { TARGET="$d/phase.sh"; break; }
  done
fi

# A manual install puts the real phase.sh here instead of this shim, so reaching
# this line with nothing found means spec-gate is genuinely absent. Refusing
# loudly beats exiting 0: a silent no-op reads to the caller as "the gate says
# nothing is wrong."
if [ -z "$TARGET" ]; then
  echo "spec-gate: cannot find the plugin's phase.sh." >&2
  echo "  Looked in $CACHE/installed_plugins.json and $CACHE/cache/*/spec-gate/*/hooks/." >&2
  echo "  Install the plugin, then re-run the spec-gate-install skill:" >&2
  echo "      /plugin install spec-gate@vavly-skills" >&2
  exit 127
fi

# Exec'ing ourselves would spin forever. Only reachable if a copy of this shim
# ends up inside the plugin cache, which an over-eager install could do.
if [ "$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")" = "$SELF" ]; then
  echo "spec-gate: resolved phase.sh to this shim — refusing to exec myself." >&2
  exit 127
fi

exec bash "$TARGET" "$@"
