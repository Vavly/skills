# Security Policy

## Reporting a vulnerability

Report privately through GitHub:
[**Report a vulnerability**](https://github.com/Vavly/skills/security/advisories/new).

Please do not open a public issue for a security problem. There is no email
address to write to — the private advisory form is the channel.

Expect an acknowledgement within a week. If a report is valid, you will get credit
in the advisory unless you would rather not be named.

## Why this repo warrants a policy

The plugins here install **hooks**, and hooks are commands Claude Code executes
inside your repository — on every write, on every turn boundary. That is the point
of the design, and it is also the risk: a malicious or careless change to a hook
runs with whatever access the person who installed it has.

So the following count as vulnerabilities here, not just bugs:

- A hook that executes attacker-influenced input — a file path, a commit message, a
  tool payload — without quoting or validating it.
- A gate that can be made to **fail open**: any input that turns a deny into an
  allow, or makes an enforcement hook exit 0 with no decision.
- A path that writes outside the target repo's `.claude/` state directory, or reads
  outside the repo and reports what it found.
- Anything in `.claude-plugin/marketplace.json` that would cause `/plugin install`
  to fetch code from somewhere other than this repository.

Findings that a gate can be *talked around* by the agent it governs are interesting
but are usually not vulnerabilities — that boundary is documented in
[plugins/spec-gate/README.md](plugins/spec-gate/README.md) under what is actually
enforced. Report them as issues; they are worth having.

## Supported versions

The default branch is what is supported. There are no backports.
