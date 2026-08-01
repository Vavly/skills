# Finding and running this repo's validations

Read this at the Phase 4 exit, when you need the repo's own checks rather than
your own tests. SKILL.md has the rule and the report template; this is how to find
the commands and what each line of the report is for.

## Work out what the checks are — do not assume, and do not invent a list

Every repo has already decided what "valid" means and encoded it somewhere. In
rough order of authority:

1. **An aggregate script that exists for exactly this purpose** — `make check`,
   `npm run verify`, `just ci`, `scripts/check.sh`. If one exists it is the
   answer, and it is the answer because someone maintained it.
2. **What CI runs.** The workflow file is the definition of "this change is
   allowed to merge", so a check that is in CI and not in your list is a check you
   will fail in ten minutes.
3. **What the pre-commit hook runs** — `.pre-commit-config.yaml`, a `husky/`
   directory, a `lefthook.yml`.
4. **What the contributor docs tell a human to run before pushing** —
   `CONTRIBUTING.md`, a `## Development` section in the README.

Your own approximation of a repo's checks is how a diff passes review and fails CI
ten minutes later. The failure mode is not laziness; it is that a plausible list
(lint, types, tests) looks exactly like the real one right up until the repo turns
out to also run a schema check, a bundle-size budget, or a codegen freshness test.

**Say which commands you settled on and where you got them.** That one sentence is
what makes a wrong guess visible instead of silent. If the repo genuinely defines
nothing, say that too, then assemble the minimum for the language and flag that you
chose it — a stated choice can be corrected, an unstated one cannot.

## Every failure is yours to account for

Including failures in files you did not touch. A type error elsewhere that your
change surfaced is your change's problem: it was latent, your change made it
reachable, and it is now in the diff's blast radius whatever the blame output says.

If a failure genuinely predates your work, **prove it rather than asserting it**:

```bash
git stash
<the failing check>     # fails here too → it predates you
git stash pop
<the failing check>     # fails here as well → same failure, not yours
```

Show both results. "That was already broken" is the single most common claim in
this workflow that turns out to be false, and it costs a reviewer a round to
discover.

## What each report line is for

```
VALIDATION REPORT
Commands: <exactly what you ran>
Source:   <where you got them>
Result:   <per command: pass, plus its summary line>
Not covered: <what this repo does not check at all>
```

- **Commands** — exactly what you ran, so the reviewer can tell a full-suite run
  from the three files you touched.
- **Source** — where you got them. This is the line that makes a wrong guess
  visible; it is also the line that saves the reviewer from re-deriving the repo's
  checks itself.
- **Result** — per command, with its summary line. "All green" is not a result;
  `42 passed` is.
- **Not covered** — what this repo does not check at all. No type checker, no
  integration tests, a suite that never exercises the concurrent path.

**`Not covered` is the line the reviewer reads first and the one you will be
tempted to leave blank.** It is what aims the review: that is the ground nothing
mechanical is watching, so a defect there is one nothing downstream will catch
either. A change whose risk sits entirely inside a covered area is a change where
the interesting findings are elsewhere — and the reviewer can only know that if you
said so. See [adversarial-review](../../adversarial-review/SKILL.md#the-validation-report).

Filling it is a Phase 4 job because Phase 4 is where you found out what the checks
actually run. Nobody downstream is in a position to work it out.
