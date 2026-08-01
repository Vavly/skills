# skills

Claude Code plugins from [Vavly](https://github.com/Vavly). One marketplace, added
once — everything published here shows up without a second repo to track.

```
/plugin marketplace add Vavly/skills
```

Then install what you want:

```
/plugin install spec-gate@vavly-skills
```

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
