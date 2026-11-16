#!/usr/bin/env node
/**
 * A local admin UI for the task-manager runs of this machine. It serves one static page and a
 * JSON API. It never writes a run file itself: the skill's helper is the only writer. Two things
 * run the helper, in the project's own clone:
 *   - "Mark as finished", which the user confirms on the page;
 *   - the PR sync: when GitHub says a layer's PR is merged, it records the merge (see createPrSync).
 *
 * Usage:
 *   node <plugin>/admin/server.mjs [--port <n>] [--root <dir>] [--open]
 *   node <plugin>/admin/server.mjs --stop [--port <n>]
 *
 * `--open` opens the page in the default browser. If the port is in use, it opens the page of the
 * server that has the port, and starts no second server. `--stop` stops the admin server on the
 * port: it sends the server a POST that only this script and the page can send.
 *
 * The root is `$TASK_MANAGER_RUNS`, default `~/.task-manager/runs` (the helper's rule), unless
 * `--root` names another one.
 *
 * Security: the server binds to 127.0.0.1 and answers only a request whose Host header is
 * 127.0.0.1:<port> or localhost:<port>, so a web page that points its own host name at 127.0.0.1
 * (DNS rebinding) cannot read the run data. It sends no CORS headers. Reads are GET. A write is
 * a POST that also needs this page's Origin and the X-Task-Manager-Admin header: another site
 * cannot send that header without a CORS preflight, which this server never allows.
 */
import { execFile, spawn } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import http from 'node:http';
import { homedir } from 'node:os';
import * as path from 'node:path';
import process from 'node:process';
import { URL, fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { BrokenRun, PLAN_FILE, RUN_ID, folderOf, listPlans, listRuns, readBoard, readRun } from './reader.mjs';

const LAYER_ID = /^l[1-9][0-9]*$/;

export const DEFAULT_PORT = 4747;
const HOST = '127.0.0.1';
const HERE = path.dirname(fileURLToPath(import.meta.url));
/** The same rule as `resolveRoot` of the helper's core module. */
export function defaultRoot(env = process.env) {
  return env.TASK_MANAGER_RUNS || path.join(homedir(), '.task-manager', 'runs');
}
const PAGE_DIR = path.join(HERE, 'page');
/** The header that a write needs. Its value names the action. */
export const ACTION_HEADER = 'x-task-manager-admin';
const HELPER_TIMEOUT_MS = 20_000;
const GH_TIMEOUT_MS = 15_000;

const HELPER_PATH = ['skills', 'task-manager', 'scripts', 'task-manager-ledger.mjs'];
/** The helper that ships with this admin page, in the same plugin. */
export const OWN_HELPER = path.join(HERE, '..', ...HELPER_PATH);

/**
 * The helper for a run of this clone: the only writer of its run files. The helper of this plugin
 * comes first, because it has the same schema as this page. A copy of this `admin/` folder with no
 * plugin around it uses the clone's hand-installed skill (`.claude/skills/task-manager/`).
 */
export function helperOf(checkout, own = OWN_HELPER) {
  return existsSync(own) ? own : path.join(checkout, '.claude', ...HELPER_PATH);
}

/** The only page files the server sends. Any other path is 404, so no path can leave PAGE_DIR. */
const PAGE_FILES = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/admin/admin.js': ['admin.js', 'text/javascript; charset=utf-8'],
  '/admin/admin.css': ['admin.css', 'text/css; charset=utf-8'],
};

const BASE_HEADERS = {
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy':
    "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
};

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function send(res, status, type, body) {
  res.writeHead(status, { ...BASE_HEADERS, 'Content-Type': type });
  res.end(body);
}

function sendJson(res, status, value) {
  send(res, status, 'application/json; charset=utf-8', JSON.stringify(value));
}

function decode(segment) {
  try {
    return decodeURIComponent(segment);
  } catch {
    throw new HttpError(400, 'the path is not valid URL encoding');
  }
}

/** The folder of a run. A bad id is 400 and never reaches the file system; an unknown id is 404. */
function runFolder(root, id) {
  if (!RUN_ID.test(id)) throw new HttpError(400, `invalid run id: ${JSON.stringify(id)}`);
  const dir = path.join(root, id);
  if (!existsSync(dir)) throw new HttpError(404, `no run ${id}`);
  return dir;
}

function runState(root, id) {
  runFolder(root, id);
  try {
    return readRun(root, id);
  } catch (error) {
    // A broken folder is data for the page, not a server error: the page shows it as broken.
    if (error instanceof BrokenRun) return { id, broken: error.message };
    throw error;
  }
}

/** A plan file of a run. The name must match PLAN_FILE, be in the run's plans folder, and stay inside it. */
function planText(root, id, name) {
  const dir = runFolder(root, id);
  if (!PLAN_FILE.test(name)) throw new HttpError(400, `invalid plan name: ${JSON.stringify(name)}`);
  if (!listPlans(dir).includes(name)) throw new HttpError(404, `no plan ${name} in run ${id}`);
  const plans = realpathSync(path.join(dir, folderOf(name)));
  const file = realpathSync(path.join(dir, folderOf(name), name));
  // A symbolic link in the run folder must not lead outside it.
  if (!file.startsWith(plans + path.sep)) throw new HttpError(404, `the plan ${name} is outside the run folder`);
  return readFileSync(file, 'utf8');
}

/** A run that the helper can change: readable, with an existing clone that has the helper. */
function writableRun(root, id, helperFor) {
  const state = runState(root, id);
  if (state.broken) throw new HttpError(409, `run ${id} cannot be read: ${state.broken}`);
  const { checkout } = state.run;
  if (!path.isAbsolute(checkout) || !existsSync(checkout)) throw new HttpError(409, `the clone ${checkout} of this project does not exist`);
  const helper = helperFor(checkout);
  if (!existsSync(helper)) throw new HttpError(409, `the clone ${checkout} has no task-manager helper at ${path.relative(checkout, helper)}`);
  return { state, checkout, helper };
}

/** Run the helper of a clone on this root. The helper takes the run lock, validates and records an event. */
function runHelper(root, { checkout, helper }, args) {
  return new Promise((resolvePromise, reject) => {
    execFile(process.execPath, [helper, ...args], { cwd: checkout, env: { ...process.env, TASK_MANAGER_RUNS: root }, timeout: HELPER_TIMEOUT_MS }, (error, stdout, stderr) => {
      if (!error) return resolvePromise(stdout);
      const reason = String(stderr).trim().replace(/^error: /, '') || error.message;
      reject(new HttpError(409, `the helper did not make the change: ${reason}`));
    });
  });
}

/** Mark a project as finished: `run --set state=finished`. */
async function finishRun(root, id, helperFor) {
  const target = writableRun(root, id, helperFor);
  if (target.state.run.state === 'finished') throw new HttpError(409, `run ${id} is already finished`);
  await runHelper(root, target, ['run', '--run', id, '--set', 'state=finished', '--summary', 'Marked finished in the task-manager admin UI']);
  return { id, state: readRun(root, id).run.state };
}

const MAX_ANSWER = 2000;

/** The JSON body of a request, or 400. The body is small: an answer to one question. */
function readJsonBody(req) {
  return new Promise((resolvePromise, reject) => {
    let raw = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > 4 * MAX_ANSWER) reject(new HttpError(413, 'the request body is too large'));
    });
    req.on('error', reject);
    req.on('end', () => {
      try {
        const body = JSON.parse(raw);
        if (body === null || typeof body !== 'object' || Array.isArray(body)) throw new Error('not an object');
        resolvePromise(body);
      } catch {
        reject(new HttpError(400, 'the request body must be a JSON object'));
      }
    });
  });
}

/**
 * Record the user's answer to an open question, through the helper. The session learns it from
 * the ledger: its `wait` command ends, or its next `show` gives the answer. A session-only
 * question (the merge yes) takes no answer here.
 */
async function answerQuestion(root, id, questionId, body, helperFor) {
  const target = writableRun(root, id, helperFor);
  const question = target.state.questions.find((q) => q.id === questionId);
  if (!question) throw new HttpError(404, `no question ${questionId} in run ${id}`);
  if (question.answer !== null && question.answer !== undefined) throw new HttpError(409, `question ${questionId} already has an answer`);
  if (question.sessionOnly) throw new HttpError(409, `question ${questionId} takes an answer in the session only`);
  const answer = typeof body.answer === 'string' ? body.answer.trim() : '';
  if (!answer) throw new HttpError(400, 'the answer is empty: choose an option or write a comment');
  if (answer.length > MAX_ANSWER) throw new HttpError(400, `the answer is longer than ${MAX_ANSWER} characters`);
  // `--answer=<text>`: an answer that starts with a dash must not read as an option.
  await runHelper(root, target, ['answer', '--run', id, '--id', questionId, `--answer=${answer}`, '--via', 'dashboard']);
  const saved = readRun(root, id).questions.find((q) => q.id === questionId);
  return { id: questionId, answer: saved?.answer ?? null };
}

/** The layer of a run, or 404. */
function layerOf(state, id, layerId) {
  const layer = state.layers.find((l) => l.id === layerId);
  if (!layer) throw new HttpError(404, `no layer ${layerId} in run ${id}`);
  return layer;
}

/**
 * Record a layer's merge: `layer --set phase=merged`, then `event --type merge`, as the skill
 * does. Only a layer with an open PR. No
 * `--summary`: the phase times read the helper's default summary, `pr_open -> merged`.
 */
async function mergeLayer(root, id, layerId, helperFor) {
  const target = writableRun(root, id, helperFor);
  const layer = layerOf(target.state, id, layerId);
  if (layer.phase !== 'pr_open' || !layer.pr) throw new HttpError(409, `layer ${layerId} has no open PR (phase ${layer.phase})`);
  await runHelper(root, target, ['layer', '--run', id, '--layer', layerId, '--set', 'phase=merged']);
  // The skill records a merge with this event too ("Phase 2", step 4).
  await runHelper(root, target, ['event', '--run', id, '--layer', layerId, '--type', 'merge', '--summary', `#${layer.pr.number}`]);
}

/** Run `gh` with these arguments; calls back `(error, stdout, stderr)`. Tests replace it. */
function runGh(args, done) {
  execFile('gh', args, { timeout: GH_TIMEOUT_MS }, done);
}

const sameUrl = (a, b) => String(a).replace(/\/+$/, '').toLowerCase() === String(b).replace(/\/+$/, '').toLowerCase();

/**
 * The state on GitHub of a layer's PR (`{number, url}`). It asks by the PR URL, because a layer's
 * PR can be in another repo than the run's clone (for example a shared library): a lookup by
 * number in the clone would find another PR with the same number. A PR with no URL, or an answer
 * for another URL, is an error, so the sync never records a merge for the wrong PR. Never throws:
 * a failure is `{error}`.
 */
export function ghPrState(pr, gh = runGh) {
  return new Promise((resolvePromise) => {
    if (!pr?.url) return resolvePromise({ error: `PR #${pr?.number} has no URL, so its repo is not known` });
    gh(['pr', 'view', pr.url, '--json', 'state,mergedAt,url'], (error, stdout, stderr) => {
      if (error) return resolvePromise({ error: String(stderr).trim() || error.message });
      try {
        const { state, mergedAt, url } = JSON.parse(stdout);
        if (!sameUrl(url, pr.url)) return resolvePromise({ error: `GitHub answered for ${url}, not for ${pr.url}` });
        resolvePromise({ state, mergedAt: mergedAt || null, url });
      } catch {
        resolvePromise({ error: 'gh gave output that is not JSON' });
      }
    });
  });
}

/** How long a GitHub answer is kept. The sweep and the PRs tab share it. */
export const GH_TTL_MS = 60_000;

/**
 * Who records a merge: the admin, for a run that no session works on (paused, finished, or
 * stale); otherwise the run's own session, because a merge also starts its restack of the PRs
 * above, and a merge that the admin records first would hide that from it. A tasks run has no PR
 * above another, so a merge starts nothing in its session: the admin always records it.
 */
export function adminRecordsMerges(state) {
  return state.run.kind === 'tasks' || state.run.state !== 'active' || Boolean(state.stale);
}

/**
 * The PR sync. It asks GitHub about the open PRs and, when GitHub says merged, records the merge
 * through the helper of the run's clone, for the runs that adminRecordsMerges allows.
 *   status(id, layerId): the GitHub state of one layer's PR, for the PRs tab; it records too.
 *   sweep(): one pass over every run that the admin records; the server runs it every minute.
 */
export function createPrSync({ root, helperFor = helperOf, prState = ghPrState, log = () => {} }) {
  const answers = new Map();
  const recording = new Set();

  /** The GitHub state of a layer's PR, kept for GH_TTL_MS by its URL. */
  async function github(pr) {
    const key = pr.url ?? `#${pr.number}`;
    const kept = answers.get(key);
    if (kept && Date.now() - kept.at < GH_TTL_MS) return kept.value;
    const value = await prState(pr);
    answers.set(key, { at: Date.now(), value });
    return value;
  }

  /** After GitHub said `pr`: record the merge if this run is the admin's to record. */
  async function settle(id, layerId, pr) {
    if (pr.state !== 'MERGED') return {};
    const state = readRun(root, id);
    const layer = state.layers.find((l) => l.id === layerId);
    if (!layer || layer.phase !== 'pr_open') return { recorded: layer?.phase === 'merged' };
    if (!adminRecordsMerges(state)) return { waitsForSession: true };
    const key = `${id}/${layerId}`;
    if (recording.has(key)) return {};
    recording.add(key);
    try {
      await mergeLayer(root, id, layerId, helperFor);
      log(`recorded the merge of PR #${layer.pr.number} (${id} ${layerId})`);
      return { recorded: true };
    } catch (error) {
      log(`cannot record the merge of PR #${layer.pr.number} (${id} ${layerId}): ${error.message}`);
      return { recordError: error.message };
    } finally {
      recording.delete(key);
    }
  }

  async function status(id, layerId) {
    const state = runState(root, id);
    if (state.broken) throw new HttpError(409, `run ${id} cannot be read: ${state.broken}`);
    const layer = layerOf(state, id, layerId);
    if (!layer.pr) throw new HttpError(404, `layer ${layerId} has no PR`);
    if (layer.phase !== 'pr_open') return { number: layer.pr.number, phase: layer.phase };
    const pr = await github(layer.pr);
    return { number: layer.pr.number, ...pr, ...(await settle(id, layerId, pr)) };
  }

  let sweeping = false;
  async function sweep() {
    if (sweeping) return;
    sweeping = true;
    try {
      for (const entry of readBoard(root).runs) {
        if (!adminRecordsMerges(entry)) continue;
        for (const l of entry.layers) {
          if (l.phase === 'pr_open' && l.pr) await settle(entry.run.id, l.id, await github(l.pr));
        }
      }
    } catch (error) {
      log(`PR sync failed: ${error.message}`);
    } finally {
      sweeping = false;
    }
  }

  return { status, sweep };
}

/** A write must come from this page: the right Origin and the action header. */
function checkWrite(req, port, action) {
  const origins = [`http://${HOST}:${port}`, `http://localhost:${port}`];
  if (!origins.includes(req.headers.origin)) throw new HttpError(403, 'a change must come from the admin page');
  if (req.headers[ACTION_HEADER] !== action) throw new HttpError(403, `a change needs the ${ACTION_HEADER} header`);
}

function route(root, pathname, res) {
  const page = PAGE_FILES[pathname];
  if (page) {
    send(res, 200, page[1], readFileSync(path.join(PAGE_DIR, page[0])));
    return;
  }
  if (pathname === '/api/runs') {
    sendJson(res, 200, listRuns(root));
    return;
  }
  if (pathname === '/api/board') {
    sendJson(res, 200, readBoard(root));
    return;
  }
  const match = /^\/api\/runs\/([^/]+)(?:\/plans\/([^/]+))?$/.exec(pathname);
  if (!match) throw new HttpError(404, 'not found');
  const id = decode(match[1]);
  if (match[2] === undefined) {
    sendJson(res, 200, runState(root, id));
    return;
  }
  send(res, 200, 'text/plain; charset=utf-8', planText(root, id, decode(match[2])));
}

/**
 * The request handler. `port()` gives the bound port, for the Host and Origin checks. `helperFor`
 * finds the helper of a clone, and `sync` is the PR sync; tests replace them.
 */
export function createHandler(root, port, { helperFor = helperOf, sync = createPrSync({ root, helperFor }), stop = () => {} } = {}) {
  return async (req, res) => {
    try {
      const allowed = [`${HOST}:${port()}`, `localhost:${port()}`];
      if (!allowed.includes(req.headers.host)) throw new HttpError(403, 'this server answers only 127.0.0.1 and localhost');
      const pathname = new URL(req.url, `http://${HOST}`).pathname;
      const finish = /^\/api\/runs\/([^/]+)\/finish$/.exec(pathname);
      if (finish) {
        if (req.method !== 'POST') {
          res.setHeader('Allow', 'POST');
          throw new HttpError(405, 'only POST is accepted here');
        }
        checkWrite(req, port(), 'finish');
        sendJson(res, 200, await finishRun(root, decode(finish[1]), helperFor));
        return;
      }
      const answer = /^\/api\/runs\/([^/]+)\/questions\/(q[1-9][0-9]*)\/answer$/.exec(pathname);
      if (answer) {
        if (req.method !== 'POST') {
          res.setHeader('Allow', 'POST');
          throw new HttpError(405, 'only POST is accepted here');
        }
        checkWrite(req, port(), 'answer');
        sendJson(res, 200, await answerQuestion(root, decode(answer[1]), answer[2], await readJsonBody(req), helperFor));
        return;
      }
      if (pathname === '/api/stop') {
        if (req.method !== 'POST') {
          res.setHeader('Allow', 'POST');
          throw new HttpError(405, 'only POST is accepted here');
        }
        checkWrite(req, port(), 'stop');
        // Answer first: the caller must learn that this server stopped.
        res.setHeader('Connection', 'close');
        sendJson(res, 200, { stopped: true });
        res.on('finish', stop);
        return;
      }
      const pr = /^\/api\/runs\/([^/]+)\/layers\/([^/]+)\/pr$/.exec(pathname);
      if (pr && req.method === 'GET') {
        const layerId = decode(pr[2]);
        if (!LAYER_ID.test(layerId)) throw new HttpError(400, `invalid layer id: ${JSON.stringify(layerId)}`);
        sendJson(res, 200, await sync.status(decode(pr[1]), layerId));
        return;
      }
      if (req.method !== 'GET') {
        res.setHeader('Allow', 'GET');
        throw new HttpError(405, 'only GET is accepted');
      }
      route(root, pathname, res);
    } catch (error) {
      const status = error instanceof HttpError ? error.status : 500;
      sendJson(res, status, { error: status === 500 ? `server error: ${error.message}` : error.message });
    }
  };
}

/**
 * Start the server on 127.0.0.1. Resolves with the server when it listens. Port 0 picks a free
 * port. With `syncMs`, the PR sync sweeps at start and then every `syncMs`. `server.prSync` is
 * the sync, for tests.
 */
export function startAdminServer({ root = defaultRoot(), port = DEFAULT_PORT, helperFor = helperOf, prState, syncMs = 0, log } = {}) {
  const server = http.createServer();
  const sync = createPrSync({ root, helperFor, prState, log });
  server.prSync = sync;
  const stop = () => {
    server.close();
    // The page keeps a connection open for its polls. Without this, close() waits for it.
    server.closeAllConnections();
  };
  server.on('request', createHandler(root, () => server.address().port, { helperFor, sync, stop }));
  return new Promise((resolvePromise, reject) => {
    server.once('error', reject);
    server.listen(port, HOST, () => {
      server.off('error', reject);
      if (syncMs > 0) {
        const timer = setInterval(() => sync.sweep(), syncMs);
        setTimeout(() => sync.sweep(), 0);
        server.on('close', () => clearInterval(timer));
      }
      resolvePromise(server);
    });
  });
}

/** The command that opens a URL in the default browser of this platform. */
export function openCommand(url, platform = process.platform) {
  if (platform === 'darwin') return ['open', [url]];
  // `start` is a builtin of cmd. Its first quoted argument is a window title, so give an empty one.
  if (platform === 'win32') return ['cmd', ['/c', 'start', '""', url]];
  return ['xdg-open', [url]];
}

/** Open a URL in the default browser. A failure is not an error of the server: the URL is printed. */
export function openInBrowser(url) {
  const [command, args] = openCommand(url);
  try {
    const child = spawn(command, args, { stdio: 'ignore', detached: true });
    child.on('error', () => {});
    child.unref();
  } catch {
    // No opener on this machine. The user has the URL.
  }
}

/**
 * Ask the admin server on `port` to stop. Resolves with true when it stopped, and with false when
 * no admin server answers there. Another program on the port does not know this request, so it is
 * never stopped.
 */
export function stopAdminServer(port) {
  return new Promise((resolvePromise) => {
    const req = http.request(
      { host: HOST, port, path: '/api/stop', method: 'POST', headers: { origin: `http://${HOST}:${port}`, [ACTION_HEADER]: 'stop' }, timeout: 5000 },
      (res) => {
        let body = '';
        res.on('data', (chunk) => (body += chunk));
        res.on('end', () => {
          let stopped = false;
          try {
            stopped = res.statusCode === 200 && JSON.parse(body).stopped === true;
          } catch {
            // Not our server.
          }
          resolvePromise(stopped);
        });
      },
    );
    req.on('timeout', () => req.destroy());
    req.on('error', () => resolvePromise(false));
    req.end();
  });
}

export async function main(argv = process.argv.slice(2), { openUrl = openInBrowser } = {}) {
  const { values } = parseArgs({ args: argv, options: { port: { type: 'string' }, root: { type: 'string' }, open: { type: 'boolean' }, stop: { type: 'boolean' } }, strict: true });
  const port = values.port === undefined ? DEFAULT_PORT : Number(values.port);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error(`--port must be an integer from 0 to 65535; got ${JSON.stringify(values.port)}`);
  if (values.stop) {
    if (values.open || values.root !== undefined) throw new Error('--stop takes only --port');
    const stopped = await stopAdminServer(port);
    process.stdout.write(stopped ? `stopped the task-manager admin server on port ${port}\n` : `no task-manager admin server answers on port ${port}\n`);
    return null;
  }
  const root = path.resolve(values.root ?? defaultRoot());
  if (!existsSync(root)) throw new Error(`the root ${root} does not exist; a run makes it, or start with --root <dir>`);
  try {
    const log = (line) => process.stdout.write(`${new Date().toLocaleTimeString()} ${line}\n`);
    const server = await startAdminServer({ root, port, syncMs: GH_TTL_MS, log });
    const url = `http://${HOST}:${server.address().port}/`;
    process.stdout.write(`task-manager admin: ${url}\nroot: ${root}\n`);
    if (values.open) openUrl(url);
    return server;
  } catch (error) {
    if (error.code === 'EADDRINUSE' && values.open) {
      // Most probably an admin server runs already. Show its page, and start nothing.
      const url = `http://${HOST}:${port}/`;
      process.stdout.write(`port ${port} is in use; opened ${url}\n`);
      openUrl(url);
      return null;
    }
    if (error.code === 'EADDRINUSE') throw new Error(`port ${port} is in use; start with --port <n> to use another port`, { cause: error });
    throw error;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`error: ${error.message}\n`);
    process.exit(1);
  });
}
