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
  printf '.claude/.spec-phase\n.claude/.spec-baseline\n.claude/.spec-red\n.claude/review-log.jsonl\n' > .gitignore
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

group "The block message sets the reviewer's stance"
# A spawn prompt that is only task intent reads as "check that this works" and
# comes back a confirmation. The framing has to survive edits to this message,
# and so does the counterweight that stops it manufacturing findings.
setup_repo
phase off
echo 'change' >> src/x.ts
# Flattened: the phrases wrap across lines in the heredoc, so a line-oriented
# grep would pin the line breaks rather than the wording.
BLOCK=$(printf '{"stop_hook_active":false}' | .claude/hooks/review-gate.sh 2>&1 >/dev/null | tr '\n' ' ' | tr -s ' ')
for want in 'adversarially reviewing' 'not to approve it' 'only thing I am telling you' 'normal outcome'; do
  if printf '%s' "$BLOCK" | grep -qF "$want"; then
    ok "block message carries: '$want'"
  else
    bad "block message is missing: '$want'"
  fi
done
# The gate fires again on the fixed diff, and that round is where a fresh spawn
# costs most: it cannot say whether the fix closed anything, because it never saw
# the finding. So the block message has to ask for the same session back, and the
# follow-up wording has to withhold as much as the first prompt did — a reviewer
# handed "here is how I fixed your finding" agrees with itself.
for want in 'same `adversary` session' 'do not spawn a second' 'Keep the handle' \
            'git add -A' 'should show the same set' \
            'Never stage between fixing and messaging' \
            'path list is the gate' 'paste the gate'; do
  if printf '%s' "$BLOCK" | grep -qF "$want"; then
    ok "block message asks for the resumed session: '$want'"
  else
    bad "block message no longer asks for session reuse: '$want' is gone"
  fi
done

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

phase start v; phase 2
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh 3')")
if printf '%s' "$reason" | grep -qi 'spec-adversary'; then
  ok "the 2 -> 3 prompt names the reviewer, so a missing verdict is visible"
else
  bad "2 -> 3 prompt does not mention the spec review: '$reason'"
fi

# Both reviewers' verdicts are worth logging, and a matcher is exact alternation
# rather than a substring — the same property that let NotebookEdit through [#5].
# So 'adversary' alone would silently stop logging the spec reviews.
if python3 -c '
import json,sys
d=json.load(open(".claude/settings.json"))
ms=[h.get("matcher","") for h in d.get("hooks",{}).get("SubagentStop",[])]
sys.exit(0 if any("spec-adversary" in m for m in ms) else 1)' 2>/dev/null; then
  ok "the review log matcher covers spec-adversary too"
else
  bad "settings.json SubagentStop matcher does not name spec-adversary"
fi

# Cursor reads .cursor/agents/, not .claude/agents/. An agent added on one side
# only is an agent the workflow names and that host cannot spawn.
a=$(cd "$SRC/agents" && ls *.md | sort)
c=$(cd "$SRC/cursor/agents" && ls *.md | sort)
[ "$a" = "$c" ] && ok "the Claude Code and Cursor agent sets match" \
  || bad "agents differ — .claude: $(echo $a) / .cursor: $(echo $c)"

group "One reviewer session per subject, resumed across rounds"
# All of this is text in four files and nothing executes any of it, so an edit can
# hollow it out silently. Pin the two halves that make reuse a review rather than
# a conversation with someone who already agrees with you: the reviewer accounts
# for its prior findings, and it does not accept a fix on the grounds that the fix
# is what it asked for.
for f in adversary spec-adversary; do
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
            'The index is the reviewer' 'Never stage between fixing and messaging'; do
  if printf '%s' "$WORKFLOW" | grep -qF "$want"; then
    ok "the workflow pins the session rule: '$want'"
  else
    bad "spec-driven no longer pins the session rule: '$want' is gone"
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

################################################################################
printf '\n%s%d passed, %d failed%s\n' "$B" "$PASS" "$FAIL" "$N"
[ "$FAIL" -eq 0 ] || exit 1
