/**
 * Read-only access to the task-manager run folders, for the admin UI.
 *
 * The `task-manager` skill writes the run folders through its helper
 * (`skills/task-manager/scripts/task-manager-ledger.mjs` in this plugin). This module only
 * reads them. Its rules for the column, the blocking layers and the next layer follow the skill's
 * core module (`scripts/lib/task-manager-core.mjs`), schema version 1. If the skill changes those
 * rules or the schema, change this file too. A run with another schema version shows as broken.
 */
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import * as path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';

export const SCHEMA = 1;
export const RUN_ID = /^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$/;
/**
 * An implementer plan (`plan-*.md`), a copy of a plan document that the user gave (`main-*.md`), or
 * the report of a report task (`report-*.md`, in the `reports` folder of the run).
 */
export const PLAN_FILE = /^(plan|main|report)-[a-z0-9-]+\.md$/;
/** The folder of a plan or report file, inside the run folder. */
export const folderOf = (name) => (name.startsWith('report-') ? 'reports' : 'plans');
/** The run kinds of the skill's core module. A run.json with no `kind` is a stack run. */
export const KINDS = ['stack', 'tasks'];
/** An active run with no event for this long, and no open question, is stale. */
export const STALE_MS = 60 * 60 * 1000;

const IN_PROGRESS = new Set(['implementing', 'review', 'fixing', 'final_checks', 'opening_pr']);
/** Phases of a layer whose branch can be the base of another layer, or whose work is finished. */
const ANCHOR = new Set(['pr_open', 'merged', 'delivered']);
/** Phases in which a layer's work is over: no time adds up in them. */
export const FINAL = new Set(['merged', 'delivered']);
/** The default summary of a `layer_phase` event, written by the helper: `<from> -> <to>`. */
const PHASE_SUMMARY = /^([a-z_]+) -> ([a-z_]+)$/;

export class BrokenRun extends Error {}

function broken(message) {
  throw new BrokenRun(message);
}

/** Read a JSON Lines file. A line that does not parse is skipped and reported in `errors`. */
export function readJsonl(file, errors = []) {
  if (!existsSync(file)) return [];
  const records = [];
  readFileSync(file, 'utf8')
    .split('\n')
    .forEach((line, index) => {
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
    if (existsSync(path.join(dir, 'ledger.md'))) broken('old format: this run has ledger.md and no run.json');
    broken('no run.json in this folder');
  }
  let run;
  try {
    run = JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    broken('run.json does not parse');
  }
  if (run === null || typeof run !== 'object' || Array.isArray(run)) broken('run.json is not a JSON object');
  if (run.schema !== SCHEMA) broken(`unsupported schema version ${JSON.stringify(run.schema)}; the admin UI reads version ${SCHEMA}`);
  if (typeof run.id !== 'string' || typeof run.state !== 'string' || typeof run.checkout !== 'string') {
    broken('run.json has no id, state or checkout');
  }
  if (run.kind !== undefined && !KINDS.includes(run.kind)) broken(`run.json has an unknown kind ${JSON.stringify(run.kind)}`);
  const validLayer = (l) =>
    l !== null &&
    typeof l === 'object' &&
    typeof l.id === 'string' &&
    typeof l.phase === 'string' &&
    Number.isInteger(l.position) &&
    Array.isArray(l.dependsOn) &&
    l.dependsOn.every((d) => typeof d === 'string');
  if (!Array.isArray(run.layers) || !run.layers.every(validLayer)) broken('run.json has no valid layers array');
  return run;
}

// ── Derived values (the same rules as the skill's core module) ──────────────────────────────────

export const kindOf = (run) => run.kind ?? 'stack';

export function openQuestions(questions) {
  return questions.filter((q) => q.answer === null || q.answer === undefined);
}

export function columnOf(layer, open) {
  if (layer.parked || open.some((q) => q.layer === layer.id)) return 'needs_input';
  if (layer.phase === 'queued') return 'todo';
  if (IN_PROGRESS.has(layer.phase)) return 'in_progress';
  return 'done';
}

const byLayerNumber = (a, b) => Number(a.slice(1)) - Number(b.slice(1));
const byPosition = (layers) => [...layers].sort((a, b) => a.position - b.position);

/** The dependencies of a layer, direct or through other layers, that match `keep`. */
function dependencies(run, layerId, keep) {
  const byId = new Map(run.layers.map((l) => [l.id, l]));
  const seen = new Set();
  const found = [];
  const stack = [...(byId.get(layerId)?.dependsOn ?? [])];
  while (stack.length) {
    const id = stack.pop();
    if (seen.has(id)) continue;
    seen.add(id);
    const dep = byId.get(id);
    if (!dep) continue;
    if (keep(dep)) found.push(id);
    stack.push(...dep.dependsOn);
  }
  return found.sort(byLayerNumber);
}

/** The parked layers that a layer depends on. */
export const blockedBy = (run, layerId) => dependencies(run, layerId, (dep) => Boolean(dep.parked));

/** The layers that a layer depends on with no PR open or merged yet. */
export const waitsFor = (run, layerId) => dependencies(run, layerId, (dep) => !ANCHOR.has(dep.phase));

/**
 * The lowest-position `queued` layer that can start, or null: its dependencies all have their
 * outcome, and no question of its own is open (a layer cannot park before it starts, so the
 * question is its only mark). The rule of `nextLayer` in the helper's core module.
 */
export function nextLayer(run, open = []) {
  for (const layer of byPosition(run.layers)) {
    if (layer.phase === 'queued' && waitsFor(run, layer.id).length === 0 && !open.some((q) => q.layer === layer.id)) return layer.id;
  }
  return null;
}

/**
 * The milliseconds that each layer spent in each phase: `{l1: {implementing: 120000}}`. It reads
 * the `layer_phase` events whose summary has the helper's default form `<from> -> <to>`, and skips
 * the others. The current phase counts up to `until` (ISO time), except `merged`. A parked layer
 * keeps its phase, so the parked time counts in that phase.
 */
export function phaseTimes(events, until) {
  const end = Date.parse(until);
  const current = new Map();
  const times = {};
  const add = (layer, phase, ms) => {
    times[layer] ??= {};
    times[layer][phase] = (times[layer][phase] ?? 0) + Math.max(0, ms);
  };
  for (const e of events) {
    if (e?.type !== 'layer_phase' || !e.layer) continue;
    const match = PHASE_SUMMARY.exec(e.summary ?? '');
    const ts = Date.parse(e.ts);
    if (!match || Number.isNaN(ts)) continue;
    const open = current.get(e.layer);
    if (open) add(e.layer, open.phase, ts - open.since);
    current.set(e.layer, { phase: match[2], since: ts });
  }
  for (const [layer, open] of current) {
    if (!FINAL.has(open.phase) && !Number.isNaN(end)) add(layer, open.phase, end - open.since);
  }
  return times;
}

/** The time of the last event, or the run's `created` time when it has no event. */
export function lastEventTime(run, events) {
  for (let i = events.length - 1; i >= 0; i -= 1) {
    if (typeof events[i]?.ts === 'string') return events[i].ts;
  }
  return run.created ?? null;
}

/** True when an `active` run has no open question and no event for more than STALE_MS. */
export function isStale(run, events, open, at = Date.now()) {
  if (run.state !== 'active' || open.length > 0) return false;
  const last = Date.parse(lastEventTime(run, events));
  return !Number.isNaN(last) && at - last > STALE_MS;
}

/** The time of the last event of each layer: `{l1: '<ts>'}`. */
export function layerEventTimes(events) {
  const times = {};
  for (const e of events) {
    if (e?.layer && typeof e.ts === 'string') times[e.layer] = e.ts;
  }
  return times;
}

/** The plan file names of a run: the main plans (`main-*.md`) first, then the implementer plans (`plan-*.md`), each sorted. */
export function listPlans(dir) {
  const namesIn = (folder, prefix) => {
    const full = path.join(dir, folder);
    if (!existsSync(full)) return [];
    return readdirSync(full).filter((name) => PLAN_FILE.test(name) && name.startsWith(prefix)).sort();
  };
  // The reports come last: they are the outcome of report tasks, not a plan.
  return [...namesIn('plans', 'main-'), ...namesIn('plans', 'plan-'), ...namesIn('reports', 'report-')];
}

/**
 * True when the process that wrote a marker still runs: the same PID with the same start time.
 * This is the rule of `processAlive` in the helper's core module. A process that ended and that
 * nobody collected (a zombie) does not run. With no usable `ps`, the PID alone decides.
 */
export function processAlive(pid, lstart) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
  } catch (error) {
    if (error.code !== 'EPERM') return false;
  }
  const out = spawnSync('ps', ['-o', 'stat=,lstart=', '-p', String(pid)], { encoding: 'utf8' });
  if (out.error) return true;
  const line = (out.stdout ?? '').trim();
  if (out.status !== 0 || line === '') return false;
  const [stat, ...rest] = line.split(/\s+/);
  if (stat.startsWith('Z')) return false;
  return typeof lstart !== 'string' || rest.join(' ') === lstart;
}

function jsonOrNull(file) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

/**
 * Who works on a run now, from the two marker files of the helper (`sessionsOf` in its core
 * module): `watching` is true while a `wait` command of a session runs, and `started` is the
 * session that the page started, while its process runs.
 */
export function sessionOf(dir, alive = processAlive) {
  let watching = false;
  try {
    const folder = path.join(dir, 'watchers');
    watching = readdirSync(folder).some((name) => alive(Number(name), jsonOrNull(path.join(folder, name))?.lstart));
  } catch {
    // No watcher folder: no watcher.
  }
  const saved = jsonOrNull(path.join(dir, 'session.json'));
  const started = saved && alive(saved.pid, saved.lstart) ? { pid: saved.pid, started: saved.started ?? null } : null;
  return { watching, started };
}

const USAGE_KEYS = ['tokens', 'toolUses', 'durationMs', 'cost'];

/** The sum of usage records. `cost` stays null when no record has one. The rule of `sumUsage` in the helper's core module. */
export function sumUsage(records) {
  const total = { agents: records.length, tokens: 0, toolUses: 0, durationMs: 0, cost: null };
  for (const record of records) {
    for (const key of USAGE_KEYS) {
      if (typeof record[key] !== 'number') continue;
      total[key] = (total[key] ?? 0) + record[key];
    }
  }
  return total;
}

/**
 * What the agents of a run used, from `usage.jsonl`:
 *   total        every record;
 *   layers       one sum for each layer that has a record, with a sum for each role;
 *   tiers        one sum for each tier, with the number of layers and the mean tokens for a layer;
 *   runLevel     one sum for each role, from the records with no layer: the restacker and the
 *                stack verifier work on several layers.
 */
export function usageOf(run, records) {
  const layers = {};
  for (const layer of run.layers) {
    const own = records.filter((r) => r.layer === layer.id);
    if (!own.length) continue;
    const roles = {};
    for (const role of new Set(own.map((r) => r.role))) roles[role] = sumUsage(own.filter((r) => r.role === role));
    layers[layer.id] = { ...sumUsage(own), roles };
  }
  const tiers = {};
  for (const tier of new Set(run.layers.filter((l) => layers[l.id]).map((l) => l.tier))) {
    const ids = run.layers.filter((l) => l.tier === tier && layers[l.id]).map((l) => l.id);
    const sum = sumUsage(records.filter((r) => ids.includes(r.layer)));
    tiers[tier] = { ...sum, layers: ids.length, tokensPerLayer: Math.round(sum.tokens / ids.length) };
  }
  const loose = records.filter((r) => !run.layers.some((l) => l.id === r.layer));
  const runLevel = {};
  for (const role of new Set(loose.map((r) => String(r.role)))) runLevel[role] = sumUsage(loose.filter((r) => String(r.role) === role));
  return { total: sumUsage(records), layers, tiers, runLevel };
}

// ── Runs ─────────────────────────────────────────────────────────────────────────────────────────

/** Read one run with every derived value. `at` (milliseconds) is "now", for tests. */
export function readRun(root, id, { at = Date.now() } = {}) {
  if (!RUN_ID.test(id)) broken(`invalid run id: ${JSON.stringify(id)}`);
  const dir = path.join(root, id);
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
  const layerTimes = layerEventTimes(events);
  const layers = byPosition(run.layers).map((layer) => ({
    ...layer,
    // Only a tasks run records CI on a layer.
    ci: layer.ci ?? null,
    // A layer of a run from before the outcome key is a pr layer.
    outcome: layer.outcome ?? 'pr',
    report: layer.report ?? null,
    delivery: layer.delivery ?? null,
    lastEvent: layerTimes[layer.id] ?? null,
    column: columnOf(layer, open),
    blockedBy: blockedBy(run, layer.id),
    waitsFor: waitsFor(run, layer.id),
    openFindings: findings[layer.id].filter((f) => f.state === 'open' || f.state === 'not_fixed').length,
  }));
  // Only records: a line such as `null` is valid JSON, and it must not break the page.
  const usageRecords = readJsonl(path.join(dir, 'usage.jsonl'), errors).filter((r) => r !== null && typeof r === 'object' && !Array.isArray(r));
  const lastEvent = lastEventTime(run, events);
  // The current phase of a run that no longer works ends at its last event, not now.
  const until = run.state === 'active' ? new Date(at).toISOString() : lastEvent;
  return {
    run: { ...run, kind: kindOf(run), mainPlans: Array.isArray(run.mainPlans) ? run.mainPlans : [] },
    layers,
    events,
    questions,
    openQuestions: open,
    followups,
    findings,
    next: nextLayer(run, open),
    lastEvent,
    stale: isStale(run, events, open, at),
    phaseTimes: phaseTimes(events, until),
    plans: listPlans(dir),
    session: sessionOf(dir),
    usage: usageOf(run, usageRecords),
    errors,
  };
}

/**
 * Read every run folder in the root with `pick(state)`. A folder that cannot be read goes in
 * `broken` and never stops the scan. Folders with no run files (such as `admin/`) are skipped.
 */
function scanRuns(root, at, pick) {
  if (!existsSync(root)) return { runs: [], broken: [] };
  const runs = [];
  const brokenRuns = [];
  for (const name of readdirSync(root).sort()) {
    const dir = path.join(root, name);
    if (!RUN_ID.test(name) || !statSync(dir).isDirectory()) continue;
    if (!existsSync(path.join(dir, 'run.json')) && !existsSync(path.join(dir, 'ledger.md'))) continue;
    try {
      runs.push(pick(readRun(root, name, { at })));
    } catch (error) {
      brokenRuns.push({ id: name, error: error instanceof BrokenRun ? error.message : `unexpected error: ${error.message}` });
    }
  }
  return { runs, broken: brokenRuns };
}

/** A summary of every run, for the runs list. */
export function listRuns(root, { at = Date.now() } = {}) {
  return scanRuns(root, at, ({ run, layers, openQuestions: open, lastEvent, stale }) => ({
    id: run.id,
    title: run.title,
    kind: run.kind,
    state: run.state,
    stage: run.stage,
    checkout: run.checkout,
    layers: layers.length,
    done: layers.filter((l) => l.column === 'done').length,
    prsOpen: layers.filter((l) => l.pr && l.phase === 'pr_open').length,
    prsMerged: layers.filter((l) => l.pr && l.phase === 'merged').length,
    openQuestions: open.length,
    updated: run.updated,
    created: run.created ?? null,
    archived: run.archived === true,
    lastEvent,
    stale,
  }));
}

/**
 * The layers and open questions of every run, for the board across all runs. Each entry has the
 * shape of `readRun` without the events, findings, follow-ups and phase times, which the board
 * does not show.
 */
export function readBoard(root, { at = Date.now() } = {}) {
  return scanRuns(root, at, ({ run, layers, questions, openQuestions: open, next, lastEvent, stale, plans, session, usage }) => ({
    run: { id: run.id, title: run.title, kind: run.kind, state: run.state, stage: run.stage, checkout: run.checkout, nextStep: run.nextStep, archived: run.archived === true },
    layers,
    // The Tasks view links a report only when its file is there, so it needs the file names.
    plans,
    session,
    // The Tasks view shows the tokens of each task.
    usage: { total: usage.total, layers: usage.layers },
    // Only the questions that a card shows: the open ones and the question of each parked layer.
    questions: questions.filter((q) => q.answer === null || q.answer === undefined || layers.some((l) => l.parked?.question === q.id)),
    openQuestions: open,
    next,
    lastEvent,
    stale,
  }));
}
