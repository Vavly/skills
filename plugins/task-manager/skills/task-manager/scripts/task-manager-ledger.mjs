#!/usr/bin/env node
/**
 * The only writer of task-manager run state. The orchestrator calls it at every event, so no
 * agent edits run JSON by hand. Each command validates its input, writes, and prints one line of
 * JSON. A validation error prints `error: <reason>` on stderr and exits 1.
 *
 * Usage (from the root of the project's checkout):
 *   node <task-manager skill folder>/scripts/task-manager-ledger.mjs <command> [options]
 *
 * The root folder is $TASK_MANAGER_RUNS, default ~/.task-manager/runs.
 * The commands and the data model are in core.md, "Run folder and the ledger".
 */
import { readFileSync } from 'node:fs';
import process from 'node:process';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import {
  LedgerError,
  addDecision,
  addEventCommand,
  addFinding,
  addMainPlan,
  addFollowup,
  answer,
  ask,
  followupFiled,
  initRun,
  listRuns,
  notifyTest,
  park,
  readRun,
  resolve,
  resolveRoot,
  rule,
  setLayer,
  setRun,
  show,
  showLayer,
  unpark,
  waitForAnswer,
} from './lib/task-manager-core.mjs';

const OPTIONS = {
  run: { type: 'string' },
  layer: { type: 'string' },
  id: { type: 'string' },
  set: { type: 'string', multiple: true },
  option: { type: 'string', multiple: true },
  title: { type: 'string' },
  checkout: { type: 'string' },
  kind: { type: 'string' },
  'request-file': { type: 'string' },
  'layers-file': { type: 'string' },
  question: { type: 'string' },
  answer: { type: 'string' },
  tip: { type: 'string' },
  base: { type: 'string' },
  'base-tip': { type: 'string' },
  head: { type: 'string' },
  'last-reviewed': { type: 'string' },
  type: { type: 'string' },
  summary: { type: 'string' },
  round: { type: 'string' },
  sha: { type: 'string' },
  pr: { type: 'string' },
  url: { type: 'string' },
  severity: { type: 'string' },
  file: { type: 'string' },
  line: { type: 'string' },
  defect: { type: 'string' },
  'expected-fix': { type: 'string' },
  ruling: { type: 'string' },
  reason: { type: 'string' },
  state: { type: 'string' },
  body: { type: 'string' },
  'data-loss': { type: 'boolean' },
  'session-only': { type: 'boolean' },
  via: { type: 'string' },
  timeout: { type: 'string' },
  issue: { type: 'string' },
};

function need(values, name) {
  if (values[name] === undefined) throw new LedgerError(`--${name} is required`);
  return values[name];
}

function pairs(values) {
  const list = values.set ?? [];
  if (list.length === 0) throw new LedgerError('give at least one --set key=value');
  return list.map((item) => {
    const index = item.indexOf('=');
    if (index < 1) throw new LedgerError(`--set needs key=value; got ${JSON.stringify(item)}`);
    return [item.slice(0, index), item.slice(index + 1)];
  });
}

function readJsonFile(file, what) {
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch {
    throw new LedgerError(`cannot read the ${what} file ${file}`);
  }
  if (what === 'request') return raw;
  try {
    return JSON.parse(raw);
  } catch {
    throw new LedgerError(`the ${what} file ${file} is not valid JSON`);
  }
}

const COMMANDS = {
  init: (v, root) =>
    initRun(root, {
      title: need(v, 'title'),
      checkout: need(v, 'checkout'),
      request: readJsonFile(need(v, 'request-file'), 'request'),
      layers: readJsonFile(need(v, 'layers-file'), 'layers'),
      kind: v.kind,
    }),
  layer: (v, root) => setLayer(root, need(v, 'run'), need(v, 'layer'), pairs(v), v.summary),
  run: (v, root) => setRun(root, need(v, 'run'), pairs(v), v.summary),
  decision: (v, root) => addDecision(root, need(v, 'run'), need(v, 'question'), need(v, 'answer')),
  event: (v, root) =>
    addEventCommand(root, need(v, 'run'), {
      type: need(v, 'type'),
      layer: v.layer,
      summary: need(v, 'summary'),
      round: v.round,
      sha: v.sha,
      pr: v.pr,
      url: v.url,
    }),
  ask: (v, root) => ask(root, need(v, 'run'), { layer: v.layer, question: need(v, 'question'), options: v.option, sessionOnly: v['session-only'] }),
  answer: (v, root) => answer(root, need(v, 'run'), need(v, 'id'), need(v, 'answer'), v.via),
  park: (v, root) =>
    park(root, need(v, 'run'), need(v, 'layer'), { question: v.question, questionId: v.id, options: v.option, tip: need(v, 'tip'), sessionOnly: v['session-only'] }),
  unpark: (v, root) =>
    unpark(root, need(v, 'run'), need(v, 'layer'), {
      base: need(v, 'base'),
      baseTip: need(v, 'base-tip'),
      head: need(v, 'head'),
      lastReviewed: v['last-reviewed'],
    }),
  'main-plan': (v, root) => addMainPlan(root, need(v, 'run'), need(v, 'file')),
  next: (v, root) => ({ next: readRun(root, need(v, 'run')).next }),
  finding: (v, root) =>
    addFinding(root, need(v, 'run'), need(v, 'layer'), {
      round: need(v, 'round'),
      severity: need(v, 'severity'),
      file: need(v, 'file'),
      line: v.line,
      defect: need(v, 'defect'),
      expectedFix: v['expected-fix'],
    }),
  rule: (v, root) => rule(root, need(v, 'run'), need(v, 'layer'), need(v, 'id'), { ruling: need(v, 'ruling'), reason: v.reason }),
  resolve: (v, root) => resolve(root, need(v, 'run'), need(v, 'layer'), need(v, 'id'), { state: need(v, 'state'), sha: v.sha }),
  followup: (v, root) =>
    addFollowup(root, need(v, 'run'), { layer: v.layer, title: need(v, 'title'), body: need(v, 'body'), dataLoss: v['data-loss'] }),
  'followup-filed': (v, root) => followupFiled(root, need(v, 'run'), need(v, 'id'), need(v, 'issue')),
  list: (v, root) => listRuns(root, { checkout: v.checkout, states: v.state ? v.state.split(',') : undefined }),
  'notify-test': (v, root) => notifyTest(root),
  show: (v, root) => (v.layer ? showLayer(root, need(v, 'run'), v.layer) : show(root, need(v, 'run'))),
};

export function main(argv, env = process.env) {
  const [command, ...rest] = argv;
  if (!command || !Object.hasOwn(COMMANDS, command)) {
    return { code: 1, stderr: `error: unknown command ${JSON.stringify(command ?? '')}; one of ${Object.keys(COMMANDS).join(', ')}, wait` };
  }
  try {
    const { values } = parseArgs({ args: rest, options: OPTIONS, strict: true, allowPositionals: false });
    const result = COMMANDS[command](values, resolveRoot(env));
    return { code: 0, stdout: typeof result === 'string' ? result : JSON.stringify(result) };
  } catch (error) {
    if (error instanceof LedgerError || error?.code?.startsWith?.('ERR_PARSE_ARGS')) {
      return { code: 1, stderr: `error: ${error.message}` };
    }
    throw error;
  }
}

/** `wait --run <id> [--timeout <seconds>]`: the one command that does not end at once. */
export async function waitCommand(rest, env = process.env) {
  try {
    const { values } = parseArgs({ args: rest, options: OPTIONS, strict: true, allowPositionals: false });
    const seconds = values.timeout === undefined ? 0 : Number(values.timeout);
    if (!Number.isFinite(seconds) || seconds < 0) throw new LedgerError(`--timeout must be a number of seconds; got ${JSON.stringify(values.timeout)}`);
    const result = await waitForAnswer(resolveRoot(env), need(values, 'run'), { timeoutMs: seconds * 1000 });
    return { code: 0, stdout: JSON.stringify(result) };
  } catch (error) {
    if (error instanceof LedgerError || error?.code?.startsWith?.('ERR_PARSE_ARGS')) return { code: 1, stderr: `error: ${error.message}` };
    throw error;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const argv = process.argv.slice(2);
  const { code, stdout, stderr } = argv[0] === 'wait' ? await waitCommand(argv.slice(1)) : main(argv);
  if (stdout) process.stdout.write(`${stdout}\n`);
  if (stderr) process.stderr.write(`${stderr}\n`);
  process.exitCode = code;
}
