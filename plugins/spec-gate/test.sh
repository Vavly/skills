#!/usr/bin/env bash
# test.sh — regression suite for spec-gate.
#
# Builds a throwaway git repo in a temp dir, installs the hooks into it, and
# drives them with synthetic hook payloads. Nothing here touches the repo you
# run it from.
#
# Every case marked [#n] pins a bug found in the 2026-07-25 review; those are the
# ones that must never silently come back.
#
# Needs: git, bash, python3 (to build payloads), and jq or python3 for the hooks.
#
# Usage: ./test.sh

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t specgate)
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'; else G=""; R=""; B=""; N=""; fi

ok()  { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"; }
group(){ printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# --- fixture ------------------------------------------------------------------
setup_repo() {
  rm -rf "$WORK/repo"; mkdir -p "$WORK/repo"
  cd "$WORK/repo" || exit 1
  git init -q .
  git config user.email t@example.com; git config user.name test
  mkdir -p .claude docs/specs src tests
  cp -R "$SRC"/hooks "$SRC"/agents "$SRC"/skills .claude/
  cp "$SRC"/settings.json .claude/settings.json
  echo 'orig' > src/x.ts
  echo 'orig' > src/x.test.ts
  echo 'orig' > tests/helper.ts
  # Must stay identical to the install block in README.md. An untracked state
  # file is work the review gate considers owed, so a name missing here is a gate
  # that arms itself every time it writes its own bookkeeping.
  printf '.claude/.spec-phase\n.claude/.spec-baseline\n.claude/.spec-red\n.claude/.spec-approval*\n.claude/review-log.jsonl\n' > .gitignore
  git add -A >/dev/null 2>&1; git commit -qm init
  export CLAUDE_PROJECT_DIR="$PWD"
  rm -f .git/claude-review-gate
}

phase() { .claude/hooks/phase.sh "$@" >/dev/null 2>&1; }

# Build payloads with python3 so command strings with quotes survive intact.
pl_write() { python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[2],"tool_input":{"file_path":sys.argv[1]}}))' "$1" "${2:-Write}"; }
pl_bash()  { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }

# ALLOW | DENY | ASK | BADJSON — BADJSON matters: malformed output on exit 0 is
# treated by Claude Code as "no decision", so the call proceeds. A deny that
# cannot be parsed is a deny that did not happen.
guard() {
  local out dec
  out=$(printf '%s' "$1" | .claude/hooks/phase-guard.sh 2>/dev/null)
  if [ -z "$out" ]; then echo ALLOW; return; fi
  dec=$(printf '%s' "$out" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: print("BADJSON"); sys.exit(0)
print(d.get("hookSpecificOutput", {}).get("permissionDecision", "NONE").upper())
' 2>/dev/null)
  echo "${dec:-BADJSON}"
}

# The reason string is the confirmation question the user reads, so an ask with
# an empty reason would be a prompt with no context.
guard_reason() {
  printf '%s' "$1" | .claude/hooks/phase-guard.sh 2>/dev/null | python3 -c '
import json, sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])
except Exception: print("")
' 2>/dev/null
}

expect() { # <label> <expected> <payload>
  local got; got=$(guard "$3")
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1 — expected $2, got $got"; fi
}
expect_w() { expect "$1" "$2" "$(pl_write "$3" "${4:-Write}")"; }
expect_b() { expect "$1" "$2" "$(pl_bash "$3")"; }

gate() { # <stop_hook_active> -> exit code
  printf '{"stop_hook_active":%s}' "${1:-false}" | .claude/hooks/review-gate.sh >/dev/null 2>&1
  echo $?
}
expect_gate() { # <label> <expected-exit> [stop_hook_active]
  local got; got=$(gate "${3:-false}")
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1 — expected exit $2, got $got"; fi
}

################################################################################
setup_repo

group "Dormant (no phase file) — the gate must cost nothing"
phase off
expect_w "production write allowed when inactive" ALLOW src/x.ts
expect_b "arbitrary shell allowed when inactive"  ALLOW 'echo hi > src/y.ts'

group "Phase 1 — Clarify: nothing may be written"
phase start verify
expect_w "production write denied"        DENY  src/x.ts
expect_w "spec document allowed"          ALLOW docs/specs/a.md
expect_w "NotebookEdit is covered [#5]"   DENY  src/nb.ipynb NotebookEdit
expect_w "Edit is covered"                DENY  src/x.ts Edit
expect_b "read-only command allowed"      ALLOW 'cat src/x.ts'
expect_b "redirect to /dev/null [#10]"    ALLOW 'pytest -q > /dev/null 2>&1'
expect_b "git status to /dev/null [#10]"  ALLOW 'git status >/dev/null'
expect_b "read-only subshell allowed"     ALLOW 'grep -rn foo $(git ls-files)'
expect_b "stderr redirect allowed"        ALLOW 'make build 2>&1 | tail -5'

group "Phase 3 — tests only: every write vector"
phase 3
expect_w "test file allowed"                   ALLOW src/x.test.ts
expect_w "tests/ dir allowed"                  ALLOW tests/new.ts
expect_w "production write denied"             DENY  src/x.ts
expect_b "redirect to production denied"       DENY  'echo hi > src/y.ts'
expect_b "append to production denied"         DENY  'echo hi >> src/y.ts'
expect_b "cp to production denied [#4]"        DENY  'cp /tmp/e src/x.ts'
expect_b "mv to production denied [#4]"        DENY  'mv /tmp/e src/x.ts'
expect_b "tee to production denied [#3]"       DENY  'cat /tmp/e | tee src/x.ts'
expect_b "dd of= denied [#3]"                  DENY  'dd if=/tmp/e of=src/x.ts'
expect_b "sed -i denied [#3]"                  DENY  "sed -i '' s/a/b/ src/x.ts"
expect_b "touch production denied"             DENY  'touch src/brand-new.ts'
expect_b "runtime-computed target denied"      DENY  'echo x > $(mktemp)'
expect_b "cp to a test path allowed"           ALLOW 'cp /tmp/e tests/ok.test.ts'
expect_b "read-only command still allowed"     ALLOW 'cat src/x.ts && ls -la'
expect_b "quoted path with space denied [#6]"  DENY  'echo x > "src/a b.ts"'
# A shell repo keeps its whole suite in one script. Scoring that as production
# locked Phase 3 out of editing the only tests such a repo has.
expect_w "test.sh is a test file"              ALLOW test.sh
expect_w "nested test.sh is a test file"       ALLOW spec-gate/test.sh
expect_w "run-tests.sh is a test file"         ALLOW run-tests.sh
expect_w "deploy-test.sh stays production"     DENY  scripts/deploy-test.sh

group "Phase state is never the model's [#8]"
expect_b "redirect into phase file denied"     DENY  'echo phase=5 > .claude/.spec-phase'
expect_b "rm of phase file denied"             DENY  'rm .claude/.spec-phase'
expect_b "mv of phase file denied"             DENY  'mv /tmp/x .claude/.spec-phase'
expect_b "baseline file denied"                DENY  'rm .claude/.spec-baseline'
expect_b "forging the RED receipt denied"      DENY  'printf x > .claude/.spec-red'
expect_w "Write to the RED receipt denied"     DENY  .claude/.spec-red
expect_w "Write to phase file denied"          DENY  .claude/.spec-phase
phase 5
expect_b "phase 5 cannot rewrite state [#8]"   DENY  'echo phase=4 > .claude/.spec-phase'

group "The gate's own config is writable in every phase [#11]"
# The complement of the group above: phase STATE is never the model's, but gate
# CONFIG always is. Getting this backwards deadlocked the workflow outright —
# `phase.sh red` with no test command tells you to create
# .claude/spec-gate-test-cmd, and Phase 3 then refused the write as "production
# code", so the only route to Phase 4 was the force gate the user had to answer.
for p in 1 2 3; do
  phase "$p"
  expect_w "phase $p: Write the test command"    ALLOW .claude/spec-gate-test-cmd
  expect_b "phase $p: redirect the test command" ALLOW "printf 'yarn jest \$SPEC_GATE_TEST_FILES\n' > .claude/spec-gate-test-cmd"
  expect_w "phase $p: Write the exclude list"    ALLOW .claude/spec-gate-review-exclude
done
phase 3
expect_w "absolute path form allowed"          ALLOW "$PWD/.claude/spec-gate-test-cmd"
expect_b "tee onto the test command allowed"   ALLOW 'echo x | tee .claude/spec-gate-test-cmd'
# The exemption is two exact filenames, not a hole in .claude/. Opening the
# directory would let Phase 3 rewrite settings.json or the guard script itself —
# i.e. unlock production code by disarming the thing refusing it.
expect_w "settings.json stays denied"          DENY  .claude/settings.json
expect_w "the guard script stays denied"       DENY  .claude/hooks/phase-guard.sh
expect_w "the policy file stays denied"        DENY  .claude/hooks/phase-policy.sh
expect_w "a lookalike name stays denied"       DENY  .claude/spec-gate-test-cmd.sh
expect_w "phase state is still denied"         DENY  .claude/.spec-red

# The deadlock, end to end: what `phase.sh red` instructs must be a write the
# guard permits. These two drifting apart is the actual defect, so pin them
# against each other rather than against a hardcoded path.
setup_repo; phase start v; phase 3
out=$(.claude/hooks/phase.sh red 2>&1)
sug=$(printf '%s' "$out" | sed -nE "s|.*> (\.claude/[a-z-]+).*|\1|p" | head -1)
if [ -n "$sug" ]; then
  ok "phase.sh red names a config path to create ($sug)"
  expect_w "and the guard permits exactly that path" ALLOW "$sug"
else
  bad "phase.sh red printed no config path: $(printf '%s' "$out" | tr '\n' ' ')"
fi

# Writing the test command decides what "RED verified" means, so the command has
# to be visible in the transcript the user approves from. Without this, `exit 1`
# mints a receipt that looks exactly like a real test run.
printf 'exit 1\n' > .claude/spec-gate-test-cmd
printf 'a new test\n' > src/feature.test.ts
out=$(.claude/hooks/phase.sh red 2>&1)
# Matched with the label, not bare: "RED verified (exit 1)" already contains the
# command string, so a bare grep passes without the command ever being shown.
printf '%s' "$out" | grep -q 'command: exit 1' \
  && ok "red echoes the command it ran" \
  || bad "red does not show the command: $(printf '%s' "$out" | tr '\n' ' ')"
grep -q '^cmd=exit 1$' .claude/.spec-red \
  && ok "the receipt records the command" \
  || bad "the receipt does not record the command it ran"

# Hand the next group the fixture it expects. The groups below share one repo and
# reach Phase 4 through `phase 4`, which only succeeds while RED is unverifiABLE
# — no test command configured. Leaving the one written above in place makes that
# advance refuse instead, and the failure surfaces three groups later as an
# unrelated-looking "4 -> 5 denied".
setup_repo; phase start verify; phase 5

group "Phase 4/5 — normal permission flow"
phase 4
expect_w "production write allowed at 4"       ALLOW src/x.ts
expect_b "shell write allowed at 4"            ALLOW 'echo hi > src/y.ts'

group "Who may advance a phase [#1]"
adv() { # <label> <current> <arg> <expected>
  phase "$2"
  expect_b "$1" "$4" ".claude/hooks/phase.sh $3"
}
adv "1 -> 2 model may"                    1 2   ALLOW
adv "1 -> 3 skip denied"                  1 3   DENY
adv "1 -> 4 skip denied"                  1 4   DENY
adv "2 -> 3 prompts for spec approval"    2 3   ASK
adv "3 -> 4 denied while RED unverified"  3 4   DENY
adv "3 -> 2 retreat allowed"              3 2   ALLOW
adv "4 -> 2 contradiction retreat"        4 2   ALLOW
adv "4 -> 5 self-submit to review"        4 5   ALLOW
adv "5 -> 4 escaping review denied"       5 4   DENY
adv "5 -> 2 escaping review denied"       5 2   DENY
adv "1 -> off denied"                     1 off DENY
adv "3 -> off denied"                     3 off DENY
# `off` from 4-5 expands no write access, which is why it used to be allowed
# outright. It still ends the task, and that decision is the user's.
adv "5 -> off prompts, never silent"      5 off ASK
adv "4 -> off prompts, never silent"      4 off ASK
adv "status always allowed"               3 status ALLOW
adv "red is the model's to run"           3 red    ALLOW
adv "re-arming denied while armed"        3 start  DENY
phase 3
expect_b "alternate spelling denied [#1]" DENY 'bash .claude/hooks/phase.sh 4'
expect_b "absolute spelling denied [#1]"  DENY "bash $PWD/.claude/hooks/phase.sh 4"
# --force is the user's override for a refused RED check. If the model could
# reach it, the check would be advisory.
expect_b "--force is never the model's"   DENY '.claude/hooks/phase.sh 4 --force'
phase 5
expect_b "--force denied from phase 5 too" DENY '.claude/hooks/phase.sh 4 --force'

phase 2
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh 3')")
if printf '%s' "$reason" | grep -qi 'spec'; then
  ok "the 2 -> 3 prompt explains what approving asserts"
else
  bad "2 -> 3 ask reason is empty or unhelpful: '$reason'"
fi
if printf '%s' "$reason" | grep -q '"'; then
  bad "ask reason contains a raw double quote — would break hand-built JSON"
else
  ok "ask reason is JSON-safe"
fi

# The hook's `ask` is not documented to survive bypassPermissions, so
# settings.json must carry an explicit ask rule for both approval gates.
for t in 3 4 off; do
  if python3 -c '
import json,sys
d=json.load(open(".claude/settings.json"))
rules=d.get("permissions",{}).get("ask",[])
sys.exit(0 if any("phase.sh "+sys.argv[1] in r for r in rules) else 1)' "$t" 2>/dev/null; then
    ok "settings.json ask rule for phase.sh $t covers bypassPermissions"
  else
    bad "settings.json has no permissions.ask rule for phase.sh $t"
  fi
done

# The close-out prompt is the last thing standing between "review done" and a
# disarmed gate, so it has to say what accepting disposes of.
phase 5
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh off')")
if printf '%s' "$reason" | grep -qi 'pull request'; then
  ok "the off prompt names the decision it is standing in for"
else
  bad "off ask reason does not mention shipping the work: '$reason'"
fi
if printf '%s' "$reason" | grep -q '"'; then
  bad "off ask reason contains a raw double quote — would break hand-built JSON"
else
  ok "off ask reason is JSON-safe"
fi

group "Corrupt state fails closed [#7]"
printf 'phase=notanumber\ntask=x\n' > .claude/.spec-phase
expect_w "corrupt phase denies writes"    DENY src/x.ts
out=$(.claude/hooks/phase.sh status 2>&1); rc=$?
if [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -qi 'unbound variable'; then
  ok "phase.sh status survives corrupt state [#7]"
else
  bad "phase.sh status on corrupt state — rc=$rc out=$out"
fi
printf 'task=only\n' > .claude/.spec-phase
expect_w "missing phase= denies writes"   DENY src/x.ts

# phase.sh degrades rather than erroring when the policy file is gone, and the
# degraded answer has to be a refusal — an advance nobody could check is the
# fail-open this project keeps finding.
setup_repo; phase start v; phase 3
printf 'exit 1\n' > .claude/spec-gate-test-cmd
printf 'a new test\n' > src/feature.test.ts
mv .claude/hooks/phase-policy.sh "$WORK/policy.bak"
out=$(.claude/hooks/phase.sh red 2>&1); rc=$?
if [ "$rc" != 0 ] && ! printf '%s' "$out" | grep -qi 'command not found'; then
  ok "phase.sh red refuses when phase-policy.sh is missing"
else
  bad "phase.sh red without a policy file — rc=$rc out=$(printf '%s' "$out" | tr '\n' ' ')"
fi
.claude/hooks/phase.sh 4 >/dev/null 2>&1
[ "$(sed -n 's/^phase=//p' .claude/.spec-phase)" = 3 ] \
  && ok "phase.sh 4 does not advance without a policy file" \
  || bad "phase.sh 4 advanced with no policy file to check against"
mv "$WORK/policy.bak" .claude/hooks/phase-policy.sh

group "Review gate"
setup_repo
phase off
expect_gate "clean tree ends the turn" 0
echo 'change' >> src/x.ts
expect_gate "dirty tracked tree blocks" 2
expect_gate "same diff is not re-reviewed" 0
expect_gate "loop guard honours stop_hook_active" 0 true

group "The fingerprint ignores the index"
# The workflow stages the work before the first review round, so that later rounds
# arrive as `git diff` and the reviewer can find the fixes without re-reading
# everything. That only works if `git add` is invisible to the gate: both of the
# obvious fingerprint sources are index-sensitive (`git status --porcelain`
# rewrites its codes, and `git diff HEAD` starts including a file the moment it is
# added), and either would demand a fresh review of byte-identical content — the
# same bill that "committing re-armed the gate" used to run up.
setup_repo
phase off
echo 'change' >> src/x.ts
echo 'new' > src/brand-new.ts
expect_gate "dirty tree with an untracked file blocks" 2
git add -A >/dev/null 2>&1
expect_gate "git add -A does not re-arm the gate" 0
git restore --staged . >/dev/null 2>&1
expect_gate "unstaging does not re-arm it either" 0
git add -A >/dev/null 2>&1
# The point of the whole mechanism: a fix on top of a staged base still gets
# reviewed. If invariance had been bought by dropping content from the
# fingerprint, this is the case that would silently pass.
echo 'the fix' >> src/brand-new.ts
expect_gate "a fix on top of a staged base is still owed review" 2
git add -A >/dev/null 2>&1
expect_gate "staging the fix is not itself a change" 0
# Deletions and mode changes have no content hash to move, so they are carried
# separately. tree_snapshot only hashes files that exist.
rm tests/helper.ts
expect_gate "a deletion is owed review" 2
git add -A >/dev/null 2>&1
expect_gate "staging the deletion is not a change" 0
chmod +x src/x.ts
expect_gate "a mode change is owed review" 2
git add -A >/dev/null 2>&1
expect_gate "staging the mode change is not a change" 0
# A *new* file's mode reaches `git diff HEAD --summary` only as `create mode`,
# which appears only once the file is staged — so index-invariance cost the mode
# of every new file until tree_snapshot started carrying an exec flag. The hole
# was: review a new script, chmod +x it, ship the mode change unreviewed.
printf '#!/bin/sh\n' > src/hook.sh
expect_gate "a new script is owed review" 2
git add -A >/dev/null 2>&1
expect_gate "staged, and quiet" 0
chmod +x src/hook.sh
expect_gate "chmod +x on a staged new file is owed review" 2
git add -A >/dev/null 2>&1
expect_gate "staging that mode change is not a change" 0

# Without phase-policy.sh there is no shared snapshot to hash, and the fallback
# has to be a louder gate rather than a quieter one: a fail-open here is the whole
# guarantee gone. It costs index-sensitivity, which the message says out loud.
setup_repo
phase off
echo 'change' >> src/x.ts
mv .claude/hooks/phase-policy.sh "$WORK/policy.bak"
FB=$(printf '{"stop_hook_active":false}' | .claude/hooks/review-gate.sh 2>&1 >/dev/null; echo "rc=$?")
if printf '%s' "$FB" | grep -q 'rc=2'; then
  ok "the gate still fires with no phase-policy.sh"
else
  bad "no policy file left the review gate inert — fail-open: $(printf '%s' "$FB" | tr '\n' ' ')"
fi
printf '%s' "$FB" | grep -qi 'index-sensitive' \
  && ok "and says the fingerprint degraded" \
  || bad "the degraded fingerprint is silent"
mv "$WORK/policy.bak" .claude/hooks/phase-policy.sh

group "The gate reports what moved between rounds"
# The one part of the follow-up message a hook can settle instead of a prompt.
# Everything else in that message is the model's account of its own fixes; this is
# the fingerprint's, so the marker keeps the whole snapshot rather than its hash.
setup_repo
phase off
delta() { printf '{"stop_hook_active":false}' | .claude/hooks/review-gate.sh 2>&1 >/dev/null | tr '\n' ' ' | tr -s ' '; }
echo 'work' >> src/x.ts
printf 'new\n' > src/new.ts
D=$(delta)
printf '%s' "$D" | grep -qi 'changed since the last review round' \
  && bad "round one reported a delta against nothing" \
  || ok "round one reports no delta — there is no previous round"

git add -A >/dev/null 2>&1
echo 'the fix' >> src/new.ts
D=$(delta)
printf '%s' "$D" | grep -q 'Changed since the last review round: src/new.ts' \
  && ok "round two names exactly the path that moved" \
  || bad "the delta did not name the fixed path: $(printf '%s' "$D" | head -c 200)"
printf '%s' "$D" | grep -q 'src/x.ts' \
  && bad "the delta re-reported a path that did not move" \
  || ok "and leaves out the path that did not move"
# A path that goes back to matching HEAD has to be reported too, and reported as a
# different thing: the reviewer's judgment of it is now void either way.
git add -A >/dev/null 2>&1
rm src/new.ts
D=$(delta)
printf '%s' "$D" | grep -q 'No longer differs from HEAD.*src/new.ts' \
  && ok "a reverted or removed path is reported separately" \
  || bad "a path that stopped differing was not reported: $(printf '%s' "$D" | head -c 200)"
printf '%s' "$D" | grep -qi 'list is the gate' \
  && ok "the message says whose list it is" \
  || bad "the delta is presented without saying it is the gate's"

# A marker written before the format change holds a bare hash. It must still
# answer "same diff?" and must not produce a garbage delta on the way.
setup_repo
phase off
echo 'work' >> src/x.ts
printf 'not-a-snapshot\n' > "$(git rev-parse --git-dir)/claude-review-gate"
D=$(delta)
printf '%s' "$D" | grep -qi 'REVIEW GATE' \
  && ok "a legacy hash-only marker still blocks" \
  || bad "a legacy marker broke the gate: $(printf '%s' "$D" | head -c 200)"
printf '%s' "$D" | grep -qi 'changed since the last review round' \
  && bad "a legacy marker produced a delta out of nothing" \
  || ok "and reports no delta rather than an invented one"
expect_gate "the upgraded marker suppresses the same diff" 0

# A clean tree ends the round. Leaving the marker behind would make the next
# task's first round report the last task's committed work as reverted.
setup_repo
phase off
echo 'work' >> src/x.ts
expect_gate "work blocks" 2
git add -A >/dev/null 2>&1; git commit -qm "ship it" >/dev/null 2>&1
expect_gate "clean tree after the commit" 0
[ -f "$(git rev-parse --git-dir)/claude-review-gate" ] \
  && bad "the marker survived a clean tree" \
  || ok "a clean tree drops the marker"
echo 'next task' >> src/x.ts
D=$(delta)
printf '%s' "$D" | grep -qi 'no longer differs' \
  && bad "the next task inherited the last one's snapshot" \
  || ok "the next task starts without a delta"

group "The bookmark is kept by a hook, not by the caller"
# Both jobs here were prose that failed in real use. Staging went wrong silently
# in the dangerous direction — staged after revising, so the reviewer opened an
# empty `git diff` — and the gate had no record of a review round it did not
# mediate, which is every first round in Phase 5.
bookmark() { # <event> <agent>
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":sys.argv[1],"agent_type":sys.argv[2],"cwd":sys.argv[3]}))' \
    "$1" "$2" "$PWD" | .claude/hooks/review-bookmark.sh >/dev/null 2>&1
}

setup_repo; phase off
echo 'round one work' > src/new.ts
bookmark SubagentStart adversary
if [ -z "$(git diff --name-only)" ] && [ -n "$(git diff --cached --name-only)" ]; then
  ok "spawning a reviewer stages the work it is about to judge"
else
  bad "SubagentStart left the tree unstaged — the reviewer sees no bookmark"
fi

# The gate has never run: this is the Phase 5 shape, where the workflow spawns the
# reviewer itself and the gate only wakes up at the end of the turn.
rm -f .git/claude-review-gate
bookmark SubagentStop adversary
if [ -f .git/claude-review-gate ]; then
  ok "a landed verdict records the round, even one the gate never mediated"
else
  bad "SubagentStop did not seed the marker — the next block reports no delta"
fi
echo 'the fix' >> src/new.ts
D=$(printf '{"stop_hook_active":false}' | .claude/hooks/review-gate.sh 2>&1 >/dev/null)
if printf '%s' "$D" | grep -qF 'Changed since the last review round'; then
  ok "the first block after a workflow-driven round reports its delta"
else
  bad "no delta after a recorded round — the marker is not being read"
fi

# Staging on the way out is the half that kept failing. It has to land before the
# caller can touch anything, which is what SubagentStop buys.
setup_repo; phase off
echo 'work' > src/new.ts
bookmark SubagentStart adversary
echo 'a fix made in response to the verdict' >> src/new.ts
bookmark SubagentStop adversary
if [ -z "$(git diff --name-only)" ]; then
  ok "the verdict landing re-stages, so the next round's diff starts empty"
else
  bad "SubagentStop did not re-stage — round three would show round two's fix"
fi

# The design reviewer must not seed the code reviewer's marker. It runs at phases
# 2-3, so a marker written from its rounds would make Phase 5's first delta list
# every file written in phases 3 and 4.
setup_repo; phase off
echo 'work' > src/new.ts
rm -f .git/claude-review-gate
bookmark SubagentStop spec-adversary
if [ ! -f .git/claude-review-gate ]; then
  ok "spec-adversary stages but does not record the code reviewer's round"
else
  bad "a design review seeded the code review marker — wrong subject"
fi
if [ -n "$(git diff --cached --name-only)" ]; then
  ok "spec-adversary still stages on the way out"
else
  bad "spec-adversary left the spec unstaged — its own round two loses the diff"
fi

# Any other subagent is none of this hook's business, even if a wider matcher
# lets it through.
setup_repo; phase off
echo 'work' > src/new.ts
bookmark SubagentStop Explore
if [ -z "$(git diff --cached --name-only)" ]; then
  ok "an unrelated subagent does not touch the index"
else
  bad "review-bookmark.sh staged on a subagent that is not a reviewer"
fi

# One implementation of the fingerprint, or the delta compares two different ideas
# of what changed and reports nonsense authoritatively.
if grep -qF 'review_fingerprint' "$SRC/hooks/review-gate.sh" \
   && grep -qF 'review_fingerprint' "$SRC/hooks/review-bookmark.sh" \
   && grep -qF 'review_fingerprint()' "$SRC/hooks/phase-policy.sh"; then
  ok "both marker writers share one fingerprint implementation"
else
  bad "the fingerprint is implemented more than once — the delta will drift"
fi
if [ -x "$SRC/hooks/review-bookmark.sh" ]; then
  ok "review-bookmark.sh is committed executable"
else
  bad "review-bookmark.sh is not executable — cp -R installs a hook that cannot run"
fi
if python3 -c '
import json, sys
d = json.load(open(".claude/settings.json"))
h = d.get("hooks", {})
def wired(ev):
    return any("adversary" in (x.get("matcher") or "")
               and any("review-bookmark" in c.get("command", "") for c in x.get("hooks", []))
               for x in h.get(ev, []))
sys.exit(0 if wired("SubagentStart") and wired("SubagentStop") else 1)' 2>/dev/null; then
  ok "settings.json wires the bookmark hook to both ends of a review"
else
  bad "settings.json does not run review-bookmark.sh on both SubagentStart and SubagentStop"
fi

group "The block message drives the caller, not the reviewer"
# The split: the reviewer loads its own procedure from the skill, so the spawn text
# here is a pointer. What stays is everything a read-only subagent cannot do —
# validate, stage, spawn, act — plus the two facts only the gate holds.
setup_repo
phase off
echo 'change' >> src/x.ts
# Flattened: the phrases wrap across lines in the heredoc, so a line-oriented
# grep would pin the line breaks rather than the wording.
BLOCK=$(printf '{"stop_hook_active":false}' | .claude/hooks/review-gate.sh 2>&1 >/dev/null | tr '\n' ' ' | tr -s ' ')
# The spawn is a pointer. 'a pointer, not a briefing' is the rule that stops this
# message regrowing a second copy of the reviewer's brief, which is what it was.
for want in 'Use the `adversarial-review` skill and follow it' 'a pointer, not a briefing' \
            'no restating the skill' 'only thing I am telling you'; do
  if printf '%s' "$BLOCK" | grep -qF "$want"; then
    ok "block message spawns with a pointer: '$want'"
  else
    bad "block message no longer spawns with a pointer: '$want' is gone"
  fi
done
# Validate before the spawn, and stage before the reviewer sees anything. Both are
# caller-only: the reviewer cannot fix a red suite and must not touch the index.
for want in 'get it green' 'do not invent a list' 'VALIDATION REPORT'; do
  if printf '%s' "$BLOCK" | grep -qF "$want"; then
    ok "block message runs validations before spawning: '$want'"
  else
    bad "block message dropped the pre-spawn work: '$want' is gone"
  fi
done
# Staging moved to review-bookmark.sh because the caller kept getting it wrong.
# The message must now tell the caller to keep its hands off the index — an
# instruction to run `git add` is the thing that broke the bookmark.
for want in 'the gate stages for you' 'no reason to run'; do
  if printf '%s' "$BLOCK" | grep -qF "$want"; then
    ok "block message hands staging to the hook: '$want'"
  else
    bad "block message still asks the caller to stage: '$want' is gone"
  fi
done
# The gate fires again on the fixed diff, and that round is where a fresh spawn
# costs most: it cannot say whether the fix closed anything, because it never saw
# the finding. So the block message has to ask for the same session back, and the
# follow-up wording has to withhold as much as the first prompt did.
for want in 'same `adversary` session' 'do not spawn a second' 'Keep the handle' \
            'should show the same set' 'Never stage between fixing and messaging' \
            'path list is the gate' 'paste the gate'; do
  if printf '%s' "$BLOCK" | grep -qF "$want"; then
    ok "block message asks for the resumed session: '$want'"
  else
    bad "block message no longer asks for session reuse: '$want' is gone"
  fi
done

group "The validation report's field labels are one contract, not three"
# The skill tells the reviewer to read the `Not covered` line *by name*, and calls
# it the most useful thing it is told all round. Two separate producers have to
# emit that label: Phase 4 writes the report for the workflow path, and the block
# message instructs it for the no-workflow path the review gate exists to cover.
#
# The bug this replaces: the hook described the field ("what this repo checks
# nothing about") without ever naming it, so on the gate path the reviewer looked
# for a label nobody had written. Both sides were pinned — but to *different*
# strings, in two independent assertions, so both stayed green while they
# disagreed. Same shape as the tools:/body contradiction, between two prose files.
#
# So this asserts the label itself across the consumer and every producer, and any
# new producer has to be added here. One contract, one test.
# Producers are checked for the label as an EMITTED FIELD — 'Not covered:', with
# the colon, as it appears in the report template. Not for the bare words anywhere
# in the file: both producers also discuss the field in prose ("`Not covered` is
# the one you will be tempted to leave blank"), so a file-wide grep for the words
# passes with the template field deleted. Confirmed by deleting it — 314/314 green.
# The consumer is the mirror image: it never emits the report, it refers to the
# label, so there the backticked prose form is the correct thing to pin.
setup_repo
if grep -qF '`Not covered`' "$SRC/skills/adversarial-review/SKILL.md"; then
  ok "the consumer reads 'Not covered' by name"
else
  bad "the skill no longer names 'Not covered' — producers are labelling for nobody"
fi
for p in skills/spec-driven/SKILL.md hooks/review-gate.sh; do
  if grep -qE '^ *Not covered:' "$SRC/$p"; then
    ok "$p emits a 'Not covered:' field"
  else
    bad "$p describes the field without labelling it — the reviewer looks up by name"
  fi
done
# The other three labels travel with it: a report the reviewer can parse at all
# needs the same field names from both producers, in template position.
for lbl in 'VALIDATION REPORT' 'Commands:' 'Source:' 'Result:'; do
  if grep -qE "^ *$lbl" "$SRC/skills/spec-driven/SKILL.md" \
     && grep -qE "^ *$lbl" "$SRC/hooks/review-gate.sh"; then
    ok "both producers emit '$lbl'"
  else
    bad "'$lbl' is not emitted by both producers — the two report shapes diverge"
  fi
done

group "The adversarial-review skill holds the reviewer's procedure"
# One copy, loaded by the subagent itself. These are the phrases that make it a
# review rather than a confirmation; every caller reaches them through the skill,
# so losing them here loses them everywhere at once.
setup_repo
[ -f .claude/skills/adversarial-review/SKILL.md ] \
  && ok "adversarial-review skill is installed" \
  || bad "no .claude/skills/adversarial-review/SKILL.md — the agent points at nothing"
REVIEW=$(tr '\n' ' ' < .claude/skills/adversarial-review/SKILL.md 2>/dev/null | tr -s ' ')
for want in 'adversarial reviewer' 'find the reason it is wrong' \
            'no reasoning from the author' 'Do not manufacture findings' \
            'say so in one line'; do
  if printf '%s' "$REVIEW" | grep -qF "$want"; then
    ok "skill carries the stance: '$want'"
  else
    bad "skill is missing the stance: '$want'"
  fi
done
for want in 'Follow-up rounds' 'not re-checked' 'because it is the one you asked for' \
            'Do not pad a later round' 'claim to check, not a report to accept' \
            'If nothing is staged' 'empty `git diff` is not evidence' \
            'nothing appears to have moved'; do
  if printf '%s' "$REVIEW" | grep -qF "$want"; then
    ok "skill handles follow-up rounds: '$want'"
  else
    bad "skill is missing the follow-up rule: '$want'"
  fi
done
# A clean tree does not mean nothing to review — it means the work is committed.
# Hardcoding 'main' diffs against a ref that may not exist, and an empty diff
# reads exactly like a change with nothing wrong in it.
for want in 'merge-base' 'symbolic-ref' 'indistinguishable from a change with nothing wrong' \
            'branch mode'; do
  if printf '%s' "$REVIEW" | grep -qF "$want"; then
    ok "skill resolves a clean tree to the branch: '$want'"
  else
    bad "skill cannot review a committed branch: '$want' is gone"
  fi
done
# The reviewer stops paying for a suite the caller already ran — but only if the
# procedure says so, and only if it still allows a targeted run to prove a finding.
for want in 'Do not re-run the suite' 'Not covered' \
            'prove a specific finding is still right' 'report is a claim'; do
  if printf '%s' "$REVIEW" | grep -qF "$want"; then
    ok "skill uses the validation report: '$want'"
  else
    bad "skill is missing the report rule: '$want'"
  fi
done
# A green suite is the best cover a weakened test has: both the suite and the
# report say 'pass'. With the reviewer no longer running tests, this is the one
# regression the split could have introduced.
if printf '%s' "$REVIEW" | grep -qF 'weakened to'; then
  ok "skill treats a loosened test as a blocker"
else
  bad "skill no longer catches a test loosened to make a fix pass"
fi

group "The adversary agent can actually reach the skill it points at"
# The failure this group exists for shipped once and every prose test passed over
# it: the body said "invoke the adversarial-review skill" while `tools:` was an
# exact allowlist that excluded Skill and no `skills:` field was set, so the
# reviewer was told to load something it had no way to load.
#
# Claude Code's agent schema, verbatim from the binary:
#   tools  — "Array of allowed tool names. If omitted, inherits all tools from
#            parent. Note: passing 'Skill' here is deprecated — use the skills
#            field instead."
#   skills — "Array of skill names to preload into the agent context"
#
# So this asserts frontmatter, not prose. Prose is what lied last time.
setup_repo
for f in agents/adversary.md cursor/agents/adversary.md; do
  FM=$(awk 'NR>1 && /^---$/{exit} NR>1{print}' "$SRC/$f")
  if printf '%s' "$FM" | grep -qE '^skills:.*adversarial-review'; then
    ok "$f preloads the skill via skills:"
  else
    bad "$f has no 'skills: adversarial-review' — the pointer in its body cannot resolve"
  fi
  # Preloading, not tool-granting. `Skill` in tools: is documented as deprecated,
  # and it only makes the skill *reachable* by a reviewer that remembers to fetch
  # it; skills: puts the procedure in context whether it remembers or not.
  if printf '%s' "$FM" | grep -qE '^tools:.*\bSkill\b'; then
    bad "$f grants the deprecated Skill tool instead of preloading via skills:"
  else
    ok "$f does not rely on the deprecated Skill tool"
  fi
done
# The name in skills: has to match the directory the skill installs to, or it
# preloads nothing and fails exactly as silently as having no field at all.
SKILL_NAME=$(sed -n 's/^name: *//p' "$SRC/skills/adversarial-review/SKILL.md" | head -1)
if [ "$SKILL_NAME" = "adversarial-review" ] && [ -d "$SRC/skills/adversarial-review" ]; then
  ok "the skill's name matches what the agents preload"
else
  bad "skill name '$SKILL_NAME' does not match the agents' 'adversarial-review'"
fi
# A reviewer that cannot load its procedure must not improvise, and must not
# return nothing either — cannot-assess is already defined as 'not a pass', so it
# is the one verdict that fails safe.
for f in agents/adversary.md cursor/agents/adversary.md; do
  if grep -qF 'cannot load the skill, return `cannot-assess`' "$SRC/$f"; then
    ok "$f fails safe when the skill is unreachable"
  else
    bad "$f does not say what to do when the skill cannot be loaded"
  fi
done

group "Branch mode resolves a trunk that exists, or refuses"
# `git merge-base HEAD main` in a master-trunk repo fails, leaves BASE empty, and
# turns `git diff "$BASE"..HEAD` into HEAD..HEAD — exit 0, no output. The reviewer
# reads nothing and reports sound. Every candidate has to be verified to exist.
setup_repo
RES=$(tr '\n' ' ' < .claude/skills/adversarial-review/SKILL.md | tr -s ' ')
for want in 'rev-parse --verify' 'origin/main origin/master origin/develop' \
            'no trunk resolved' 'is not in the list'; do
  if printf '%s' "$RES" | grep -qF "$want"; then
    ok "trunk resolution is verified: '$want'"
  else
    bad "trunk resolution lost its guard: '$want' is gone"
  fi
done
# init.defaultBranch describes repo *creation*, not this repo's trunk. It agrees
# often enough to look correct, which is what made it survive review the first time.
if printf '%s' "$RES" | grep -qF 'init.defaultBranch}'; then
  bad "trunk resolution still falls back to init.defaultBranch"
else
  ok "trunk resolution does not trust init.defaultBranch"
fi
# Live check of the resolution against the case that used to fail silently: master
# trunk, no remote. The skill ships this as a script rather than a fenced block a
# reviewer retypes, so the test runs the artefact itself — there is no longer an
# extraction step that could pass while the shipped procedure rots.
BR="$WORK/branchmode"; rm -rf "$BR"; mkdir -p "$BR"; cd "$BR"
git init -q -b master . && git config user.email t@e.com && git config user.name t
echo a > f.ts && git add -A && git commit -qm i
git checkout -q -b feature && echo b >> f.ts && git commit -qam work
# Kept OUTSIDE the fixture repos, and that is not tidiness: the script resolves a
# dirty tree to `TARGET: working tree` before it ever looks for a trunk, so a copy
# living inside the fixture is an untracked file that sends every branch-mode case
# down the working-tree path. Cost an hour the first time.
RESOLVE="$WORK/resolve-review-target.sh"
cp "$SRC/skills/adversarial-review/scripts/resolve-review-target.sh" "$RESOLVE" 2>/dev/null
if [ ! -s "$RESOLVE" ]; then
  bad "the skill ships no scripts/resolve-review-target.sh — step 1 points at nothing"
else
  # The script's contract is its stdout, so the resolved trunk and base are parsed
  # out of the TARGET: line rather than sourced as variables. That is the same
  # thing the reviewer reads, which is the point: the test consumes the interface
  # the skill documents, not the implementation behind it.
  OUT=$(bash "$RESOLVE" 2>&1)
  T=$(printf '%s\n' "$OUT" | sed -n 's/^TARGET: branch \([^ ]*\) @ .*/\1/p')
  BS=$(printf '%s\n' "$OUT" | sed -n 's/^TARGET: branch [^ ]* @ \([^.]*\)\.\..*/\1/p')
  if [ "$T" = "master" ] && [ -n "$BS" ]; then
    ok "the shipped script resolves a master trunk with no remote"
  else
    bad "the shipped script fails on a master trunk (trunk='$T' base='$BS')"
  fi
  # Not $N — that is the suite's colour-reset escape, and shadowing it prints
  # "FAIL1" instead of a reset. Same class of bug as $B; hence both comments.
  NFILES=$(git diff --name-only "$BS"..HEAD 2>/dev/null | wc -l | tr -d ' ')
  [ "$NFILES" = "1" ] && ok "and produces a non-empty diff (1 file)" \
    || bad "and produces an empty diff — the silent-sound failure is back"
fi

# The two ways this block used to produce an empty diff while looking fine. Both
# are executed, and — this is the part the first version of these tests got wrong —
# both assert that `git diff` **never ran**, not that it printed nothing.
#
# Why the distinction is the whole test: in these fixtures the unguarded diff is
# `git diff ..HEAD`, which git reads as HEAD..HEAD and which prints nothing. The
# emptiness *is* the bug. So an output-based check ("no ^diff --git lines") passes
# identically on the guarded and unguarded block, and can never fire in the one
# fixture it exists to guard. Verified by reintroducing the bug: both output
# assertions still passed, 306/306 green.
#
# `bash -x` traces commands as they execute regardless of what they emit, which is
# the property actually being asserted. Same reintroduction makes it fail.
ran_diff() {  # $1 = fixture dir, echoes the number of times `git diff` executed
  ( cd "$1" && bash -x "$RESOLVE" 2>&1 >/dev/null \
      | grep -c "^+* git diff" )
}

# (A) no trunk among the candidates. The guard must suppress the diff, not merely
#     print next to it. This is the case the output-based assertion could not see.
rm -rf notrunk && mkdir notrunk && cd notrunk
git init -q -b wip . && git config user.email t@e.com && git config user.name t
echo x > f.ts && git add -A && git commit -qm i
OUT=$(bash "$RESOLVE" 2>&1)
if printf '%s' "$OUT" | grep -q '^STOP:'; then
  ok "no trunk: the block refuses"
else
  bad "no trunk: the block did not print STOP (got: $(printf '%s' "$OUT" | head -1))"
fi
cd "$WORK/branchmode"
T=$(ran_diff notrunk)
if [ "$T" = "0" ]; then
  ok "no trunk: and git diff never executes"
else
  bad "no trunk: it warned and ran git diff anyway ($T call(s)) — the guard does not guard"
fi

# (B) HEAD *is* the trunk. merge-base returns HEAD, so BASE is non-empty and every
#     guard passes — quieter than (A), which printed at least a warning. This is
#     the likely one: commit to main, then ask for a review.
rm -rf ontrunk && mkdir ontrunk && cd ontrunk
git init -q -b main . && git config user.email t@e.com && git config user.name t
echo x > f.ts && git add -A && git commit -qm i && echo y >> f.ts && git commit -qam two
OUT=$(bash "$RESOLVE" 2>&1)
if printf '%s' "$OUT" | grep -q 'no branch to review'; then
  ok "HEAD is the trunk: the block says so"
else
  bad "HEAD is the trunk: silently resolved to an empty diff (got: $(printf '%s' "$OUT" | head -1))"
fi
cd "$WORK/branchmode"
T=$(ran_diff ontrunk)
if [ "$T" = "0" ]; then
  ok "HEAD is the trunk: and git diff never executes"
else
  bad "HEAD is the trunk: git diff ran on an empty range ($T call(s))"
fi

# (C) A dirty tree short-circuits trunk resolution entirely. This path did not
#     exist while step 1 was a fenced block — the porcelain check was prose the
#     reviewer ran by hand — so it is the one part of the script nothing had ever
#     executed. It is also the common case: Phase 5 and the review gate only ever
#     review a dirty tree.
rm -rf dirty && mkdir dirty && cd dirty
git init -q -b main . && git config user.email t@e.com && git config user.name t
echo x > f.ts && git add -A && git commit -qm i
echo untracked > new.ts
OUT=$(bash "$RESOLVE" 2>&1)
if printf '%s' "$OUT" | grep -q '^TARGET: working tree'; then
  ok "an untracked file alone resolves to the working tree"
else
  bad "a dirty tree did not resolve to the working tree (got: $(printf '%s' "$OUT" | head -1))"
fi
if printf '%s' "$OUT" | grep -q 'new.ts'; then
  ok "and the untracked file is named in the output"
else
  bad "the working-tree target hides the untracked file the reviewer has to read"
fi
cd "$WORK"

group "Every path a skill points at exists"
# A SKILL.md that links a bundled file which is not there is the same failure the
# adversary group guards against — a procedure told to load something it cannot
# load — relocated into the skill's own filesystem, where nothing was looking. It
# fails silently in the worst way: the model reads the pointer, finds nothing, and
# improvises the part that was written down precisely so it would not have to.
#
# Anchors are checked too, not just files. Progressive disclosure only works if
# "see references/slicing.md#the-boundary" lands on a heading that still exists;
# a renamed heading leaves a link that resolves to the top of the file and looks
# like it worked.
setup_repo
LINKCHECK=$(python3 - "$SRC/skills" <<'PY'
import os, re, sys

root = sys.argv[1]
link = re.compile(r'\]\(([^)]+)\)')
head = re.compile(r'^#{1,6}\s+(.*?)\s*$', re.M)

def slug(t):
    t = re.sub(r'`', '', t).lower()
    t = re.sub(r'[^\w\s-]', '', t)
    return re.sub(r'\s+', '-', t.strip())

docs = [os.path.join(d, f) for d, _, fs in os.walk(root)
        for f in fs if f.endswith('.md')]
anchors = {p: {slug(h) for h in head.findall(open(p).read())} for p in docs}

n = 0
for p in docs:
    rel = os.path.relpath(p, root)
    for target in link.findall(open(p).read()):
        if target.startswith(('http', 'mailto:')):
            continue
        path, _, frag = target.partition('#')
        dest = os.path.normpath(os.path.join(os.path.dirname(p), path)) if path else p
        n += 1
        if not os.path.exists(dest):
            print(f"BAD {rel} links {target}, which does not exist")
        elif frag and dest.endswith('.md') and slug(frag) not in anchors.get(dest, set()):
            print(f"BAD {rel} links {target}, but no heading there has that anchor")
        else:
            print(f"OK  {rel} -> {target}")
print(f"COUNT {n}")
PY
)
while IFS= read -r line; do
  case "$line" in
    "OK  "*)  ok "${line#OK  }" ;;
    BAD*)     bad "${line#BAD }" ;;
    COUNT*)   [ "${line#COUNT }" -gt 0 ] \
                && ok "the skills carry ${line#COUNT } internal links" \
                || bad "no links found — the extractor broke, not the skills" ;;
  esac
done <<< "$LINKCHECK"

group "The reviewer's resolution ships as a script, not as prose to retype"
# The block used to be a fenced snippet the reviewer transcribed. A procedure that
# has to be retyped to run is a procedure that drifts from the one that was tested,
# and this suite could only ever check the copy in the markdown. Now there is one
# artefact and the tests above execute it.
setup_repo
RS=skills/adversarial-review/scripts/resolve-review-target.sh
[ -f "$SRC/$RS" ] && ok "the skill bundles $RS" \
  || bad "no $RS — SKILL.md step 1 points at a file that is not shipped"
# cp -R preserves the exec bit and the install does no chmod, so a script committed
# without it installs unrunnable. Same reason the hooks carry theirs.
[ -x "$SRC/$RS" ] && ok "and it is committed executable, as cp -R install requires" \
  || bad "$RS is not executable — cp -R installs it unrunnable"
[ -x ".claude/$RS" ] && ok "and it survives the install as executable" \
  || bad "$RS lost its exec bit on install"
# The skill has to name the file, or the script is shipped and never reached.
if grep -qF 'resolve-review-target.sh' "$SRC/skills/adversarial-review/SKILL.md"; then
  ok "SKILL.md names the script it ships"
else
  bad "SKILL.md does not name resolve-review-target.sh — the bundle is unreachable"
fi
# Both install roots, because the agent that loads this skill runs on both hosts
# and the skill is copied to .cursor/skills/ as the same file.
for host in .claude .cursor; do
  if grep -qF "$host/skills/adversarial-review/scripts" "$SRC/skills/adversarial-review/SKILL.md"; then
    ok "the lookup covers the $host install root"
  else
    bad "the lookup misses $host — the skill is installed there and would not find its own script"
  fi
done

group "The README does not claim a rule lives where it does not"
# The change that moved the code reviewer's procedure into the skill left every
# README sentence saying "both briefs" pointing at agents/adversary.md, which no
# longer holds any of them. Same defect the split exists to fix — one copy drifting
# from another, silently — relocated into the doc layer, where nothing looked.
#
# So: for each rule, find which file really holds it, then assert the README does
# not attribute it to a file that doesn't. This is the only test that reads the
# README, which is why the drift survived a green suite.
setup_repo
RM=$(tr '\n' ' ' < "$SRC/README.md" | tr -s ' ')
holds() { grep -qF "$2" "$SRC/$1"; }
# 'both briefs' is banned outright: there are no longer two briefs holding the
# reviewer rules — there is one brief (spec-adversary) and one skill.
if printf '%s' "$RM" | grep -qiF 'both briefs'; then
  bad "README still says 'both briefs' — the code reviewer's rules are in the skill"
else
  ok "README does not say 'both briefs'"
fi
# The rules that moved: present in the skill, absent from the agent. If one ever
# reappears in the agent, the split has regressed and the README wording is wrong
# in the other direction.
for r in 'claim to check, not a report to accept' \
         'empty `git diff` is not evidence' \
         'because it is the one you asked for'; do
  if holds skills/adversarial-review/SKILL.md "$r" && ! holds agents/adversary.md "$r"; then
    ok "'$r' lives in the skill, not the agent"
  else
    bad "'$r' is not where the README says — check both files"
  fi
done
# The loosened-test rule is the compensating control for this change's own cost,
# and it exists in exactly one place. The README used to claim two. If it is ever
# claimed to be in spec-adversary, that is false — a spec review has no test hunks.
if holds skills/adversarial-review/SKILL.md 'weakened to' \
   && ! holds agents/spec-adversary.md 'weakened to'; then
  ok "the loosened-test control is in the skill alone"
else
  bad "the loosened-test control moved or spread — the README describes one location"
fi
if printf '%s' "$RM" | grep -qF 'one paragraph in `skills/adversarial-review/SKILL.md`'; then
  ok "README points at the single file that holds it"
else
  bad "README no longer names where the loosened-test control actually lives"
fi
# Tuning recipes have to stay executable. 'Copy adversary.md, narrow the prompt'
# became a no-op the moment the prompt left that file.
if printf '%s' "$RM" | grep -qF 'Copy `adversary.md`, narrow the prompt'; then
  bad "Tuning still says to copy adversary.md — there is no prompt left in it"
else
  ok "the second-reviewer recipe does not copy an empty pointer"
fi

group "Branch mode records its own starting point"
# The reviewer was told the author supplies 'the tip they last showed you'. No
# caller ever does: the gate and Phase 5 are working-tree-only, and the standalone
# path's caller is a person. A contract only one side can sign fails every round.
setup_repo
BR=$(tr '\n' ' ' < .claude/skills/adversarial-review/SKILL.md | tr -s ' ')
for want in 'REVIEWED:' 'read it out of your own last verdict' \
            'no caller in this system supplies a tip'; do
  if printf '%s' "$BR" | grep -qF "$want"; then
    ok "branch mode is self-sufficient: '$want'"
  else
    bad "branch mode still depends on a tip nobody sends: '$want' is gone"
  fi
done

group "The adversary agent is a pointer to the skill, identically on both hosts"
# The agent file carries what a spawn config must — name, tools, the independence
# stance — and defers the procedure. If it starts re-stating the procedure, the
# two copies drift and the drift is silent.
setup_repo
for f in agents/adversary.md cursor/agents/adversary.md; do
  # Not $B — that is the suite's blue escape, and shadowing it makes every later
  # group() header print this file instead of a colour.
  AB=$(tr '\n' ' ' < "$SRC/$f" 2>/dev/null | tr -s ' ')
  for want in 'Invoke the `adversarial-review` skill and follow it' \
              'no reasoning from the author' \
              'Do not modify the files under review' \
              'the spawn is a pointer'; do
    if printf '%s' "$AB" | grep -qF "$want"; then
      ok "$f points at the skill: '$want'"
    else
      bad "$f is missing the pointer rule: '$want'"
    fi
  done
  # Thin means thin. A file that regrows the attack checklist is the second copy
  # this split exists to delete, and nothing else would notice.
  #
  # Count the BODY, not the file. The thing being protected is "the procedure has
  # not come back", and frontmatter comments are not procedure — the total-line
  # version of this sat two lines from failing on a comment-only edit, which would
  # have been a false statement about what changed. `tr -d ' '` because BSD wc pads
  # its output and the message would otherwise read "(      61 lines)".
  nbody=$(sed -n '/^You are an adversarial reviewer\./,$p' "$SRC/$f" | wc -l | tr -d ' ')
  if [ "$nbody" -lt 45 ]; then
    ok "$f body is still a pointer ($nbody lines)"
  else
    bad "$f body has regrown into a second brief ($nbody lines, procedure belongs in the skill)"
  fi
done
# Same reason the agent sets are compared elsewhere: a brief that differs per host
# is a brief that drifts. The bodies are identical; only frontmatter may differ.
claude_body=$(sed -n '/^You are an adversarial reviewer\./,$p' "$SRC/agents/adversary.md")
cursor_body=$(sed -n '/^You are an adversarial reviewer\./,$p' "$SRC/cursor/agents/adversary.md")
if [ "$(printf '%s\n' "$claude_body" | wc -l)" -lt 10 ]; then
  bad "adversary has no body to compare"
elif [ "$claude_body" = "$cursor_body" ]; then
  ok "adversary body is identical in .claude and .cursor"
else
  bad "adversary body has drifted between the two hosts"
fi

group "The spec is reviewed before the 2 -> 3 prompt"
# The spec review is instructed, not enforced, so everything load-bearing about it
# is text — in three separate files, and every one of them is something an edit can
# silently delete. Pin the parts that make it a review instead of a rubber stamp:
# the brief exists, the workflow names the reviewer it has to spawn, and the
# approval prompt says what a missing verdict means.
setup_repo
[ -f .claude/agents/spec-adversary.md ] \
  && ok "spec-adversary is installed alongside adversary" \
  || bad "no .claude/agents/spec-adversary.md — the Phase 2 review has no reviewer"
BRIEF=$(tr '\n' ' ' < .claude/agents/spec-adversary.md 2>/dev/null | tr -s ' ')
# 'designed it differently' is the rule that stops a design reviewer from
# proposing a new architecture every run; 'manufacture' and 'sound' are the same
# counterweights the code adversary carries.
for want in 'not to approve it' 'Do not manufacture findings' 'designed it differently' 'sound'; do
  if printf '%s' "$BRIEF" | grep -qF "$want"; then
    ok "spec-adversary brief carries: '$want'"
  else
    bad "spec-adversary brief is missing: '$want'"
  fi
done

WORKFLOW=$(tr '\n' ' ' < .claude/skills/spec-driven/SKILL.md 2>/dev/null | tr -s ' ')
for want in 'spec-adversary' 'You do not review your own spec' 'Before the tests, not after'; do
  if printf '%s' "$WORKFLOW" | grep -qF "$want"; then
    ok "the workflow demands the spec review: '$want'"
  else
    bad "spec-driven no longer instructs the spec review: '$want' is gone"
  fi
done

group "status and off answer to /spec-driven, not only /spec-phase"
# The escape hatches were on /spec-phase alone, which a user who typed
# /spec-driven has no reason to know exists — so "where am I" and "stop" had no
# reachable spelling from the command they actually used. These pin the two
# words onto the workflow skill, and pin the one property that keeps `off` from
# becoming a command the model can reach for.
#
# The two words are pinned as their dispatch ROWS, not as the bare words. Both
# already appear all over this file — `phase.sh status`, "`off` is never yours" —
# so `grep -F status` passes with the whole section deleted. Confirmed by
# deleting it: 3 of these 6 cases stayed green, which is the vacuous-test failure
# `phase.sh red` exists to catch, arriving in the suite that polices it.
for want in 'Two of those words are not a task' \
            '| `status` | `phase.sh status` |' \
            '| `off` | the close-out question below |'; do
  if printf '%s' "$WORKFLOW" | grep -qF "$want"; then
    ok "the workflow dispatches on '$want'"
  else
    bad "spec-driven no longer answers to '$want' — the escape hatch is unreachable again"
  fi
done

# `off` here is the close-out QUESTION, not `phase.sh off`. A dispatch table that
# ran the bare command would hand the model the one transition the whole design
# reserves to the user, through a door marked "the user typed it" — and a model
# that auto-invoked this skill would be holding that door.
if printf '%s' "$WORKFLOW" | grep -qF 'ask close-out' \
   && printf '%s' "$WORKFLOW" | grep -qF '`off` is still not yours'; then
  ok "typed 'off' routes through the close-out question, and says why"
else
  bad "spec-driven's 'off' is not pinned to the close-out question — it can degrade to phase.sh off"
fi

# The split has to be stated, or the next edit adds `red` and `ask` here too and
# the two skills quietly become one with two names.
if printf '%s' "$WORKFLOW" | grep -qF '/spec-phase'; then
  ok "the workflow points past its two words at the full control surface"
else
  bad "spec-driven never names /spec-phase — a user wanting 'red' or a phase number is stranded"
fi

# The frontmatter is the only part of this a user sees before they type, so a
# dispatch the argument hint does not advertise is a dispatch nobody finds.
if grep -qE '^argument-hint:.*status.*off' "$SRC/skills/spec-driven/SKILL.md"; then
  ok "argument-hint advertises status and off"
else
  bad "argument-hint does not mention status/off — the commands exist but are undiscoverable"
fi

group "The shim: one stable path over a central install"
# spec-gate installs centrally and is used across many projects, so there is no
# stable path to hardcode — the plugin's own copy sits at a versioned cache path
# that moves on every update. Under a plugin install .claude/hooks/ does not
# exist at all, and every command both skills named died with exit 127. The shim
# gives each project one spelling that every doc, every permissions.ask rule and
# every hook message already uses.
setup_repo
SHIM_HOME="$WORK/shimhome"; rm -rf "$SHIM_HOME"
# Two versions, and the ORDER they are written in is the whole test. 0.10.0 goes
# down first so it is the older by mtime, and it also sorts lexically FIRST
# ("0.1" < "0.9"). So a name-ordered lookup picks 0.10.0 and a time-ordered one
# picks 0.9.0, and only then does the assertion below distinguish them.
#
# Written the other way round — 0.9.0 first — both orderings return 0.10.0 and
# the case passes whichever is implemented, which is what it did until a mutation
# run caught it.
#
# mtime is the right key rather than version order: it tracks what was installed
# most recently, which is what Claude Code is actually running, and that includes
# a deliberate downgrade.
for v in 0.10.0 0.9.0; do
  mkdir -p "$SHIM_HOME/.claude/plugins/cache/vavly-skills/spec-gate/$v"
  cp -R "$SRC/hooks" "$SHIM_HOME/.claude/plugins/cache/vavly-skills/spec-gate/$v/hooks"
  sleep 1
done

SHIMREPO="$WORK/shimrepo"; rm -rf "$SHIMREPO"
mkdir -p "$SHIMREPO/.claude/hooks" "$SHIMREPO/src/deep"
cp "$SRC/hooks/phase-shim.sh" "$SHIMREPO/.claude/hooks/phase.sh"
( cd "$SHIMREPO" && git init -q . && git config user.email t@example.com \
    && git config user.name test ) >/dev/null 2>&1

# CLAUDE_PROJECT_DIR is unset for Bash tool calls, and setup_repo exports it —
# leaving it set would test the one case that never reaches the shim's fallback.
shim() { ( cd "$1" && unset CLAUDE_PROJECT_DIR && HOME="$SHIM_HOME" \
           bash "$SHIMREPO/.claude/hooks/phase.sh" "${@:2}" 2>&1 ); }

OUT=$(shim "$SHIMREPO" start demo)
printf '%s' "$OUT" | grep -q "phase 1" \
  && ok "the shim resolves the plugin copy and runs it" \
  || bad "the shim did not run phase.sh under a plugin-only install: $OUT"

# The split-brain case. CLAUDE_PROJECT_DIR is set for hooks but NOT for Bash tool
# calls, so a $PWD fallback wrote a second .spec-phase wherever the caller stood
# while every hook kept reading the one at the root. Two state files, and the one
# being enforced is not the one being written.
shim "$SHIMREPO/src/deep" status >/dev/null 2>&1
NSTATE=$(find "$SHIMREPO" -name '.spec-phase' | wc -l | tr -d ' ')
if [ "$NSTATE" = 1 ] && [ -f "$SHIMREPO/.claude/.spec-phase" ]; then
  ok "invoked from a subdirectory, state still lands at the repo root"
else
  bad "subdirectory invocation forked the phase state — $NSTATE .spec-phase files found"
fi

OUT=$(cd "$SHIMREPO" && unset CLAUDE_PROJECT_DIR && HOME="$SHIM_HOME" bash -x .claude/hooks/phase.sh status 2>&1 \
      | grep -o 'spec-gate/[0-9.]*/hooks/phase.sh' | head -1)
case "$OUT" in
  *0.9.0*)  ok "resolution picks the newest version by mtime, not by name" ;;
  *0.10.0*) bad "resolution picked 0.10.0 — that is the lexically-first version, not the newest installed" ;;
  *) bad "resolution picked nothing: '$OUT'" ;;
esac

# The shim exports CLAUDE_PROJECT_DIR before exec'ing, so the above never reaches
# phase.sh's OWN fallback — which is the one a manual install depends on, and the
# one that used to be a bare $PWD. Exercise it directly, the way a Bash tool call
# would: no shim, no CLAUDE_PROJECT_DIR, standing in a subdirectory.
DIRECT="$WORK/directrepo"; rm -rf "$DIRECT"
mkdir -p "$DIRECT/src/deep"
( cd "$DIRECT" && git init -q . && git config user.email t@example.com \
    && git config user.name test ) >/dev/null 2>&1
( cd "$DIRECT/src/deep" && unset CLAUDE_PROJECT_DIR \
    && bash "$SRC/hooks/phase.sh" start direct ) >/dev/null 2>&1
if [ -f "$DIRECT/.claude/.spec-phase" ] && [ ! -f "$DIRECT/src/deep/.claude/.spec-phase" ]; then
  ok "phase.sh run directly from a subdirectory still writes state at the repo root"
else
  bad "phase.sh wrote state beside the caller, not at the repo root — the hooks read the other one"
fi

OUT=$(cd "$SHIMREPO" && unset CLAUDE_PROJECT_DIR && HOME="$WORK/no-such-home" bash .claude/hooks/phase.sh status 2>&1)
RC=$?
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'cannot find'; then
  ok "with no plugin installed the shim fails loudly instead of exiting quiet"
else
  bad "the shim was silent with no plugin — a no-op reads as 'nothing is wrong': rc=$RC $OUT"
fi

group "One reviewer session per subject, resumed across rounds"
# All of this is text in four files and nothing executes any of it, so an edit can
# hollow it out silently. Pin the two halves that make reuse a review rather than
# a conversation with someone who already agrees with you: the reviewer accounts
# for its prior findings, and it does not accept a fix on the grounds that the fix
# is what it asked for.
# `adversary` is not in this loop: its procedure moved into the adversarial-review
# skill, and the group above checks the same rules there. `spec-adversary` still
# carries its own brief inline, because a spec review has no meaning outside the
# workflow that produces specs and so was never split out.
for f in spec-adversary; do
  BRIEF=$(tr '\n' ' ' < "$SRC/agents/$f.md" 2>/dev/null | tr -s ' ')
  # 'empty `git diff`' is the one that stops the staging convention failing in the
  # dangerous direction: staged after fixing, reviewer sees an untouched tree, and
  # "nothing moved" reads as nothing to re-review.
  for want in 'Follow-up rounds' 'not re-checked' 'because it is the one you asked for' \
              'Do not pad a later round' 'claim to check, not a report to accept' \
              'If nothing is staged' 'empty `git diff` is not evidence' \
              'nothing appears to have moved'; do
    if printf '%s' "$BRIEF" | grep -qF "$want"; then
      ok "$f brief handles follow-up rounds: '$want'"
    else
      bad "$f brief is missing the follow-up rule: '$want'"
    fi
  done
  # Same reason the agent *sets* are compared above: a brief that differs per host
  # is a brief that drifts, and the drift shows up as one host reviewing fixes
  # cold while the README claims both do not.
  #
  # The line count is asserted first because two *missing* sections compare equal:
  # a diff of two empty streams passes, which would turn a deleted section into a
  # green test. Caught by making exactly that mistake by hand.
  claude_fu=$(awk '/^## Follow-up rounds$/{f=1} f' "$SRC/agents/$f.md")
  cursor_fu=$(awk '/^## Follow-up rounds$/{f=1} f' "$SRC/cursor/agents/$f.md")
  if [ "$(printf '%s\n' "$claude_fu" | wc -l)" -lt 20 ]; then
    bad "$f has no follow-up section to compare"
  elif [ "$claude_fu" = "$cursor_fu" ]; then
    ok "$f follow-up section is identical in .claude and .cursor"
  else
    bad "$f follow-up section has drifted between the two hosts"
  fi
done

# The workflow owns three things the block message cannot say: that there are two
# sessions and they never merge, that later rounds resume rather than respawn, and
# that a slice boundary resets both.
for want in 'The two reviewer sessions' 'SendMessage' 'The two never merge' \
            'Both reviewer sessions end at the boundary' 'no live design session' \
            'The index is the reviewer'; do
  if printf '%s' "$WORKFLOW" | grep -qF "$want"; then
    ok "the workflow pins the session rule: '$want'"
  else
    bad "spec-driven no longer pins the session rule: '$want' is gone"
  fi
done

# This replaced 'Never stage between fixing and messaging', and it is the stronger
# rule rather than a weaker one: that phrasing forbade one ordering, this forbids
# the caller touching the index at all. Every ordering that breaks the bookmark
# starts with a `git add` the hook did not make, so the superset is the right ban —
# and the earlier, narrower version is what shipped while the convention was
# breaking three times in a week.
for want in 'do not run `git add` during a review round, at all' \
            'review-bookmark.sh'; do
  if printf '%s' "$WORKFLOW" | grep -qF "$want"; then
    ok "the workflow hands staging to the hook: '$want'"
  else
    bad "spec-driven no longer keeps the caller out of the index: '$want' is gone"
  fi
done

# `status` is the post-compaction re-read, and compaction is the one event that
# loses a session handle — so it has to say what to do about that unprompted.
# Captured before matching, for the pipefail reason documented at st() below.
setup_repo
phase start sessions; phase 2; phase 3
S=$(.claude/hooks/phase.sh status 2>/dev/null)
printf '%s' "$S" | grep -qi 'started cold' \
  && ok "Phase 3 status says what to do with a lost session handle" \
  || bad "Phase 3 status no longer mentions reusing the spec reviewer"
phase 4; phase 5
S=$(.claude/hooks/phase.sh status 2>/dev/null)
printf '%s' "$S" | grep -qi 'same session' \
  && ok "Phase 5 status points later rounds at the same session" \
  || bad "Phase 5 status no longer mentions the code reviewer session"

group "Slice position"
setup_repo
phase start sliced
# A task nobody sliced must be indistinguishable from the old single-pass
# workflow, output included — otherwise everyone pays for a feature they did not
# ask for.
grep -q '^slice=1/1$' .claude/.spec-phase \
  && ok "start writes slice=1/1" || bad "start did not write a slice field"

# Capture before matching, never `phase.sh status | grep -q`. Under `pipefail`
# grep -q exits on the matching line, SIGPIPEs phase.sh mid-output, and the
# pipeline reports 141 — so a *successful* match reads as failure whenever the
# match is not on the last line. Silent, and it inverts the assertion.
st() { .claude/hooks/phase.sh status 2>/dev/null; }

# Matched on the reported shape, not the bare word: the task is called 'sliced'
# and `(task: sliced)` contains it.
printf '%s' "$(st)" | grep -qiE 'slice [0-9]+ of' \
  && bad "status mentions slices for a 1/1 task" || ok "1/1 says nothing about slices"

.claude/hooks/phase.sh slices 4 >/dev/null 2>&1
grep -q '^slice=1/4$' .claude/.spec-phase \
  && ok "slices 4 sets the total, keeps the position" || bad "slices 4 did not set 1/4"
printf '%s' "$(st)" | grep -q 'slice 1 of 4' \
  && ok "status reports slice 1 of 4" || bad "status does not report the slice"

# The task name survived a write that had nothing to do with it — the reason the
# state file is written from one place.
grep -q '^task=sliced$' .claude/.spec-phase \
  && ok "slices preserves the task name" || bad "slices dropped the task name"

for bad_n in 0 -1 abc ''; do
  if .claude/hooks/phase.sh slices "$bad_n" >/dev/null 2>&1; then
    bad "slices accepted '$bad_n'"
  else
    ok "slices rejects '$bad_n'"
  fi
done

# Absent reads as 1/1; malformed fails closed. A bad value cannot come from the
# user — the guard denies every write to this file — so it means corruption.
printf 'phase=3\ntask=t\n' > .claude/.spec-phase
printf '%s' "$(st)" | grep -qi 'corrupt' \
  && bad "absent slice field reported as corrupt" || ok "absent slice field reads as 1/1"
for junk in 'abc' '2/' '/5' '0/3' '4/2' '1/2/3'; do
  printf 'phase=3\ntask=t\nslice=%s\n' "$junk" > .claude/.spec-phase
  if printf '%s' "$(st)" | grep -qi 'corrupt'; then
    ok "slice='$junk' fails closed"
  else
    bad "slice='$junk' was accepted"
  fi
done
printf 'phase=4\ntask=t\nslice=2/2\n' > .claude/.spec-phase
.claude/hooks/phase.sh slices 1 >/dev/null 2>&1 \
  && bad "slices dropped the total below the current slice" \
  || ok "slices refuses a total below the current slice"

group "The slice boundary is a commit [5 -> 3]"
setup_repo
phase start sliced
.claude/hooks/phase.sh slices 3 >/dev/null 2>&1
printf 'phase=5\ntask=sliced\nslice=1/3\n' > .claude/.spec-phase

# Dirty tree: the next slice would fold this diff into its baseline and the
# review gate would never see it again. That is the escape Phase 5 exists to
# block, so the boundary has to refuse.
echo 'unreviewed' > src/leftover.ts
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh 3')")
if printf '%s' "$reason" | grep -qi 'not been reviewed and committed'; then
  ok "5 -> 3 denied while a diff is owed review"
else
  bad "5 -> 3 allowed with an unreviewed diff: '$reason'"
fi

# Staging is not committing. The workflow stages on every review round, so a
# boundary that accepted a staged tree would open the escape above on the most
# routine action in the loop.
git add -A >/dev/null 2>&1
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh 3')")
if printf '%s' "$reason" | grep -qi 'not been reviewed and committed'; then
  ok "5 -> 3 still denied when the diff is only staged"
else
  bad "5 -> 3 accepted a staged tree as committed: '$reason'"
fi

git commit -qm "slice 1" >/dev/null 2>&1
out=$(pl_bash '.claude/hooks/phase.sh 3' | .claude/hooks/phase-guard.sh)
if [ -z "$out" ]; then
  ok "5 -> 3 allowed once the slice is committed"
else
  bad "5 -> 3 blocked on a clean tree: $(printf '%s' "$out" | head -c 120)"
fi
.claude/hooks/phase.sh 3 >/dev/null 2>&1
grep -q '^slice=2/3$' .claude/.spec-phase \
  && ok "5 -> 3 advances the slice position" || bad "slice position did not advance"

# The last slice has no next one. Closing out is `off`, which is the user's.
printf 'phase=5\ntask=sliced\nslice=3/3\n' > .claude/.spec-phase
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh 3')")
[ -n "$reason" ] && ok "5 -> 3 denied on the final slice" \
                 || bad "5 -> 3 allowed past the final slice"
# Every other move off 5 stays denied, sliced or not.
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh 4')")
[ -n "$reason" ] && ok "5 -> 4 still denied" || bad "5 -> 4 escaped the review gate"
printf 'phase=5\ntask=sliced\nslice=1/3\n' > .claude/.spec-phase
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh 2')")
[ -n "$reason" ] && ok "5 -> 2 still denied mid-slice" || bad "5 -> 2 escaped the review gate"

group "Changing the total after approval is the user's"
setup_repo
phase start sliced
# Phase 1-2: the spec is not approved, so neither is the count in it.
for p in 1 2; do
  phase "$p"
  out=$(pl_bash '.claude/hooks/phase.sh slices 5' | .claude/hooks/phase-guard.sh)
  [ -z "$out" ] && ok "slices is silent at phase $p" \
                || bad "slices prompted at phase $p, before the spec was approved"
done
# Phase 3+: the total is part of what was approved at 2 -> 3.
for p in 3 4 5; do
  printf 'phase=%s\ntask=sliced\nslice=1/5\n' "$p" > .claude/.spec-phase
  d=$(pl_bash '.claude/hooks/phase.sh slices 8' | .claude/hooks/phase-guard.sh \
      | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("hookSpecificOutput",{}).get("permissionDecision",""))
except Exception: print("")' 2>/dev/null)
  [ "$d" = ask ] && ok "slices asks at phase $p" || bad "slices did not ask at phase $p (got '$d')"
done
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh slices 8')")
for want in 'MORE WORK' 'retreat to Phase 2' 'checklist'; do
  printf '%s' "$reason" | grep -qF "$want" \
    && ok "the slices prompt says: '$want'" \
    || bad "the slices prompt is missing: '$want'"
done

group "Closing out names the unfinished slices"
setup_repo
phase start sliced
printf 'phase=5\ntask=sliced\nslice=2/5\n' > .claude/.spec-phase
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh off')")
if printf '%s' "$reason" | grep -q 'slice 2 of 5'; then
  ok "the close-out prompt names the slice position"
else
  bad "close-out does not mention the unfinished slices: '$reason'"
fi
printf '%s' "$reason" | grep -q '3 more are unimplemented' \
  && ok "close-out counts what is left" || bad "close-out does not count the remainder"
printf 'phase=5\ntask=sliced\nslice=5/5\n' > .claude/.spec-phase
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh off')")
printf '%s' "$reason" | grep -qi 'unimplemented' \
  && bad "close-out warns about slices on a finished task" \
  || ok "a finished task closes out without a slice warning"

group "Untracked fixes are re-reviewed [#2]"
setup_repo
phase off
echo 'export const f = (a) => a.length' > src/newfeature.ts   # untracked
expect_gate "new untracked file blocks" 2
echo 'export const f = (a) => { if (!a) throw new Error(); return a.length }' > src/newfeature.ts
expect_gate "changed untracked content re-blocks [#2]" 2
expect_gate "unchanged untracked content passes" 0

group "Review gate defers to the workflow"
setup_repo
echo 'change' >> src/x.ts
phase start v; phase 4
expect_gate "phase 4 defers review" 0
phase 5
expect_gate "phase 5 owes review" 2

group "Stop scan catches writes the guard never saw"
setup_repo
phase start v
phase 3                                     # baseline: clean tree
printf 'sneaky\n' > src/evil.ts             # written without passing the guard
expect_gate "production file during Phase 3 is caught" 2
rm -f src/evil.ts
printf 'test change\n' >> src/x.test.ts
expect_gate "test file during Phase 3 is fine" 0

group "Stop scan respects the phase-entry baseline"
setup_repo
echo 'dirty before the phase started' >> src/x.ts
phase start v
phase 3                                     # baseline captures src/x.ts as dirty
expect_gate "pre-existing dirt is not blamed on the phase" 0
echo 'changed during phase 3' >> src/x.ts
expect_gate "further change to the same file is caught" 2

group "Spec docs do not arm the review gate"
# Observed in real use: after the code shipped, one uncommitted spec doc kept the
# gate armed indefinitely, and committing byte-identical work re-armed it because
# `git diff HEAD` empties as HEAD moves.
setup_repo
phase off
expect_gate "clean tree is quiet" 0
printf 'the spec\n' > docs/specs/task.md
expect_gate "a spec doc alone does not arm the gate" 0
printf 'the spec, corrected\n' > docs/specs/task.md
expect_gate "editing a spec doc costs no review cycle" 0
echo 'code change' >> src/x.ts
expect_gate "code alongside a spec doc still arms it" 2
git add -A >/dev/null 2>&1; git commit -qm work
expect_gate "after committing, the leftover spec stays quiet" 0

setup_repo
phase off
printf '\n' > .claude/spec-gate-review-exclude     # empty = nothing extra excluded
expect_gate "writing a config file does not arm the gate" 0
printf 'the spec\n' > docs/specs/task.md
expect_gate "an empty exclude file restores gating on specs" 2

setup_repo
phase off
printf 'src/generated\n' > .claude/spec-gate-review-exclude
mkdir -p src/generated
printf 'machine written\n' > src/generated/out.ts
expect_gate "a custom exclude path is honoured" 0
echo 'hand written' >> src/x.ts
expect_gate "non-excluded code still arms it" 2

group "RED verification — phase.sh red"
cur_phase() { sed -n 's/^phase=//p' .claude/.spec-phase 2>/dev/null | head -1; }
red() { # <label> <expect-rc> <expect-substring>
  local out rc; out=$(.claude/hooks/phase.sh red 2>&1); rc=$?
  if [ "$rc" = "$2" ] && printf '%s' "$out" | grep -qi "$3"; then
    ok "$1"
  else
    bad "$1 — rc=$rc (want $2); output: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
  fi
}
receipt() { [ -f .claude/.spec-red ] && echo yes || echo no; }

setup_repo; phase start v; phase 3
printf 'exit 1\n' > .claude/spec-gate-test-cmd      # tests fail = RED
printf 'a new test\n' > src/feature.test.ts
red "tests fail: RED verified" 0 "RED verified"
[ "$(receipt)" = yes ] && ok "a receipt is written on RED" || bad "no receipt after a verified RED"
[ "$(cur_phase)" = 3 ] && ok "red does not advance the phase" || bad "red advanced to $(cur_phase)"

setup_repo; phase start v; phase 3
printf 'exit 0\n' > .claude/spec-gate-test-cmd      # tests pass = vacuous
printf 'a new test\n' > src/feature.test.ts
red "tests pass: REFUSED" 1 "REFUSED"
[ "$(receipt)" = no ] && ok "no receipt when the tests passed" || bad "receipt written for passing tests"

setup_repo; phase start v; phase 3
printf 'exit 1\n' > .claude/spec-gate-test-cmd
printf 'prod only\n' > src/untested.ts              # no test file touched
red "no tests written: REFUSED" 1 "no test files changed"

setup_repo; phase start v; phase 3
printf 'echo "GOT:[$SPEC_GATE_TEST_FILES]"; exit 1\n' > .claude/spec-gate-test-cmd
printf 'a new test\n' > src/feature.test.ts
out=$(.claude/hooks/phase.sh red 2>&1)
if printf '%s' "$out" | grep -q 'GOT:\[.*src/feature.test.ts.*\]'; then
  ok "the changed test files are passed to the command"
else
  bad "SPEC_GATE_TEST_FILES not populated: $(printf '%s' "$out" | grep GOT: | head -1)"
fi

setup_repo; phase start v; phase 4
printf 'exit 1\n' > .claude/spec-gate-test-cmd
red "red outside Phase 3 is refused" 1 "Phase 3"

group "The receipt gates the 3 -> 4 prompt"
# The whole point of the receipt: the model verifies, the user approves, and
# between those two acts the tests must not move.
setup_repo; phase start v; phase 3
printf 'exit 1\n' > .claude/spec-gate-test-cmd
printf 'a new test\n' > src/feature.test.ts
expect_b "3 -> 4 denied before red runs"    DENY '.claude/hooks/phase.sh 4'
.claude/hooks/phase.sh red >/dev/null 2>&1
expect_b "3 -> 4 prompts once RED is on file" ASK '.claude/hooks/phase.sh 4'

reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh 4')")
if printf '%s' "$reason" | grep -qi 'reason the spec expects\|failed for the reason'; then
  ok "the 3 -> 4 prompt says what the check does NOT prove"
else
  bad "3 -> 4 ask reason does not qualify the claim: '$reason'"
fi
if printf '%s' "$reason" | grep -q '"'; then
  bad "3 -> 4 ask reason contains a raw double quote — would break hand-built JSON"
else
  ok "3 -> 4 ask reason is JSON-safe"
fi

# Verify RED, then edit the test green. The receipt must not still vouch for it.
printf 'a new test, quietly rewritten\n' > src/feature.test.ts
expect_b "editing a test after RED voids the prompt" DENY '.claude/hooks/phase.sh 4'
out=$(.claude/hooks/phase.sh status 2>&1)
printf '%s' "$out" | grep -qi 'STALE' && ok "status reports the stale receipt" \
  || bad "status did not report a stale receipt: $(printf '%s' "$out" | tr '\n' ' ')"

# A second test file appearing after verification is equally unvouched-for.
setup_repo; phase start v; phase 3
printf 'exit 1\n' > .claude/spec-gate-test-cmd
printf 'a new test\n' > src/feature.test.ts
.claude/hooks/phase.sh red >/dev/null 2>&1
printf 'another test\n' > src/second.test.ts
expect_b "an unverified extra test voids the prompt" DENY '.claude/hooks/phase.sh 4'

# Retreating into Phase 3 to fix the tests must not ride the old receipt.
setup_repo; phase start v; phase 3
printf 'exit 1\n' > .claude/spec-gate-test-cmd
printf 'a new test\n' > src/feature.test.ts
.claude/hooks/phase.sh red >/dev/null 2>&1
phase 2; phase 3
expect_b "a phase change discards the receipt" DENY '.claude/hooks/phase.sh 4'

group "The gates are asked as questions, and the answer is a receipt"
# The three decisions that are the user's arrive as an AskUserQuestion rather
# than as a permission prompt on a shell command. What makes that a gate and not
# decoration is that the ANSWER comes back through the host: approval-receipt.sh
# sees it, phase-guard.sh reads the receipt, and the model is nowhere in that
# path except as the thing that asked.
#
# Every case below that expects ASK is pinning the fallback. AskUserQuestion's
# result shape is not a documented contract, so the design requirement is that
# failing to recognise an answer costs the confirmation prompt this gate always
# raised — never a block.

gate_q() {
  .claude/hooks/phase.sh ask "$1" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["questions"][0]["question"])' 2>/dev/null
}

# answer <gate> <what-the-user-picked> [question-actually-asked]
answer() {
  local q; q="${3:-$(gate_q "$1")}"
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "AskUserQuestion", "cwd": sys.argv[1],
                  "tool_input": {"questions": [{"question": sys.argv[2]}]},
                  "tool_response": {"answers": {"a": sys.argv[3]}}}))' \
    "$PWD" "$q" "$2" | .claude/hooks/approval-receipt.sh >/dev/null 2>&1
}

raw_answer() { printf '%s' "$1" | .claude/hooks/approval-receipt.sh >/dev/null 2>&1; }

setup_repo; phase start v; phase 2
printf 'the spec\n' > docs/specs/demo.md

for g in spec red close-out; do
  if .claude/hooks/phase.sh ask "$g" 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "phase.sh ask $g emits a valid AskUserQuestion payload"
  else
    bad "phase.sh ask $g did not emit valid JSON"
  fi
done
# The strings are interpolated into hand-built JSON by phase.sh, exactly like the
# guard's ask reasons. A raw quote in one of them is the malformed-output bug [#6]
# arriving through a file nobody thinks of as a hook.
if .claude/hooks/phase.sh ask close-out 2>/dev/null | grep -q '\\'; then
  bad "an emitted question contains a backslash — would break hand-built JSON"
else
  ok "emitted questions are JSON-safe"
fi
expect_b "asking is allowed in every phase" ALLOW '.claude/hooks/phase.sh ask spec'
phase 5
expect_b "asking is allowed at phase 5 too"  ALLOW '.claude/hooks/phase.sh ask close-out'

# One copy of the wording. approval-receipt.sh identifies a gate by matching the
# question verbatim against phase-policy.sh, so a second copy in the skill would
# not drift into a wrong answer — it would drift into an answer nothing accepts,
# which looks exactly like a user who was never asked.
phase 2
Q=$(gate_q spec)
if [ -n "$Q" ] && ! grep -qF "$Q" "$SRC/skills/spec-driven/SKILL.md"; then
  ok "the skill points at phase.sh ask instead of copying the question"
else
  bad "the canonical question is duplicated in spec-driven/SKILL.md — it will drift"
fi
if grep -qF 'phase.sh ask' "$SRC/skills/spec-driven/SKILL.md"; then
  ok "the workflow tells the model where to get the question"
else
  bad "spec-driven/SKILL.md never mentions phase.sh ask"
fi

group "The spec gate: 2 -> 3 on an answer"
setup_repo; phase start v; phase 2
printf 'the spec\n' > docs/specs/demo.md
expect_b "unasked, the old prompt still stands"  ASK   '.claude/hooks/phase.sh 3'
answer spec 'Approve the spec'
expect_b "approved: no second prompt"            ALLOW '.claude/hooks/phase.sh 3'

answer spec 'Send the spec back'
expect_b "sent back: denied, not re-prompted"    DENY  '.claude/hooks/phase.sh 3'

# The attack the fingerprint exists for: get the answer, then change what was
# answered about. Same shape as editing a test after RED.
setup_repo; phase start v; phase 2
printf 'the spec\n' > docs/specs/demo.md
answer spec 'Approve the spec'
printf 'and one more requirement nobody approved\n' >> docs/specs/demo.md
expect_b "editing the spec after approval voids it" DENY '.claude/hooks/phase.sh 3'
# A brand-new spec document is the same event, and it is the one a fingerprint
# built from tracked files would miss [#2].
setup_repo; phase start v; phase 2
printf 'the spec\n' > docs/specs/demo.md
answer spec 'Approve the spec'
printf 'a whole second document\n' > docs/specs/extra.md
expect_b "a new spec document after approval voids it" DENY '.claude/hooks/phase.sh 3'

# Approving with nothing on disk to approve. An empty fingerprint must read as
# stale, or the answer silently covers whatever gets written next.
setup_repo; phase start v; phase 2
answer spec 'Approve the spec'
expect_b "an approval with no spec on disk is not honoured" DENY '.claude/hooks/phase.sh 3'
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh 3')")
# The first version reported this as "a spec document has changed", which was a
# lie: nothing changed, there was never a spec. A gate that misreports why it
# refused teaches people to stop reading its refusals.
if printf '%s' "$reason" | grep -qi 'nothing there to approve'; then
  ok "the refusal does not claim a document changed when none existed"
else
  bad "the empty-spec refusal misdescribes what happened: '$reason'"
fi

group "What the receipt hook refuses to record"
setup_repo; phase start v; phase 2
printf 'the spec\n' > docs/specs/demo.md

answer spec 'let me think about it'
expect_b "free-text Other records nothing"       ASK '.claude/hooks/phase.sh 3'

# The model may not ask an easier question and redeem the answer against a gate.
answer spec 'Approve the spec' 'Shall we press on?'
expect_b "a reworded question records nothing"   ASK '.claude/hooks/phase.sh 3'

# A response that echoes the options back is not a selection, and guessing which
# one was meant is exactly the kind of near-enough that turns a gate into a
# rubber stamp.
raw_answer "$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "AskUserQuestion", "cwd": sys.argv[1],
                  "tool_input": {"questions": [{"question": sys.argv[2]}]},
                  "tool_response": {"options": ["Approve the spec", "Send the spec back"]}}))' \
  "$PWD" "$(gate_q spec)")"
expect_b "an echoed option list records nothing"  ASK '.claude/hooks/phase.sh 3'

raw_answer '{"tool_name":"AskUserQuestion","tool_input":{"shape":"changed"}}'
expect_b "an unrecognised payload records nothing" ASK '.claude/hooks/phase.sh 3'
raw_answer 'not json at all'
expect_b "unparseable input records nothing"       ASK '.claude/hooks/phase.sh 3'

# An answer to one gate is not an answer to another.
answer close-out 'Disarm and leave it'
expect_b "a close-out answer does not open 2 -> 3" ASK '.claude/hooks/phase.sh 3'

# The receipt is the file that says the user said yes, so it is the one the model
# must never be able to write. Every vector, the same as the other state files.
expect_w "the approval receipt is not writable"    DENY .claude/.spec-approval
expect_b "echo into the receipt denied"            DENY 'echo verdict=approve > .claude/.spec-approval'
expect_b "cp onto the receipt denied"              DENY 'cp /tmp/x .claude/.spec-approval'
expect_b "rm of the receipt denied"                DENY 'rm .claude/.spec-approval'
expect_b "naming it at all is denied"              DENY 'cat .claude/.spec-approval'

# Answering while the workflow is off must not leave a receipt lying around for
# the next task to spend.
phase off
answer spec 'Approve the spec'
if [ ! -e .claude/.spec-approval ]; then
  ok "no receipt is written while the gate is disarmed"
else
  bad "a receipt was written with no phase file"
fi

group "An answer is spent where it was given"
setup_repo; phase start v; phase 2
printf 'the spec\n' > docs/specs/demo.md
answer spec 'Approve the spec'
phase 1; phase 2
expect_b "a phase change discards the answer" ASK '.claude/hooks/phase.sh 3'

setup_repo; phase start v; phase 2
printf 'the spec\n' > docs/specs/demo.md
answer spec 'Approve the spec'
.claude/hooks/phase.sh slices 3 >/dev/null 2>&1
expect_b "changing the slice count discards the answer" DENY '.claude/hooks/phase.sh 3'
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh 3')")
if printf '%s' "$reason" | grep -qi 'different point in this task'; then
  ok "an expired answer is reported as expired, not as a changed spec"
else
  bad "the expired-answer refusal misdescribes what happened: '$reason'"
fi

group "The RED gate needs both receipts"
setup_repo; phase start v; phase 3
printf 'exit 1\n' > .claude/spec-gate-test-cmd
printf 'a new test\n' > src/feature.test.ts
answer red 'Accept these failures'
expect_b "accepting failures nobody ran is not enough" DENY '.claude/hooks/phase.sh 4'
.claude/hooks/phase.sh red >/dev/null 2>&1
expect_b "RED alone still prompts"                     ASK  '.claude/hooks/phase.sh 4'
answer red 'Accept these failures'
expect_b "RED plus an answer: no second prompt"        ALLOW '.claude/hooks/phase.sh 4'
answer red 'One of them is broken'
expect_b "a rejected failure denies the advance"       DENY  '.claude/hooks/phase.sh 4'

setup_repo; phase start v; phase 3
printf 'exit 1\n' > .claude/spec-gate-test-cmd
printf 'a new test\n' > src/feature.test.ts
.claude/hooks/phase.sh red >/dev/null 2>&1
answer red 'Accept these failures'
printf 'quietly rewritten\n' > src/feature.test.ts
expect_b "editing a test after the answer voids it"    DENY  '.claude/hooks/phase.sh 4'

group "Close-out is three answers, not yes and no"
setup_repo; phase start v; phase 5
printf 'work\n' > src/thing.ts
expect_b "unasked, the old prompt still stands" ASK  '.claude/hooks/phase.sh off'

answer close-out 'Keep iterating'
expect_b "keep iterating is a refusal, not a declined prompt" DENY '.claude/hooks/phase.sh off'

# The ordering the old prompt could only ask for in prose. "Open a PR" means the
# PR comes first, and a tree with work still in it is the observable form of a PR
# that does not exist yet.
answer close-out 'Open a pull request'
expect_b "PR chosen with the work uncommitted: denied" DENY '.claude/hooks/phase.sh off'
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh off')")
if printf '%s' "$reason" | grep -qF 'src/thing.ts'; then
  ok "the denial names what is still uncommitted"
else
  bad "the PR-ordering denial does not say what is outstanding: '$reason'"
fi
git add -A >/dev/null 2>&1; git commit -qm work
answer close-out 'Open a pull request'
expect_b "PR chosen and the work committed: allowed"   ALLOW '.claude/hooks/phase.sh off'

answer close-out 'Disarm and leave it'
expect_b "disarm chosen: allowed"                      ALLOW '.claude/hooks/phase.sh off'

# `off` from 1-3 is equivalent to jumping to Phase 4, and no answer changes that.
phase 2
answer close-out 'Disarm and leave it'
expect_b "an answer does not unlock off from phase 2"  DENY  '.claude/hooks/phase.sh off'

group "The five transitions that used to need a terminal"
# Each existed as "go run this in your own shell" for one stated reason: a
# PreToolUse hook cannot tell a Bash call the model chose from one a slash
# command made. The receipt answers that without a terminal — it proves the USER
# answered, because the answer came back through the host and was written by a
# hook the model cannot reach.
#
# Three cases per gate, and the middle one is the point: unasked must still deny,
# or the whole mechanism is decoration.
#
#   gate           phase  command                 approve label
gate_case() {
  local gate="$1" ph="$2" cmd="$3" yes="$4" no="$5"
  setup_repo; phase start v
  [ "$ph" != 1 ] && phase "$ph"

  expect_b "$gate: denied when the user has not been asked" DENY "$cmd"

  answer "$gate" "$no"
  expect_b "$gate: denied when the user declined"           DENY "$cmd"

  setup_repo; phase start v; [ "$ph" != 1 ] && phase "$ph"
  answer "$gate" "$yes"
  expect_b "$gate: allowed once the user approved"          ALLOW "$cmd"
}

gate_case force        3 '.claude/hooks/phase.sh 4 --force'  'Unlock without RED'      'Fix the tests first'
gate_case skip         2 '.claude/hooks/phase.sh 5'          'Skip the phases between' 'Go one phase at a time'
gate_case abandon      2 '.claude/hooks/phase.sh off'        'Turn the gate off'       'Keep the gate on'
gate_case leave-review 5 '.claude/hooks/phase.sh 2'          'Leave the review behind' 'Stay in Phase 5'
gate_case restart      2 '.claude/hooks/phase.sh start other' 'Discard it and restart' 'Keep the current task'

# An answer is spent where it was given. Without this a user could approve a skip
# in Phase 2 and have it redeemed three phases later against a different jump.
setup_repo; phase start v; phase 2
answer skip 'Skip the phases between'
phase 3
expect_b "an approval does not survive the phase it was given in" DENY '.claude/hooks/phase.sh 5'

group "gate_list is the only place a gate is registered"
# The list was hardcoded in four files. A gate present in phase-policy.sh but
# missing from approval-receipt.sh's matcher is a question whose answer nothing
# redeems — indistinguishable, from the user's side, from never being asked.
setup_repo
( . "$SRC/hooks/phase-policy.sh" 2>/dev/null
  miss=0
  for g in $(gate_list); do
    [ -n "$(gate_header "$g")" ] && [ -n "$(gate_question "$g")" ] \
      && [ -n "$(gate_options "$g")" ] || { echo "$g"; miss=1; }
  done
  exit $miss ) > "$WORK/missing" 2>/dev/null
if [ -s "$WORK/missing" ]; then
  bad "gates registered but not fully defined: $(tr '\n' ' ' < "$WORK/missing")"
else
  ok "every gate in gate_list has a header, a question and options"
fi

for f in hooks/approval-receipt.sh hooks/phase.sh; do
  if grep -qF 'gate_list' "$SRC/$f"; then
    ok "$f iterates gate_list rather than its own copy"
  else
    bad "$f still hardcodes the gate names — a new gate will be half-registered"
  fi
done

# Every gate must survive the JSON hand-building in phase.sh. A tab splits the
# option fields and a quote or backslash breaks the payload outright.
setup_repo; phase start v; phase 2
badq=0
for g in $(. "$SRC/hooks/phase-policy.sh" 2>/dev/null; gate_list); do
  .claude/hooks/phase.sh ask "$g" 2>/dev/null \
    | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null || { badq=1; echo "$g"; }
done
[ "$badq" = 0 ] && ok "every gate emits a valid AskUserQuestion payload" \
                || bad "some gate emits invalid JSON (above)"

group "Answering a question is not reviewable work"
# The review gate treats untracked files as owed review, and .claude/ is
# deliberately NOT on the exclude list. So a state file the gate writes for its
# own bookkeeping must be ignored by git, or every answer arms the review gate
# against the gate's own paperwork — the "a leftover doc kept it armed" failure,
# arriving from a file the user never touched.
setup_repo; phase start v; phase 2
printf 'the spec\n' > docs/specs/demo.md
git add -A >/dev/null 2>&1; git commit -qm spec
answer spec 'Approve the spec'
if [ -e .claude/.spec-approval ]; then
  ok "the receipt was actually written (the check below means something)"
else
  bad "no receipt written — the arming check below would pass vacuously"
fi
pending=$(cd "$PWD" && .claude/hooks/phase.sh status 2>&1)
if printf '%s' "$pending" | grep -q '.spec-approval'; then
  bad "the approval receipt shows up as work owed review — add it to .gitignore"
else
  ok "the approval receipt does not arm the review gate"
fi
# The install block in the README is the only thing that puts it there, so the
# fixture and the docs have to agree or this test proves nothing about a real
# install.
for n in .spec-phase .spec-baseline .spec-red .spec-approval; do
  if grep -qF "$n" .gitignore && grep -qF "$n" "$SRC/README.md"; then
    ok "$n is gitignored by the documented install"
  else
    bad "$n is missing from .gitignore or from the README install block"
  fi
done

group "The receipt hook is registered"
if python3 -c '
import json, sys
d = json.load(open(".claude/settings.json"))
hooks = d.get("hooks", {}).get("PostToolUse", [])
sys.exit(0 if any("AskUserQuestion" in (h.get("matcher") or "")
                  and any("approval-receipt" in c.get("command", "")
                          for c in h.get("hooks", []))
                  for h in hooks) else 1)' 2>/dev/null; then
  ok "settings.json runs approval-receipt.sh on AskUserQuestion"
else
  bad "settings.json has no PostToolUse hook for AskUserQuestion — nothing records an answer"
fi
if [ -x "$SRC/hooks/approval-receipt.sh" ]; then
  ok "approval-receipt.sh is committed executable"
else
  bad "approval-receipt.sh is not executable — cp -R would install a hook that cannot run"
fi

group "phase.sh 4 in a terminal"
tw() { # <label> <expect-phase> <expect-substring> [--force]
  local out; out=$(.claude/hooks/phase.sh 4 ${4:-} 2>&1)
  if [ "$(cur_phase)" = "$2" ] && printf '%s' "$out" | grep -qi "$3"; then
    ok "$1"
  else
    bad "$1 — phase=$(cur_phase) (want $2); output: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  fi
}

setup_repo; phase start v; phase 3
printf 'a new test\n' > src/feature.test.ts
tw "unconfigured: advances, but says so" 4 "no test command configured"

setup_repo; phase start v; phase 3
printf 'exit 1\n' > .claude/spec-gate-test-cmd
printf 'a new test\n' > src/feature.test.ts
tw "no receipt: runs the check itself" 4 "RED verified"

setup_repo; phase start v; phase 3
printf 'exit 1\n' > .claude/spec-gate-test-cmd
printf 'a new test\n' > src/feature.test.ts
.claude/hooks/phase.sh red >/dev/null 2>&1
tw "a valid receipt is honoured without re-running" 4 "receipt verified"

setup_repo; phase start v; phase 3
printf 'exit 0\n' > .claude/spec-gate-test-cmd      # tests pass = vacuous
printf 'a new test\n' > src/feature.test.ts
tw "tests pass: REFUSED, still Phase 3" 3 "REFUSED"
tw "--force overrides the refusal" 4 "skipping the RED tripwire" --force

setup_repo; phase start v; phase 5
printf 'exit 0\n' > .claude/spec-gate-test-cmd      # would refuse if it ran
tw "retreat 5 -> 4 is not gated by the tripwire" 4 "Execute"

group "Cursor adapters"
# Cursor has its own hook system with its own payload shapes. These drive the
# adapters with synthetic Cursor payloads; they cannot verify Cursor's real
# field names, only that the translation is faithful to the documented schema.
cur_shell() {
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"beforeShellExecution","command":sys.argv[1],"cwd":sys.argv[2],"workspace_roots":[sys.argv[2]]}))' "$1" "$PWD"
}
cur_tool() {
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"preToolUse","tool_name":sys.argv[3],"tool_input":json.loads(sys.argv[1]),"cwd":sys.argv[2],"workspace_roots":[sys.argv[2]]}))' "$1" "$PWD" "${2:-Write}"
}
cperm() {
  printf '%s' "$1" | .claude/hooks/cursor-guard.sh 2>/dev/null | python3 -c '
import json, sys
try: print(json.load(sys.stdin).get("permission","?"))
except Exception: print("BADJSON")' 2>/dev/null
}
expect_c() { local got; got=$(cperm "$3"); [ "$got" = "$2" ] && ok "$1" || bad "$1 — expected $2, got $got"; }

setup_repo
phase off
expect_c "dormant: shell allowed"            allow "$(cur_shell 'echo hi > src/y.ts')"
expect_c "dormant: write allowed"            allow "$(cur_tool '{"file_path":"src/x.ts"}')"

phase start v; phase 3
expect_c "write with content denied"         deny  "$(cur_tool '{"file_path":"src/x.ts","content":"x"}')"
expect_c "write by tool name denied"         deny  "$(cur_tool '{"file_path":"src/x.ts"}' write_file)"
expect_c "edit with new_string denied"       deny  "$(cur_tool '{"target_file":"src/x.ts","new_string":"x"}')"
expect_c "test file write allowed"           allow "$(cur_tool '{"file_path":"src/x.test.ts","content":"x"}' write_file)"
# preToolUse fires for reads too, and a read carries a path exactly like a write.
# Treating "has a path" as a write would block reading production code in Phase 3.
expect_c "READ of production code allowed"   allow "$(cur_tool '{"path":"src/x.ts"}' read_file)"
expect_c "grep over production allowed"      allow "$(cur_tool '{"path":"src/x.ts","pattern":"foo"}' grep_search)"
expect_c "list_dir allowed"                  allow "$(cur_tool '{"path":"src"}' list_dir)"
expect_c "unknown tool shape allowed"        allow "$(cur_tool '{"pattern":"foo"}')"
expect_c "phase 3: shell write denied"       deny  "$(cur_shell 'echo hi > src/y.ts')"
expect_c "phase 3: read-only shell allowed"  allow "$(cur_shell 'cat src/x.ts')"
expect_c "3 -> 4 denied without a receipt"   deny  "$(cur_shell '.claude/hooks/phase.sh 4')"
expect_c "shell seen via preToolUse defers"  allow "$(cur_tool '{"command":".claude/hooks/phase.sh 4"}')"

phase 2
expect_c "2 -> 3 asks, on the event that can" ask  "$(cur_shell '.claude/hooks/phase.sh 3')"

phase 3
printf 'exit 1\n' > .claude/spec-gate-test-cmd
printf 'a new test\n' > src/feature.test.ts
.claude/hooks/phase.sh red >/dev/null 2>&1
expect_c "3 -> 4 asks once RED is on file"   ask   "$(cur_shell '.claude/hooks/phase.sh 4')"

phase 5
expect_c "closing out asks in Cursor too"    ask   "$(cur_shell '.claude/hooks/phase.sh off')"

cstop() {
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"stop","status":sys.argv[1],"loop_count":int(sys.argv[2]),"cwd":sys.argv[3],"workspace_roots":[sys.argv[3]]}))' "${1:-completed}" "${2:-0}" "$PWD" \
    | .claude/hooks/cursor-stop.sh 2>/dev/null
}
has_followup() { printf '%s' "$1" | grep -q 'followup_message' && echo yes || echo no; }

setup_repo
phase off
[ "$(has_followup "$(cstop completed 0)")" = no ] && ok "clean tree: no follow-up" || bad "clean tree produced a follow-up"
echo 'change' >> src/x.ts
[ "$(has_followup "$(cstop completed 0)")" = yes ] && ok "dirty tree: injects the review instruction" || bad "dirty tree produced no follow-up"
rm -f .git/claude-review-gate
[ "$(has_followup "$(cstop completed 2)")" = no ] && ok "loop_count guards against spinning" || bad "loop_count did not guard"
rm -f .git/claude-review-gate
[ "$(has_followup "$(cstop aborted 0)")" = no ] && ok "aborted turn is not judged" || bad "aborted turn produced a follow-up"

setup_repo
phase start v; phase 3
printf 'sneaky\n' > src/evil.ts
out=$(cstop completed 0)
if printf '%s' "$out" | grep -q 'PHASE GATE'; then
  ok "phase scan reaches Cursor as a follow-up"
else
  bad "phase violation did not reach Cursor: $(printf '%s' "$out" | head -c 120)"
fi

group "The two install paths register the same gate"
# There are now two copies of the wiring: settings.json for the cp -R install, and
# hooks/hooks.json for the plugin install. Two copies of the same facts drift, and
# the failure is silent in the worst way — a plugin that installs clean, registers
# four of five hooks, and enforces less than the README promises. Same reason the
# two reviewer briefs are compared across hosts byte for byte.
#
# Only the path prefix may differ: "$CLAUDE_PROJECT_DIR"/.claude/hooks/x.sh in
# settings.json, "${CLAUDE_PLUGIN_ROOT}/hooks/x.sh" in hooks.json. Event, matcher,
# script and timeout must match. The count is asserted before the comparison,
# because two empty signatures compare equal and a diff of nothing is a green test.
WIRING=$(python3 - "$SRC/settings.json" "$SRC/hooks/hooks.json" <<'PY'
import json, re, sys

def sig(hooks):
    # event -> sorted list of (matcher, script-or-raw-command, timeout)
    out = {}
    for event, entries in hooks.items():
        rows = []
        for entry in entries:
            matcher = entry.get("matcher", "")
            for h in entry.get("hooks", []):
                cmd = h.get("command", "")
                m = re.search(r'hooks/([A-Za-z0-9._-]+\.sh)', cmd)
                rows.append((matcher, m.group(1) if m else cmd, h.get("timeout")))
        out[event] = sorted(rows)
    return out

settings = json.load(open(sys.argv[1]))
plugin = json.load(open(sys.argv[2]))

a = sig(settings.get("hooks", {}))
b = sig(plugin.get("hooks", {}))

n = sum(len(v) for v in a.values())
print("COUNT %d" % n)

if set(a) == set(b):
    print("OK  both paths register the same %d events" % len(a))
else:
    only_a = ", ".join(sorted(set(a) - set(b))) or "none"
    only_b = ", ".join(sorted(set(b) - set(a))) or "none"
    print("BAD event mismatch — only in settings.json: %s; only in hooks.json: %s" % (only_a, only_b))

for event in sorted(set(a) & set(b)):
    if a[event] == b[event]:
        print("OK  %s matches across both install paths" % event)
    else:
        print("BAD %s differs: settings.json %r vs hooks.json %r" % (event, a[event], b[event]))

# The plugin copy must not reach for the project dir to find its own code, and the
# settings copy must not reach for a plugin root that a cp -R install never sets.
#
# Walk the parsed structure rather than regexing a re-dumped blob: these command
# strings contain their own quotes, so json.dumps escapes them and a
# '"command": "([^"]*)"' pattern matches nothing at all. That reads as "no
# offenders found" and passes while checking exactly zero commands.
def commands(hooks):
    out = []
    for entries in hooks.values():
        for entry in entries:
            for h in entry.get("hooks", []):
                out.append(h.get("command", ""))
    return out

plugin_cmds = [c for c in commands(plugin.get("hooks", {})) if ".sh" in c]
settings_cmds = [c for c in commands(settings.get("hooks", {})) if ".sh" in c]

if not plugin_cmds or not settings_cmds:
    print("BAD no script commands extracted (%d plugin, %d settings) — the walker broke"
          % (len(plugin_cmds), len(settings_cmds)))
else:
    print("OK  extracted %d script commands to check" % (len(plugin_cmds) + len(settings_cmds)))

    bad_root = [c for c in plugin_cmds if "CLAUDE_PLUGIN_ROOT" not in c]
    if bad_root:
        print("BAD hooks.json resolves a script outside ${CLAUDE_PLUGIN_ROOT}: %s" % bad_root[0])
    else:
        print("OK  all %d hooks.json scripts resolve through ${CLAUDE_PLUGIN_ROOT}" % len(plugin_cmds))

    bad_proj = [c for c in settings_cmds if "CLAUDE_PROJECT_DIR" not in c]
    if bad_proj:
        print("BAD settings.json resolves a script outside $CLAUDE_PROJECT_DIR: %s" % bad_proj[0])
    else:
        print("OK  all %d settings.json scripts resolve through $CLAUDE_PROJECT_DIR" % len(settings_cmds))
PY
)
while IFS= read -r line; do
  case "$line" in
    "OK  "*)  ok "${line#OK  }" ;;
    BAD*)     bad "${line#BAD }" ;;
    COUNT*)   [ "${line#COUNT }" -gt 0 ] \
                && ok "the wiring declares ${line#COUNT } hooks to compare" \
                || bad "no hooks found — the extractor broke, not the wiring" ;;
  esac
done <<< "$WIRING"

# The manifest is what makes the plugin installable at all; a plugin directory the
# marketplace does not list is a plugin nobody can reach.
MANIFEST="$SRC/.claude-plugin/plugin.json"
[ -f "$MANIFEST" ] && ok "the plugin ships .claude-plugin/plugin.json" \
  || bad "no .claude-plugin/plugin.json — /plugin install cannot see this"
if [ -f "$MANIFEST" ]; then
  PNAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$MANIFEST")
  [ "$PNAME" = "spec-gate" ] && ok "and it names itself spec-gate" \
    || bad "plugin.json name is '$PNAME', not spec-gate"
fi

################################################################################
printf '\n%s%d passed, %d failed%s\n' "$B" "$PASS" "$FAIL" "$N"
[ "$FAIL" -eq 0 ] || exit 1
