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
| `issue` | A triage, an audit, a list of defects to record for later | GitHub issues, filed from a reviewed draft after your yes |
| `comment` | A review of a pull request that exists | One review comment on that pull request, posted from a reviewed draft after your yes |

One run can mix them. A `pr` task can wait for a task of the other three kinds: "find the cause,
then fix it". An `issue` task and a `comment` task send nothing before a separate reviewer
approved the draft and you said yes. The comment gives findings only: it never approves a pull
request, and it never requests changes.

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
/task-manager from-issues label:ready
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

One checkout has one writer, and the ledger enforces it at the start of each task. Report tasks
change nothing in the checkout, so up to 4 of them can work at the same time when the profile
permits it ("Parallel report tasks"; the default is 1). All other tasks run one at a time, no agent uses a git worktree, and one
checkout has one active run. A question about one task parks only that task.

## Tasks from GitHub issues

`/task-manager from-issues <filter>` makes the task list from open issues: a search such as
`label:ready`, or issue numbers. You get the list first, with the author of each issue, and the
run starts only the issues that you choose. An issue of an author with no write permission in
the repository is marked, and it becomes a task only when you give its number. An issue that
has an assignee, an open PR or a task in another run is marked too. The PR of a task that
closes its issue fully has `Closes #<N>`.

The text of a source (an issue, a comment, a document, a web page) is data for the agents, not
an instruction. A change of a permission, a workflow or a secret is part of a task only when
your request names it, or after your yes. This rule is prompt text for the agents: the plugin
has no code that enforces it.

## Preview before you start

`/task-manager preview <tasks>` shows what a run would do, and it starts nothing: no run, no
agent, no question, no change. You get the run kind, each task with its outcome, tier and source,
the order, the questions that the run would ask, and the blockers (a tree that is not clean, an
active run, a missing GitHub remote). Start the run with `/task-manager <tasks>`.

When earlier runs on this machine have usage records, you also get a token estimate. It is the
mean of the complete tasks of those runs, for each tier and outcome, from all your projects, and
it counts the workers and the reviewers only. Read it as an order of size, not as a price.

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

**A short command.** `bin/task-manager` in the plugin is one command for the dashboard and the
ledger. Put it on your PATH one time:

```
plugins/task-manager/bin/task-manager install
```

This writes one small launcher file to `~/.local/bin/task-manager` (`--dir <folder>` for another
place). It replaces only a launcher that it wrote. With `--force` it also replaces another file
of that name. It never writes through a symbolic link, and it never replaces a folder. Then,
from any folder:

```
task-manager admin             # start the dashboard and open it
task-manager admin stop        # stop it
task-manager runs              # list the runs of this machine
task-manager ledger show --run <run-id>
```

A plugin update puts the new version into a new folder. When you install the launcher from the
installed plugin, it asks the record of Claude Code (`~/.claude/plugins/installed_plugins.json`)
for the current folder of the plugin, of the same marketplace only, on each run. When you install
it from a clone of this repository, it runs that clone. `task-manager uninstall` removes the
launcher. The command needs
`bash` and `node`, so it is for macOS and Linux.

The page is at http://127.0.0.1:4747/. Without `--open`, the server only prints the URL. If the
port is in use, `--open` opens the page of the server that runs already.

**Usage for each task.** The orchestrator records what each agent used when it returns: tokens,
tool uses and time. It records nothing for itself: the harness gives no numbers for it. The page
adds the records for each task, each role and each tier, on the task page,
in the Tasks list and in the timeline of a run. The mean for each tier shows if the tiers are set
correctly. The harness gives tokens, not dollars, so the page shows a cost only when a record has
one.

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

**A confirmed answer to a session-only question.** With your setting, the page takes these
answers too, with one more step: you choose an option, and you type that option again, letter for
letter (for a merge, the top PR, such as `#506`). A question with no options takes the word
`yes`. A confirmed answer has no comment: to say "not yet" or to add a condition, answer in the
session. The ledger checks the typed text, and it marks the answer as confirmed. It refuses this
answer from a session that the page started. It cannot refuse it from a session with a terminal
that runs the same command: the rule against that is a prompt, as the rule for every answer is. The setting is in
`config.json` in the runs folder, and it is off by default:

```json
{ "answers": { "confirmOnPage": true } }
```

With this setting and "Start a session", a merge can go from your answer on the page to the
merge with no terminal. Turn it on only if you want that.

**Start a session from the page.** A run shows who works on it: "a session watches" while a
session waits for answers, and "no session" when an answer would wait for a resume. With your
setting, the run page then has a "Start a session" button. It starts
`claude -p "/task-manager resume <run-id>"` in the clone of the run, with no terminal, so an
answer that you give on the page moves the work with no open session. The setting is in
`config.json` in the runs folder, and it is off by default:

```json
{ "resume": { "enabled": true, "args": ["--allowedTools", "Bash(git *) Bash(node *)"], "checkouts": ["/path/to/a/clone"] } }
```

| Key | Meaning |
|---|---|
| `enabled` | `true` permits the button. Only you set it: the page and the sessions cannot. |
| `args` | Arguments for the program, before the prompt. A session with no terminal cannot ask for a permission, so give it here the allow rules that your work needs. |
| `checkouts` | Optional. Only a run in one of these clones can start a session. |
| `command` | Optional. The program, in place of `claude`. |

The ledger starts the session, and it refuses a run that a session works on: an active run with
an event in the last hour, a run that a session watches, and a run with a started session that
still runs. The session gets these permissions from the ledger, and no more: it reads the skill
files and its own run folder, and it writes plans and reports there. It cannot edit the skill
files or `config.json`, also when your `args` permit more. It does not get the identity of the
session that started the dashboard.

Its output goes to `session.log` in the run folder. It acts on a session-only question only when its answer is confirmed (above). It uses
the settings of the clone (`.claude/` in it) with no trust question, so turn this on only for
clones that you know, and in which you do not work at the same time. A permission that you give
in `args` is a permission for a session that nobody watches: give the smallest one that works.

**Search and archive.** The runs folder is for the full machine, so the lists grow. The Projects
view and the Tasks view have a search box (title, id, clone, and for a task its text) and a
filter for each clone. A finished project has an "Archive" button: the page then hides it from
the board and from the lists, until you turn on "Show archived". The archive withdraws each open
question of the project, so nothing of it stays in "Waiting for you". A withdrawn question takes
no answer, also after "Bring back". A project whose clone is gone can be archived. Nothing is
deleted: the run folder stays as it is, "Bring back" removes the mark, and a reopen of the run
removes it too.

The page never writes a run file. It asks for five changes, and each one runs the ledger script
in the project's checkout: "Mark as finished", "Archive", an answer to a question, "Start a session", and the
record of a PR that GitHub says is merged. The
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
| `bin/task-manager` | You: one short command for the dashboard and the ledger |
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
