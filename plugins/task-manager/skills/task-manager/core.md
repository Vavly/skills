# Core rules of a run: one reviewed PR per task

`SKILL.md` sends you to this file for every run. A run has one of two kinds. A **stack run** puts
each PR on the PR below it: its kind file is `stack.md`. A **tasks run** holds independent tasks:
its kind file is `independent.md`. Read both files, in full, before you act: this file and your
kind file. The kind file sets the base of each layer, and gives the intake and the finish. Where
the two files disagree, the kind file wins. This file gives everything else: the profile, the hard rules, the tiers,
questions and parked layers, the ledger, the resume, the loop for one layer, and the events.

In this file, a **layer** is one task of the run. In a tasks run, a layer is one independent
task. Each layer has an **outcome**. A `pr` layer changes the repository: it has its own branch,
and it ends as a reviewed pull request. A `report` layer changes nothing in the repository: an
investigation, a plan, a debug session, a code execution or a search for information. It ends as
a reviewed report file in the run folder. This file gives the loop of a `pr` layer (Phase 1).
[report-tasks.md](report-tasks.md) gives the loop of a report layer, and says which rules of
this file apply to it. Every rule here applies to both kinds, unless the rule says
"stack run only" or "tasks run only".

Three placeholders occur in all files of this skill:

- `<skill>` is the absolute path of the folder that holds this file: the folder of the
  `task-manager` skill. `SKILL.md` says how to find it.
- `<default>` is the default branch of the repository, from the profile. It is `main` in most
  repositories.
- `<checkout>` is the absolute path of the checkout that this session works in.

You are the **orchestrator** and the admin of the run. You own every decision inside the scope of
the tasks. You do not write code, and you do not review code. You find the source of each task,
brief the agents, relay their findings, rule on scope, keep the ledger, and verify every PR. The
user gets one short progress line at each step. You ask the user only in the cases that hard
rules 6 and 7 and the table in "Questions and parked layers" list.

Agent briefs live next to this file. Pass their absolute paths and the absolute path of the
profile to the agents; do not paste them. Tell each agent the run kind: `kind: stack` or
`kind: tasks`.

| File | Reader |
|---|---|
| [implementer-brief.md](implementer-brief.md) | the implementer of each layer |
| [reviewer-brief.md](reviewer-brief.md) | the reviewer of each layer |
| [restack.md](restack.md) | stack run only: the restacker and the stack verifier |

## The profile

This skill has no project rule of its own. The **profile** is the file that gives the rules of
one project: its default branch, commands, checks, review skill, PR rules, CI, high-risk areas and
user data. [profile-template.md](profile-template.md) lists its sections. Find it in this order:

1. `<checkout>/.claude/task-manager.md`, if it exists. `/task-manager setup` writes it.
2. `<run folder>/profile.md`, if it exists. An earlier session of this run made it.
3. Neither exists: make one at intake, before the tiers.
   - Read `AGENTS.md`, `CLAUDE.md`, `.claude/rules/`, the README, the contribution guide, the
     package scripts and the CI workflows of the checkout.
   - Write every section of the template to a file in your session scratchpad. Write "none" in a
     section that does not apply. Do not guess a command: write only a command that a file of
     the repo gives.
   - Show the user a short summary, and ask for a yes or corrections together with the intake
     decisions.
   - After `L init`, write the file to `<run folder>/profile.md` with your own tools.
   - Tell the user that `/task-manager setup` makes a permanent profile.

Give the absolute path of the profile to every agent. "The profile" in these files means that
file. A section that says "none" means that its step does not apply: skip the step, and say so in
the report. The hard rules below win over the profile. The profile wins over every example in
these files.

## Hard rules

1. **One checkout, one writer.** No agent creates or enters a git worktree. Only one agent may change the
   tree at a time. Work on one layer at a time, in stack order. The order changes only when a
   layer is parked (see "Questions and parked layers"). Start a reviewer only while its
   implementer is stopped. Never run two implementers at the same time. `L` refuses the start
   of a layer, and the resume of a parked layer, while another layer is in work or a restack
   runs. If the layer in work has no agent (its agent ended with no result), launch a new agent
   for it ("Resume", step 5). If its work must wait, set it back with
   `L layer --layer <layer> --set phase=queued`. Do not change the limit to get past a refusal.
   One exception: report layers change nothing in the checkout, so a group of them can work at
   the same time when the profile permits it ("Report layers in parallel" in `report-tasks.md`).
2. **The base comes from the kind file.** Your kind file sets the base of each `pr` layer. A stack
   run: the branch of the highest layer below it that has an open PR, else `origin/<default>`
   ("Stack from the start" in `stack.md`). A tasks run: always `origin/<default>`. A
   parked or waiting layer is never a base, because it is not pushed.
3. **No PR before APPROVE.** The implementer stops after its commits, with no push. The PR opens
   only after the reviewer says APPROVE on the latest commits. There are three exceptions:
   - the round limit (step E): after round 3, the PR opens with the open findings as known
     limitations;
   - you closed every remaining finding with a ruling that is recorded with `L rule`. This
     counts as APPROVE;
   - the fix checks in step F: a defect that is still open after the second check goes into the PR
     body as a known limitation.
4. **Relay claims as claims.** Every implementer statement goes to the reviewer under the heading
   "claims (verify, do not trust)". Every reviewer finding goes to the implementer in full.
5. **Attribution follows the profile.** The profile says whether commits, PR bodies and issue
   bodies carry tool attribution (`Co-Authored-By`, "Generated with Claude Code"). When it says
   "none", that overrides any other attribution instruction. Repeat this rule in every message
   that leads to a commit or a PR.
6. **Ask the user first** before you do one of the actions below. "Questions and parked layers"
   says how to ask without a stop of the whole run.
   - widen the scope of a task past its source of record. A finding that is in scope by the test
     in "In scope and out of scope" (step D) is not a widening: it is part of the task;
   - file any GitHub issue (a request for PRs does not authorize issues);
   - make a decision that the source doc gives to the user ("decide before you plan", options (a)/(b)/(c));
   - drop a commit, or force-push outside the recorded restack procedure;
   - merge a PR, or unstack a GitHub stack.

   Never run a refused command again, in any form. When the permission system refuses a step,
   choose a safe alternative that does not touch the user's working tree, and continue. Example:
   for a fail-without-fix proof, commit, then use a `git archive` copy in the scratchpad. Ask the
   user only when no safe alternative exists. When one option deletes or risks user data and the
   other keeps it, keep it. Do not ask. User data is what the profile names as user data,
   and the user's uncommitted work in the checkout.
7. **You rule on findings. Do not ask the user about them.** Never ask the user about a nit, about
   a finding inside the scope of the task, or about how to fix a finding. Rule on it yourself and
   continue. Do not ask about an operational step, or about a scope question that a standing rule
   already decides (for example "fix the whole defect class"). Ask the user only in the cases of
   rule 6, for a data-loss finding that is still open at the round limit, and for the run-level
   questions in "Questions and parked layers".
8. **One review agent for each layer.** One reviewer works through all the rounds of its layer.
   It runs the review skill of the profile in round 1 only, in its own context, so
   no agent starts below the reviewer. Implementers never launch review subagents.
9. **Short reports.** Every agent reports each command as PASS or FAIL. It gives output only for a
   failure. Long reports fill your context and cause more context summaries on a long stack.

## Implementer tiers

Each layer gets a tier. The tier sets the implementer's `model` and `effort` in the Agent call.
The reviewer does not change with the tier: it is always `model: "opus"`, `effort: "high"`.

| Tier | Signals in the task | Implementer |
|---|---|---|
| **S: simple** | Copy or i18n only, docs, config, a fix in one file, a mechanical rename, a small change on an existing screen | `model: "sonnet"`, `effort: "medium"` |
| **M: standard** | Usual feature work in one area, a new UI state, several files, a check of the real app is necessary | `model: "opus"`, `effort: "high"` |
| **L: complex** | Any one of the high-risk signals that the profile lists ("Tiers"). Always: a persisted field or a schema migration, a data sync or round trip, a security boundary, restart or restore, a risk of data loss | `model: "opus"`, `effort: "xhigh"` |

- When a task is between two tiers, give it the higher tier.
- The tier and a one-line reason go into the layers file of `L init` (the intake of your kind file).
- **Escalation from S.** Escalate an S layer to M when round 1 returns a blocker, or when the
  implementer reports FAIL on the same check two times. Do not continue with the S implementer.
  Launch a new M implementer (step A) on the same branch. Tell it: "The branch exists and is
  checked out. Do not create it. Read the plan and `git diff <base tip>...HEAD` first." Then tell
  it what to continue, from the phase where the escalation happened:
  - before the first review: finish the implementation and report (step B);
  - in a review round: fix the findings, which you give to it;
  - in step F: run the final checks from the failed check onward.

  Do not run step A's `L layer` record for it: the phase and the base stay. If a reviewer exists,
  it stays the same. From now on the layer's tier is M, also after a resume. Record it first:
  `L layer --layer <layer> --set tier=M --set escalated=true --set
  implementer=<new id>`, then `L event --layer <layer> --type escalation --summary "<phase>:
  <cause>"`. Then, in a review round, run `L layer --layer <layer> --set phase=fixing` as in
  step D. A report layer escalates in the same way: the new worker continues
  from the plan and the report file, not from a branch. Use another model only when the user asks for it.

## Questions and parked layers

A question that blocks only one layer must not stop the other layers. `AskUserQuestion` stops
the whole session until the user answers, and the admin page cannot answer its dialog. So, when
the run exists, ask in text and record the question in the ledger. Use `AskUserQuestion` only
before the run exists.

**Three kinds of question.**

| Kind | Examples | How to ask |
|---|---|---|
| Before the run exists | The intake decisions, a dirty tree at intake, "resume it, or start a new run", which run to resume | `AskUserQuestion`. No `L ask`: no run exists for it yet. Record the intake decisions after `L init` with `L decision`. |
| Run-level: nothing can move without the answer | A dirty tree at a resume, an empty commit after a rebase (stack run), which follow-ups to file, the merge yes (stack run) | `L ask` (no `--layer`). Ask in text, start the answer watcher (below), and stop your turn. The answer comes as a message, or from the admin page. The empty commit and the merge yes are session-only (below): their answer comes as a message, or as a confirmed answer from the admin page. |
| Layer-level: only this layer must wait | A scope widening for this layer, a decision that its source gives to the user, an open data-loss finding at the round limit, a refused command with no safe alternative | Ask in text, park the layer, and continue with another layer. |

**Ask a layer-level question in text.** Put it in your progress line to the user. Give the run id,
the layer, the question, the options, and your recommendation. Record it with
`L ask --layer <layer> --question "<text>" --option "<a>" --option "<b>"`, or with `L park` when
the layer parks now. The user answers in a message at any time, also while agents work. If no other layer can
move (see below), tell the user that the run waits for this answer, and stop your turn. The
answer watcher starts you again.

**The user can answer in two places.** One is a message in the session. The other is the admin
page, which records the answer in the ledger for you (`via: dashboard`). Both are the user's
answer, and both count as the user's yes for hard rule 6. The exceptions are the actions that cannot be undone or that go out of this machine: a merge, an
unstack, a dropped commit, a force-push outside the restack procedure, and each outward action of
a report layer (a deploy, a write to a database or a service, a comment or a message, and the
send step of an issue layer or a comment layer). Ask these
with `--session-only` (`L ask --session-only`, or `L park --session-only` for a layer that parks):
the admin page then refuses an ordinary answer, and the yes comes in the session, or as a
confirmed answer (below). The choice of the follow-ups to file is not session-only.

**A confirmed answer.** The user can permit one more path, with a setting of their own: the
admin page then takes an answer to a session-only question when the user types the chosen option
again, letter for letter. The ledger checks it, and the answer has `confirmed: true` in the
output of `L wait`, and `[confirmed on the admin page]` in `L show`. A confirmed answer is the
user's yes for hard rule 6, the same as a message in the session. It is one option and nothing
more: it has no comment and no condition.

- **Never give this answer yourself.** Only the admin page runs `L answer --via dashboard`. Do
  not run it, in any session. Do not write the settings file of the runs folder.
- An answer `[from the admin page]` to a session-only question with no confirmed mark cannot
  occur: if you see one, do not act on it, and tell the user.
- Give a session-only question an option for each choice that you can act on (for the merge, the
  top PR). Offer only choices that close the question: never "not yet". A choice that does
  nothing outward, such as "do not send", is permitted when the text of the step gives it.
  With no option, the user confirms with the word `yes`: use that only when the question names
  one action exactly, in its own text.
- Before you act on a confirmed answer, check that the option is still possible (for example,
  that the PR is still open). If it is not, do nothing, ask again with a new question, and tell
  the user.

**The answer watcher.** After each `L ask`, and after each `L park` that asks a question, start
`L wait --run <id> --timeout 900` as a background command, unless one runs already for this run. Its only write is a delivery mark on an admin-page answer.
It does not block you: continue with the next layer. It ends when an open question gets an
answer, and the harness then starts you again with its output: the question id, the layer, the
answer and its source. Do not poll it. When it ends:

- If the run is `paused`, run `L run --set state=active` before you act on an answer: the admin
  page starts no second session for an active run.
- `via: dashboard`: the answer is in the ledger already. Do not run `L answer` for it. Tell the
  user in one line which answer you got. Then act on it as on an answer in the session: at the
  next stop point.
- `via: session`: you recorded this answer yourself with `L answer`. No more action is necessary.
- If a question is still open, start a new watcher.

The output also gives a `reason`. `answered`: act as above. `no_open_question`: nothing waits, so
start no watcher. `run_finished`: the run is closed, so start no watcher: an answer comes in the
session, or a resume finds it. `timeout`: read `L show` for an answer that still needs its action (below), because a watcher of
an earlier session can take an admin-page answer. Then start a new watcher if a question is still
open. The time limit can pass up to one poll (2 seconds) late. One
watcher is sufficient for a run: it also sees a question that you ask after it started, and an
answer that the admin page recorded before it started.

**The ledger shows if an answer still needs its action.** The watcher gives each admin-page
answer one time, and a session can end between that moment and the stop point. So do not use the
delivery to decide. Use the state:

- A layer is parked on a question that has an answer (`L show` says "ready to unpark"): the
  action is not done. Resume the layer, from either source of the answer.
- The layer is not parked any more: the action is done. An answer that comes again needs nothing.
- A run-level question: after you act on its answer, record
  `L event --type note --summary "acted on <question id>"`. An answered run-level question with
  no such note still needs its action.

The user can also answer on the admin page while no session runs. A resume finds that answer by
these rules ("Resume", step 6).

**A layer with an open PR is never parked.** The layers above it already use its pushed tip.
Record the question with `L ask --layer <layer>` and continue. Act on the answer at the next stop
point (below). If the answer
needs new commits on that layer, a restack of the layers above follows (stack run only). An answer that needs no
change (for example, the code already does what the user chose) needs only its record: `L answer`
for a session answer, nothing for an answer from the admin page.

**A stop point** needs both of these conditions:

- the current layer's PR is open and verified (step H), or its report is delivered (step R-F of
  `report-tasks.md`), or the current layer is parked; **and**
- no agent runs: no implementer, reviewer, restacker or stack verifier.

A pause inside a round is not a stop point, also when no agent runs (for example between step D
and the message to the implementer). Act on an answer, and start a restack, only at a stop point.
Only one writer works at a time.

**Park a layer.**

1. Its agents stop at a safe point. If the implementer has work that is not committed, it commits
   it on its branch (`wip: <what>` is permitted, when the merge method of the profile is a squash). The tree must be
   clean.
2. Run `L park --layer <layer> --question "<text>" --option ... --tip <tip SHA>`. If you asked
   the question earlier with `L ask`, give `--id <question id>` in place of `--question`. `L park`
   records the phase, the round, the base tip, the tip and the last reviewed SHA. These SHAs do
   not change until the layer's own rebase, also when a restack moves other layers.
3. Switch to the base of the next layer that can move.

**Choose the next layer.** Run `L next`. It gives the lowest layer in stack order that has not
started and whose dependencies all have an open or merged PR, directly or through another layer
(the "depends on" lists of the intake; a delivered report counts as an open PR here. In a
tasks run, only a task that waits for a parked report task is blocked). A layer that depends on a parked layer is never next. Its base follows hard rule 2. When the layer starts (`--set phase=implementing`), `L` moves it
below the parked layers. A layer that depends on a parked layer waits too, but it is not parked:
it has not started, and it has no branch. If `L next` gives `null`, no layer can move, and the
question becomes run-level. Tell the user that the run waits for the answer, and stop your turn:
the answer watcher starts you again. Record nothing more: the
`L park` record already shows the question.

**Resume a parked layer after the answer.**

1. Record the answer with `L answer --id <question id> --answer "<text>"`, unless it came from
   the admin page: that answer is in the ledger already, and `L answer` refuses it. Wait for a stop
   point. Read the recorded SHAs of the parked layer from `L show`.
   **Tasks run only:** the base is `origin/<default>`, and the task's branch is not pushed. No rebase
   is necessary. Skip steps 2 to 4. The checkout is on another branch now, so the layer's
   implementer (a new one in a new session, "Resume" step 5) must get its branch back first. Tell it: "Run `git status -sb`; the tree must be
   clean. Check out `<branch>`. `git rev-parse HEAD` must be `<recorded tip>`. If not, stop and
   report." Then run `L unpark --layer <layer> --base <default> --base-tip <recorded base tip> --head
   <recorded tip>`, and add `--last-reviewed <recorded last reviewed SHA>` when `L show` gives one.
   Then continue at step 5.
2. Stack run only. Move the layer directly above the highest layer that has an open PR. That
   layer's branch is its new base (hard rule 2). Every other layer stays above it: layers that are still parked, and
   layers that have not started. This keeps the stack linear: each PR has exactly one PR on top.
3. The layer's implementer does the rebase, because it owns the branch. In the same session, send
   it a message. In a new session, launch a new one with the layer's tier (see "Resume"). Give it:
   `git rebase --onto <new base tip> <recorded base tip> <branch>`. It is not pushed, so no force
   push is necessary. Doc conflicts follow [restack.md](restack.md) step 3. On a code conflict,
   the implementer resolves it and reports each resolution.
4. The same reviewer checks the rebase with `git range-diff <recorded base tip>..<recorded tip>
   <new base tip>..HEAD`. The only differences must be the conflict resolutions that the
   implementer named. This check is not a review round. From now on, every re-verification of the
   layer uses ranges on the new base. Record the old and the new ranges with
   `L event --layer <layer> --type note --summary "rebase: <old range> -> <new range>"`. Then run
   `L unpark --layer <layer> --base <base branch> --base-tip <SHA> --head <new tip> --last-reviewed
   <rebased counterpart of the last reviewed SHA, from the range-diff>`. `--last-reviewed` is
   required when the layer had a review before it parked. When `L show` gives no last reviewed SHA
   for the layer, it parked before its first review report: skip the range-diff check, because its
   first review covers the rebased branch, and give `L unpark` no `--last-reviewed`. `L unpark`
   clears the park, records the new base, head and last reviewed SHA, and moves the layer to the
   position of step 2.
5. Continue at the recorded phase and round, with the user's answer:
   - an answer to a scope question, when a review round is still available: the implementer gets
     it with the findings of the next round;
   - any other answer that needs a change: one more fix and one more verification of what the answer
     covers. This is not a review round, like the fix check in step F. This applies to a data-loss
     finding at the round limit, a data-loss defect parked in step F, and a scope question after
     round 3. Then continue at the step after the one where the layer parked (step F, or step G
     after a park in step F). `L unpark` records the head before this fix, so record the fix after
     its verification: `L layer --layer <layer> --set head=<SHA> --set lastReviewed=<SHA>`,
     `L resolve` if the fix closes a recorded finding, and `L event --layer <layer> --type note
     --summary "<answer>: fix <SHA>, CONFIRMED FIXED"`.
6. Layers that waited for it can now start, above it.

Stack run only: the final merge order is the order at the end of the run. Phase 2 step 1 of the
`stack.md` writes it into every PR.

## Run folder and the ledger

Every run keeps its state in its own folder, outside every clone. Any session in any clone can
read it, and no commit or PR can carry it. Several runs can exist at the same time.

**The ledger** in this skill means the run state in the run folder. Only the helper script writes
it. Never edit a JSON file of the run folder by hand: one wrong comma makes the run unreadable to
a resume. Below, `L` means this command, run from the repo root:

```
node <skill>/scripts/task-manager-ledger.mjs
```

Write the full command in each call, with the path in quotes. Do not keep `node <path>` in one
shell variable: some shells run it as one word, and the command fails.

Each `L` command checks its input, writes, adds one event with the time, and prints one line of
JSON. On bad input it prints `error: <reason>` and exits 1: correct the input and run it again.
Run `L` commands one at a time, never in parallel. A lock file keeps two commands on one run from
mixing their writes, but a command that waits more than 10 seconds for it stops with an error.

```
~/.task-manager/runs/           ($TASK_MANAGER_RUNS changes it)
  <run-id>/                   <run-id> = <YYYY-MM-DD>-<slug>, for example 2026-11-06-undo-timeline
    run.json                  the header and the layers
    events.jsonl              one line for each event
    questions.jsonl           the questions to the user, and the answers
    findings/<layer>.jsonl    the findings of the layer, with your rulings and their state
    followups.jsonl           the out-of-scope items
    plans/plan-<slug>.md      the implementer plans (agents write these with their own tools)
    plans/main-<slug>.md      a copy of each plan document that the user gave (L main-plan writes these)
    reports/report-<slug>.md  the report of each report layer (agents write these with their own tools)
    profile.md                the profile, only when the checkout has none (you write this)
    stack-original-tips.txt   the SHA records of the latest restack (the restacker writes this)
```

- **Run id.** `L init` makes it from the date and the title, and adds `-2`, `-3` when the folder
  exists. `L init` also refuses while another run for the same checkout is `active`.
- **Layer id.** `L init` gives each layer a stable id: `l1`, `l2` and so on, in intake order. The
  id never changes. Its position in the stack can change when a layer is parked: `L` moves it.
  Every prompt and message names a layer by its id, never by its position. `<layer>` in this skill
  means the layer id.
- **No index file.** `L list` scans the run folders. With no shared file, two sessions in two
  clones never write the same file.
- **Derived, never stored.** `L show` and `L next` calculate the board column of each layer, the
  parked layers that block a layer, and the next layer that can move. Use their answers. Do not
  calculate these yourself.
- **Write the ledger after every event, before the next action.** It is the only state that a new
  session can see. Before a stop, set the next step: `L run --run <id> --set nextStep="<step>"`.
- **Record every question that waits for the user.** Run `L ask` before you ask (with `--layer`
  for a layer question), and `L answer` when the answer comes. This applies to every question after
  `L init`. The user can then answer on the admin page too. The admin board shows an open question as
  "needs input". A question before `L init`, or before the run is chosen, gets no `L ask`,
  because no run exists for it yet. These are: the intake decisions (record them after `L init`
  with `L decision`), a dirty tree at intake, "resume it, or start a new run", and which run to
  resume.
- **A finished run is closed.** `L` refuses its writes, except a reopen
  (`L run --set state=paused`), a merge record of a layer whose PR is open
  (`L layer --set phase=merged` and `L event --type merge`), a filed follow-up
  (`L followup-filed`), and an answer to a question that was still open (`L answer`).
- **A run belongs to one checkout.** Commits that are not pushed exist only in that checkout. One
  checkout has one active run at a time, a stack run or a tasks run, because there is only one
  writer.
- **The outcome of a layer.** The layers file of `L init` gives each layer its `outcome`: `pr`
  (the default), `report`, `issue` or `comment`. A layer that is not a `pr` layer has no branch,
  no PR and no CI. It ends at the phase `delivered`, which needs its `report` path and the file,
  and for an `issue` layer and a `comment` layer also its `delivery`: what went out. A layer that depends on it can start
  then.
- **The run kind.** `L init --kind tasks` makes a tasks run. With no `--kind`, the run is a stack
  run. A tasks run refuses a `dependsOn` that names a `pr` task, the GitHub stack, the `restack` stage and the run-level CI
  keys. It records CI on each task instead (`ciRunUrl`, `ciResult` on the layer).
- Never put a run-folder path in a commit or a PR body. The path is local to this machine.
- The layers of finished runs (tier, rounds, escalation) are the data to tune the tiers.

**Commands for each event.** Each command except `init` and `list` takes `--run <id>`; the
steps below leave it out. In each command, `--layer` takes the layer id.

| Event | Command |
|---|---|
| Start a run (the intake of your kind file) | `L init [--kind tasks] --title --checkout --request-file --layers-file` |
| Check the plan of a run, and write nothing (`/task-manager preview`) | `L init --dry-run` with the same options. It prints the run that `init` would make, `activeRun` and `pausedRuns` for the checkout, and a token estimate from earlier runs. Only `init` takes `--dry-run`. |
| A decision of the user at intake | `L decision --question --answer` |
| A layer field changes: phase, round, branch, SHAs, agent ids, tier, escalation, PR | `L layer --layer <layer> --set key=value ...` |
| A run field changes: state, stage, next step, CI | `L run --set key=value ...` |
| A question to the user, and its answer | `L ask [--layer] [--session-only] --question --option ...`, `L answer --id --answer`. `--session-only` is for the questions that "The user can answer in two places" lists: the admin page cannot answer it, or only with a typed confirmation when the user's setting permits that. |
| Start a session with no terminal, for the admin page | `L start-session --run <id>`. Only the admin page runs it, and only with the user's setting. Do not run it yourself. |
| What one agent used, when it returns | `L usage [--layer <layer>] --role --agent --model --tokens --tool-uses --duration-ms [--cost]`. `--layer` is required for an implementer and a reviewer. With no `--layer`, the record is for the run: a restacker or a verifier. A finished run accepts it. |
| Test the user's notification settings | `L notify-test`. It sends one test notification in place, and prints what each sender did. `L` sends the real notifications itself, after `ask`, `park` and a change to `paused` or `finished`: you run no command for them. |
| Wait for an answer, in the background | `L wait --run <id> [--timeout <seconds>]`. It prints `{"answered": [{id, layer, answer, via}], "reason"}` and ends. `reason` is `answered`, `no_open_question`, `run_finished` or `timeout`. |
| Park a layer, and resume it | `L park --layer (--question --option ... [--session-only] \| --id) --tip`, `L unpark --layer --base --base-tip --head [--last-reviewed]` |
| A finding, your ruling, its state after a fix | `L finding`, `L rule`, `L resolve` |
| A plan document that the user gave as a source (the intake of your kind file) | `L main-plan --file <path>`. It copies the file to `plans/main-<slug>.md` and prints the path. The same text is copied one time only. |
| An out-of-scope item, and its issue when filed | `L followup [--layer] --title --body [--data-loss]`, `L followup-filed --id --issue` |
| Anything else worth a line in the history | `L event --type <type> --summary` |
| Read the state | `L show` (the run), `L show --layer <layer>` (one layer's findings, rulings, review rounds and questions), `L next` (it prints `next`, and also `ready`: every layer that can start, with `alone: true` for a layer that is never in a group, `working`: the layers in work, and `parallel`: the limit of the run), `L list [--checkout] [--state]` |

Layer keys for `--set`: `phase` (`queued`, `implementing`, `review`, `fixing`, `final_checks`,
`opening_pr`, `pr_open`, `merged`; a report layer: `queued`, `implementing`, `review`, `fixing`,
`delivered`), `outcome` (`pr`, `report`, `issue`, `comment`; only while the layer is `queued`), `report`
(`reports/report-<slug>.md`, relative to the run folder; not for a `pr` layer), `delivery` (one line: what an `issue` layer or a `comment` layer sent, or `not sent: <reason>`), `round` (0 to 3), `tier`, `tierReason`, `escalated`, `branch`,
`base`, `baseTip`, `head`, `lastReviewed`, `implementer`, `reviewer`, `pr`, `prUrl`, `plan`
(`plans/<slug>.md`, relative to the run folder), `dependsOn` (ids, comma-separated; in a tasks run, only ids of report layers), and in a tasks run only `ciRunUrl` (it sets `ciResult` to `pending`) and `ciResult`
(`pending`, `pass`, `fail`, `no_e2e`). Run keys:
`state` (`active`, `paused`, `finished`), `stage` (`intake`, `layers`, `restack`, `ci`, `finish`;
`restack` is stack run only), `nextStep` (`null` clears it), and in a stack run only `stack` (the
GitHub stack number, or `null` after an unstack), `ciPr`, `ciRunUrl`, `ciResult` (`pending`,
`pass`, `fail`, `no_e2e`). Finding fields: `--round
--severity (blocker|should_fix|nit) --file [--line] --defect [--expected-fix]`; `rule --id --ruling
(relay|closed|out_of_scope) [--reason]`; `resolve --id --state
(open|fixed|not_fixed|closed|known_limitation) [--sha]`.

## Resume

`/task-manager resume [<run-id>]` continues a run in a new session. `L show` gives the kind of
the run: read its kind file before you continue.

**A session with no terminal.** The admin page can start this mode for the user. The environment
variable `TASK_MANAGER_NO_TERMINAL` is then `1`, and no user reads your text or answers in the
session. In that session:

- Do not use `AskUserQuestion`. Record each question with `L ask` or `L park`: the user answers
  on the admin page, and the ledger notifies the user.
- Do not do the action of a session-only question, unless its answer is confirmed ("A confirmed
  answer" in "Questions and parked layers"). With no confirmed answer, leave the question open.
- When no layer can move, set `state=paused` with the next step, and end. Start no answer watcher
  before you end: the page then shows that no session watches, and the user can start one again.
- If a step needs a permission that you do not get, record it with `L event --type note`, set
  `state=paused`, and end.

1. **Find the run.** With no run id, run
   `L list --checkout <absolute path of this checkout> --state active,paused`. If it gives more
   than one run, ask the user which one. If it reports a broken run folder, tell the user.
2. **Check the checkout.** If this session's checkout is not the run's checkout, stop. Tell the
   user which checkout owns the run. Then find the profile ("The profile").
3. **Read the state.** Run `L show --run <id>`. It gives the request, the decisions, each layer
   with its column, SHAs and agent ids, the parked layers with their SHAs and answers, the open and
   the recently answered questions, the follow-ups, the last events and the next step. Then run
   `L show --run <id> --layer <layer>` for the current layer: its findings, your rulings, the
   verdict and range of each round, and its questions. The current layer is the layer that is
   not parked and whose phase is `implementing`, `review`, `fixing`, `final_checks` or
   `opening_pr`. If no layer has one of these phases, skip this command: the next layer from
   `L next` starts at step A.
4. **Check the real state.** The ledger can be one event behind. Run `git fetch origin` and
   `git status -sb`.
   - If the tree is not clean, stop. This is a run-level question: an agent of the earlier session
     can have left work that is not committed. Record it with `L ask --question "<what is not
     clean>"`, ask the user in text, and stop your turn. Record a session answer with `L answer`. Never
     clean, stash or commit the tree yourself.
   - For each layer, compare `git rev-parse <branch>` with `git ls-remote origin <branch>`, and run
     `gh pr view <N>` for each PR. A layer with no PR has no remote branch, so an empty
     `ls-remote` result is correct for it. When the real state is different from the ledger, the
     real state is correct. Correct the ledger with `L layer` and record the difference with
     `L event --type note`.
   - Stack run only: check the GitHub stack, as "Resume: the GitHub stack" in
     `stack.md` says.
   - Tasks run only: for each task with a `ciRunUrl` and `ciResult=pending`, read the run with
     step 4 of "Run CI on a PR and check it". If the run is `completed`, record the result that
     came while no session ran.
5. **Start new agents.** A session cannot send messages to the agents of an earlier session. Use
   the layer's current tier: M if it was escalated.
   - Implementer, when the layer stopped before its first report (step B): launch a new one. Tell
     it that the branch exists if `git rev-parse <branch>` finds it, and give it the plan path.
     It finishes the implementation from the branch and the plan, then reports.
   - Reviewer, when round 1 finished: launch a new one for the current layer (step C), but with
     this first line in place of the step C one: "You are the REVIEWER for layer `<layer>` of a run of
     `kind: <stack|tasks>`. First read and follow every rule in `<skill>/reviewer-brief.md`, and the project profile at `<profile path>`.
     Round 1 finished in an earlier session. Do not run a review skill. Continue from the
     history below." Give it the output of `L show --run <id> --layer <layer>` as that history.
     It continues at the recorded round, because the round count does not reset.
   - Reviewer, when round 1 did not finish: launch a new one with the normal step C prompt.
   - Implementer, when fixes or final checks are pending: launch a new one. Tell it that the
     branch exists (see the escalation in "Implementer tiers"), and give it the findings to fix or
     the check to run.
   - A report layer: use the R-A and R-C prompts of `report-tasks.md`, not the prompts above. Give
     the new worker the report path and the plan path: it continues from the report file. Give a
     new reviewer the output of `L show --run <id> --layer <layer>` as its history.
   - Record each new agent: `L layer --layer <layer> --set implementer=<id>` or
     `--set reviewer=<id>`.
6. **Report.** Tell the user the run id, the current layer and its position of *n*, the round,
   and the next step. Give every open question again, with its layer, because the user cannot
   see the earlier session.
   Run `L run --run <id> --set state=active` and `L event --run <id> --type resume --summary
   "<what you found>"`. Then run `L wait --run <id> --timeout 1` in the
   foreground: it marks the admin-page answers that came while no session ran as given. Then find
   every answer that still needs its action ("The ledger shows if an answer still needs its
   action"), from `L show`, and act on each one. If a question is still open, start the answer
   watcher in the background. Then continue the loop. If the run then only waits for the user (every
   layer has its outcome, and every answer has its action), set `state=paused` again before you stop,
   and do not ask an open question a second time: an `active` run blocks a new run in
   this checkout. A parked layer stays parked until its answer
   comes.

When the user stops a run, or the session ends before the run finishes, run
`L run --run <id> --set state=paused --set nextStep="<the next step>"`.

## Phase 1 — The loop for one layer

**A. Implementer.** Launch a `general-purpose` agent in the background, with the `model` and
`effort` of the layer's tier. Its prompt contains:

- "You are the IMPLEMENTER for layer `<layer>` of a run of `kind: <stack|tasks>`. First read and
  follow every rule in `<skill>/implementer-brief.md`, and the project profile at
  `<profile path>`. Load each skill that the profile requires for an implementer before you write
  the plan, and apply it to every change and every fix."
- The task: the source of record with file and lines, the acceptance criteria, and the user's
  decisions for it.
- The scope limit: the other tasks are other layers, so do not do them. Name the tasks that are
  near this one.
- The base from hard rule 2: `origin/<default>`, or `origin/<base branch>` at SHA `<tip>`. Give a
  suggested branch name (`fix/…`, `feat/…`).
- The plan path: `<run folder>/plans/plan-<slug>.md`, as an absolute path.
- The skills that the profile names for the area of this task.
- Stack run only: what the lower layers changed, if this task touches the same code.
- The absolute paths of the reports of the report layers that this layer depends on. The
  implementer reads them before it writes the plan.

If `L` refuses the record below, another layer is in work: stop the new agent at once, and wait
for a stop point.

Record the start: `L layer --layer <layer> --set phase=implementing --set implementer=<agent id>
--set base=<base branch> --set baseTip=<SHA> --set branch=<suggested branch> --set
plan=plans/plan-<slug>.md` (the slug uses `a-z`, `0-9` and `-` only). `base` is the branch name
without `origin/`: `<default>` for a layer with no open PR below it. The branch is recorded now, so that
a layer that parks before step B has it. Step B corrects it if the implementer uses another name.
`L` moves a starting layer below the parked layers.

**B. Wait for the report.** A notification can say that the agent waits on its own background
work, for example a long test run. Then wait. Do not relaunch the agent, and do not poll it.
Record the branch and the tip: `L layer --layer <layer> --set branch=<branch> --set head=<SHA>`.
Record the report: `L event --layer <layer> --type report --summary "<one line>"`. The report must
list each skill that the profile requires for an implementer. If one is missing, send the task
back to the implementer: it must load the skill and check its change against it before the
review starts.

**Record the usage of each agent.** When an agent returns, or ends its turn after a message, the
harness gives its tokens, its tool uses and its time. Record them, for every agent of the run and
in every step: `L usage --layer <layer> --role implementer|reviewer --agent <agent id> --model
<model> --tokens <n> --tool-uses <n> --duration-ms <n>`. A restacker and a stack verifier work on
several layers: record them with `--role restacker` or `--role verifier` and no `--layer`. Give
only the numbers that you got, and never estimate one: leave out an option that has no number.
Record nothing for yourself: the harness gives no numbers for the orchestrator. Give `--cost <dollars>` only when a source gives the cost. A
record is for one return: an agent that you message three times gets three records. The admin
page adds them for each layer, each role and each tier.

**C. Reviewer.** Launch a new `general-purpose` agent in the background, with `model: "opus"` and
`effort: "high"` for every tier. Its prompt contains:

- "You are the REVIEWER for layer `<layer>` of a run of `kind: <stack|tasks>`. First read and
  follow every rule in `<skill>/reviewer-brief.md`, and the project profile at `<profile path>`.
  If the profile names a review skill, load it with the argument `<base tip>...HEAD`, and follow
  it in your own context. Run it in this round only. If the profile names none, do the round-1
  review of your brief. Never load a review skill that starts agents, and never launch an agent.
  Run only the checks for the changed code. The implementer runs the full suite."
- Record it: `L layer --layer <layer> --set phase=review --set round=1 --set reviewer=<agent id>`.
  All rounds of this layer go to this agent.
- The source of record, the branch (now checked out), the base tip SHA, and the diff command
  `git diff <base tip>...HEAD`.
- The plan path.
- The implementer's claims as a list, under "claims (verify, do not trust)".
- The implementer's open points, each one to get a ruling.
- An "especially check" list: the risks you see from the task and the report.

**D. Rule on the findings, then relay them.** First, the round-1 report must confirm the round-1
review (the review skill of the profile, or the review of the brief) on the correct diff range, with its coverage check. If it does not, send
the review back to the reviewer. Do not relay anything yet.

After each round, record it. A reviewer in a new session continues from this record:

- each new finding: `L finding --layer <layer> --round <n> --severity <s> --file <f> [--line <n>]
  --defect "<text>" [--expected-fix "<text>"]`. It prints the finding id, for example `l1-f1`. Use
  that id exactly in `L rule` and `L resolve`;
- your ruling on each finding: `L rule --layer <layer> --id <finding id> --ruling
  relay|closed|out_of_scope [--reason "<text>"]`. A closed or out-of-scope ruling needs a reason;
- the verdict and the reviewed range: `L event --layer <layer> --type review --round <n>
  --summary "<verdict>, <SHA range>"`, and `L layer --layer <layer> --set lastReviewed=<SHA>`.

Rule on each finding yourself (hard rule 7):

- Relay a blocker, and a should-fix finding that has a reachable failure path.
- Close a finding with a one-line reason (`L rule --ruling closed`) when it has low value: a
  theoretical race with no reachable path, or a change that only churns the code. Data loss is
  never low value.
- Relay nits only together with a blocker or a should-fix finding. A review that has only nits is
  an APPROVE. Do not start a round for nits. Rule each nit of such a review with
  `L rule --ruling closed --reason "nit; the review approves"`, so that no finding stays open.
- If you closed every remaining finding, the verdict counts as APPROVE (hard rule 3). Do not start
  a round with nothing to relay.

On an S layer, a blocker in round 1 is an escalation (see "Implementer tiers"). Send the findings
to the new M implementer, not to the S implementer.

On CHANGES REQUESTED, run `L layer --layer <layer> --set phase=fixing`, then use `SendMessage` to
the **same** implementer:

- every relayed finding, numbered, with severity, `file:line`, the defect and the expected fix;
- the reviewer's rulings on the open points;
- what is not in this PR. Record each out-of-scope item with `L followup --layer <layer> --title
  "<one line>" --body "<one paragraph>"`, and add `--data-loss` for a data-loss item;
- the rules again: new commits only, no amend, no force, no push, no PR, and the attribution rule;
- the report format: for each finding, the commit SHA, what changed, and the command results.

**In scope and out of scope.** The source of record is where a task starts, not where it ends.
A finding is **in scope** for the layer when one or more of these conditions is true:

1. **The layer causes it.** The defect does not occur on the base tip, and it occurs on the
   layer's head. A new path, a new state, a new prompt or a new file that the layer adds counts.
2. **The layer widens it.** The defect occurs on the base tip, but the layer adds a new trigger
   for it, or makes it more reachable.
3. **The defect is in the code that the layer changes.** The defect is in a function, a write
   path or a mechanism that the layer's diff changes, or it is the same defect class as the task
   (the same mechanism, also in another file).
4. **The layer's text names it.** A doc row, a code comment or a PR body of the layer names the
   defect as a gap, a limitation or "not covered yet".

An in-scope finding is relayed. Its severity rules apply as usual, and it is never a follow-up.
This is true also when its fix is larger than the task.

A finding is **out of scope** only when all of these conditions are true:

- it occurs on the base tip as it does on the layer's head;
- the layer does not change its code, and the defect is not the same mechanism as the task;
- the layer adds no trigger to it, and no text of the layer names it.

Rule an out-of-scope finding with `L rule --ruling out_of_scope`, and give in `--reason` the
condition that excludes it. Record it with `L followup`. It is not relayed, and you do not ask
about it.

When you are not sure which side a finding is on, it is in scope. Ask the reviewer to check the
finding on the base tip, if its report does not say this.

Ask the user only in one case: an out-of-scope change is necessary to meet the layer's acceptance
criteria. Then:

1. relay the in-scope findings of the round as normal, and let the implementer fix them;
2. ask the scope question in text, in the same progress line;
3. if the answer has not come when the in-scope fixes are verified, park the layer.

If the implementer refuses a finding and gives a reason, send that reason to the reviewer for a
ruling.

**E. Re-verify.** Use `SendMessage` to the **same** reviewer. Give the new SHAs, the diff
`git diff <last reviewed SHA>..HEAD`, and the implementer's claim for each finding. After a rebase
of a parked layer, the last reviewed SHA is on the old base. Take its rebased counterpart from the
range-diff output of step 4 of "Resume a parked layer", and diff from that SHA. The commits after
it, for example fixes or a `wip:` commit, are not reviewed yet. When the fix report comes, record
the new tip: `L layer --layer <layer> --set head=<SHA>`. When you send the fixes to the reviewer,
record the round: `L layer --layer <layer> --set phase=review --set round=<n>`. After the report,
record each finding's state
(`L resolve --layer <layer> --id <finding id> --state fixed|not_fixed [--sha]`),
new findings and the verdict as in step D, and the new `lastReviewed` (none for a report layer). Tell it: "Do not run
a review skill again. Verify each fix directly. Run only the checks for the changed code."
Ask for CONFIRMED FIXED or NOT FIXED on each finding, any new defect, and a verdict. If the
report shows a new run of a review skill or a new agent, reject it, and ask again for a direct
check of the fixes. Repeat D and E until the verdict is APPROVE.

**Round limit: 3.** Round 1 is the first review. Rounds 2 and 3 are re-verifications. If round 3
still has CHANGES REQUESTED, do not send its findings back for fixes. Continue to step F:

- each open finding goes into the PR body as a known limitation: `L resolve --state
  known_limitation`, and `L followup`;
- a commit that no reviewer saw is named in the PR body as not reviewed;
- a data-loss finding that is still open: ask the user in text and park the layer before step F
  (see "Questions and parked layers"). Do not mark it `known_limitation` before the answer: the
  answer decides it.

**F. Final checks.** Run `L layer --layer <layer> --set phase=final_checks`. Use `SendMessage` to
the implementer with the section "When you are told to run the final checks" from its brief. The implementer runs the final checks of the profile one time. Do not run them yourself, also when
they are short: the implementer owns the fix of a failure.
If a check fails, the implementer fixes it in a new commit. Send
that fix to the same reviewer for a check of that fix only. This check is not a review round.
Record the failure and the fix: `L event --layer <layer> --type final_checks --summary "FAIL:
<check>; fix <SHA>"`, and after the check, `L layer --layer <layer> --set head=<SHA> --set
lastReviewed=<SHA>`.
If the reviewer says NOT FIXED, or finds a new defect in the fix, allow one more fix and one more
check. After that, an open defect goes into the PR body as a known limitation, and into the
follow-ups (`L followup`). If it is data loss, ask the user in text and park the layer. Record the
result: `L event --layer <layer> --type final_checks --summary "<PASS or the failures>"`.

**G. Open the PR.** Run `L layer --layer <layer> --set phase=opening_pr`. Use `SendMessage` to the
implementer with the section "When you are told to open the PR" from its brief.
Add the base branch, the stack line (stack run only), and what the body must state for this
layer: the rulings, the known limitations, and "Not in this PR".

**H. Verify the PR yourself.** Do not trust an exit code of 0:

```bash
gh pr view <N> --json state,baseRefName,headRefOid,body \
  --jq '.state, .baseRefName, .headRefOid, (.body|test("Generated with|Co-Authored-By"))'
git ls-remote origin <branch>
git status -sb | head -1
```

The result must show `OPEN`, the correct base, a head equal to the remote branch, `false` for
attribution, and a clean tree. Ignore the attribution value when the profile permits attribution. Record it: `L layer --layer <layer> --set phase=pr_open --set
pr=<N> --set prUrl=<url> --set head=<SHA>`, then `L event --layer <layer> --type pr_verified
--summary "#<N>"`. Then do the after-PR step of your kind file: in a stack run, link the PR into
the GitHub stack and check the stack; in a tasks run, start the task's CI. Then tell the user how
many of the *n* PRs are open, for example "3 of 5 PRs are open".
If an answer to a parked layer came, resume that layer now ("Questions and parked layers").
Otherwise start the next layer that `L next` gives, at step A (a report layer: at step R-A of
`report-tasks.md`). When `L next` gives `null` and no
layer is parked, go to the finish of your kind file. Before each step, set the next
step: `L run --set nextStep="<step>"`.

## Shared procedures

Both run kinds use these procedures. Each kind file says where they apply and how to record the
result.

### Find the source of record

Find the source of record for each task:

- an issue: `gh issue view <N> --comments`;
- a phrase: `grep -rn` in the folders that the profile lists ("Sources of record"). Record the
  file, the item number and the lines. A plan marked Done is not evidence that the behaviour
  shipped.

### Ask the decisions at intake

Collect every decision that the sources give to the user. Ask them all now, before the first
layer, so that the run does not stop halfway. `AskUserQuestion` takes at most 4 questions per
call. After `L init`, record each answer with `L decision --question --answer`.

### Copy the plan documents

After `L init`, for each plan document that the user gave, or that a task's source of record is,
run `L main-plan --run <id> --file <absolute path>`. The copy keeps the plan as it was at the
start, also when the file is untracked or changes later. The source of record stays the file in
the checkout.

### Run CI on a PR and check it

The profile section "CI" gives how a PR run starts, the workflow, the jobs of the slow suite, and
the paths that skip the slow suite. The **slow suite** is the suite that the profile names as too
slow for each round, for example e2e. If the profile says that the project has no PR CI, skip
this procedure. Record `L event --type note --summary "no PR CI"`, and say so in the report.

1. **Does the slow suite run?** CI can skip the slow suite on a PR whose diff touches only the
   paths that the profile lists. Your kind file says what to do when the slow suite does not run.
2. **Start it**, as the profile says. When a label starts CI: `gh pr edit <N> --add-label <label>`.
   When CI starts on each push, the push already started it, so do nothing here.
3. **Find the run of the head SHA**, not an older run of the branch:
   `gh run list --workflow <workflow file> --event pull_request --commit <head SHA> --json databaseId,url`.
   Leave out `--workflow` when the profile names no workflow file.
   The run can take some seconds to appear. With no match the command prints `[]` and exits 0, so
   repeat it in a background loop until the JSON array is not empty, for at most 5 minutes. If no
   run appears, tell the user: CI did not start (with a label start, the label can still be on
   the PR from an earlier run; the profile says how to start a second run). A new head SHA has no earlier
   run, so the run found is the new one. Then run `gh run watch <id> --exit-status` in the
   background. Do not poll it.
4. **Decide the result.** First read the run's conclusion:
   `gh run view <id> --json status,conclusion`. A run that is not `completed` has no result yet.
   - A conclusion other than `success` (for example `failure` or `cancelled`) is `fail`, whatever
     the jobs of the slow suite show. A failure in an earlier job can skip them.
   - A `success` run is not proof that the slow suite ran. If the profile names the jobs of the
     slow suite, check them:
     `gh run view <id> --json jobs --jq '.jobs[] | select(.name | startswith("<job prefix>")) | [.name, .conclusion]'`.
     Every such job `success` is `pass`. Skipped jobs are `no_e2e`: this is the ledger's value for
     "the slow suite did not run". If the profile names no such jobs, `success` is `pass`.
5. **A flaky test.** If you think that a test is flaky, do not start a new run for the same head
   SHA: the lookup would find the old run. Set the result to `pending` (as your kind file records
   it), then run `gh run rerun <id> --failed`, then `gh run watch <id> --exit-status` on the same
   id. If it passes on that second attempt, record the test with `L followup`.

### Report the follow-ups and the checkout

Both final reports contain these items:

- what no agent could verify, for example a screen reader or a real Windows desktop;
- the follow-ups, one line each, data loss first, from `L show`. While this question is open, do
  not set the run to `finished`: a finished run ends the answer watcher. Set it to `paused`, and
  finish it after the answer. Ask which ones to file, and record
  the question: `L ask --question "Which follow-ups to file?" --option <id> ...`. Record the choice
  with `L answer` (an answer from the admin page is recorded already), and name both the filed and the declined ones. File only the ones the user
  chooses, with `gh issue create`, and with the attribution rule of hard rule 5. Record each one:
  `L followup-filed --id <follow-up id> --issue <N>`;
- the checkout state: the branch, clean or not, and how far behind `origin/<default>`. With no
  git repository, give no checkout state, list the follow-ups only, and do not ask which ones to
  file: no issue tracker is known. No question waits then, so the run can finish;
- the run id.

## Events

| Event | Action |
|---|---|
| The permission system refuses an agent's command | The agent stops and reports. Do not repeat the command in any form. Choose a safe alternative and continue (hard rule 6). Ask the user only when no safe alternative exists. |
| The implementer finds that the task is already done, or that its premise is false | The reviewer verifies it. If the scope changes, ask the user in text and park the layer. |
| A layer needs the user's answer | Ask in text, park the layer, and continue with the next layer that does not depend on it ("Questions and parked layers"). |
| The user answers an open question, in the session or on the admin page | Record a session answer with `L answer`. An answer from the admin page is in the ledger already. At the next stop point ("Questions and parked layers"), resume the parked layer ("Questions and parked layers"). |
| The reviewer finds a defect in `<default>` that is out of scope by the test in step D | Record it with `L followup`. If it is data loss, report it to the user now, and record that: `L event --layer <layer> --type note --summary "data loss reported: <follow-up id>"`. `L finding` takes `--expected-fix` only when the reviewer gives one. A defect in `<default>` that the layer widens, or whose code the layer changes, is in scope: relay it. |
| The implementer says a proposed fix would block a legitimate path | Send the reason to the reviewer. A known limitation goes into the PR body, and a follow-up issue needs the user's yes. |
