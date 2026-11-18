# Restack: restacker and stack verifier

A restack moves every layer of the stack onto the new tip of the layer below. It is necessary when
a layer gets new commits after a layer above it exists, when a layer merges to `<default>` in a run
with no GitHub stack, or when `<default>` moves and a PR conflicts. In a GitHub stack, GitHub rebases
the PRs above a merged PR. Two agents do it: a restacker changes the branches, and a separate
read-only verifier checks the result.

## Restacker

Work in the current checkout. Never create a worktree. The orchestrator gives you the path of the
project **profile**: the file that gives the rules of this project. Read it in full. `<default>`
below is the default branch that it names. The tree must be clean on `<default>`. Load the skill
for tests and the skill for the PR title, if the profile names them. Run every command as the
"Commands" section of the profile says.

The orchestrator gives you the run folder path and the list of the layers to restack, bottom to
top. The list has only the layers with an open PR. "Layer" below means a layer of that list.
Never touch a branch that is not on the list: a parked layer or a layer in progress has no remote
branch, and its own rebase comes later.

1. **Record before you change anything.** `git fetch origin`. Overwrite
   `<run folder>/stack-original-tips.txt` with one line for each layer:
   `<branch> tip=<origin tip SHA> old-base=<SHA>`. Do not append to an earlier restack's lines.
   The old base of the lowest layer is its merge base with `origin/<default>`. The old base of each
   other layer is the recorded tip of the layer below it in the list. If the orchestrator gives
   an old base for a layer, use that SHA. The verifier and the pushes need these SHAs.
2. **Rebase bottom to top.** Non-interactive only (no `-i`). For each layer, first confirm that
   the local branch has no commit that the remote lacks. `git log origin/<branch>..<branch>` must
   print nothing, or the branch must not exist locally. If it prints a commit, stop and report.
   ```bash
   git switch -C <branch> origin/<branch>
   git rebase --onto <new base tip> <old base> <branch>
   ```
   The new base is `origin/<default>` for the lowest open layer, or the new tip of the layer below.
   If a layer merged to `<default>`, it leaves the stack. Without a GitHub stack, rebase the layer
   above onto `origin/<default>`, with the merged layer's recorded tip as its old base. With a GitHub
   stack, GitHub already rebased the remote branches, so the merged layer's tip is not an
   ancestor. Do not use it. Use the old bases of step 1, which come from the remote tips.
3. **Resolve conflicts by keeping the intent of both sides.** Keep the base side's text, which is
   what `<default>` or the lower layer already says. Add this layer's own edit to it. Never drop a line
   from either side, unless this layer's original commit intentionally replaced that exact line.
   - A file with its own conflict rule in the profile ("Restack"): follow that rule. For a counted
     value in a doc, never add the deltas of the two sides. At each layer, set the value to the one
     that the code or its test requires, in every place where the value appears.
   - Code conflict: stop and report it. The only exception is a conflict that is fully mechanical,
     for example two imports added at the same line.
   - A commit that becomes empty: record it, and stop before any push. The user decides.
4. **Check each layer.** Run the checks that the profile gives for each layer after a rebase
   ("Restack"). If it gives none, run its checks for the changed code, and the layer's own
   targeted tests. Fix only mistakes in the conflict resolution. Do not change behaviour.
5. **Check the top.** Run the checks that the profile gives for the top of the stack. If it gives
   none, run its full checks. Run the slow suite only if you resolved a code conflict in step 3.
   Then run only the parts that the conflicted code touches, one time.
   A clean rebase, or one with only doc conflicts, runs no slow suite. The verifier's range-diff
   proves that the code did not change, and the full slow suite runs in CI.
6. **Push.** Push only the stack branches, never `<default>`:
   `git push --force-with-lease=<branch>:<recorded tip> origin <branch>`.
   If the orchestrator gives you a GitHub stack number, GitHub sets the bases: do not edit them.
   Without a stack number, set the base: `gh pr edit <N> --base <branch below>`, or `--base <default>`
   for the bottom layer. Keep the stack line as the first line of each body. Follow the
   attribution rule of the profile. Never run `gh stack` commands, and never link, unstack or merge a PR.
7. **Verify.** `gh pr view <N> --json state,headRefOid,baseRefName,mergeable` must show `OPEN`, a
   head equal to the local tip, and the correct base. `git ls-remote origin <branch>` must match.
   If the base is wrong in a GitHub stack, stop and report it. End with `git switch <default>` and a
   clean tree.
8. **Stale docs.** When the orchestrator sends the verifier's stale-doc list, fix each line in the
   layer that owns it. Use one `docs:` commit per layer. Then rebase the layers above onto it, and
   push again with the lease on the current remote tips.

If the permission system refuses a command, stop and report it. Do not find another way to do it.

Report for each layer: the old tip and the new tip, each file that conflicted and how you resolved
it (one line each), each counted value that you set, each command as PASS or FAIL (output only for a failure), and
the PR base and mergeable state. Then the result of the slow suite, or "no slow suite: no code conflict", and the
full-test result. Say what you were not sure about.

## Stack verifier (read-only)

Never edit, stage, commit, stash, check out, switch, reset, rebase or push anything, and never
change a PR. You may run `git fetch`, `git log`, `git diff`, `git range-diff`, `git show`,
`gh pr view`, and read files. Do not run tests; the restacker already ran them.

The orchestrator gives you the run folder path, the profile path and the list of the restacked
layers. For each
layer of that list, use the recorded SHAs in `<run folder>/stack-original-tips.txt`:

1. `git range-diff <old base>..<old tip> <new base>..<new tip>`. Every original commit maps to a
   rebased commit. The only differences are the conflict resolutions that the restacker named.
2. `git diff <new base>...<new tip>` contains this layer's change and nothing from another layer.
   It removes nothing that a lower layer or `<default>` added. For each changed doc, count the headings
   and the checkboxes before and after.
3. Code, not docs and not comments, is identical to the reviewed version, except for a
   mechanical merge that the restacker named. Compare `git diff <old base> <old tip> -- <code paths>`
   with `git diff <new base> <new tip> -- <code paths>`.
4. Each counted value that the profile lists ("Restack") agrees, at each layer, with what the
   layer adds or removes.
5. For each pushed layer: the PR is `OPEN`, the head matches, the base is the branch below, the body
   starts with the stack line, and, when the profile says no attribution, there is no "Generated
   with" or "Co-Authored-By". If the
   orchestrator gives you a GitHub stack number, its open PRs are the restacked layers, in the
   same order:
   `gh api "repos/{owner}/{repo}/stacks/<stack>" --jq '[.pull_requests[] | select(.state == "open") | .number]'`.
6. Stale docs: grep the files that the stack touches for `not merged`, `it.failing`,
   `expected fail`, and for statements about PRs that are now merged. Check each merge-commit SHA
   that the docs cite against `gh pr view <N> --json mergeCommit`. List each stale line with its
   `file:line` and the layer that must fix it.

Report PASS or FAIL for checks 1 to 5 on each layer, with evidence. Then give the stale-doc list,
and a verdict: is it safe to push the stack as it is?
