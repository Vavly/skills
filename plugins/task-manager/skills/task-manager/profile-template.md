# Task-manager profile

<!--
This file gives the rules of one project to the `task-manager` skill. Its place is
`.claude/task-manager.md` in the repository. The orchestrator, each implementer, each reviewer and
the restacker read it in full. Keep every heading. Write "none" in a section that does not apply.
Write only a command that works in this repository. Delete these comments when the file is complete.
-->

## Project

- Repository: `<owner>/<repo>`
- Default branch: `main`
- Read first: <the files that every agent reads before it works, for example `AGENTS.md`, `CLAUDE.md`, and the rule files that match the changed paths>

## Commands

<!-- What an agent must know before it runs any command of this project. -->

- Package manager: <for example "pnpm only, never npm">
- Environment: <variables to export before a command, or "none">
- Sandbox: <commands that must run outside the agent sandbox, or "none">
- Never run: <commands that agents must not run, or "none">

## Checks for the changed code

<!-- Fast checks. The implementer runs them before each report. The reviewer runs them too. -->

- Type check: <command, or "none">
- Lint the changed files: <command that takes a file list, or "none">
- Targeted tests: <how to run only the tests of the changed code>

## Final checks

<!-- The full battery. The implementer runs it one time, after the review approves. -->

- Full checks: <the commands of the CI check job, in order>
- Slow suite: <the suite that is too slow for each round, for example e2e: the command to run only the parts that the change touches, or "none">
- Visible result: <how to run and look at the real app when a change has a visible result, or "none">

## Review

- Review skill: <the name of a skill that reviews a diff range in the reviewer's own context and starts no agent, or "none">
- Project rules to check: <for example i18n, the design system, the layer boundaries, or "none">

## Skills

<!-- Skills that agents load with the Skill tool. -->

- Every implementer: <skill names, or "none">
- By area: <for example "`frontend-design` for changes under `src/ui/`", or "none">
- Tests: <a skill to load before any test command, or "none">

## PR

- Title: <the title rule, or the skill that gives it, for example "Conventional Commits; CI checks it">
- Attribution: <"none": no `Co-Authored-By` and no "Generated with" line in commits, PR bodies and issues; or "default">
- Merge method: <squash | merge | rebase>
- PR URL: `https://github.com/<owner>/<repo>/pull/<N>`
- Docs to keep current: <checklists or design docs that a change must update, and the placeholder for a PR that is not open yet, or "none">

## CI

- PR CI starts: <"on each push" | "on the label `<label>`" | "none: the project has no PR CI">
- A second run on the same PR: <how to start CI again after new commits, for example "CI removes the label, so add it again", or "each push starts it">
- Workflow file: <for example `main.yml`, or "none">
- Jobs of the slow suite: <the prefix of their job names, for example `e2e`, or "none">
- Paths that skip the slow suite: <globs, or "none">

## Tiers

<!-- Signals that make a task tier L (complex) in this project. core.md has the general list. -->

- <for example "a schema migration", "the sync engine", "the auth boundary">

## Sources of record

- Folders to search for a task that the user names by a phrase: <for example `docs/plans/`, `docs/design/`>

## User data

<!-- Data that no agent may delete or put at risk without the user's yes. -->

- <for example "the user's project database", or "none besides uncommitted work in the checkout">

## Restack

<!-- Stack runs only. -->

- Conflict rules: <rules for files that many layers edit, for example a counted value that a test must confirm, or "none">
- Checks after a rebase: <commands for each layer, and for the top of the stack>

## Scratch

- Scratch folder: <a gitignored folder for agent outputs, for example `tmp/`, or "none">
