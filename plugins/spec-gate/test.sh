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
  printf '.claude/.spec-phase\n.claude/.spec-baseline\n.claude/.spec-red\n.claude/.spec-approval*\n.claude/.spec-scaffold\n.claude/.spec-validation\n.claude/spec-journal.md\n.claude/review-log.jsonl\n' > .gitignore
  git add -A >/dev/null 2>&1; git commit -qm init
  export CLAUDE_PROJECT_DIR="$PWD"
  rm -f .git/claude-review-gate
}

# `phase 5` here is setup, never the thing under test. 4 -> 5 refuses without a
# recorded validation report, so a bare `phase 5` would otherwise silently leave
# every Phase 5 test standing in Phase 4 — which is exactly how four of them
# failed rather than telling us the tripwire worked. The tripwire has its own
# tests below; this one only needs to arrive.
phase() {
  case "${1:-}" in
    5) .claude/hooks/phase.sh 5 --force >/dev/null 2>&1 ;;
    *) .claude/hooks/phase.sh "$@" >/dev/null 2>&1 ;;
  esac
}

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

group "A '>' inside quotes is not a redirect"
# The scanner used to read the raw command text, so every '>' was an operator
# wherever it sat. The costly one in practice is the JS arrow function: the
# target it invented was whatever followed, so `c => {d+=c}` was refused as a
# write to a production file called '{d+=c}'. Each of these cost a reworded
# command that was doing nothing wrong.
expect_b "arrow fn: accumulator"      ALLOW 'node -e "let d=0; s.forEach(c => {d+=c})"'
expect_b "arrow fn: concatenation"    ALLOW 'node -e "xs.map(k => k+1)"'
expect_b "arrow fn: single quotes"    ALLOW "node -e 'xs.map(k => k+1)'"
expect_b "an arrow in a commit msg"   ALLOW 'git commit -m "refactor: parse -> validate -> emit"'
expect_b "a > inside a jq program"    ALLOW "jq '.a | map(select(.n > 3))' data.json"
expect_b "a > inside a grep pattern"  ALLOW "grep -c '^[<>]' src/x.ts"
expect_b "an awk comparison"          ALLOW "awk '\$1 > 5' src/x.ts"
expect_b "a quoted >> in prose"       ALLOW 'echo "append with >> src/x.ts"'
# Same defect, same line: the in-place-editor check also read raw text, so
# naming sed -i inside a string was refused as though it were running it.
expect_b "sed -i named in a string"   ALLOW 'git commit -m "stop using sed -i here"'
# The editor name has to be a command, not any word whose basename matches. These
# were all ALLOW before the per-word scan and DENY after it.
expect_b "a directory called ex"      ALLOW 'pytest tests/ex -s'
expect_b "a binary called ex"         ALLOW 'bin/ex -s'
expect_b "a file called patch"        ALLOW 'cat notes/patch'
expect_b "patch as a commit subject"  ALLOW 'git commit -m patch'
# ...while the real invocations stay denied, including through a dispatcher.
expect_b "sed -i through find -exec"  DENY  'find . -name "*.ts" -exec sed -i s/a/b/ {} ;'
expect_b "sed -i through xargs"       DENY  'ls | xargs sed -i s/a/b/'
# The original regex scanned raw text, so a wrapper taking its own operand made
# no difference. Keying off the verb lost these: sudo consumes `-u`, then `root`
# becomes the verb and everything after it is an argument.
expect_b "sed -i behind sudo -u"      DENY  'sudo -u root sed -i s/a/b/ src/x.ts'
expect_b "sed -i behind timeout N"    DENY  'timeout 5 sed -i s/a/b/ src/x.ts'
expect_b "sed -i behind nice -n"      DENY  'nice -n 10 sed -i s/a/b/ src/x.ts'
expect_b "perl -i behind env VAR="    DENY  'env FOO=1 perl -pi -e s/a/b/ src/x.ts'
expect_b "patch as the verb"          DENY  'patch -p1 < fix.diff'

# None of that may cost a genuine redirect. These are the cases the scanner
# exists for, and they still have to land.
expect_b "real redirect still denied"      DENY 'echo hi > src/y.ts'
expect_b "real append still denied"        DENY 'echo hi >> src/y.ts'
expect_b "quoted target still denied [#6]" DENY 'echo x > "src/a b.ts"'
expect_b "computed target still denied"    DENY 'echo x > $(mktemp)'
expect_b "sed -i actually run: denied"     DENY "sed -i '' s/a/b/ src/x.ts"
expect_b "tee still denied [#3]"           DENY 'cat /tmp/e | tee src/x.ts'
expect_b "redirect after a quoted arrow"   DENY 'echo "a -> b" > src/y.ts'
expect_b "fd dup is not a write"           ALLOW 'pytest -q > /dev/null 2>&1'
expect_b "stderr to stdout is not a write" ALLOW 'make build 2>&1 | tail -5'
expect_b "explicit >&2 is not a write"     ALLOW 'echo problem >&2'
expect_b "2>&1 is not a write"             ALLOW 'make 2>&1 | tail -1'
expect_b ">&- is not a write"              ALLOW 'exec 3>&-'
# `>&word` where word is not a descriptor is bash's synonym for `&>word`, i.e.
# a real file write. Treating every `>&` as a dup was a deliberate wrong answer.
expect_b ">&file IS a write"               DENY  'echo hi >& src/y.ts'
expect_b ">&file with no space"            DENY  'echo hi >&src/y.ts'
# `>|` overrides noclobber. Leaving the bar unconsumed made it read as a pipe,
# which ended the segment and discarded the target that was pending on it.
expect_b "noclobber override is a write"   DENY  'echo hi >| src/y.ts'
# A backslash at end of line ran off the end of the string, emitted a spurious
# empty word that swallowed the pending redirect, and the newline then ended the
# segment — so the target on the next line was filed as an ordinary argument.
# Continuing a line before a long path is idiomatic, not adversarial.
expect_b "continuation before a target"    DENY  "$(printf 'echo hi > \\\n  src/y.ts')"
expect_b "continuation with no space"      DENY  "$(printf 'echo hi >\\\nsrc/y.ts')"
expect_b "continuation before a cp dest"   DENY  "$(printf 'cp /tmp/e \\\n  src/x.ts')"
# Two more ways to desynchronise the lexer and take everything after it with
# them. `$((1<<3))` was read as a heredoc opening with delimiter `3))`, which
# never matches, so every later line was swallowed as body. An apostrophe in a
# comment opened a quote that never closed. Both were caught by the raw-text
# scanner this replaced.
expect_b "arithmetic shift is not a heredoc" DENY "$(printf 'echo $((1<<3))\necho x > src/y.ts')"
expect_b "an apostrophe in a comment"        DENY "$(printf "ls # don't\necho x > src/y.ts")"
expect_b "a comment does not eat the line"   ALLOW "$(printf 'ls -la   # writes nothing > here')"
expect_b "a hash inside a word is not one"   DENY  'echo a#b > src/y.ts'
expect_b "a real heredoc still works"        ALLOW "$(printf 'cat > docs/specs/p.md <<HD\nbody\nHD')"
expect_b "1> is a write"                   DENY  'echo hi 1> src/y.ts'
expect_b "&> is a write"                   DENY  'echo hi &> src/y.ts'

# A hook that dies emits no decision, and Claude Code reads no decision as no
# opinion — so a crash in the parser does not fail closed, it disables the Bash
# gate entirely. That is how `local s=$1 n=${#s}` (which reads an unset s under
# set -u) turned every DENY above into a silent ALLOW. Nothing here asserts a
# verdict; it asserts the guard ran at all.
for c in 'echo hi > src/y.ts' 'node -e "xs.map(k => k+1)"' 'pytest -q 2>&1' \
         "grep -c '^[<>]' src/x.ts" 'cat /tmp/e | tee src/x.ts' \
         "cat > docs/specs/p.md <<'EOF'
body -> here
EOF"; do
  err=$(pl_bash "$c" | .claude/hooks/phase-guard.sh 2>&1 >/dev/null)
  if [ -z "$err" ]; then
    ok "the guard runs clean on: $(printf '%s' "$c" | head -1 | cut -c1-38)"
  else
    bad "the guard errored (and so failed OPEN) on '$(printf '%s' "$c" | head -1)': $err"
  fi
done

group "A quoted string handed to a shell is not data"
# The tokenizer is right that a quoted `>` is not an operator. It was wrong that
# a quoted string is therefore inert: `bash -c "..."` and `eval "..."` hand it
# straight back to a shell. Every one of these was DENY before the tokenizer and
# ALLOW after it — the most obvious deliberate route around a Bash write gate,
# reopened by the fix for a different bug.
expect_b "bash -c payload is re-read"      DENY 'bash -c "echo hi > src/y.ts"'
expect_b "sh -c payload is re-read"        DENY "sh -c 'echo hi > src/y.ts'"
expect_b "eval payload is re-read"         DENY 'eval "echo hi > src/y.ts"'
expect_b "zsh -c too"                      DENY 'zsh -c "echo hi > src/y.ts"'
expect_b "nested one level deeper"         DENY 'bash -c "sh -c \"echo hi > src/y.ts\""'
expect_b "through xargs"                   DENY 'echo x | xargs -I{} sh -c "echo x > src/y.ts"'
expect_b "through find -exec"              DENY 'find . -exec sh -c "echo x > src/y.ts" ;'
# awk writes files with a redirect to a quoted literal. `$1 > 5` is a comparison
# and must stay allowed — the distinguishing shape is the quoted target.
expect_b "awk redirect to a quoted file"   DENY  'awk '"'"'BEGIN{print "x" > "src/y.ts"}'"'"''
expect_b "awk append to a quoted file"     DENY  'awk '"'"'BEGIN{print "x" >> "src/y.ts"}'"'"''
expect_b "an awk comparison still passes"  ALLOW "awk '\$1 > 5' src/x.ts"
# The payload is only shell when a shell runs it.
expect_b "a -c payload naming a test path" ALLOW 'bash -c "echo hi > src/y.test.ts"'
expect_b "an ordinary quoted arrow"        ALLOW 'git commit -m "parse -> validate"'
expect_b "a benign bash -c"                ALLOW 'bash -c "cd src && ls"'

group "The guard cannot be outrun"
# A PreToolUse hook that exceeds its timeout emits no decision, and no decision
# reads as no opinion — so a slow guard is a fail-open, not a slow gate. The
# char-by-char bash lexer was O(n^2): 20 KB took 15.3s against a 15s timeout, and
# 20 KB is an ordinary `git commit -m`, a `gh pr create --body`, or the heredoc
# plan document this workflow tells you to write.
BIG=$(python3 -c "print('x '*10000)")
START=$(python3 -c 'import time;print(time.time())')
got=$(guard "$(pl_bash "git commit -m \"$BIG\"")")
ELAPSED=$(python3 -c "import time;print(round(time.time()-$START,2))")
if [ "$(python3 -c "print(1 if $ELAPSED < 3 else 0)")" = 1 ]; then
  ok "a 20KB command is judged in ${ELAPSED}s (timeout is 15s)"
else
  bad "a 20KB command took ${ELAPSED}s — the hook times out and the gate vanishes"
fi
[ "$got" = ALLOW ] && ok "and judged correctly" || bad "a long commit message was $got"
# The same length, but as a write that must still be caught.
got=$(guard "$(pl_bash "echo \"$BIG\" > src/y.ts")")
[ "$got" = DENY ] && ok "a long command with a real redirect is still denied" \
                  || bad "length defeated the scan: got $got"

# The tokenizer runs in awk, so awk joined jq/python3 as something the guard
# needs. A dead hook emits no decision and no decision reads as no opinion, so an
# unusable awk was a silent, total fail-open of the Bash gate.
mkdir -p "$WORK/fakebin"; printf '#!/bin/sh\nexit 127\n' > "$WORK/fakebin/awk"; chmod +x "$WORK/fakebin/awk"
got=$(printf '%s' "$(pl_bash 'echo hi > src/y.ts')" | PATH="$WORK/fakebin:$PATH" .claude/hooks/phase-guard.sh 2>/dev/null \
  | python3 -c 'import json,sys
t=sys.stdin.read().strip(); print("ALLOW" if not t else json.loads(t)["hookSpecificOutput"]["permissionDecision"].upper())')
[ "$got" = DENY ] && ok "an unusable awk fails closed" \
                  || bad "with awk broken the Bash gate vanished: got $got"
rm -rf "$WORK/fakebin"

group "Heredoc bodies are data, not commands"
# Phase 3 is where the plan document gets written, and a plan names the files it
# touches. The body of a heredoc was scanned as though it were shell, so an
# arrow in a diagram or a sentence made authoring the plan via Bash impossible —
# the workflow's own instructions blocked by the gate enforcing them.
expect_b "prose naming production files" ALLOW "cat > docs/specs/plan.md <<'EOF'
## Plan
1. Edit src/parser.ts to add the new branch
2. Update config.json with the flag
EOF"
expect_b "an arrow in the body"          ALLOW "cat > docs/specs/plan.md <<'EOF'
Flow: parser -> validator -> emitter
EOF"
expect_b "a mermaid diagram in the body" ALLOW "cat > docs/specs/plan.md <<'EOF'
graph TD
  A[read] --> B[write config.json]
EOF"
expect_b "a command quoted in the body"  ALLOW "cat > docs/specs/plan.md <<'EOF'
cp src/old.ts src/new.ts
EOF"
expect_b "a redirect quoted in the body" ALLOW "cat > docs/specs/plan.md <<'EOF'
echo hi > src/y.ts
EOF"
# The heredoc's own target is still a real write target.
expect_b "heredoc onto production denied" DENY "cat > src/x.ts <<'EOF'
code
EOF"
expect_b "heredoc onto a test allowed"    ALLOW "cat > tests/new.test.ts <<'EOF'
assert(1)
EOF"
# A redirect AFTER the body has ended is shell again, not data.
expect_b "a redirect after the terminator" DENY "cat > docs/specs/plan.md <<'EOF'
prose
EOF
echo sneaky > src/y.ts"

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
#
# Every command that widens what may be written belongs here, not just the two
# numbered transitions: `scaffold` opens Phase 2 to new files, and `5 --force`
# enters review with the repo's checks unrun. Both were added to settings.json
# without this loop noticing, which is how `5 --force` shipped gated by a
# permission rule alone while every comparable override had a receipt gate.
for t in scaffold 3 4 "5 --force" off; do
  if python3 -c '
import json,sys
d=json.load(open(".claude/settings.json"))
rules=d.get("permissions",{}).get("ask",[])
sys.exit(0 if any("phase.sh "+sys.argv[1] in r for r in rules) else 1)' "$t" 2>/dev/null; then
    ok "settings.json ask rule for phase.sh $t covers bypassPermissions"
  else
    bad "settings.json has no permissions.ask rule for phase.sh $t"
  fi
  # settings.json is what a manual install copies and the README block is what a
  # human retypes under a plugin install, where settings.json is not read at all.
  # A rule in one and not the other is a gate that exists for half its users.
  if grep -qF "phase.sh $t" "$SRC/README.md"; then
    ok "and the README's permissions.ask block lists phase.sh $t"
  else
    bad "the README permissions.ask block is missing phase.sh $t"
  fi
  # The third copy, and the one that decides what real installs actually get:
  # spec-gate-install writes this array into the target repo. It was missing
  # `scaffold` while settings.json had it, so every installed repo was a rule
  # short of the shipped default.
  if grep -qF "phase.sh $t" "$SRC/skills/spec-gate-install/SKILL.md"; then
    ok "and the install skill writes an ask rule for phase.sh $t"
  else
    bad "the install skill's permissions.ask block is missing phase.sh $t"
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
# Matched with `case` rather than a pipe into grep -q. This file runs under
# pipefail, and grep -q exits on its first match, which SIGPIPEs the printf
# feeding it: the pipeline then reports 141 and the assertion fails while the
# text it wanted is sitting in the output. That race made this loop flaky —
# observed failing on '1/2/3' alone, on a run where every other case passed.
for junk in 'abc' '2/' '/5' '0/3' '4/2' '1/2/3'; do
  printf 'phase=3\ntask=t\nslice=%s\n' "$junk" > .claude/.spec-phase
  if grep -qi 'corrupt' <<< "$(st)"; then
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

group "Close-out at a slice boundary offers the next slice"
# Observed: at slice 1 of 8 the gate asked "Review is done. What happens to this
# work?" and offered PR / keep iterating / disarm. Review of slice ONE was done,
# seven slices were unbuilt, and the move that was actually next — commit, tick
# the checklist, phase.sh 3 — was not on the list. The model had to add it in
# prose underneath, which is the gate delegating its own contract to a paragraph.
#
# The guard already computed the warning for exactly this (OFF_SLICES) and then
# used it only in the no-receipt fallback, so it fired when the model skipped the
# question and stayed silent when the model asked properly.
setup_repo; phase start sliced
printf 'phase=5\ntask=sliced\nslice=1/8\n' > .claude/.spec-phase

Q=$(gate_q close-out)
printf '%s' "$Q" | grep -qi 'slice 1 of 8' \
  && ok "the close-out question names the slice it is closing" \
  || bad "close-out still claims the whole task is reviewed at slice 1 of 8: '$Q'"

OPTS=$(.claude/hooks/phase.sh ask close-out 2>/dev/null \
  | python3 -c 'import json,sys; print("\n".join(o["label"] for o in json.load(sys.stdin)["questions"][0]["options"]))' 2>/dev/null)
printf '%s' "$OPTS" | grep -qF 'Commit and open slice 2' \
  && ok "the fourth path is an option, not a caveat" \
  || bad "close-out does not offer the next slice: '$(printf '%s' "$OPTS" | tr '\n' '/')'"
# The three that were always there stay answerable: a user who types `off` at
# slice 1 still wants a way out, and removing it would trade one dead end for
# another.
for l in 'Open a pull request' 'Keep iterating' 'Disarm and leave it'; do
  printf '%s' "$OPTS" | grep -qF "$l" \
    && ok "'$l' is still on offer mid-task" \
    || bad "'$l' disappeared at a slice boundary"
done

# Choosing the next slice is not choosing to end the task, so `off` must refuse
# it the way `continue` does.
answer close-out 'Commit and open slice 2'
expect_b "opening the next slice is not a close-out" DENY '.claude/hooks/phase.sh off'
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh off')")
printf '%s' "$reason" | grep -q 'phase.sh 3' \
  && ok "the denial names the move the user actually chose" \
  || bad "the next-slice denial does not point at phase.sh 3: '$reason'"

# The two answers that DO disarm have to carry what is being abandoned. This is
# the silent half of the bug: with a receipt the guard allowed and said nothing
# about the seven slices it was ending.
git add -A >/dev/null 2>&1; git commit -qm "slice 1" >/dev/null 2>&1
for pick in 'Open a pull request' 'Disarm and leave it'; do
  answer close-out "$pick"
  expect_b "'$pick' still disarms on a clean tree" ALLOW '.claude/hooks/phase.sh off'
  reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh off')")
  printf '%s' "$reason" | grep -q '7 more are unimplemented' \
    && ok "'$pick' says what it is abandoning" \
    || bad "'$pick' disarms an 8-slice task silently: '$reason'"
done

# The last slice is the case close-out was written for, and it must not grow a
# next-slice option that goes nowhere.
printf 'phase=5\ntask=sliced\nslice=8/8\n' > .claude/.spec-phase
Q=$(gate_q close-out)
printf '%s' "$Q" | grep -qi 'slice' \
  && bad "the final slice is asked about as though more were coming: '$Q'" \
  || ok "the final slice gets the plain close-out question"
.claude/hooks/phase.sh ask close-out 2>/dev/null \
  | grep -qF 'Commit and open slice' \
  && bad "a ninth slice was offered on an 8-of-8 task" \
  || ok "no next slice is offered once the last one is reviewed"

# An unsliced task must be indistinguishable from before any of this existed.
printf 'phase=5\ntask=sliced\nslice=1/1\n' > .claude/.spec-phase
.claude/hooks/phase.sh ask close-out 2>/dev/null | grep -qiE 'slice' \
  && bad "a 1/1 task is asked about slices it never had" \
  || ok "a 1/1 task closes out with no slice wording"

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
for n in .spec-phase .spec-baseline .spec-red .spec-approval .spec-scaffold \
         .spec-validation spec-journal.md review-log.jsonl; do
  if grep -qF "$n" .gitignore && grep -qF "$n" "$SRC/README.md"; then
    ok "$n is gitignored by the documented install"
  else
    bad "$n is missing from .gitignore or from the README install block"
  fi
  # The install skill is the third copy of this list and the one users actually
  # run, so it has to carry every name too. Two of these were added to the
  # fixture and the README and missed here, which is the drift this catches.
  if grep -qF "$n" "$SRC/skills/spec-gate-install/SKILL.md"; then
    ok "$n is in the install skill's .gitignore block"
  else
    bad "$n is missing from the install skill's .gitignore block"
  fi
  # And this repo's own .gitignore, which is not a copy of the docs but a real
  # install of them. It shipped without .spec-scaffold for two releases: the
  # gate then treats its own untracked state as work owed review, arms on it,
  # and cannot be cleared by any commit because the path is ignored by design.
  if grep -qF "$n" "$SRC/../../.gitignore"; then
    ok "$n is gitignored in spec-gate's own repository"
  else
    bad "$n is missing from this repository's .gitignore — the gate will arm on it"
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
    # event -> sorted list of (matcher, script + its arguments, timeout)
    #
    # The argument tail is part of the signature, not noise to strip. phase.sh is
    # both the CLI and the SessionStart hook, so which script runs no longer says
    # what the hook does — `phase.sh brief` and `phase.sh status` are the same
    # script and different features. Reducing to the basename compared them equal.
    out = {}
    for event, entries in hooks.items():
        rows = []
        for entry in entries:
            matcher = entry.get("matcher", "")
            for h in entry.get("hooks", []):
                cmd = h.get("command", "")
                m = re.search(r'hooks/([A-Za-z0-9._-]+\.sh)(.*)$', cmd)
                if m:
                    # The path prefix legitimately differs between the two
                    # installs; everything after the script name must not. A
                    # trailing quote belongs to the prefix's own quoting
                    # ("...phase.sh" brief vs "...phase.sh brief").
                    tail = m.group(2).lstrip('"').strip()
                    ident = (m.group(1) + " " + tail).strip()
                else:
                    ident = cmd
                rows.append((matcher, ident, h.get("timeout")))
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

# A self-check on the comparator itself. Every other registration is identified
# by which script runs; SessionStart is the one whose behaviour is decided by an
# argument, because phase.sh is both the CLI and the hook. A signature that stops
# at the basename compares `phase.sh brief` equal to `phase.sh status`, so the
# two installs could disagree about what the hook DOES and this group would still
# be green — the drift it exists to catch, invisible to it.
import copy

mutated = copy.deepcopy(settings.get("hooks", {}))
touched = False
for entry in mutated.get("SessionStart", []):
    for h in entry.get("hooks", []):
        if " brief" in h.get("command", ""):
            h["command"] = h["command"].replace(" brief", " status")
            touched = True

if not touched:
    print("BAD no SessionStart command carrying 'brief' — this self-check checks nothing")
elif sig(mutated) == a:
    print("BAD the wiring comparison cannot tell 'phase.sh brief' from 'phase.sh status'")
else:
    print("OK  the wiring comparison reads the hook's arguments, not only its script")
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

group "RED classifies the failure, not just the exit code"
# `phase.sh red` treated any non-zero exit as "the tests failed", which certifies
# two things that are not a failing test:
#
#   a runner that never ran   — a typo'd or uninstalled test command exits 127,
#                               and the receipt recorded RED for a suite that
#                               produced no evidence at all. No pipeline needed.
#   a missing module          — every new-module test fails identically whatever
#                               it asserts, which is the hole scaffold exists to
#                               close. Reaching assertion-red is not the same as
#                               being required to.
setup_repo; phase start t; phase 3
kind() { # <label> <test-cmd> <expect: RED|REFUSED> [expect-substring]
  printf '%s\n' "$2" > .claude/spec-gate-test-cmd
  printf 'changed %s\n' "$RANDOM" > tests/probe.test.ts
  local out; out=$(.claude/hooks/phase.sh red 2>&1)
  local got; case "$out" in *"RED verified"*) got=RED ;; *REFUSED*) got=REFUSED ;; *) got=OTHER ;; esac
  if [ "$got" = "$3" ] && { [ -z "${4:-}" ] || printf '%s' "$out" | grep -qi "$4"; }; then
    ok "$1"
  else
    bad "$1 — got $got (want $3): $(printf '%s' "$out" | grep -iE 'REFUSED|RED verified|did not run' | head -1)"
  fi
}

kind "a green suite is still refused"        'true'                              REFUSED 'PASSED'
kind "a runner that does not exist"          'no-such-test-runner -q'            REFUSED 'did not run'
kind "a runner that is not executable"       'exit 126'                          REFUSED 'did not run'
kind "shell 'command not found' in output"   'printf "sh: nope: command not found\n" >&2; exit 1' REFUSED 'did not run'
kind "a missing module is not a failing test" 'printf "ModuleNotFoundError: No module named src.parser\n"; exit 1' REFUSED 'scaffold'
kind "a real assertion failure is RED"       'printf "AssertionError: 1 != 2\n"; exit 1' RED 'RED verified'
# pipefail: the suite failed but the last pipeline stage swallowed it. Without
# it the gate read the tail's 0 and reported the failing suite as PASSED.
kind "a failure behind a pipe still counts"  'printf "AssertionError\n"; exit 1 | tail -1' RED 'RED verified'

# The receipt says which kind of red it saw, so the claim it carries is the one
# that was actually established.
grep -q '^kind=assertion$' .claude/.spec-red \
  && ok "the receipt records that the failure was an assertion" \
  || bad "the receipt does not record the failure kind: $(grep -c . .claude/.spec-red) lines"

# Cross-language module-resolution patterns, checked directly so the list is
# pinned rather than inferred from whichever runner the fixture happens to use.
# Captured before the loop: a `| while` runs in a subshell, so every ok/bad it
# counted would be discarded along with it.
KINDS=$( . .claude/hooks/phase-policy.sh 2>/dev/null
  while IFS='|' read -r want text; do
    [ -z "$want" ] && continue
    got=$(red_failure_kind 1 "$text")
    if [ "$got" = "$want" ]; then echo "OK  $want: ${text:0:44}"; else echo "BAD $want expected for '${text:0:44}' — got $got"; fi
  done <<'CASES'
import|ModuleNotFoundError: No module named 'src.parser'
import|ImportError: cannot import name parse from src.parser
import|Error: Cannot find module './parser'
import|error TS2307: Cannot find module './parser'.
import|ERR_MODULE_NOT_FOUND
import|cannot find package "example.com/x"
import|no required module provides package example.com/x
import|error[E0432]: unresolved import crate::parser
import|error: package com.x does not exist
import|cannot load such file -- ./parser
assertion|AssertionError: expected 1 to equal 2
assertion|FAIL src/x.test.ts (1 failed)
assertion|Expected: {error: empty}  Received: undefined
CASES
)
while IFS= read -r line; do
  case "$line" in "OK  "*) ok "${line#OK  }" ;; BAD*) bad "${line#BAD }" ;; esac
done <<< "$KINDS"

# Scaffold mode is the one place a missing module IS the assertion.
setup_repo; phase start t; phase 2
printf 'the spec\n' > docs/specs/t.md
answer spec 'Approve, and create the files first'
.claude/hooks/phase.sh scaffold >/dev/null 2>&1
kind "in scaffold, a missing module is RED"  'printf "ModuleNotFoundError: No module named src.parser\n"; exit 1' RED 'RED verified'
kind "but a broken runner still is not"      'no-such-test-runner -q'            REFUSED 'did not run'

group "Scaffold: reaching assertion-red on code that does not exist yet"
# The hole this closes: `phase.sh red` has exactly one detector for a vacuous
# test — the test passes. Against a module that does not exist, a careful test
# and `assert True` both fail with ModuleNotFoundError, so the detector is blind
# for precisely the new feature work the workflow exists for. Phase 3 forbids
# creating the module, so the agent has no move that produces assertion-red.
#
# Scaffold is a MODE on Phase 2, not a phase number. A phase numbered below 3
# that may write production code would be reachable through the guard's retreat
# rule ([ "$ARG" -lt "$PHASE" ] is allowed unchecked, because lower has always
# meant stricter), which is a bypass straight through the gate.
setup_repo
phase start newfeature
phase 2
printf 'the spec\n' > docs/specs/newfeature.md

# Unasked, this is the confirmation prompt every other gate falls back to — not
# an allow, and not a refusal either. It is the only route that exists under
# Cursor, where no receipt can ever be written.
expect_b "unasked, scaffold prompts rather than proceeds" ASK '.claude/hooks/phase.sh scaffold'
# Only one .spec-approval exists at a time, so a scaffold gate of its own would
# overwrite the answer that 2 -> 3 still needs. The decision rides on the spec
# approval instead — which is where the surface being created is described.
answer spec 'Approve the spec'
expect_b "the plain approval does not authorise it"  DENY '.claude/hooks/phase.sh scaffold'
[ -f .claude/.spec-scaffold ] && bad "scaffold armed itself without an answer" \
                             || ok "a plain spec approval arms nothing"

answer spec 'Approve, and create the files first'
expect_b "the scaffold answer authorises it"  ALLOW '.claude/hooks/phase.sh scaffold'
expect_b "and 2 -> 3 still honours the same answer" ALLOW '.claude/hooks/phase.sh 3'

# Cursor has no AskUserQuestion, so approval_status is permanently `none` there
# and a receipt can never exist. With scaffold reachable only through a receipt,
# a Cursor user writing a new module hit import-red in Phase 3, was told to
# scaffold, and had no way to do it — a hard block introduced by making
# import-red refuse. beforeShellExecution does carry `ask`, so the fallback every
# other gate already has works there too.
rm -f .claude/.spec-approval .claude/.spec-scaffold
expect_b "unasked, scaffold falls back to a prompt" ASK '.claude/hooks/phase.sh scaffold'
reason=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh scaffold')")
printf '%s' "$reason" | grep -qi 'not been approved' \
  && ok "the prompt says the spec was never approved through the question" \
  || bad "the scaffold prompt hides that the spec is unapproved: '$reason'"
printf '%s' "$reason" | grep -qi 'do not exist' \
  && ok "and says what it is granting" \
  || bad "the scaffold prompt does not say what it grants: '$reason'"
# Choosing the plain approval is a decision AGAINST scaffolding, not an absence
# of one, so it must not degrade into a prompt that asks again.
answer spec 'Approve the spec'
expect_b "a plain approval is still a refusal" DENY '.claude/hooks/phase.sh scaffold'
# `stale` and `expired` are answers, not the absence of one, and every other gate
# in the guard spells them out as denials. The fallback must not turn them into a
# fresh prompt — re-asking until the answer changes is not consent.
answer spec 'Approve, and create the files first'
printf 'and one more requirement nobody approved\n' >> docs/specs/newfeature.md
expect_b "a stale answer is not re-prompted"   DENY '.claude/hooks/phase.sh scaffold'
answer spec 'Approve, and create the files first'
printf 'phase=2\ntask=newfeature\nslice=1/2\n' > .claude/.spec-phase
expect_b "an expired answer is not re-prompted" DENY '.claude/hooks/phase.sh scaffold'
printf 'phase=2\ntask=newfeature\nslice=1/1\n' > .claude/.spec-phase
.claude/hooks/phase.sh scaffold >/dev/null 2>&1
[ -f .claude/.spec-scaffold ] && ok "scaffold mode is recorded on disk" \
                             || bad "phase.sh scaffold left no marker"
printf '%s' "$(.claude/hooks/phase.sh status 2>&1)" | grep -qi 'scaffold' \
  && ok "status says the gate is in scaffold mode" \
  || bad "status does not mention scaffold: $(.claude/hooks/phase.sh status 2>&1 | head -2)"

# The write bound. "New" means UNTRACKED, not "does not exist" — at Stop-scan
# time the file it just created does exist, so an existence test would have the
# two layers disagreeing about the same file in the same turn.
expect_w "a brand-new module may be created"   ALLOW src/parser.ts
expect_w "a tracked file may NOT be edited"    DENY  src/x.ts
expect_w "not even to append to it"            DENY  src/x.ts Edit
expect_b "nor through a redirect"              DENY  'echo x >> src/x.ts'
expect_w "tests are still writable"            ALLOW src/parser.test.ts
expect_w "specs are still writable"            ALLOW docs/specs/newfeature.md
# `git ls-files --error-unmatch` matches STAGED files, so the guard's answer
# changed the moment the work was staged — and review-bookmark.sh stages on every
# review round. The file then read as "tracked", the Stop scan called it a phase
# violation, and its advice was to revert the work scaffold exists to produce.
printf 'export const parse = () => null\n' > src/scaffolded.ts
expect_w "a scaffolded file before staging" ALLOW src/scaffolded.ts
git add src/scaffolded.ts >/dev/null 2>&1
expect_w "and the same file after staging"  ALLOW src/scaffolded.ts
expect_gate "staging it is not a phase violation" 0
git rm -q --cached src/scaffolded.ts >/dev/null 2>&1; rm -f src/scaffolded.ts
expect_w "phase state is still not writable"   DENY  .claude/.spec-phase
expect_w "and neither is the scaffold marker"  DENY  .claude/.spec-scaffold
expect_b "naming the marker at all is denied"  DENY  'rm .claude/.spec-scaffold'

# Both layers have to agree, or prevention and detection contradict each other
# on the same file. The Stop scan asks git the same question the guard did.
printf 'export const parse = () => { throw new Error("not implemented") }\n' > src/parser.ts
expect_gate "a scaffolded new file does not violate the phase" 0
echo 'edited' >> src/x.ts
expect_gate "editing a tracked file during scaffold does"      2
git checkout -- src/x.ts 2>/dev/null

# The import test can be shown red before the file exists — the one case where
# import-red is the assertion, because existence is what the step delivers.
rm -f src/parser.ts
printf 'exit 1\n' > .claude/spec-gate-test-cmd
printf 'import { parse } from "./parser"\n' > src/parser.test.ts
out=$(.claude/hooks/phase.sh red 2>&1); rc=$?
[ "$rc" = 0 ] && ok "phase.sh red runs in scaffold mode" \
              || bad "red refused during scaffold: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"

# Leaving scaffold closes it. Advancing is the ordinary 2 -> 3, and the spec
# approval the user already gave still covers it.
printf 'export const parse = () => null\n' > src/parser.ts
.claude/hooks/phase.sh 3 >/dev/null 2>&1
[ -f .claude/.spec-scaffold ] && bad "the scaffold marker survived a phase change" \
                             || ok "advancing to Phase 3 clears scaffold mode"
expect_w "and production is blocked again at Phase 3" DENY src/another.ts

# Scaffold belongs to Phase 2 and nowhere else. This is what makes it unable to
# serve as the free retreat a numbered phase would have been.
for p in 1 3 4 5; do
  printf 'phase=%s\ntask=newfeature\nslice=1/1\n' "$p" > .claude/.spec-phase
  .claude/hooks/phase.sh scaffold >/dev/null 2>&1
  [ -f .claude/.spec-scaffold ] && bad "scaffold armed from phase $p" \
                               || ok "scaffold is refused at phase $p"
done
printf 'phase=2\ntask=newfeature\nslice=1/1\n' > .claude/.spec-phase
.claude/hooks/phase.sh off >/dev/null 2>&1
[ -f .claude/.spec-scaffold ] && bad "off left the scaffold marker behind" \
                             || ok "off clears scaffold mode too"

group "One tree per task: the gate fails closed on a split"
# Observed: the gate armed at Phase 3 in the main checkout, `status` reporting
# "inactive" from a worktree, and the guard ALLOWING a production write to
# <worktree>/src because the path was not under PROJECT_DIR. The gate reported
# itself armed and enforced nothing — a fail-open, not friction. Nothing here can
# span two trees: PROJECT_DIR decides where .spec-phase is read from and
# in_project decides which paths are the gate's business, and on a split those
# two answers come from different trees.
setup_repo
MAIN=$PWD
phase start feature
phase 3
git worktree add -q "$WORK/wt" -b feature-wt >/dev/null 2>&1
WT=$(cd "$WORK/wt" && pwd -P)

# From the worktree: nothing is armed here, but something is armed next door.
# "Inactive" was the old answer and it is the dangerous one.
export CLAUDE_PROJECT_DIR="$WT"
cd "$WT" || exit 1
expect_w "a write from the un-armed worktree is denied" DENY "$WT/src/x.ts"
# Failing closed means refusing the WRITES, not bricking the tree. The deny used
# to fire before the tool was even looked at, so `ls`, `git status` and `cat`
# all died — including the phase.sh status that reports the split, which made the
# one escape hatch unreachable from the session that needed it. It also caught
# Claude Code's own worktree-isolated subagents.
expect_b "reads are not the gate's business"  ALLOW 'ls -la'
expect_b "nor is git status"                  ALLOW 'git status'
expect_b "nor running the suite"              ALLOW 'npm test'
expect_b "and status stays reachable"         ALLOW '.claude/hooks/phase.sh status'
expect_b "but a write through Bash is denied" DENY  'echo x > src/x.ts'
# in_project is a prefix test against THIS tree, so an absolute path into the
# armed tree scored as "not our business" — the same fail-open the split check
# exists to close, from the mirror direction. The third one disarms the gate.
expect_b "a write INTO the armed tree"       DENY  "echo x > $MAIN/src/x.ts"
expect_b "a cp INTO the armed tree"          DENY  "cp /tmp/e $MAIN/src/x.ts"
expect_b "rewriting the armed tree's state"  DENY  "printf 'phase=5' > $MAIN/.claude/.spec-phase"
# The escape hatch matched *phase.sh* anywhere in the command, so naming it in a
# comment or a string skipped the check entirely.
expect_b "phase.sh in a comment is not it"   DENY  'echo x > src/x.ts # phase.sh'
expect_b "phase.sh in a string is not it"    DENY  'echo "phase.sh" > src/x.ts'
expect_b "reading phase.sh into a file"      DENY  'cat .claude/hooks/phase.sh > src/x.ts'
reason=$(guard_reason "$(pl_write "$WT/src/x.ts")")
printf '%s' "$reason" | grep -qF "$MAIN" && printf '%s' "$reason" | grep -qF "$WT" \
  && ok "the refusal names both trees" \
  || bad "the split refusal does not name both trees: '$reason'"
printf '%s' "$reason" | grep -q 'phase.sh off' \
  && ok "the refusal says how to reconcile by hand" \
  || bad "the split refusal offers no way out: '$reason'"

out=$("$MAIN"/.claude/hooks/phase.sh status 2>&1)
printf '%s' "$out" | grep -qi 'inactive' \
  && bad "status still reports inactive while a sibling tree is armed: '$out'" \
  || ok "status reports the split instead of inactive"
printf '%s' "$out" | grep -qF "$MAIN" \
  && ok "status names the tree that holds the state" \
  || bad "status does not say where the state actually is: '$out'"

# The same question put to `brief`, which had the branch for it and could not
# reach it: FOREIGN is only computed when no state file is present here, which is
# exactly the case brief used to exit 0 on, and the refusal above it caught brief
# before either. A regression here is silent in the worst way — brief is the
# SessionStart hook, and stdout from a hook that exits non-zero never becomes
# context, so the session simply starts knowing nothing.
BOUT=$(.claude/hooks/phase.sh brief 2>&1); BRC=$?
[ "$BRC" = 0 ] && ok "brief exits 0 from a tree the task does not live in" \
  || bad "brief exited $BRC across a split; a SessionStart hook that fails says nothing"
[ -n "$BOUT" ] && ok "and is not silent, which is how it reports 'no task armed'" \
  || bad "brief was silent across a split — indistinguishable from nothing being armed"
printf '%s' "$BOUT" | grep -q 'ANOTHER WORKTREE' \
  && ok "and says the task is armed somewhere else" \
  || bad "brief across a split did not report the split: '$BOUT'"
printf '%s' "$BOUT" | grep -qF "$MAIN" \
  && ok "and names the tree that holds it" \
  || bad "brief does not say where the task actually is: '$BOUT'"

out=$("$MAIN"/.claude/hooks/phase.sh 4 2>&1)
[ "$(sed -n 's/^phase=//p' "$MAIN/.claude/.spec-phase" | head -1)" = 3 ] \
  && ok "phase.sh does not advance a task living in another tree" \
  || bad "the cross-tree call moved the real state"
# "not started" is the OLD answer and it is wrong: something IS started, next
# door. A refusal that misdescribes why it refused is how people learn to stop
# reading refusals.
printf '%s' "$out" | grep -qF "$MAIN" \
  && ok "and says which tree the task is actually in" \
  || bad "phase.sh refuses across a split without saying where the task is: '$out'"

# The Stop gate has the same blind spot, and the dangerous direction is the one
# where PROJECT_DIR points at the CLEAN tree: it scans there, finds nothing owed,
# and passes a turn whose work it never looked at.
#
# But "another worktree is dirty" is not that question. A scratch tree, or
# someone else's branch, is none of this task's business, and blocking on it
# would make one permanently-dirty spare worktree block every turn forever. The
# tree has to be related to THIS task, and the signal is the task's own spec
# document: written in Phase 2 on the task's branch, so a tree that predates the
# task does not have it.
cd "$MAIN" || exit 1
export CLAUDE_PROJECT_DIR="$MAIN"
printf 'phase=5\ntask=feature\nslice=1/1\n' > "$MAIN/.claude/.spec-phase"
printf 'someone elses branch\n' > "$WT/src/unrelated.ts"
rc=$(gate)
[ "$rc" = 0 ] && ok "an unrelated dirty worktree is not this task's business" \
              || bad "a dirty worktree with no connection to the task blocked (exit $rc)"

mkdir -p "$WT/docs/specs"
printf 'the spec\n' > "$WT/docs/specs/feature.md"
printf 'work nobody reviewed\n' > "$WT/src/newthing.ts"
rc=$(gate)
[ "$rc" = 2 ] && ok "a worktree holding this task's spec blocks the turn" \
              || bad "the Stop gate passed a turn whose work is in another tree (exit $rc)"
rm -rf "$WT/docs/specs" "$WT/src/newthing.ts" "$WT/src/unrelated.ts"
rc=$(gate)
[ "$rc" = 0 ] && ok "and goes quiet once no related tree is dirty" \
              || bad "the Stop gate stayed blocked with no related tree left (exit $rc)"
printf 'phase=3\ntask=feature\nslice=1/1\n' > "$MAIN/.claude/.spec-phase"
cd "$WT" || exit 1
export CLAUDE_PROJECT_DIR="$WT"

# The mirror case: armed in main, and a tool call reaches into the worktree.
# in_project used to read that as "not repo work" and skip it.
cd "$MAIN" || exit 1
export CLAUDE_PROJECT_DIR="$MAIN"
expect_w "a write INTO another worktree is denied" DENY "$WT/src/x.ts"
# The same write, named the way a real tool payload names it: unresolved, with
# whatever symlinked parent the caller happened to be standing under. git reports
# worktrees in physical form, so a prefix comparison against the raw path is
# false for reasons that have nothing to do with which tree the file is in. Both
# unit tests above pass with the normalisation removed; this one does not.
expect_w "and denied when the path is not pre-resolved" DENY "$WORK/wt/src/x.ts"
expect_w "a not-yet-existing nested path too"          DENY "$WORK/wt/src/deep/new/thing.ts"
# Paths genuinely outside the repo are still none of the gate's business.
expect_b "an unrelated absolute path still passes" ALLOW 'pytest -q > /dev/null 2>&1'
expect_w "a path outside any worktree is ignored"  ALLOW /tmp/scratch.ts

# Starting a second task here while one is armed next door is refused too, and
# has to be: the refusal tells you to turn the other one off first, so a `start`
# that quietly armed a second tree would contradict the instruction the same
# gate just gave. One tree at a time is the whole claim.
cd "$WT" || exit 1
export CLAUDE_PROJECT_DIR="$WT"
"$MAIN"/.claude/hooks/phase.sh start wt-task >/dev/null 2>&1
[ -f "$WT/.claude/.spec-phase" ] \
  && bad "start armed a second tree while another was already armed" \
  || ok "start is refused while a sibling tree holds the task"

# The reconciliation the refusal actually names, end to end. This is the path a
# user is told to take, so it is the one that must work.
cd "$MAIN" || exit 1
export CLAUDE_PROJECT_DIR="$MAIN"
"$MAIN"/.claude/hooks/phase.sh off >/dev/null 2>&1
cd "$WT" || exit 1
export CLAUDE_PROJECT_DIR="$WT"
"$MAIN"/.claude/hooks/phase.sh start wt-task >/dev/null 2>&1
"$MAIN"/.claude/hooks/phase.sh 3 >/dev/null 2>&1
[ "$(sed -n 's/^phase=//p' "$WT/.claude/.spec-phase" 2>/dev/null | head -1)" = 3 ] \
  && ok "once the other tree is disarmed, this one arms normally" \
  || bad "the reconciliation the refusal names does not work"
expect_w "the newly armed tree denies production" DENY  "$WT/src/x.ts"
expect_w "and permits its own tests"              ALLOW "$WT/src/x.test.ts"
out=$("$MAIN"/.claude/hooks/phase.sh status 2>&1)
printf '%s' "$out" | grep -qi 'another worktree' \
  && bad "the surviving armed tree still reports a split: '$out'" \
  || ok "one armed tree is not a split"
cd "$MAIN" || exit 1
export CLAUDE_PROJECT_DIR="$MAIN"

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
# The validation report and the journal. Phase 5 hands the repo's own checks to a
# reviewer, so a report that exists only in the conversation is one the session
# after this one cannot hand over — hence a tripwire shaped like the RED one.
group "4 -> 5 refuses without a recorded validation report"
setup_repo
phase start jrnl; phase 2; phase 3; phase 4 --force

.claude/hooks/phase.sh 5 >/dev/null 2>&1 \
  && bad "4 -> 5 advanced with no validation report on record" \
  || ok "4 -> 5 refused without a validation report"
VP=$(sed -n 's/^phase=//p' .claude/.spec-phase | head -1)
[ "$VP" = 4 ] && ok "and the refusal left the phase at 4" \
  || bad "refused but the phase moved to '$VP'"

printf 'Commands: make test\nSource: the Makefile\nResult: pass\nNot covered: types\n' \
  | .claude/hooks/phase.sh validation >/dev/null 2>&1 \
  && ok "phase.sh validation records the report" \
  || bad "phase.sh validation failed inside Phase 4"
[ -f .claude/.spec-validation ] && ok "and writes the marker" \
  || bad "no .spec-validation marker was written"
grep -q 'VALIDATION REPORT' .claude/spec-journal.md 2>/dev/null \
  && ok "and the report lands in the journal" \
  || bad "the journal has no VALIDATION REPORT entry"
grep -q 'make test' .claude/spec-journal.md 2>/dev/null \
  && ok "with the body it was handed" || bad "the journal entry lost its body"

.claude/hooks/phase.sh 5 >/dev/null 2>&1 \
  && ok "4 -> 5 goes through once the report is recorded" \
  || bad "4 -> 5 still refused with a report on record"

# The marker is spent by the phase it described, exactly like the RED receipt.
[ -f .claude/.spec-validation ] \
  && bad "the validation marker survived the phase change" \
  || ok "the marker is cleared by the phase change"
phase 4 --force
.claude/hooks/phase.sh 5 >/dev/null 2>&1 \
  && bad "a second 4 -> 5 rode the earlier report" \
  || ok "a retreat into 4 cannot ride the earlier report"
grep -q 'VALIDATION REPORT' .claude/spec-journal.md 2>/dev/null \
  && ok "the journal itself survives a phase change" \
  || bad "the journal was cleared by a phase change"

phase 2
printf 'x\n' | .claude/hooks/phase.sh validation >/dev/null 2>&1 \
  && bad "a validation report was accepted outside Phase 4" \
  || ok "phase.sh validation is refused outside Phase 4"

################################################################################
# The validation marker is what 4 -> 5 rests on, so it is state in the sense that
# .spec-red is state: everything that keeps the model away from the RED receipt
# has to keep it away from this one, or the gate is a suggestion.
group "the validation marker is phase state, not the model's to write"
setup_repo
phase start vstate; phase 2; phase 3; phase 4 --force

expect_w "Write to the validation marker denied"  DENY  .claude/.spec-validation
expect_w "Edit to it denied too"                  DENY  .claude/.spec-validation Edit
expect_b "forging the marker from bash denied"    DENY  'printf x > .claude/.spec-validation'
expect_b "and removing it is denied"              DENY  'rm -f .claude/.spec-validation'
# The command that legitimately writes it must still get through, or the only
# way past the gate is the override.
expect_b "phase.sh validation is still allowed"   ALLOW '.claude/hooks/phase.sh validation'

# An empty report used to write the marker and clear 4 -> 5, which is the gate
# certifying that nothing was run — a receipt worse than no receipt, because the
# next session reads it as evidence and stops asking.
printf '' | .claude/hooks/phase.sh validation >/dev/null 2>&1 \
  && bad "an empty validation report was accepted" \
  || ok "an empty validation report is refused"
[ -f .claude/.spec-validation ] \
  && bad "the empty report still wrote the marker" \
  || ok "and it wrote no marker"
printf '   \n\n  \n' | .claude/hooks/phase.sh validation >/dev/null 2>&1 \
  && bad "a whitespace-only validation report was accepted" \
  || ok "a whitespace-only report is refused too"
.claude/hooks/phase.sh 5 >/dev/null 2>&1 \
  && bad "4 -> 5 cleared on a refused report" \
  || ok "4 -> 5 still refuses after a refused report"
# Same rule for the journal: a stamped header with nothing under it reads as an
# entry describing work that happened.
printf '' | .claude/hooks/phase.sh journal >/dev/null 2>&1 \
  && bad "an empty journal entry was accepted" \
  || ok "an empty journal entry is refused"

# The marker records the task and slice it was written for. Those fields existed
# from the start and nothing read them, so a report survived a re-slice that
# redrew the scope it was describing.
group "a validation report is pinned to the slice it was written for"
setup_repo
phase start vpin; phase 2; phase 3; phase 4 --force
.claude/hooks/phase.sh slices 2 >/dev/null 2>&1
printf 'Commands: make test\nResult: pass\n' \
  | .claude/hooks/phase.sh validation >/dev/null 2>&1
grep -q '^slice=1/2$' .claude/.spec-validation \
  && ok "the marker records the slice it was written on" \
  || bad "the marker does not carry the slice: $(cat .claude/.spec-validation)"
.claude/hooks/phase.sh slices 3 >/dev/null 2>&1
.claude/hooks/phase.sh 5 >/dev/null 2>&1 \
  && bad "a report written for slice 1/2 cleared 4 -> 5 after a re-slice" \
  || ok "re-slicing voids a report written against the old shape"
VOUT=$(.claude/hooks/phase.sh 5 2>&1)
printf '%s' "$VOUT" | grep -q 'different point in this task' \
  && ok "and the refusal says why rather than claiming none was recorded" \
  || bad "the stale-report refusal is indistinguishable from a missing one"

################################################################################
# Two rounds of review moved the *token* path forward — ARG, the write-target
# loop — and left the phase-state check reading raw command text. The text is
# not what the shell runs. `.spec-vali''dation` reaches the same inode while
# containing no `.spec-validation`; `rm -f .claude/.spec-*` names no state file
# until the glob expands; `git clean -fdx` names nothing at all and removes
# every one of them, because they are gitignored by design. All of these were
# ALLOW, so the 4 -> 5 marker was the model's to write after all, and the whole
# gate could be swept away at Phase 3 by a command with no evasion in it.
group "the phase-state check reads what the shell would run, not the text"
setup_repo
phase start ptok; phase 2; phase 3

expect_b "rm through a glob that covers the state files" \
  DENY 'rm -f .claude/.spec-*'
expect_b "git clean -fdx, which removes every gitignored state file" \
  DENY 'git clean -fdx'
expect_b "and -X, which removes the ignored ones and nothing else" \
  DENY 'git clean -fdX'
expect_b "mv of a quote-split state path" \
  DENY "mv .claude/.spec-pha''se /tmp/parked"
expect_b "truncating a quote-split state path to nothing" \
  DENY "truncate -s 0 .claude/.spec-pha''se"
expect_b "a backslash-split state path" \
  DENY 'rm -f .claude/.spec-phas\e'
expect_b "rm -rf on the directory that holds them" \
  DENY 'rm -rf .claude'
# A quoted string handed to a shell is not data, it is shell — the rule this
# suite already applies to write targets. Reading the raw text used to cover
# this for free; reading tokens does not, unless the payload is re-read.
expect_b "a state path inside a nested shell payload" \
  DENY 'bash -c "rm -f .claude/.spec-red && echo done"'
expect_b "and one nested two deep" \
  DENY 'sh -c "bash -c \"rm -f .claude/.spec-phase\""'

# Blunt is fine on the state files themselves; blunt on their directory is not.
# `.claude` holds the hooks, the settings and the skills, and the model reads
# all three.
setup_repo; phase start ptok2; phase 2; phase 3
expect_b "reading the directory is still allowed"  ALLOW 'ls .claude'
expect_b "so is reading a file next to the state"  ALLOW 'cat .claude/settings.json'
expect_b "git clean without -x leaves them alone"  ALLOW 'git clean -fd'
expect_b "and an ordinary rm is not a phase question" ALLOW 'rm -rf build/'

# The other half of "the text is not the command": a heredoc body is data, which
# this suite already asserts for redirects and verbs. Concluding on the raw text
# denied a journal entry for describing the state file it was denied from
# touching — the workflow's own record blocked by the gate it records.
expect_b "a journal entry may name a state file" ALLOW ".claude/hooks/phase.sh journal <<'EOF'
tried to write .claude/.spec-phase directly and the guard refused, correctly
EOF"

# Phase >= 4 returns to the normal permission flow, and that early exit sat
# above the loop that resolves write targets — so at Phase 4, the only phase
# the validation marker exists in, the substring was the whole defence.
setup_repo; phase start ptok3; phase 2; phase 3; phase 4 --force
expect_b "the split marker write is refused at Phase 4" \
  DENY "printf 'task=ptok3\nslice=1/1\n' > .claude/.spec-vali''dation"
[ -f .claude/.spec-validation ] \
  && bad "the refused command still wrote the marker" \
  || ok "and no marker was written"
.claude/hooks/phase.sh 5 >/dev/null 2>&1 \
  && bad "4 -> 5 cleared with nothing run" \
  || ok "so 4 -> 5 still refuses"

# Same early exit, one phase later: writing phase=4 from Phase 5 puts the repo
# back where the Stop review gate does not arm, which is the scenario the check
# was placed above the exit to prevent.
setup_repo; phase start ptok4; phase 2; phase 3; phase 4 --force; phase 5
expect_b "and a split phase rewrite is refused at Phase 5" \
  DENY "printf 'phase=4\ntask=ptok4\nslice=1/1\n' > .claude/.spec-pha''se"

################################################################################
# 5 --force and 4 --force are spelled the same and skip different checks. One
# question standing for both meant an answer about unlocking production code was
# redeemable for entering review unvalidated, and vice versa.
group "5 --force has its own gate, not the RED one"
setup_repo
phase start vforce; phase 2; phase 3; phase 4 --force

expect_b "5 --force is denied until the user is asked" \
  DENY '.claude/hooks/phase.sh 5 --force'
FR=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh 5 --force')")
printf '%s' "$FR" | grep -qi 'phase 5' \
  && ok "and the reason names Phase 5, not Phase 4" \
  || bad "the 5 --force reason does not mention Phase 5: '$FR'"
printf '%s' "$FR" | grep -qi 'force-validation' \
  && ok "and points at the force-validation gate" \
  || bad "the 5 --force reason does not name its gate: '$FR'"

# The load-bearing half: the two gates do not redeem each other. Before they were
# split, this answer allowed the transition below — the user having been asked
# about unlocking production code, and that answer spent on entering review with
# the checks unrun.
answer force 'Unlock without RED'
expect_b "an answer to the RED force gate does not clear 5 --force" \
  DENY '.claude/hooks/phase.sh 5 --force'
answer force-validation 'Review it unvalidated'
expect_b "its own answer does clear it" \
  ALLOW '.claude/hooks/phase.sh 5 --force'

setup_repo
phase start vforce2; phase 2; phase 3
answer force-validation 'Review it unvalidated'
expect_b "and does not clear 4 --force in exchange" \
  DENY '.claude/hooks/phase.sh 4 --force'
answer force-validation 'Run the checks first'
setup_repo; phase start vforce3; phase 2; phase 3; phase 4 --force
answer force-validation 'Run the checks first'
expect_b "declining force-validation denies rather than asks again" \
  DENY '.claude/hooks/phase.sh 5 --force'

# The dispatch routes on ARG, and ARG used to be the first token after phase.sh —
# so writing the flag first made ARG '--force', which is not 5, and the Phase 5
# override fell through to the Phase 4 question. The user would be asked about
# unlocking production code in order to decide something else: the confusion the
# split exists to prevent, reachable by typing the same two words in the other
# order.
setup_repo; phase start vforceord; phase 2; phase 3; phase 4 --force
FR=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh --force 5')")
printf '%s' "$FR" | grep -qi 'phase 5' \
  && ok "flag-first '--force 5' still reaches the Phase 5 question" \
  || bad "'--force 5' asked about something else: '$FR'"
printf '%s' "$FR" | grep -qi 'force-validation' \
  && ok "and still names the force-validation gate" \
  || bad "'--force 5' did not route to force-validation: '$FR'"
expect_b "and flag-first is not itself a way around the gate" \
  DENY '.claude/hooks/phase.sh --force 5'

# The mirror, so the flag-skipping walk cannot be "return 5 whenever unsure".
FR=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh --force 4')")
printf '%s' "$FR" | grep -qi 'phase 4' \
  && ok "flag-first '--force 4' still reaches the Phase 4 question" \
  || bad "'--force 4' asked about something else: '$FR'"

# A flag with no destination at all names no phase, and must not be read as one.
FR=$(guard_reason "$(pl_bash '.claude/hooks/phase.sh --force')")
printf '%s' "$FR" | grep -qi 'phase 5' \
  && bad "a bare '--force' was routed to the Phase 5 gate: '$FR'" \
  || ok "a bare '--force' does not invent a destination"

# ARG was fixed to read tokens; the DETECTION above it still scanned the whole
# command, heredoc bodies included. `journal` and `validation` exist to write
# prose about this workflow, and prose about this workflow says "--force" — so
# recording that you forced the RED gate was itself denied, and the question the
# user got was about unlocking production code in order to save a note.
setup_repo; phase start vforcetext; phase 2; phase 3; phase 4 --force
expect_b "a validation report may describe a force" ALLOW ".claude/hooks/phase.sh validation <<'EOF'
Commands: make test
Note: we advanced with phase.sh 4 --force earlier, so RED was never shown
EOF"
expect_b "so may a journal entry" ALLOW ".claude/hooks/phase.sh journal <<'EOF'
declined finding 3; used --force on the RED gate and said why
EOF"
# The same mistake reached past phase.sh entirely: any command anywhere in the
# line carrying the word put the user in front of a phase gate.
expect_b "an unrelated --force in another command is not a phase override" \
  ALLOW 'git push --force && .claude/hooks/phase.sh status'
# And the flag itself is still the flag.
expect_b "the real thing is still gated" \
  DENY '.claude/hooks/phase.sh 4 --force'

################################################################################
# An untracked state file counts as work owed review, so a name the install
# forgot to gitignore arms the gate on the gate's own bookkeeping — and nothing
# clears it, because the path is meant to be ignored and cannot be committed.
group "the gate does not arm on its own state files"
setup_repo
# Deliberately the pre-fix .gitignore: this is the install that shipped, and the
# exclusion has to hold without it.
printf '.claude/.spec-phase\n.claude/.spec-baseline\n.claude/.spec-red\n' > .gitignore
git add -A >/dev/null 2>&1; git commit -qm base >/dev/null 2>&1
phase start vexcl; phase 2

# Each marker is checked at a phase where it is actually on disk. Every
# transition deletes most of them, so a single checkpoint at the end would be
# asserting that files which no longer exist are not listed — which passes
# whatever the exclusion list says, and proves nothing.
printf 'the spec\n' > docs/specs/vexcl.md
answer spec 'Approve the spec'
.claude/hooks/phase.sh scaffold >/dev/null 2>&1
printf 'a note\n' | .claude/hooks/phase.sh journal >/dev/null 2>&1
printf '{"t":"now","agent":"adversary","msg":"x"}\n' > .claude/review-log.jsonl
for n in .spec-scaffold .spec-approval spec-journal.md review-log.jsonl; do
  [ -e ".claude/$n" ] && ok "$n exists, so the pending check below is not vacuous" \
    || bad "$n was never created — the check below would pass on nothing"
done
# review_pending_paths is what the Stop gate and the 5 -> 3 boundary both read,
# so it is asked directly rather than through a command that summarises it.
PEND=$( . "$SRC/hooks/phase-policy.sh"; PROJECT_DIR="$PWD" review_pending_paths )
for n in .spec-scaffold .spec-approval spec-journal.md review-log.jsonl; do
  printf '%s' "$PEND" | grep -q "$n" \
    && bad "$n is owed review — the gate armed on its own bookkeeping" \
    || ok "$n does not arm the review gate even when ungitignored"
done

# The receipt is written through a temp file beside itself. The exclusion list
# holds exact names, and `.spec-approval` is not `.spec-approval.tmp.4321` — so
# on an install whose .gitignore lacks the glob, a Stop scan landing inside that
# window arms on the write of a receipt, which is the exact failure this list
# exists to make impossible without a correct install.
printf 'x\n' > ".claude/.spec-approval.tmp.$$"
PEND=$( . "$SRC/hooks/phase-policy.sh"; PROJECT_DIR="$PWD" review_pending_paths )
printf '%s' "$PEND" | grep -q '.spec-approval.tmp' \
  && bad "the approval receipt's temp file is owed review" \
  || ok "and neither does the temp file it is written through"
rm -f ".claude/.spec-approval.tmp.$$"

phase 3; phase 4 --force
printf 'Commands: make test\nResult: pass\n' \
  | .claude/hooks/phase.sh validation >/dev/null 2>&1
[ -e .claude/.spec-validation ] && ok ".spec-validation exists, so the check below is not vacuous" \
  || bad ".spec-validation was never created"
PEND=$( . "$SRC/hooks/phase-policy.sh"; PROJECT_DIR="$PWD" review_pending_paths )
printf '%s' "$PEND" | grep -q '.spec-validation' \
  && bad ".spec-validation is owed review" \
  || ok ".spec-validation does not arm the review gate even when ungitignored"

# The other side of the same coin, and the reason this is a list of exact names
# rather than a hole in .claude/: ordinary files there are still work.
printf 'x\n' > .claude/settings-note.txt
PEND=$( . "$SRC/hooks/phase-policy.sh"; PROJECT_DIR="$PWD" review_pending_paths )
printf '%s' "$PEND" | grep -q 'settings-note.txt' \
  && ok "and an ordinary untracked file in .claude/ is still owed review" \
  || bad "the exclusion swallowed a file that is not the gate's own state"
rm -f .claude/settings-note.txt

# End to end, through the hook that actually ends turns: with nothing dirty but
# the gate's own state, Phase 5 must let the turn finish. This is the failure
# that has no exit — those paths are gitignored by design, so there is no commit
# a human can make to satisfy a gate that is asking for them.
phase 5
expect_gate "the Stop gate is quiet when only the gate's own state is dirty" 0
printf 'real work\n' > src/x.ts
expect_gate "and still blocks on actual work" 2

group "phase.sh brief — handing the task back to a session that lost it"
setup_repo
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
[ -z "$BOUT" ] && ok "brief says nothing at all when no task is armed" \
  || bad "brief spoke with no task armed: '$BOUT'"

phase start resumable
printf '# spec\n' > docs/specs/resumable.md
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -q 'ACTIVE spec-driven task' \
  && ok "brief announces an active task" || bad "brief did not announce the task"
printf '%s' "$BOUT" | grep -q 'resumable' \
  && ok "and names it" || bad "brief did not name the task"

# Every line below is asserted where it can be true and asserted ABSENT where it
# cannot. The negative half is the half that matters: each of these lines was
# once printed unconditionally, and a briefing that reports "RED: not verified"
# at a phase that deletes the RED receipt is not merely noisy — it tells a
# resuming session that verified work is unverified, which is the one failure a
# briefing cannot survive.
printf '%s' "$BOUT" | grep -q 'NOT FOUND' \
  && bad "brief called the spec missing at Phase 1, where writing it is still Phase 2's job" \
  || ok "no missing-spec warning at Phase 1, where there is not meant to be one"
printf '%s' "$BOUT" | grep -q 'did NOT survive' \
  && bad "brief warned about lost reviewer sessions at Phase 1, before any exist" \
  || ok "no reviewer-session warning at Phase 1"
printf '%s' "$BOUT" | grep -q 'RED:' \
  && bad "brief reported RED status at Phase 1" || ok "no RED line at Phase 1"

phase 2
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -q 'docs/specs/resumable.md' \
  && ok "and points at the spec once Phase 2 owns one" \
  || bad "brief did not point at the spec"

# A spec that is not there is named as missing rather than quietly printed as a
# path, because the path alone reads as a file the resuming session can open.
rm -f docs/specs/resumable.md
# Captured first, never piped straight into grep -q: this file runs under
# pipefail, and grep -q exits on the first match, which SIGPIPEs the command
# feeding it. The pipeline then reports 141 and the assertion fails while the
# text it was looking for is sitting right there in the output.
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -q 'NOT FOUND' \
  && ok "a missing spec is called out as missing" \
  || bad "brief was quiet about a spec that is not there"
printf '# spec\n' > docs/specs/resumable.md

# Phase 3 is the only phase where the RED receipt can still exist: every
# transition deletes it, so at 4 and 5 the line could only ever read "not
# verified" whatever actually happened.
phase 3
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -q 'RED:' \
  && ok "the RED line appears at Phase 3, where the receipt can be true" \
  || bad "brief dropped the RED line at Phase 3"

phase 4 --force
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -q 'RED:' \
  && bad "brief reported RED at Phase 4, where entering deleted the receipt" \
  || ok "no RED line at Phase 4, where it could only ever say 'not verified'"
printf '%s' "$BOUT" | grep -q 'checks:' \
  && ok "the checks line appears at Phase 4, where the marker can be true" \
  || bad "brief dropped the checks line at Phase 4"

printf 'declined finding 2, the scale was 200 rows\n' \
  | .claude/hooks/phase.sh journal >/dev/null 2>&1
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -q 'declined finding 2' \
  && ok "the journal reaches the briefing" \
  || bad "brief did not surface the journal"
# The journal is the only thing in the briefing the model wrote itself, and the
# only part that can be confidently wrong. It is labelled as testimony rather
# than as state, and this asserts the labelling did not quietly go away.
printf '%s' "$BOUT" | grep -qi 'not verified state' \
  && ok "and is marked as the previous session's notes, not as verified state" \
  || bad "the journal is presented without saying it is unverified testimony"

phase 5
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -q 'did NOT survive' \
  && ok "the reviewer-session warning appears at Phase 5, where reviewers exist" \
  || bad "brief did not say the reviewer sessions are gone at Phase 5"
printf '%s' "$BOUT" | grep -q 'checks:' \
  && bad "brief reported checks at Phase 5, where entering deleted the marker" \
  || ok "no checks line at Phase 5, where it could only ever say 'none recorded'"

# A new task inheriting the last one's findings is a briefing that lies.
phase start another
[ -s .claude/spec-journal.md ] \
  && bad "a new task inherited the previous task's journal" \
  || ok "start clears the journal"
printf 'x\n' | .claude/hooks/phase.sh journal >/dev/null 2>&1
phase off
[ -f .claude/spec-journal.md ] \
  && bad "off left the journal behind" || ok "off clears the journal"

# The same rule, one section down. The journal was scoped to the task; the
# reviewer verdicts were scoped to the repo and printed under whatever task
# happened to be armed — so a fresh task's briefing opened with a verdict about
# work it has nothing to do with, in the register the briefing reserves for
# facts read off disk.
setup_repo
printf '{"t":"2026-08-01T10:00:00Z","agent":"spec-adversary","msg":"sound - the parser slice is clean"}\n' \
  > .claude/review-log.jsonl
phase start parser-task
phase off
phase start unrelated-new-task
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -q 'the parser slice is clean' \
  && bad "a fresh task's briefing carried the previous task's reviewer verdict" \
  || ok "verdicts from a previous task do not appear under a new one"
# Scoped, not deleted: the log is the only durable record that a review happened.
[ -s .claude/review-log.jsonl ] \
  && ok "and the log itself survives, since it is the only audit trail there is" \
  || bad "scoping the section destroyed the review log"

# Where they DO belong, they are still there — and still marked as the reviewer's
# claim rather than as a verified fact, the way the journal above it is.
phase 2; phase 3; phase 4 --force; phase 5
printf '{"t":"2026-08-09T10:00:00Z","agent":"spec-adversary","msg":"one finding: the retry loop never terminates"}\n' \
  >> .claude/review-log.jsonl
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -q 'the retry loop never terminates' \
  && ok "a verdict recorded during this task does reach the briefing" \
  || bad "brief dropped a verdict belonging to the current task"

# A malformed line is not hypothetical on an append-only log written by a hook
# that can be killed mid-write. jq aborts the whole stream on the first bad
# line and prints nothing; python3 skips it and prints the rest. The header was
# printed before either ran, so the failure mode was an assertion with nothing
# under it.
printf 'not json at all\n' >> .claude/review-log.jsonl
printf '{"t":"2026-08-09T11:00:00Z","agent":"spec-adversary","msg":"second round: fixed"}\n' \
  >> .claude/review-log.jsonl
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -q 'second round: fixed' \
  && ok "a torn line does not cost the verdicts written after it" \
  || bad "one malformed line silenced every verdict after it"
printf '%s' "$BOUT" | grep -q 'Reviewer verdicts on record' \
  && ok "and the section that was printed has content under it" \
  || bad "the verdict section vanished entirely on a torn line"

# The complement: the header must not appear with nothing beneath it.
printf 'not json\nnot json either\n' > .claude/review-log.jsonl
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -q 'Reviewer verdicts on record' \
  && bad "brief asserted verdicts on record and listed none" \
  || ok "no verdict header when nothing could be read"

################################################################################
# The guard reads ARGV out of the command with a regex, and a regex over text is
# the mistake this whole layer was rewritten to stop making. `.*phase\.sh` is
# greedy, so on a line with two calls it matched the LAST one; `head -1` took the
# first LINE. Either way the guard judged a call that was not the dangerous one
# while the dangerous one still ran — every transition and every --force
# reachable by appending a harmless second call.
group "every phase.sh in the command is judged, not one of them"
setup_repo; phase start decoy; phase 2; phase 3

expect_b "the bare force is denied" \
  DENY '.claude/hooks/phase.sh 4 --force'
expect_b "a trailing decoy does not launder it" \
  DENY '.claude/hooks/phase.sh 4 --force ; .claude/hooks/phase.sh status'
expect_b "nor does one joined with &&" \
  DENY '.claude/hooks/phase.sh 4 --force && .claude/hooks/phase.sh status'
expect_b "nor a leading decoy on the line before" \
  DENY '.claude/hooks/phase.sh status
.claude/hooks/phase.sh 4 --force'
expect_b "nor a leading decoy in the same segment list" \
  DENY '.claude/hooks/phase.sh status ; .claude/hooks/phase.sh 4 --force'
# A forward skip, not a retreat: 3 -> 2 is strictly more restrictive and is the
# model's to take, so it would be allowed behind a decoy or not.
expect_b "and a plain forward skip is covered the same way" \
  DENY '.claude/hooks/phase.sh status ; .claude/hooks/phase.sh 5'

# The end-to-end half: a decision the guard got right is worth nothing if the
# phase moved anyway.
PH_BEFORE=$(.claude/hooks/phase.sh status 2>&1 | head -1)
[ "$(guard "$(pl_bash '.claude/hooks/phase.sh 4 --force ; .claude/hooks/phase.sh status')")" = DENY ] \
  && ok "so the decoy transition never reaches phase.sh" \
  || bad "the decoy transition was allowed through to phase.sh"
printf '%s' "$PH_BEFORE" | grep -q 'phase 3' \
  && ok "and the repo is still standing in Phase 3" \
  || bad "the repo left Phase 3: $PH_BEFORE"

# Two benign calls must stay benign, or the fix is just a different denial bug.
expect_b "two reads in one command are still allowed" \
  ALLOW '.claude/hooks/phase.sh status ; .claude/hooks/phase.sh status'
expect_b "and an unrelated --force beside a read still is not a phase override" \
  ALLOW 'git push --force && .claude/hooks/phase.sh status'

################################################################################
# A PreToolUse hook that is killed emits no JSON, and no JSON is read as no
# decision — so the call proceeds. That makes "how long the guard takes" a
# security property, not a performance one: any command that outruns the 15s
# timeout in hooks.json is allowed by default. scan_state_tokens forked one awk
# per argument with no budget, so the cost was linear in a number the model picks.
group "a large command cannot outrun the hook's own timeout"
setup_repo; phase start budget; phase 2; phase 3

BIGARGS=$(python3 -c "print(' '.join('w%d' % i for i in range(6000)))")
T0=$(date +%s)
expect_b "a command with more tokens than the budget is refused, not scanned" \
  DENY "bash $BIGARGS ; rm -f .claude/.spec-phase"
T1=$(date +%s)
[ $((T1 - T0)) -le 5 ] \
  && ok "and the refusal lands in $((T1 - T0))s, well inside the 15s timeout" \
  || bad "the guard took $((T1 - T0))s on 6000 tokens — past the timeout, so it fails open"

# The same starvation without any shell verb: the phase policy's own segment
# walk accumulated words into a string, which is quadratic in the word count.
BIGW=$(python3 -c "print(' '.join('w%d' % i for i in range(20000)))")
T0=$(date +%s)
expect_b "and a production write behind a wall of words is still refused" \
  DENY "echo $BIGW >/dev/null ; echo pwned > src/evil.ts"
T1=$(date +%s)
[ $((T1 - T0)) -le 5 ] \
  && ok "and that refusal lands in $((T1 - T0))s too" \
  || bad "the phase policy took $((T1 - T0))s on 20000 words — past the timeout"

# The budget must not fire on ordinary work, or it becomes a denial-of-service on
# the user instead of on the model.
expect_b "an ordinary command is nowhere near the budget" \
  ALLOW 'ls -la src/ && git status --porcelain'
# A heredoc body is data, not tokens — the journal and validation reports are
# prose and can be long, so length alone must never be the thing that refuses.
LONGPROSE=$(python3 -c "print('\n'.join('finding %d: considered and declined, see spec' % i for i in range(400)))")
expect_b "a long validation report is prose, not a token flood" ALLOW ".claude/hooks/phase.sh journal <<'EOF'
$LONGPROSE
EOF"

################################################################################
# The runtime-computed-target check sat inside the write-target loop, which is
# below `[ \"\$PHASE\" -ge 4 ] && exit 0`. So at Phase 4 — the only phase the
# validation marker exists in, and the phase whose exit the marker gates — a
# target the shell computes was never examined at all. This is the same
# structural mistake the token rewrite set out to fix, in the one path it did not
# move.
group "a target the shell computes is refused at every phase"
setup_repo; phase start runtime; phase 2; phase 3; phase 4 --force

expect_b "a command-substituted marker path is refused at Phase 4" \
  DENY 'printf "task=runtime\nslice=1/1\n" > "$(echo .claude/.spec-validation)"'
[ -f .claude/.spec-validation ] \
  && bad "the refused command still wrote the marker" \
  || ok "and no marker was written"
expect_b "so is one built from a variable" \
  DENY 'V=.spec-validation; printf "task=runtime\nslice=1/1\n" > .claude/$V'
expect_b "and one built with backticks" \
  DENY 'printf x > `echo .claude/.spec-phase`'
.claude/hooks/phase.sh 5 >/dev/null 2>&1 \
  && bad "4 -> 5 cleared with nothing run" \
  || ok "so 4 -> 5 still refuses"

# Reading is not writing: the deny is scoped to write targets, so an ordinary
# read through a substitution must stay allowed at every phase.
expect_b "a command substitution that writes nothing is untouched" \
  ALLOW 'grep -l TODO $(git ls-files)'

################################################################################
# The token list can never be complete — find, git stash, an interpreter and an
# env-assignment prefix all reach the same inodes, and each needed its own case.
# These are the spellings the third review found; they are pinned here so the
# next round finds new ones rather than these.
group "the deletion routes the verb list missed"
setup_repo; phase start spell; phase 2; phase 3

expect_b "a glob relative to a cd'd directory" \
  DENY 'cd .claude && rm -f .spec-*'
expect_b "find -delete by name" \
  DENY "find .claude -name '.spec-*' -delete"
expect_b "find -delete with no name at all" \
  DENY 'find .claude -type f -delete'
expect_b "find -exec rm" \
  DENY 'find .claude -name ".spec-*" -exec rm {} ;'
expect_b "git stash --all, which removes ignored files exactly as clean -x does" \
  DENY 'git stash --all'
expect_b "and its short spelling" \
  DENY 'git stash -a'
expect_b "an interpreter given the unlink as an argument" \
  DENY "python3 -c \"import os; os.remove('.claude/.spec-phase')\""
expect_b "and another interpreter, same shape" \
  DENY 'node -e "require(`fs`).unlinkSync(`.claude/.spec-phase`)"'
expect_b "a fused -c flag, which is one token starting with a dash" \
  DENY "bash -c'rm -f .claude/.spec-red && echo x'"
expect_b "an env-assignment prefix whose value contains a slash" \
  DENY 'FOO=a/b git clean -fdx'

# The complements, so none of the above became a blanket refusal.
setup_repo; phase start spell2; phase 2; phase 3
expect_b "an ordinary find that deletes nothing"     ALLOW 'find src -name "*.ts"'
expect_b "a find -delete outside .claude"            ALLOW 'find build -type f -delete'
expect_b "git stash without -a/-u leaves them alone" ALLOW 'git stash'
expect_b "an interpreter doing ordinary work"        ALLOW 'python3 -c "print(1 + 1)"'
expect_b "and an env prefix on an innocent command"  ALLOW 'FOO=a/b git status'

################################################################################
# Deleting a marker only re-arms a gate; forging one clears it. Every route above
# is a deletion route, so the guard's job there is containment — but the marker
# itself must be unforgeable, or one missed write spelling is the whole gate. The
# key lives under .git/, which is not a working-tree path: no git clean, no git
# stash --all and no `rm -rf .claude` reaches it.
group "the gate markers are authenticated, not merely present"
setup_repo; phase start forge; phase 2; phase 3; phase 4 --force

# Written by hand, with every field the tripwire reads set correctly.
printf 'task=forge\nslice=1/1\n' > .claude/.spec-validation
.claude/hooks/phase.sh 5 >/dev/null 2>&1 \
  && bad "a hand-written validation marker cleared 4 -> 5" \
  || ok "a hand-written validation marker does not clear 4 -> 5"
FOUT=$(.claude/hooks/phase.sh 5 2>&1)
printf '%s' "$FOUT" | grep -qi 'not written by phase.sh\|could not be authenticated\|written by hand' \
  && ok "and the refusal says the marker was not machine-written" \
  || bad "the refusal does not explain the marker was forged: $FOUT"

# The legitimate writer must still clear it, or the gate is simply broken.
setup_repo; phase start forge2; phase 2; phase 3; phase 4 --force
.claude/hooks/phase.sh validation >/dev/null 2>&1 <<'EOF'
Commands: make test
Result:   pass, 12 assertions
EOF
.claude/hooks/phase.sh 5 >/dev/null 2>&1 \
  && ok "a marker written by phase.sh validation does clear 4 -> 5" \
  || bad "the real validation path no longer clears 4 -> 5"

# A tampered authenticator with every readable field left correct. task= and
# slice= already have their own check, so this is the case that isolates the MAC:
# before it existed there was nothing here to tamper with, and the marker cleared.
setup_repo; phase start forge3; phase 2; phase 3; phase 4 --force
.claude/hooks/phase.sh validation >/dev/null 2>&1 <<'EOF'
Commands: make test
Result:   pass
EOF
sed 's/^mac=.*/mac=0000000000000000000000000000000000000000000000000000000000000000/' \
  .claude/.spec-validation > .claude/.spec-validation.x
mv .claude/.spec-validation.x .claude/.spec-validation
.claude/hooks/phase.sh 5 >/dev/null 2>&1 \
  && bad "a marker with a wrong authenticator still cleared 4 -> 5" \
  || ok "a wrong authenticator voids the marker even with the fields intact"

# The key is outside the working tree, so the routes that remove every state file
# cannot remove it — and a marker cannot be re-minted by wiping the key and
# writing a fresh pair.
setup_repo; phase start forge4; phase 2; phase 3; phase 4 --force
.claude/hooks/phase.sh validation >/dev/null 2>&1 <<'EOF'
Commands: make test
Result:   pass
EOF
[ -f "$(git rev-parse --git-dir)/spec-gate-key" ] \
  && ok "the key lives under .git/, where no working-tree wipe reaches it" \
  || bad "no key under .git/ — the marker cannot be authenticated across a clean"
git clean -fdx >/dev/null 2>&1
[ -f "$(git rev-parse --git-dir)/spec-gate-key" ] \
  && ok "and git clean -fdx leaves it standing" \
  || bad "git clean -fdx removed the authentication key"

################################################################################
# brief tested `[ -f "$VALIDATION" ]` while the tripwire additionally required
# the task and slice to match — so a stale marker was reported to a resuming
# session as a recorded report, and the transition then refused it. A briefing
# that contradicts the gate it is describing is the one thing brief must not do.
group "brief agrees with the tripwire about the marker"
setup_repo; phase start bstale; phase 2; phase 3; phase 4 --force
printf 'task=somethingelse\nslice=9/9\n' > .claude/.spec-validation
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -qi 'a validation report is recorded' \
  && bad "brief called a stale marker a recorded report" \
  || ok "brief does not call a stale marker a recorded report"
printf '%s' "$BOUT" | grep -qi 'checks:' \
  && ok "and it still says something about the checks" \
  || bad "brief dropped the checks line entirely"

# The agreeing case, both directions.
setup_repo; phase start bfresh; phase 2; phase 3; phase 4 --force
.claude/hooks/phase.sh validation >/dev/null 2>&1 <<'EOF'
Commands: make test
Result:   pass
EOF
BOUT=$(.claude/hooks/phase.sh brief 2>&1)
printf '%s' "$BOUT" | grep -qi 'a validation report is recorded' \
  && ok "a real report is reported as one" \
  || bad "brief did not see the real report: $BOUT"

################################################################################
# .claude/spec-gate-test-cmd is writable in every phase by design, and phase.sh
# red executes its contents as shell. Two allowed calls therefore disarmed the
# whole workflow: write the payload, run the gate's own verifier. That makes the
# marker hardening above moot, so it is closed here in the same pass.
group "the configured test command cannot disarm the gate"
# A changed test file first, or `red` refuses before it ever runs the command and
# the payload below is never reached — the test would pass having proved nothing.
setup_repo; phase start tcmd; phase 2; phase 3
echo 'it("fails", () => expect(1).toBe(2))' > src/x.test.ts

printf 'rm -f .claude/.spec-phase .claude/.spec-baseline; exit 1\n' > .claude/spec-gate-test-cmd
.claude/hooks/phase.sh red >/dev/null 2>&1
[ -f .claude/.spec-phase ] \
  && ok "phase.sh red did not let its test command remove the phase state" \
  || bad "the configured test command disarmed the workflow"

setup_repo; phase start tcmd2; phase 2; phase 3
echo 'it("fails", () => expect(1).toBe(2))' > src/x.test.ts
printf 'rm -rf .claude; exit 1\n' > .claude/spec-gate-test-cmd
.claude/hooks/phase.sh red >/dev/null 2>&1
[ -f .claude/.spec-phase ] \
  && ok "nor to take the directory instead" \
  || bad "the configured test command removed the state directory"

# An ordinary test command must still run, or this is just a broken feature.
# RED needs a changed test file to have anything to certify, so write one first.
setup_repo; phase start tcmd3; phase 2; phase 3
echo 'it("fails", () => expect(1).toBe(2))' > src/x.test.ts
printf 'exit 1\n' > .claude/spec-gate-test-cmd
ROUT=$(.claude/hooks/phase.sh red 2>&1)
printf '%s' "$ROUT" | grep -qi 'RED verified\|tests failed as required' \
  && ok "and an ordinary failing test command still verifies RED" \
  || bad "a legitimate test command no longer works: $ROUT"

################################################################################
# The budget's refusal has to be deliverable. `deny` is printf-then-exit, so
# inside `$( )` the JSON lands in the captured string and the exit ends only the
# subshell — the hook then falls off the end having printed nothing, and no
# output reads as no decision. The scanners share one counter, so a command
# sized to survive the state scan and run out during the phase-call walk got no
# transition gating at all: the control below denies, and the same call behind a
# thousand filler words was allowed and advanced.
group "a refusal is delivered from wherever it is raised"
setup_repo; phase start deliver; phase 2; phase 3; phase 4 --force

FILLER=$(python3 -c "print(' '.join('w%d' % i for i in range(1000)))")
expect_b "the control refuses" \
  DENY '.claude/hooks/phase.sh 5 --force'
expect_b "and filler in front of it does not buy the transition" \
  DENY "echo $FILLER >/dev/null ; .claude/hooks/phase.sh 5 --force"
# Emptiness is the tell: a swallowed deny leaves the hook silent rather than
# allowing out loud, so assert on the bytes as well as on the decision.
OUT=$(pl_bash "echo $FILLER >/dev/null ; .claude/hooks/phase.sh 5 --force" | .claude/hooks/phase-guard.sh 2>/dev/null)
[ -n "$OUT" ] \
  && ok "and the hook actually emitted a decision rather than going quiet" \
  || bad "the hook printed nothing — a swallowed deny reads as permission"
PH=$(.claude/hooks/phase.sh status 2>&1 | head -1)
printf '%s' "$PH" | grep -q 'phase 4' \
  && ok "so the repo is still standing in Phase 4" \
  || bad "the repo left Phase 4: $PH"

# The same for the gate that only asks: an ASK swallowed the same way becomes an
# allow, which is worse than the denial it replaced.
expect_b "an ask is delivered behind filler too" \
  ASK "echo $FILLER >/dev/null ; .claude/hooks/phase.sh off"

# The lex counter was incremented inside lex_command, which is only ever called
# as `$(lex_command ...)` — so every increment was discarded in a subshell and
# the bound never existed. One recursion per argument means the fork count is
# the model's to choose.
setup_repo; phase start lexbudget; phase 2; phase 3
MANY=$(python3 -c "print(' '.join('a%d' % i for i in range(200)))")
T0=$(date +%s)
expect_b "two hundred nested payloads exhaust the lex budget" \
  DENY "bash $MANY ; rm -f .claude/.spec-phase"
T1=$(date +%s)
[ $((T1 - T0)) -le 5 ] \
  && ok "and it refuses in $((T1 - T0))s rather than forking on" \
  || bad "200 payloads took $((T1 - T0))s — the lex bound is not holding"

################################################################################
# The budget counted tokens; the cost is in bytes. `${T##*/}` is quadratic in
# bash 3.2 — the file's own header says so about the string walk it replaced —
# and it runs per token, so ONE long token costs everything while the token
# count stays at 1. A 130 KB command outran the 15s timeout with the budget
# untouched, which is the same fail-open by the other axis.
group "one enormous token cannot outrun the timeout either"
setup_repo; phase start bytes; phase 2; phase 3

BIGTOK=$(python3 -c "print('A' * 200000)")
T0=$(date +%s)
expect_b "a 200 KB single token is decided, not scanned forever" \
  DENY "echo $BIGTOK > src/evil.ts"
T1=$(date +%s)
[ $((T1 - T0)) -le 5 ] \
  && ok "and the decision lands in $((T1 - T0))s" \
  || bad "one 200 KB token took $((T1 - T0))s — past the timeout, so it fails open"

# Long prose must still be free: heredoc bodies are data, and a validation
# report or a plan document is legitimately large.
LONGDOC=$(python3 -c "print('\n'.join('line %d of a long plan document' % i for i in range(3000)))")
T0=$(date +%s)
expect_b "a long heredoc document is not a size problem" ALLOW ".claude/hooks/phase.sh journal <<'EOF'
$LONGDOC
EOF"
T1=$(date +%s)
[ $((T1 - T0)) -le 5 ] \
  && ok "and it is handled in $((T1 - T0))s, since the body never becomes tokens" \
  || bad "a long heredoc took $((T1 - T0))s"

################################################################################
# A heredoc body is data — correct for prose, fatal when the verb reads stdin.
# The lexer consumes the body and emits nothing, so an interpreter fed its
# program on stdin was a channel the scanner was built to look away from. The
# -c spellings of the same commands are denied, which is what makes this a gap
# rather than a policy.
group "a heredoc handed to a shell is shell, not prose"
setup_repo; phase start hdoc; phase 2; phase 3

expect_b "bash reading its script from a heredoc" DENY 'bash <<EOF
rm -f .claude/.spec-phase
EOF'
expect_b "python3 reading its program from a heredoc" DENY 'python3 <<EOF
import os
os.remove(".claude/.spec-phase")
EOF'
expect_b "and the explicit stdin form" DENY 'python3 - <<EOF
import os
os.remove(".claude/.spec-phase")
EOF'
expect_b "a phase transition hidden in a heredoc" DENY 'bash <<EOF
.claude/hooks/phase.sh 4 --force
EOF'
# The prose case is the whole reason bodies are data. It must stay allowed.
expect_b "a journal entry naming a state file is still prose" ALLOW ".claude/hooks/phase.sh journal <<'EOF'
tried to write .claude/.spec-phase directly and the guard refused, correctly
EOF"
expect_b "and a heredoc into a file that is not a shell" ALLOW 'cat > docs/specs/notes.md <<EOF
rm -f .claude/.spec-phase is what I was told not to do
EOF'

################################################################################
# The verb decides how every other token is read, so a verb the guard cannot
# resolve is a command it cannot classify. A path in a variable was skipped by
# the assignment filter before anything looked at its value, and a shell reading
# its script from a redirect names the script in a place the lexer discards.
# Neither is exotic and both are complete overrides, since phase.sh has no gate
# of its own.
group "an unresolvable verb is refused, not skipped"
setup_repo; phase start verb; phase 2; phase 3

expect_b "a phase.sh path held in a variable" \
  DENY 'P=.claude/hooks/phase.sh; $P 4 --force'
expect_b "and the same quoted" \
  DENY 'P=.claude/hooks/phase.sh; "$P" 4 --force'
expect_b "a shell reading its script from a redirect" \
  DENY 'bash -s 4 --force < .claude/hooks/phase.sh'
expect_b "and one reading it from a pipe" \
  DENY 'cat .claude/hooks/phase.sh | bash -s 4 --force'
PH=$(.claude/hooks/phase.sh status 2>&1 | head -1)
printf '%s' "$PH" | grep -q 'phase 3' \
  && ok "and none of them moved the phase" \
  || bad "the phase moved: $PH"

# Ordinary redirects and ordinary variables must survive.
expect_b "an input redirect into something that is not a shell" ALLOW 'sort < src/x.ts'
expect_b "a variable used as data rather than as a verb"       ALLOW 'F=src/x.ts; grep TODO $F'

################################################################################
# The key is what makes the marker unforgeable, and it was not in any protected
# list — so it could be replaced, and a model that can choose the key can mint
# any marker it likes. Reading it was the threat the README described; replacing
# it is cheaper and was free.
group "the marker key is protected like the markers"
setup_repo; phase start key; phase 2; phase 3

expect_b "the key cannot be overwritten"      DENY 'printf x > .git/spec-gate-key'
expect_b "nor removed"                        DENY 'rm -f .git/spec-gate-key'
expect_b "nor moved"                          DENY 'mv .git/spec-gate-key /tmp/k'
expect_b "and not at Phase 4 either"          DENY 'printf x > .git/spec-gate-key'
setup_repo; phase start key2; phase 2; phase 3; phase 4 --force
expect_b "the key is protected past the phase-4 exit" \
  DENY 'printf x > .git/spec-gate-key'
expect_b "a glob that would expand onto the key" \
  DENY 'rm -f .git/spec-gate-*'
expect_b "the same glob reached through a cd" \
  DENY 'cd .git && rm -f spec-gate-*'
expect_b "and find aimed at the directory holding it" \
  DENY 'find .git -type f -delete'
expect_b "and taking the whole directory it lives in" \
  DENY 'rm -rf .git'
# The .claude sibling must stay writable: spec-gate-test-cmd is gate config the
# model has to be able to create, and it shares the spec-gate- prefix.
expect_b "the test-command glob is not the key glob" \
  ALLOW 'ls .claude/spec-gate-*'
# Ordinary git work must not be caught by this.
expect_b "ordinary git commands are untouched" ALLOW 'git log --oneline -5'
expect_b "and so is writing inside .git by git itself" ALLOW 'git commit -am wip'

################################################################################
# The verifier put the gate's state aside and read a missing backup as "nothing
# moved", so the test command only had to delete the backup — and it could
# rewrite the backup instead, in which case restore installed the rewrite while
# reporting that the damage had been undone.
group "the state snapshot cannot be turned against the gate"
setup_repo; phase start bak; phase 2; phase 3
echo 'it("f", () => expect(1).toBe(2))' > src/x.test.ts

printf 'rm -f .claude/.spec-phase; rm -rf .git/spec-gate-statebak; exit 1\n' > .claude/spec-gate-test-cmd
.claude/hooks/phase.sh red >/dev/null 2>&1
[ -f .claude/.spec-phase ] \
  && ok "deleting the backup does not let the payload through" \
  || bad "the test command deleted the backup and disarmed the gate"

setup_repo; phase start bak2; phase 2; phase 3
echo 'it("f", () => expect(1).toBe(2))' > src/x.test.ts
printf 'D=$(ls -d .git/spec-gate-statebak 2>/dev/null); [ -n "$D" ] && printf "phase=4\\ntask=bak2\\nslice=1/1\\n" > "$D"/*spec-phase* ; exit 1\n' \
  > .claude/spec-gate-test-cmd
.claude/hooks/phase.sh red >/dev/null 2>&1
BP=$(sed -n 's/^phase=//p' .claude/.spec-phase 2>/dev/null | head -1)
[ "$BP" = 3 ] \
  && ok "rewriting the backup does not get installed as the restore" \
  || bad "the backup was rewritten and restored as phase=$BP"

# The snapshot is held in memory, so there is nothing on disk for a payload to
# find. A directory — even from mktemp — is walkable: deleting it was enough to
# disarm the gate, however loudly the restore complained afterwards.
setup_repo; phase start bak3; phase 2; phase 3
echo 'it("f", () => expect(1).toBe(2))' > src/x.test.ts
# TMPDIR is pointed at a scratch directory the payload then empties, so a
# snapshot taken with mktemp -d would land there and be swept. Aimed at that
# directory rather than at the real TMPDIR, which is where this suite keeps its
# own fixture — the sweep would otherwise delete the repo under test.
mkdir -p "$WORK/sweep"
printf 'rm -f .claude/.spec-phase; rm -rf "${TMPDIR%%/}"/* 2>/dev/null; exit 1\n' \
  > .claude/spec-gate-test-cmd
TMPDIR="$WORK/sweep" .claude/hooks/phase.sh red >/dev/null 2>&1
[ -f .claude/.spec-phase ] \
  && ok "a payload sweeping TMPDIR cannot reach the snapshot" \
  || bad "the snapshot was found on disk and the gate was disarmed"
[ -d .git/spec-gate-statebak ] \
  && bad "a state backup directory was left on disk" \
  || ok "and no backup directory exists to be found in the first place"

################################################################################
# find rooted at '.' covers the state directory, so any -delete denied — which
# is most ordinary cleanup. A -name that cannot match a state file is not a
# threat and must not be treated as one.
group "find is judged on what it would actually reach"
setup_repo; phase start findfp; phase 2; phase 3

expect_b "a filtered find that cannot match state"   ALLOW 'find . -name "*.pyc" -delete'
expect_b "and one rooted in the tree with a filter"  ALLOW 'find . -name "*.log" -delete'
expect_b "an unfiltered find still reaches them"     DENY  'find . -type f -delete'
expect_b "and a filter that does match is refused"   DENY  'find . -name ".spec-*" -delete'

################################################################################
# phase.sh reads ${BASH_SOURCE[0]} under `set -u` to find its policy file. Fed
# on stdin there is no BASH_SOURCE, so it aborted — and the degraded path it
# aborted into treats an unverifiable RED as grounds to advance.
group "phase.sh degrades closed, not open"
setup_repo; phase start degrade; phase 2; phase 3

SOUT=$(bash -s status < .claude/hooks/phase.sh 2>&1)
printf '%s' "$SOUT" | grep -q 'unbound variable' \
  && bad "phase.sh aborted on BASH_SOURCE when read from stdin: $SOUT" \
  || ok "phase.sh survives being read from stdin"

# phase.sh itself advances here and says it verified nothing — it is the user's
# control surface, not the gate. The enforcement is phase-guard, which refuses
# 3 -> 4 on any receipt state but 'valid'. So the property to pin is the guard's,
# in both degraded states: no test command to run, and no policy file at all.
setup_repo; phase start degrade2; phase 2; phase 3
expect_b "the guard refuses 3 -> 4 with RED unverifiable" \
  DENY '.claude/hooks/phase.sh 4'
mv .claude/hooks/phase-policy.sh .claude/hooks/phase-policy.sh.off
expect_b "and refuses every write with no policy file to read" \
  DENY 'echo x > src/evil.ts'
expect_b "including the transition itself" \
  DENY '.claude/hooks/phase.sh 4'
mv .claude/hooks/phase-policy.sh.off .claude/hooks/phase-policy.sh

################################################################################
# The verb filter skipped an assignment token whole, so nothing ever looked at
# its value — and a redirect target that is only `$V` names no state and has no
# literal prefix to test, so the computed-target rule found nothing either. Past
# the phase-4 exit, where the write scan no longer runs, that made every state
# file writable through one variable. The previous round tested the shape where
# `.claude/` is still visible in the token; this is the other half.
group "a path is judged after the variable holding it is resolved"
setup_repo; phase start resolv; phase 2; phase 3; phase 4 --force

expect_b "the whole path in a variable, as a redirect target" \
  DENY 'V=.claude/.spec-phase; printf "phase=4\ntask=t\nslice=1/1\n" > $V'
expect_b "the signing key the same way" \
  DENY 'K=.git/spec-gate-key; printf deadbeef > $K'
expect_b "and quoted" \
  DENY 'V=.claude/.spec-validation; printf x > "$V"'
expect_b "and in braces" \
  DENY 'V=.claude/.spec-red; printf x > ${V}'
expect_b "the same variable handed to rm" \
  DENY 'V=.claude/.spec-phase; rm -f $V'
# A variable that does not name state is ordinary work and must stay so.
expect_b "an ordinary variable target is untouched" \
  ALLOW 'L=build/out.log; echo hi > $L'
expect_b "and an unset one is not assumed to be state" \
  ALLOW 'echo hi > $LOGFILE'

################################################################################
# The verb was refused when it could not be resolved; the arguments were not.
# phase.sh has no gate of its own, so the destination phase and --force arriving
# through a variable meant the guard evaluated a call it had misread — and the
# `case "$ARG"` had no default arm, so an unrecognised destination decided
# nothing at all.
group "a phase.sh call is refused when its arguments cannot be read"
setup_repo; phase start argres; phase 2; phase 3; phase 4 --force

expect_b "the control refuses"                DENY '.claude/hooks/phase.sh 5 --force'
expect_b "--force through a variable"         DENY 'F=--force; .claude/hooks/phase.sh 5 $F'
expect_b "the destination through a variable" DENY 'N=5; .claude/hooks/phase.sh $N --force'
expect_b "a destination from a substitution"  DENY '.claude/hooks/phase.sh $(echo 5) --force'
expect_b "arguments arriving on xargs stdin"  DENY 'printf %s "5 --force" | xargs .claude/hooks/phase.sh'
PH=$(.claude/hooks/phase.sh status 2>&1 | head -1)
printf '%s' "$PH" | grep -q 'phase 4' \
  && ok "and none of them moved the phase" \
  || bad "the phase moved: $PH"
# Resolvable arguments still work, in both directions.
setup_repo; phase start argres2; phase 2; phase 3
expect_b "a resolvable variable is read, not just refused" \
  DENY 'N=4; .claude/hooks/phase.sh $N'
expect_b "and reading the phase is still free" \
  ALLOW 'C=status; .claude/hooks/phase.sh $C'

################################################################################
# decide/deny/ask all exit, and the phase walk runs before the write scan — so
# the first call that produced a decision ended the hook and spoke for the whole
# command. The deny direction was fixed by judging every call; the allow and ask
# directions were not, and an early one authorised everything after it.
group "an allow speaks for one call, not for the command"
setup_repo; phase start shortc; phase 2; phase 3

expect_b "the write alone is refused" DENY 'echo pwned > src/evil.ts'
expect_b "and a read-only phase call does not launder it" \
  DENY '.claude/hooks/phase.sh status ; echo pwned > src/evil.ts'
expect_b "nor does one that would be asked about" \
  DENY '.claude/hooks/phase.sh slices 2 ; echo pwned > src/evil.ts'
expect_b "nor a transition that is allowed on its own" \
  DENY '.claude/hooks/phase.sh 2 ; echo pwned > src/evil.ts'
# The allow itself must survive when nothing else in the command objects.
expect_b "a lone allowed call is still allowed" ALLOW '.claude/hooks/phase.sh status'
expect_b "and one beside harmless work"         ALLOW '.claude/hooks/phase.sh status ; ls src/'

################################################################################
# `<<<` was lexed as a plain segment separator, so the script after it became an
# ordinary word in a new segment, was never re-read as shell, and the
# reads-stdin refusal could not fire because neither a redirect nor a pipe was
# involved.
group "a herestring handed to a shell is shell"
setup_repo; phase start herestr; phase 2; phase 3

expect_b "a shell reading its script from a herestring" \
  DENY "bash <<< 'rm -f .claude/.spec-phase; echo gone'"
expect_b "a transition hidden in one" \
  DENY "bash <<< '.claude/hooks/phase.sh 4 --force'"
expect_b "a production write hidden in one" \
  DENY "bash <<< 'echo pwned > src/evil.ts'"
expect_b "and an interpreter given one" \
  DENY "python3 <<< 'import os; os.remove(\".claude/.spec-phase\")'"
# A herestring to something that is not a shell is data.
expect_b "a herestring into grep is just input" ALLOW "grep -q orig <<< 'orig'"

################################################################################
# The SEP for an operator was emitted the moment the operator was seen, while
# only the end-of-line SEP was held back for a pending heredoc. So on `bash
# <<EOF | cat` the body arrived after the segment had already closed and the
# verb had become `cat`, and the body was discarded as prose.
group "a heredoc body belongs to the verb that opened it"
setup_repo; phase start hdverb; phase 2; phase 3

expect_b "a heredoc into a shell, piped onward" DENY 'bash <<EOF | cat
rm -f .claude/.spec-phase
EOF'
expect_b "a transition in one" DENY 'bash <<EOF | cat
.claude/hooks/phase.sh 4 --force
EOF'
expect_b "an interpreter heredoc, piped onward" DENY 'python3 <<EOF | cat
import os
os.remove(".claude/.spec-phase")
EOF'
expect_b "and one joined with &&" DENY 'bash <<EOF && echo done
rm -f .claude/.spec-phase
EOF'
# Prose piped onward is still prose.
expect_b "a journal entry piped onward is not a program" ALLOW ".claude/hooks/phase.sh journal <<'EOF' | cat
tried to write .claude/.spec-phase and the guard refused, correctly
EOF"

################################################################################
# The byte budget bounded the bash side, but the whole lexer runs first and
# builds each word one character at a time, which is quadratic. The cost was
# therefore paid in full before any counter moved: 700 KB in one word took 23s
# against a 15s timeout, and a killed hook emits no decision.
group "the cost is bounded before the lexer runs"
setup_repo; phase start prelex; phase 2; phase 3

for KB in 200 700; do
  BIGW=$(python3 -c "print('A' * ($KB * 1000))")
  T0=$(date +%s)
  D=$(guard "$(pl_bash "echo '$BIGW' > src/evil.ts")")
  T1=$(date +%s)
  [ "$D" = DENY ] \
    && ok "a ${KB} KB word is refused" \
    || bad "a ${KB} KB word was $D"
  [ $((T1 - T0)) -le 5 ] \
    && ok "and decided in $((T1 - T0))s, not at the timeout" \
    || bad "a ${KB} KB word took $((T1 - T0))s — past the timeout, so it fails open"
done

# Prose stays cheap: a heredoc body is read a line at a time, never a character
# at a time, so a long document must not be caught by the same bound.
LONGDOC=$(python3 -c "print('\n'.join('line %d of a long plan document' % i for i in range(3000)))")
T0=$(date +%s)
expect_b "a 3000-line journal entry is still prose" ALLOW ".claude/hooks/phase.sh journal <<'EOF'
$LONGDOC
EOF"
T1=$(date +%s)
[ $((T1 - T0)) -le 5 ] \
  && ok "and costs $((T1 - T0))s" \
  || bad "a long document took $((T1 - T0))s"

################################################################################
# Four review rounds running, each one found holes one axis over from the last
# round's fix, because each round's tests pinned the reproduction it was given
# rather than the rule. This group is shaped the other way: it enumerates the
# protected targets against every channel a command can deliver a payload
# through, and asserts they all reach the same decision as the bare spelling.
#
# The point is that adding a channel here costs one line and immediately tests
# it against every target, and adding a target costs one line and immediately
# tests it against every channel. A scanner that learns about a token kind in
# two places out of three fails this group rather than shipping.
group "coverage equivalence: every channel reaches the same decision"

# One payload, wrapped in each way a shell can carry it to the same effect.
chan() {   # $1 = channel name, $2 = shell payload
  case "$1" in
    bare)      printf '%s' "$2" ;;
    dash_c)    printf 'bash -c "%s"' "$2" ;;
    nested)    printf 'sh -c "bash -c \\"%s\\""' "$2" ;;
    herestring) printf "bash <<< '%s'" "$2" ;;
    heredoc)   printf 'bash <<CH_EOF\n%s\nCH_EOF' "$2" ;;
    heredoc2)  printf 'cat <<CH_A && bash <<CH_B\nprose\nCH_A\n%s\nCH_B' "$2" ;;
    after_read) printf '.claude/hooks/phase.sh status ; %s' "$2" ;;
    seq)       printf 'true ; %s' "$2" ;;
  esac
}
CHANNELS="bare dash_c nested herestring heredoc heredoc2 after_read seq"

setup_repo; phase start cover; phase 2; phase 3
for T in .claude/.spec-phase .claude/.spec-validation .git/spec-gate-key; do
  for C in $CHANNELS; do
    expect_b "[$C] rm -f $T" DENY "$(chan "$C" "rm -f $T")"
  done
done

# The same targets, reached by every way of spelling the PATH rather than every
# way of carrying the command. C1 of the sixth round lived here: the value on
# the right of an `=` was never looked at, and the resolver took the first
# assignment rather than the last.
setup_repo; phase start cover2; phase 2; phase 3
for T in .claude/.spec-phase .git/spec-gate-key; do
  expect_b "[literal] $T"           DENY "rm -f $T"
  expect_b "[variable] $T"          DENY "V=$T; rm -f \$V"
  expect_b "[braced] $T"            DENY "V=$T; rm -f \${V}"
  expect_b "[quoted] $T"            DENY "V=$T; rm -f \"\$V\""
  expect_b "[reassigned] $T"        DENY "V=safe.txt; V=$T; rm -f \$V"
  expect_b "[assigned, read] $T"    DENY "V=$T; cat \$V"
  expect_b "[dir + basename] $T"    DENY "A=${T##*/}; rm -f ${T%/*}/\$A"
  expect_b "[dir in a variable] $T" DENY "D=${T%/*}; rm -rf \$D"
done

# Production code during the tests-only phase, through the same channels. The
# write scan is a separate reader from the state scan and has its own idea of
# which token kinds exist, which is exactly how it came to miss heredoc bodies.
setup_repo; phase start cover3; phase 2; phase 3
for C in $CHANNELS; do
  expect_b "[$C] write production code" DENY "$(chan "$C" "echo pwned > src/evil.ts")"
done

# And the transitions, through the same channels: phase.sh has no gate of its
# own, so every one of these is a complete override if it is not seen.
setup_repo; phase start cover4; phase 2; phase 3
for C in $CHANNELS; do
  expect_b "[$C] force past the RED gate" \
    DENY "$(chan "$C" ".claude/hooks/phase.sh 4 --force")"
done
PH=$(.claude/hooks/phase.sh status 2>&1 | head -1)
printf '%s' "$PH" | grep -q 'phase 3' \
  && ok "and none of the channels moved the phase" \
  || bad "a channel moved the phase: $PH"

# The negative half. Every channel must still carry ordinary work, or the group
# above is satisfied by a guard that refuses everything.
setup_repo; phase start cover5; phase 2; phase 3
for C in $CHANNELS; do
  expect_b "[$C] ordinary work is untouched" ALLOW "$(chan "$C" "echo hello")"
done
# Prose that merely names a state file is not a command that touches one.
expect_b "prose naming a state file stays prose" ALLOW ".claude/hooks/phase.sh journal <<'EOF'
tried rm -f .claude/.spec-phase and the guard refused, correctly
EOF"
expect_b "and a spec document may describe one" ALLOW 'cat > docs/specs/notes.md <<EOF
never run rm -f .claude/.spec-phase
EOF'
expect_b "even beside a real shell heredoc" ALLOW 'bash <<CH_A && cat > docs/specs/n2.md <<CH_B
echo hello
CH_A
never run rm -f .claude/.spec-phase
CH_B'

################################################################################
# The snapshot phase.sh red restores from is keyed by state path. Records used
# to be separated in-band, and one of the files it snapshots is the journal —
# whose content the model writes. A separator in a journal entry therefore
# forged a record, and `phase.sh red` wrote it back: an arbitrary-path write
# performed by trusted code, reachable with two allowed commands.
group "the state snapshot cannot be forged through its own contents"
setup_repo; phase start inject; phase 2; phase 3
echo 'it("f", () => expect(1).toBe(2))' > src/x.test.ts
printf 'exit 1\n' > .claude/spec-gate-test-cmd

python3 -c 'import sys
sys.stdout.write("progress note\x1d.claude/.spec-phase\x1cphase=4\ntask=inject\nslice=1/1")' \
  | .claude/hooks/phase.sh journal >/dev/null 2>&1
.claude/hooks/phase.sh red >/dev/null 2>&1
BP=$(sed -n 's/^phase=//p' .claude/.spec-phase 2>/dev/null | head -1)
[ "$BP" = 3 ] \
  && ok "a forged record in the journal does not rewrite the phase" \
  || bad "the journal injected a snapshot record and the phase became $BP"

setup_repo; phase start inject2; phase 2; phase 3
echo 'it("f", () => expect(1).toBe(2))' > src/x.test.ts
printf 'exit 1\n' > .claude/spec-gate-test-cmd
python3 -c 'import sys
sys.stdout.write("note\x1dsrc/evil.ts\x1cPWNED")' \
  | .claude/hooks/phase.sh journal >/dev/null 2>&1
.claude/hooks/phase.sh red >/dev/null 2>&1
[ -f src/evil.ts ] \
  && bad "the snapshot restored a path that is not gate state" \
  || ok "and it cannot be steered at a path outside the state list"

# The journal itself must still round-trip: it is snapshotted like everything
# else, and an entry is prose that may contain anything.
setup_repo; phase start inject3; phase 2; phase 3
echo 'it("f", () => expect(1).toBe(2))' > src/x.test.ts
printf 'exit 1\n' > .claude/spec-gate-test-cmd
.claude/hooks/phase.sh journal >/dev/null 2>&1 <<'EOF'
an ordinary entry with punctuation: a=b, c|d, e;f
EOF
BEFORE=$(cat .claude/spec-journal.md)
.claude/hooks/phase.sh red >/dev/null 2>&1
[ "$(cat .claude/spec-journal.md)" = "$BEFORE" ] \
  && ok "an ordinary journal survives the snapshot unchanged" \
  || bad "the snapshot altered the journal it saved"

################################################################################
printf '\n%s%d passed, %d failed%s\n' "$B" "$PASS" "$FAIL" "$N"
[ "$FAIL" -eq 0 ] || exit 1
