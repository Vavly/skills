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
| Hard rule 1 (one writer) | Applies. A worker can run code in the checkout, so it counts as the writer. Do not run a worker while an implementer works. Several workers at the same time: only as "Report layers in parallel" says. |
| Hard rule 2 (the base) | Does not apply: a report layer has no branch. It is never a base. |
| Hard rule 3 (no PR before APPROVE) | Becomes: **no delivery before APPROVE**. The exceptions are the same: the round limit, and findings that you all closed with `L rule`. |
| Hard rules 4, 6, 7, 9 | Apply. |
| Hard rule 5 (attribution) | Applies to the out files of an issue layer and of a comment layer: their text goes to GitHub. |
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
   rule 6): ask in text, and park the layer with `L park --session-only`. Name the one action exactly in
   the question. The yes comes in the session, or as a confirmed answer from the admin page ("A
   confirmed answer" in `core.md`).

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

If `L` refuses the record below, another layer is in work: stop the new worker at once.

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
When `L next` gives `null`, no layer is parked, and its `held` list is empty, go to the finish of
your kind file. If a layer waits for an answer, the run waits: "Choose the next layer" in `core.md`. In its
final report, a report layer shows the path of its report in place of a PR. A tasks run in which
every task is `delivered` has nothing that waits for a merge. After the final report, set it to
`paused` while the follow-up question is open. When that question has its answer and its action, or when you asked no
follow-up question, run `L run --set stage=finish --set state=finished --set nextStep=null`.

## Report layers in parallel

Report layers change nothing in the checkout, so a group of them can work at the same time. This
is off unless the profile gives a number above 1 in "Parallel report tasks". A derived profile
has 1. With a number above 1:

- **Record the limit** after `L init`: `L run --set parallel=<n>` (at most 4). `L` enforces it.
  Use the number of the profile, and do not change it during the run.
- **Which layers.** Run `L next`. Its `ready` list gives every layer that can start, and
  `working` the layers in work. A group has only layers of `ready` with `alone: false`: report,
  issue and comment layers that depend on no `pr` layer. A layer with `alone: true` is a `pr`
  layer, or a report layer of a stack run that reads the code of a `pr` layer: it works alone.
- **Keep the work order.** Start the layers of `ready` from the first one. Stop at the first
  layer with `alone: true`, and never start a layer that comes after it in `ready`. That layer
  starts when `working` is empty, and the group continues after it.
- **Never with a `pr` layer.** Start no report layer while an implementer works or a restack
  runs. Start a `pr` layer only when `working` is empty. `L` refuses these starts. It cannot see
  an implementer that rebases a parked layer, so the rule is yours too.
- **A step that needs the checkout waits for the group.** The resume of a parked `pr` layer, more
  changes on a PR, a CI fix, a restack and the cleanup after a merge all change the checkout.
  For such a step, start no new report layer, wait until `working` is empty, and then do the
  step. Do not do step 3 of "Park a layer" in `core.md` (the switch to another base) while a
  group works.
- **A step of one report layer needs only that layer.** Its unpark, and its send step, need only
  its own worker and reviewer to be stopped. Do not make the user's answer wait for the group.
- **Check the tree one time for the group** (rule 1): clean, and record the branch and `HEAD`,
  before the first worker of the group starts.
- **Tell each worker and each reviewer that other agents use the same checkout.** Then the agent
  writes nothing into the checkout, also no cache and no build output: it runs every command
  that writes (a build, a test run, an experiment) in its own copy outside the checkout. Give
  each agent its own folder for that copy, outside the checkout: a new folder in your session
  scratchpad. The scratch folder of the profile is inside the checkout, so it is not the place.
  A reviewer of a group does not report a tree that is not clean as a finding: it tells you.
- **Each layer has its own loop** (R-A to R-F), its own worker and its own reviewer. A reviewer
  can work while the workers of other layers work: it only reads. Run the `L` commands one at a
  time, as always.
- **A layer that parks, or that waits for the yes of its send step, leaves the group.** Another
  ready report layer can start in its place.
- **At each delivery, check the tree.** If it is not clean, or `HEAD` moved, you cannot know
  which worker did it. Start no new layer. Let the workers in work reach their next report, ask
  each one what it wrote into the checkout, and ask the user. Never clean the tree yourself.
- **A resume.** `working` of `L next` gives the layers of the group. Continue each one as
  "Resume" in `core.md` says, with a new worker or a new reviewer for each.

## Issue tasks and comment tasks

An **issue layer** (outcome `issue`) and a **comment layer** (outcome `comment`) are report layers
with one more step: after the review, and only with the user's yes, you send text to GitHub.
Nothing goes out before that. Rule 2 applies to the worker and to the reviewer with no change.

**The target.** Before R-A, find the repository, and for a comment layer the pull request. Use
the source of the task when it gives a URL. Otherwise run `gh repo view --json nameWithOwner`.
Record it: `L event --layer <layer> --type note --summary "target: <owner/repo>[ PR #<N>]"`. Give
the target to the worker and to the reviewer. Every `gh` command of this section names it: a
clone of a fork can resolve to another repository.

**The out files.** The text that goes out is not the report. The worker writes the report as
every worker does (`reports/report-<slug>.md`: what it did, the evidence, the gaps). It also
writes, in the same folder, the exact text to send:

- *Issue layer:* for issue number `<k>`, `reports/out-<slug>-<k>.title.txt` (one line) and
  `reports/out-<slug>-<k>.body.md`. The body says what is wrong, the evidence with `file:line`,
  how to reproduce it, and what done means. Before it writes an issue, the worker reads the open
  and the closed issues (`gh issue list -R <owner/repo> --state all --search "<words>"`). It
  writes no out file for an issue that exists already, or for a defect that it did not confirm:
  those go into the report.
- *Comment layer:* one file, `reports/out-<slug>-1.body.md`: the findings, most severe first, each
  with `file:line` of the diff, the defect, and the fix that the worker expects. The worker reads
  the pull request with `gh pr view <N> -R <owner/repo>` and `gh pr diff <N> -R <owner/repo>`. It
  does not check out the branch. The text gives no verdict: it does not approve, and it does not
  request changes.

Tell the worker these names in the R-A prompt, as absolute paths. An out file holds only text
for its reader on GitHub: no notes of the worker, and no section of the report.

**The review.** The reviewer checks the report (R-C), and each out file as the text that goes
out: each issue is real, is one piece of work, and is not a duplicate; each finding of a comment
is true, and the text is fair to its author. For a comment layer, the reviewer gives the head
that it checked (`gh pr view <N> -R <owner/repo> --json headRefOid`). Record that head in the
summary of the `review` event: `"APPROVE, PR head <SHA>"`.

**At the round limit.** An out file with an open finding does not go out. Name each such item in
the question as "not included", and do not send it.

**R-F for these layers: ask, send, record.** After APPROVE, do the checks of R-F. Then:

1. **Ask.** Park the layer on a session-only question that names the one action exactly:
   `L park --layer <layer> --session-only --question "<File <n> issues in <owner/repo>: <the
   titles> | Post one review comment on PR #<N> of <owner/repo>>? The text is in <the folder of
   the out files>." --option "send" --option "do not send" --tip <HEAD SHA>`. This is an outward
   action (hard rule 6). The answer is a message in the session, or a confirmed answer from the
   admin page. "do not send" sends nothing, so it is a permitted option.
2. **Close the question first.** When the answer comes, at a stop point: record a session answer
   with `L answer`, and run `L unpark` as "Park and resume" says. Do this before any other step,
   for every answer. The ledger refuses `delivered` for a parked layer.
3. **"do not send".** Run `L layer --layer <layer> --set delivery="not sent: <the user's
   reason>" --set phase=delivered`. The out files stay in the run folder.
4. **The user wants changes.** Send them to the worker (R-D). The reviewer checks the changed out
   files. This check is not a review round. Then ask again, with a new question (step 1): a yes
   is for the text that the user saw.
5. **"send".** First check that the action is still possible. For a comment: the pull request is
   open, and its head is the head of the `review` event. If the head moved, do not send. Ask the
   reviewer to check the out file against the new head. This check is not a review round. If
   the text must change, go to step 4. If the reviewer confirms the text as it is, record the
   new head in a `review` event, and continue.
6. **Send one item at a time, and record each one.** For each out file, in order:
   - run `L run --set nextStep="send <layer>: item <k> of <n>"`, and
     `L event --layer <layer> --type note --summary "sending <k>/<n>"`;
   - send it. An issue: `gh api repos/<owner/repo>/issues -F title=@<title file> -F body=@<body
     file> --jq .html_url`. A comment: `gh api repos/<owner/repo>/pulls/<N>/reviews -f
     event=COMMENT -F body=@<body file> --jq .html_url`. Each command prints the URL of what it
     made. Give the files as they are: do not type a title or a body again. Never send
     `event=APPROVE` or `event=REQUEST_CHANGES`;
   - record it: `L layer --layer <layer> --set delivery="<every URL up to now>"`.
7. **Deliver.** When every item has its record, run
   `L layer --layer <layer> --set phase=delivered`.
8. **A command that fails.** Try that item one more time. If it fails again, do not send the
   items after it. Run `L layer --layer <layer> --set delivery="<the URLs that went out>; not
   sent: items <k> to <n>: <the error>" --set phase=delivered`, and tell the user.

**A resume during the send.** The layer is not parked, its question has an answer "send", and it
is not `delivered`. The `delivery` field of `L show --layer` gives the items that went out, and
the last "sending <k>/<n>" note gives the item that was in progress. That item can be on GitHub
with no record. Look before you send it: for an issue, `gh api
"repos/<owner/repo>/issues?state=all&sort=created&direction=desc&per_page=30" --jq '.[] | .title
+ " " + .html_url'`, and compare with the title file; for a comment, `gh api
repos/<owner/repo>/pulls/<N>/reviews --jq '.[] | .html_url + " " + (.body | length | tostring)'`.
If it is there, record its URL, and continue with the next item. Never send an item that has a
record.

**More changes on a delivered issue layer or comment layer.** "More changes on a delivered
report" applies, with this rule: what went out stays out. The worker writes new out files with
the next numbers. After the review, the question says "<n> more issues" or "a second review
comment". Send only the new files, and add their URLs to `delivery`.

**A session with no terminal** does all of these steps. It needs the confirmed answer "send" or
"do not send" from the admin page.

In the final report, such a layer shows its delivery in place of a PR.

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

1. Run `L show --run <id>`. If an agent of this session works, wait for a stop point. If the run
   is `finished`, run `L run --set state=paused` first. Then
   run `L run --set state=active`. If `L` refuses because another run is active for this
   checkout, tell the user, and stop.
2. Record the request: `L event --layer <layer> --type note --summary "changes #<k>: <what>"`.
   Run `L layer --layer <layer> --set phase=fixing`.
3. Launch a worker with the task's tier. Give it the report path and the change. It updates the
   report, and it keeps the earlier conclusions that the change does not touch.
4. A reviewer checks the changed parts only. This check is not a review round. A change that
   adds a new question gets a full review of the new part, with `round` set from 1 again.
5. After APPROVE, deliver again (step R-F).
