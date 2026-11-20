/**
 * Tests for the admin reader and server. Run them by hand:
 *   node --test <plugin>/admin/test/*.test.mjs
 */
import { strict as assert } from 'node:assert';
import { spawn } from 'node:child_process';
import { appendFileSync, chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import { tmpdir } from 'node:os';
import * as path from 'node:path';
import process from 'node:process';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { STALE_MS, columnOf, isStale, listRuns, phaseTimes, readBoard, readRun } from '../reader.mjs';
import { adminRecordsMerges, ghPrState, startAdminServer } from '../server.mjs';
import { IDS, addOutsideLink, buildFixtureRoot } from './fixture.mjs';

const SERVER = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'server.mjs');
const MIN = 60_000;

/** A raw request, so that the test controls the path and the Host header exactly. */
function request(server, pathname, { method = 'GET', host, headers = {} } = {}) {
  const { port } = server.address();
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: pathname, method, headers: { host: host ?? `127.0.0.1:${port}`, ...headers } }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => (body += chunk));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

const json = (res) => JSON.parse(res.body);

let root;
let end;
let server;

before(async () => {
  root = mkdtempSync(path.join(tmpdir(), 'task-manager-admin-'));
  end = Date.now();
  buildFixtureRoot(root, { end });
  const secret = path.join(mkdtempSync(path.join(tmpdir(), 'secret-')), 'secret.md');
  writeFileSync(secret, 'SECRET');
  addOutsideLink(root, secret);
  server = await startAdminServer({ root, port: 0 });
});

after(() => server.close());

// ── Reader ───────────────────────────────────────────────────────────────────────────────────────

test('R1. listRuns reads every run, reports broken, old-format and other-schema folders, and skips the rest', () => {
  const { runs, broken } = listRuns(root, { at: end });
  assert.deepEqual(runs.map((r) => r.id).sort(), [IDS.finished, IDS.main, IDS.stale, IDS.torn, IDS.tasks, IDS.oneTask, IDS.finishedTasks].sort());
  const reasons = Object.fromEntries(broken.map((b) => [b.id, b.error]));
  assert.deepEqual(Object.keys(reasons).sort(), [IDS.broken, IDS.oldFormat, IDS.otherSchema, IDS.badKind].sort());
  assert.match(reasons[IDS.badKind], /unknown kind "queue"/);
  assert.match(reasons[IDS.oldFormat], /old format/);
  assert.match(reasons[IDS.otherSchema], /schema version 2/);
  const main = runs.find((r) => r.id === IDS.main);
  assert.equal(main.openQuestions, 2);
  assert.equal(main.done, 1);
  assert.equal(main.prsOpen, 1);
  assert.equal(main.prsMerged, 0);
  assert.equal(runs.find((r) => r.id === IDS.finished).prsMerged, 1);
  assert.equal(main.stage, 'layers');
});

test('R2. the columns, blocked layers, waiting layers and next layer follow the skill rules', () => {
  const state = readRun(root, IDS.main, { at: end });
  const by = Object.fromEntries(state.layers.map((l) => [l.id, l]));
  assert.deepEqual(state.layers.map((l) => l.id), ['l1', 'l4', 'l2', 'l3', 'l5', 'l6']);
  assert.equal(by.l1.column, 'done');
  assert.equal(by.l4.column, 'in_progress');
  assert.equal(by.l2.column, 'needs_input');
  assert.equal(by.l3.column, 'todo');
  assert.deepEqual(by.l3.blockedBy, ['l2']);
  assert.deepEqual(by.l5.blockedBy, []);
  assert.deepEqual(by.l5.waitsFor, ['l4']);
  assert.equal(state.next, 'l6');
  assert.equal(by.l4.openFindings, 2);
  assert.equal(by.l1.openFindings, 0);
  assert.deepEqual(state.openQuestions.map((q) => q.id), ['q1', 'q2']);
  // The main plans come first.
  assert.deepEqual(state.plans, ['main-undo-timeline-plan.md', 'plan-outside.md', 'plan-typing-groups.md', 'plan-undo-chapter-moves.md']);
  // An open question about a layer puts it in needs_input in any phase; an answered one does not.
  assert.equal(columnOf({ id: 'l9', phase: 'pr_open', parked: null }, [{ layer: 'l9', answer: null }]), 'needs_input');
  assert.equal(columnOf({ id: 'l9', phase: 'pr_open', parked: null }, []), 'done');
  // A parked layer stays in needs_input after its answer, until the skill unparks it.
  assert.equal(columnOf({ id: 'l9', phase: 'review', parked: { question: 'q9' } }, []), 'needs_input');
});

test('R3. phaseTimes reads the default summaries, skips others, and stops a finished run at its last event', () => {
  const state = readRun(root, IDS.main, { at: end });
  assert.deepEqual(state.phaseTimes.l1, { implementing: 20 * MIN, review: 15 * MIN, final_checks: 5 * MIN, opening_pr: 5 * MIN, pr_open: 65 * MIN });
  // l4: implementing 10, review 30 to 10 (the custom summary at 20 is skipped), then review again to now.
  assert.deepEqual(state.phaseTimes.l4, { implementing: 10 * MIN, review: 30 * MIN });
  const finished = readRun(root, IDS.finished, { at: end });
  // The time goes to the phase that was open (implementing); no time counts after `merged`.
  assert.deepEqual(finished.phaseTimes.l1, { implementing: 30 * MIN });
  const torn = readRun(root, IDS.torn, { at: end });
  assert.deepEqual(Object.keys(torn.phaseTimes.l1), ['implementing']);
  assert.deepEqual(phaseTimes([{ type: 'layer_phase', layer: 'l1', ts: 'x', summary: 'queued -> review' }], new Date(end).toISOString()), {});
});

test('R4. isStale: only an active run with no open question and an event older than 60 minutes', () => {
  const last = Date.parse('2026-11-13T10:00:00.000Z');
  const events = [{ ts: '2026-11-13T10:00:00.000Z' }];
  const active = { state: 'active', created: '2026-11-13T09:00:00.000Z' };
  assert.equal(STALE_MS, 60 * MIN);
  assert.equal(isStale(active, events, [], last + 61 * MIN), true);
  assert.equal(isStale(active, events, [], last + 59 * MIN), false);
  assert.equal(isStale({ ...active, state: 'paused' }, events, [], last + 120 * MIN), false);
  assert.equal(isStale(active, events, [{ id: 'q', answer: null }], last + 120 * MIN), false);
  assert.equal(isStale(active, [], [], Date.parse(active.created) + 61 * MIN), true);
  const { runs } = listRuns(root, { at: end });
  assert.deepEqual(runs.filter((r) => r.stale).map((r) => r.id), [IDS.stale]);
});

test('R7. kind: a run.json with no kind is a stack run; a tasks run keeps its kind, its CI and its main plans', () => {
  const stack = readRun(root, IDS.main, { at: end });
  assert.equal(stack.run.kind, 'stack');
  assert.deepEqual(stack.run.mainPlans, []);
  assert.ok(stack.layers.every((l) => l.ci === null));
  const tasks = readRun(root, IDS.tasks, { at: end });
  assert.equal(tasks.run.kind, 'tasks');
  assert.deepEqual(tasks.run.mainPlans.map((p) => p.path), ['plans/main-small-fixes-plan.md']);
  assert.deepEqual(tasks.plans, ['main-small-fixes-plan.md', 'plan-toast-copy.md']);
  const by = Object.fromEntries(tasks.layers.map((l) => [l.id, l]));
  assert.deepEqual(by.l1.ci, { runUrl: 'https://github.com/example/app/actions/runs/1', result: 'fail' });
  assert.equal(by.l3.ci, null);
  // Each column of a task follows the same rules as a layer.
  assert.deepEqual(tasks.layers.map((l) => [l.id, l.column]), [['l1', 'done'], ['l2', 'needs_input'], ['l3', 'todo'], ['l4', 'in_progress']]);
  // The last event of each task; a task with no event has null.
  assert.equal(by.l1.lastEvent, new Date(end - 30 * MIN).toISOString());
  assert.equal(by.l3.lastEvent, null);
  const listed = Object.fromEntries(listRuns(root, { at: end }).runs.map((r) => [r.id, r.kind]));
  assert.equal(listed[IDS.main], 'stack');
  assert.equal(listed[IDS.tasks], 'tasks');
  const board = readBoard(root, { at: end }).runs.find((e) => e.run.id === IDS.oneTask);
  assert.equal(board.run.kind, 'tasks');
  assert.equal(board.layers[0].ci.result, 'pass');
});

test('R5. a torn last line is reported and skipped, and the earlier lines are read', () => {
  const state = readRun(root, IDS.torn, { at: end });
  assert.equal(state.errors.length, 1);
  assert.match(state.errors[0], /events\.jsonl:\d+: line does not parse/);
  assert.equal(state.events.at(-1).type, 'note');
});

test('R6. readBoard gives every run with its layers, open questions and parked questions, and the broken folders', () => {
  const { runs, broken } = readBoard(root, { at: end });
  assert.deepEqual(runs.map((e) => e.run.id).sort(), [IDS.finished, IDS.main, IDS.stale, IDS.torn, IDS.tasks, IDS.oneTask, IDS.finishedTasks].sort());
  assert.equal(broken.length, 4);
  const main = runs.find((e) => e.run.id === IDS.main);
  assert.deepEqual(main.layers.map((l) => [l.id, l.column]), readRun(root, IDS.main, { at: end }).layers.map((l) => [l.id, l.column]));
  assert.equal(main.next, 'l6');
  assert.equal(main.run.checkout, '/Users/dev/projects/app-alpha');
  // The Tasks view reads `plans` from each board entry to decide if a report link is safe.
  for (const entry of runs) assert.deepEqual(entry.plans, readRun(root, entry.run.id, { at: end }).plans);
  // q1 (parked l2) and q2 (run) are open; q3 is answered and belongs to no parked layer.
  assert.deepEqual(main.questions.map((q) => q.id), ['q1', 'q2']);
  assert.deepEqual(main.openQuestions.map((q) => q.id), ['q1', 'q2']);
  assert.equal('events' in main, false);
});

// ── Server ───────────────────────────────────────────────────────────────────────────────────────

test('S1. GET /api/runs returns the runs and the broken folders', async () => {
  const res = await request(server, '/api/runs');
  assert.equal(res.status, 200);
  const { runs, broken } = json(res);
  assert.equal(runs.length, 7);
  assert.equal(broken.length, 4);
});

test('S2. GET /api/runs/<id> returns the derived values; a broken folder returns 200 with broken', async () => {
  const body = json(await request(server, `/api/runs/${IDS.main}`));
  assert.deepEqual(body.layers.map((l) => [l.id, l.column]), readRun(root, IDS.main).layers.map((l) => [l.id, l.column]));
  assert.equal(body.next, 'l6');
  const brokenRes = await request(server, `/api/runs/${IDS.broken}`);
  assert.equal(brokenRes.status, 200);
  assert.deepEqual(json(brokenRes), { id: IDS.broken, broken: 'run.json does not parse' });
});

test('S3. a bad id returns 400, an unknown id 404', async () => {
  for (const bad of ['..%2F..%2Fetc', '2026-11-13-UNDO', '2026-11-13-a%20b', '%E0%A4%A']) {
    assert.equal((await request(server, `/api/runs/${bad}`)).status, 400, bad);
  }
  assert.equal((await request(server, '/api/runs/2026-01-01-no-such-run')).status, 404);
  // A dot segment is removed by URL parsing before routing, so the route does not match.
  assert.equal((await request(server, '/api/runs/%2E%2E')).status, 404);
});

test('S4. the plan route returns a plan as text; bad names, missing plans and links outside the run fail', async () => {
  const res = await request(server, `/api/runs/${IDS.main}/plans/plan-undo-chapter-moves.md`);
  assert.equal(res.status, 200);
  assert.match(res.headers['content-type'], /^text\/plain/);
  assert.match(res.body, /<script>alert\("not run"\)<\/script>/);
  for (const [name, status] of [
    ['notes.txt', 400],
    ['..%2Frun.json', 400],
    ['plan-none.md', 404],
    ['plan-outside.md', 404],
  ]) {
    const r = await request(server, `/api/runs/${IDS.main}/plans/${name}`);
    assert.equal(r.status, status, name);
    assert.doesNotMatch(r.body, /SECRET|"schema"/, name);
  }
});

test('S4b. the plan route returns a main plan, and the main plans of another run are not there', async () => {
  const res = await request(server, `/api/runs/${IDS.tasks}/plans/main-small-fixes-plan.md`);
  assert.equal(res.status, 200);
  assert.match(res.body, /Small fixes \(the user's plan\)/);
  assert.equal((await request(server, `/api/runs/${IDS.tasks}/plans/main-undo-timeline-plan.md`)).status, 404);
  assert.equal((await request(server, `/api/runs/${IDS.tasks}/plans/main-.md`)).status, 400);
});

test('S5. only the page files are served; any other path is 404', async () => {
  const page = await request(server, '/');
  assert.equal(page.status, 200);
  assert.match(page.headers['content-type'], /^text\/html/);
  assert.match(page.headers['content-security-policy'], /default-src 'none'/);
  assert.equal((await request(server, '/admin/admin.js')).status, 200);
  assert.equal((await request(server, '/admin/admin.css')).status, 200);
  for (const p of ['/admin/../server.mjs', '/admin/%2e%2e/server.mjs', '/server.mjs', '/admin/index.html', '/page/admin.js', '/admin/']) {
    const res = await request(server, p);
    assert.equal(res.status, 404, p);
    assert.doesNotMatch(res.body, /createHandler/, p);
  }
});

test('S6. a request with another Host returns 403, and no answer allows other origins', async () => {
  const { port } = server.address();
  for (const host of [`evil.example:${port}`, 'evil.example', `127.0.0.1:${port + 1}`]) {
    assert.equal((await request(server, '/api/runs', { host })).status, 403, host);
  }
  assert.equal((await request(server, '/api/runs', { host: `localhost:${port}` })).status, 200);
  for (const p of ['/', '/api/runs', `/api/runs/${IDS.main}`, '/nothing']) {
    assert.equal((await request(server, p)).headers['access-control-allow-origin'], undefined, p);
  }
});

test('S7. a method other than GET returns 405', async () => {
  for (const method of ['POST', 'PUT', 'DELETE']) {
    const res = await request(server, '/api/runs', { method });
    assert.equal(res.status, 405, method);
    assert.equal(res.headers.allow, 'GET');
  }
});

test('S8. the server listens on 127.0.0.1 only', () => {
  assert.equal(server.address().address, '127.0.0.1');
});

test('S9. a port in use makes the script exit 1 with a message that names --port', async () => {
  const { port } = server.address();
  const child = spawn(process.execPath, [SERVER, '--port', String(port), '--root', root]);
  let stderr = '';
  child.stderr.on('data', (chunk) => (stderr += chunk));
  const code = await new Promise((resolve) => child.on('exit', resolve));
  assert.equal(code, 1);
  assert.match(stderr, /in use.*--port/);
});

test('S10. GET /api/board returns every run for the board', async () => {
  const res = await request(server, '/api/board');
  assert.equal(res.status, 200);
  const { runs, broken } = json(res);
  assert.equal(runs.length, 7);
  assert.equal(broken.length, 4);
  assert.ok(runs.every((e) => Array.isArray(e.layers) && e.run.id));
});

// ── Mark as finished ─────────────────────────────────────────────────────────────────────────────

/** A stub of the skill's helper: it records how it was called, then acts like `run --set state=...` or `layer --set phase=...`. */
const STUB = `
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import * as path from 'node:path';
const args = process.argv.slice(2);
const root = process.env.TASK_MANAGER_RUNS;
const id = args[args.indexOf('--run') + 1];
writeFileSync(path.join(root, id, 'helper-call.json'), JSON.stringify({ args, cwd: process.cwd() }));
appendFileSync(path.join(root, id, 'helper-calls.jsonl'), JSON.stringify(args) + '\\n');
if (process.env.STUB_FAIL || args.includes('fail')) { process.stderr.write('error: run is locked by process 42\\n'); process.exit(1); }
if (args[0] === 'event') process.exit(0);
const file = path.join(root, id, 'run.json');
const run = JSON.parse(readFileSync(file, 'utf8'));
const value = args[args.indexOf('--set') + 1].split('=')[1];
if (args[0] === 'layer') run.layers.find((l) => l.id === args[args.indexOf('--layer') + 1]).phase = value;
else run.state = value;
writeFileSync(file, JSON.stringify(run));
process.stdout.write(JSON.stringify({ run: id }) + '\\n');
`;

/** A root with one active run whose clone exists, and a server whose helper is `helper`. */
async function finishSetup(helperBody = STUB, prState = undefined, runStateValue = 'active') {
  const own = mkdtempSync(path.join(tmpdir(), 'task-manager-finish-'));
  const ownRoot = path.join(own, 'runs');
  buildFixtureRoot(ownRoot, { end: Date.now() });
  const checkout = path.join(own, 'clone');
  mkdirSync(checkout);
  const file = path.join(ownRoot, IDS.main, 'run.json');
  writeFileSync(file, JSON.stringify({ ...JSON.parse(readFileSync(file, 'utf8')), checkout, state: runStateValue }));
  const helper = path.join(own, 'helper.mjs');
  writeFileSync(helper, helperBody);
  const s = await startAdminServer({ root: ownRoot, port: 0, helperFor: (c) => (c === checkout ? helper : path.join(c, 'no-helper.mjs')), prState });
  const origin = `http://127.0.0.1:${s.address().port}`;
  const finish = (id = IDS.main, headers = { origin, 'x-task-manager-admin': 'finish' }, method = 'POST') => request(s, `/api/runs/${id}/finish`, { method, headers });
  const stateOf = (id = IDS.main) => JSON.parse(readFileSync(path.join(ownRoot, id, 'run.json'), 'utf8')).state;
  const phaseOf = (layer, id = IDS.main) => JSON.parse(readFileSync(path.join(ownRoot, id, 'run.json'), 'utf8')).layers.find((l) => l.id === layer).phase;
  const helperCall = () => {
    try {
      return JSON.parse(readFileSync(path.join(ownRoot, IDS.main, 'helper-call.json'), 'utf8'));
    } catch {
      return null;
    }
  };
  return { s, ownRoot, checkout, finish, stateOf, origin, phaseOf, helperCall };
}

test('F1. POST finish runs the helper of the clone, in the clone, on this root, and returns the new state', async () => {
  const { s, ownRoot, checkout, finish, stateOf } = await finishSetup();
  try {
    const res = await finish();
    assert.equal(res.status, 200, res.body);
    assert.deepEqual(json(res), { id: IDS.main, state: 'finished' });
    assert.equal(stateOf(), 'finished');
    const call = JSON.parse(readFileSync(path.join(ownRoot, IDS.main, 'helper-call.json'), 'utf8'));
    assert.deepEqual(call.args, ['run', '--run', IDS.main, '--set', 'state=finished', '--summary', 'Marked finished in the task-manager admin UI']);
    assert.equal(realpath(call.cwd), realpath(checkout));
    // A second click: the run is finished now.
    assert.equal((await finish()).status, 409);
  } finally {
    s.close();
  }
});

function realpath(p) {
  return path.resolve(p).replace(/^\/private\//, '/');
}

test('F2. a write with no Origin, another Origin or no action header is 403, and GET or OPTIONS is 405', async () => {
  const { s, finish, stateOf, origin } = await finishSetup();
  try {
    assert.equal((await finish(IDS.main, { 'x-task-manager-admin': 'finish' })).status, 403);
    assert.equal((await finish(IDS.main, { origin: 'http://evil.example', 'x-task-manager-admin': 'finish' })).status, 403);
    assert.equal((await finish(IDS.main, { origin: `${origin}0`, 'x-task-manager-admin': 'finish' })).status, 403);
    assert.equal((await finish(IDS.main, { origin })).status, 403);
    assert.equal((await finish(IDS.main, { origin, 'x-task-manager-admin': 'other' })).status, 403);
    const get = await finish(IDS.main, { origin, 'x-task-manager-admin': 'finish' }, 'GET');
    assert.equal(get.status, 405);
    assert.equal(get.headers.allow, 'POST');
    const options = await finish(IDS.main, { origin: 'http://evil.example', 'access-control-request-method': 'POST' }, 'OPTIONS');
    assert.equal(options.status, 405);
    assert.equal(options.headers['access-control-allow-origin'], undefined);
    assert.equal(stateOf(), 'active');
  } finally {
    s.close();
  }
});

test('F3. a finished, broken or unknown run, a clone with no helper, and a helper error are refused', async () => {
  const { s, ownRoot, finish, stateOf } = await finishSetup();
  try {
    assert.equal((await finish(IDS.finished)).status, 409);
    assert.equal((await finish(IDS.broken)).status, 409);
    assert.equal((await finish('2026-01-01-no-such-run')).status, 404);
    assert.equal((await finish('..%2Fx')).status, 400);
    // The stale run's clone (/Users/dev/...) does not exist on this computer.
    const missing = await finish(IDS.stale);
    assert.equal(missing.status, 409);
    assert.match(json(missing).error, /does not exist/);
    assert.equal(stateOf(IDS.stale), 'active');
    // A clone that exists but has no helper.
    const tornFile = path.join(ownRoot, IDS.torn, 'run.json');
    writeFileSync(tornFile, JSON.stringify({ ...JSON.parse(readFileSync(tornFile, 'utf8')), checkout: ownRoot }));
    const noHelper = await finish(IDS.torn);
    assert.equal(noHelper.status, 409);
    assert.match(json(noHelper).error, /has no task-manager helper/);
  } finally {
    s.close();
  }
  const failing = await finishSetup(`${STUB.replace("if (process.env.STUB_FAIL || args.includes('fail'))", 'if (true)')}`);
  try {
    const res = await failing.finish();
    assert.equal(res.status, 409);
    assert.match(json(res).error, /helper did not make the change: run is locked by process 42/);
    assert.equal(failing.stateOf(), 'active');
  } finally {
    failing.s.close();
  }
});

// ── PR sync: GitHub says merged, the merge is recorded ───────────────────────────────────────────

/** A GitHub stub: `states` maps a PR number to its state. It counts the calls. */
function gitHub(states) {
  const calls = [];
  const prState = async ({ number, url }) => {
    calls.push([url, number]);
    const state = states[number] ?? 'OPEN';
    return { state, mergedAt: state === 'MERGED' ? '2026-11-13T12:00:00Z' : null, url: `https://github.com/example/app/pull/${number}` };
  };
  return { prState, calls };
}

test('P1. a paused run: GitHub says merged, so GET .../pr records the merge through the helper, with no summary', async () => {
  const gh = gitHub({ 901: 'MERGED' });
  const { s, ownRoot, checkout, phaseOf, helperCall } = await finishSetup(STUB, gh.prState, 'paused');
  try {
    const res = await request(s, `/api/runs/${IDS.main}/layers/l1/pr`);
    assert.equal(res.status, 200);
    assert.deepEqual(json(res), { number: 901, state: 'MERGED', mergedAt: '2026-11-13T12:00:00Z', url: 'https://github.com/example/app/pull/901', recorded: true });
    assert.equal(phaseOf('l1'), 'merged');
    // The phase change has no --summary: the phase times read the helper's default
    // "pr_open -> merged". Then the merge event, as the skill records it.
    const calls = readFileSync(path.join(ownRoot, IDS.main, 'helper-calls.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    assert.deepEqual(calls, [
      ['layer', '--run', IDS.main, '--layer', 'l1', '--set', 'phase=merged'],
      ['event', '--run', IDS.main, '--layer', 'l1', '--type', 'merge', '--summary', '#901'],
    ]);
    assert.equal(realpath(helperCall().cwd), realpath(checkout));
    // Asked by the PR URL, not by the number in the clone.
    assert.deepEqual(gh.calls, [['https://github.com/example/app/pull/901', 901]]);
    // Merged now: no more GitHub calls for it.
    assert.deepEqual(json(await request(s, `/api/runs/${IDS.main}/layers/l1/pr`)), { number: 901, phase: 'merged' });
    assert.equal(gh.calls.length, 1);
  } finally {
    s.close();
  }
});

test('P2. an active run that is not stale: the merge waits for its session, and nothing is written', async () => {
  const gh = gitHub({ 901: 'MERGED' });
  const { s, phaseOf, helperCall } = await finishSetup(STUB, gh.prState, 'active');
  try {
    const body = json(await request(s, `/api/runs/${IDS.main}/layers/l1/pr`));
    assert.equal(body.state, 'MERGED');
    assert.equal(body.waitsForSession, true);
    assert.equal(body.recorded, undefined);
    assert.equal(phaseOf('l1'), 'pr_open');
    assert.equal(helperCall(), null);
  } finally {
    s.close();
  }
});

test('P3. an open PR changes nothing, and a GitHub answer is kept for a minute', async () => {
  const gh = gitHub({ 901: 'OPEN' });
  const { s, phaseOf, helperCall } = await finishSetup(STUB, gh.prState, 'paused');
  try {
    for (let i = 0; i < 3; i += 1) {
      const body = json(await request(s, `/api/runs/${IDS.main}/layers/l1/pr`));
      assert.equal(body.state, 'OPEN');
      assert.equal(body.recorded, undefined);
    }
    assert.equal(gh.calls.length, 1);
    assert.equal(phaseOf('l1'), 'pr_open');
    assert.equal(helperCall(), null);
    assert.equal((await request(s, `/api/runs/${IDS.main}/layers/l4/pr`)).status, 404);
    assert.equal((await request(s, `/api/runs/${IDS.main}/layers/L1/pr`)).status, 400);
  } finally {
    s.close();
  }
});

test('P4. sweep records merges in the runs that the admin records, and leaves an active run to its session', async () => {
  const paused = gitHub({ 901: 'MERGED' });
  const one = await finishSetup(STUB, paused.prState, 'paused');
  try {
    await one.s.prSync.sweep();
    assert.equal(one.phaseOf('l1'), 'merged');
  } finally {
    one.s.close();
  }
  const active = gitHub({ 901: 'MERGED' });
  const two = await finishSetup(STUB, active.prState, 'active');
  try {
    await two.s.prSync.sweep();
    assert.equal(two.phaseOf('l1'), 'pr_open');
    // The fixture's other runs have no open PR, or a clone that does not exist: GitHub is asked
    // only about the paused or stale runs' open PRs, so the active main run causes no call.
    assert.ok(active.calls.every(([, number]) => number !== 901));
  } finally {
    two.s.close();
  }
});

test('P5. the merge button route is gone', async () => {
  const { s, origin } = await finishSetup();
  try {
    const res = await request(s, `/api/runs/${IDS.main}/layers/l1/merge`, { method: 'POST', headers: { origin, 'x-task-manager-admin': 'merge' } });
    assert.equal(res.status, 405);
  } finally {
    s.close();
  }
});

test('P6. adminRecordsMerges: paused, finished and stale runs yes; an active run that is not stale no', () => {
  assert.equal(adminRecordsMerges({ run: { state: 'paused' }, stale: false }), true);
  assert.equal(adminRecordsMerges({ run: { state: 'finished' }, stale: false }), true);
  assert.equal(adminRecordsMerges({ run: { state: 'active' }, stale: true }), true);
  assert.equal(adminRecordsMerges({ run: { state: 'active' }, stale: false }), false);
  // A tasks run: a merge starts nothing in its session, so the admin records it also while active.
  assert.equal(adminRecordsMerges({ run: { kind: 'tasks', state: 'active' }, stale: false }), true);
  assert.equal(adminRecordsMerges({ run: { kind: 'stack', state: 'active' }, stale: false }), false);
});

test('P7. ghPrState asks by the PR URL, and refuses a PR with no URL or an answer for another PR', async () => {
  const runs = [];
  const gh = (answer) => (args, done) => {
    runs.push(args);
    done(null, JSON.stringify(answer), '');
  };
  const url = 'https://github.com/example/design-system/pull/53';
  // The real case: PR #53 of another repo is open, while the clone's own #53 is merged.
  const open = await ghPrState({ number: 53, url }, gh({ state: 'OPEN', mergedAt: null, url }));
  assert.deepEqual(open, { state: 'OPEN', mergedAt: null, url });
  assert.deepEqual(runs[0], ['pr', 'view', url, '--json', 'state,mergedAt,url']);
  const other = await ghPrState({ number: 53, url }, gh({ state: 'MERGED', mergedAt: '2026-05-01T00:00:00Z', url: 'https://github.com/example/app/pull/53' }));
  assert.match(other.error, /answered for https:\/\/github.com\/example\/app\/pull\/53/);
  assert.equal(other.state, undefined);
  const noUrl = await ghPrState({ number: 53, url: null }, gh({ state: 'MERGED' }));
  assert.match(noUrl.error, /no URL/);
  assert.equal(runs.length, 2);
  // A trailing slash or a case difference is the same PR.
  assert.equal((await ghPrState({ number: 53, url: `${url}/` }, gh({ state: 'OPEN', url: url.toUpperCase() }))).state, 'OPEN');
});

test('P8. a merged answer for another PR records nothing', async () => {
  const wrong = async () => ({ error: 'GitHub answered for https://github.com/example/app/pull/901, not for the layer PR' });
  const { s, phaseOf, helperCall } = await finishSetup(STUB, wrong, 'paused');
  try {
    const body = json(await request(s, `/api/runs/${IDS.main}/layers/l1/pr`));
    assert.match(body.error, /answered for/);
    await s.prSync.sweep();
    assert.equal(phaseOf('l1'), 'pr_open');
    assert.equal(helperCall(), null);
  } finally {
    s.close();
  }
});

test('P9. sweep records a merge in an active tasks run, because no restack waits for it', async () => {
  const gh = gitHub({ 950: 'MERGED' });
  const { s, ownRoot, checkout, phaseOf } = await finishSetup(STUB, gh.prState, 'active');
  try {
    const file = path.join(ownRoot, IDS.tasks, 'run.json');
    writeFileSync(file, JSON.stringify({ ...JSON.parse(readFileSync(file, 'utf8')), checkout }));
    await s.prSync.sweep();
    assert.equal(phaseOf('l1', IDS.tasks), 'merged');
    // The active stack run in the same root still waits for its session.
    assert.equal(phaseOf('l1'), 'pr_open');
  } finally {
    s.close();
  }
});

// ── The helper and the root of a plugin install ─────────────────────────────────────────────────

test('H1. the helper is the one of this plugin; a bare copy of admin/ uses the clone\'s hand-installed skill', async () => {
  const { helperOf, OWN_HELPER, defaultRoot } = await import('../server.mjs');
  const { existsSync } = await import('node:fs');
  const { homedir } = await import('node:os');
  assert.equal(existsSync(OWN_HELPER), true, 'the plugin ships the ledger script next to admin/');
  assert.equal(helperOf('/some/clone'), OWN_HELPER);
  assert.equal(
    helperOf('/some/clone', '/no/such/helper.mjs'),
    path.join('/some/clone', '.claude', 'skills', 'task-manager', 'scripts', 'task-manager-ledger.mjs'),
  );
  assert.equal(defaultRoot({ TASK_MANAGER_RUNS: '/some/where' }), '/some/where');
  assert.equal(defaultRoot({}), path.join(homedir(), '.task-manager', 'runs'));
});

// ── Report tasks: the ledger writes them, the reader and the server show them ───────────────────

test('O1. a delivered report task is done, frees the task that waits for it, and its report is served', async () => {
  const core = await import('../../skills/task-manager/scripts/lib/task-manager-core.mjs');
  const ownRoot = mkdtempSync(path.join(tmpdir(), 'task-manager-admin-report-'));
  const entry = (task, extra = {}) => ({ task, source: 'request', tier: 'M', tierReason: 'r', dependsOn: [], ...extra });
  const { id } = core.initRun(ownRoot, {
    title: 'Slow export',
    checkout: '/Users/dev/projects/app-alpha',
    request: 'find the cause, then fix it',
    kind: 'tasks',
    layers: [entry('find the cause', { outcome: 'report' }), entry('fix it', { dependsOn: [1] })],
  });
  let state = readRun(ownRoot, id);
  assert.deepEqual(state.layers.map((l) => [l.id, l.outcome, l.column, l.waitsFor]), [['l1', 'report', 'todo', []], ['l2', 'pr', 'todo', ['l1']]]);
  assert.equal(state.next, 'l1');

  writeFileSync(path.join(ownRoot, id, 'reports', 'report-slow-export.md'), '# The cause\n');
  core.setLayer(ownRoot, id, 'l1', [['phase', 'implementing']]);
  core.setLayer(ownRoot, id, 'l1', [['report', 'reports/report-slow-export.md'], ['phase', 'delivered']]);
  state = readRun(ownRoot, id);
  const l1 = state.layers.find((l) => l.id === 'l1');
  assert.deepEqual([l1.phase, l1.column, l1.report], ['delivered', 'done', 'reports/report-slow-export.md']);
  assert.equal(state.next, 'l2');
  assert.deepEqual(state.plans, ['report-slow-export.md']);

  const s = await startAdminServer({ root: ownRoot, port: 0 });
  try {
    const res = await request(s, `/api/runs/${id}/plans/report-slow-export.md`);
    assert.equal(res.status, 200);
    assert.equal(res.body, '# The cause\n');
    // A report name is looked up in reports/ only: a plan of that name does not exist.
    assert.equal((await request(s, `/api/runs/${id}/plans/plan-slow-export.md`)).status, 404);
  } finally {
    s.close();
  }
});

// ── --open ──────────────────────────────────────────────────────────────────────────────────────

test('B1. --open opens the page of the new server; without --open nothing opens', async () => {
  const { main, openCommand } = await import('../server.mjs');
  const opened = [];
  const openUrl = (url) => opened.push(url);
  const quiet = await main(['--root', root, '--port', '0'], { openUrl });
  try {
    assert.deepEqual(opened, []);
  } finally {
    quiet.close();
  }
  const s = await main(['--root', root, '--port', '0', '--open'], { openUrl });
  try {
    assert.deepEqual(opened, [`http://127.0.0.1:${s.address().port}/`]);
    // The port is in use now: a second --open shows the page of the first server and starts nothing.
    const second = await main(['--root', root, '--port', String(s.address().port), '--open'], { openUrl });
    assert.equal(second, null);
    assert.deepEqual(opened.length, 2);
    assert.equal(opened[1], opened[0]);
    // Without --open, a used port is still an error.
    await assert.rejects(() => main(['--root', root, '--port', String(s.address().port)], { openUrl }), /is in use/);
  } finally {
    s.close();
  }
  assert.deepEqual(openCommand('http://x/', 'darwin'), ['open', ['http://x/']]);
  assert.deepEqual(openCommand('http://x/', 'linux'), ['xdg-open', ['http://x/']]);
  assert.deepEqual(openCommand('http://x/', 'win32'), ['cmd', ['/c', 'start', '""', 'http://x/']]);
});

// ── --stop ──────────────────────────────────────────────────────────────────────────────────────

test('S1. --stop stops the admin server on the port; another site cannot, and a free port is "no server"', async () => {
  const { main, stopAdminServer } = await import('../server.mjs');
  const s = await main(['--root', root, '--port', '0']);
  const port = s.address().port;
  const origin = `http://127.0.0.1:${port}`;
  // Refused: no header, a wrong action, the origin of another site, and a GET.
  assert.equal((await request(s, '/api/stop', { method: 'POST', headers: { origin } })).status, 403);
  assert.equal((await request(s, '/api/stop', { method: 'POST', headers: { origin, 'x-task-manager-admin': 'finish' } })).status, 403);
  assert.equal((await request(s, '/api/stop', { method: 'POST', headers: { origin: 'http://evil.example', 'x-task-manager-admin': 'stop' } })).status, 403);
  assert.equal((await request(s, '/api/stop', { headers: { origin, 'x-task-manager-admin': 'stop' } })).status, 405);
  assert.equal(s.listening, true);

  const closed = new Promise((done) => s.once('close', done));
  assert.equal(await main(['--stop', '--port', String(port)]), null);
  await closed;
  assert.equal(s.listening, false);
  // Nothing listens there now.
  assert.equal(await stopAdminServer(port), false);
  await assert.rejects(() => main(['--stop', '--open']), /--stop takes only --port/);
});

test('S2. --stop does not stop another program on the port', async () => {
  const { stopAdminServer } = await import('../server.mjs');
  const other = http.createServer((req, res) => res.end('{"stopped":false}'));
  await new Promise((done) => other.listen(0, '127.0.0.1', done));
  try {
    assert.equal(await stopAdminServer(other.address().port), false);
    assert.equal(other.listening, true);
  } finally {
    other.close();
  }
});

// ── Answer a question from the page ─────────────────────────────────────────────────────────────

/** A POST with a JSON body. `request` above sends no body. */
function post(server, pathname, body, headers) {
  return new Promise((done, reject) => {
    const text = typeof body === 'string' ? body : JSON.stringify(body);
    const req = http.request({ host: '127.0.0.1', port: server.address().port, path: pathname, method: 'POST', headers: { 'content-type': 'application/json', ...headers } }, (res) => {
      let raw = '';
      res.on('data', (chunk) => (raw += chunk));
      res.on('end', () => done({ status: res.statusCode, body: raw }));
    });
    req.on('error', reject);
    req.end(text);
  });
}

test('Q1. the page answers an open question through the real helper; the session-only question and bad requests are refused', async () => {
  const core = await import('../../skills/task-manager/scripts/lib/task-manager-core.mjs');
  const own = mkdtempSync(path.join(tmpdir(), 'task-manager-admin-answer-'));
  const ownRoot = path.join(own, 'runs');
  const checkout = path.join(own, 'clone');
  mkdirSync(checkout);
  const entry = (task) => ({ task, source: 'request', tier: 'M', tierReason: 'r', dependsOn: [] });
  const { id } = core.initRun(ownRoot, { title: 'Scroll position', checkout, request: 'do it', layers: [entry('a'), entry('b')] });
  const q1 = core.ask(ownRoot, id, { layer: 'l1', question: 'Per chapter or per window?', options: ['Per chapter', 'Per window'] }).id;
  const merge = core.ask(ownRoot, id, { question: 'Merge the stack?', sessionOnly: true }).id;

  const s = await startAdminServer({ root: ownRoot, port: 0 });
  const origin = `http://127.0.0.1:${s.address().port}`;
  const ok = { origin, 'x-task-manager-admin': 'answer' };
  const url = (q) => `/api/runs/${id}/questions/${q}/answer`;
  try {
    // Refused, and nothing is recorded: another site, no header, an empty answer, a body that is not JSON.
    assert.equal((await post(s, url(q1), { answer: 'Per window' }, { origin: 'http://evil.example', 'x-task-manager-admin': 'answer' })).status, 403);
    assert.equal((await post(s, url(q1), { answer: 'Per window' }, { origin })).status, 403);
    assert.equal((await post(s, url(q1), { answer: '   ' }, ok)).status, 400);
    assert.equal((await post(s, url(q1), 'not json', ok)).status, 400);
    assert.equal((await post(s, url(q1), { answer: 'x'.repeat(2001) }, ok)).status, 400);
    assert.equal((await post(s, url('q9'), { answer: 'x' }, ok)).status, 404);
    assert.equal(readRun(ownRoot, id).openQuestions.length, 2);

    // The merge yes stays in the session.
    const refused = await post(s, url(merge), { answer: 'yes' }, ok);
    assert.equal(refused.status, 409);
    assert.match(json(refused).error, /in the session only/);

    // An option with a comment. The text starts with a dash on purpose: it must not read as a CLI option.
    const waiting = core.waitForAnswer(ownRoot, id, { pollMs: 5, timeoutMs: 5000 });
    const res = await post(s, url(q1), { answer: '--Per window — keep the old key' }, ok);
    assert.equal(res.status, 200);
    assert.deepEqual(json(res), { id: q1, answer: '--Per window — keep the old key' });
    // The session's wait command ends with this answer.
    assert.deepEqual((await waiting).answered, [{ id: q1, layer: 'l1', answer: '--Per window — keep the old key', via: 'dashboard' }]);
    const saved = readRun(ownRoot, id).questions.find((q) => q.id === q1);
    assert.equal(saved.via, 'dashboard');
    // A second answer to the same question is refused.
    assert.equal((await post(s, url(q1), { answer: 'Per chapter' }, ok)).status, 409);
    assert.equal((await request(s, url(q1), { headers: ok })).status, 405);
  } finally {
    s.close();
  }
});

// ── Findings of the code review ─────────────────────────────────────────────────────────────────

test('V1. [review] a delivered report adds no time after its delivery, and a report file cannot lead out of the run', async () => {
  const core = await import('../../skills/task-manager/scripts/lib/task-manager-core.mjs');
  const { symlinkSync } = await import('node:fs');
  const own = mkdtempSync(path.join(tmpdir(), 'task-manager-admin-final-'));
  const ownRoot = path.join(own, 'runs');
  const entry = (task, extra = {}) => ({ task, source: 'request', tier: 'M', tierReason: 'r', dependsOn: [], ...extra });
  const { id } = core.initRun(ownRoot, { title: 'Final', checkout: own, request: 'r', kind: 'tasks', layers: [entry('find', { outcome: 'report' })] });
  writeFileSync(path.join(ownRoot, id, 'reports', 'report-find.md'), '# found\n');
  core.setLayer(ownRoot, id, 'l1', [['phase', 'implementing']]);
  core.setLayer(ownRoot, id, 'l1', [['report', 'reports/report-find.md'], ['phase', 'delivered']]);
  // One hour later, the run is still active: the delivered phase has no time that grows.
  const later = readRun(ownRoot, id, { at: Date.now() + 60 * 60_000 });
  assert.equal(later.phaseTimes.l1.delivered, undefined);
  assert.ok(later.phaseTimes.l1.implementing < 60_000);

  const secret = path.join(own, 'secret.md');
  writeFileSync(secret, 'outside');
  symlinkSync(secret, path.join(ownRoot, id, 'reports', 'report-outside.md'));
  const s = await startAdminServer({ root: ownRoot, port: 0 });
  try {
    assert.equal((await request(s, `/api/runs/${id}/plans/report-find.md`)).status, 200);
    const res = await request(s, `/api/runs/${id}/plans/report-outside.md`);
    assert.equal(res.status, 404);
    assert.doesNotMatch(res.body, /outside$/);
  } finally {
    s.close();
  }
});

test('V2. [review] a body over the limit gets 413 and records nothing; a relative runs root is refused', async () => {
  const core = await import('../../skills/task-manager/scripts/lib/task-manager-core.mjs');
  const { defaultRoot } = await import('../server.mjs');
  const own = mkdtempSync(path.join(tmpdir(), 'task-manager-admin-413-'));
  const ownRoot = path.join(own, 'runs');
  const { id } = core.initRun(ownRoot, { title: 'Big', checkout: own, request: 'r', layers: [{ task: 't', source: 's', tier: 'S', tierReason: 'r' }] });
  const q1 = core.ask(ownRoot, id, { question: 'A or B?' }).id;
  const s = await startAdminServer({ root: ownRoot, port: 0 });
  try {
    const origin = `http://127.0.0.1:${s.address().port}`;
    const res = await post(s, `/api/runs/${id}/questions/${q1}/answer`, { answer: 'x'.repeat(200_000) }, { origin, 'x-task-manager-admin': 'answer' });
    assert.equal(res.status, 413);
    assert.equal(readRun(ownRoot, id).openQuestions.length, 1);
    // The server still answers after it.
    assert.equal((await request(s, '/api/runs')).status, 200);
  } finally {
    s.close();
  }
  assert.throws(() => defaultRoot({ TASK_MANAGER_RUNS: 'runs' }), /must be an absolute path/);
});

// ── Start a session from the page ───────────────────────────────────────────────────────────────

test('P1. the page starts a session only with the user setting, through the real helper; the run then shows the session', async () => {
  const core = await import('../../skills/task-manager/scripts/lib/task-manager-core.mjs');
  const own = mkdtempSync(path.join(tmpdir(), 'task-manager-admin-session-'));
  const ownRoot = path.join(own, 'runs');
  const checkout = path.join(own, 'clone');
  mkdirSync(checkout);
  const fake = path.join(own, 'fake-session.mjs');
  writeFileSync(fake, '#!/usr/bin/env node\nsetTimeout(() => {}, 4000);\n');
  chmodSync(fake, 0o755);
  const { id } = core.initRun(ownRoot, { title: 'Scroll position', checkout, request: 'do it', layers: [{ task: 'a', source: 'request', tier: 'M', tierReason: 'r', dependsOn: [] }] });
  core.setRun(ownRoot, id, [['state', 'paused']]);
  const config = path.join(ownRoot, 'config.json');
  const s = await startAdminServer({ root: ownRoot, port: 0 });
  const origin = `http://127.0.0.1:${s.address().port}`;
  const ok = { origin, 'x-task-manager-admin': 'session' };
  const url = `/api/runs/${id}/session`;
  let pid = null;
  try {
    // Off: no settings file, a bad file, and a file that does not say `enabled: true`.
    assert.deepEqual(json(await request(s, '/api/settings')), { startSessions: false, confirmOnPage: false });
    assert.equal((await post(s, url, {}, ok)).status, 403);
    writeFileSync(config, '{ not json');
    assert.deepEqual(json(await request(s, '/api/settings')), { startSessions: false, confirmOnPage: false });
    writeFileSync(config, JSON.stringify({ resume: { enabled: 'yes', command: fake } }));
    assert.equal((await post(s, url, {}, ok)).status, 403);
    assert.deepEqual(json(await request(s, `/api/runs/${id}`)).session, { watching: false, started: null });

    writeFileSync(config, JSON.stringify({ resume: { enabled: true, command: fake } }));
    assert.deepEqual(json(await request(s, '/api/settings')), { startSessions: true, confirmOnPage: false });
    assert.equal((await post(s, url, {}, { origin: 'http://evil.example', 'x-task-manager-admin': 'session' })).status, 403);
    assert.equal((await post(s, url, {}, { origin, 'x-task-manager-admin': 'answer' })).status, 403);
    assert.equal((await request(s, url)).status, 405);
    assert.equal((await post(s, '/api/runs/2026-01-01-no-run/session', {}, ok)).status, 404);

    const res = await post(s, url, {}, ok);
    assert.equal(res.status, 200, res.body);
    pid = json(res).pid;
    assert.equal(Number.isInteger(pid), true);
    assert.equal(json(await request(s, `/api/runs/${id}`)).session.started.pid, pid);
    assert.equal(json(await request(s, '/api/board')).runs[0].session.started.pid, pid);
    // A second click while it runs: the helper refuses.
    const again = await post(s, url, {}, ok);
    assert.equal(again.status, 409);
    assert.match(json(again).error, /a started session works on run/);
  } finally {
    if (pid) {
      try {
        process.kill(pid);
      } catch {
        // It ended already.
      }
    }
    s.close();
  }
});

// ── Usage ────────────────────────────────────────────────────────────────────────────────────────

test('U1. the reader adds the usage for each layer, each role and each tier, and the board carries the layer sums', async () => {
  const core = await import('../../skills/task-manager/scripts/lib/task-manager-core.mjs');
  const { usageOf, sumUsage } = await import('../reader.mjs');
  const own = mkdtempSync(path.join(tmpdir(), 'task-manager-admin-usage-'));
  const ownRoot = path.join(own, 'runs');
  const entry = (task, tier) => ({ task, source: 'request', tier, tierReason: 'r', dependsOn: [] });
  const { id } = core.initRun(ownRoot, { title: 'Usage', checkout: own, request: 'do it', layers: [entry('a', 'S'), entry('b', 'M'), entry('c', 'M'), entry('d', 'L')] });
  const use = (fields) => core.addUsage(ownRoot, id, fields);
  use({ layer: 'l1', role: 'implementer', tokens: '1000', toolUses: '4', durationMs: '60000' });
  use({ layer: 'l1', role: 'reviewer', tokens: '500' });
  use({ layer: 'l1', role: 'implementer', tokens: '200' });
  use({ layer: 'l2', role: 'implementer', tokens: '3000' });
  use({ layer: 'l3', role: 'implementer', tokens: '5000', cost: '1.5' });
  use({ role: 'restacker', tokens: '700' });
  use({ role: 'verifier', tokens: '50' });
  use({ role: 'restacker', tokens: '300' });

  const { usage } = readRun(ownRoot, id);
  assert.deepEqual(usage.total, { agents: 8, tokens: 10750, toolUses: 4, durationMs: 60000, cost: 1.5 });
  assert.deepEqual(Object.keys(usage.layers), ['l1', 'l2', 'l3']);
  assert.deepEqual({ ...usage.layers.l1, roles: null }, { agents: 3, tokens: 1700, toolUses: 4, durationMs: 60000, cost: null, roles: null });
  assert.equal(usage.layers.l1.roles.implementer.tokens, 1200);
  assert.equal(usage.layers.l1.roles.reviewer.agents, 1);
  // The tier means count only the layers that have a record: l4 (tier L) has none.
  assert.deepEqual(Object.keys(usage.tiers).sort(), ['M', 'S']);
  assert.deepEqual([usage.tiers.M.layers, usage.tiers.M.tokens, usage.tiers.M.tokensPerLayer, usage.tiers.M.cost], [2, 8000, 4000, 1.5]);
  // The records with no layer show under their own role, not as a layer and not in a tier.
  assert.deepEqual(Object.keys(usage.runLevel).sort(), ['restacker', 'verifier']);
  assert.deepEqual([usage.runLevel.restacker.agents, usage.runLevel.restacker.tokens, usage.runLevel.verifier.tokens], [2, 1000, 50]);
  // A line that is valid JSON but not a record does not break the page.
  appendFileSync(path.join(ownRoot, id, 'usage.jsonl'), 'null\n[1]\n"x"\n');
  assert.equal(readRun(ownRoot, id).usage.total.agents, 8);
  assert.equal(readBoard(ownRoot).broken.length, 0);
  const board = readBoard(ownRoot).runs[0];
  assert.deepEqual(board.usage, { total: usage.total, layers: usage.layers });
  // A run from before this file has no usage, and nothing fails.
  assert.deepEqual(usageOf({ layers: [{ id: 'l1', tier: 'S' }] }, []), { total: sumUsage([]), layers: {}, tiers: {}, runLevel: {} });
  assert.equal(readRun(root, IDS.main, { at: end }).usage.total.agents, 0);
});

// ── A confirmed answer to a session-only question ───────────────────────────────────────────────

test('C1. the page answers a session-only question only with the user setting and the option typed exactly', async () => {
  const core = await import('../../skills/task-manager/scripts/lib/task-manager-core.mjs');
  const own = mkdtempSync(path.join(tmpdir(), 'task-manager-admin-confirm-'));
  const ownRoot = path.join(own, 'runs');
  const checkout = path.join(own, 'clone');
  mkdirSync(checkout);
  const entry = (task) => ({ task, source: 'request', tier: 'M', tierReason: 'r', dependsOn: [] });
  const { id } = core.initRun(ownRoot, { title: 'Stack', checkout, request: 'do it', layers: [entry('a'), entry('b')] });
  const merge = core.ask(ownRoot, id, { question: 'Merge the stack? Which PR is the top?', options: ['#504', '#506'], sessionOnly: true }).id;
  const bare = core.ask(ownRoot, id, { question: 'Deploy to staging?', sessionOnly: true }).id;
  const config = path.join(ownRoot, 'config.json');
  const s = await startAdminServer({ root: ownRoot, port: 0 });
  const origin = `http://127.0.0.1:${s.address().port}`;
  const ok = { origin, 'x-task-manager-admin': 'answer' };
  const url = (q) => `/api/runs/${id}/questions/${q}/answer`;
  const open = () => readRun(ownRoot, id).openQuestions.map((q) => q.id);
  try {
    // Off by default: the page cannot answer, also with a correct confirmation.
    assert.equal((await post(s, url(merge), { answer: '#506', confirm: '#506' }, ok)).status, 409);
    writeFileSync(config, JSON.stringify({ answers: { confirmOnPage: 'yes' } }));
    assert.equal((await post(s, url(merge), { answer: '#506', confirm: '#506' }, ok)).status, 409);

    writeFileSync(config, JSON.stringify({ answers: { confirmOnPage: true } }));
    assert.equal(json(await request(s, '/api/settings')).confirmOnPage, true);
    // No confirmation, a wrong one, one that differs in case or space, and an answer for another option.
    assert.equal((await post(s, url(merge), { answer: '#506' }, ok)).status, 400);
    for (const body of [
      { answer: '#506', confirm: '506' },
      { answer: '#506', confirm: '#506 ' },
      { answer: '#506', confirm: 'yes' },
      { answer: '#504', confirm: '#506' },
      { answer: 'not yet', confirm: '#506' },
      { answer: '#5060', confirm: '#506' },
      // A comment could add a condition to the yes.
      { answer: '#506 — but not #505', confirm: '#506' },
      { answer: 'yes', confirm: 'YES' },
    ]) {
      const res = await post(s, url(body.confirm === 'YES' ? bare : merge), body, ok);
      assert.equal(res.status, 409, JSON.stringify(body));
      // Refused for the confirmation, not for another reason such as a setting that reads as off.
      assert.match(json(res).error, /needs a confirmation|must be the confirmed option/, JSON.stringify(body));
    }
    assert.deepEqual(open(), [merge, bare]);

    // The option typed exactly. A server that a session with no terminal started still acts for the user.
    process.env.TASK_MANAGER_NO_TERMINAL = '1';
    let res;
    try {
      res = await post(s, url(merge), { answer: '#506', confirm: '#506' }, ok);
    } finally {
      delete process.env.TASK_MANAGER_NO_TERMINAL;
    }
    assert.equal(res.status, 200, res.body);
    const saved = readRun(ownRoot, id).questions.find((q) => q.id === merge);
    assert.deepEqual([saved.answer, saved.via, saved.confirmed], ['#506', 'dashboard', true]);
    // A question with no options takes the word "yes".
    assert.equal((await post(s, url(bare), { answer: 'yes', confirm: 'yes' }, ok)).status, 200);
    assert.deepEqual(open(), []);
  } finally {
    s.close();
  }
});

// ── The outcomes issue and comment ───────────────────────────────────────────────────────────────

test('E1. the reader gives the outcome and the delivery of an issue layer and a comment layer, and counts them as done', async () => {
  const core = await import('../../skills/task-manager/scripts/lib/task-manager-core.mjs');
  const own = mkdtempSync(path.join(tmpdir(), 'task-manager-admin-outcomes-'));
  const ownRoot = path.join(own, 'runs');
  const entry = (task, outcome) => ({ task, source: 'request', tier: 'S', tierReason: 'r', outcome });
  const { id } = core.initRun(ownRoot, { title: 'Triage', checkout: own, request: 'r', kind: 'tasks', layers: [entry('triage', 'issue'), entry('review', 'comment')] });
  writeFileSync(path.join(ownRoot, id, 'reports', 'report-triage.md'), 'draft');
  core.setLayer(ownRoot, id, 'l1', [['phase', 'implementing']]);
  core.setLayer(ownRoot, id, 'l1', [['report', 'reports/report-triage.md'], ['delivery', '#101'], ['phase', 'delivered']]);
  const state = readRun(ownRoot, id);
  assert.deepEqual(state.layers.map((l) => [l.outcome, l.delivery, l.column]), [['issue', '#101', 'done'], ['comment', null, 'todo']]);
  assert.deepEqual(state.plans, ['report-triage.md']);
  assert.deepEqual(readBoard(ownRoot).runs[0].layers.map((l) => l.delivery), ['#101', null]);
});

// ── Archive ──────────────────────────────────────────────────────────────────────────────────────

test('H1. the page archives a finished project through the real helper and brings it back; the lists carry the mark', async () => {
  const core = await import('../../skills/task-manager/scripts/lib/task-manager-core.mjs');
  const own = mkdtempSync(path.join(tmpdir(), 'task-manager-admin-archive-'));
  const ownRoot = path.join(own, 'runs');
  const checkout = path.join(own, 'clone');
  mkdirSync(checkout);
  const { id } = core.initRun(ownRoot, { title: 'Old work', checkout, request: 'r', layers: [{ task: 'a', source: 's', tier: 'S', tierReason: 'r' }] });
  const s = await startAdminServer({ root: ownRoot, port: 0 });
  const origin = `http://127.0.0.1:${s.address().port}`;
  const ok = { origin, 'x-task-manager-admin': 'archive' };
  const url = `/api/runs/${id}/archive`;
  const marks = async () => [json(await request(s, '/api/runs')).runs[0].archived, json(await request(s, '/api/board')).runs[0].run.archived, json(await request(s, `/api/runs/${id}`)).run.archived ?? false];
  try {
    assert.deepEqual(await marks(), [false, false, false]);
    // A run that is not finished, a bad body, a wrong header and a GET are refused.
    assert.equal((await post(s, url, { archived: true }, ok)).status, 409);
    core.setRun(ownRoot, id, [['state', 'finished']]);
    assert.equal((await post(s, url, { archived: 'yes' }, ok)).status, 400);
    assert.equal((await post(s, url, {}, ok)).status, 400);
    assert.equal((await post(s, url, { archived: true }, { origin, 'x-task-manager-admin': 'finish' })).status, 403);
    assert.equal((await post(s, url, { archived: true }, { origin: 'http://evil.example', 'x-task-manager-admin': 'archive' })).status, 403);
    assert.equal((await request(s, url)).status, 405);
    assert.equal((await post(s, '/api/runs/2026-01-01-no-run/archive', { archived: true }, ok)).status, 404);
    assert.deepEqual(await marks(), [false, false, false]);

    const res = await post(s, url, { archived: true }, ok);
    assert.equal(res.status, 200, res.body);
    assert.deepEqual(json(res), { id, archived: true });
    assert.deepEqual(await marks(), [true, true, true]);
    assert.deepEqual(json(await post(s, url, { archived: false }, ok)), { id, archived: false });
    assert.deepEqual(await marks(), [false, false, false]);

    // An old project whose clone is gone can still be archived: that is what the archive is for.
    rmSync(checkout, { recursive: true });
    const gone = await post(s, url, { archived: true }, ok);
    assert.equal(gone.status, 200, gone.body);
    assert.deepEqual(await marks(), [true, true, true]);

    // A finished run with an open session-only question: the page cannot answer it and no session
    // runs, so the archive withdraws it. Nothing of the archived run waits for the user then.
    const tasks = core.initRun(ownRoot, { title: 'Tasks', checkout: own, request: 'r', kind: 'tasks', layers: [{ task: 'a', source: 's', tier: 'S', tierReason: 'r' }] }).id;
    const { id: q } = core.ask(ownRoot, tasks, { question: 'Merge?', sessionOnly: true });
    core.setRun(ownRoot, tasks, [['state', 'finished']]);
    const waiting = async () => json(await request(s, '/api/runs')).runs.find((r) => r.id === tasks).openQuestions;
    assert.equal(await waiting(), 1);
    const archived = await post(s, `/api/runs/${tasks}/archive`, { archived: true }, ok);
    assert.equal(archived.status, 200, archived.body);
    assert.equal(await waiting(), 0);
    const board = json(await request(s, '/api/board')).runs.find((e) => e.run.id === tasks);
    assert.deepEqual([board.openQuestions, board.questions], [[], []]);
    const detail = json(await request(s, `/api/runs/${tasks}`));
    assert.deepEqual([detail.openQuestions, detail.questions.find((x) => x.id === q).withdrawn], [[], true]);
    // A withdrawn question takes no answer from the page.
    const late = await post(s, `/api/runs/${tasks}/questions/${q}/answer`, { answer: 'yes' }, { origin, 'x-task-manager-admin': 'answer' });
    assert.notEqual(late.status, 200);
  } finally {
    s.close();
  }
});

// ── Corrections from the first real runs ────────────────────────────────────────────────────────

test('AD1. the lists and the board show the layers that add puts on a run, and a merge question that add withdrew waits no more', async () => {
  const core = await import('../../skills/task-manager/scripts/lib/task-manager-core.mjs');
  const own = mkdtempSync(path.join(tmpdir(), 'task-manager-admin-add-'));
  const ownRoot = path.join(own, 'runs');
  const layer = (task) => ({ task, source: 's', tier: 'S', tierReason: 'r' });
  const { id } = core.initRun(ownRoot, { title: 'Stack', checkout: own, request: 'r', layers: [layer('a'), layer('b')] });
  core.setRun(ownRoot, id, [['stage', 'finish'], ['state', 'paused']]);
  const { id: merge } = core.ask(ownRoot, id, { question: 'Merge the stack?', options: ['#2'], sessionOnly: true, merge: true });
  const s = await startAdminServer({ root: ownRoot, port: 0 });
  try {
    const listed = async () => json(await request(s, '/api/runs')).runs[0];
    assert.deepEqual([(await listed()).layers, (await listed()).openQuestions], [2, 1]);
    core.addLayers(ownRoot, id, [layer('c'), layer('d')]);
    assert.deepEqual([(await listed()).layers, (await listed()).openQuestions], [4, 0]);
    const board = json(await request(s, '/api/board')).runs[0];
    assert.deepEqual(board.layers.map((l) => [l.id, l.task, l.column]), [['l1', 'a', 'todo'], ['l2', 'b', 'todo'], ['l3', 'c', 'todo'], ['l4', 'd', 'todo']]);
    assert.deepEqual([board.run.stage, board.openQuestions], ['layers', []]);
    const detail = json(await request(s, `/api/runs/${id}`));
    assert.deepEqual(detail.questions.filter((q) => q.id === merge).map((q) => [q.withdrawn, q.by]), [[true, 'add']]);
  } finally {
    s.close();
  }
});

test('RR1. [real run] the page starts a session for an active run only with the user word in the body; a queued task with a question is not next', async () => {
  const core = await import('../../skills/task-manager/scripts/lib/task-manager-core.mjs');
  const own = mkdtempSync(path.join(tmpdir(), 'task-manager-admin-realrun-'));
  const ownRoot = path.join(own, 'runs');
  const checkout = path.join(own, 'clone');
  mkdirSync(checkout);
  const fake = path.join(own, 'fake-session.mjs');
  writeFileSync(fake, '#!/usr/bin/env node\nsetTimeout(() => {}, 4000);\n');
  chmodSync(fake, 0o755);
  const entry = (task) => ({ task, source: 'request', tier: 'S', tierReason: 'r', dependsOn: [] });
  const { id } = core.initRun(ownRoot, { title: 'Left active', checkout, request: 'r', kind: 'tasks', layers: [entry('a'), entry('b')] });
  core.ask(ownRoot, id, { layer: 'l1', question: 'A or B?' });
  writeFileSync(path.join(ownRoot, 'config.json'), JSON.stringify({ resume: { enabled: true, command: fake } }));
  const s = await startAdminServer({ root: ownRoot, port: 0 });
  const origin = `http://127.0.0.1:${s.address().port}`;
  const ok = { origin, 'x-task-manager-admin': 'session' };
  const url = `/api/runs/${id}/session`;
  let pid = null;
  try {
    // l1 waits for the user, so the page marks l2 as the next task, in the run view and on the board.
    assert.equal(json(await request(s, `/api/runs/${id}`)).next, 'l2');
    assert.equal(json(await request(s, '/api/board')).runs[0].next, 'l2');
    // The run is active, with a new event: no session without the user word.
    const refused = await post(s, url, {}, ok);
    assert.equal(refused.status, 409);
    assert.match(json(refused).error, /is active: a session works on it/);
    assert.equal((await post(s, url, { evenIfActive: 'yes' }, ok)).status, 409);
    const res = await post(s, url, { evenIfActive: true }, ok);
    assert.equal(res.status, 200, res.body);
    pid = json(res).pid;
    assert.equal(json(await request(s, `/api/runs/${id}`)).session.started.pid, pid);
  } finally {
    if (pid) {
      try {
        process.kill(pid);
      } catch {
        // It ended already.
      }
    }
    s.close();
  }
});
