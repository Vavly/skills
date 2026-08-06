---
name: spec-gate-install
description: Set up spec-gate in this repository — the phase shim, docs/specs, gitignore entries, the RED test command, and the permission rules. Run once per project after installing the plugin, and again after a plugin update.
argument-hint: ""
disable-model-invocation: true
allowed-tools: Bash, Read, Edit, Write
---

# Install spec-gate into this repository

The plugin installs **centrally, once**. Everything below is **per project**,
because every project has its own spec, its own slices and its own phase state.
That split is why this skill exists: five setup steps that can each be
half-done, and a half-done install fails later and somewhere else.

**You are writing configuration into someone's repository.** Two rules hold
throughout, and neither is negotiable:

- **Read a file before you change it.** Never overwrite `settings.json`,
  `.gitignore` or anything else you have not read in this session.
- **Show the whole set of changes and get agreement before making any of them.**
  One confirmation for the batch, not five. Say what already looks correct and
  will be skipped.

Re-running this is safe and expected — it is also the repair step after a plugin
update. Every step below is idempotent; check the current state first and say
"already correct" rather than writing the same thing twice.

## 1. Check the ground

```bash
git rev-parse --show-toplevel 2>/dev/null || echo "NOT A GIT REPO"
```

Both Stop-hook jobs fingerprint the working tree with `git diff HEAD`,
`git ls-files` and `git hash-object`. Outside a work tree the hooks exit
silently, so **stop here and say so** rather than installing something inert.

Then check for `jq` or `python3` — the hooks need one of them and fail closed
without either — and report which was found.

## 2. The shim

Copy the plugin's `hooks/phase-shim.sh` to `.claude/hooks/phase.sh` in this repo.
Find it the same way the reviewer's script is found:

```bash
P=$(ls -td ~/.claude/plugins/cache/*/spec-gate/*/hooks 2>/dev/null | head -1)
[ -n "$P" ] && echo "found: $P" || echo "STOP: spec-gate plugin not installed"
```

**If this repo already has a real `.claude/hooks/` install** — the whole set of
scripts, not just `phase.sh` — it is a manual install. Say so and skip this step:
overwriting `phase.sh` with the shim there would replace the real thing with a
pointer to a copy that may not exist.

The shim is a pointer and holds no policy, so it does not go stale on a plugin
update — but re-run this skill anyway after one, since nothing else re-checks the
rest of the list.

**Commit it.** The review gate treats untracked files as reviewable, so leaving
`.claude/` uncommitted makes the gate fire on its own tooling.

## 3. `docs/specs/`

`mkdir -p docs/specs`. Phase 2 may write nowhere else, so without it the first
spec has nowhere to go.

## 4. The RED test command

`.claude/spec-gate-test-cmd` holds one command. It runs from the project root
with `$SPEC_GATE_TEST_FILES` set to the test files Phase 3 changed.

**Work out what this repo actually uses — do not ask cold, and do not guess.**
Look at `package.json` scripts, `pytest.ini`, `pyproject.toml`, `go.mod`,
`Makefile`, or the CI workflow, and propose what you found:

```
yarn jest $SPEC_GATE_TEST_FILES
pytest $SPEC_GATE_TEST_FILES
go test ./...
```

Say where you got it. If nothing in the repo answers the question, say that and
ask — a wrong command here does not fail loudly, it makes `phase.sh red` unable
to verify anything, and 3 → 4 then rests on an assertion instead of on output.

## 5. `.gitignore`

Eight entries, and each one is state the gate writes about itself:

```
.claude/.spec-phase
.claude/.spec-baseline
.claude/.spec-red
.claude/.spec-approval*
.claude/.spec-scaffold
.claude/.spec-validation
.claude/spec-journal.md
.claude/review-log.jsonl
```

**Append only what is missing.** An untracked state file is work the review gate
considers owed, so a name absent here is a gate that arms itself every time it
writes its own bookkeeping.

## 6. `permissions.ask`

```json
{
  "permissions": {
    "ask": [
      "Bash(.claude/hooks/phase.sh scaffold*)",
      "Bash(.claude/hooks/phase.sh 3*)",
      "Bash(.claude/hooks/phase.sh 4*)",
      "Bash(.claude/hooks/phase.sh 5 --force*)",
      "Bash(.claude/hooks/phase.sh off*)"
    ]
  }
}
```

`5 --force` is listed and a bare `5` is not, on purpose: advancing into review is
the model's own transition and prompting on it would be noise, but the `--force`
spelling skips the validation report the reviewer is about to be handed.

**Merge into any existing `.claude/settings.json`; never replace it.** The `ask`
array goes inside whatever `permissions` object is already there, and everything
else in the file stays untouched. Read it first, and if it already has these,
say so and skip.

These are a backstop, not the main gate. `phase-guard.sh` matches `phase.sh` with
no path anchor, so it asks in every normal permission mode wherever the script
lives. What these cover is `bypassPermissions`, where a hook's `ask` is not
documented to survive — and they match the shim's path, which is exactly why the
shim gives every project the same one.

**Do not copy the plugin's `hooks` block into settings.** The plugin registers
its own hooks through `hooks/hooks.json`; a second copy pointing at
`$CLAUDE_PROJECT_DIR/.claude/hooks/*.sh` would name scripts a plugin install does
not have.

## 7. Report

Say what you changed, what you skipped as already correct, and what you could not
determine. Then show how to check the result — this is the first thing that
proves the install works end to end:

```
/spec-phase status
```

If that reports a phase or `inactive`, the install is good. If it reports that
`phase.sh` cannot be found, the shim did not resolve and step 2 is where to look.
