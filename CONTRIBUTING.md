# Contributing

This repo is a Claude Code plugin marketplace. Everything in `plugins/` is
installable, which means a mistake here runs shell inside someone else's
repository. That shapes most of the rules below.

## Adding a skill

Four steps, and the last one is the one people forget:

1. Create `plugins/<name>/` following the standard plugin layout — `commands/`,
   `agents/`, `skills/`, `hooks/`, `scripts/` at the plugin root, only the ones you
   need.
2. Add `plugins/<name>/.claude-plugin/plugin.json`. Required field is `name`
   (kebab-case, unique); include `description`, `version`, `author`, `license`.
3. Add a row to the root [README.md](README.md) table.
4. **Register it in [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json)**
   with `"source": "./plugins/<name>"`. A plugin directory the marketplace does not
   list is a plugin nobody can install — it will sit in the repo looking finished
   and be unreachable from `/plugin install`.

Verify before opening the PR:

```
/plugin marketplace add /path/to/your/clone
/plugin install <name>@vavly-skills
```

Then confirm the thing actually does something — `/hooks` for hook registration,
`/help` for commands. A plugin that installs cleanly and no-ops is the failure
mode worth testing for.

## Tests

```bash
cd plugins/spec-gate && ./test.sh
```

Needs `git`, `bash`, `python3`, and either `jq` or `python3` for the hooks. CI runs
every `plugins/*/test.sh` it finds, on Linux and macOS, so a new plugin gets covered
by adding the file — no workflow edit.

**Every fix carries a regression case.** This is already how `spec-gate` is
maintained: cases tagged `[#n]` pin specific bugs found in review, and they exist so
those bugs cannot quietly come back. A fix without a test is a fix with a schedule
for returning.

Two things worth copying from the existing suite, because both were learned the
hard way:

- **Assert the count before the comparison.** Two empty sets compare equal, and a
  diff of nothing is a green test that proves nothing.
- **Test the negative cases.** Roughly half of `spec-gate`'s approval tests drive a
  hook with input it should *refuse*. A suite that only walks the happy path stays
  green on a version that has become a rubber stamp.

## Both install paths stay in sync

Plugins that ship hooks carry the wiring twice: `settings.json` for the manual
`cp -R` install, and `hooks/hooks.json` for the plugin install. They differ only in
how paths resolve — `$CLAUDE_PROJECT_DIR/.claude/hooks/` versus
`${CLAUDE_PLUGIN_ROOT}/hooks/`.

Touch one, touch the other. `spec-gate`'s suite asserts they register the same
events with the same matchers, scripts and timeouts, so drift fails CI rather than
shipping a plugin that enforces less than its README claims.

## Shell conventions

- `#!/usr/bin/env bash`, and bash — not sh. Arrays, `<<<` and process substitution
  are all in use.
- **No bash 4+ constructs.** No `declare -A`, no `mapfile`/`readarray`, no
  `${var,,}`. macOS ships bash 3.2 and that is what many contributors run; CI
  covers both 3.2 and 5.x so this fails fast rather than on someone's laptop.
- **Commit scripts with the executable bit set.** `cp -R` preserves it and the
  install does no `chmod`, so a script committed without it installs unrunnable.
  The suites assert `-x` for this reason.
- Hooks must fail closed. If a hook cannot reach a decision, it denies. Malformed
  output on exit 0 reads as "no decision" and the call proceeds — a deny that
  cannot be parsed is a deny that did not happen.

## Commits and PRs

Conventional Commits, scoped by plugin:

```
feat(spec-gate): verify RED mechanically before unlocking Execute
fix(spec-gate): stop the review gate firing on its own bookkeeping
docs(spec-gate): write down the multi-slice design before building it
chore: add CI
```

Subject describes the intent rather than the diff, lowercase, no trailing period.

PRs need a passing CI run. Outside contributions need a review; see the PR template
for what to include.

## Reporting security issues

Do not open an issue. See [SECURITY.md](SECURITY.md).
