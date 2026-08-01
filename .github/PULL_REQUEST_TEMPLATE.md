## What moved

<!-- One or two sentences on the intent, not a restatement of the diff. -->

## Install paths touched

<!-- Plugins that ship hooks carry the wiring twice. Tick both or neither. -->

- [ ] `settings.json` (manual `cp -R` install)
- [ ] `hooks/hooks.json` (plugin install)
- [ ] Neither — this change does not touch hook registration

## Tests

<!-- Paste the summary line, e.g. "417 passed, 0 failed". -->

```
```

- [ ] A fix? Then it carries a regression case that fails without the fix.
- [ ] New or changed shell is bash 3.2-safe (no `declare -A`, `mapfile`, `${var,,}`).
- [ ] New scripts are committed with the executable bit set.
- [ ] New plugin? It is registered in `.claude-plugin/marketplace.json` and listed
      in the root README.
