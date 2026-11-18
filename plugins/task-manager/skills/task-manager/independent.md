# Tasks run: independent tasks, each with its own outcome

`SKILL.md` sends you to this file for a **tasks run**: 1 to n tasks that do not use each other's
code. Each task is one layer in the ledger. A `pr` task has its own branch and its own PR on
`origin/<default>`. A `report` task ends as a report file ([report-tasks.md](report-tasks.md)).
The tasks run one at a time, in the user's order, because the checkout has one writer. Report tasks can
work in a group when the profile permits it ("Report layers in parallel" in `report-tasks.md`).

You read `core.md` before this file. This file adds only what a tasks run needs, and it wins
where it disagrees with `core.md`. When this file names a step or a section that it does not
contain (for example step H, hard rule 6 or "Implementer tiers"), that step or section is in
`core.md`. Make the run with `L init --kind tasks`. Tell every agent `kind: tasks`.

## Rules of a tasks run

- **The base is the default branch** (hard rule 2). Each `pr` task branches from the current tip of `origin/<default>`
  when it starts. Run `git fetch origin` before each step A, and give the implementer that SHA.
- **No stack.** No stack line, no GitHub stack, no restack, no merge-order line.
- **No merge.** The orchestrator never merges a PR and never asks about a merge. The user merges.
- **No auto finish.** When every PR is open, the run is `paused`, not `finished`. The one
  exception is a run in which every task is a delivered report (Phase 2, step 2). The user marks it
  as finished in the admin page, asks for more changes, or says that a PR is merged.
- **Every question about one task parks only that task.** The other tasks are independent, so
  `L next` gives the next task. A question is run-level only when no task can move.
- **Git steps only at a stop point.** Every step that changes the checkout (a checkout, a switch,
  a branch delete) waits for a stop point ("Questions and parked layers" in `core.md`), and needs
  no other active run for this checkout. This applies also to "More changes" and "Cleanup after a
  merge", which the user can ask for at any time.

## Phase 0 — Intake

1. `git fetch origin` and `git status -sb`. The tree must be clean. If it is not clean, stop and
   ask the user about the work in it before you do anything else. Run
   `L list --checkout <absolute path of this checkout> --state active,paused`. If it gives an
   active run, tell the user and ask: resume it, or start a new run. A new run needs the active run
   `paused` or `finished` first. A paused run with open PRs that wait for the user does not block
   a new run.
2. Find the profile ("The profile" in `core.md`). If the checkout has none, make one now, and
   ask the user to confirm it in step 5. Then find the source of record for each task ("Find the
   source of record" in `core.md`).
3. **The shared-code check.** For each pair of tasks, compare the files and the modules that their
   sources name, and the code that they will probably change. If two tasks will probably change
   the same code, or one task uses code that another task changes, tell the user. Recommend the
   stack run for those tasks. Do not stop: continue with the run. A shared checklist or design
   doc only is not shared code: the user resolves that conflict at the merge.
4. Give each task its tier (see "Implementer tiers"), from the source of record and the code that
   it touches.
5. Ask every decision now ("Ask the decisions at intake" in `core.md`). A profile that you
   made in step 2 is one of them.
6. Make the run. Write two files in your session scratchpad: `request.txt` with the user's request
   word for word, and `layers.json`, a JSON array in work order with one object for each task:
   `{"task", "source", "outcome", "tier", "tierReason", "dependsOn": []}`. For a task with no
   other source, write `the user's request` as its `source`. `outcome` is `pr`,
   `report`, `issue` or `comment` ("Outcomes" in `SKILL.md`). `dependsOn` can name only earlier tasks that are not `pr` tasks, by their
   1-based index: a task that needs the result of a report waits for it. Then run:
   `L init --kind tasks --title "<short title>" --checkout <absolute path of this checkout>
   --request-file <request.txt> --layers-file <layers.json>`. It prints `{"id", "dir"}`. `dir` is
   the run folder: use it, word for word, for `<run folder>` in every step and prompt. Then run
   `L run --run <id> --set stage=layers --set nextStep="Phase 1 step A for l1"`. Then record the
   decisions of step 5, write a profile that you made to `<run folder>/profile.md`, and copy the
   plan documents ("Copy the plan documents" in `core.md`). If the profile permits report tasks
   in parallel, record the limit ("Report layers in parallel" in `report-tasks.md`).
7. Tell the user the run id, the order and the tier of each task, the result of the shared-code
   check, the decisions you recorded, and that the tasks run one at a time, or which report tasks
   can work in a group. Say that
   `/task-manager resume <run-id>` continues the run in a new session.

## Phase 1 — The loop for each task

A report task follows [report-tasks.md](report-tasks.md), not the steps below. For each `pr`
task, do steps A to H of `core.md`, with these changes:

- **Step A.** The base is `origin/<default>` at the SHA of the fetch. Record `base=<default>` and
  `baseTip=<that SHA>`. Name the other tasks of the run in the scope limit: they are other tasks,
  so the implementer does not do them.
- **Step G.** The PR base is `<default>`. There is no stack line.
- **Step H.** After the record, start the task's CI (below). Then continue with the next task that
  `L next` gives. CI does not touch the checkout, so the next task can start while CI runs.

### CI for each task

If the profile says that the project has no PR CI, skip this section: record the note that
`core.md` gives, and set no `ciRunUrl` and no `ciResult`. The task then has no CI result, and
Phase 2 does not wait for one.

Follow "Run CI on a PR and check it" in `core.md` for the task's PR, with these records:

- **Step 1.** If the PR's diff touches only paths that skip the slow suite, the slow suite does
  not run. Still start CI (step 2). Expect `no_e2e`.
- **Step 2.** After the start, record
  `L event --layer <layer> --type ci_started --pr <N> --sha <head SHA> --summary "CI on #<N>"`.
- **Step 3.** When the run is found, record `L layer --layer <layer> --set ciRunUrl=<url>`. This
  also sets `ciResult=pending`.
- **Step 4.** Record `L layer --layer <layer> --set ciResult=pass|fail|no_e2e`, and
  `L event --layer <layer> --type ci_result --summary "<result>"`.
- **Step 5.** For a flaky test, the result is set with
  `L layer --layer <layer> --set ciResult=pending`.

**A failure.** Handle it at the next stop point:

1. Tell the user the task, the PR and the failed jobs.
2. Run `L layer --layer <layer> --set phase=fixing`.
3. Send the failure to the task's implementer (a new one in a new session, see "Resume" in
   `core.md`). It follows "When you get more changes on an open PR" of its brief, which checks out
   the branch.
4. The task's reviewer checks the fix only. This check is not a review round.
5. After the check, tell the implementer to push. Verify as in step H, and run
   `L layer --layer <layer> --set phase=pr_open --set head=<SHA> --set lastReviewed=<SHA>`.
6. Start CI again from step 2 of the procedure. A new `ciRunUrl` resets the result to `pending`.

## Phase 2 — The stop

Go to Phase 2 only when all these conditions are true:

- every `pr` task is `pr_open` or `merged`, and every report task is `delivered`;
- no task is parked, and no task waits for an answer before its start (`held` of `L next` is
  empty). While a task waits for an answer and `L next` gives `null`, follow "Choose the next
  layer" in `core.md`: tell the user that the run waits for the answer, and stop your turn;
- every started CI run has a result.

Then:

1. Give the report:
   - a table: task, outcome (the PR, or the path of the report), CI result;
   - the result of the shared-code check again, if it found a pair;
   - the items of "Report the follow-ups and the checkout" in `core.md`;
   - the three next actions of the user (below).
2. Run `L run --set stage=finish --set state=paused --set nextStep="waits for the user: more
   changes, merged, or finished"`. Do not ask about a merge. Do not record a merge question.
   Exception: if every task of the run is `delivered`, nothing waits for a merge. Then run
   `L run --set stage=finish --set state=finished --set nextStep=null`, after the follow-up
   question has its answer. If you asked no follow-up question, run it now.

The user can then do one of these three actions, for each task, at any time:

- **Mark as finished**, in the admin page. Nothing for you to do.
- **More changes:** `/task-manager changes <run-id> <task> <what to change>` (see below).
- **Merged:** `/task-manager merged <run-id> <task>`, or the user says it in the session (see
  "Cleanup after a merge").

## More changes on an open PR

1. Run `L show --run <id>`. If an agent of this session runs, wait for a stop point. If the run is
   `finished`, run `L run --set state=paused` first. Then `L run --set state=active`. `L` refuses
   it while another run for this checkout is active: then tell the user, and stop.
2. `git fetch origin` and `git status -sb`. The tree must be clean (the rules of "Resume" step 4
   in `core.md`). Read the PR head: `gh pr view <N> --json headRefOid`. If it is not the recorded
   head, the real state is correct: correct the ledger, and record it with `L event --type note`.
3. Count the earlier change requests of this task in `L show --layer <layer>` (the notes
   "changes #<k>"). This request is number `<k>`. Record it:
   `L event --layer <layer> --type note --summary "changes #<k>: <what>"`. Run
   `L layer --layer <layer> --set phase=fixing --set head=<PR head>`.
4. Launch an implementer with the task's tier, or send a message to the task's implementer in the
   same session. Tell it `kind: tasks`, that the branch exists, the PR head, and the change. It
   follows "When you get more changes on an open PR" of its brief, which checks out the branch.
   Record it with `--set implementer=<id>`.
5. **Choose the check.** Compare the files of the new commits (`git diff --name-only <old
   head>..HEAD`) with the files of the first review (`git diff --name-only <base
   tip>...<old head>`).
   - Every new file is in the first review: a fix check by one reviewer. It is not a review round.
     Give the reviewer `git diff <old head>..HEAD` and the change. It does not run
     a review skill.
   - A file is new: a full review round, with the review skill of the profile, on `<old head>..HEAD`, by a new
     reviewer (step C of `core.md`, with that range). Its findings and rounds follow steps D and E,
     with `round` set from 1 again. Start the summary of each `review` event, and the `--defect`
     of each finding, with `changes #<k>:`. A resumed reviewer then sees which round belongs to
     which change.

   Record the choice: `L event --layer <layer> --type note --summary "changes #<k>: fix check|full
   round, <range>"`.
6. After APPROVE, run the final checks of step F for the changed code. Then tell the implementer
   to push. Verify as in step H. Run `L layer --layer <layer> --set phase=pr_open --set
   head=<SHA> --set lastReviewed=<SHA>`.
7. Start CI again ("CI for each task"). When it has a result, do Phase 2 again for this run.

## Cleanup after a merge

1. Run `gh pr view <N> --json state,headRefOid`. Continue only if `state` is `MERGED`. If it is
   not merged, tell the user, and stop.
2. If the admin PR sync did not record it yet (`L show` does not give `merged`), record the merge:
   `L layer --layer <layer> --set phase=merged`, and
   `L event --layer <layer> --type merge --summary "#<N>"`. A finished run accepts this record.
3. **The git steps wait.** If an agent of this session runs, or another run for this checkout is
   `active` (`L list --checkout <path> --state active`), do not touch the checkout now. Record
   `L event --layer <layer> --type note --summary "cleanup waits: <reason>"`, tell the user, and do
   steps 4 to 6 at the next stop point, or when the user asks again.
4. Run `git status -sb`. If the tree is not clean, skip the switch (this step) and the local
   delete (step 5), and continue at step 6. Tell the user. Never stash, clean or commit the tree
   yourself. If it is
   clean, run `git fetch origin`, `git switch <default>` and `git merge --ff-only origin/<default>`.
5. Delete the local branch. A squash merge leaves commits on the branch that are not in `<default>`, so
   `git branch -d` refuses it. Use `git branch -D <branch>` only when `git rev-parse <branch>` is
   equal to the merged PR's `headRefOid`. If it is not equal, the branch has commits that nobody
   pushed: keep it, and tell the user.
6. Run `git ls-remote origin <branch>`. If the remote branch still exists, delete it with
   `git push origin --delete <branch>`.
7. Delete the session scratchpad files of that task, and the implementer's scratch outputs that name the
   task, in the scratch folder of the profile.
8. Keep the run folder. It holds the plans, the findings and the tier data.
9. If every task of the run is `merged` or `delivered`, no question is open, and the run is not
   `finished` yet, run
   `L run --set state=finished --set nextStep=null`. Otherwise keep the run as it is.
10. Tell the user what you deleted, what you kept, and what waits, one line each.

## Resume

`/task-manager resume [<run-id>]` follows "Resume" in `core.md`. With no run id, the list gives
`active` and `paused` runs of both kinds. For a tasks run:

- A task is parked and its question has an answer, from either source: continue. Resume the
  parked task ("Questions and parked layers" in `core.md`).
- A task is still `queued`, or in progress: continue the loop.
- Every task is `pr_open`, `merged` or `delivered`, and no question waits: the run waits for the user. Give the
  user its report again (Phase 2, step 1), set `state=paused` again, and stop. Exception: if every
  task is `delivered`, finish the run as Phase 2 step 2 says.
