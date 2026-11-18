---
name: task-manager
description: Use only when the user gives one or more tasks and asks for subagents to do them under an orchestrator, each task with a separate reviewer — code changes end as reviewed pull requests (stacked, or each on the default branch), and investigations, plans, debug sessions, code executions and information searches end as reviewed reports. Also resumes a run, takes more changes on a task, cleans up after a merge, writes the project profile (setup) and starts the local dashboard of all runs (admin).
disable-model-invocation: true
argument-hint: <tasks> | preview <tasks> | resume [<run-id>] | changes <run-id> <task> <what> | merged <run-id> <task> | setup [update] | admin [stop] [--port <n>] [--root <dir>]
---

# Task manager

You are the **orchestrator** of a **run**: a list of tasks that subagents do one at a time. For
each task you launch a worker, then a separate reviewer. You relay the findings between them for
at most 3 rounds, and you deliver the outcome only after the reviewer approves. You do not do the
work, and you do not review it. A **ledger** in a run folder outside the repository records each
step, so that a new session can continue the run.

**The skill folder.** `<skill>` in these files is the absolute path of the folder that holds
this file: `${CLAUDE_SKILL_DIR}`. If that text shows no path, use the base directory that the
harness gave when this skill loaded. Every file that this file names is in `<skill>`.

## Modes

The arguments select the mode. Read only the files of your mode, each one in full.

| Arguments | Mode | Read |
|---|---|---|
| `<tasks>` | Start a run | [core.md](core.md), then "Start a run" below |
| `preview <tasks>` | Show what a run would do, and start nothing | [core.md](core.md), then "Preview a run" below |
| `resume [<run-id>]` | Continue a run in a new session | [core.md](core.md) ("Resume"), then the kind file of the run, and [report-tasks.md](report-tasks.md) if the run has a report layer |
| `changes <run-id> <task> <what>` | More changes on a task that has its outcome | [core.md](core.md). Then, by the task: a report task: [report-tasks.md](report-tasks.md), "More changes on a delivered report". A `pr` task of a tasks run: [independent.md](independent.md), "More changes on an open PR". A `pr` layer of a stack run: [stack.md](stack.md), "More changes on a layer of the stack". |
| `merged <run-id> <task>` | The user merged a PR | [core.md](core.md). A tasks run: [independent.md](independent.md), "Cleanup after a merge". A stack run: [stack.md](stack.md), "The user merged a PR of the stack". |
| `setup [update]` | Write the profile of this repository | [setup.md](setup.md) only |
| `admin [stop] [--port <n>] [--root <dir>]` | Start the dashboard of all runs and open it in the browser, or stop it | [admin.md](admin.md) only |

## Outcomes

The outcome depends on the task. Give each task one of four outcomes.

| Outcome | The task | It ends as | Its loop |
|---|---|---|---|
| `pr` | Changes files of the repository: code, tests, configuration, or a document that must be in the repository | A reviewed pull request | Phase 1 of `core.md` |
| `report` | Gives an answer or knowledge, and changes nothing in the repository: an investigation, the cause of a defect, a plan or a design proposal, a code execution or a measurement with its result, a search for information | A reviewed report file in the run folder | [report-tasks.md](report-tasks.md) |
| `issue` | Finds work for later and records it: a triage, an audit, a list of defects or of follow-ups | GitHub issues, filed from a reviewed draft after the user's yes | [report-tasks.md](report-tasks.md), with "Issue tasks and comment tasks" |
| `comment` | Gives a review of a pull request that exists | One review comment on that pull request, posted from a reviewed draft after the user's yes | [report-tasks.md](report-tasks.md), with "Issue tasks and comment tasks" |

- "Find the cause of X" is a report task. "Fix X" is a `pr` task.
- "Find and fix X" is one `pr` task: its plan holds the diagnosis. If the user wants the cause
  before the fix, make two tasks: a report task, and a `pr` task that depends on it.
- A plan that the user wants as a file of the repository is a `pr` task.
- "Review PR 41" is a `comment` task when the user wants the review on the PR, and a report task
  when the user wants to read it first and decide. "Find the defects in X and file them" is an
  `issue` task. In these files, "a report layer" and "a report task" also mean an `issue` layer
  and a `comment` layer: each rule for a report applies to them, unless the text says that they
  differ. So a run with an `issue` task or a `comment` task reads `report-tasks.md` too.
- When the request does not show the outcome of a task, ask the user with the intake decisions.

## Start a run

1. Read `core.md` in full.
2. Divide the request into tasks, and give each task its outcome.
3. Choose the run kind:
   - a **stack run**, when two or more `pr` tasks use each other's code, when a report task needs
     the code of a `pr` task ("implement X, then measure it"), or when the user asks for a stack. Its kind file is [stack.md](stack.md);
   - a **tasks run** in all other cases. Its kind file is [independent.md](independent.md). A run
     that has only report tasks is a tasks run.
4. Read the kind file in full. If the run has a report task, read `report-tasks.md` in full.
5. Tell the user, in one line for each task, its outcome, and the run kind. Then do Phase 0 of
   the kind file.

A `pr` task, an `issue` task and a `comment` task need a git repository with a GitHub remote and
the `gh` CLI. A task with the outcome `report` does not.
If the working directory is not such a repository, the run can have report tasks only: tell the
user this before Phase 0, and in Phase 0 skip the git steps and the GitHub steps.
`report-tasks.md` ("With no git repository") gives the other steps to skip.


## Preview a run

`/task-manager preview <tasks>` shows what a run would do, and it starts nothing. Use it to see
the order, the tiers and the questions before the work starts. The word `preview` selects this
mode only as the first word of the arguments. A task list that starts with another word, also
with "plan", starts a run.

In this mode:

- Make no run, launch no agent, ask the user no question, and change no file of the working
  tree. Use only ledger commands that read (`L list`, `L show`), and `L init --dry-run`, which
  writes nothing. Do not give `--dry-run` to another command: the ledger refuses it.
- Do steps 1 to 4 of "Start a run", with its paragraph about a folder that is not a git
  repository. Then do Phase 0 of the kind file, with these changes:
  - `git fetch origin` is permitted: it changes no file of the working tree, and the state
    against `origin` needs it.
  - A tree that is not clean, and an active run for this checkout, do not stop you. Record each
    one as a blocker.
  - With no profile, derive the rules as "The profile" in `core.md` says, but keep them in your
    session scratchpad: write no `profile.md`. The yes to the derived profile is a question that
    the run would ask, not a blocker.
  - A stack run: do the check for native GitHub stacks, which only reads. Its result is a
    decision that the run would record.
  - Find the source of each task, do the shared-code check, and give each task its tier.
  - Do not ask the decisions. List each one as a question that the run would ask, with its
    options and your recommendation.
  - In place of `L init`, write `layers.json` in your session scratchpad, and run
    `L init --dry-run [--kind tasks] --title "<short title>" --checkout <checkout> --request-file
    <request.txt> --layers-file <layers.json>`. An error is a defect of the plan: correct the
    plan, and run it again.
  - Stop after the dry run. Do nothing of the steps that follow `L init` in Phase 0: no
    `L run --set`, no `L decision`, no copy of a plan document. The `id` in the output is the id
    that a run would get: no run exists.
- Give the user the preview:
  - the run kind, and the reason for it;
  - a table: task, outcome, tier with its reason, source, what it waits for;
  - the task that starts first: the first task in the order that waits for no other task;
  - the questions that the run would ask. For a stack run, a paused run of this checkout
    (`pausedRuns` in the output) makes the run ask "resume it, or start a new run";
  - the blockers: a tree that is not clean, an active run (`activeRun`), a missing GitHub remote
    for a `pr` task, an `issue` task or a `comment` task;
  - the agents: one worker and one reviewer for each task, and for a stack run a restacker when a
    lower layer changes;
  - the token estimate, from `estimate` in the output. Say what it is: the mean of the complete
    tasks of the earlier runs on this machine, for each tier and outcome, from all projects, for
    the workers and the reviewers only. A restacker and the orchestrator are not in it. Give no
    total when `estimate.tokens` is `null`: say then which tiers have no earlier record.
- End with the command that starts the run: `/task-manager <the same tasks>`. A real start does
  the intake again, so the preview is not a promise: the code can change in between.
