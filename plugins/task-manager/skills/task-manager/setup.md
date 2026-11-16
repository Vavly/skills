# Setup: write the profile of this repository

`SKILL.md` sends you to this file for `/task-manager setup`. The task manager has no project rule
of its own. It reads the rules of a project from its **profile**: the file
`.claude/task-manager.md` in the repository. This mode writes that file. The template is
[profile-template.md](profile-template.md), next to this file.

## Steps

1. Read the template in full. If `.claude/task-manager.md` exists, read it too: you update it, and
   you keep each line that the user wrote.
2. Read the sources of the project rules, where they exist:
   - `AGENTS.md`, `CLAUDE.md`, `.claude/rules/`, the README and the contribution guide;
   - the package scripts (`package.json`, `Makefile`, `justfile`, `pyproject.toml`, `Cargo.toml`
     or the equivalent);
   - the CI workflows (`.github/workflows/`): what starts a run on a PR, the job names, and the
     path filters;
   - the skills of the project (`.claude/skills/`): a review skill, a test skill, a PR skill;
   - `gh repo view --json nameWithOwner,defaultBranchRef,squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed`.
3. Write each section of the template. Obey these rules:
   - Write only a command that a file of the repository gives. Do not guess a command.
   - Write "none" in a section that does not apply.
   - A review skill is correct for the profile only if it runs in the reviewer's own context and
     starts no agent. If the project has none, write "none": the reviewer then does the review of
     its brief.
   - For "Attribution", use the instruction of the user or of the project. If neither gives one,
     ask.
4. Ask the user about each value that the sources do not give, and that changes what an agent
   does. Ask all the questions in one call. Do not ask about a value that you found.
5. Write the file to `.claude/task-manager.md`. Remove the template comments.
6. Tell the user: the path, a summary of each section in one line, and each section that says
   "none". Say that the file is part of the repository, so a commit shares it with every clone.
   Do not commit it yourself.
