/**
 * Run state of a task-manager run: read, validate, write.
 *
 * Every write to a run folder goes through this module (through `task-manager-ledger.mjs`), so that
 * no agent edits run JSON by hand. `run.json` is written atomically; the logs are JSON Lines and
 * only get new lines. The board column, the blocking layers and the next layer are derived here,
 * never stored, so the skill, `show` and a later admin UI all read one answer.
 *
 * Layout of a run folder (see "Run folder and the ledger" in core.md):
 *   run.json, events.jsonl, questions.jsonl, followups.jsonl, findings/<layer-id>.jsonl
 */
import {
  appendFileSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
  writeSync,
} from 'node:fs';
import { Buffer } from 'node:buffer';
import { homedir } from 'node:os';
import * as path from 'node:path';
import process from 'node:process';

export const SCHEMA = 1;

export const PHASES = [
  'queued',
  'implementing',
  'review',
  'fixing',
  'final_checks',
  'opening_pr',
  'pr_open',
  'merged',
  'delivered',
];
export const IN_PROGRESS = new Set(['implementing', 'review', 'fixing', 'final_checks', 'opening_pr']);
/** Phases of a layer whose branch can be the base of another layer, or whose work is finished. */
const ANCHOR = new Set(['pr_open', 'merged', 'delivered']);

/**
 * The outcome of a layer. A `pr` layer changes the repository and ends as a pull request. A
 * `report` layer (an investigation, a plan, a debug session, a code execution) changes nothing in
 * the repository: it ends as a reviewed report file in the run folder, at phase `delivered`. A
 * layer with no `outcome` key is a `pr` layer: runs made before the key existed stay valid.
 */
export const OUTCOMES = ['pr', 'report'];
/** Phases that only a `pr` layer has. */
const PR_PHASES = new Set(['final_checks', 'opening_pr', 'pr_open', 'merged']);

export function outcomeOf(layer) {
  return layer.outcome ?? 'pr';
}

/**
 * The kind of a run. A `stack` run puts each PR on the PR below it. A `tasks`
 * run holds independent tasks, each with its own outcome and no stack. A run.json with no `kind` key is
 * a stack run: runs made before the key existed stay valid at schema 1.
 */
export const KINDS = ['stack', 'tasks'];
export const RUN_STATES = ['active', 'paused', 'finished'];
export const STAGES = ['intake', 'layers', 'restack', 'ci', 'finish'];
export const CI_RESULTS = ['pending', 'pass', 'fail', 'no_e2e'];
export const TIERS = ['S', 'M', 'L'];
export const SEVERITIES = ['blocker', 'should_fix', 'nit'];
export const RULINGS = ['relay', 'closed', 'out_of_scope'];
export const FINDING_STATES = ['open', 'fixed', 'not_fixed', 'closed', 'known_limitation'];
export const EVENT_TYPES = [
  'run_created',
  'run_update',
  'decision',
  'layer_phase',
  'layer_update',
  'report',
  'review',
  'ruling',
  'escalation',
  'final_checks',
  'pr_opened',
  'pr_verified',
  'question',
  'answer',
  'park',
  'unpark',
  'followup',
  'restack',
  'ci_started',
  'ci_result',
  'merge',
  'resume',
  'main_plan',
  'state',
  'note',
];

const RUN_ID = /^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$/;
const LAYER_ID = /^l[1-9][0-9]*$/;
/** A layer's plan file, relative to its run folder. No `..`, no absolute path. */
export const PLAN_PATH = /^plans\/[a-z0-9-]+\.md$/;
/** The report file of a report layer, relative to its run folder. */
export const REPORT_PATH = /^reports\/report-[a-z0-9-]+\.md$/;
export class LedgerError extends Error {}

function fail(message) {
  throw new LedgerError(message);
}

export function now() {
  return new Date().toISOString();
}

/** The folder that holds every run folder: `$TASK_MANAGER_RUNS`, or `~/.task-manager/runs`. */
export function resolveRoot(env = process.env) {
  const given = env.TASK_MANAGER_RUNS;
  if (!given) return path.join(homedir(), '.task-manager', 'runs');
  // A settings file gives the value with no shell, so `~` is not expanded there.
  const value = given === '~' || given.startsWith('~/') ? path.join(homedir(), given.slice(1)) : given;
  // A relative root would land in the current directory: the checkout, where a commit can carry it.
  if (!path.isAbsolute(value)) fail(`TASK_MANAGER_RUNS must be an absolute path; got ${JSON.stringify(given)}`);
  return value;
}

export function assertRunId(id) {
  if (typeof id !== 'string' || !RUN_ID.test(id)) fail(`invalid run id: ${JSON.stringify(id)}`);
  return id;
}

export function assertLayerId(id) {
  if (typeof id !== 'string' || !LAYER_ID.test(id)) fail(`invalid layer id: ${JSON.stringify(id)}`);
  return id;
}

export function slugify(title) {
  const slug = String(title)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40)
    .replace(/-+$/g, '');
  if (!slug) fail('the title must contain at least one letter or digit');
  return slug;
}

function runDir(root, id) {
  return path.join(root, assertRunId(id));
}

// ── Files ────────────────────────────────────────────────────────────────────────────────────────

/** Write a file through a temp file and a rename, so a reader never sees half of it. */
function writeAtomic(file, text) {
  const tmp = `${file}.tmp-${process.pid}`;
  writeFileSync(tmp, text);
  renameSync(tmp, file);
}

/** Append one record. If the file ends in a torn line (no newline), start on a new line. */
function appendLine(file, record) {
  mkdirSync(path.dirname(file), { recursive: true });
  let prefix = '';
  if (existsSync(file)) {
    const size = statSync(file).size;
    if (size > 0) {
      const fd = openSync(file, 'r');
      const last = Buffer.alloc(1);
      readSync(fd, last, 0, 1, size - 1);
      closeSync(fd);
      if (last[0] !== 0x0a) prefix = '\n';
    }
  }
  appendFileSync(file, `${prefix}${JSON.stringify(record)}\n`);
}

// ── Lock ─────────────────────────────────────────────────────────────────────────────────────────

const LOCK_WAIT_MS = 10_000;
const LOCK_STALE_MS = 60_000;

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/** True when a process with this PID runs. EPERM means it runs under another user. */
function processRuns(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

/**
 * Run `fn` while this process holds the run's lock file. Two `L` commands on one run never
 * interleave their read and write, so no id is given twice and no field is lost. The lock holds
 * the PID of its process. A lock whose process no longer runs, or that is older than
 * LOCK_STALE_MS, is left from a crash and is removed.
 */
function withLock(dir, fn) {
  if (!existsSync(path.join(dir, 'run.json'))) fail(`no run ${path.basename(dir)}`);
  const lock = path.join(dir, '.lock');
  const start = Date.now();
  let fd;
  for (;;) {
    try {
      fd = openSync(lock, 'wx');
      writeSync(fd, String(process.pid));
      break;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      let owner;
      let age;
      try {
        owner = Number.parseInt(readFileSync(lock, 'utf8'), 10);
        age = Date.now() - statSync(lock).mtimeMs;
      } catch {
        continue;
      }
      const ownerGone = Number.isInteger(owner) && owner > 0 && !processRuns(owner);
      if (ownerGone || age > LOCK_STALE_MS) {
        rmSync(lock, { force: true });
        continue;
      }
      if (Date.now() - start > LOCK_WAIT_MS) {
        fail(
          `run ${path.basename(dir)} is locked by process ${Number.isInteger(owner) ? owner : '(unknown)'} ` +
            `for ${Math.round(age / 1000)} s; run L commands one at a time, or retry when that process ends`,
        );
      }
      sleep(25);
    }
  }
  try {
    return fn();
  } finally {
    closeSync(fd);
    rmSync(lock, { force: true });
  }
}

/** Wrap a command `(root, runId, ...args)` so that it runs under the run's lock. */
function locked(fn) {
  return (root, runId, ...args) => withLock(runDir(root, runId), () => fn(root, runId, ...args));
}

/** Read a JSON Lines file. A line that does not parse is skipped and reported in `errors`. */
export function readJsonl(file, errors = []) {
  if (!existsSync(file)) return [];
  const records = [];
  const lines = readFileSync(file, 'utf8').split('\n');
  lines.forEach((line, index) => {
    if (!line.trim()) return;
    try {
      records.push(JSON.parse(line));
    } catch {
      errors.push(`${path.basename(file)}:${index + 1}: line does not parse, skipped`);
    }
  });
  return records;
}

/** The latest record for each id, in the order each id first appeared. */
export function foldLatest(records) {
  const byId = new Map();
  for (const record of records) {
    const previous = byId.get(record.id);
    byId.set(record.id, previous ? { ...previous, ...record } : record);
  }
  return [...byId.values()];
}

function readRunJson(dir) {
  const file = path.join(dir, 'run.json');
  if (!existsSync(file)) {
    if (existsSync(path.join(dir, 'ledger.md'))) fail('old format: this run has ledger.md and no run.json');
    fail('no run.json in this folder');
  }
  let run;
  try {
    run = JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    fail('run.json does not parse');
  }
  if (run === null || typeof run !== 'object' || Array.isArray(run)) fail('run.json is not a JSON object');
  if (run.schema !== SCHEMA) fail(`unsupported schema version ${JSON.stringify(run.schema)}; this helper reads version ${SCHEMA}`);
  if (typeof run.id !== 'string' || typeof run.state !== 'string' || typeof run.checkout !== 'string') {
    fail('run.json has no id, state or checkout');
  }
  if (run.kind !== undefined && !KINDS.includes(run.kind)) fail(`run.json has an unknown kind ${JSON.stringify(run.kind)}`);
  const validLayer = (l) =>
    l !== null &&
    typeof l === 'object' &&
    typeof l.id === 'string' &&
    typeof l.phase === 'string' &&
    Number.isInteger(l.position) &&
    Array.isArray(l.dependsOn) &&
    l.dependsOn.every((d) => typeof d === 'string');
  if (!Array.isArray(run.layers) || !run.layers.every(validLayer)) {
    fail('run.json has no valid layers array');
  }
  return run;
}

// ── Derived state ────────────────────────────────────────────────────────────────────────────────

export function kindOf(run) {
  return run.kind ?? 'stack';
}

/** Refuse a command that only a stack run has. */
function stackOnly(run, what) {
  if (kindOf(run) === 'tasks') fail(`run ${run.id} is a tasks run: ${what} applies to a stack run only`);
}

export function openQuestions(questions) {
  return questions.filter((q) => q.answer === null || q.answer === undefined);
}

export function columnOf(layer, open) {
  if (layer.parked || open.some((q) => q.layer === layer.id)) return 'needs_input';
  if (layer.phase === 'queued') return 'todo';
  if (IN_PROGRESS.has(layer.phase)) return 'in_progress';
  return 'done';
}

/** The parked layers that `layerId` depends on, directly or through other layers. */
export function blockedBy(run, layerId) {
  const byId = new Map(run.layers.map((l) => [l.id, l]));
  const seen = new Set();
  const blocking = [];
  const stack = [...(byId.get(layerId)?.dependsOn ?? [])];
  while (stack.length) {
    const id = stack.pop();
    if (seen.has(id)) continue;
    seen.add(id);
    const dep = byId.get(id);
    if (!dep) continue;
    if (dep.parked) blocking.push(id);
    stack.push(...dep.dependsOn);
  }
  return blocking.sort(byLayerNumber);
}

function byLayerNumber(a, b) {
  return Number(a.slice(1)) - Number(b.slice(1));
}

function byPosition(layers) {
  return [...layers].sort((a, b) => a.position - b.position);
}

/** The layers that `layerId` depends on, directly or through other layers, with no PR open or merged yet. */
export function waitsFor(run, layerId) {
  const byId = new Map(run.layers.map((l) => [l.id, l]));
  const seen = new Set();
  const waiting = [];
  const stack = [...(byId.get(layerId)?.dependsOn ?? [])];
  while (stack.length) {
    const id = stack.pop();
    if (seen.has(id)) continue;
    seen.add(id);
    const dep = byId.get(id);
    if (!dep) continue;
    if (!ANCHOR.has(dep.phase)) waiting.push(id);
    stack.push(...dep.dependsOn);
  }
  return waiting.sort(byLayerNumber);
}

/** The lowest-position `queued` layer whose dependencies all have an open or merged PR, or null. */
export function nextLayer(run) {
  for (const layer of byPosition(run.layers)) {
    if (layer.phase === 'queued' && waitsFor(run, layer.id).length === 0) return layer.id;
  }
  return null;
}

/**
 * Move a layer directly above the highest layer whose PR is open or merged. Every other layer
 * (parked, or not started) stays above it. This is the place of a layer that starts, and of a
 * parked layer that resumes, so the stack stays linear.
 */
function placeAboveBase(run, layerId) {
  const ordered = byPosition(run.layers);
  const self = ordered.find((l) => l.id === layerId);
  const rest = ordered.filter((l) => l.id !== layerId);
  let anchor = -1;
  rest.forEach((l, index) => {
    if (ANCHOR.has(l.phase) && !l.parked) anchor = index;
  });
  rest.splice(anchor + 1, 0, self);
  rest.forEach((l, index) => {
    l.position = index + 1;
  });
}

export function readRun(root, id) {
  const dir = runDir(root, id);
  const errors = [];
  const run = readRunJson(dir);
  const events = readJsonl(path.join(dir, 'events.jsonl'), errors);
  const questions = foldLatest(readJsonl(path.join(dir, 'questions.jsonl'), errors));
  const followups = foldLatest(readJsonl(path.join(dir, 'followups.jsonl'), errors));
  const findings = {};
  for (const layer of run.layers) {
    findings[layer.id] = foldLatest(readJsonl(path.join(dir, 'findings', `${layer.id}.jsonl`), errors));
  }
  const open = openQuestions(questions);
  const layers = byPosition(run.layers).map((layer) => ({
    ...layer,
    // Runs made before the plan field existed have no key: read it as null.
    plan: layer.plan ?? null,
    // The CI of one task. Only a tasks run records it; a stack run has one CI record on the run.
    ci: layer.ci ?? null,
    column: columnOf(layer, open),
    blockedBy: blockedBy(run, layer.id),
    waitsFor: waitsFor(run, layer.id),
    openFindings: findings[layer.id].filter((f) => f.state === 'open' || f.state === 'not_fixed').length,
  }));
  return { run: { ...run, kind: kindOf(run), mainPlans: run.mainPlans ?? [] }, layers, events, questions, openQuestions: open, followups, findings, next: nextLayer(run), errors };
}

// ── Writes ───────────────────────────────────────────────────────────────────────────────────────

function saveRun(dir, run) {
  run.updated = now();
  writeAtomic(path.join(dir, 'run.json'), `${JSON.stringify(run, null, 2)}\n`);
}

function addEvent(dir, event) {
  if (!EVENT_TYPES.includes(event.type)) fail(`unknown event type: ${event.type}`);
  appendLine(path.join(dir, 'events.jsonl'), {
    ts: now(),
    layer: event.layer ?? null,
    type: event.type,
    round: event.round ?? null,
    summary: event.summary,
    refs: event.refs ?? {},
  });
}

function layerOf(run, layerId) {
  assertLayerId(layerId);
  const layer = run.layers.find((l) => l.id === layerId);
  if (!layer) fail(`no layer ${layerId} in run ${run.id}`);
  return layer;
}

/**
 * Read a run for a write. A finished run refuses writes, so that a late command cannot change a
 * closed record. `finishedOk` allows the few writes that can come after the end: reopening the run,
 * recording a merge, recording a filed follow-up issue, and answering a question that was still
 * open at the end.
 */
function load(root, runId, { finishedOk = false } = {}) {
  const dir = runDir(root, runId);
  const run = readRunJson(dir);
  if (run.state === 'finished' && !finishedOk) {
    fail(`run ${run.id} is finished; reopen it first with: run --run ${run.id} --set state=paused`);
  }
  return { dir, run };
}

function oneOf(name, value, allowed) {
  if (!allowed.includes(value)) fail(`${name} must be one of ${allowed.join(', ')}; got ${JSON.stringify(value)}`);
  return value;
}

function intIn(name, value, min, max) {
  const n = Number(value);
  if (!Number.isInteger(n) || n < min || n > max) fail(`${name} must be an integer from ${min} to ${max}; got ${JSON.stringify(value)}`);
  return n;
}

function text(name, value) {
  if (typeof value !== 'string' || !value.trim()) fail(`${name} is required`);
  return value;
}

/** An optional text option: absent is null; given, it cannot be empty. */
function optionalText(name, value) {
  if (value === undefined) return null;
  if (typeof value !== 'string' || !value.trim()) fail(`${name} cannot be empty`);
  return value;
}

function nullableText(value) {
  return value === 'null' || value === '' ? null : value;
}

function nextId(records, prefix) {
  const ids = new Set(records.map((r) => r.id));
  let n = 1;
  while (ids.has(`${prefix}${n}`)) n += 1;
  return `${prefix}${n}`;
}

export function listRuns(root, { checkout, states } = {}) {
  if (!existsSync(root)) return { runs: [], broken: [] };
  const runs = [];
  const broken = [];
  for (const name of readdirSync(root).sort()) {
    const dir = path.join(root, name);
    if (!statSync(dir).isDirectory() || !RUN_ID.test(name)) continue;
    if (!existsSync(path.join(dir, 'run.json')) && !existsSync(path.join(dir, 'ledger.md'))) continue;
    try {
      const { run, layers, openQuestions: open } = readRun(root, name);
      if (checkout && path.resolve(run.checkout) !== path.resolve(checkout)) continue;
      if (states && !states.includes(run.state)) continue;
      runs.push({
        id: run.id,
        title: run.title,
        kind: run.kind,
        state: run.state,
        checkout: run.checkout,
        layers: layers.length,
        done: layers.filter((l) => l.column === 'done').length,
        openQuestions: open.length,
        updated: run.updated,
      });
    } catch (error) {
      // One bad folder must never stop `list`, or `init` for every checkout.
      broken.push({ id: name, error: error instanceof LedgerError ? error.message : `unexpected error: ${error.message}` });
    }
  }
  return { runs, broken };
}

/**
 * Create a run. `layers` is an array of `{task, source, tier, tierReason, dependsOn}` in stack
 * order, where `dependsOn` holds 1-based indexes of earlier entries. A `tasks` run takes the same
 * array in work order, and its tasks are independent: no `dependsOn`.
 */
export function initRun(root, { title, checkout, request, layers, kind = 'stack', date = now().slice(0, 10) }) {
  oneOf('kind', kind, KINDS);
  text('title', title);
  text('checkout', checkout);
  if (!path.isAbsolute(checkout)) fail('checkout must be an absolute path');
  checkout = path.resolve(checkout);
  text('request', request);
  if (!Array.isArray(layers) || layers.length === 0) fail('the layers file must be a non-empty JSON array');
  const active = listRuns(root, { checkout, states: ['active'] }).runs;
  if (active.length) fail(`run ${active[0].id} is active for this checkout; set it to paused or finished first`);

  const built = layers.map((entry, index) => {
    const number = index + 1;
    const deps = entry.dependsOn ?? [];
    if (!Array.isArray(deps)) fail(`layer ${number}: dependsOn must be an array of indexes`);
    const outcome = entry.outcome === undefined ? 'pr' : oneOf(`layer ${number} outcome`, entry.outcome, OUTCOMES);
    for (const dep of deps) {
      if (!Number.isInteger(dep) || dep < 1 || dep >= number) {
        fail(`layer ${number}: dependsOn may name only earlier layers by 1-based index; got ${JSON.stringify(dep)}`);
      }
    }
    // In a tasks run, no PR is on another PR. A task can wait only for a report.
    if (kind === 'tasks' && deps.some((dep) => (layers[dep - 1].outcome ?? 'pr') !== 'report')) {
      fail(`task ${number}: in a tasks run, dependsOn may name only report tasks; use a stack run for a task that uses the code of another task`);
    }
    return {
      id: `l${number}`,
      position: number,
      outcome,
      report: null,
      task: text(`layer ${number} task`, entry.task),
      source: text(`layer ${number} source`, entry.source),
      dependsOn: deps.map((d) => `l${d}`),
      parked: null,
      tier: oneOf(`layer ${number} tier`, entry.tier, TIERS),
      tierReason: text(`layer ${number} tierReason`, entry.tierReason),
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
      plan: null,
    };
  });

  mkdirSync(root, { recursive: true });
  const base = `${date}-${slugify(title)}`;
  let id = base;
  for (let n = 2; ; n += 1) {
    try {
      mkdirSync(path.join(root, id));
      break;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      id = `${base}-${n}`;
    }
  }
  const dir = path.join(root, id);
  mkdirSync(path.join(dir, 'findings'), { recursive: true });
  mkdirSync(path.join(dir, 'plans'), { recursive: true });
  mkdirSync(path.join(dir, 'reports'), { recursive: true });
  const ts = now();
  const run = {
    schema: SCHEMA,
    id,
    kind,
    title,
    checkout,
    request,
    decisions: [],
    state: 'active',
    stage: 'intake',
    nextStep: null,
    stack: null,
    ci: null,
    created: ts,
    updated: ts,
    layers: built,
  };
  saveRun(dir, run);
  const unit = kind === 'tasks' ? 'task' : 'layer';
  addEvent(dir, { type: 'run_created', summary: `${built.length} ${unit}${built.length === 1 ? '' : 's'}: ${title}` });
  return { id };
}

const LAYER_SETTERS = {
  phase: (v) => oneOf('phase', v, PHASES),
  round: (v) => intIn('round', v, 0, 3),
  tier: (v) => oneOf('tier', v, TIERS),
  tierReason: (v) => text('tierReason', v),
  escalated: (v) => oneOf('escalated', v, ['true', 'false']) === 'true',
  task: (v) => text('task', v),
  source: (v) => text('source', v),
  branch: nullableText,
  base: nullableText,
  baseTip: nullableText,
  head: nullableText,
  lastReviewed: nullableText,
  implementer: nullableText,
  reviewer: nullableText,
  plan: (v) => {
    const value = nullableText(v);
    if (value !== null && !PLAN_PATH.test(value)) fail(`plan must match plans/<slug>.md with [a-z0-9-] only; got ${JSON.stringify(v)}`);
    return value;
  },
  report: (v) => {
    const value = nullableText(v);
    if (value !== null && !REPORT_PATH.test(value)) fail(`report must match reports/report-<slug>.md with [a-z0-9-] only; got ${JSON.stringify(v)}`);
    return value;
  },
};

/** Apply `key=value` pairs to a layer. `id`, `position` and `parked` are not settable. */
function setLayerUnlocked(root, runId, layerId, pairs, summary) {
  const mergeOnly = pairs.length === 1 && pairs[0][0] === 'phase' && pairs[0][1] === 'merged';
  const { dir, run } = load(root, runId, { finishedOk: mergeOnly });
  const layer = layerOf(run, layerId);
  // On a finished run, only a layer whose PR is open can be recorded as merged.
  if (run.state === 'finished' && (layer.phase !== 'pr_open' || !layer.pr)) {
    fail(`run ${run.id} is finished; reopen it first with: run --run ${run.id} --set state=paused`);
  }
  const before = layer.phase;
  const changes = [];
  for (const [key, raw] of pairs) {
    if (key === 'dependsOn') {
      const deps = raw === '' ? [] : raw.split(',').map((d) => assertLayerId(d.trim()));
      for (const dep of deps) {
        if (dep === layer.id) fail('a layer cannot depend on itself');
        if (kindOf(run) === 'tasks' && outcomeOf(layerOf(run, dep)) !== 'report') {
          fail(`run ${run.id} is a tasks run: dependsOn may name only report tasks`);
        }
        layerOf(run, dep);
      }
      layer.dependsOn = deps;
      if (blockedByCycle(run, layer.id)) fail('dependsOn would make a cycle');
    } else if (key === 'outcome') {
      if (layer.phase !== 'queued') fail('the outcome of a layer can change only while it is queued');
      const outcome = oneOf('outcome', raw, OUTCOMES);
      // In a tasks run, a task can wait only for a report. Keep that true for the tasks that wait for this one.
      const waiting = run.layers.filter((l) => l.dependsOn.includes(layer.id)).map((l) => l.id);
      if (outcome === 'pr' && kindOf(run) === 'tasks' && waiting.length) {
        fail(`${waiting.join(', ')} depend${waiting.length === 1 ? 's' : ''} on ${layer.id}: in a tasks run, a task can wait only for a report task`);
      }
      layer.outcome = outcome;
    } else if (key === 'pr') {
      if (outcomeOf(layer) === 'report') fail(`layer ${layer.id} is a report layer: it has no PR`);
      const number = nullableText(raw);
      layer.pr = number === null ? null : { number: intIn('pr', number, 1, Number.MAX_SAFE_INTEGER), url: layer.pr?.url ?? null };
    } else if (key === 'prUrl') {
      if (!layer.pr) fail('set pr before prUrl');
      layer.pr.url = text('prUrl', raw);
    } else if (key === 'ciRunUrl' || key === 'ciResult') {
      // Each task of a tasks run has its own PR on main, so each has its own CI run.
      if (kindOf(run) !== 'tasks') fail(`${key} on a layer applies to a tasks run only; a stack run records CI with: run --set ciPr=<N>`);
      if (key === 'ciRunUrl') {
        // A new CI run starts with no result.
        layer.ci = { runUrl: text('ciRunUrl', raw), result: 'pending' };
      } else {
        if (!layer.ci) fail('set ciRunUrl before ciResult');
        layer.ci.result = oneOf('ciResult', raw, CI_RESULTS);
      }
    } else if (Object.hasOwn(LAYER_SETTERS, key)) {
      layer[key] = LAYER_SETTERS[key](raw);
    } else {
      fail(`cannot set ${JSON.stringify(key)} on a layer`);
    }
    changes.push(`${key}=${raw}`);
  }
  if (outcomeOf(layer) === 'report') {
    if (PR_PHASES.has(layer.phase)) fail(`layer ${layer.id} is a report layer: it has no phase ${layer.phase}; it ends at delivered`);
    if (layer.phase === 'delivered' && !layer.report) fail('set report=reports/report-<slug>.md before phase=delivered');
    if (layer.phase === 'delivered' && !existsSync(path.join(dir, layer.report))) fail(`the report file ${layer.report} does not exist in the run folder`);
  } else {
    if (layer.phase === 'delivered') fail(`layer ${layer.id} is a pr layer: it ends at merged, not at delivered`);
    if (layer.report) fail(`layer ${layer.id} is a pr layer: it has no report`);
  }
  if (before === 'queued' && layer.phase !== 'queued') placeAboveBase(run, layer.id);
  saveRun(dir, run);
  const phaseChanged = before !== layer.phase;
  addEvent(dir, {
    type: phaseChanged ? 'layer_phase' : 'layer_update',
    layer: layer.id,
    round: layer.round,
    summary: summary || (phaseChanged ? `${before} -> ${layer.phase}` : changes.join(', ')),
  });
  return { layer: layer.id, phase: layer.phase, position: layer.position };
}

function blockedByCycle(run, start) {
  const byId = new Map(run.layers.map((l) => [l.id, l]));
  const seen = new Set();
  const stack = [...byId.get(start).dependsOn];
  while (stack.length) {
    const id = stack.pop();
    if (id === start) return true;
    if (seen.has(id)) continue;
    seen.add(id);
    stack.push(...(byId.get(id)?.dependsOn ?? []));
  }
  return false;
}

const RUN_SETTERS = {
  state: (v) => oneOf('state', v, RUN_STATES),
  stage: (v) => oneOf('stage', v, STAGES),
  // `null` clears it when nothing is left to do.
  nextStep: (v) => (v === 'null' ? null : text('nextStep', v)),
  // The number of the native GitHub stack that links the run's PRs (the Stacks REST API).
  // `null` clears it after an unstack.
  stack: (v) => (v === 'null' ? null : intIn('stack', v, 1, Number.MAX_SAFE_INTEGER)),
};

function setRunUnlocked(root, runId, pairs, summary) {
  const { dir, run } = load(root, runId, { finishedOk: true });
  const before = run.state;
  const changes = [];
  for (const [key, raw] of pairs) {
    if (key === 'ciPr' || key === 'ciRunUrl' || key === 'ciResult') {
      stackOnly(run, `${key} on the run (a tasks run records CI on each task: layer --set ciRunUrl=<url>)`);
    }
    if (key === 'stack') stackOnly(run, 'the GitHub stack');
    if (key === 'stage' && raw === 'restack') stackOnly(run, 'the restack stage');
    if (key === 'ciPr') {
      run.ci = { pr: intIn('ciPr', raw, 1, Number.MAX_SAFE_INTEGER), runUrl: null, result: 'pending' };
    } else if (key === 'ciRunUrl' || key === 'ciResult') {
      if (!run.ci) fail(`set ciPr before ${key}`);
      if (key === 'ciRunUrl') run.ci.runUrl = text('ciRunUrl', raw);
      else run.ci.result = oneOf('ciResult', raw, CI_RESULTS);
    } else if (Object.hasOwn(RUN_SETTERS, key)) {
      run[key] = RUN_SETTERS[key](raw);
      if (key === 'state' && run.state === 'active' && before !== 'active') {
        const other = listRuns(root, { checkout: run.checkout, states: ['active'] }).runs.find((r) => r.id !== run.id);
        if (other) fail(`run ${other.id} is active for this checkout; set it to paused or finished first`);
      }
    } else {
      fail(`cannot set ${JSON.stringify(key)} on a run`);
    }
    changes.push(`${key}=${raw}`);
  }
  if (before === 'finished' && run.state === 'finished') {
    fail(`run ${run.id} is finished; reopen it first with: run --run ${run.id} --set state=paused`);
  }
  saveRun(dir, run);
  addEvent(dir, {
    type: before !== run.state ? 'state' : 'run_update',
    summary: summary || changes.join(', '),
  });
  return { run: run.id, state: run.state, stage: run.stage };
}

function addDecisionUnlocked(root, runId, question, answer) {
  const { dir, run } = load(root, runId);
  run.decisions.push({ question: text('question', question), answer: text('answer', answer) });
  saveRun(dir, run);
  addEvent(dir, { type: 'decision', summary: `${question} -> ${answer}` });
  return { decisions: run.decisions.length };
}

function addEventCommandUnlocked(root, runId, { type, layer, summary, round, sha, pr, url }) {
  const { dir, run } = load(root, runId, { finishedOk: type === 'merge' });
  if (layer) layerOf(run, layer);
  addEvent(dir, {
    type: oneOf('type', type, EVENT_TYPES),
    layer: layer ?? null,
    round: round === undefined ? null : intIn('round', round, 0, 3),
    summary: text('summary', summary),
    refs: Object.fromEntries(Object.entries({ sha, pr, url }).filter(([, v]) => v !== undefined)),
  });
  saveRun(dir, run);
  return { ok: true };
}

function writeQuestion(dir, run, { layer, question, options, sessionOnly = false }) {
  if (layer) layerOf(run, layer);
  const questionsFile = path.join(dir, 'questions.jsonl');
  const id = nextId(foldLatest(readJsonl(questionsFile)), 'q');
  appendLine(questionsFile, {
    ts: now(),
    id,
    layer: layer ?? null,
    question: text('question', question),
    options: options ?? [],
    // A session-only question (for example the merge yes) takes no answer from the admin page.
    sessionOnly: Boolean(sessionOnly),
    answer: null,
  });
  return id;
}

function askUnlocked(root, runId, { layer, question, options, sessionOnly }) {
  const { dir, run } = load(root, runId);
  const id = writeQuestion(dir, run, { layer, question, options, sessionOnly });
  saveRun(dir, run);
  addEvent(dir, { type: 'question', layer: layer ?? null, summary: `${id}: ${question}` });
  return { id };
}

/** Where an answer came from: the user's message in the session, or the admin page. */
export const ANSWER_VIAS = ['session', 'dashboard'];

function answerUnlocked(root, runId, questionId, answerText, via = 'session') {
  oneOf('via', via, ANSWER_VIAS);
  const { dir, run } = load(root, runId, { finishedOk: true });
  const file = path.join(dir, 'questions.jsonl');
  const current = foldLatest(readJsonl(file)).find((q) => q.id === questionId);
  if (!current) fail(`no question ${questionId}`);
  if (current.answer !== null && current.answer !== undefined) fail(`question ${questionId} is already answered`);
  if (current.sessionOnly && via !== 'session') fail(`question ${questionId} takes an answer in the session only`);
  appendLine(file, { ts: now(), id: questionId, answer: text('answer', answerText), via });
  saveRun(dir, run);
  addEvent(dir, { type: 'answer', layer: current.layer, summary: `${questionId}: ${answerText}${via === 'dashboard' ? ' (from the admin page)' : ''}` });
  return { id: questionId };
}

/**
 * Park a layer on a question. Give `question` to ask a new one, or `questionId` to park on a
 * question that was already asked for this layer and has no answer yet.
 */
function parkUnlocked(root, runId, layerId, { question, questionId, options, tip, sessionOnly }) {
  const { dir, run } = load(root, runId);
  const layer = layerOf(run, layerId);
  if (layer.parked) fail(`layer ${layerId} is already parked`);
  if (layer.phase === 'queued') fail(`layer ${layerId} has not started; it waits, it is not parked`);
  if (ANCHOR.has(layer.phase)) fail(`layer ${layerId} has an open or merged PR, or a delivered report; such a layer is never parked`);
  if ((question === undefined) === (questionId === undefined)) fail('give --question or --id, not both');
  text('tip', tip);
  for (const option of options ?? []) text('option', option);
  if (question !== undefined) text('question', question);
  let id = questionId;
  if (id === undefined) {
    id = writeQuestion(dir, run, { layer: layerId, question, options, sessionOnly });
  } else {
    const existing = foldLatest(readJsonl(path.join(dir, 'questions.jsonl'))).find((q) => q.id === id);
    if (!existing) fail(`no question ${id}`);
    if (existing.layer !== layerId) fail(`question ${id} is not about layer ${layerId}`);
    if (existing.answer !== null && existing.answer !== undefined) fail(`question ${id} is already answered`);
    question = existing.question;
  }
  layer.parked = {
    question: id,
    phase: layer.phase,
    round: layer.round,
    baseTip: layer.baseTip,
    tip: text('tip', tip),
    lastReviewed: layer.lastReviewed,
  };
  saveRun(dir, run);
  addEvent(dir, { type: 'park', layer: layerId, round: layer.round, summary: `${id}: ${question}` });
  return { id };
}

function unparkUnlocked(root, runId, layerId, { base, baseTip, head, lastReviewed }) {
  const { dir, run } = load(root, runId);
  const layer = layerOf(run, layerId);
  if (!layer.parked) fail(`layer ${layerId} is not parked`);
  const q = foldLatest(readJsonl(path.join(dir, 'questions.jsonl'))).find((x) => x.id === layer.parked.question);
  if (!q || q.answer === null || q.answer === undefined) fail(`question ${layer.parked.question} has no answer yet`);
  text('base', base);
  text('baseTip', baseTip);
  text('head', head);
  if (layer.parked.lastReviewed && lastReviewed === undefined) {
    fail('give --last-reviewed: the rebased counterpart of the last reviewed SHA, from the range-diff');
  }
  layer.parked = null;
  layer.base = base;
  layer.baseTip = baseTip;
  layer.head = head;
  if (lastReviewed !== undefined) layer.lastReviewed = text('lastReviewed', lastReviewed);
  placeAboveBase(run, layer.id);
  saveRun(dir, run);
  addEvent(dir, { type: 'unpark', layer: layerId, round: layer.round, summary: `base ${base} at ${baseTip}` });
  return { layer: layerId, position: layer.position };
}

/**
 * Copy a plan document that the user gave as a source into the run's plans folder, as
 * `plans/main-<slug>.md`. The copy is a snapshot at that time: the run keeps it also when the
 * source is untracked, edited or deleted later. The same source with the same text is copied one
 * time only; a different text under the same name gets `-2`, `-3`.
 */
function addMainPlanUnlocked(root, runId, file) {
  const { dir, run } = load(root, runId);
  text('file', file);
  const source = path.resolve(file);
  if (!/\.md$/i.test(source)) fail(`the plan document must be a .md file; got ${JSON.stringify(file)}`);
  let body;
  try {
    if (!statSync(source).isFile()) fail(`not a file: ${source}`);
    body = readFileSync(source, 'utf8');
  } catch (error) {
    if (error instanceof LedgerError) throw error;
    fail(`cannot read the plan document ${source}`);
  }
  const slug = slugifyFile(path.basename(source).replace(/\.md$/i, ''));
  mkdirSync(path.join(dir, 'plans'), { recursive: true });
  mkdirSync(path.join(dir, 'reports'), { recursive: true });
  let name = `plans/main-${slug}.md`;
  for (let n = 2; existsSync(path.join(dir, name)); n += 1) {
    if (readFileSync(path.join(dir, name), 'utf8') === body) return { path: name, copied: false };
    name = `plans/main-${slug}-${n}.md`;
  }
  writeAtomic(path.join(dir, name), body);
  run.mainPlans = [...(run.mainPlans ?? []), { path: name, source, copied: now() }];
  saveRun(dir, run);
  addEvent(dir, { type: 'main_plan', summary: `${name} from ${source}` });
  return { path: name, copied: true };
}

/** A file name as `[a-z0-9-]`, with no cut: a plan's name is often long. */
function slugifyFile(name) {
  const slug = String(name).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  if (!slug) fail('the plan document name must contain at least one letter or digit');
  return slug;
}

function addFindingUnlocked(root, runId, layerId, fields) {
  const { dir, run } = load(root, runId);
  layerOf(run, layerId);
  const file = path.join(dir, 'findings', `${layerId}.jsonl`);
  const id = nextId(foldLatest(readJsonl(file)), `${layerId}-f`);
  const record = {
    ts: now(),
    id,
    round: intIn('round', fields.round, 1, 3),
    severity: oneOf('severity', fields.severity, SEVERITIES),
    file: text('file', fields.file),
    line: fields.line === undefined ? null : intIn('line', fields.line, 1, Number.MAX_SAFE_INTEGER),
    defect: text('defect', fields.defect),
    // A reviewer does not always give a fix, for example for an out-of-scope defect.
    expectedFix: optionalText('expected-fix', fields.expectedFix),
    ruling: null,
    reason: null,
    state: 'open',
    fixSha: null,
  };
  appendLine(file, record);
  saveRun(dir, run);
  addEvent(dir, { type: 'review', layer: layerId, round: record.round, summary: `${id} ${record.severity}: ${record.defect}` });
  return { id };
}

function findingOf(dir, layerId, findingId) {
  const file = path.join(dir, 'findings', `${layerId}.jsonl`);
  const current = foldLatest(readJsonl(file)).find((f) => f.id === findingId);
  if (!current) fail(`no finding ${findingId} on layer ${layerId}`);
  return { file, current };
}

function ruleUnlocked(root, runId, layerId, findingId, { ruling, reason }) {
  const { dir, run } = load(root, runId);
  layerOf(run, layerId);
  const { file } = findingOf(dir, layerId, findingId);
  oneOf('ruling', ruling, RULINGS);
  if (ruling !== 'relay') text('reason', reason);
  const state = ruling === 'relay' ? 'open' : 'closed';
  appendLine(file, { ts: now(), id: findingId, ruling, reason: reason ?? null, state });
  saveRun(dir, run);
  addEvent(dir, { type: 'ruling', layer: layerId, summary: `${findingId}: ${ruling}${reason ? ` (${reason})` : ''}` });
  return { id: findingId, state };
}

function resolveUnlocked(root, runId, layerId, findingId, { state, sha }) {
  const { dir, run } = load(root, runId);
  layerOf(run, layerId);
  const { file } = findingOf(dir, layerId, findingId);
  oneOf('state', state, FINDING_STATES);
  appendLine(file, { ts: now(), id: findingId, state, fixSha: sha ?? null });
  saveRun(dir, run);
  addEvent(dir, { type: 'review', layer: layerId, summary: `${findingId}: ${state}`, refs: sha ? { sha } : {} });
  return { id: findingId, state };
}

function addFollowupUnlocked(root, runId, { layer, title, body, dataLoss }) {
  const { dir, run } = load(root, runId);
  if (layer) layerOf(run, layer);
  const file = path.join(dir, 'followups.jsonl');
  const id = nextId(foldLatest(readJsonl(file)), 'fu');
  appendLine(file, {
    ts: now(),
    id,
    layer: layer ?? null,
    title: text('title', title),
    body: text('body', body),
    dataLoss: Boolean(dataLoss),
    issue: null,
  });
  saveRun(dir, run);
  addEvent(dir, { type: 'followup', layer: layer ?? null, summary: `${id}${dataLoss ? ' DATA LOSS' : ''}: ${title}` });
  return { id };
}

function followupFiledUnlocked(root, runId, followupId, issue) {
  const { dir, run } = load(root, runId, { finishedOk: true });
  const file = path.join(dir, 'followups.jsonl');
  if (!foldLatest(readJsonl(file)).some((f) => f.id === followupId)) fail(`no follow-up ${followupId}`);
  const number = intIn('issue', issue, 1, Number.MAX_SAFE_INTEGER);
  appendLine(file, { ts: now(), id: followupId, issue: number });
  saveRun(dir, run);
  addEvent(dir, { type: 'followup', summary: `${followupId} filed as #${number}`, refs: { pr: number } });
  return { id: followupId, issue: number };
}

export const setLayer = locked(setLayerUnlocked);
export const setRun = locked(setRunUnlocked);
export const addDecision = locked(addDecisionUnlocked);
export const addEventCommand = locked(addEventCommandUnlocked);
export const ask = locked(askUnlocked);
export const answer = locked(answerUnlocked);
export const park = locked(parkUnlocked);
export const unpark = locked(unparkUnlocked);
export const addMainPlan = locked(addMainPlanUnlocked);
export const addFinding = locked(addFindingUnlocked);
export const rule = locked(ruleUnlocked);
export const resolve = locked(resolveUnlocked);
export const addFollowup = locked(addFollowupUnlocked);
export const followupFiled = locked(followupFiledUnlocked);

/** A short text summary for the orchestrator. Cheaper to read than the files. */
export function show(root, runId) {
  const state = readRun(root, runId);
  const { run, layers } = state;
  const answered = new Map(state.questions.filter((q) => q.answer !== null && q.answer !== undefined).map((q) => [q.id, q]));
  const lines = [];
  const tasks = run.kind === 'tasks';
  lines.push(`run ${run.id} [${run.kind}, ${run.state}, stage ${run.stage}] ${run.title}`);
  lines.push(`checkout ${run.checkout}`);
  lines.push(`request: ${run.request}`);
  for (const d of run.decisions) lines.push(`decision: ${d.question} -> ${d.answer}`);
  if (run.stack) lines.push(`github stack: #${run.stack}`);
  for (const p of run.mainPlans) lines.push(`main plan: ${p.path} (from ${p.source})`);
  if (run.ci) lines.push(`ci: PR #${run.ci.pr} ${run.ci.result}${run.ci.runUrl ? ` ${run.ci.runUrl}` : ''}`);
  lines.push(tasks ? 'tasks (work order):' : 'layers (bottom to top):');
  for (const l of layers) {
    const parts = [`  ${l.position}. ${l.id} [${l.column}] ${l.phase} r${l.round}/3 tier ${l.tier}${l.escalated ? ' (escalated)' : ''}`];
    if (outcomeOf(l) === 'report') parts.push(`report ${l.report ?? '-'}`);
    if (l.pr) parts.push(`PR #${l.pr.number}`);
    if (l.ci) parts.push(`ci ${l.ci.result} ${l.ci.runUrl}`);
    if (l.openFindings) parts.push(`${l.openFindings} open finding${l.openFindings === 1 ? '' : 's'}`);
    if (l.blockedBy.length) parts.push(`blocked by parked ${l.blockedBy.join(', ')}`);
    if (l.phase === 'queued' && l.waitsFor.length) parts.push(`waits for ${l.waitsFor.join(', ')}`);
    lines.push(`${parts.join(', ')} - ${l.task}`);
    if (l.phase !== 'queued' && l.phase !== 'merged' && l.phase !== 'delivered') {
      lines.push(
        `     source ${l.source}; branch ${l.branch ?? '-'}; base ${l.base ?? '-'}@${l.baseTip ?? '-'}; head ${l.head ?? '-'}; ` +
          `last reviewed ${l.lastReviewed ?? '-'}; implementer ${l.implementer ?? '-'}; reviewer ${l.reviewer ?? '-'}; plan ${l.plan ?? '-'}`,
      );
    }
    if (l.parked) {
      const a = answered.get(l.parked.question);
      lines.push(
        `     PARKED on ${l.parked.question} at ${l.parked.phase} r${l.parked.round}` +
          ` (base tip ${l.parked.baseTip ?? '-'}, tip ${l.parked.tip}, last reviewed ${l.parked.lastReviewed ?? '-'})` +
          (a ? `; answer: ${a.answer} - ready to unpark` : '; no answer yet'),
      );
    }
  }
  lines.push(`next ${tasks ? 'task' : 'layer'} that can move: ${state.next ?? 'none'}`);
  if (state.openQuestions.length) {
    lines.push('open questions:');
    for (const q of state.openQuestions) {
      lines.push(`  ${q.id}${q.layer ? ` (${q.layer})` : ' (run)'}${q.sessionOnly ? ' [session only]' : ''}: ${q.question}${q.options.length ? ` [${q.options.join(' | ')}]` : ''}`);
    }
  }
  const recentAnswers = [...answered.values()].slice(-5);
  if (recentAnswers.length) {
    lines.push('answered questions (last 5):');
    for (const q of recentAnswers) lines.push(`  ${q.id}${q.layer ? ` (${q.layer})` : ' (run)'}: ${q.question} -> ${q.answer}`);
  }
  const openFollowups = state.followups.filter((f) => f.issue === null || f.issue === undefined);
  if (openFollowups.length) {
    lines.push('follow-ups not filed (data loss first):');
    const ordered = [...openFollowups.filter((f) => f.dataLoss), ...openFollowups.filter((f) => !f.dataLoss)];
    for (const f of ordered) lines.push(`  ${f.id}${f.dataLoss ? ' DATA LOSS' : ''}${f.layer ? ` (${f.layer})` : ''}: ${f.title}`);
  }
  const filedFollowups = state.followups.filter((f) => f.issue !== null && f.issue !== undefined);
  if (filedFollowups.length) {
    lines.push(`follow-ups filed: ${filedFollowups.map((f) => `${f.id} #${f.issue}`).join(', ')}`);
  }
  lines.push('last events:');
  for (const e of state.events.slice(-5)) {
    lines.push(`  ${e.ts} ${e.type}${e.layer ? ` ${e.layer}` : ''}: ${e.summary}`);
  }
  lines.push(`next step: ${run.nextStep ?? '(not recorded)'}`);
  for (const error of state.errors) lines.push(`warning: ${error}`);
  return lines.join('\n');
}

/** The history of one layer: its fields, its findings with rulings and states, its review events, its questions. */
export function showLayer(root, runId, layerId) {
  const state = readRun(root, runId);
  assertLayerId(layerId);
  const l = state.layers.find((x) => x.id === layerId);
  if (!l) fail(`no layer ${layerId} in run ${runId}`);
  const lines = [];
  lines.push(`layer ${l.id} (position ${l.position}) [${l.column}] ${l.phase} r${l.round}/3 tier ${l.tier}${l.escalated ? ' (escalated)' : ''} - ${l.task}`);
  lines.push(`source ${l.source}; depends on ${l.dependsOn.join(', ') || '-'}`);
  lines.push(`branch ${l.branch ?? '-'}; base ${l.base ?? '-'}@${l.baseTip ?? '-'}; head ${l.head ?? '-'}; last reviewed ${l.lastReviewed ?? '-'}`);
  lines.push(`implementer ${l.implementer ?? '-'}; reviewer ${l.reviewer ?? '-'}${l.pr ? `; PR #${l.pr.number} ${l.pr.url ?? ''}` : ''}; plan ${l.plan ?? '-'}`);
  if (l.ci) lines.push(`ci ${l.ci.result} ${l.ci.runUrl}`);
  if (l.parked) lines.push(`PARKED on ${l.parked.question} at ${l.parked.phase} r${l.parked.round} (base tip ${l.parked.baseTip ?? '-'}, tip ${l.parked.tip}, last reviewed ${l.parked.lastReviewed ?? '-'})`);
  lines.push('findings:');
  for (const f of state.findings[l.id]) {
    lines.push(
      `  ${f.id} r${f.round} ${f.severity} [${f.state}] ${f.file}${f.line ? `:${f.line}` : ''}: ${f.defect}` +
        (f.expectedFix ? ` | expected: ${f.expectedFix}` : '') +
        (f.ruling ? ` | ruling: ${f.ruling}${f.reason ? ` (${f.reason})` : ''}` : '') +
        (f.fixSha ? ` | fix ${f.fixSha}` : ''),
    );
  }
  if (!state.findings[l.id].length) lines.push('  (none)');
  lines.push('review events:');
  const history = state.events.filter((e) => e.layer === l.id && ['review', 'ruling', 'escalation', 'park', 'unpark', 'final_checks', 'note'].includes(e.type));
  for (const e of history) lines.push(`  ${e.ts} ${e.type}${e.round !== null ? ` r${e.round}` : ''}: ${e.summary}`);
  const questions = state.questions.filter((q) => q.layer === l.id);
  if (questions.length) {
    lines.push('questions:');
    for (const q of questions) lines.push(`  ${q.id}: ${q.question} -> ${q.answer ?? '(no answer yet)'}`);
  }
  for (const error of state.errors) lines.push(`warning: ${error}`);
  return lines.join('\n');
}

// ── Wait for an answer ───────────────────────────────────────────────────────────────────────────

const isAnswered = (q) => q.answer !== null && q.answer !== undefined;

/**
 * Resolve when a question of the run gets an answer, from the session or from the admin page. The
 * orchestrator runs this in the background: the harness starts the session again when the command
 * ends. It gives:
 *   - an answer to a question that was open at some time during this wait, also a question that
 *     was asked after the wait started;
 *   - an answer from the admin page that no earlier wait gave to the session. This covers an
 *     answer that came between `ask` and the start of this wait, or while no wait ran.
 * It marks each admin-page answer that it gives as `delivered`, so the next wait does not give it
 * again. That mark is its only write. It reads the marks again under the run lock before it
 * writes, so two waits on one run never give the same admin-page answer. It also ends when the run
 * is finished, when no question is open, or after `timeoutMs`.
 */
export async function waitForAnswer(root, runId, { timeoutMs = 0, pollMs = 2000 } = {}) {
  const dir = runDir(root, runId);
  const file = path.join(dir, 'questions.jsonl');
  readRunJson(dir);
  const watched = new Set();
  const started = Date.now();
  const fromPage = (q) => q.via === 'dashboard';
  for (;;) {
    const questions = foldLatest(readJsonl(file));
    // A session answer is news only for a wait that saw the question open. An admin-page answer
    // is news until one wait takes it.
    const give = questions.filter((q) => isAnswered(q) && !fromPage(q) && watched.has(q.id));
    const candidates = questions.filter((q) => isAnswered(q) && fromPage(q) && !q.delivered);
    if (candidates.length) {
      // A busy lock or a write error must not end the watcher, and must not drop an answer that
      // already has its mark: `give` keeps it, and the next poll tries the other answers again.
      try {
        withLock(dir, () => {
          const taken = new Set(foldLatest(readJsonl(file)).filter((q) => q.delivered).map((q) => q.id));
          for (const q of candidates) {
            if (taken.has(q.id)) continue;
            appendLine(file, { ts: now(), id: q.id, delivered: true });
            give.push(q);
          }
        });
      } catch (error) {
        if (!(error instanceof LedgerError) && give.length === 0) throw error;
      }
    }
    if (give.length) {
      return { answered: give.map((q) => ({ id: q.id, layer: q.layer ?? null, answer: q.answer, via: q.via ?? 'session' })), reason: 'answered' };
    }
    const open = questions.filter((q) => !isAnswered(q));
    for (const q of open) watched.add(q.id);
    if (open.length === 0) return { answered: [], reason: 'no_open_question' };
    if (readRunJson(dir).state === 'finished') return { answered: [], reason: 'run_finished' };
    if (timeoutMs > 0 && Date.now() - started >= timeoutMs) return { answered: [], reason: 'timeout' };
    await new Promise((done) => setTimeout(done, pollMs));
  }
}
