# skills

[![test](https://github.com/Vavly/skills/actions/workflows/test.yml/badge.svg)](https://github.com/Vavly/skills/actions/workflows/test.yml)

Claude Code plugins from [Vavly](https://github.com/Vavly). One marketplace, added
once — everything published here shows up without a second repo to track.

Both steps are required, in this order:

```
/plugin marketplace add Vavly/skills
/plugin install spec-gate@vavly-skills
```

The first line registers the marketplace and is needed once, ever. The second
installs a plugin from it, and you run it again for each plugin you want.

> **`Marketplace "vavly-skills" not found`** means the first line has not run in
> this installation. The repo is `Vavly/skills` and the marketplace it declares is
> named `vavly-skills` — you add it by repo, then install from it by name, and the
> error mentions only the name. Run the first line and try again.

Outside an interactive session, the same two steps are
`claude plugin marketplace add Vavly/skills` and
`claude plugin install spec-gate@vavly-skills`.

**Using Cursor?** Plugins are a Claude Code mechanism — Cursor cannot read them,
so the commands above install nothing it can see. spec-gate ships a Cursor
adapter, but it is installed by hand; see [Running under
Cursor](plugins/spec-gate/README.md#running-under-cursor). Do not combine the two:
Cursor's hooks resolve the scripts at a repo-relative path that a plugin install
does not create, and they are configured to fail closed, so the result is every
tool call denied rather than a gate that quietly does nothing.

## What's here

| Plugin | What it does |
|---|---|
| [**spec-gate**](plugins/spec-gate) | Moves oversight of AI-written code from *approving each tool call* to *reviewing each outcome*. A `Stop` hook refuses to end a turn on a diff that hasn't been through adversarial review; a `PreToolUse` hook blocks production code until a spec exists and you have approved it. Ships two reviewer subagents, three skills, and a Cursor adapter. |

### spec-gate

The design premise is worth stating up front, because it decides what belongs in
this repo at all: **prompts raise the average, hooks raise the minimum.** Anything
that must always happen is a hook. Anything needing judgment is a prompt. A gate
that only asks nicely is not a gate.

It works standalone too — `/adversarial-review` will judge any diff, with or
without the workflow around it. Full documentation, including exactly what is
enforced and what is merely encouraged, is in
[plugins/spec-gate/README.md](plugins/spec-gate/README.md).

Requires `git`, `bash` (not `sh`), and either `jq` or `python3`.

## Installing without the marketplace

Every plugin here also installs by hand — copy its `hooks/`, `agents/` and
`skills/` into your repo's `.claude/` and merge its `settings.json`. Per-plugin
instructions are in each plugin's README. The manual path is the one the test
suites exercise, so it is not a second-class route.

## Contributing

New skills are welcome, as are fixes to the ones here. See
[CONTRIBUTING.md](CONTRIBUTING.md) — it covers how to add a plugin to the
marketplace, how the test suites work, and the one rule that matters most: every
fix carries a regression case.

Questions and ideas go to
[Discussions](https://github.com/Vavly/skills/discussions); defects go to
[Issues](https://github.com/Vavly/skills/issues). Security reports have their own
private channel — see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE).
