# task-manager

An orchestrator for tasks that subagents do, each task with a separate reviewer.

You give a list of tasks. The orchestrator session does not do the work and does not review it.
For each task it launches a **worker**, then a separate read-only **reviewer**. It relays the
findings between them for at most 3 rounds, rules on scope itself, and delivers the outcome only
after the reviewer approves. Every step goes into a **ledger** outside the repository, so a new
session can continue a run, and a local **dashboard** shows every run of every project.

The outcome depends on the task:

| Outcome | The task | It ends as |
|---|---|---|
| `pr` | A change to the repository: code, tests, configuration, docs in the repository | A reviewed pull request, in a stack or on the default branch |
| `report` | An investigation, the cause of a defect, a plan, a code execution, a search for information | A reviewed report file in the run folder |

One run can mix the two. A `pr` task can wait for a report task: "find the cause, then fix it".

## Install

```
/plugin marketplace add Vavly/skills
/plugin install task-manager@vavly-skills
```

Requirements: `node` 20 or later. A `pr` task also needs `git`, a GitHub remote, and the GitHub
CLI `gh`, signed in. A report task needs none of these.

By hand: copy `skills/task-manager` into the `.claude/skills/` folder of your repository. Run the
dashboard from a clone of this repository.

## Use

There is one skill, `task-manager`. It starts only when you invoke it
(`disable-model-invocation`), because a run launches many agents.

```
/task-manager #12 #15 "make the export toast shorter"
/task-manager find why the export is slow, then fix it
/task-manager compare the three sync libraries and recommend one
/task-manager resume
/task-manager changes <run-id> l2 "also cover the empty state"
/task-manager merged <run-id> l2
/task-manager setup
/task-manager admin
/task-manager admin stop
```

At the start of a run, the orchestrator gives each task its outcome and chooses the run kind:

- a **stack run**, when `pr` tasks use each other's code: each PR is on the PR below it. The
  orchestrator links the PRs as a native GitHub stack when the repository has stacks, restacks
  after a change, and merges only after your yes;
- a **tasks run** in all other cases: each `pr` task has its PR on the default branch, with CI,
  and the run stops at the open PRs. It never merges.

One checkout has one writer. The tasks run one at a time, no agent uses a git worktree, and one
checkout has one active run. A question about one task parks only that task.

## The profile

The skill holds no project rule. The commands, the checks, the CI start, the review skill, the PR
rules and the high-risk areas of a project come from one file in its repository:
`.claude/task-manager.md`. The sections are in
[profile-template.md](skills/task-manager/profile-template.md).

- Run `/task-manager setup` one time in each repository. It reads `AGENTS.md`, `CLAUDE.md`, the
  package scripts and the CI workflows, asks you what it cannot find, and writes the file.
- With no profile, a run still works. The orchestrator derives the rules at intake, asks you to
  confirm them, and keeps them in the run folder for that run only.

## Runs and the ledger

Each run has a folder in `~/.task-manager/runs/`. Set `TASK_MANAGER_RUNS` to use another folder.
The folder is outside every clone, so no commit can carry it, and any session can read it. It
holds the state of the run, the plans, the findings of each review, and the reports.

Only `skills/task-manager/scripts/task-manager-ledger.mjs` writes the run state. The orchestrator
calls it at every event. `core.md` lists its commands.

Agents write their plans and reports into the run folder. If your permission mode asks about
each write outside the project, add the folder to `permissions.additionalDirectories` in your
settings.

## Notifications

The ledger can tell you when a run needs you, so you do not have to watch the dashboard. Put the
settings in `config.json` in the runs folder (`~/.task-manager/runs/config.json`):

```json
{ "notify": { "desktop": true, "command": "my-notifier", "events": ["question", "finished"] } }
```

| Key | Meaning |
|---|---|
| `desktop` | `true` sends a desktop notification: `osascript` on macOS, `notify-send` on Linux. |
| `command` | A shell command that runs for each event, for example a script that posts to a chat. |
| `events` | Which events to send. The default is all three: `question` (a question opened), `paused` (the run waits for you) and `finished`. |

The command gets the event as one line of JSON on stdin: `type`, `run`, `title`, `layer` and
`text`, and for a `question` event also `questionId` and `sessionOnly`. A long text is cut to
4000 characters. It gets the same values in the variables
`TASK_MANAGER_EVENT`, `TASK_MANAGER_RUN`, `TASK_MANAGER_TITLE`, `TASK_MANAGER_LAYER`,
`TASK_MANAGER_QUESTION_ID`, `TASK_MANAGER_TEXT` and `TASK_MANAGER_SESSION_ONLY`; a value that the
event does not have is empty. No text of a run
goes into the command line.

With no file, nothing is sent. The file is per user and per machine, not per project, and
`/task-manager setup` can write it. A sender that fails never stops a run: test the settings with
`node skills/task-manager/scripts/task-manager-ledger.mjs notify-test`, which reports each sender.

## The dashboard

`/task-manager admin` starts it and opens the page in your default browser. Or, from a clone of
this repository:

```
node plugins/task-manager/admin/server.mjs --open [--port <n>] [--root <dir>]
```

The page is at http://127.0.0.1:4747/. Without `--open`, the server only prints the URL. If the
port is in use, `--open` opens the page of the server that runs already.

To stop the server: `/task-manager admin stop`, or `node plugins/task-manager/admin/server.mjs
--stop [--port <n>]`. It stops only a task-manager admin server, never another program on the
port.

- **Board**: all runs of all projects in four columns: to do, in progress, needs input, done.
- **Projects**: the stack runs, with a board, a timeline, the follow-ups, the PRs and the plans
  of each.
- **Tasks**: one row for each task of every tasks run, with its outcome (the PR or the report)
  and its CI result. A report opens in the page.

**Answer a question from the page.** A task that needs your input shows its question, its
options and an "Answer" button. You choose an option, write a comment, or do both: the comment
field is always there. The page records the answer in the ledger. The session has a background
`wait` command on the ledger, so it gets the answer and continues. If the session is closed, it
gets the answer at the next `/task-manager resume`. Some questions take an answer in the session only: a merge, an unstack, a dropped commit, a
force-push, and an outward action of a report task (a deploy, a write to a database, a comment).

The page never writes a run file. It asks for three changes, and each one runs the ledger script
in the project's checkout: "Mark as finished", an answer to a question, and the record of a PR
that GitHub says is merged. The
server binds to 127.0.0.1, answers only its own Host name, and accepts a write only with its own
Origin and the `X-Task-Manager-Admin` header.

## What is enforced, and what is not

The ledger script enforces the data rules: valid phases and states for each outcome, one active
run for each checkout, a closed finished run, a lock on each run, and a report file that exists
before a report task is `delivered`. Everything else is a prompt: the orchestrator and the agents
follow `core.md` and the briefs. The plugin has no hooks.

## Files

| File | Reader |
|---|---|
| `skills/task-manager/SKILL.md` | The orchestrator: the modes, the outcomes, the run kinds |
| `core.md` | The orchestrator: the shared rules, the ledger, the loop of a `pr` task |
| `stack.md`, `independent.md` | The orchestrator: the intake and the finish of each run kind |
| `report-tasks.md` | The orchestrator: the loop of a report task |
| `implementer-brief.md`, `reviewer-brief.md` | The agents of a `pr` task |
| `report-brief.md` | The agents of a report task |
| `restack.md` | The restacker and the stack verifier |
| `scripts/lib/task-manager-notify.mjs` | The senders of the notifications |
| `setup.md`, `admin.md`, `profile-template.md` | The two side modes, and the profile |

## Test

```bash
cd plugins/task-manager && ./test.sh
```

It runs the ledger tests and the dashboard tests with `node --test`, and it checks the links and
the profile sections of the skill files. To look at every state of the dashboard:

```bash
node admin/test/fixture.mjs /tmp/task-manager-fixture
node admin/server.mjs --root /tmp/task-manager-fixture --port 4748
```
