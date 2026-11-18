# Report tasks: the loop for a layer that ends as a report

A **report layer** is a task with the outcome `report`: an investigation, the cause of a defect,
a plan, a code execution, a search for information. It changes nothing in the repository. It
ends as a report file in the run folder, `reports/report-<slug>.md`, after a separate reviewer
approves it. The agent that does the task is the **worker**. The ledger records the worker in the
`implementer` field.

## Which rules of core.md apply

| Rule of `core.md` | For a report layer |
|---|---|
| The profile | Applies: "Project", "Commands", "Skills" (by area), "User data", "Sources of record". With no repository, the profile is "none": skip it. |
| Hard rule 1 (one writer) | Applies. A worker can run code in the checkout, so it counts as the writer. Do not run a worker while an implementer works. |
| Hard rule 2 (the base) | Does not apply: a report layer has no branch. It is never a base. |
| Hard rule 3 (no PR before APPROVE) | Becomes: **no delivery before APPROVE**. The exceptions are the same: the round limit, and findings that you all closed with `L rule`. |
| Hard rules 4, 6, 7, 9 | Apply. |
| Hard rule 5 (attribution) | Applies only if the worker files something, which needs the user's yes. |
| Hard rule 8 (one reviewer) | Applies. The reviewer runs no review skill. It follows its brief. |
| Tiers | Apply, with the signals below. |
| Record the usage of each agent | Applies. The worker of a report layer has `--role implementer`. |
| Questions and parked layers, the ledger, the resume, the events | Apply. "Park and resume" below gives the commands. |
| Steps F, G and H, CI, the restack | Do not apply. |

**Tier signals of a report task.**

| Tier | Signals |
|---|---|
| **S** | A lookup, a question that one file or one command answers, a short summary |
| **M** | An investigation across one area, a plan for a usual feature, a measurement with a known method |
| **L** | The cause of a defect that is intermittent or that loses data, a plan that touches persisted data or a security boundary, an investigation across systems, a result that a costly decision depends on |

## Two rules for every report layer

1. **The tree does not change.** Before the worker starts, the tree must be clean. Record the
   branch and `git rev-parse HEAD`. At delivery, the branch and `HEAD` must be the same, and the
   tree must be clean. The worker makes no commit and no branch. It does an experiment that
   changes files in a copy outside the checkout.
2. **Nothing goes out.** The worker only reads from systems outside this machine. It files no
   issue, posts no comment, sends no message, starts no deploy, and writes to no database or
   service. If the task needs one of these actions, that is a question for the user (hard
   rule 6): ask in text, and park the layer with `L park --session-only`. The yes comes in the
   session, not from the admin page.

**With no git repository.** A report task can run in a folder that is not a git repository. Then
skip rule 1 and every git check of this file and of the resume in `core.md`. Where a ledger
command needs a branch or a SHA, give the word `none`: `base=none`, `baseTip=none`, `--tip none`,
`--base none`, `--base-tip none`, `--head none`. Tell each agent that the folder has no git.

## The loop

**R-A. Worker.** Check the tree (rule 1). Launch a `general-purpose` agent in the background,
with the `model` and `effort` of the layer's tier. Its prompt contains:

- "You are the WORKER for report layer `<layer>`. First read and follow every rule in the section
  "Worker" of `<skill>/report-brief.md`, and the project profile at `<profile path>`."
- The task: the question to answer, the source of record, and the user's decisions for it.
- What the report must contain to be complete. These are the acceptance criteria.
- The scope limit: the other tasks of the run are other layers.
- The plan path `<run folder>/plans/plan-<slug>.md` and the report path
  `<run folder>/reports/report-<slug>.md`, as absolute paths.
- The results of the report layers that this layer depends on: the paths of their reports.
- Stack run only, when this layer depends on a `pr` layer: the branch of that layer and its
  recorded head. The worker needs that code, and its brief permits no checkout. So before you
  launch it, at a stop point and with a clean tree, run `git switch <that branch>` yourself.
  `git rev-parse HEAD` must be the recorded head: if not, stop and ask the user. Record that
  branch as `base` and that head as `baseTip`.

Record the start: `L layer --layer <layer> --set phase=implementing --set implementer=<agent id>
--set base=<current branch> --set baseTip=<HEAD SHA> --set plan=plans/plan-<slug>.md --set
report=reports/report-<slug>.md`.

**R-B. Wait for the report.** Record it: `L event --layer <layer> --type report --summary "<the
answer in one line>"`.

**R-C. Reviewer.** Launch a new `general-purpose` agent in the background, with `model: "opus"`
and `effort: "high"` for every tier. Its prompt contains:

- "You are the REVIEWER for report layer `<layer>`. First read and follow every rule in the
  section "Reviewer" of `<skill>/report-brief.md`, and the project profile at `<profile path>`.
  Never launch an agent."
- The task and the acceptance criteria, as you gave them to the worker.
- The report path and the plan path.
- The worker's claims as a list, under "claims (verify, do not trust)".
- An "especially check" list: the conclusions that a decision depends on, and the weak points
  that you see.

Record it: `L layer --layer <layer> --set phase=review --set round=1 --set reviewer=<agent id>`.

**R-D. Rule on the findings, then relay them.** Record each finding, your ruling and the verdict
as step D of `core.md` says, but set no `lastReviewed`, in this step and in R-E: a report layer has no commit to record, and `L unpark` refuses a report layer that has one. For `--file`, give the report path, or the code file that the
finding is about. Use these severities:

- **blocker:** a conclusion is wrong, or the report does not answer the question;
- **should_fix:** a claim that the conclusion depends on has no evidence, or a required part is
  missing;
- **nit:** wording, order, a detail that changes no conclusion.

A finding is in scope when it is about what the task asks. A new question that the task did not
ask is out of scope: record it with `L followup`, and do not relay it. On CHANGES REQUESTED, run
`L layer --layer <layer> --set phase=fixing`, and send the relayed findings to the **same**
worker. The worker changes the report file, and says what changed for each finding.

**R-E. Re-verify.** Send the worker's answer for each finding to the **same** reviewer, as step E
of `core.md` says. Record the round, each finding's state and the verdict. The round limit is 3.
If round 3 still has CHANGES REQUESTED, do not send its findings back. Tell the worker to add
each open finding to the section "Known gaps" of the report, and record each one:
`L resolve --state known_limitation`. A wrong conclusion that is still open is not a known gap:
ask the user in text, and park the layer.

**R-F. Deliver.** Check the result yourself:

- the report file exists and is not empty;
- `git status -sb` shows a clean tree, and the branch and `git rev-parse HEAD` are the recorded
  ones (rule 1). If not, stop: ask the user about the difference. Never clean the tree yourself.

Then run `L layer --layer <layer> --set phase=delivered`. Give the user:

- the answer, in 3 to 6 lines;
- the absolute path of the report;
- the known gaps, and what no agent could verify;
- the next tasks that the report proposes. Record each one with `L followup`. Do not start them:
  the user decides.

If an answer to a parked layer came, resume that layer now ("Questions and parked layers" in
`core.md`). Otherwise start the next layer that `L next` gives. A layer that depends on this one
can start now.
When `L next` gives `null` and no layer is parked, go to the finish of your kind file. In its
final report, a report layer shows the path of its report in place of a PR. A tasks run in which
every task is `delivered` has nothing that waits for a merge. After the final report, set it to
`paused` while the follow-up question is open. When that question has its answer and its action, or when you asked no
follow-up question, run `L run --set stage=finish --set state=finished --set nextStep=null`.

## Park and resume

Park a report layer as "Park a layer" in `core.md` says. The worker makes no commit: it saves its
notes in the report file, and it leaves the tree clean. Give the current `HEAD` as the tip:
`L park --layer <layer> --question "<text>" --option ... --tip <HEAD SHA>`.

After the answer, at a stop point, record it with `L answer`, unless it came from the admin page. Then run `L unpark --layer <layer>
--base <current branch> --base-tip <HEAD SHA> --head <HEAD SHA>`. No rebase and no range-diff are
necessary. Exception: a layer that depends on a `pr` layer of a stack run. First put the checkout
back on its recorded `base` branch, as R-A says, and give the recorded `base` and the current
head of that branch to `L unpark`. Continue at the recorded phase and round, with the user's answer.

## More changes on a delivered report

The user can ask for more after the delivery: `/task-manager changes <run-id> <task> <what>`.

1. Run `L show --run <id>`. If the run is `finished`, run `L run --set state=paused` first. Then
   run `L run --set state=active`. If `L` refuses because another run is active for this
   checkout, tell the user, and stop.
2. Record the request: `L event --layer <layer> --type note --summary "changes #<k>: <what>"`.
   Run `L layer --layer <layer> --set phase=fixing`.
3. Launch a worker with the task's tier. Give it the report path and the change. It updates the
   report, and it keeps the earlier conclusions that the change does not touch.
4. A reviewer checks the changed parts only. This check is not a review round. A change that
   adds a new question gets a full review of the new part, with `round` set from 1 again.
5. After APPROVE, deliver again (step R-F).
