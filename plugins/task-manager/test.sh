#!/usr/bin/env bash
# Suite of the task-manager plugin: the ledger script, the admin server, and the skill files.
# Needs node 20 or later. No dependencies to install.
set -uo pipefail
cd "$(dirname "$0")"

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is not installed; the ledger and the admin page need node 20 or later" >&2
  exit 1
fi

status=0

echo "== ledger =="
node --test skills/task-manager/scripts/__tests__/*.test.mjs || status=1

echo "== admin =="
node --test admin/test/*.test.mjs || status=1

echo "== skill files =="
# Every file that a skill text links to must exist. A broken link is a rule that no agent reads.
checked=0
for skill in skills/task-manager/*.md; do
  dir=$(dirname "$skill")
  links=$(grep -o '](\.\{0,2\}[A-Za-z0-9_./-]*\.md)' "$skill" | sed 's/^](//; s/)$//' | sort -u)
  for link in $links; do
    checked=$((checked + 1))
    if [ ! -f "$dir/$link" ]; then
      echo "FAIL: $skill links to $link, which does not exist"
      status=1
    fi
  done
done
# Assert the count before the comparison: zero links checked is a broken extractor.
if [ "$checked" -lt 12 ]; then
  echo "FAIL: only $checked links checked; the link extractor is broken"
  status=1
else
  echo "ok: $checked links"
fi

# The skills are generic: the name of the project they came from must not come back.
if grep -rIil 'vavly-write\|vavly-task\|task-stack\|task-prs\|yarn \|NODE_AUTH_TOKEN' skills admin; then
  echo "FAIL: the files above name a project-specific tool or path"
  status=1
else
  echo "ok: no project-specific names"
fi

# Each section that the skill texts cite must be a heading of the profile template.
for section in "Project" "Commands" "Checks for the changed code" "Final checks" "Review" "Skills" "PR" "CI" "Tiers" "Sources of record" "User data" "Restack" "Scratch"; do
  if ! grep -qx "## $section" skills/task-manager/profile-template.md; then
    echo "FAIL: the profile template has no section \"$section\""
    status=1
  fi
done

# Each mode file that SKILL.md routes to must exist, and the one skill must stay one skill.
if [ "$(ls -d skills/*/ | wc -l | tr -d ' ')" != "1" ]; then
  echo "FAIL: the plugin must have exactly one skill folder"
  status=1
fi

[ "$status" -eq 0 ] && echo "task-manager: all checks passed"
exit "$status"
