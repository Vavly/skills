import { strict as assert } from 'node:assert';
import { spawn, spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import * as path from 'node:path';
import process from 'node:process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  PHASES,
  addFinding,
  answer,
  ask,
  blockedBy,
  columnOf,
  initRun,
  listRuns,
  nextLayer,
  park,
  readRun,
  resolve,
  rule,
  setLayer,
  setRun,
  show,
  showLayer,
  slugify,
  unpark,
  waitsFor,
} from '../lib/task-manager-core.mjs';
import { main } from '../task-manager-ledger.mjs';

const CLI = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'task-manager-ledger.mjs');
const CHECKOUT = '/Users/someone/app-delta';
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

function tempRoot() {
  return mkdtempSync(path.join(tmpdir(), 'task-manager-'));
}

function layers(n, deps = {}) {
  return Array.from({ length: n }, (_, i) => ({
    task: `task ${i + 1}`,
    source: `#${100 + i}`,
    tier: 'M',
    tierReason: 'feature work',
    dependsOn: deps[i + 1] ?? [],
  }));
}

function newRun(root, n = 3, deps = {}, extra = {}) {
  return initRun(root, { title: 'Undo timeline', checkout: CHECKOUT, request: 'do it', layers: layers(n, deps), date: '2026-11-06', ...extra }).id;
}

function eventCount(root, id) {
  return readFileSync(path.join(root, id, 'events.jsonl'), 'utf8').trim().split('\n').length;
}

function cli(root, ...args) {
  return main(args, { TASK_MANAGER_RUNS: root });
}

/** Set a layer's phase. Like a real start, leaving `queued` moves the layer below the parked layers. */
function phase(root, id, layer, value) {
  setLayer(root, id, layer, [['phase', value]]);
}

test('1. init makes <date>-<slug>, and a second run with the same title the same day gets -2', () => {
  const root = tempRoot();
  const first = newRun(root);
  setRun(root, first, [['state', 'finished']]);
  const second = newRun(root);
  assert.equal(first, '2026-11-06-undo-timeline');
  assert.equal(second, '2026-11-06-undo-timeline-2');
});

test('2. every command rejects a run id with a slash, .., capitals or spaces', () => {
  const root = tempRoot();
  const commands = [
    ['layer', '--layer', 'l1', '--set', 'round=1'],
    ['run', '--set', 'state=paused'],
    ['decision', '--question', 'q', '--answer', 'a'],
    ['event', '--type', 'note', '--summary', 's'],
    ['ask', '--question', 'q'],
    ['answer', '--id', 'q1', '--answer', 'a'],
    ['park', '--layer', 'l1', '--question', 'q', '--tip', 'abc'],
    ['unpark', '--layer', 'l1', '--base', 'b', '--base-tip', 'abc', '--head', 'h'],
    ['next'],
    ['finding', '--layer', 'l1', '--round', '1', '--severity', 'nit', '--file', 'f', '--defect', 'd', '--expected-fix', 'x'],
    ['rule', '--layer', 'l1', '--id', 'l1-f1', '--ruling', 'relay'],
    ['resolve', '--layer', 'l1', '--id', 'l1-f1', '--state', 'fixed'],
    ['followup', '--title', 't', '--body', 'b'],
    ['followup-filed', '--id', 'fu1', '--issue', '1'],
    ['show'],
  ];
  for (const bad of ['../2026-11-06-x', '2026-11-06-X', '2026-11-06-a b', '2026-11-06/x']) {
    for (const [command, ...rest] of commands) {
      const result = cli(root, command, '--run', bad, ...rest);
      assert.equal(result.code, 1, `${command} accepted ${bad}`);
      assert.match(result.stderr, /invalid run id/);
    }
  }
});

test('3. phase, round and tier accept only their values', () => {
  const root = tempRoot();
  const id = newRun(root);
  // `delivered` is the end of a report layer only (see the O tests).
  for (const value of PHASES.filter((p) => p !== 'delivered')) assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', `phase=${value}`).code, 0);
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'phase=done').code, 1);
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'round=4').code, 1);
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'round=-1').code, 1);
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'round=3').code, 0);
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'tier=XL').code, 1);
  for (const tier of ['S', 'M', 'L']) assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', `tier=${tier}`).code, 0);
});

test('4. an unknown key is rejected and run.json does not change', () => {
  const root = tempRoot();
  const id = newRun(root);
  const before = readFileSync(path.join(root, id, 'run.json'), 'utf8');
  const result = cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'round=1', '--set', 'colour=red');
  assert.equal(result.code, 1);
  assert.match(result.stderr, /cannot set "colour"/);
  assert.equal(readFileSync(path.join(root, id, 'run.json'), 'utf8'), before);
});

test('5. each mutating command appends exactly one event with an ISO time', () => {
  const root = tempRoot();
  const id = newRun(root);
  const steps = [
    ['layer', '--run', id, '--layer', 'l1', '--set', 'phase=implementing'],
    ['run', '--run', id, '--set', 'stage=layers'],
    ['decision', '--run', id, '--question', 'keep key?', '--answer', 'migrate'],
    ['event', '--run', id, '--type', 'note', '--summary', 'hello'],
    ['ask', '--run', id, '--question', 'which?', '--option', 'a', '--option', 'b'],
    ['answer', '--run', id, '--id', 'q1', '--answer', 'a'],
    ['finding', '--run', id, '--layer', 'l1', '--round', '1', '--severity', 'blocker', '--file', 'src/a.ts', '--line', '3', '--defect', 'd', '--expected-fix', 'x'],
    ['rule', '--run', id, '--layer', 'l1', '--id', 'l1-f1', '--ruling', 'relay'],
    ['resolve', '--run', id, '--layer', 'l1', '--id', 'l1-f1', '--state', 'fixed', '--sha', 'abc'],
    ['park', '--run', id, '--layer', 'l1', '--question', 'scope?', '--tip', 'def'],
    ['answer', '--run', id, '--id', 'q2', '--answer', 'yes'],
    ['unpark', '--run', id, '--layer', 'l1', '--base', 'main', '--base-tip', '123', '--head', 'h1'],
    ['followup', '--run', id, '--layer', 'l1', '--title', 't', '--body', 'b', '--data-loss'],
    ['followup-filed', '--run', id, '--id', 'fu1', '--issue', '700'],
  ];
  for (const step of steps) {
    const before = eventCount(root, id);
    const result = cli(root, ...step);
    assert.equal(result.code, 0, `${step[0]}: ${result.stderr}`);
    assert.equal(eventCount(root, id), before + 1, `${step[0]} did not write exactly one event`);
  }
  const events = readRun(root, id).events;
  for (const e of events) assert.match(e.ts, ISO);
  for (const read of [['next', '--run', id], ['show', '--run', id], ['list']]) {
    const before = eventCount(root, id);
    assert.equal(cli(root, ...read).code, 0);
    assert.equal(eventCount(root, id), before, `${read[0]} wrote an event`);
  }
});

test('6. after a write, run.json parses and no temp file remains', () => {
  const root = tempRoot();
  const id = newRun(root);
  setLayer(root, id, 'l1', [['phase', 'implementing'], ['branch', 'fix/a']]);
  JSON.parse(readFileSync(path.join(root, id, 'run.json'), 'utf8'));
  assert.deepEqual(readdirSync(path.join(root, id)).filter((f) => f.includes('.tmp')), []);
});

test('7. columnOf: queued is todo, a working phase is in_progress, a PR is done, an open question is needs_input', () => {
  const layer = (phaseName) => ({ id: 'l1', phase: phaseName });
  assert.equal(columnOf(layer('queued'), []), 'todo');
  for (const p of ['implementing', 'review', 'fixing', 'final_checks', 'opening_pr']) assert.equal(columnOf(layer(p), []), 'in_progress');
  assert.equal(columnOf(layer('pr_open'), []), 'done');
  assert.equal(columnOf(layer('merged'), []), 'done');
  for (const p of PHASES) assert.equal(columnOf(layer(p), [{ id: 'q1', layer: 'l1' }]), 'needs_input');
  assert.equal(columnOf(layer('review'), [{ id: 'q1', layer: 'l2' }]), 'in_progress');

  const root = tempRoot();
  const id = newRun(root);
  phase(root, id, 'l1', 'review');
  ask(root, id, { layer: 'l1', question: 'which?' });
  assert.equal(readRun(root, id).layers.find((l) => l.id === 'l1').column, 'needs_input');
  answer(root, id, 'q1', 'this');
  assert.equal(readRun(root, id).layers.find((l) => l.id === 'l1').column, 'in_progress');
});

test('8. ask then answer closes the question; an unknown or answered question is rejected', () => {
  const root = tempRoot();
  const id = newRun(root);
  ask(root, id, { question: 'run-level?' });
  assert.equal(readRun(root, id).openQuestions.length, 1);
  answer(root, id, 'q1', 'yes');
  const state = readRun(root, id);
  assert.equal(state.openQuestions.length, 0);
  assert.equal(state.questions[0].question, 'run-level?');
  assert.equal(state.questions[0].answer, 'yes');
  assert.equal(cli(root, 'answer', '--run', id, '--id', 'q9', '--answer', 'x').code, 1);
  assert.match(cli(root, 'answer', '--run', id, '--id', 'q1', '--answer', 'again').stderr, /already answered/);
});

test('9. finding, rule and resolve: the latest record wins, and openFindings counts open and not_fixed', () => {
  const root = tempRoot();
  const id = newRun(root);
  const finding = (severity) => addFinding(root, id, 'l1', { round: 1, severity, file: 'a.ts', defect: 'd', expectedFix: 'x' }).id;
  const f1 = finding('blocker');
  const f2 = finding('should_fix');
  const f3 = finding('nit');
  assert.deepEqual([f1, f2, f3], ['l1-f1', 'l1-f2', 'l1-f3']);
  rule(root, id, 'l1', f1, { ruling: 'relay' });
  rule(root, id, 'l1', f3, { ruling: 'closed', reason: 'churn' });
  resolve(root, id, 'l1', f2, { state: 'not_fixed' });
  let state = readRun(root, id);
  assert.equal(state.layers.find((l) => l.id === 'l1').openFindings, 2);
  resolve(root, id, 'l1', f1, { state: 'fixed', sha: 'abc' });
  state = readRun(root, id);
  const byId = Object.fromEntries(state.findings.l1.map((f) => [f.id, f]));
  assert.equal(byId[f1].state, 'fixed');
  assert.equal(byId[f1].ruling, 'relay');
  assert.equal(byId[f1].fixSha, 'abc');
  assert.equal(byId[f3].state, 'closed');
  assert.equal(state.layers.find((l) => l.id === 'l1').openFindings, 1);
  assert.equal(cli(root, 'rule', '--run', id, '--layer', 'l1', '--id', f2, '--ruling', 'closed').code, 1, 'closed needs a reason');
});

test('10. list filters by checkout and state, skips non-runs, and reports broken folders', () => {
  const root = tempRoot();
  const a = newRun(root, 1);
  setRun(root, a, [['state', 'paused']]);
  newRun(root, 1, {}, { checkout: '/Users/someone/app-alpha', title: 'Other' });
  mkdirSync(path.join(root, 'notes'));
  mkdirSync(path.join(root, '2026-11-01-empty'));
  mkdirSync(path.join(root, '2026-11-02-broken'));
  writeFileSync(path.join(root, '2026-11-02-broken', 'run.json'), '{ not json');
  mkdirSync(path.join(root, '2026-11-03-old'));
  writeFileSync(path.join(root, '2026-11-03-old', 'ledger.md'), '# ledger');

  const all = listRuns(root);
  assert.equal(all.runs.length, 2);
  assert.deepEqual(all.broken.map((b) => b.id).sort(), ['2026-11-02-broken', '2026-11-03-old']);
  assert.match(all.broken.find((b) => b.id === '2026-11-03-old').error, /old format/);
  assert.deepEqual(listRuns(root, { checkout: CHECKOUT }).runs.map((r) => r.id), [a]);
  assert.deepEqual(listRuns(root, { states: ['active'] }).runs.map((r) => r.title), ['Other']);
});

test('11. a broken last JSONL line is reported and skipped, and earlier lines are read', () => {
  const root = tempRoot();
  const id = newRun(root);
  ask(root, id, { question: 'first?' });
  appendFileSync(path.join(root, id, 'questions.jsonl'), '{"ts":"2026-11-06T00:00:00.000Z","id":"q2","que');
  const state = readRun(root, id);
  assert.deepEqual(state.questions.map((q) => q.id), ['q1']);
  assert.equal(state.errors.length, 1);
  assert.match(state.errors[0], /questions\.jsonl:2/);
  assert.match(show(root, id), /warning: questions\.jsonl:2/);
});

test('12. show prints the open questions and the last 5 events', () => {
  const root = tempRoot();
  const id = newRun(root);
  for (let i = 1; i <= 7; i += 1) cli(root, 'event', '--run', id, '--type', 'note', '--summary', `note ${i}`);
  ask(root, id, { layer: 'l2', question: 'scope?', options: ['add', 'skip'] });
  setRun(root, id, [['nextStep', 'start l1 at step A']]);
  const text = show(root, id);
  assert.match(text, /q1 \(l2\): scope\? \[add \| skip\]/);
  const eventLines = text.split('last events:\n')[1].split('\nnext step:')[0].split('\n');
  assert.equal(eventLines.length, 5);
  assert.doesNotMatch(text, /note 4/);
  assert.match(text, /note 7/);
  assert.match(text, /next step: start l1 at step A/);
});

test('13. init refuses while another run for the checkout is active, and accepts after it pauses', () => {
  const root = tempRoot();
  const first = newRun(root);
  assert.throws(() => newRun(root, 1, {}, { title: 'Second' }), /is active for this checkout/);
  newRun(root, 1, {}, { title: 'Elsewhere', checkout: '/Users/someone/app-alpha' });
  setRun(root, first, [['state', 'paused']]);
  assert.equal(newRun(root, 1, {}, { title: 'Second' }), '2026-11-06-second');
});

test('14. a run.json with an unknown schema version is rejected with a clear message', () => {
  const root = tempRoot();
  const id = newRun(root);
  const file = path.join(root, id, 'run.json');
  writeFileSync(file, JSON.stringify({ ...JSON.parse(readFileSync(file, 'utf8')), schema: 2 }));
  assert.throws(() => readRun(root, id), /unsupported schema version 2; this helper reads version 1/);
});

test('15. init rejects a dependsOn on the same layer or a later layer', () => {
  const root = tempRoot();
  assert.throws(() => newRun(root, 3, { 2: [2] }), /only earlier layers/);
  assert.throws(() => newRun(root, 3, { 2: [3] }), /only earlier layers/);
  assert.throws(() => newRun(root, 3, { 2: [0] }), /only earlier layers/);
  assert.deepEqual(readdirSync(root), [], 'a rejected init leaves no folder');
});

test('16. park sets parked and an open question; a queued or PR layer cannot park', () => {
  const root = tempRoot();
  const id = newRun(root);
  setLayer(root, id, 'l1', [['phase', 'review'], ['round', '2'], ['baseTip', 'base1'], ['lastReviewed', 'rev1']]);
  const { id: qid } = park(root, id, 'l1', { question: 'widen scope?', options: ['yes', 'no'], tip: 'tip1' });
  const l1 = readRun(root, id).layers.find((l) => l.id === 'l1');
  assert.deepEqual(l1.parked, { question: qid, phase: 'review', round: 2, baseTip: 'base1', tip: 'tip1', lastReviewed: 'rev1' });
  assert.equal(l1.column, 'needs_input');
  assert.match(cli(root, 'park', '--run', id, '--layer', 'l2', '--question', 'q', '--tip', 't').stderr, /has not started/);
  phase(root, id, 'l3', 'pr_open');
  assert.match(cli(root, 'park', '--run', id, '--layer', 'l3', '--question', 'q', '--tip', 't').stderr, /never parked/);
  assert.match(cli(root, 'park', '--run', id, '--layer', 'l1', '--question', 'q', '--tip', 't').stderr, /already parked/);
});

test('17. blockedBy lists parked layers reached directly or through another layer', () => {
  const root = tempRoot();
  const id = newRun(root, 4, { 3: [2], 4: [3] });
  phase(root, id, 'l2', 'implementing');
  park(root, id, 'l2', { question: 'q', tip: 't' });
  const run = readRun(root, id).run;
  assert.deepEqual(blockedBy(run, 'l3'), ['l2']);
  assert.deepEqual(blockedBy(run, 'l4'), ['l2']);
  assert.deepEqual(blockedBy(run, 'l1'), []);
});

test('18. nextLayer skips blocked layers, takes the lowest free queued layer, and is null when all are blocked', () => {
  const root = tempRoot();
  const id = newRun(root, 4, { 3: [1], 4: [1] });
  assert.equal(nextLayer(readRun(root, id).run), 'l1');
  phase(root, id, 'l1', 'implementing');
  park(root, id, 'l1', { question: 'q', tip: 't' });
  assert.equal(nextLayer(readRun(root, id).run), 'l2');
  phase(root, id, 'l2', 'pr_open');
  assert.equal(nextLayer(readRun(root, id).run), null, 'l3 and l4 depend on the parked l1');
  assert.deepEqual(JSON.parse(cli(root, 'next', '--run', id).stdout), { next: null });
});

test('19. unpark needs an answer, then places the layer above the highest PR layer and keeps its id', () => {
  const root = tempRoot();
  const id = newRun(root, 5);
  // l1 opens its PR. l2 parks. l3 starts below the parked l2, then parks. l4 starts and opens its PR.
  phase(root, id, 'l1', 'pr_open');
  phase(root, id, 'l2', 'implementing');
  addFinding(root, id, 'l2', { round: 1, severity: 'blocker', file: 'a.ts', defect: 'd', expectedFix: 'x' });
  const { id: q2 } = park(root, id, 'l2', { question: 'q2', tip: 't2' });
  phase(root, id, 'l3', 'implementing');
  park(root, id, 'l3', { question: 'q3', tip: 't3' });
  phase(root, id, 'l4', 'implementing');
  phase(root, id, 'l4', 'pr_open');
  const order = () => readRun(root, id).layers.map((l) => l.id);
  assert.deepEqual(order(), ['l1', 'l4', 'l3', 'l2', 'l5'], 'a started layer goes below the parked layers');

  assert.match(cli(root, 'unpark', '--run', id, '--layer', 'l2', '--base', 'feat/l4', '--base-tip', 'b4', '--head', 'h2').stderr, /has no answer/);
  answer(root, id, q2, 'go');
  unpark(root, id, 'l2', { base: 'feat/l4', baseTip: 'b4', head: 'h2' });
  assert.deepEqual(order(), ['l1', 'l4', 'l2', 'l3', 'l5'], 'l2 moves directly above l4, below the parked l3');
  const l2 = readRun(root, id).layers.find((l) => l.id === 'l2');
  assert.equal(l2.parked, null);
  assert.equal(l2.base, 'feat/l4');
  assert.equal(l2.baseTip, 'b4');
  assert.equal(l2.phase, 'implementing', 'the layer keeps its recorded phase');
  assert.equal(l2.openFindings, 1, 'its findings are still read by the same id');
  assert.match(cli(root, 'unpark', '--run', id, '--layer', 'l2', '--base', 'x', '--base-tip', 'y', '--head', 'z').stderr, /is not parked/);
});

test('16b. park can attach a question that was asked earlier for the same layer', () => {
  const root = tempRoot();
  const id = newRun(root);
  phase(root, id, 'l1', 'fixing');
  const { id: q } = ask(root, id, { layer: 'l1', question: 'widen scope?' });
  ask(root, id, { layer: 'l2', question: 'other layer?' });
  assert.match(cli(root, 'park', '--run', id, '--layer', 'l1', '--id', 'q2', '--tip', 't').stderr, /is not about layer l1/);
  assert.match(cli(root, 'park', '--run', id, '--layer', 'l1', '--question', 'x', '--id', q, '--tip', 't').stderr, /not both/);
  assert.equal(cli(root, 'park', '--run', id, '--layer', 'l1', '--id', q, '--tip', 't').code, 0);
  const state = readRun(root, id);
  assert.equal(state.questions.length, 2, 'no duplicate question');
  assert.equal(state.layers.find((l) => l.id === 'l1').parked.question, q);
});

test('show prints the recorded SHAs of a parked layer and the follow-ups not filed, data loss first', () => {
  const root = tempRoot();
  const id = newRun(root);
  setLayer(root, id, 'l1', [['phase', 'review'], ['baseTip', 'base1'], ['lastReviewed', 'rev1']]);
  park(root, id, 'l1', { question: 'q', tip: 'tip1' });
  cli(root, 'followup', '--run', id, '--title', 'minor thing', '--body', 'b');
  cli(root, 'followup', '--run', id, '--layer', 'l1', '--title', 'loses edits', '--body', 'b', '--data-loss');
  cli(root, 'followup', '--run', id, '--title', 'filed thing', '--body', 'b');
  cli(root, 'followup-filed', '--run', id, '--id', 'fu3', '--issue', '9');
  const text = show(root, id);
  assert.match(text, /base tip base1, tip tip1, last reviewed rev1/);
  const block = text.split('follow-ups not filed (data loss first):\n')[1].split('\nlast events:')[0].split('\n');
  // A filed follow-up is not in the list, but a short line names it (gap 28).
  assert.deepEqual(block, ['  fu2 DATA LOSS (l1): loses edits', '  fu1: minor thing', 'follow-ups filed: fu3 #9']);
});

test('20. layer --set cannot change id, position or parked', () => {
  const root = tempRoot();
  const id = newRun(root);
  for (const key of ['id', 'position', 'parked']) {
    const result = cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', `${key}=x`);
    assert.equal(result.code, 1);
    assert.match(result.stderr, new RegExp(`cannot set "${key}"`));
  }
});

test('dependsOn set later is validated: unknown ids, the layer itself, and cycles are rejected', () => {
  const root = tempRoot();
  const id = newRun(root, 3, { 2: [1] });
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l3', '--set', 'dependsOn=l9').code, 1);
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l3', '--set', 'dependsOn=l3').code, 1);
  assert.match(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'dependsOn=l2').stderr, /cycle/);
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l3', '--set', 'dependsOn=l1,l2').code, 0);
});

test('pr and the CI fields keep their shape', () => {
  const root = tempRoot();
  const id = newRun(root);
  assert.match(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'prUrl=https://x').stderr, /set pr before prUrl/);
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'pr=668', '--set', 'prUrl=https://github.com/o/r/pull/668').code, 0);
  assert.deepEqual(readRun(root, id).run.layers[0].pr, { number: 668, url: 'https://github.com/o/r/pull/668' });
  assert.match(cli(root, 'run', '--run', id, '--set', 'ciResult=pass').stderr, /set ciPr before ciResult/);
  assert.equal(cli(root, 'run', '--run', id, '--set', 'ciPr=668', '--set', 'ciResult=no_e2e').code, 0);
  assert.deepEqual(readRun(root, id).run.ci, { pr: 668, runUrl: null, result: 'no_e2e' });
  assert.equal(cli(root, 'run', '--run', id, '--set', 'ciResult=green').code, 1);
});

test('the GitHub stack number is a positive integer and shows in the summary', () => {
  const root = tempRoot();
  const id = newRun(root);
  assert.equal(readRun(root, id).run.stack, null);
  assert.equal(cli(root, 'run', '--run', id, '--set', 'stack=0').code, 1);
  assert.equal(cli(root, 'run', '--run', id, '--set', 'stack=abc').code, 1);
  assert.equal(cli(root, 'run', '--run', id, '--set', 'stack=732').code, 0);
  assert.equal(readRun(root, id).run.stack, 732);
  assert.match(cli(root, 'show', '--run', id).stdout, /github stack: #732/);
  assert.equal(cli(root, 'run', '--run', id, '--set', 'stack=null').code, 0);
  assert.equal(readRun(root, id).run.stack, null);
  assert.doesNotMatch(cli(root, 'show', '--run', id).stdout, /github stack/);
});

test('a run.json from before the stack key still loads, shows, and takes a stack number', () => {
  const root = tempRoot();
  const id = newRun(root);
  const file = path.join(root, id, 'run.json');
  const run = JSON.parse(readFileSync(file, 'utf8'));
  delete run.stack;
  writeFileSync(file, JSON.stringify(run));
  const shown = cli(root, 'show', '--run', id);
  assert.equal(shown.code, 0);
  assert.doesNotMatch(shown.stdout, /github stack/);
  assert.equal(cli(root, 'run', '--run', id, '--set', 'stack=12').code, 0);
  assert.equal(readRun(root, id).run.stack, 12);
});

test('the CLI runs as a script, prints one JSON line, and exits 1 with an error line on bad input', () => {
  const root = tempRoot();
  const env = { ...process.env, TASK_MANAGER_RUNS: root };
  const layersFile = path.join(root, 'layers.json');
  const requestFile = path.join(root, 'request.txt');
  writeFileSync(layersFile, JSON.stringify(layers(1)));
  writeFileSync(requestFile, 'the request');
  const ok = spawnSync(process.execPath, [CLI, 'init', '--title', 'Script', '--checkout', CHECKOUT, '--request-file', requestFile, '--layers-file', layersFile], { env, encoding: 'utf8' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.deepEqual(JSON.parse(ok.stdout), { id: `${new Date().toISOString().slice(0, 10)}-script` });
  const bad = spawnSync(process.execPath, [CLI, 'nope'], { env, encoding: 'utf8' });
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /^error: unknown command "nope"/);
  const missing = spawnSync(process.execPath, [CLI, 'show'], { env, encoding: 'utf8' });
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /^error: --run is required/);
  assert.ok(existsSync(path.join(root)));
});

// ── Review round 1 fixes ─────────────────────────────────────────────────────────────────────────

function runCli(root, args) {
  return new Promise((done) => {
    const child = spawn(process.execPath, [CLI, ...args], { env: { ...process.env, TASK_MANAGER_RUNS: root } });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('close', (code) => done({ code, stdout, stderr }));
  });
}

test('R1. show gives a resume what it needs: request, decisions, layer SHAs and agents, answers', () => {
  const root = tempRoot();
  const id = newRun(root);
  cli(root, 'decision', '--run', id, '--question', 'keep the old key?', '--answer', 'migrate');
  setLayer(root, id, 'l1', [['phase', 'review'], ['round', '2'], ['base', 'main'], ['baseTip', 'bt1'], ['head', 'h1'], ['lastReviewed', 'lr1'], ['implementer', 'imp1'], ['reviewer', 'rev1'], ['branch', 'fix/a']]);
  const { id: q } = park(root, id, 'l1', { question: 'widen?', tip: 'h1' });
  let text = show(root, id);
  assert.match(text, /request: do it/);
  assert.match(text, /^decision: keep the old key\? -> migrate$/m);
  assert.match(text, /base main@bt1; head h1; last reviewed lr1; implementer imp1; reviewer rev1/);
  assert.match(text, /no answer yet/);
  answer(root, id, q, 'yes, widen');
  text = show(root, id);
  assert.match(text, /answer: yes, widen - ready to unpark/);
  assert.match(text, /answered questions \(last 5\):\n {2}q1 \(l1\): widen\? -> yes, widen/);
});

test('R1. show --layer gives the findings with rulings and the review events with rounds', () => {
  const root = tempRoot();
  const id = newRun(root);
  phase(root, id, 'l1', 'review');
  const f = addFinding(root, id, 'l1', { round: 1, severity: 'blocker', file: 'src/a.ts', line: 7, defect: 'drops edits', expectedFix: 'flush' }).id;
  rule(root, id, 'l1', f, { ruling: 'relay' });
  cli(root, 'event', '--run', id, '--layer', 'l1', '--type', 'review', '--round', '1', '--summary', 'CHANGES REQUESTED, aaa...bbb');
  resolve(root, id, 'l1', f, { state: 'fixed', sha: 'ccc' });
  const text = cli(root, 'show', '--run', id, '--layer', 'l1').stdout;
  assert.match(text, /l1-f1 r1 blocker \[fixed\] src\/a\.ts:7: drops edits \| expected: flush \| ruling: relay \| fix ccc/);
  assert.match(text, /review r1: CHANGES REQUESTED, aaa\.\.\.bbb/);
  assert.match(cli(root, 'show', '--run', id, '--layer', 'l9').stderr, /no layer l9/);
  assert.equal(showLayer(root, id, 'l2').includes('(none)'), true);
});

test('R2. parallel L commands on one run give distinct ids and lose no field', async () => {
  const root = tempRoot();
  const id = newRun(root);
  const findings = await Promise.all(
    Array.from({ length: 6 }, (_, i) =>
      runCli(root, ['finding', '--run', id, '--layer', 'l1', '--round', '1', '--severity', 'nit', '--file', `f${i}`, '--defect', 'd', '--expected-fix', 'x']),
    ),
  );
  for (const r of findings) assert.equal(r.code, 0, r.stderr);
  assert.equal(new Set(findings.map((r) => JSON.parse(r.stdout).id)).size, 6);
  assert.equal(readRun(root, id).findings.l1.length, 6);
  const sets = await Promise.all(
    [['head', 'h'], ['lastReviewed', 'lr'], ['reviewer', 'rv'], ['branch', 'b']].map(([k, v]) =>
      runCli(root, ['layer', '--run', id, '--layer', 'l1', '--set', `${k}=${v}`]),
    ),
  );
  for (const r of sets) assert.equal(r.code, 0, r.stderr);
  const l1 = readRun(root, id).run.layers[0];
  assert.deepEqual([l1.head, l1.lastReviewed, l1.reviewer, l1.branch], ['h', 'lr', 'rv', 'b']);
  assert.equal(existsSync(path.join(root, id, '.lock')), false, 'the lock is released');
});

test('R2. a lock left by a crash is removed when it is old', () => {
  const root = tempRoot();
  const id = newRun(root);
  const lock = path.join(root, id, '.lock');
  writeFileSync(lock, '');
  const old = new Date(Date.now() - 120_000);
  utimesSync(lock, old, old);
  assert.equal(cli(root, 'event', '--run', id, '--type', 'note', '--summary', 'after crash').code, 0);
  assert.equal(existsSync(lock), false);
});

test('R3. an append after a torn last line starts on a new line and reads back', () => {
  const root = tempRoot();
  const id = newRun(root);
  ask(root, id, { question: 'first?' });
  appendFileSync(path.join(root, id, 'questions.jsonl'), '{"ts":"x","id":"q2","que');
  const { id: second } = ask(root, id, { question: 'second?' });
  const state = readRun(root, id);
  assert.deepEqual(state.questions.map((q) => [q.id, q.question]), [['q1', 'first?'], [second, 'second?']]);
  assert.equal(state.errors.length, 1, 'only the torn line is lost');
});

test('R4. nextLayer waits for a dependency with no open or merged PR, also a higher one', () => {
  const root = tempRoot();
  const id = newRun(root, 3);
  setLayer(root, id, 'l2', [['dependsOn', 'l3']]);
  let run = readRun(root, id).run;
  assert.deepEqual(waitsFor(run, 'l2'), ['l3']);
  assert.equal(nextLayer(run), 'l1');
  phase(root, id, 'l1', 'pr_open');
  assert.equal(nextLayer(readRun(root, id).run), 'l3', 'l2 waits for l3, so l3 goes first');
  phase(root, id, 'l3', 'pr_open');
  run = readRun(root, id).run;
  assert.equal(nextLayer(run), 'l2');
});

test('R5. unpark records the new head and the rebased last reviewed SHA', () => {
  const root = tempRoot();
  const id = newRun(root);
  setLayer(root, id, 'l1', [['phase', 'fixing'], ['round', '1'], ['baseTip', 'old-base'], ['head', 'old-head'], ['lastReviewed', 'old-rev']]);
  const { id: q } = park(root, id, 'l1', { question: 'q', tip: 'old-head' });
  answer(root, id, q, 'go');
  assert.match(cli(root, 'unpark', '--run', id, '--layer', 'l1', '--base', 'main', '--base-tip', 'nb', '--head', 'nh').stderr, /give --last-reviewed/);
  unpark(root, id, 'l1', { base: 'main', baseTip: 'nb', head: 'nh', lastReviewed: 'nr' });
  const l1 = readRun(root, id).run.layers[0];
  assert.deepEqual([l1.baseTip, l1.head, l1.lastReviewed], ['nb', 'nh', 'nr']);
});

test('R6. park with an empty tip writes no question', () => {
  const root = tempRoot();
  const id = newRun(root);
  phase(root, id, 'l1', 'review');
  assert.match(cli(root, 'park', '--run', id, '--layer', 'l1', '--question', 'scope?', '--tip', '').stderr, /tip is required/);
  assert.match(cli(root, 'park', '--run', id, '--layer', 'l1', '--question', 'scope?', '--option', '', '--tip', 't').stderr, /option is required/);
  assert.equal(readRun(root, id).questions.length, 0);
});

test('R7. list and init survive a run.json that parses but has the wrong shape', () => {
  const root = tempRoot();
  for (const [name, body] of [['2026-11-01-null', 'null'], ['2026-11-02-bare', '{"schema":1}'], ['2026-11-03-array', '[]'], ['2026-11-04-badlayers', '{"schema":1,"id":"x","state":"active","checkout":"/c","layers":[null]}']]) {
    mkdirSync(path.join(root, name));
    writeFileSync(path.join(root, name, 'run.json'), body);
  }
  const { runs, broken } = listRuns(root);
  assert.equal(runs.length, 0);
  assert.equal(broken.length, 4);
  assert.match(newRun(root), /undo-timeline/);
});

test('R2b. a lock whose process no longer runs is removed at once', () => {
  const root = tempRoot();
  const id = newRun(root);
  const gone = spawnSync(process.execPath, ['-e', '']).pid;
  writeFileSync(path.join(root, id, '.lock'), String(gone));
  const started = Date.now();
  assert.equal(cli(root, 'event', '--run', id, '--type', 'note', '--summary', 'after crash').code, 0);
  assert.ok(Date.now() - started < 2000, 'no wait for a dead owner');
  assert.equal(existsSync(path.join(root, id, '.lock')), false);
});

test('R7b. list reports a run.json whose layer has no dependsOn, and does not throw', () => {
  const root = tempRoot();
  const id = newRun(root, 2, { 2: [1] });
  const file = path.join(root, id, 'run.json');
  const run = JSON.parse(readFileSync(file, 'utf8'));
  delete run.layers[0].dependsOn;
  writeFileSync(file, JSON.stringify(run));
  const { runs, broken } = listRuns(root);
  assert.equal(runs.length, 0);
  assert.deepEqual(broken.map((b) => b.id), [id]);
  assert.match(broken[0].error, /no valid layers array/);
});

test('R9. setting a run active is refused while another run for the checkout is active', () => {
  const root = tempRoot();
  const a = newRun(root);
  setRun(root, a, [['state', 'paused']]);
  const b = newRun(root, 1, {}, { title: 'Second' });
  assert.match(cli(root, 'run', '--run', a, '--set', 'state=active').stderr, /run .*second is active/);
  setRun(root, b, [['state', 'finished']]);
  assert.equal(cli(root, 'run', '--run', a, '--set', 'state=active').code, 0);
});

test('R10. a parked layer stays in needs_input after the answer, until unpark', () => {
  const root = tempRoot();
  const id = newRun(root);
  phase(root, id, 'l1', 'review');
  const { id: q } = park(root, id, 'l1', { question: 'q', tip: 't' });
  answer(root, id, q, 'a');
  assert.equal(readRun(root, id).layers.find((l) => l.id === 'l1').column, 'needs_input');
});

test('R13. the checkout path is normalized in init and list', () => {
  const root = tempRoot();
  const id = newRun(root, 1, {}, { checkout: `${CHECKOUT}/` });
  assert.equal(readRun(root, id).run.checkout, CHECKOUT);
  assert.deepEqual(listRuns(root, { checkout: `${CHECKOUT}/./` }).runs.map((r) => r.id), [id]);
  assert.throws(() => newRun(root, 1, {}, { title: 'Again', checkout: `${CHECKOUT}//` }), /is active for this checkout/);
});

test('R8. a layer with a PR does not move when other fields change', () => {
  const root = tempRoot();
  const id = newRun(root, 3);
  phase(root, id, 'l1', 'pr_open');
  phase(root, id, 'l2', 'implementing');
  park(root, id, 'l2', { question: 'q', tip: 't' });
  phase(root, id, 'l3', 'pr_open');
  const order = () => readRun(root, id).layers.map((l) => l.id);
  const before = order();
  assert.deepEqual(before, ['l1', 'l3', 'l2']);
  setLayer(root, id, 'l1', [['head', 'new-head'], ['baseTip', 'new-base']]);
  assert.deepEqual(order(), before, 'a restack update of a low PR layer keeps the order');
});

test('R8. escalated stores a boolean, null clears a text field, and the finding round starts at 1', () => {
  const root = tempRoot();
  const id = newRun(root);
  setLayer(root, id, 'l1', [['escalated', 'true'], ['branch', 'fix/a']]);
  assert.equal(readRun(root, id).run.layers[0].escalated, true);
  setLayer(root, id, 'l1', [['escalated', 'false'], ['branch', 'null']]);
  assert.equal(readRun(root, id).run.layers[0].escalated, false);
  assert.equal(readRun(root, id).run.layers[0].branch, null);
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'escalated=yes').code, 1);
  assert.equal(cli(root, 'finding', '--run', id, '--layer', 'l1', '--round', '0', '--severity', 'nit', '--file', 'f', '--defect', 'd', '--expected-fix', 'x').code, 1);
});

test('R8. a merged layer is an anchor for placement and cannot park', () => {
  const root = tempRoot();
  const id = newRun(root, 3);
  phase(root, id, 'l1', 'merged');
  assert.match(cli(root, 'park', '--run', id, '--layer', 'l1', '--question', 'q', '--tip', 't').stderr, /never parked/);
  phase(root, id, 'l2', 'implementing');
  park(root, id, 'l2', { question: 'q', tip: 't' });
  phase(root, id, 'l3', 'implementing');
  assert.deepEqual(readRun(root, id).layers.map((l) => l.id), ['l1', 'l3', 'l2'], 'l3 starts directly above the merged l1');
});

test('R8. a phase change writes layer_phase, a state change writes state, other changes write *_update', () => {
  const root = tempRoot();
  const id = newRun(root);
  setLayer(root, id, 'l1', [['phase', 'implementing']]);
  setLayer(root, id, 'l1', [['head', 'h']]);
  setRun(root, id, [['state', 'paused']]);
  setRun(root, id, [['stage', 'layers']]);
  assert.deepEqual(readRun(root, id).events.slice(-4).map((e) => e.type), ['layer_phase', 'layer_update', 'state', 'run_update']);
});

test('R8. list ignores a folder whose name is not a run id, and slugs are cut at 40 characters', () => {
  const root = tempRoot();
  mkdirSync(path.join(root, 'scratch'));
  writeFileSync(path.join(root, 'scratch', 'run.json'), 'null');
  assert.deepEqual(listRuns(root), { runs: [], broken: [] });
  const slug = slugify('A very long title that goes on and on beyond forty characters');
  assert.ok(slug.length <= 40);
  assert.equal(slug.endsWith('-'), false);
});

// ── Skill gaps (simulation tests of 2026-11-14) ──────────────────────────────────────────────────

test('G13. layer plan: stored, validated, cleared, shown, and null for a run.json with no plan key', () => {
  const root = tempRoot();
  const id = newRun(root, 2);
  assert.equal(readRun(root, id).layers[0].plan, null);
  setLayer(root, id, 'l1', [['phase', 'implementing'], ['plan', 'plans/plan-undo-a.md']]);
  assert.equal(readRun(root, id).layers.find((l) => l.id === 'l1').plan, 'plans/plan-undo-a.md');
  assert.match(show(root, id), /plan plans\/plan-undo-a\.md/);
  assert.match(showLayer(root, id, 'l1'), /plan plans\/plan-undo-a\.md/);
  for (const bad of ['../x.md', '/abs.md', 'plans/A.md', 'plans/../run.md', 'plans/a.txt', 'other/a.md']) {
    assert.throws(() => setLayer(root, id, 'l1', [['plan', bad]]), /plan must match/, bad);
  }
  setLayer(root, id, 'l1', [['plan', 'null']]);
  assert.equal(readRun(root, id).layers.find((l) => l.id === 'l1').plan, null);
  const file = path.join(root, id, 'run.json');
  const run = JSON.parse(readFileSync(file, 'utf8'));
  for (const layer of run.layers) delete layer.plan;
  writeFileSync(file, JSON.stringify(run));
  assert.deepEqual(readRun(root, id).layers.map((l) => l.plan), [null, null]);
});

test('G15. finding: --expected-fix is optional, and show --layer leaves it out when absent', () => {
  const root = tempRoot();
  const id = newRun(root, 1);
  const out = cli(root, 'finding', '--run', id, '--layer', 'l1', '--round', '1', '--severity', 'should_fix', '--file', 'src/a.ts', '--defect', 'drops notes');
  assert.equal(out.code, 0, out.stderr);
  const [finding] = readRun(root, id).findings.l1;
  assert.equal(finding.expectedFix, null);
  assert.doesNotMatch(showLayer(root, id, 'l1'), /expected:/);
  assert.throws(() => addFinding(root, id, 'l1', { round: 1, severity: 'nit', file: 'a', defect: 'd', expectedFix: '  ' }), /expected-fix cannot be empty/);
});

test('G5. nextStep=null clears the next step', () => {
  const root = tempRoot();
  const id = newRun(root, 1);
  setRun(root, id, [['nextStep', 'merge after the yes']]);
  setRun(root, id, [['nextStep', 'null']]);
  assert.equal(readRun(root, id).run.nextStep, null);
  assert.match(show(root, id), /next step: \(not recorded\)/);
});

/** Every file of a run folder with its text, to prove that a refused write changed nothing. */
function snapshot(dir) {
  const files = {};
  const walk = (sub) => {
    for (const name of readdirSync(path.join(dir, sub), { withFileTypes: true })) {
      const rel = path.join(sub, name.name);
      if (name.isDirectory()) walk(rel);
      else if (name.name !== '.lock') files[rel] = readFileSync(path.join(dir, rel), 'utf8');
    }
  };
  walk('');
  return files;
}

test('G26. a finished run refuses every write, except a reopen, a merge of an open PR, a merge event, a filed follow-up and an answer', () => {
  const root = tempRoot();
  const id = newRun(root, 3);
  phase(root, id, 'l1', 'implementing');
  setLayer(root, id, 'l1', [['phase', 'pr_open'], ['pr', '501']]);
  phase(root, id, 'l2', 'implementing');
  const { id: f1 } = addFinding(root, id, 'l2', { round: 1, severity: 'nit', file: 'a', defect: 'd' });
  cli(root, 'followup', '--run', id, '--layer', 'l1', '--title', 't', '--body', 'b');
  const { id: q1 } = ask(root, id, { layer: 'l2', question: 'still open?', options: ['a', 'b'] });
  setRun(root, id, [['state', 'finished']]);
  const dir = path.join(root, id);
  const before = snapshot(dir);
  const refused = [
    ['layer', '--run', id, '--layer', 'l2', '--set', 'round=1'],
    ['layer', '--run', id, '--layer', 'l1', '--set', 'phase=merged', '--set', 'head=x'],
    // A merge record needs an open PR: l3 is queued with no PR (it would also move positions).
    ['layer', '--run', id, '--layer', 'l3', '--set', 'phase=merged'],
    ['run', '--run', id, '--set', 'nextStep=x'],
    ['run', '--run', id, '--set', 'state=finished'],
    ['decision', '--run', id, '--question', 'q', '--answer', 'a'],
    ['event', '--run', id, '--type', 'note', '--summary', 'x'],
    ['ask', '--run', id, '--question', 'q?'],
    ['park', '--run', id, '--layer', 'l2', '--question', 'q', '--tip', 't'],
    ['unpark', '--run', id, '--layer', 'l2', '--base', 'b', '--base-tip', 't', '--head', 'h'],
    ['finding', '--run', id, '--layer', 'l2', '--round', '1', '--severity', 'nit', '--file', 'a', '--defect', 'd'],
    ['rule', '--run', id, '--layer', 'l2', '--id', f1, '--ruling', 'closed', '--reason', 'r'],
    ['resolve', '--run', id, '--layer', 'l2', '--id', f1, '--state', 'fixed'],
    ['followup', '--run', id, '--title', 't', '--body', 'b'],
  ];
  for (const args of refused) {
    const out = cli(root, ...args);
    assert.equal(out.code, 1, args.join(' '));
    assert.match(out.stderr, /finished; reopen it first/, args.join(' '));
  }
  assert.deepEqual(snapshot(dir), before);
  // The writes that can come after the end:
  setLayer(root, id, 'l1', [['phase', 'merged']]);
  assert.equal(cli(root, 'event', '--run', id, '--layer', 'l1', '--type', 'merge', '--summary', '#501').code, 0);
  assert.equal(cli(root, 'followup-filed', '--run', id, '--id', 'fu1', '--issue', '77').code, 0);
  assert.equal(cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'a').code, 0);
  const state = readRun(root, id);
  assert.equal(state.layers.find((l) => l.id === 'l1').phase, 'merged');
  assert.deepEqual(state.layers.map((l) => [l.id, l.position]), [['l1', 1], ['l2', 2], ['l3', 3]]);
  assert.equal(state.openQuestions.length, 0);
  // A reopen to active is refused while another run for the checkout is active.
  const other = initRun(root, { title: 'Other', checkout: CHECKOUT, request: 'r', layers: layers(1), date: '2026-11-07' }).id;
  assert.throws(() => setRun(root, id, [['state', 'active']]), new RegExp(`run ${other} is active`));
  assert.equal(readRun(root, id).run.state, 'finished');
  // A reopen to paused works, and with it the other writes.
  setRun(root, id, [['state', 'paused'], ['nextStep', 'l3 starts']]);
  setLayer(root, id, 'l3', [['phase', 'implementing']]);
  assert.equal(readRun(root, id).run.state, 'paused');
});

// ── Tasks runs : independent tasks, each PR on main ─────────────────────────────────

function newTasksRun(root, n = 3, extra = {}) {
  return newRun(root, n, {}, { title: 'Small fixes', kind: 'tasks', ...extra });
}

test('T1. init --kind tasks stores the kind; a run with no kind reads as a stack run', () => {
  const root = tempRoot();
  const one = newTasksRun(root, 1);
  assert.equal(readRun(root, one).run.kind, 'tasks');
  assert.match(readFileSync(path.join(root, one, 'events.jsonl'), 'utf8'), /1 task: Small fixes/);
  setRun(root, one, [['state', 'paused']]);
  const three = newTasksRun(root, 3);
  assert.equal(readRun(root, three).layers.length, 3);
  setRun(root, three, [['state', 'paused']]);

  const stack = newRun(root);
  const file = path.join(root, stack, 'run.json');
  const raw = JSON.parse(readFileSync(file, 'utf8'));
  assert.equal(raw.kind, 'stack');
  delete raw.kind;
  writeFileSync(file, JSON.stringify(raw));
  assert.equal(readRun(root, stack).run.kind, 'stack');
  assert.match(show(root, stack), /^run \S+ \[stack, active/);
  const listed = listRuns(root).runs.map((r) => [r.id, r.kind]);
  // `list` sorts by run id.
  assert.deepEqual(listed, [
    [one, 'tasks'],
    [three, 'tasks'],
    [stack, 'stack'],
  ]);
});

test('T2. init refuses an unknown kind, and a tasks run with a dependsOn', () => {
  const root = tempRoot();
  assert.throws(() => newRun(root, 2, {}, { kind: 'queue' }), /kind must be one of stack, tasks/);
  assert.throws(() => newRun(root, 2, { 2: [1] }, { kind: 'tasks' }), /dependsOn may name only report tasks/);
  assert.deepEqual(readdirSync(root), []);
});

test('T3. the CLI init takes --kind tasks', () => {
  const root = tempRoot();
  const request = path.join(root, 'request.txt');
  const layersFile = path.join(root, 'layers.json');
  writeFileSync(request, 'two small fixes');
  writeFileSync(layersFile, JSON.stringify(layers(2)));
  const out = cli(root, 'init', '--kind', 'tasks', '--title', 'Two fixes', '--checkout', CHECKOUT, '--request-file', request, '--layers-file', layersFile);
  assert.equal(out.code, 0, out.stderr);
  const { id } = JSON.parse(out.stdout);
  assert.equal(readRun(root, id).run.kind, 'tasks');
  assert.match(cli(root, 'show', '--run', id).stdout, /tasks \(work order\):/);
});

test('T4. a tasks run refuses the stack-only commands, and run.json does not change', () => {
  const root = tempRoot();
  const id = newTasksRun(root);
  const file = path.join(root, id, 'run.json');
  const before = readFileSync(file, 'utf8');
  for (const args of [
    ['run', '--run', id, '--set', 'stack=12'],
    ['run', '--run', id, '--set', 'stage=restack'],
    ['run', '--run', id, '--set', 'ciPr=12'],
    ['run', '--run', id, '--set', 'ciResult=pass'],
  ]) {
    const out = cli(root, ...args);
    assert.equal(out.code, 1, args.join(' '));
    assert.match(out.stderr, /is a tasks run: .* applies to a stack run only/, args.join(' '));
  }
  // A task can wait only for a report task, and l1 is a pr task.
  assert.match(cli(root, 'layer', '--run', id, '--layer', 'l2', '--set', 'dependsOn=l1').stderr, /dependsOn may name only report tasks/);
  assert.equal(readFileSync(file, 'utf8'), before);
  // The stages a tasks run uses, and an empty dependsOn, still work.
  assert.equal(cli(root, 'run', '--run', id, '--set', 'stage=layers').code, 0);
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l2', '--set', 'dependsOn=').code, 0);
});

test('T5. a stack run refuses the CI keys of a task', () => {
  const root = tempRoot();
  const id = newRun(root);
  assert.match(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'ciRunUrl=https://x').stderr, /applies to a tasks run only/);
  assert.equal(readRun(root, id).layers[0].ci, null);
});

test('T6. each task has its own CI: ciRunUrl starts it pending, ciResult needs it first, show prints it', () => {
  const root = tempRoot();
  const id = newTasksRun(root, 2);
  assert.match(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'ciResult=pass').stderr, /set ciRunUrl before ciResult/);
  setLayer(root, id, 'l1', [['ciRunUrl', 'https://github.com/o/r/actions/runs/1']]);
  assert.deepEqual(readRun(root, id).layers.find((l) => l.id === 'l1').ci, { runUrl: 'https://github.com/o/r/actions/runs/1', result: 'pending' });
  setLayer(root, id, 'l1', [['ciResult', 'fail']]);
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'ciResult=green').code, 1);
  // A new CI run resets the result.
  setLayer(root, id, 'l1', [['ciRunUrl', 'https://github.com/o/r/actions/runs/2']]);
  const l1 = readRun(root, id).layers.find((l) => l.id === 'l1');
  assert.deepEqual(l1.ci, { runUrl: 'https://github.com/o/r/actions/runs/2', result: 'pending' });
  assert.equal(readRun(root, id).layers.find((l) => l.id === 'l2').ci, null);
  assert.match(show(root, id), /l1 .*ci pending https:\/\/github.com\/o\/r\/actions\/runs\/2/);
  assert.match(showLayer(root, id, 'l1'), /^ci pending https:\/\/github.com\/o\/r\/actions\/runs\/2$/m);
  // The CI events take a task.
  assert.equal(cli(root, 'event', '--run', id, '--layer', 'l1', '--type', 'ci_result', '--summary', 'fail').code, 0);
});

test('T7. a parked task does not block the next task', () => {
  const root = tempRoot();
  const id = newTasksRun(root, 3);
  phase(root, id, 'l1', 'implementing');
  park(root, id, 'l1', { question: 'Widen the scope?', options: ['yes', 'no'], tip: 'abc' });
  assert.equal(nextLayer(readRun(root, id).run), 'l2');
  phase(root, id, 'l2', 'implementing');
  phase(root, id, 'l2', 'pr_open');
  assert.equal(nextLayer(readRun(root, id).run), 'l3');
});

test('T8. more changes: a task goes from pr_open back to fixing and to pr_open again', () => {
  const root = tempRoot();
  const id = newTasksRun(root, 1);
  phase(root, id, 'l1', 'implementing');
  setLayer(root, id, 'l1', [['phase', 'pr_open'], ['pr', '901']]);
  setRun(root, id, [['state', 'paused'], ['stage', 'finish']]);
  setRun(root, id, [['state', 'active']]);
  phase(root, id, 'l1', 'fixing');
  assert.equal(readRun(root, id).layers[0].column, 'in_progress');
  phase(root, id, 'l1', 'review');
  phase(root, id, 'l1', 'pr_open');
  assert.equal(readRun(root, id).layers[0].column, 'done');
  // After a finish, a reopen to paused allows the same flow.
  setRun(root, id, [['state', 'finished']]);
  assert.throws(() => phase(root, id, 'l1', 'fixing'), /is finished/);
  setRun(root, id, [['state', 'paused']]);
  phase(root, id, 'l1', 'fixing');
});

test('T9. a run.json with an unknown kind is reported as broken', () => {
  const root = tempRoot();
  const id = newTasksRun(root);
  const file = path.join(root, id, 'run.json');
  writeFileSync(file, JSON.stringify({ ...JSON.parse(readFileSync(file, 'utf8')), kind: 'queue' }));
  assert.match(listRuns(root).broken[0].error, /unknown kind "queue"/);
});

// ── Main plans: a plan document that the user gave as a source ──────────────────────────────────

test('M1. main-plan copies a plan document to plans/main-<slug>.md, records it, and show prints it', () => {
  for (const kind of ['stack', 'tasks']) {
    const root = tempRoot();
    const id = newRun(root, 2, {}, { kind });
    const docs = mkdtempSync(path.join(tmpdir(), 'plan-doc-'));
    const source = path.join(docs, 'Window_Arrange-controls-plan.md');
    writeFileSync(source, '# Window arrange plan\n');
    const out = cli(root, 'main-plan', '--run', id, '--file', source);
    assert.equal(out.code, 0, out.stderr);
    assert.deepEqual(JSON.parse(out.stdout), { path: 'plans/main-window-arrange-controls-plan.md', copied: true });
    assert.equal(readFileSync(path.join(root, id, 'plans', 'main-window-arrange-controls-plan.md'), 'utf8'), '# Window arrange plan\n');
    const { mainPlans } = readRun(root, id).run;
    assert.equal(mainPlans.length, 1);
    assert.equal(mainPlans[0].source, source);
    assert.match(mainPlans[0].copied, ISO);
    assert.match(show(root, id), /main plan: plans\/main-window-arrange-controls-plan\.md \(from .*Window_Arrange-controls-plan\.md\)/);
    assert.match(readFileSync(path.join(root, id, 'events.jsonl'), 'utf8'), /"type":"main_plan"/);
  }
});

test('M2. the same text is copied one time; a different text with the same name gets -2', () => {
  const root = tempRoot();
  const id = newRun(root);
  const docs = mkdtempSync(path.join(tmpdir(), 'plan-doc-'));
  const source = path.join(docs, 'undo-plan.md');
  writeFileSync(source, 'v1');
  assert.equal(JSON.parse(cli(root, 'main-plan', '--run', id, '--file', source).stdout).copied, true);
  const again = JSON.parse(cli(root, 'main-plan', '--run', id, '--file', source).stdout);
  assert.deepEqual(again, { path: 'plans/main-undo-plan.md', copied: false });
  writeFileSync(source, 'v2');
  assert.equal(JSON.parse(cli(root, 'main-plan', '--run', id, '--file', source).stdout).path, 'plans/main-undo-plan-2.md');
  assert.deepEqual(readRun(root, id).run.mainPlans.map((p) => p.path), ['plans/main-undo-plan.md', 'plans/main-undo-plan-2.md']);
});

test('M3. main-plan refuses a file that is missing or not .md, and a finished run; old runs read as no main plans', () => {
  const root = tempRoot();
  const id = newRun(root);
  assert.equal(readRun(root, id).run.mainPlans.length, 0);
  const docs = mkdtempSync(path.join(tmpdir(), 'plan-doc-'));
  writeFileSync(path.join(docs, 'notes.txt'), 'x');
  assert.match(cli(root, 'main-plan', '--run', id, '--file', path.join(docs, 'notes.txt')).stderr, /must be a \.md file/);
  assert.match(cli(root, 'main-plan', '--run', id, '--file', path.join(docs, 'gone.md')).stderr, /cannot read the plan document/);
  mkdirSync(path.join(docs, 'dir.md'));
  assert.match(cli(root, 'main-plan', '--run', id, '--file', path.join(docs, 'dir.md')).stderr, /not a file/);
  assert.equal(readRun(root, id).run.mainPlans.length, 0);
  writeFileSync(path.join(docs, 'late-plan.md'), 'x');
  setRun(root, id, [['state', 'finished']]);
  assert.match(cli(root, 'main-plan', '--run', id, '--file', path.join(docs, 'late-plan.md')).stderr, /is finished/);
});

// ── The runs root ───────────────────────────────────────────────────────────────────────────────

test('resolveRoot: $TASK_MANAGER_RUNS wins; the default is ~/.task-manager/runs, outside every clone', async () => {
  const { resolveRoot } = await import('../lib/task-manager-core.mjs');
  const { homedir } = await import('node:os');
  assert.equal(resolveRoot({ TASK_MANAGER_RUNS: '/some/where' }), '/some/where');
  assert.equal(resolveRoot({}), path.join(homedir(), '.task-manager', 'runs'));
  // An empty value is not a root: a run folder must never land in the current directory.
  assert.equal(resolveRoot({ TASK_MANAGER_RUNS: '' }), path.join(homedir(), '.task-manager', 'runs'));
});

// ── Outcomes: a pr layer ends as a PR, a report layer ends as a report file ─────────────────────

function mixedRun(root, kind = 'tasks') {
  const entry = (task, extra = {}) => ({ task, source: 'request', tier: 'M', tierReason: 'r', dependsOn: [], ...extra });
  return initRun(root, {
    title: 'Slow export',
    checkout: CHECKOUT,
    request: 'find the cause, then fix it',
    kind,
    date: '2026-11-16',
    layers: [entry('find the cause of the slow export', { outcome: 'report' }), entry('fix the slow export', { dependsOn: [1] })],
  }).id;
}

test('O1. init records the outcome, defaults to pr, and refuses an unknown outcome', () => {
  const root = tempRoot();
  const id = mixedRun(root);
  const { run } = readRun(root, id);
  assert.deepEqual(run.layers.map((l) => [l.id, l.outcome, l.report]), [['l1', 'report', null], ['l2', 'pr', null]]);
  assert.equal(existsSync(path.join(root, id, 'reports')), true);
  const other = tempRoot();
  assert.equal(readRun(other, newRun(other)).run.layers[0].outcome, 'pr');
  const bad = [{ task: 't', source: 's', tier: 'S', tierReason: 'r', outcome: 'essay' }];
  assert.throws(() => initRun(tempRoot(), { title: 'x', checkout: CHECKOUT, request: 'r', layers: bad }), /outcome must be one of pr, report/);
});

test('O2. in a tasks run, a pr task can wait for a report task: it is next only after the report is delivered', () => {
  const root = tempRoot();
  const id = mixedRun(root);
  const set = (layer, ...pairs) => cli(root, 'layer', '--run', id, '--layer', layer, ...pairs.flatMap((p) => ['--set', p]));
  assert.equal(readRun(root, id).next, 'l1');
  assert.equal(set('l1', 'phase=implementing').code, 0);
  assert.equal(readRun(root, id).next, null, 'l2 waits for the report');
  assert.equal(set('l1', 'phase=review', 'round=1').code, 0);
  // Delivery needs the report path, and the file itself.
  assert.match(set('l1', 'phase=delivered').stderr, /set report=reports\/report-<slug>.md before phase=delivered/);
  assert.match(set('l1', 'report=../../etc/passwd').stderr, /report must match reports\/report-<slug>.md/);
  assert.match(set('l1', 'report=reports/report-slow-export.md', 'phase=delivered').stderr, /does not exist in the run folder/);
  writeFileSync(path.join(root, id, 'reports', 'report-slow-export.md'), '# Cause\n');
  assert.equal(set('l1', 'report=reports/report-slow-export.md', 'phase=delivered').code, 0);
  const state = readRun(root, id);
  assert.equal(state.layers.find((l) => l.id === 'l1').column, 'done');
  assert.equal(state.next, 'l2');
  assert.match(cli(root, 'show', '--run', id).stdout, /l1 \[done\] delivered .*report reports\/report-slow-export.md/);
});

test('O3. a report layer has no PR and no PR phase; a pr layer has no report and is never delivered', () => {
  const root = tempRoot();
  const id = mixedRun(root);
  const file = path.join(root, id, 'run.json');
  const before = readFileSync(file, 'utf8');
  const set = (layer, pair) => cli(root, 'layer', '--run', id, '--layer', layer, '--set', pair);
  for (const phase of ['final_checks', 'opening_pr', 'pr_open', 'merged']) {
    assert.match(set('l1', `phase=${phase}`).stderr, /is a report layer: it has no phase/, phase);
  }
  assert.match(set('l1', 'pr=12').stderr, /is a report layer: it has no PR/);
  assert.match(set('l2', 'phase=delivered').stderr, /is a pr layer: it ends at merged/);
  assert.match(set('l2', 'report=reports/report-x.md').stderr, /is a pr layer: it has no report/);
  assert.equal(readFileSync(file, 'utf8'), before);
  // The outcome can change only before the layer starts.
  assert.equal(set('l2', 'outcome=report').code, 0);
  assert.equal(set('l2', 'phase=implementing').code, 0);
  assert.match(set('l2', 'outcome=pr').stderr, /can change only while it is queued/);
});

test('O4. a run made before the outcome key existed reads as pr layers', () => {
  const root = tempRoot();
  const id = newRun(root, 2);
  const file = path.join(root, id, 'run.json');
  const run = JSON.parse(readFileSync(file, 'utf8'));
  for (const l of run.layers) {
    delete l.outcome;
    delete l.report;
  }
  writeFileSync(file, JSON.stringify(run));
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'phase=pr_open').code, 0);
  assert.match(cli(root, 'layer', '--run', id, '--layer', 'l2', '--set', 'phase=delivered').stderr, /is a pr layer/);
});

// ── Answers from the admin page, session-only questions, and wait ───────────────────────────────

test('A1. an answer records where it came from; a session-only question refuses the admin page', () => {
  const root = tempRoot();
  const id = newRun(root);
  const q1 = JSON.parse(cli(root, 'ask', '--run', id, '--layer', 'l1', '--question', 'Per chapter or per window?', '--option', 'Per chapter', '--option', 'Per window').stdout).id;
  const merge = JSON.parse(cli(root, 'ask', '--run', id, '--question', 'Merge the stack?', '--session-only').stdout).id;
  assert.match(cli(root, 'show', '--run', id).stdout, new RegExp(`${merge} \\(run\\) \\[session only\\]: Merge the stack\\?`));

  assert.equal(cli(root, 'answer', '--run', id, '--id', q1, '--answer=Per window — keep the old key', '--via', 'dashboard').code, 0);
  const refused = cli(root, 'answer', '--run', id, '--id', merge, '--answer', 'yes', '--via', 'dashboard');
  assert.equal(refused.code, 1);
  assert.match(refused.stderr, /takes an answer in the session only/);
  assert.match(cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'x', '--via', 'email').stderr, /via must be one of session, dashboard/);

  let questions = readRun(root, id).questions;
  assert.deepEqual(questions.map((q) => [q.id, q.answer, q.via ?? null, q.sessionOnly]), [[q1, 'Per window — keep the old key', 'dashboard', false], [merge, null, null, true]]);
  const events = readFileSync(path.join(root, id, 'events.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.match(events.at(-1).summary, /Per window — keep the old key \(from the admin page\)$/);

  // The session can answer it, and that is the default source.
  assert.equal(cli(root, 'answer', '--run', id, '--id', merge, '--answer', 'yes, top is #12').code, 0);
  questions = readRun(root, id).questions;
  assert.equal(questions.find((q) => q.id === merge).via, 'session');
});

test('A2. wait ends when an open question gets an answer, and says which one', async () => {
  const { waitForAnswer } = await import('../lib/task-manager-core.mjs');
  const root = tempRoot();
  const id = newRun(root);
  // No open question: it ends at once.
  assert.deepEqual(await waitForAnswer(root, id, { pollMs: 5 }), { answered: [], reason: 'no_open_question' });

  const q1 = JSON.parse(cli(root, 'ask', '--run', id, '--layer', 'l2', '--question', 'A or B?', '--option', 'A', '--option', 'B').stdout).id;
  // Still open: it waits, then the timeout ends it.
  assert.deepEqual(await waitForAnswer(root, id, { pollMs: 5, timeoutMs: 30 }), { answered: [], reason: 'timeout' });

  const waiting = waitForAnswer(root, id, { pollMs: 5, timeoutMs: 5000 });
  setTimeout(() => cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'B', '--via', 'dashboard'), 20);
  assert.deepEqual(await waiting, { answered: [{ id: q1, layer: 'l2', answer: 'B', via: 'dashboard' }], reason: 'answered' });

  // A finished run ends the wait, also with a question still open.
  cli(root, 'ask', '--run', id, '--question', 'Which follow-ups?');
  cli(root, 'run', '--run', id, '--set', 'state=finished');
  assert.deepEqual(await waitForAnswer(root, id, { pollMs: 5, timeoutMs: 5000 }), { answered: [], reason: 'run_finished' });
});

test('A3. the wait command of the CLI prints the answer and exits 0; a bad run id exits 1', async () => {
  const root = tempRoot();
  const id = newRun(root);
  const q1 = JSON.parse(cli(root, 'ask', '--run', id, '--question', 'A or B?').stdout).id;
  const child = spawn(process.execPath, [CLI, 'wait', '--run', id, '--timeout', '20'], { env: { ...process.env, TASK_MANAGER_RUNS: root } });
  let out = '';
  child.stdout.on('data', (chunk) => (out += chunk));
  setTimeout(() => cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'A'), 100);
  const code = await new Promise((done) => child.on('close', done));
  assert.equal(code, 0);
  assert.deepEqual(JSON.parse(out), { answered: [{ id: q1, layer: null, answer: 'A', via: 'session' }], reason: 'answered' });

  const bad = spawnSync(process.execPath, [CLI, 'wait', '--run', '../x'], { env: { ...process.env, TASK_MANAGER_RUNS: root }, encoding: 'utf8' });
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /invalid run id/);
});
