#!/usr/bin/env node
/**
 * A task-manager root with every state that the admin UI shows. The tests read it, and a person can
 * review the UI against it:
 *
 *   node admin/test/fixture.mjs <dir>
 *   node admin/server.mjs --root <dir>
 *
 * The files have the shape that the skill's helper writes (schema 1).
 */
import { mkdirSync, symlinkSync, writeFileSync } from 'node:fs';
import * as path from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';

export const IDS = {
  finished: '2026-11-09-spellcheck-dictionaries',
  main: '2026-11-13-undo-timeline-and-history',
  stale: '2026-11-12-export-docx-styles',
  torn: '2026-11-11-chapter-word-counts',
  broken: '2026-11-10-broken-json',
  oldFormat: '2026-11-01-old-ledger',
  otherSchema: '2026-11-02-schema-two',
  // Tasks runs : independent tasks, each PR on main.
  tasks: '2026-11-14-small-fixes',
  oneTask: '2026-11-14-window-menu-label',
  finishedTasks: '2026-11-08-toast-copy',
  badKind: '2026-11-04-kind-queue',
};

const MIN = 60_000;
const jsonl = (records) => `${records.map((r) => JSON.stringify(r)).join('\n')}\n`;

function layer(n, fields) {
  return {
    id: `l${n}`,
    position: n,
    task: `task ${n}`,
    source: `#${700 + n}`,
    dependsOn: [],
    parked: null,
    tier: 'M',
    tierReason: 'feature work',
    escalated: false,
    branch: null,
    base: null,
    baseTip: null,
    head: null,
    lastReviewed: null,
    phase: 'queued',
    round: 0,
    implementer: null,
    reviewer: null,
    pr: null,
    ...fields,
  };
}

/** Write one run folder. `events` are `[minutesBeforeEnd, fields]`; `end` is the time of the last event. */
function writeRun(root, run, { end, events, questions = [], findings = {}, followups = [], plans = {} }) {
  const dir = path.join(root, run.id);
  mkdirSync(path.join(dir, 'findings'), { recursive: true });
  mkdirSync(path.join(dir, 'plans'), { recursive: true });
  const ts = (minutes) => new Date(end - minutes * MIN).toISOString();
  const created = ts(events[0][0]);
  writeFileSync(path.join(dir, 'run.json'), `${JSON.stringify({ schema: 1, decisions: [], nextStep: null, stack: null, ci: null, created, updated: ts(0), ...run }, null, 2)}\n`);
  writeFileSync(
    path.join(dir, 'events.jsonl'),
    jsonl(events.map(([minutes, e]) => ({ ts: ts(minutes), layer: null, round: null, refs: {}, ...e }))),
  );
  writeFileSync(path.join(dir, 'questions.jsonl'), questions.length ? jsonl(questions.map((q) => ({ ts: ts(0), options: [], answer: null, ...q }))) : '');
  writeFileSync(path.join(dir, 'followups.jsonl'), followups.length ? jsonl(followups.map((f) => ({ ts: ts(0), body: 'Seen in review.', dataLoss: false, issue: null, ...f }))) : '');
  for (const [layerId, records] of Object.entries(findings)) writeFileSync(path.join(dir, 'findings', `${layerId}.jsonl`), jsonl(records));
  for (const [name, text] of Object.entries(plans)) writeFileSync(path.join(dir, 'plans', name), text);
  return dir;
}

const phase = (layerId, from, to, round = 0) => ({ type: 'layer_phase', layer: layerId, round, summary: `${from} -> ${to}` });

function finding(id, fields) {
  return { ts: '2026-11-13T10:00:00.000Z', id, round: 1, severity: 'should_fix', file: 'src/a.ts', line: 10, defect: 'defect', expectedFix: 'fix', ruling: null, reason: null, state: 'open', fixSha: null, ...fields };
}

function buildMain(root, end) {
  const pr = (n) => ({ number: n, url: `https://github.com/example/app/pull/${n}` });
  const parkedQuestion = { id: 'q1', layer: 'l2', question: 'Must a paste end a typing group?', options: ['Yes, a paste is its own step', 'No, a paste joins the group'] };
  return writeRun(
    root,
    {
      id: IDS.main,
      title: 'Undo timeline and history',
      checkout: '/Users/dev/projects/app-alpha',
      request: 'Work through the undo timeline issues #701 to #706.',
      decisions: [{ question: 'Group typing by time or by word?', answer: 'By time.' }],
      state: 'active',
      stage: 'layers',
      nextStep: 'Wait for the reviewer of l4, round 2.',
      layers: [
        layer(1, { task: 'Record undo steps for chapter moves', phase: 'pr_open', round: 1, pr: pr(901) }),
        layer(2, { position: 3, task: 'Group typing into one undo step', phase: 'review', round: 1, parked: { question: 'q1', phase: 'review', round: 1, baseTip: null, tip: 'b'.repeat(40), lastReviewed: null } }),
        layer(3, { position: 4, task: 'Show grouped steps in the history panel', dependsOn: ['l2'] }),
        layer(4, { position: 2, task: 'Undo across a chapter split', phase: 'review', round: 2, escalated: true }),
        layer(5, { task: 'Keyboard shortcut for the history panel', dependsOn: ['l4'] }),
        layer(6, { task: 'Copy edits for the history panel <b>labels</b>' }),
      ],
    },
    {
      end,
      events: [
        [120, { type: 'run_created', summary: '6 layers: Undo timeline and history' }],
        [110, phase('l1', 'queued', 'implementing')],
        [90, phase('l1', 'implementing', 'review', 1)],
        [80, { type: 'review', layer: 'l1', round: 1, summary: 'l1-f1 blocker: empty step' }],
        [75, phase('l1', 'review', 'final_checks', 1)],
        [70, phase('l1', 'final_checks', 'opening_pr', 1)],
        [65, phase('l1', 'opening_pr', 'pr_open', 1)],
        [60, phase('l2', 'queued', 'implementing')],
        [50, phase('l2', 'implementing', 'review', 1)],
        [45, { type: 'park', layer: 'l2', round: 1, summary: 'q1: Must a paste end a typing group?' }],
        [40, phase('l4', 'queued', 'implementing')],
        [30, phase('l4', 'implementing', 'review', 1)],
        [20, { type: 'layer_phase', layer: 'l4', round: 1, summary: 'custom summary that the reader skips' }],
        [10, phase('l4', 'fixing', 'review', 2)],
        [0, { type: 'question', summary: 'q2: Open the PRs as drafts?' }],
      ],
      questions: [parkedQuestion, { id: 'q2', layer: null, question: 'Open the PRs as drafts, or ready for review?', options: ['Drafts', 'Ready'] }, { id: 'q3', layer: 'l1', question: 'Keep the old step name?' }, { id: 'q3', answer: 'Yes' }],
      findings: {
        l1: [finding('l1-f1', { severity: 'blocker' }), finding('l1-f1', { state: 'fixed', fixSha: 'a'.repeat(40) })],
        l4: [finding('l4-f1', {}), finding('l4-f1', { state: 'not_fixed' }), finding('l4-f2', { round: 2, severity: 'blocker' })],
      },
      followups: [
        { id: 'fu1', layer: 'l1', title: 'History panel has no empty state' },
        { id: 'fu2', layer: 'l4', title: 'Notes are lost when a split fails', dataLoss: true },
        { id: 'fu1', issue: 912 },
      ],
      plans: {
        'plan-undo-chapter-moves.md': '# Plan\n\n<script>alert("not run")</script>\n',
        'plan-typing-groups.md': '# Typing groups\n',
        'main-undo-timeline-plan.md': '# Undo timeline plan (the user\'s document)\n',
        'notes.txt': 'not a plan',
      },
    },
  );
}

/**
 * A tasks run with a task in each column but "in progress": l1 has an open PR whose CI failed, l2
 * is parked on a question, l3 has not started. l4 works now. It has a main plan.
 */
function buildTasks(root, end) {
  const pr = (n) => ({ number: n, url: `https://github.com/example/app/pull/${n}` });
  return writeRun(
    root,
    {
      id: IDS.tasks,
      kind: 'tasks',
      title: 'Small fixes',
      checkout: '/Users/dev/projects/app-delta',
      request: 'Fix #801, #802, #803 and #804 as separate PRs.',
      state: 'active',
      stage: 'layers',
      nextStep: 'Phase 1 step C for l4',
      mainPlans: [{ path: 'plans/main-small-fixes-plan.md', source: '/Users/dev/projects/app-delta/docs/plans/small-fixes-plan.md', copied: new Date(end - 100 * MIN).toISOString() }],
      layers: [
        layer(1, { task: 'Fix the toast copy on export', source: '#801', tier: 'S', phase: 'pr_open', round: 1, pr: pr(950), branch: 'fix/toast-copy', base: 'main', ci: { runUrl: 'https://github.com/example/app/actions/runs/1', result: 'fail' }, plan: 'plans/plan-toast-copy.md' }),
        layer(2, { task: 'Keep the scroll position after a rename', source: '#802', phase: 'implementing', parked: { question: 'q1', phase: 'implementing', round: 0, baseTip: 'c'.repeat(40), tip: 'd'.repeat(40), lastReviewed: null } }),
        layer(3, { task: 'Trim spaces in a new chapter title', source: '#803', tier: 'S' }),
        layer(4, { task: 'Show the word count in the status bar', source: '#804', phase: 'review', round: 1 }),
      ],
    },
    {
      end,
      events: [
        [100, { type: 'run_created', summary: '4 tasks: Small fixes' }],
        [99, { type: 'main_plan', summary: 'plans/main-small-fixes-plan.md from /Users/dev/projects/app-delta/docs/plans/small-fixes-plan.md' }],
        [90, phase('l1', 'queued', 'implementing')],
        [70, phase('l1', 'implementing', 'review', 1)],
        [60, phase('l1', 'review', 'pr_open', 1)],
        [55, { type: 'ci_started', layer: 'l1', summary: 'run-ci on #950' }],
        [50, phase('l2', 'queued', 'implementing')],
        [40, { type: 'park', layer: 'l2', summary: 'q1: Keep the position per chapter or per window?' }],
        [30, { type: 'ci_result', layer: 'l1', summary: 'fail' }],
        [20, phase('l4', 'queued', 'implementing')],
        [5, phase('l4', 'implementing', 'review', 1)],
      ],
      questions: [{ id: 'q1', layer: 'l2', question: 'Keep the position per chapter or per window?', options: ['Per chapter', 'Per window'] }],
      plans: {
        'main-small-fixes-plan.md': '# Small fixes (the user\'s plan)\n',
        'plan-toast-copy.md': '# Toast copy\n',
      },
    },
  );
}

/** Write the fixture root into `root`. Returns the run ids. */
export function buildFixtureRoot(root, { end = Date.now() } = {}) {
  mkdirSync(root, { recursive: true });
  buildMain(root, end);
  buildTasks(root, end);
  writeRun(
    root,
    {
      id: IDS.oneTask,
      kind: 'tasks',
      title: 'Window menu label',
      checkout: '/Users/dev/projects/app-alpha',
      request: 'Fix #810.',
      state: 'paused',
      stage: 'finish',
      nextStep: 'waits for the user: more changes, merged, or finished',
      layers: [layer(1, { task: 'Rename the Window menu item', source: '#810', tier: 'S', phase: 'pr_open', round: 1, pr: { number: 960, url: 'https://github.com/example/app/pull/960' }, ci: { runUrl: 'https://github.com/example/app/actions/runs/2', result: 'pass' } })],
    },
    { end: end - 30 * MIN, events: [[40, phase('l1', 'queued', 'implementing')], [10, phase('l1', 'implementing', 'pr_open', 1)], [0, { type: 'ci_result', layer: 'l1', summary: 'pass' }]] },
  );
  writeRun(
    root,
    { id: IDS.finishedTasks, kind: 'tasks', title: 'Toast copy', checkout: '/Users/dev/projects/app-beta', request: 'Fix #790.', state: 'finished', stage: 'finish', layers: [layer(1, { task: 'Shorter toast copy', phase: 'merged', pr: { number: 870, url: null }, ci: { runUrl: 'https://github.com/example/app/actions/runs/3', result: 'no_e2e' } })] },
    { end: end - 6 * 24 * 60 * MIN, events: [[30, phase('l1', 'queued', 'implementing')], [0, phase('l1', 'pr_open', 'merged')]] },
  );
  mkdirSync(path.join(root, IDS.badKind));
  writeFileSync(path.join(root, IDS.badKind, 'run.json'), JSON.stringify({ schema: 1, id: IDS.badKind, kind: 'queue', state: 'active', checkout: '/x', layers: [] }));
  writeRun(
    root,
    { id: IDS.finished, title: 'Spellcheck dictionaries', checkout: '/Users/dev/projects/app-alpha', request: 'Ship the dictionaries.', state: 'finished', stage: 'finish', layers: [layer(1, { phase: 'merged', pr: { number: 880, url: null } })] },
    { end: end - 4 * 24 * 60 * MIN, events: [[30, phase('l1', 'queued', 'implementing')], [0, phase('l1', 'pr_open', 'merged')]] },
  );
  writeRun(
    root,
    { id: IDS.stale, title: 'Export docx styles', checkout: '/Users/dev/projects/app-gamma', request: 'Keep styles.', state: 'active', stage: 'layers', layers: [layer(1, { phase: 'implementing' })] },
    { end: end - 3 * 60 * MIN, events: [[5, { type: 'run_created', summary: '1 layer' }], [0, phase('l1', 'queued', 'implementing')]] },
  );
  const torn = writeRun(
    root,
    { id: IDS.torn, title: 'Chapter word counts', checkout: '/Users/dev/projects/app-beta', request: 'Count words.', state: 'paused', stage: 'layers', layers: [layer(1, { phase: 'implementing' })] },
    { end: end - 2 * 60 * MIN, events: [[10, { type: 'run_created', summary: '1 layer' }], [0, phase('l1', 'queued', 'implementing')]] },
  );
  writeFileSync(path.join(torn, 'events.jsonl'), `${jsonl([{ ts: new Date(end).toISOString(), type: 'note', layer: null, summary: 'ok' }])}{"ts":"2026-11-11T12:00:00.000Z","type":"rep`, { flag: 'a' });
  mkdirSync(path.join(root, IDS.broken));
  writeFileSync(path.join(root, IDS.broken, 'run.json'), '{"schema": 1, "id": ');
  mkdirSync(path.join(root, IDS.oldFormat));
  writeFileSync(path.join(root, IDS.oldFormat, 'ledger.md'), '# Ledger\n');
  mkdirSync(path.join(root, IDS.otherSchema));
  writeFileSync(path.join(root, IDS.otherSchema, 'run.json'), JSON.stringify({ schema: 2, id: IDS.otherSchema }));
  // Folders the scan must skip: the admin folder itself, and a folder with no run files.
  mkdirSync(path.join(root, 'admin'), { recursive: true });
  mkdirSync(path.join(root, '2026-11-03-empty-folder'));
  return IDS;
}

/** Add a symbolic link in the main run's plans folder that points outside the run. For a test. */
export function addOutsideLink(root, target) {
  symlinkSync(target, path.join(root, IDS.main, 'plans', 'plan-outside.md'));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const dir = process.argv[2];
  if (!dir) {
    process.stderr.write('usage: node fixture.mjs <dir>\n');
    process.exit(1);
  }
  buildFixtureRoot(path.resolve(dir));
  process.stdout.write(`${path.resolve(dir)}\n`);
}
