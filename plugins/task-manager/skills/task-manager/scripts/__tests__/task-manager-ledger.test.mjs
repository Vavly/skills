import { strict as assert } from 'node:assert';
import { spawn, spawnSync } from 'node:child_process';
import * as fsForSnapshot from 'node:fs';
import { appendFileSync, chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, utimesSync, writeFileSync } from 'node:fs';
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
  assert.deepEqual(JSON.parse(cli(root, 'next', '--run', id).stdout), { next: null, ready: [], working: [], parallel: 1 });
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
  setRun(root, id, [['state', 'paused'], ['nextStep', 'l2 continues']]);
  setLayer(root, id, 'l2', [['round', '1']]);
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
  // An answer from the admin page reaches the wait also when it comes before the child reads the
  // questions, so a slow start of the child cannot make this test fail.
  setTimeout(() => cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'A', '--via', 'dashboard'), 100);
  const code = await new Promise((done) => child.on('close', done));
  assert.equal(code, 0);
  assert.deepEqual(JSON.parse(out), { answered: [{ id: q1, layer: null, answer: 'A', via: 'dashboard' }], reason: 'answered' });

  const bad = spawnSync(process.execPath, [CLI, 'wait', '--run', '../x'], { env: { ...process.env, TASK_MANAGER_RUNS: root }, encoding: 'utf8' });
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /invalid run id/);
});

test('A4. [review] wait also sees a question that was asked after the wait started', async () => {
  const { waitForAnswer } = await import('../lib/task-manager-core.mjs');
  const root = tempRoot();
  const id = newRun(root);
  const ask = (...args) => JSON.parse(cli(root, 'ask', '--run', id, ...args).stdout).id;
  const q1 = ask('--layer', 'l1', '--question', 'first?');
  const waiting = waitForAnswer(root, id, { pollMs: 5, timeoutMs: 5000 });
  // Two layers park one after the other: the second question comes while the watcher runs.
  await new Promise((done) => setTimeout(done, 30));
  const q2 = ask('--layer', 'l2', '--question', 'second?');
  await new Promise((done) => setTimeout(done, 30));
  cli(root, 'answer', '--run', id, '--id', q2, '--answer', 'yes', '--via', 'dashboard');
  assert.deepEqual(await waiting, { answered: [{ id: q2, layer: 'l2', answer: 'yes', via: 'dashboard' }], reason: 'answered' });
  assert.equal(readRun(root, id).openQuestions.map((q) => q.id).join(), q1);
});

test('A7. [review] a session answer to a question that was asked after the wait started ends the wait', async () => {
  const { waitForAnswer } = await import('../lib/task-manager-core.mjs');
  const root = tempRoot();
  const id = newRun(root);
  const ask = (...args) => JSON.parse(cli(root, 'ask', '--run', id, ...args).stdout).id;
  ask('--layer', 'l1', '--question', 'first?');
  const waiting = waitForAnswer(root, id, { pollMs: 5, timeoutMs: 5000 });
  await new Promise((done) => setTimeout(done, 30));
  const q2 = ask('--layer', 'l2', '--question', 'second?');
  await new Promise((done) => setTimeout(done, 30));
  // Only a wait that reads the open questions again knows q2: a session answer has no other path.
  cli(root, 'answer', '--run', id, '--id', q2, '--answer', 'yes');
  assert.deepEqual(await waiting, { answered: [{ id: q2, layer: 'l2', answer: 'yes', via: 'session' }], reason: 'answered' });
});

test('A8. [review] two waits on one run give an admin-page answer one time in total', async () => {
  const { waitForAnswer } = await import('../lib/task-manager-core.mjs');
  const root = tempRoot();
  const id = newRun(root);
  const q1 = JSON.parse(cli(root, 'ask', '--run', id, '--question', 'A or B?').stdout).id;
  const waits = [waitForAnswer(root, id, { pollMs: 5, timeoutMs: 5000 }), waitForAnswer(root, id, { pollMs: 7, timeoutMs: 5000 })];
  await new Promise((done) => setTimeout(done, 30));
  cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'A', '--via', 'dashboard');
  const results = await Promise.all(waits);
  assert.deepEqual(results.map((r) => r.answered.length).sort(), [0, 1]);
  assert.equal(results.find((r) => r.answered.length === 0).reason, 'no_open_question');
});

test('A9. [review] wait processes that start together give an admin-page answer one time in total', async () => {
  const root = tempRoot();
  const id = newRun(root);
  const q1 = JSON.parse(cli(root, 'ask', '--run', id, '--question', 'A or B?').stdout).id;
  cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'A', '--via', 'dashboard');
  // Separate processes, so the read and the mark of one can come between those of another. Only
  // the run lock, with a second read inside it, keeps the answer to one process.
  const outputs = await Promise.all(
    Array.from({ length: 12 }, () => {
      const child = spawn(process.execPath, [CLI, 'wait', '--run', id, '--timeout', '20'], { env: { ...process.env, TASK_MANAGER_RUNS: root } });
      let out = '';
      child.stdout.on('data', (chunk) => (out += chunk));
      return new Promise((done) => child.on('close', () => done(JSON.parse(out))));
    }),
  );
  assert.equal(outputs.filter((o) => o.answered.length === 1).length, 1);
  assert.equal(outputs.filter((o) => o.reason === 'no_open_question').length, 11);
});

test('A5. [review] an admin-page answer that came before the wait started is given one time, not lost and not repeated', async () => {
  const { waitForAnswer } = await import('../lib/task-manager-core.mjs');
  const root = tempRoot();
  const id = newRun(root);
  const q1 = JSON.parse(cli(root, 'ask', '--run', id, '--question', 'A or B?').stdout).id;
  // The user is faster than the session: the answer is there before `wait` starts.
  cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'B', '--via', 'dashboard');
  assert.deepEqual(await waitForAnswer(root, id, { pollMs: 5, timeoutMs: 5000 }), { answered: [{ id: q1, layer: null, answer: 'B', via: 'dashboard' }], reason: 'answered' });
  // The next wait does not give it again, and the answer itself is unchanged.
  assert.deepEqual(await waitForAnswer(root, id, { pollMs: 5, timeoutMs: 5000 }), { answered: [], reason: 'no_open_question' });
  const saved = readRun(root, id).questions.find((q) => q.id === q1);
  assert.deepEqual([saved.answer, saved.via, saved.delivered], ['B', 'dashboard', true]);
  // A session answer that came before the wait is not news to the session: nothing to give.
  const q2 = JSON.parse(cli(root, 'ask', '--run', id, '--question', 'C or D?').stdout).id;
  cli(root, 'answer', '--run', id, '--id', q2, '--answer', 'C');
  assert.deepEqual(await waitForAnswer(root, id, { pollMs: 5, timeoutMs: 5000 }), { answered: [], reason: 'no_open_question' });
});

test('O5. [review] in a tasks run, a report task that another task waits for cannot become a pr task', () => {
  const root = tempRoot();
  const id = mixedRun(root);
  const file = path.join(root, id, 'run.json');
  const before = readFileSync(file, 'utf8');
  const out = cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'outcome=pr');
  assert.equal(out.code, 1);
  assert.match(out.stderr, /l2 depends on l1: in a tasks run, a task can wait only for a report task/);
  assert.equal(readFileSync(file, 'utf8'), before);
  // With no task that waits for it, the change is permitted. In a stack run it is always permitted.
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l2', '--set', 'dependsOn=').code, 0);
  assert.equal(cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'outcome=pr').code, 0);
  const stackRoot = tempRoot();
  const stack = mixedRun(stackRoot, 'stack');
  assert.equal(cli(stackRoot, 'layer', '--run', stack, '--layer', 'l1', '--set', 'outcome=pr').code, 0);
});

test('[review] the runs root must be absolute: a relative value is refused, and ~ is expanded', async () => {
  const { resolveRoot } = await import('../lib/task-manager-core.mjs');
  const { homedir } = await import('node:os');
  assert.equal(resolveRoot({ TASK_MANAGER_RUNS: '~/my-runs' }), path.join(homedir(), 'my-runs'));
  assert.throws(() => resolveRoot({ TASK_MANAGER_RUNS: 'runs' }), /TASK_MANAGER_RUNS must be an absolute path/);
  // The CLI reports it as an input error.
  const out = main(['list'], { TASK_MANAGER_RUNS: 'runs' });
  assert.equal(out.code, 1);
  assert.match(out.stderr, /must be an absolute path/);
});

test('A6. [review] a layer can park on a session-only question, and the admin page cannot answer it', () => {
  const root = tempRoot();
  const id = newRun(root);
  cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'phase=implementing');
  const out = cli(root, 'park', '--run', id, '--layer', 'l1', '--question', 'Deploy the fix to staging?', '--session-only', '--tip', 'a'.repeat(40));
  assert.equal(out.code, 0, out.stderr);
  const q = readRun(root, id).openQuestions[0];
  assert.equal(q.sessionOnly, true);
  assert.match(cli(root, 'answer', '--run', id, '--id', q.id, '--answer', 'yes', '--via', 'dashboard').stderr, /in the session only/);
  assert.equal(cli(root, 'answer', '--run', id, '--id', q.id, '--answer', 'yes').code, 0);
});

// ── Notifications ────────────────────────────────────────────────────────────────────────────────

/** Settings whose command appends each event, as one JSON line, to a file in the root. */
function notifyRoot(extra = {}) {
  const root = tempRoot();
  const log = path.join(root, 'sent.jsonl');
  writeFileSync(path.join(root, 'config.json'), JSON.stringify({ notify: { command: `cat >> "${log}"`, ...extra } }));
  return { root, log };
}

/** The sender is a detached process: wait until it wrote `count` lines. */
async function sentEvents(log, count) {
  for (let i = 0; i < 200; i += 1) {
    const lines = existsSync(log) ? readFileSync(log, 'utf8').trim().split('\n').filter(Boolean) : [];
    if (lines.length >= count) return lines.map((line) => JSON.parse(line));
    await new Promise((done) => setTimeout(done, 25));
  }
  throw new Error(`fewer than ${count} notifications after 5 s`);
}

test('N1. a new question, a paused run and a finished run each send one notification', async () => {
  const { root, log } = notifyRoot();
  const id = newRun(root);
  const q1 = JSON.parse(cli(root, 'ask', '--run', id, '--layer', 'l1', '--question', 'A or B?', '--session-only').stdout).id;
  assert.deepEqual(await sentEvents(log, 1), [{ type: 'question', run: id, title: 'Undo timeline', layer: 'l1', questionId: q1, text: 'A or B?', sessionOnly: true }]);
  cli(root, 'layer', '--run', id, '--layer', 'l2', '--set', 'phase=implementing');
  cli(root, 'park', '--run', id, '--layer', 'l2', '--question', 'C or D?', '--tip', 'a'.repeat(40));
  assert.deepEqual((await sentEvents(log, 2))[1].text, 'C or D?');
  cli(root, 'run', '--run', id, '--set', 'state=paused', '--set', 'nextStep=waits for the user');
  assert.deepEqual((await sentEvents(log, 3))[2], { type: 'paused', run: id, title: 'Undo timeline', layer: null, text: 'waits for the user' });
  cli(root, 'run', '--run', id, '--set', 'state=finished', '--set', 'nextStep=null');
  assert.deepEqual((await sentEvents(log, 4))[3], { type: 'finished', run: id, title: 'Undo timeline', layer: null, text: null });
});

test('N2. a park on a question that was asked earlier, an answer and a stage change send nothing', async () => {
  const { root, log } = notifyRoot();
  const id = newRun(root);
  const q1 = JSON.parse(cli(root, 'ask', '--run', id, '--layer', 'l1', '--question', 'A or B?').stdout).id;
  // The senders are separate processes: wait for each one, so that the order in the file is sure.
  await sentEvents(log, 1);
  cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'phase=implementing');
  assert.equal(cli(root, 'park', '--run', id, '--layer', 'l1', '--id', q1, '--tip', 'a'.repeat(40)).code, 0);
  cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'A');
  cli(root, 'run', '--run', id, '--set', 'stage=layers');
  // A reopen of a finished run is the user's own action: it sends nothing.
  cli(root, 'run', '--run', id, '--set', 'state=finished');
  await sentEvents(log, 2);
  cli(root, 'run', '--run', id, '--set', 'state=paused');
  // A last question marks the end. A wrong notification from a step above started before it, so
  // a short wait after the marker is sufficient to see it.
  cli(root, 'ask', '--run', id, '--question', 'last?');
  await sentEvents(log, 3);
  await new Promise((done) => setTimeout(done, 300));
  assert.deepEqual((await sentEvents(log, 3)).map((e) => [e.type, e.text]), [['question', 'A or B?'], ['finished', null], ['question', 'last?']]);
});

test('N3. the events list limits what is sent, and the command gets the event in its environment', async () => {
  const root = tempRoot();
  const log = path.join(root, 'env.txt');
  writeFileSync(path.join(root, 'config.json'), JSON.stringify({ notify: { events: ['finished'], command: `printf '%s|%s|%s\\n' "$TASK_MANAGER_EVENT" "$TASK_MANAGER_RUN" "$TASK_MANAGER_TITLE" >> "${log}"` } }));
  const id = newRun(root);
  cli(root, 'ask', '--run', id, '--question', 'A or B?');
  cli(root, 'run', '--run', id, '--set', 'state=paused');
  cli(root, 'run', '--run', id, '--set', 'state=finished');
  for (let i = 0; i < 200 && !existsSync(log); i += 1) await new Promise((done) => setTimeout(done, 25));
  await new Promise((done) => setTimeout(done, 100));
  assert.equal(readFileSync(log, 'utf8'), `finished|${id}|Undo timeline\n`);
});

test('N4. a question cannot inject shell code, and a command that fails does not fail the ledger', async () => {
  const { root, log } = notifyRoot();
  const id = newRun(root);
  const marker = path.join(root, 'injected');
  const evil = `"; touch "${marker}"; $(touch "${marker}") \`touch "${marker}"\``;
  assert.equal(cli(root, 'ask', '--run', id, '--question', evil).code, 0);
  assert.equal((await sentEvents(log, 1))[0].text, evil);
  assert.equal(existsSync(marker), false);

  for (const config of ['{ not json', JSON.stringify({ notify: { command: 'exit 7' } }), JSON.stringify({ notify: { command: '/no/such/program' } }), JSON.stringify({ notify: { events: ['nope'] } })]) {
    writeFileSync(path.join(root, 'config.json'), config);
    const out = cli(root, 'ask', '--run', id, '--question', 'still works?');
    assert.equal(out.code, 0, out.stderr);
  }
});

test('N5. notify-test reports each sender, a bad settings file, and no settings; the root with a settings file still lists its runs', () => {
  const { root, log } = notifyRoot();
  const id = newRun(root);
  const ok = JSON.parse(cli(root, 'notify-test').stdout);
  assert.deepEqual(ok.sent, [{ sender: 'command', ok: true }]);
  assert.equal(JSON.parse(readFileSync(log, 'utf8').trim()).text, 'The notifications of the task manager work.');
  assert.deepEqual(listRuns(root).runs.map((r) => r.id), [id]);

  writeFileSync(path.join(root, 'config.json'), JSON.stringify({ notify: { command: 'echo no >&2; exit 3' } }));
  assert.deepEqual(JSON.parse(cli(root, 'notify-test').stdout).sent, [{ sender: 'command', ok: false, reason: 'exit 3: no' }]);
  writeFileSync(path.join(root, 'config.json'), '{ not json');
  assert.match(JSON.parse(cli(root, 'notify-test').stdout).error, /is not valid JSON/);
  assert.match(JSON.parse(cli(tempRoot(), 'notify-test').stdout).note, /nothing is sent/);
});

test('N6. the desktop command gets the text as arguments, never as script source', async () => {
  const { desktopCommand, messageOf } = await import('../lib/task-manager-notify.mjs');
  const event = { type: 'question', run: 'r', title: 'Undo "timeline"', layer: 'l2', text: 'A or B?\n" & do shell script "x' };
  const mac = desktopCommand(event, 'darwin');
  assert.equal(mac[0], 'osascript');
  assert.equal(mac.at(-2), messageOf(event));
  // A title that starts with `-e` would be one more line of script, without the `--` before it.
  const dash = desktopCommand({ ...event, title: '-eproperty p : (do shell script "touch /tmp/x")' }, 'darwin');
  assert.equal(dash.at(-3), '--');
  assert.equal(dash.indexOf('--'), dash.length - 3);
  assert.equal(mac.slice(1, -2).some((part) => part.includes('Undo') || part.includes('shell script')), false);
  assert.deepEqual(desktopCommand(event, 'linux').slice(0, 2), ['notify-send', '--']);
  assert.equal(desktopCommand(event, 'win32'), null);
  assert.equal(desktopCommand({ ...event, text: 'x'.repeat(500) }, 'linux').at(-1).length, 240);
});

test('N7. [review] a long question is cut for the senders, so a command that reads nothing cannot hold the ledger process', async () => {
  const { MAX_TEXT } = await import('../lib/task-manager-notify.mjs');
  const { root, log } = notifyRoot();
  const id = newRun(root);
  cli(root, 'ask', '--run', id, '--question', 'x'.repeat(200_000));
  const [event] = await sentEvents(log, 1);
  assert.equal(event.text.length, MAX_TEXT);
  // The ledger keeps the full question: only the notification is cut.
  assert.equal(readRun(root, id).openQuestions[0].question.length, 200_000);

  // The real CLI process must end at once, also when the command sleeps and reads no stdin.
  writeFileSync(path.join(root, 'config.json'), JSON.stringify({ notify: { command: 'sleep 20' } }));
  const file = path.join(root, 'long.txt');
  writeFileSync(file, 'y'.repeat(120_000));
  const started = Date.now();
  const out = spawnSync(process.execPath, [CLI, 'ask', '--run', id, '--question', readFileSync(file, 'utf8')], { env: { ...process.env, TASK_MANAGER_RUNS: root }, encoding: 'utf8', timeout: 15_000 });
  assert.equal(out.status, 0, out.stderr);
  assert.ok(Date.now() - started < 10_000, `the CLI took ${Date.now() - started} ms`);
});

// ── Sessions of a run ────────────────────────────────────────────────────────────────────────────

/** A root with a paused run, whose settings start a stand-in for the session program: it records its call and stays alive. */
function sessionRoot({ enabled = true, lifeMs = 4000, extra = {} } = {}) {
  const base = tempRoot();
  const root = path.join(base, 'runs');
  const checkout = path.join(base, 'clone');
  mkdirSync(root);
  mkdirSync(checkout);
  const fake = path.join(base, 'fake-session.mjs');
  const call = path.join(base, 'call.json');
  writeFileSync(
    fake,
    `#!/usr/bin/env node
import { writeFileSync } from 'node:fs';
writeFileSync(${JSON.stringify(call)}, JSON.stringify({ args: process.argv.slice(2), cwd: process.cwd(), env: process.env }));
console.log('session output');
setTimeout(() => {}, ${lifeMs});
`,
  );
  chmodSync(fake, 0o755);
  writeFileSync(path.join(root, 'config.json'), JSON.stringify({ resume: { enabled, command: fake, args: ['--permission-mode', 'acceptEdits'], ...extra } }));
  const id = initRun(root, { title: 'Undo timeline', checkout, request: 'do it', layers: layers(2), date: '2026-11-06' }).id;
  setRun(root, id, [['state', 'paused']]);
  return { base, root, checkout, call, id, fake };
}

async function fileJson(file) {
  for (let i = 0; i < 200; i += 1) {
    if (existsSync(file)) {
      try {
        return JSON.parse(readFileSync(file, 'utf8'));
      } catch {
        // Written in part: try again.
      }
    }
    await new Promise((done) => setTimeout(done, 25));
  }
  throw new Error(`no ${file} after 5 s`);
}

const stopProcess = (pid) => {
  try {
    process.kill(pid);
  } catch {
    // It ended already.
  }
};

test('X1. start-session starts the program in the checkout with the resume prompt and tight permissions, records it, and refuses a second one while it runs', async () => {
  const { realpathSync } = await import('node:fs');
  const { root, checkout, call, id } = sessionRoot();
  const env = { TASK_MANAGER_RUNS: root };
  // The identity of the session that started the admin server must not reach the new session.
  const parent = { CLAUDECODE: '1', CLAUDE_PID: '1', CLAUDE_CODE_SESSION_ID: 'old', CLAUDE_CODE_CHILD_SESSION: '1', CLAUDE_CODE_MESSAGING_SOCKET: '/x', CLAUDE_CODE_ENTRYPOINT: 'cli', CLAUDE_CODE_USE_BEDROCK: 'keep' };
  const out = spawnSync(process.execPath, [CLI, 'start-session', '--run', id], { env: { ...process.env, ...parent, ...env }, encoding: 'utf8' });
  assert.equal(out.status, 0, out.stderr);
  const started = JSON.parse(out.stdout);
  try {
    const seen = await fileJson(call);
    assert.deepEqual(seen.args.filter((_, i) => i !== 1), ['--settings', '--permission-mode', 'acceptEdits', '-p', `/task-manager resume ${id}`]);
    const skill = path.resolve(path.dirname(CLI), '..');
    const { permissions } = JSON.parse(seen.args[1]);
    assert.deepEqual(permissions.allow, [`Read(/${skill}/**)`, `Read(/${root}/${id}/**)`, `Edit(/${root}/${id}/plans/**)`, `Edit(/${root}/${id}/reports/**)`]);
    // The session can never edit the ledger code or the settings file: both run with no permission check.
    assert.equal(permissions.deny.includes(`Edit(/${skill}/**)`), true);
    assert.equal(permissions.deny.includes(`Edit(/${root}/config.json)`), true);
    assert.equal(seen.args.includes('--add-dir'), false);
    assert.equal(realpathSync(seen.cwd), realpathSync(checkout));
    assert.equal(seen.env.TASK_MANAGER_RUNS, root);
    assert.equal(seen.env.TASK_MANAGER_NO_TERMINAL, '1');
    assert.deepEqual(Object.keys(parent).filter((key) => key in seen.env), ['CLAUDE_CODE_USE_BEDROCK']);
    assert.deepEqual(JSON.parse(readFileSync(path.join(root, id, 'session.json'), 'utf8')), started);
    assert.equal(started.log, path.join(root, id, 'session.log'));
    assert.match(readRun(root, id).events.at(-1).summary, /a session was started from the admin page/);
    const again = cli(root, 'start-session', '--run', id);
    assert.equal(again.code, 1);
    assert.match(again.stderr, new RegExp(`a started session works on run ${id} \\(process ${started.pid}\\)`));
  } finally {
    stopProcess(started.pid);
  }
  // When that process is gone, its record has no effect: a new session can start.
  for (let i = 0; i < 200; i += 1) {
    const next = cli(root, 'start-session', '--run', id);
    if (next.code === 0) {
      stopProcess(JSON.parse(next.stdout).pid);
      assert.match(readFileSync(path.join(root, id, 'session.log'), 'utf8'), /session output/);
      return;
    }
    await new Promise((done) => setTimeout(done, 25));
  }
  assert.fail('a new session did not start after the first one ended');
});

test('X2. start-session is off by default, and it refuses a finished run, a bad checkout, a missing program and bad settings', () => {
  const off = sessionRoot({ enabled: false });
  const refused = cli(off.root, 'start-session', '--run', off.id);
  assert.equal(refused.code, 1);
  assert.match(refused.stderr, /starting a session is off; set "resume": \{ "enabled": true \}/);
  assert.equal(existsSync(path.join(off.root, off.id, 'session.json')), false);
  // No settings file at all is also off.
  const bare = tempRoot();
  assert.match(cli(bare, 'start-session', '--run', newRun(bare)).stderr, /starting a session is off/);

  const { root, id } = sessionRoot();
  const config = path.join(root, 'config.json');
  writeFileSync(config, JSON.stringify({ resume: { enabled: true, command: '/no/such/program' } }));
  const missing = cli(root, 'start-session', '--run', id);
  assert.equal(missing.code, 1);
  assert.match(missing.stderr, /cannot start "\/no\/such\/program"/);
  assert.equal(existsSync(path.join(root, id, 'session.json')), false);
  for (const [bad, message] of [
    [{ resume: { enabled: true, args: 'x' } }, /"resume.args" .* must be a list of texts/],
    [{ resume: { enabled: true, command: 5 } }, /"resume.command" .* must be the name of a program/],
    [{ resume: { enabled: true, checkouts: ['relative'] } }, /"resume.checkouts" .* must be a list of absolute paths/],
    [{ resume: [] }, /"resume" .* must be an object/],
  ]) {
    writeFileSync(config, JSON.stringify(bad));
    assert.match(cli(root, 'start-session', '--run', id).stderr, message);
  }
  writeFileSync(config, '{ not json');
  assert.match(cli(root, 'start-session', '--run', id).stderr, /is not a JSON object/);

  // A checkout that is not there, and one that is a file: an input error, not a crash.
  for (const make of [() => '/no/such/clone', (base) => (writeFileSync(path.join(base, 'a-file'), ''), path.join(base, 'a-file'))]) {
    const bad = sessionRoot();
    const file = path.join(bad.root, bad.id, 'run.json');
    const checkout = make(bad.base);
    writeFileSync(file, JSON.stringify({ ...JSON.parse(readFileSync(file, 'utf8')), checkout }));
    const out = cli(bad.root, 'start-session', '--run', bad.id);
    assert.equal(out.code, 1);
    assert.match(out.stderr, /does not exist, or is not a folder/);
  }
  const done = sessionRoot();
  cli(done.root, 'run', '--run', done.id, '--set', 'state=finished');
  assert.match(cli(done.root, 'start-session', '--run', done.id).stderr, /is finished/);
});

test('X3. a wait marks the run as watched while it runs, and start-session refuses a watched run', async () => {
  const { waitForAnswer, sessionsOf } = await import('../lib/task-manager-core.mjs');
  const { root, id } = sessionRoot();
  const dir = path.join(root, id);
  const q1 = JSON.parse(cli(root, 'ask', '--run', id, '--question', 'A or B?').stdout).id;
  const waiting = waitForAnswer(root, id, { pollMs: 5, timeoutMs: 5000 });
  await new Promise((done) => setTimeout(done, 30));
  assert.deepEqual(sessionsOf(dir).watchers, [process.pid]);
  const refused = cli(root, 'start-session', '--run', id);
  assert.equal(refused.code, 1);
  assert.match(refused.stderr, new RegExp(`a session watches run ${id}`));
  cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'A');
  await waiting;
  assert.deepEqual(sessionsOf(dir), { watchers: [], started: null });
});

test('X4. [review] a marker counts only for the process that wrote it: not for a dead PID, a PID that another process has now, or a bad file', async () => {
  const { sessionsOf, processStart } = await import('../lib/task-manager-core.mjs');
  const { root, id } = sessionRoot();
  const dir = path.join(root, id);
  mkdirSync(path.join(dir, 'watchers'), { recursive: true });
  const mine = processStart(process.pid);
  assert.equal(typeof mine, 'string');
  assert.equal(processStart(2147483646), null);
  // This process runs, but the marker has the start time of an earlier process with the same PID.
  writeFileSync(path.join(dir, 'watchers', String(process.pid)), JSON.stringify({ lstart: 'Thu Jan  1 00:00:00 1970' }));
  writeFileSync(path.join(dir, 'watchers', '2147483646'), JSON.stringify({ lstart: mine }));
  writeFileSync(path.join(dir, 'watchers', 'not-a-pid'), '');
  writeFileSync(path.join(dir, 'watchers', '0'), '');
  assert.deepEqual(sessionsOf(dir).watchers, []);
  for (const pid of [0, -1, process.pid]) {
    writeFileSync(path.join(dir, 'session.json'), JSON.stringify({ pid, lstart: 'Thu Jan  1 00:00:00 1970' }));
    assert.equal(sessionsOf(dir).started, null);
  }
  // The same PID with the right start time is alive.
  writeFileSync(path.join(dir, 'watchers', String(process.pid)), JSON.stringify({ lstart: mine }));
  assert.deepEqual(sessionsOf(dir).watchers, [process.pid]);
  // start-session removes the markers of the processes that ended.
  cli(root, 'run', '--run', id, '--set', 'nextStep=x');
  assert.equal(cli(root, 'start-session', '--run', id).code, 1);
  assert.deepEqual(readdirSync(path.join(dir, 'watchers')), [String(process.pid)]);
});

test('X5. [review] a wait that a signal ends removes its marker', async () => {
  const { root, id } = sessionRoot();
  const marker = (pid) => path.join(root, id, 'watchers', String(pid));
  cli(root, 'ask', '--run', id, '--question', 'A or B?');
  const child = spawn(process.execPath, [CLI, 'wait', '--run', id, '--timeout', '30'], { env: { ...process.env, TASK_MANAGER_RUNS: root } });
  for (let i = 0; i < 200 && !existsSync(marker(child.pid)); i += 1) await new Promise((done) => setTimeout(done, 25));
  assert.equal(existsSync(marker(child.pid)), true);
  child.kill('SIGTERM');
  const code = await new Promise((done) => child.on('close', done));
  assert.equal(code, 143);
  assert.equal(existsSync(marker(child.pid)), false);
});

test('X6. [review] an active run is not started unless it had no event for an hour; the checkout list limits the clones', async () => {
  const { startSession } = await import('../lib/task-manager-core.mjs');
  const { root, id, checkout } = sessionRoot();
  cli(root, 'run', '--run', id, '--set', 'state=active');
  const active = cli(root, 'start-session', '--run', id);
  assert.equal(active.code, 1);
  assert.match(active.stderr, /is active: a session works on it/);
  // After an hour with no event, the session that worked on it is gone.
  const calls = [];
  const spawnFn = (file, args, options) => (calls.push({ file, args, options }), { pid: process.pid, on() {}, unref() {} });
  const started = startSession(root, id, { spawnFn, at: Date.now() + 61 * 60 * 1000, alive: () => false });
  assert.equal(started.pid, process.pid);
  assert.equal(calls.length, 1);

  const listed = sessionRoot({ extra: { checkouts: ['/some/other/clone'] } });
  const out = cli(listed.root, 'start-session', '--run', listed.id);
  assert.equal(out.code, 1);
  assert.match(out.stderr, /is not in "resume.checkouts"/);
  writeFileSync(path.join(listed.root, 'config.json'), JSON.stringify({ resume: { enabled: true, command: listed.fake, checkouts: [`${listed.checkout}/`] } }));
  const ok = cli(listed.root, 'start-session', '--run', listed.id);
  assert.equal(ok.code, 0, ok.stderr);
  stopProcess(JSON.parse(ok.stdout).pid);
  assert.equal(typeof checkout, 'string');
});

// ── Usage ────────────────────────────────────────────────────────────────────────────────────────

test('U1. usage records what an agent used; show adds it up; bad numbers and an empty record are refused', async () => {
  const { sumUsage } = await import('../lib/task-manager-core.mjs');
  const root = tempRoot();
  const id = newRun(root);
  const before = eventCount(root, id);
  const use = (...args) => cli(root, 'usage', '--run', id, ...args);
  assert.equal(use('--layer', 'l1', '--role', 'implementer', '--agent', 'a1', '--model', 'sonnet', '--tokens', '84204', '--tool-uses', '23', '--duration-ms', '171799').code, 0);
  assert.equal(use('--layer', 'l1', '--role', 'reviewer', '--tokens', '20000', '--cost', '0.35').code, 0);
  // A restacker works on several layers, so its record has no layer.
  assert.equal(use('--role', 'restacker', '--duration-ms', '60000').code, 0);
  // A measurement is not an event of the run.
  assert.equal(eventCount(root, id), before);
  const state = readRun(root, id);
  assert.equal(state.usage.length, 3);
  assert.deepEqual({ ...state.usage[0], ts: null }, { ts: null, layer: 'l1', role: 'implementer', agent: 'a1', model: 'sonnet', tokens: 84204, toolUses: 23, durationMs: 171799, cost: null });
  assert.deepEqual(sumUsage(state.usage), { agents: 3, tokens: 104204, toolUses: 23, durationMs: 231799, cost: 0.35 });
  assert.equal(sumUsage(state.usage.slice(0, 1)).cost, null);
  assert.match(cli(root, 'show', '--run', id).stdout, /usage: 3 agents, 104204 tokens, 23 tool uses, 4 min of agent time, \$0\.35/);

  for (const [args, message] of [
    [['--layer', 'l1', '--role', 'implementer'], /give at least one of --tokens/],
    [['--role', 'boss', '--tokens', '1'], /role must be one of/],
    [['--role', 'orchestrator', '--tokens', '1'], /role must be one of/],
    [['--role', 'implementer', '--tokens', '1'], /--layer is required for the role implementer/],
    [['--role', 'reviewer', '--tokens', '1'], /--layer is required for the role reviewer/],
    // An empty value is not a 0 that the harness gave.
    [['--layer', 'l1', '--role', 'reviewer', '--tokens', ''], /tokens must be a whole number/],
    [['--layer', 'l1', '--role', 'reviewer', '--tool-uses', ' '], /tool-uses must be a whole number/],
    [['--layer', 'l1', '--role', 'reviewer', '--duration-ms', '1e3'], /duration-ms must be a whole number/],
    [['--layer', 'l1', '--role', 'reviewer', '--tokens', '0x10'], /tokens must be a whole number/],
    [['--layer', 'l1', '--role', 'reviewer', '--cost', ''], /cost must be a number of dollars/],
    [['--layer', 'l1', '--role', 'reviewer', '--cost', '1e3'], /cost must be a number of dollars/],
    [['--tokens', '1'], /--role is required/],
    [['--layer', 'l1', '--role', 'reviewer', '--tokens=-1'], /tokens must be a whole number/],
    [['--layer', 'l1', '--role', 'reviewer', '--tokens', '1.5'], /tokens must be a whole number/],
    [['--layer', 'l1', '--role', 'reviewer', '--cost', 'cheap'], /cost must be a number of dollars/],
    [['--layer', 'l1', '--role', 'reviewer', '--cost=-1'], /cost must be a number of dollars/],
    [['--layer', 'l9', '--role', 'reviewer', '--tokens', '1'], /l9/],
  ]) {
    const out = use(...args);
    assert.equal(out.code, 1, JSON.stringify(args));
    assert.match(out.stderr, message);
  }
  assert.equal(readRun(root, id).usage.length, 3);
  // A finished run still accepts the usage of its last agent.
  cli(root, 'run', '--run', id, '--set', 'state=finished');
  assert.equal(use('--layer', 'l2', '--role', 'reviewer', '--tokens', '5').code, 0);
  // A line that is valid JSON but not a record does not break `show`.
  appendFileSync(path.join(root, id, 'usage.jsonl'), 'null\n[1]\n"x"\n');
  assert.equal(cli(root, 'show', '--run', id).code, 0);
  assert.equal(readRun(root, id).usage.length, 4);
  // A run with no record prints no usage line.
  const other = tempRoot();
  assert.doesNotMatch(cli(other, 'show', '--run', newRun(other)).stdout, /usage:/);
});

// ── A confirmed answer to a session-only question ───────────────────────────────────────────────

test('K1. a session-only question takes a page answer only with the user setting and the exact option; the wait gives it as confirmed', async () => {
  const { waitForAnswer } = await import('../lib/task-manager-core.mjs');
  const root = tempRoot();
  const id = newRun(root);
  const q1 = JSON.parse(cli(root, 'ask', '--run', id, '--session-only', '--question', 'Merge the stack?', '--option', '#504', '--option', '#506').stdout).id;
  const page = (...args) => cli(root, 'answer', '--run', id, '--id', q1, '--via', 'dashboard', ...args);
  // Off by default, also with the right confirmation.
  assert.match(page('--answer', '#506', '--confirm', '#506').stderr, /takes an answer in the session only/);
  writeFileSync(path.join(root, 'config.json'), '{ not json');
  assert.match(page('--answer', '#506', '--confirm', '#506').stderr, /takes an answer in the session only/);
  writeFileSync(path.join(root, 'config.json'), JSON.stringify({ answers: { confirmOnPage: true } }));
  assert.match(page('--answer', '#506').stderr, /needs a confirmation: type one of its options exactly \("#504", "#506"\)/);
  assert.match(page('--answer', '#506', '--confirm', '506').stderr, /needs a confirmation/);
  assert.match(page('--answer', '#504', '--confirm', '#506').stderr, /must be the confirmed option "#506" and nothing more/);
  assert.match(page('--answer', '#5060', '--confirm', '#506').stderr, /must be the confirmed option "#506"/);
  // A comment could add a condition to the yes, so a confirmed answer has none.
  assert.match(page('--answer', '#506 — but not #505', '--confirm', '#506').stderr, /and nothing more/);
  assert.equal(readRun(root, id).openQuestions.length, 1);
  // A session that the page started cannot give the answer of the page.
  process.env.TASK_MANAGER_NO_TERMINAL = '1';
  try {
    assert.match(page('--answer', '#506', '--confirm', '#506').stderr, /a session cannot give the answer of the admin page/);
  } finally {
    delete process.env.TASK_MANAGER_NO_TERMINAL;
  }
  // With no such variable, the same command is the page's own call: it works.
  const ok = page('--answer', '#506', '--confirm', '#506');
  assert.equal(ok.code, 0, ok.stderr);

  // The mark is still there after the wait wrote its delivery line.
  assert.deepEqual(await waitForAnswer(root, id, { pollMs: 5, timeoutMs: 5000 }), { answered: [{ id: q1, layer: null, answer: '#506', via: 'dashboard', confirmed: true }], reason: 'answered' });
  const saved = readRun(root, id).questions.find((q) => q.id === q1);
  assert.deepEqual([saved.confirmed, saved.delivered, saved.via], [true, true, 'dashboard']);
  assert.match(readRun(root, id).events.at(-1).summary, /from the admin page, with a typed confirmation/);
  assert.match(cli(root, 'show', '--run', id).stdout, /-> #506 \[confirmed on the admin page\]/);

  // A session answer needs no confirmation, and an ordinary question ignores one.
  const q2 = JSON.parse(cli(root, 'ask', '--run', id, '--session-only', '--question', 'Deploy?').stdout).id;
  assert.equal(cli(root, 'answer', '--run', id, '--id', q2, '--answer', 'go').code, 0);
  const q3 = JSON.parse(cli(root, 'ask', '--run', id, '--question', 'A or B?').stdout).id;
  assert.equal(cli(root, 'answer', '--run', id, '--id', q3, '--answer', 'A', '--via', 'dashboard').code, 0);
  assert.equal(readRun(root, id).questions.find((q) => q.id === q3).confirmed, undefined);
  // With no options, the word is "yes".
  const q4 = JSON.parse(cli(root, 'ask', '--run', id, '--session-only', '--question', 'Force-push?').stdout).id;
  assert.match(cli(root, 'answer', '--run', id, '--id', q4, '--via', 'dashboard', '--answer', 'ok', '--confirm', 'ok').stderr, /type one of its options exactly \("yes"\)/);
  assert.equal(cli(root, 'answer', '--run', id, '--id', q4, '--via', 'dashboard', '--answer', 'yes', '--confirm', 'yes').code, 0);
});

test('K2. [review] show gives the mark of an answer where a resume reads it: on a parked layer and in the layer view', () => {
  const root = tempRoot();
  const id = newRun(root);
  writeFileSync(path.join(root, 'config.json'), JSON.stringify({ answers: { confirmOnPage: true } }));
  cli(root, 'layer', '--run', id, '--layer', 'l1', '--set', 'phase=implementing');
  const q1 = JSON.parse(cli(root, 'park', '--run', id, '--layer', 'l1', '--session-only', '--question', 'Deploy the fix to staging?', '--tip', 'a'.repeat(40)).stdout).id;
  assert.equal(cli(root, 'answer', '--run', id, '--id', q1, '--via', 'dashboard', '--answer', 'yes', '--confirm', 'yes').code, 0);
  assert.match(cli(root, 'show', '--run', id).stdout, /answer: yes \[confirmed on the admin page\] - ready to unpark/);
  assert.match(cli(root, 'show', '--run', id, '--layer', 'l1').stdout, /q1 \[session only\]: Deploy the fix to staging\? -> yes \[confirmed on the admin page\]/);
  // An ordinary answer from the page has its own mark, and a session answer has none.
  const q2 = JSON.parse(cli(root, 'ask', '--run', id, '--layer', 'l2', '--question', 'A or B?').stdout).id;
  cli(root, 'answer', '--run', id, '--id', q2, '--answer', 'A', '--via', 'dashboard');
  const q3 = JSON.parse(cli(root, 'ask', '--run', id, '--layer', 'l2', '--question', 'C or D?').stdout).id;
  cli(root, 'answer', '--run', id, '--id', q3, '--answer', 'C');
  const view = cli(root, 'show', '--run', id, '--layer', 'l2').stdout;
  assert.match(view, /q2: A or B\? -> A \[from the admin page\]/);
  assert.match(view, /q3: C or D\? -> C$/);
});

test('K3. [review] an option is a text that the user can type again: not empty, and with no space around it', () => {
  const root = tempRoot();
  const id = newRun(root);
  writeFileSync(path.join(root, 'config.json'), JSON.stringify({ answers: { confirmOnPage: true } }));
  for (const bad of ['', '   ']) {
    const out = cli(root, 'ask', '--run', id, '--session-only', '--question', 'Merge?', `--option=${bad}`, '--option', 'b');
    assert.equal(out.code, 1);
    assert.match(out.stderr, /option is required/);
  }
  assert.equal(readRun(root, id).questions.length, 0);
  const q1 = JSON.parse(cli(root, 'ask', '--run', id, '--session-only', '--question', 'Merge?', '--option', ' #506 ').stdout).id;
  assert.deepEqual(readRun(root, id).questions[0].options, ['#506']);
  assert.equal(cli(root, 'answer', '--run', id, '--id', q1, '--via', 'dashboard', '--answer', '#506', '--confirm', '#506').code, 0);
});

// ── A dry run of init ────────────────────────────────────────────────────────────────────────────

/** Every file under a folder with its size and change time: equal snapshots mean that nothing was written. */
function treeSnapshot(dir) {
  const { statSync } = fsForSnapshot;
  const out = [];
  const walk = (folder) => {
    for (const name of readdirSync(folder).sort()) {
      const file = path.join(folder, name);
      const stat = statSync(file);
      out.push(`${path.relative(dir, file)} ${stat.size} ${stat.mtimeMs}`);
      if (stat.isDirectory()) walk(file);
    }
  };
  walk(dir);
  return out;
}

test('D1. init --dry-run checks the plan and writes nothing; it reports the active and the paused runs of the checkout', () => {
  const base = tempRoot();
  const root = path.join(base, 'runs');
  const request = path.join(base, 'request.txt');
  const file = path.join(base, 'layers.json');
  writeFileSync(request, 'do it');
  writeFileSync(file, JSON.stringify([{ task: 'Find the cause', source: '#1', tier: 'S', tierReason: 'small', outcome: 'report' }, { task: 'Fix it', source: '#1', tier: 'M', tierReason: 'fix', dependsOn: [1] }, { task: 'Docs', source: '#2', tier: 'S', tierReason: 'text' }]));
  const dry = (...extra) => cli(root, 'init', '--dry-run', '--kind', 'tasks', '--title', 'Undo timeline', '--checkout', CHECKOUT, '--request-file', request, '--layers-file', file, ...extra);
  const out = dry();
  assert.equal(out.code, 0, out.stderr);
  const plan = JSON.parse(out.stdout);
  assert.equal(plan.dryRun, true);
  assert.match(plan.id, /^\d{4}-\d{2}-\d{2}-undo-timeline$/);
  assert.deepEqual([plan.kind, plan.checkout, plan.activeRun, plan.pausedRuns], ['tasks', CHECKOUT, null, []]);
  assert.deepEqual(plan.layers, [
    { id: 'l1', task: 'Find the cause', outcome: 'report', tier: 'S', dependsOn: [], tokens: null },
    { id: 'l2', task: 'Fix it', outcome: 'pr', tier: 'M', dependsOn: ['l1'], tokens: null },
    { id: 'l3', task: 'Docs', outcome: 'pr', tier: 'S', dependsOn: [], tokens: null },
  ]);
  assert.deepEqual(plan.estimate, { tokens: null, history: {} });
  // Nothing was written: not the root, and no run.
  assert.equal(existsSync(root), false);

  // An active run for the checkout blocks a real init. A dry run reports it and continues. With a
  // root that has runs, the dry run changes no file in it.
  const real = cli(root, 'init', '--kind', 'tasks', '--title', 'Undo timeline', '--checkout', CHECKOUT, '--request-file', request, '--layers-file', file);
  const realId = JSON.parse(real.stdout).id;
  const before = treeSnapshot(root);
  const blocked = dry('--kind', 'stack');
  assert.equal(blocked.code, 0, blocked.stderr);
  assert.deepEqual(treeSnapshot(root), before);
  const second = JSON.parse(blocked.stdout);
  assert.equal(second.activeRun, realId);
  // The id is the one that a real init gives now: that folder exists, so it gets a number.
  assert.equal(second.id, `${realId}-2`);
  cli(root, 'run', '--run', realId, '--set', 'state=paused');
  const afterPause = JSON.parse(dry().stdout);
  assert.deepEqual([afterPause.activeRun, afterPause.pausedRuns], [null, [realId]]);
  assert.equal(JSON.parse(cli(root, 'init', '--kind', 'tasks', '--title', 'Undo timeline', '--checkout', CHECKOUT, '--request-file', request, '--layers-file', file).stdout).id, second.id);
});

test('D2. [review] a dry run and a real init refuse the same input; --dry-run is refused by every other command', () => {
  const base = tempRoot();
  const request = path.join(base, 'request.txt');
  const file = path.join(base, 'layers.json');
  writeFileSync(request, 'do it');
  const entry = (extra = {}) => ({ task: 'A', source: 's', tier: 'S', tierReason: 'r', ...extra });
  const cases = [
    [[entry(), entry({ dependsOn: [1] })], 'tasks', /in a tasks run, dependsOn may name only report tasks/],
    [[entry({ tier: 'XL' })], 'stack', /tier/],
    [[entry({ task: '  ' })], 'stack', /task is required/],
    [[entry({ dependsOn: [2] }), entry()], 'stack', /dependsOn may name only earlier layers/],
    [[entry({ outcome: 'email' })], 'tasks', /outcome/],
    [[], 'stack', /non-empty JSON array/],
  ];
  for (const [layerList, kind, message] of cases) {
    writeFileSync(file, JSON.stringify(layerList));
    for (const flags of [[], ['--dry-run']]) {
      const root = path.join(tempRoot(), 'runs');
      const out = cli(root, 'init', ...flags, '--kind', kind, '--title', 'T', '--checkout', CHECKOUT, '--request-file', request, '--layers-file', file);
      assert.equal(out.code, 1, `${JSON.stringify(layerList)} ${flags}`);
      assert.match(out.stderr, message);
      assert.equal(existsSync(root), false);
    }
  }
  // A root that cannot be made fails the dry run too, with an input error.
  writeFileSync(file, JSON.stringify([entry()]));
  const blocker = path.join(base, 'a-file');
  writeFileSync(blocker, '');
  const noRoot = cli(path.join(blocker, 'runs'), 'init', '--dry-run', '--title', 'T', '--checkout', CHECKOUT, '--request-file', request, '--layers-file', file);
  assert.equal(noRoot.code, 1);
  assert.match(noRoot.stderr, /the runs folder .* cannot be made/);

  // A flag that promises no write is never ignored by a command that writes.
  const root = tempRoot();
  const id = newRun(root);
  const before = readFileSync(path.join(root, id, 'run.json'), 'utf8');
  for (const args of [['run', '--run', id, '--set', 'nextStep=HELLO'], ['ask', '--run', id, '--question', 'A?'], ['decision', '--run', id, '--question', 'q', '--answer', 'a'], ['show', '--run', id]]) {
    const out = cli(root, ...args, '--dry-run');
    assert.equal(out.code, 1, args.join(' '));
    assert.match(out.stderr, /--dry-run applies to init only/);
  }
  assert.equal(readFileSync(path.join(root, id, 'run.json'), 'utf8'), before);
  assert.equal(readRun(root, id).questions.length, 0);
});

test('D3. the dry run estimates the tokens from the complete tasks of earlier runs, for each tier and outcome', async () => {
  const { tierHistory } = await import('../lib/task-manager-core.mjs');
  const { symlinkSync } = fsForSnapshot;
  const root = tempRoot();
  const first = initRun(root, { title: 'First', checkout: CHECKOUT, request: 'r', kind: 'tasks', date: '2026-11-01', layers: [{ task: 'a', source: 's', tier: 'S', tierReason: 'r', outcome: 'report' }, { task: 'b', source: 's', tier: 'M', tierReason: 'r' }, { task: 'c', source: 's', tier: 'M', tierReason: 'r' }, { task: 'd', source: 's', tier: 'M', tierReason: 'r' }, { task: 'e', source: 's', tier: 'L', tierReason: 'r' }] }).id;
  for (const [layer, role, tokens] of [['l1', 'implementer', '1000'], ['l1', 'reviewer', '500'], ['l2', 'implementer', '4000'], ['l3', 'implementer', '6000'], ['l4', 'implementer', '100']]) {
    assert.equal(cli(root, 'usage', '--run', first, '--layer', layer, '--role', role, '--tokens', tokens).code, 0);
  }
  assert.equal(cli(root, 'usage', '--run', first, '--role', 'restacker', '--tokens', '9999').code, 0);
  // Complete: l1 (delivered), l2 and l3 (PR open). l4 still works, so its usage is a part only.
  writeFileSync(path.join(root, first, 'reports', 'report-a.md'), 'x');
  const file = path.join(root, first, 'run.json');
  const run = JSON.parse(readFileSync(file, 'utf8'));
  for (const [index, phase] of [[0, 'delivered'], [1, 'pr_open'], [2, 'merged'], [3, 'review']]) run.layers[index].phase = phase;
  writeFileSync(file, JSON.stringify(run));
  // Things in the root that are not a run of their own: a settings file, a broken run, a link to the run.
  writeFileSync(path.join(root, 'config.json'), '{}');
  mkdirSync(path.join(root, '2026-11-02-broken'));
  writeFileSync(path.join(root, '2026-11-02-broken', 'usage.jsonl'), '{"layer":"l1","tokens":5}\n');
  symlinkSync(path.join(root, first), path.join(root, '2026-11-03-link'));
  appendFileSync(path.join(root, first, 'usage.jsonl'), 'null\n{"layer":"l9","tokens":7}\n{"layer":"l2","tokens":"many"}\n');

  // l5 (tier L) has no record, l4 is not complete, and the restacker has no layer: none counts.
  assert.deepEqual(tierHistory(root), { 'S/report': { layers: 1, tokensPerLayer: 1500 }, 'M/pr': { layers: 2, tokensPerLayer: 5000 } });

  const plan = (entries) => initRun(root, { title: 'Next', checkout: '/other/clone', request: 'r', kind: 'tasks', dryRun: true, layers: entries.map(([tier, outcome]) => ({ task: tier, source: 's', tier, tierReason: 'r', outcome })) });
  const known = plan([['S', 'report'], ['M', 'pr'], ['M', 'pr']]);
  assert.equal(known.estimate.tokens, 11500);
  assert.deepEqual(known.layers.map((l) => l.tokens), [1500, 5000, 5000]);
  // The history of a report task is not the history of a pr task of the same tier.
  const partial = plan([['S', 'pr'], ['M', 'pr'], ['L', 'pr']]);
  assert.equal(partial.estimate.tokens, null);
  assert.deepEqual(partial.layers.map((l) => l.tokens), [null, 5000, null]);
});

// ── The outcomes issue and comment ───────────────────────────────────────────────────────────────

test('E1. an issue layer and a comment layer follow the report phases, and they are delivered only with a record of what went out', () => {
  const root = tempRoot();
  const id = initRun(root, { title: 'Triage', checkout: CHECKOUT, request: 'r', kind: 'tasks', date: '2026-11-06', layers: [
    { task: 'Triage the crash reports', source: 'request', tier: 'M', tierReason: 'r', outcome: 'issue' },
    { task: 'Review PR 41', source: '#41', tier: 'S', tierReason: 'r', outcome: 'comment' },
    { task: 'Fix the top crash', source: 'request', tier: 'M', tierReason: 'r', dependsOn: [1] },
    { task: 'Find the cause', source: 'request', tier: 'S', tierReason: 'r', outcome: 'report' },
  ] }).id;
  const set = (layer, ...pairs) => cli(root, 'layer', '--run', id, '--layer', layer, ...pairs.flatMap((p) => ['--set', p]));
  // A pr task can wait for an issue task: it changes no code. It still waits until that task is delivered.
  assert.equal(readRun(root, id).next, 'l1');
  assert.deepEqual(readRun(root, id).layers.find((l) => l.id === 'l3').waitsFor, ['l1']);

  assert.equal(set('l1', 'phase=implementing').code, 0);
  // No PR phase, and no PR.
  assert.match(set('l1', 'phase=opening_pr').stderr, /l1 is an issue layer: it has no phase opening_pr/);
  assert.match(set('l1', 'pr=7').stderr, /is an issue layer: it has no PR/);
  assert.equal(set('l1', 'phase=review', 'round=1').code, 0);
  // Delivered needs the draft file, and the record of what went out.
  assert.match(set('l1', 'phase=delivered').stderr, /set report=reports\/report-<slug>.md before phase=delivered/);
  writeFileSync(path.join(root, id, 'reports', 'report-triage.md'), '## Issue: crash on save');
  assert.match(set('l1', 'report=reports/report-triage.md', 'phase=delivered').stderr, /is an issue layer: set delivery=/);
  assert.equal(readRun(root, id).layers[0].phase, 'review');
  assert.equal(set('l1', 'report=reports/report-triage.md', 'delivery=#101, #102', 'phase=delivered').code, 0);
  assert.match(cli(root, 'show', '--run', id).stdout, /issue reports\/report-triage.md \(#101, #102\)/);
  // The task that waited can start now.
  assert.deepEqual(readRun(root, id).layers.find((l) => l.id === 'l3').waitsFor, []);

  // A comment that the user declined is delivered too, with the reason.
  writeFileSync(path.join(root, id, 'reports', 'report-review-41.md'), 'draft');
  assert.equal(set('l2', 'phase=implementing').code, 0);
  assert.match(set('l2', 'report=reports/report-review-41.md', 'phase=delivered').stderr, /is a comment layer: set delivery=/);
  assert.equal(set('l2', 'report=reports/report-review-41.md', 'delivery=not sent: the user declined', 'phase=delivered').code, 0);

  // A report layer and a pr layer send nothing, so they have no delivery.
  assert.match(set('l4', 'delivery=#5').stderr, /is a report layer: nothing of it goes out/);
  assert.match(set('l3', 'delivery=#5').stderr, /is a pr layer: it has no delivery/);
  assert.match(set('l4', `delivery=${'x'.repeat(1001)}`).stderr, /longer than 1000 characters/);
  // What went out is one line of text, not a blank.
  assert.match(set('l2', 'delivery=   ').stderr, /delivery is required/);
  assert.match(set('l2', 'delivery=a\nb').stderr, /delivery must be one line/);
  assert.match(cli(root, 'show', '--run', id, '--layer', 'l1').stdout, /outcome issue; report reports\/report-triage.md; delivery #101, #102/);
  assert.match(cli(root, 'show', '--run', id, '--layer', 'l4').stdout, /outcome report; report -\n/);
  assert.equal(readRun(root, id).layers.find((l) => l.id === 'l4').delivery ?? null, null);
});

test('E2. the outcome of a queued layer can change to issue or comment, and a change away from them drops the delivery', () => {
  const root = tempRoot();
  const id = newRun(root, 2, {}, { kind: 'tasks' });
  const set = (layer, ...pairs) => cli(root, 'layer', '--run', id, '--layer', layer, ...pairs.flatMap((p) => ['--set', p]));
  assert.equal(set('l1', 'outcome=comment', 'delivery=https://github.com/o/r/pull/4#pullrequestreview-9').code, 0);
  assert.equal(set('l2', 'dependsOn=l1').code, 0);
  // A task waits for l1, so l1 cannot become a pr task in a tasks run.
  assert.match(set('l1', 'outcome=pr').stderr, /in a tasks run, a task can wait only for a report task/);
  assert.equal(set('l1', 'outcome=report').code, 0);
  assert.equal(readRun(root, id).layers[0].delivery, null);
  assert.match(set('l1', 'outcome=email').stderr, /outcome must be one of/);
});

test('E3. [review] the send step of an issue layer: park on a session-only question, answer, unpark, record each item, deliver', () => {
  for (const kind of ['tasks', 'stack']) {
    const root = tempRoot();
    const id = initRun(root, { title: 'Triage', checkout: CHECKOUT, request: 'r', kind, date: '2026-11-06', layers: [{ task: 'Triage', source: 'request', tier: 'S', tierReason: 'r', outcome: 'issue' }, { task: 'Fix', source: 'request', tier: 'S', tierReason: 'r', dependsOn: [1] }] }).id;
    const set = (...pairs) => cli(root, 'layer', '--run', id, '--layer', 'l1', ...pairs.flatMap((p) => ['--set', p]));
    const tip = 'a'.repeat(40);
    writeFileSync(path.join(root, id, 'reports', 'report-triage.md'), 'report');
    assert.equal(set('phase=implementing').code, 0);
    assert.equal(set('phase=review', 'round=1', 'report=reports/report-triage.md').code, 0);
    const q1 = JSON.parse(cli(root, 'park', '--run', id, '--layer', 'l1', '--session-only', '--question', 'File 2 issues in o/r?', '--option', 'send', '--option', 'do not send', '--tip', tip).stdout).id;
    // The page cannot answer it with no setting, and a parked layer cannot be delivered.
    assert.equal(cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'send', '--via', 'dashboard').code, 1);
    assert.match(set('delivery=#1', 'phase=delivered').stderr, /l1 is parked: unpark it before phase=delivered/);
    assert.equal(readRun(root, id).layers[0].delivery ?? null, null);
    assert.equal(cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'send').code, 0);
    assert.equal(cli(root, 'unpark', '--run', id, '--layer', 'l1', '--base', 'main', '--base-tip', tip, '--head', tip).code, 0, kind);
    // One record after each item, so a resume knows what went out.
    assert.equal(set('delivery=https://github.com/o/r/issues/1').code, 0);
    assert.equal(readRun(root, id).layers[0].phase, 'review');
    assert.equal(set('delivery=https://github.com/o/r/issues/1, https://github.com/o/r/issues/2').code, 0);
    assert.equal(set('phase=delivered').code, 0);
    assert.equal(readRun(root, id).next, 'l2');
    // More changes later: the old record stays until the new one replaces it.
    assert.equal(set('phase=fixing').code, 0);
    assert.equal(readRun(root, id).layers[0].delivery, 'https://github.com/o/r/issues/1, https://github.com/o/r/issues/2');
  }
});

// ── One writer, and report layers in parallel ────────────────────────────────────────────────────

test('W1. a layer starts only when no other layer is in work; a parked layer and a layer with its outcome do not count', () => {
  const root = tempRoot();
  const id = newRun(root, 4);
  const set = (layer, ...pairs) => cli(root, 'layer', '--run', id, '--layer', layer, ...pairs.flatMap((p) => ['--set', p]));
  assert.equal(set('l1', 'phase=implementing').code, 0);
  const refused = set('l2', 'phase=implementing');
  assert.equal(refused.code, 1);
  assert.match(refused.stderr, /layer l2 cannot start: l1 is in work, and one checkout has one writer/);
  // The message never tells how to get past the rule.
  assert.doesNotMatch(refused.stderr, /parallel=/);
  assert.equal(readRun(root, id).layers.find((l) => l.id === 'l2').phase, 'queued');
  // The same in every phase in which an agent works on l1.
  for (const phase of ['review', 'fixing', 'final_checks', 'opening_pr']) {
    assert.equal(set('l1', `phase=${phase}`).code, 0);
    assert.equal(set('l2', 'phase=implementing').code, 1, phase);
  }
  // A PR that is open: l1 has its outcome, so l2 can start.
  assert.equal(set('l1', 'phase=pr_open').code, 0);
  assert.equal(set('l2', 'phase=implementing').code, 0);
  // A parked layer waits for the user: nobody works on it.
  cli(root, 'park', '--run', id, '--layer', 'l2', '--question', 'q', '--tip', 'a'.repeat(40));
  assert.equal(set('l3', 'phase=implementing').code, 0);
  // More changes on l1 (pr_open to fixing) is not a start, and the ledger does not judge it.
  assert.equal(set('l1', 'phase=fixing').code, 0);
  assert.deepEqual(JSON.parse(cli(root, 'next', '--run', id).stdout), { next: 'l4', ready: [{ id: 'l4', outcome: 'pr', alone: true }], working: [{ id: 'l1', outcome: 'pr', phase: 'fixing' }, { id: 'l3', outcome: 'pr', phase: 'implementing' }], parallel: 1 });
});

test('W2. report layers work at the same time up to the limit of the run, and never with a pr layer', () => {
  const root = tempRoot();
  const entry = (task, outcome, extra = {}) => ({ task, source: 's', tier: 'S', tierReason: 'r', outcome, ...extra });
  const id = initRun(root, { title: 'Audit', checkout: CHECKOUT, request: 'r', kind: 'tasks', date: '2026-11-06', layers: [entry('a', 'report'), entry('b', 'issue'), entry('c', 'comment'), entry('d', 'report'), entry('e', 'pr'), entry('f', 'report', { dependsOn: [1] })] }).id;
  const set = (layer, ...pairs) => cli(root, 'layer', '--run', id, '--layer', layer, ...pairs.flatMap((p) => ['--set', p]));
  const next = () => JSON.parse(cli(root, 'next', '--run', id).stdout);
  // l6 waits for l1, so it is not ready.
  assert.deepEqual(next().ready.map((l) => l.id), ['l1', 'l2', 'l3', 'l4', 'l5']);
  // The default is one at a time, also for report layers.
  assert.equal(set('l1', 'phase=implementing').code, 0);
  const full = set('l2', 'phase=implementing');
  assert.match(full.stderr, /1 report layer works now \(l1\), and this run permits 1 at the same time/);
  assert.doesNotMatch(full.stderr, /--set/);

  for (const bad of ['0', '5', 'many']) assert.equal(cli(root, 'run', '--run', id, '--set', `parallel=${bad}`).code, 1, bad);
  assert.equal(cli(root, 'run', '--run', id, '--set', 'parallel=3').code, 0);
  assert.equal(set('l2', 'phase=implementing').code, 0);
  assert.equal(set('l3', 'phase=implementing').code, 0);
  assert.match(set('l4', 'phase=implementing').stderr, /3 report layers work now \(l1, l2, l3\), and this run permits 3/);
  // A pr layer never starts while a report layer is in work, whatever the limit.
  assert.match(set('l5', 'phase=implementing').stderr, /layer l5 cannot start: l1, l2, l3 are in work/);
  // The group keeps the order in which its layers started.
  assert.match(cli(root, 'show', '--run', id).stdout, /1\. l1 [^\n]*\n[^\n]*\n  2\. l2 [^\n]*\n[^\n]*\n  3\. l3 /);
  assert.match(cli(root, 'show', '--run', id).stdout, /in work: l1 \(implementing\), l2 \(implementing\), l3 \(implementing\); report layers at the same time: at most 3/);
  assert.deepEqual([next().working.length, next().parallel], [3, 3]);

  // One report is delivered: the next report can start, and l6 becomes ready.
  writeFileSync(path.join(root, id, 'reports', 'report-a.md'), 'x');
  assert.equal(set('l1', 'report=reports/report-a.md', 'phase=delivered').code, 0);
  assert.equal(set('l4', 'phase=implementing').code, 0);
  assert.deepEqual(next().ready.map((l) => l.id), ['l5', 'l6']);
  // And no report layer starts while a pr layer is in work.
  const other = tempRoot();
  const mixed = initRun(other, { title: 'Mixed', checkout: CHECKOUT, request: 'r', kind: 'tasks', date: '2026-11-06', layers: [entry('p', 'pr'), entry('r', 'report')] }).id;
  cli(other, 'run', '--run', mixed, '--set', 'parallel=4');
  assert.equal(cli(other, 'layer', '--run', mixed, '--layer', 'l1', '--set', 'phase=implementing').code, 0);
  assert.match(cli(other, 'layer', '--run', mixed, '--layer', 'l2', '--set', 'phase=implementing').stderr, /layer l2 cannot start: l1 is in work/);
});

test('W3. [review] the resume of a parked layer, a restack and a report that reads the code of a pr layer obey the one-writer rule', () => {
  const entry = (task, outcome, extra = {}) => ({ task, source: 's', tier: 'S', tierReason: 'r', outcome, ...extra });
  const tip = 'a'.repeat(40);
  // A tasks run: a parked pr task cannot come back while reports work; a parked report can, also over the limit.
  const root = tempRoot();
  const id = initRun(root, { title: 'Mix', checkout: CHECKOUT, request: 'r', kind: 'tasks', date: '2026-11-06', layers: [entry('p', 'pr'), entry('a', 'report'), entry('b', 'report'), entry('c', 'report')] }).id;
  const set = (layer, ...pairs) => cli(root, 'layer', '--run', id, '--layer', layer, ...pairs.flatMap((p) => ['--set', p]));
  const unpark = (layer) => cli(root, 'unpark', '--run', id, '--layer', layer, '--base', 'main', '--base-tip', tip, '--head', tip);
  cli(root, 'run', '--run', id, '--set', 'parallel=2');
  set('l1', 'phase=implementing');
  const q1 = JSON.parse(cli(root, 'park', '--run', id, '--layer', 'l1', '--question', 'q', '--tip', tip).stdout).id;
  assert.equal(set('l2', 'phase=implementing').code, 0);
  const q2 = JSON.parse(cli(root, 'park', '--run', id, '--layer', 'l2', '--question', 'q', '--tip', tip).stdout).id;
  assert.equal(set('l3', 'phase=implementing').code, 0);
  assert.equal(set('l4', 'phase=implementing').code, 0);
  cli(root, 'answer', '--run', id, '--id', q1, '--answer', 'a');
  cli(root, 'answer', '--run', id, '--id', q2, '--answer', 'a');
  const refused = unpark('l1');
  assert.equal(refused.code, 1);
  assert.match(refused.stderr, /layer l1 cannot resume: l3, l4 are in work, and one checkout has one writer/);
  assert.notEqual(readRun(root, id).layers.find((l) => l.id === 'l1').parked, null);
  // The answer of a report layer does not wait for a free place in the group.
  assert.equal(unpark('l2').code, 0);
  assert.equal(readRun(root, id).working.length, 3);
  // But it waits while a pr layer is in work.
  const other = tempRoot();
  const mixed = initRun(other, { title: 'Mix', checkout: CHECKOUT, request: 'r', kind: 'tasks', date: '2026-11-06', layers: [entry('a', 'report'), entry('p', 'pr')] }).id;
  cli(other, 'layer', '--run', mixed, '--layer', 'l1', '--set', 'phase=implementing');
  const q = JSON.parse(cli(other, 'park', '--run', mixed, '--layer', 'l1', '--question', 'q', '--tip', tip).stdout).id;
  cli(other, 'layer', '--run', mixed, '--layer', 'l2', '--set', 'phase=implementing');
  cli(other, 'answer', '--run', mixed, '--id', q, '--answer', 'a');
  assert.match(cli(other, 'unpark', '--run', mixed, '--layer', 'l1', '--base', 'main', '--base-tip', tip, '--head', tip).stderr, /layer l1 cannot resume: l2 is in work/);

  // A stack run: no start during a restack, and a report that reads the code of a pr layer works alone.
  const stackRoot = tempRoot();
  const stack = initRun(stackRoot, { title: 'Stack', checkout: CHECKOUT, request: 'r', kind: 'stack', date: '2026-11-06', layers: [entry('p', 'pr'), entry('a', 'report'), entry('b', 'report'), entry('m', 'report', { dependsOn: [1] }), entry('n', 'report', { dependsOn: [4] })] }).id;
  const sset = (layer, ...pairs) => cli(stackRoot, 'layer', '--run', stack, '--layer', layer, ...pairs.flatMap((p) => ['--set', p]));
  cli(stackRoot, 'run', '--run', stack, '--set', 'parallel=4');
  sset('l1', 'phase=implementing');
  sset('l1', 'phase=pr_open');
  cli(stackRoot, 'run', '--run', stack, '--set', 'stage=restack');
  assert.match(sset('l2', 'phase=implementing').stderr, /layer l2 cannot start: a restack runs/);
  cli(stackRoot, 'run', '--run', stack, '--set', 'stage=layers');
  // l4 reads the code of l1, and l5 waits for l4: both are marked, and l4 is never in a group.
  assert.deepEqual(JSON.parse(cli(stackRoot, 'next', '--run', stack).stdout).ready, [{ id: 'l2', outcome: 'report', alone: false }, { id: 'l3', outcome: 'report', alone: false }, { id: 'l4', outcome: 'report', alone: true }]);
  assert.equal(sset('l2', 'phase=implementing').code, 0);
  assert.equal(sset('l3', 'phase=implementing').code, 0);
  assert.match(sset('l4', 'phase=implementing').stderr, /layer l4 cannot start: l2, l3 are in work/);
  // The other direction: nothing starts while l4 works.
  for (const layer of ['l2', 'l3']) {
    writeFileSync(path.join(stackRoot, stack, 'reports', `report-${layer}.md`), 'x');
    assert.equal(sset(layer, `report=reports/report-${layer}.md`, 'phase=delivered').code, 0);
  }
  assert.equal(sset('l4', 'phase=implementing').code, 0);
  // The limit of a run stays after a finish and a reopen, and a finished run refuses a change of it.
  cli(stackRoot, 'run', '--run', stack, '--set', 'state=finished');
  assert.equal(cli(stackRoot, 'run', '--run', stack, '--set', 'parallel=1').code, 1);
  cli(stackRoot, 'run', '--run', stack, '--set', 'state=paused');
  assert.equal(JSON.parse(cli(stackRoot, 'next', '--run', stack).stdout).parallel, 4);
});
