---
name: task-manager
description: Use only when the user gives one or more tasks and asks for subagents to do them under an orchestrator, each task with a separate reviewer — code changes end as reviewed pull requests (stacked, or each on the default branch), and investigations, plans, debug sessions, code executions and information searches end as reviewed reports. Also resumes a run, takes more changes on a task, cleans up after a merge, writes the project profile (setup) and starts the local dashboard of all runs (admin).
disable-model-invocation: true
argument-hint: <tasks> | resume [<run-id>] | changes <run-id> <task> <what> | merged <run-id> <task> | setup [update] | admin [stop] [--port <n>] [--root <dir>]
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
| `resume [<run-id>]` | Continue a run in a new session | [core.md](core.md) ("Resume"), then the kind file of the run |
| `changes <run-id> <task> <what>` | More changes on a task that has its outcome | [core.md](core.md). A `pr` task: [independent.md](independent.md), "More changes on an open PR". A report task: [report-tasks.md](report-tasks.md), "More changes on a delivered report". |
| `merged <run-id> <task>` | Cleanup after the user merged a PR | [core.md](core.md), then [independent.md](independent.md), "Cleanup after a merge" |
| `setup [update]` | Write the profile of this repository | [setup.md](setup.md) only |
| `admin [stop] [--port <n>] [--root <dir>]` | Start the dashboard of all runs and open it in the browser, or stop it | [admin.md](admin.md) only |

## Outcomes

The outcome depends on the task. Give each task one of two outcomes.

| Outcome | The task | It ends as | Its loop |
|---|---|---|---|
| `pr` | Changes files of the repository: code, tests, configuration, or a document that must be in the repository | A reviewed pull request | Phase 1 of `core.md` |
| `report` | Gives an answer or knowledge, and changes nothing in the repository: an investigation, the cause of a defect, a plan or a design proposal, a code execution or a measurement with its result, a search for information | A reviewed report file in the run folder | [report-tasks.md](report-tasks.md) |

- "Find the cause of X" is a report task. "Fix X" is a `pr` task.
- "Find and fix X" is one `pr` task: its plan holds the diagnosis. If the user wants the cause
  before the fix, make two tasks: a report task, and a `pr` task that depends on it.
- A plan that the user wants as a file of the repository is a `pr` task.
- When the request does not show the outcome of a task, ask the user with the intake decisions.

## Start a run

1. Read `core.md` in full.
2. Divide the request into tasks, and give each task its outcome.
3. Choose the run kind:
   - a **stack run**, when two or more `pr` tasks use each other's code, or when the user asks
     for a stack. Its kind file is [stack.md](stack.md);
   - a **tasks run** in all other cases. Its kind file is [independent.md](independent.md). A run
     that has only report tasks is a tasks run.
4. Read the kind file in full. If the run has a report task, read `report-tasks.md` in full.
5. Tell the user, in one line for each task, its outcome, and the run kind. Then do Phase 0 of
   the kind file.

A `pr` task needs a git repository with a GitHub remote and the `gh` CLI. A report task does not.
If the working directory is not such a repository, the run can have report tasks only: tell the
user this before Phase 0, and in Phase 0 skip the git steps and the GitHub steps.
