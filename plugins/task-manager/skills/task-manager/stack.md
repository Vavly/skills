# Stack run: one reviewed PR per task, stacked

`SKILL.md` sends you to this file for a **stack run**: each task is one layer, and the PR of each
`pr` layer is on the PR below it. You read `core.md` before this file. This file adds only what a
stack run needs: the base chain, the intake, the finish, the GitHub stack and the restack. It
wins where it disagrees with `core.md`. Make the run with `L init` and no `--kind`, so that it is
a stack run. Tell every agent `kind: stack`. When this file names a step or a section that it
does not contain (for example step H, hard rule 6 or "Implementer tiers"), that step or section
is in `core.md`.

A report layer ([report-tasks.md](report-tasks.md)) can be in a stack run. It has no branch and no
PR, so it is never a base, and it is not in the GitHub stack. A layer that needs its result
names it in its "depends on" list.

## Stack from the start (hard rule 2 of a stack run)

A layer's base is the branch of the highest layer below it in the current order that has an open
PR. If no layer below it has an open PR, its base is `origin/<default>`. The layer branches from the
pushed tip of its base, and its PR base is that branch. A parked or waiting layer is never a base,
because it is not pushed. Independent PRs that edit the same files
conflict after the first merge. You also link the open PRs as one native GitHub stack
("GitHub stack").

## Resume: the GitHub stack

Step 4 of "Resume" in `core.md` sends you here. If the run has a GitHub stack, read it (the check
in "GitHub stack"). If no stack number is recorded, and the run did not record "no GitHub stacks",
and two or more PRs are open:

1. Look up the stack of the bottom open PR with the `pull_request` query. If it gives a number,
   record it with `L run --set stack=<number>`.
2. If it gives `null`, run the stack probe of Phase 0, step 1. If the probe passes, create the
   stack from the open PRs, bottom to top, and record its number. If it fails, record "no GitHub
   stacks" as in Phase 0.

## Phase 0 — Intake

1. `git fetch origin` and `git status -sb`. The tree must be clean. If it is not clean, stop and
   ask the user about the work in it before you do anything else. Run
   `L list --checkout <absolute path of this checkout> --state active,paused`. If it gives a run,
   tell the user and ask: resume it, or start a new run. A new run needs the old one `paused` or
   `finished` first. Check that the repository has GitHub stacks:
   `gh api "repos/{owner}/{repo}/stacks?per_page=1"` must exit 0. If it fails, the run uses the base
   chain only. After step 6, record the result as a decision, because `L show` always lists the
   decisions: `L decision --question "GitHub stacks" --answer "no GitHub stacks: <error>"`.
2. Find the profile ("The profile" in `core.md`). If the checkout has none, make one now, and
   ask the user to confirm it in step 5. Then find the source of record for each task ("Find the
   source of record" in `core.md`).
3. Set the stack order. Use the user's order, but put a task after any task whose code it uses.
   Example: a task that raises a toast goes above the task that changes the toast module.
   `L init` gives the layers the ids `l1` to `ln` in this order. For each layer, list the earlier
   layers whose code it uses as its "depends on" list. A shared checklist or
   design doc is not a dependency: a rebase resolves those conflicts. The list decides which
   layers can move while a layer is parked.
4. Give each layer its tier (see "Implementer tiers"), from the source of record and the code
   that it touches.
5. Ask every decision now ("Ask the decisions at intake" in `core.md`). A profile that you
   made in step 2 is one of them.
6. Make the run. Write two files in your session scratchpad: `request.txt` with the user's request
   word for word, and `layers.json`, a JSON array in stack order with one object for each layer:
   `{"task", "source", "outcome", "tier", "tierReason", "dependsOn"}`. For a task with no other
   source, write `the user's request` as its `source`. `outcome` is `pr`,
   `report`, `issue` or `comment` ("Outcomes" in `SKILL.md`). `dependsOn` lists the 1-based indexes
   of earlier layers in this array. Then run:
   `L init --title "<short title>" --checkout <absolute path of this checkout>
   --request-file <request.txt> --layers-file <layers.json>`. It prints the run id. Then run
   `L run --run <id> --set stage=layers --set nextStep="Phase 1 step A for <first layer>"`. The
   run folder is your memory after a context summary, and the only state that a new session can
   see. Then record the decisions of step 5, write a profile that you made to
   `<run folder>/profile.md`, and copy the plan documents ("Copy the plan documents" in
   `core.md`).
7. Tell the user the run id, the stack order, the tier of each layer, the decisions you recorded,
   and that the layers run one at a time. Say that `/task-manager resume <run-id>` continues the
   run in a new session.

## Phase 2 — Finish

1. Run `L run --set stage=finish --set nextStep="Phase 2 step 1: merge-order lines"`. Edit the
   first line of each PR body to show the full merge order, for example
   `Stacked on #503 — merge in order: #503 → #504 → #506.` The bottom PR says
   `Bottom of the stack — merge in order: …`. Keep the rest of the body. Verify each edit. Then
   check the GitHub stack ("GitHub stack"): its open PRs must be in this merge order.
2. Run CI for the stack. The layers ran only the parts of the slow suite that their change
   touches. The full slow suite runs one time in CI, so that it does not block the stack. Follow "Run CI on a PR
   and check it" in `core.md`, with these records:
   - Find the highest PR whose own diff makes the slow suite run (step 1 of that procedure). Its
     head contains every layer below it. If no PR does, skip this step and say so in the final
     report. If the profile names no slow suite, use the top PR.
   - Before you start CI, record the PR and its head SHA: `L run --set stage=ci --set ciPr=<N>`
     (`ciPr` also sets the result to `pending`), and
     `L event --type ci_started --pr <N> --sha <head SHA> --summary "CI on #<N>"`.
   - When the run is found, record it: `L run --set ciRunUrl=<url>`.
   - After step 4 of the procedure, record the result: `L run --set ciResult=pass|fail|no_e2e`, and
     `L event --type ci_result --summary "<result>"`. If the slow suite was skipped, report that it did
     not run. On `pass` or `no_e2e`, also set `stage=finish`: the final report comes next.
   - For a flaky test, the result is set with `L run --set ciResult=pending`.
   - If the run fails, find the layer that owns the failure. Send the failure to that layer's
     implementer, and the fix to that layer's reviewer. Then restack the layers above it. Then start
     CI again on the new head, and check the new run in the same way. Run
     `L run --set ciPr=<N>` again before the new run: it resets the result to `pending`, so the
     board does not show the old result.
3. Give the final report:
   - a table: task, PR, base, state;
   - the CI run: its URL and its result;
   - the items of "Report the follow-ups and the checkout" in `core.md`.

   Then run `L run --set stage=finish --set state=finished --set nextStep=null`, unless merges
   and restacks are still to come, or the follow-up question is open. With only the follow-up
   question open, run `L run --set state=paused --set stage=finish --set nextStep="waits for the
   follow-up answer"`, and finish the run after the answer. With merges still to come, run `L run --set state=paused --set stage=finish
   --set nextStep="<the next step>"`, and record the merge question that waits:
   `L ask --session-only --question "Merge the stack? Which PR is the top?" --option "<top PR>"`.
   The merge yes comes in the session, or as a confirmed answer from the admin page ("A confirmed
   answer" in `core.md`). It stays open
   until the user says yes, so the board shows that the run waits for the user. "Not yet" is not
   an answer: record it with `L event --type note --summary "merge: not yet, <reason>"`, and leave
   the question open.
4. Merging. Merge only after the user's explicit yes (hard rule 6) to the question of step 3. Its
   answer names the top PR of the merge, so do not ask a second question. Record a yes from the
   session with `L answer` (a confirmed answer from the admin page is in the ledger already), and
   run `L run --set state=active --set stage=finish`. After the yes, you run the merge
   procedure of "GitHub stack". A stack merge merges every open PR below the chosen PR, and that PR,
   with one request. GitHub then retargets and rebases the PRs above it, so no restack is necessary,
   unless a PR shows a conflict.
   - Record a layer as merged only when `gh pr view <N> --json state` gives `MERGED`. An
     `enqueued` status is not a merge. Then run `L layer --layer <layer> --set phase=merged`, and
     `L event --layer <layer> --type merge --summary "#<N>"`.
   - GitHub rebased the open PRs above, so the ledger has old SHAs for them. For each open layer,
     read the new base and head (`gh pr view <N> --json baseRefName,headRefOid`, and
     `git ls-remote origin <base branch>` for the base tip). Record them with
     `L layer --layer <layer> --set base=<branch> --set baseTip=<SHA> --set head=<SHA>`.

   Without a GitHub stack, GitHub moves the next PR's base to `<default>` only when the merged branch is
   deleted. After a squash merge, the next layer still carries the squashed commits. So merge one PR
   at a time, from the bottom: the merge procedure ("GitHub stack") on that PR alone, its records
   (above), then a restack of the layers above it ("Restack"), then the next PR.

   When every merge is recorded, end the run: `L run --set state=finished --set nextStep=null`.
   If the follow-up question is still open, set `state=paused` in its place, and finish the run
   after that answer.

## GitHub stack

GitHub links a chain of PRs as one native stack. The stack view shows the order. A stack merge
is all or nothing: the whole group merges or is queued, or none of it does. The Stacks REST API
is in public preview and can change (https://docs.github.com/en/rest/pulls/stacks). You, the
orchestrator, own the stack. Agents never link, unstack or merge.

Use `gh api` only. Never run any `gh stack` command. Some of them rebase or push branches outside
the restack procedure, some move `HEAD`, and all of them keep their own local state.

| Action | Command |
|---|---|
| Create, when two PRs are open | `gh api -X POST "repos/{owner}/{repo}/stacks" -F 'pull_requests[]=<lower open PR>' -F 'pull_requests[]=<upper open PR>' --jq .number`. Then `L run --set stack=<number>`. |
| Add each later PR | `gh api -X POST "repos/{owner}/{repo}/stacks/<stack>/add" -F 'pull_requests[]=<N>'` |
| Find the stack of a PR | `gh api "repos/{owner}/{repo}/stacks?pull_request=<N>" --jq '.[0].number'`. It prints `null` when the PR is in no stack. |
| Check the stack | The first command below this table |
| Merge, after the user's yes | The merge procedure below this table |

```bash
gh api "repos/{owner}/{repo}/stacks/<stack>" \
  --jq '[.pull_requests[] | select(.state == "open") | .number]'
```

- **The check.** The open PR numbers must be the open PRs of the ledger, in stack order. Run it
  after each create, add, restack and merge.
- **Order.** The API only appends at the top. This agrees with hard rule 2: a new layer, and a
  resumed parked layer, start directly above the highest open PR.
- **Errors.**
  - A 409 means that another request changes the stack. Wait some seconds, then send the
    request again one time.
  - A 422 means that a PR does not exist, or that it cannot go into the stack. One possible cause
    is a base that is not the head of the top PR. Other causes are a closed or merged PR, and a
    PR that is already in a stack. Compare `gh pr view <N> --json state,baseRefName` with the
    layer below. Correct the ledger or the base. Do not unstack.
  - A 403 or 404 on a create or add means that writes to stacks are not available. Record
    "no GitHub stacks" as in Phase 0, step 1, and continue with the base chain only.
- **A PR closes without a merge, or a layer drops out.** The PR above it keeps the closed branch
  as its base, and you cannot change the base inside a stack. The branches above also still hold
  the commits of the closed layer. Stop and tell the user. Ask for one yes for two actions
  (hard rule 6), with `L ask --session-only`: the unstack, and the removal of the closed layer's commits from the branches
  above. After the yes:
  1. Unstack: `gh api -X POST "repos/{owner}/{repo}/stacks/<stack>/unstack" -i`. A 204 means
     that the stack is dissolved: run `L run --set stack=null`. A 200 means that some PRs stay
     in the stack, for example PRs queued for merge. Then keep the stack number, tell the user,
     and stop. Do not do steps 2 to 4.
  2. Correct the base of the PR above the closed one: `gh pr edit <N> --base <branch below>`.
  3. Restack the layers above ("Restack"). Give the restacker the closed layer's tip as the old
     base of the layer directly above it. Without it, the restacker keeps the closed layer's
     commits.
  4. Create a new stack from the open PRs, and record its number.
- **No stacks.** If the run recorded "no GitHub stacks", skip this section, except the merge
  procedure below: it also merges a PR that is in no stack. The base chain and the merge-order
  line still apply. Correct a PR base with `gh pr edit --base`.

**The merge procedure.** `gh pr merge` uses the synchronous merge, and the docs say that the
synchronous merge endpoints and mutations cannot merge a stacked PR. Use `merge-async`:

1. Start the merge on the top PR of the merge. The `sha` makes sure that GitHub merges only the
   head that the reviewer saw:
   ```bash
   gh api -X PUT "repos/{owner}/{repo}/pulls/<N>/merge-async" \
     -f merge_method=<merge method of the profile> -f sha=<recorded head of N> --jq '.status, .details.uuid'
   ```
   - A 202 response gives `pending` and a UUID. Go to step 2.
   - A 200 response means that the PR is already merged or queued. Go to step 3.
   - A 409 response means that another merge request is pending. It gives that request's UUID.
     Go to step 2 with it.
   - A 400 response means that a PR is not ready, for example closed or still a draft. Tell the
     user.
2. Poll until the status is not `pending`:
   `gh api "repos/{owner}/{repo}/pulls/<N>/merge-async/<uuid>" --jq '.status, .details.message'`.
   - `merged`: go to step 3.
   - `enqueued`: the merge queue has the PRs, but they are not merged. Tell the user. Check again
     later with `gh pr view <N> --json state`.
   - `failed`: GitHub checks branch protection when the merge runs, so a failure can come after
     the 202 response. Give `details.message` to the user, and stop.
   - A 404 means that the result expired. GitHub keeps a result for 24 hours after its last
     update. Use `gh pr view <N> --json state`.
3. Check each merged PR with `gh pr view <N> --json state`. Then do Phase 2 step 4.

## Restack

A restack is necessary when:

- a layer gets new commits after a layer above it exists;
- a layer merges to `<default>`, and the run has no GitHub stack (a stack merge rebases the PRs above);
- `<default>` moves and a PR conflicts.

A restack moves only the layers that have an open PR. A parked layer, or a layer whose work is in
progress, is not touched. Its recorded base tip, tip and last reviewed SHA do not change: its own
rebase uses them later. Start a restack only at a stop point.

Launch a restacker with [restack.md](restack.md). Give it the absolute path of the run folder,
the absolute path of the profile, the list of the layers with an open PR, the GitHub stack number if the run has one, and each
old base that you set (for example the tip of a closed layer). Then
launch a separate read-only stack verifier with the same file, with `model: "sonnet"`, and give
it the same path, list and stack number. Its work is mechanical: range-diffs, counts and greps.
Send the verifier's stale-doc list back to the restacker, so that each stale line gets its fix in
the layer that owns it. Verify every PR as in step H, and check the GitHub stack.

Record the restack: `L run --set stage=restack` before it, and `L event --type restack --summary
"<layers, result>"` after it. For each restacked layer, record its new head and base:
`L layer --layer <layer> --set head=<SHA> --set base=<branch> --set baseTip=<SHA>`. Then set the
stage back (`layers`, `ci` or `finish`).

## More changes on a layer of the stack

`/task-manager changes <run-id> <layer> <what>` on a `pr` layer of a stack run. Do not follow the
tasks-run procedure of `independent.md`: it has no restack.

1. Run `L show --run <id>`. Wait for a stop point. Note the run's state and stage now: step 8
   sets them back. Run `L list --checkout <checkout> --state active`: if another run is active,
   tell the user, and stop. If the run is `finished`, run `L run --set state=paused`. Then run
   `L run --set state=active`.
2. `git fetch origin` and `git status -sb`. The tree must be clean: if it is not, set the state
   back (step 8), ask the user about the work in it, and stop. Record the request:
   `L event --layer <layer> --type note --summary "changes: <what>"`, and
   `L layer --layer <layer> --set phase=fixing`.
3. Launch an implementer with the layer's tier, or send a message to the layer's implementer in
   the same session. Tell it `kind: stack`, that the branch exists, the PR head, and the change.
   It checks out the branch, and makes the change in new commits only, with no push.
4. The layer's reviewer checks the new commits (`git diff <old head>..HEAD`). In a new session,
   the agents of steps 3 and 4 are new ones ("Resume" step 5 in `core.md`): one implementer and
   one reviewer. Record their ids with `L layer --set implementer=<id>` and `--set reviewer=<id>`. This check is not
   a review round, unless the change touches a file that the first review did not cover: then it
   is a full round, as step C of `core.md`.
5. After APPROVE, the implementer runs the final checks for the changed code, and pushes with no
   force. Verify as in step H. Run `L layer --layer <layer> --set phase=pr_open --set head=<SHA>
   --set lastReviewed=<SHA>`.
6. Restack the layers above this layer ("Restack"). Then check the GitHub stack.
7. If CI ran for the stack, its result is for the old heads. Run Phase 2 step 2 again.
8. Give the user the new heads. Then set the run back to what step 1 noted:
   - It was `active` with layers still to do: keep `active`, set the stage back, and continue the
     loop.
   - It was `paused`, or it was `finished` and a PR or a question now waits:
     `L run --set state=paused --set stage=finish --set nextStep="<what waits>"`.
   - It was `finished` and nothing waits: `L run --set state=finished --set nextStep=null`.

   An `active` run blocks a new run in this checkout. The merge question stays open: do not ask
   it again.

## The user merged a PR of the stack

`/task-manager merged <run-id> <layer>`, or the user says it in the session. Do not follow
"Cleanup after a merge" of `independent.md`: it deletes the branch, and that branch can be the
base of the PR above.

1. Run `gh pr view <N> --json state,headRefOid`. Continue only if `state` is `MERGED`. Wait for a
   stop point.
2. If `L show` does not give `merged` for the layer yet (the admin PR sync can record it first),
   record the merge: `L layer --layer <layer> --set phase=merged`, and `L event --layer <layer>
   --type merge --summary "#<N>"`. A finished run accepts this record, but no other write: if the
   run is `finished` and a layer is still open, run `L run --set state=paused` now. Then record the
   new SHAs of the open layers, as Phase 2 step 4 says.
3. Without a GitHub stack, restack the layers above ("Restack"). With a GitHub stack, GitHub
   rebased them: check the stack.
4. Delete the local branch and the remote branch of the merged layer only when no open PR has
   that branch as its base (`gh pr list --base <branch> --state open` gives nothing), and by the
   rules of steps 4 to 6 of "Cleanup after a merge" in `independent.md`: the switch away from the
   branch, the local delete, the remote delete.
5. Set the final state. If every `pr` layer is `merged`, the merge question has nothing left to
   ask: if it is open, close it with `L answer --id <id> --answer "merged by the user"`. Then, if
   no question is open and the run is not `finished` yet, run
   `L run --set state=finished --set nextStep=null`. If the run is `finished` already, do nothing.
   Otherwise run `L run --set state=paused --set
   nextStep="<what waits>"`.

## Events of a stack run

These rows add to the table of "Events" in `core.md`.

| Event | Action |
|---|---|
| A commit becomes empty after a rebase | The restacker stops before the push. Ask the user whether to drop it, with `L ask --session-only`. |
| The full CI run fails | Find the layer that owns the failure. Its implementer fixes it, its reviewer checks the fix, then restack the layers above. Start CI again on the new head, and run `L run --set ciPr=<N>` again (Phase 2, step 2). For a flaky test, follow step 5 of "Run CI on a PR and check it" in `core.md`, with `L run --set ciResult=pending`. |
