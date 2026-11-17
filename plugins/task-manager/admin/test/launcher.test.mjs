/**
 * The `task-manager` command (`bin/task-manager`): one short command for the dashboard and the
 * ledger. The tests run it with `/bin/bash`, which is bash 3.2 on macOS. No test writes into the
 * real home folder: each one gives `--dir`, and a `HOME` of its own where the launcher reads it.
 */
import { strict as assert } from 'node:assert';
import { spawn, spawnSync } from 'node:child_process';
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import * as path from 'node:path';
import process from 'node:process';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const PLUGIN = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const SCRIPT = path.join(PLUGIN, 'bin', 'task-manager');

const made = [];
function temp(name) {
  const dir = realpathSync(mkdtempSync(path.join(tmpdir(), `task-manager-launcher-${name}-`)));
  made.push(dir);
  return dir;
}
after(() => {
  for (const dir of made) rmSync(dir, { recursive: true, force: true });
});

function run(file, args, env = {}, options = {}) {
  const out = spawnSync('/bin/bash', [file, ...args], { encoding: 'utf8', env: { ...process.env, ...env }, timeout: 20_000, ...options });
  return { code: out.status, stdout: out.stdout, stderr: out.stderr };
}

/** A copy of the plugin, without its tests, in `dir`. */
function copyPlugin(dir, label = null) {
  mkdirSync(dir, { recursive: true });
  for (const part of ['bin', 'admin', 'skills']) {
    cpSync(path.join(PLUGIN, part), path.join(dir, part), { recursive: true, filter: (src) => !src.includes(`${path.sep}test${path.sep}`) && !src.includes('__tests__') });
  }
  const script = path.join(dir, 'bin', 'task-manager');
  // A label in the help text shows which copy ran.
  if (label) writeFileSync(script, readFileSync(script, 'utf8').replaceAll('task-manager: one short command for the dashboard', `${label} task-manager: one short command for the dashboard`));
  return script;
}

const executable = (file) => (statSync(file).mode & 0o111) !== 0;

test('L1. the command file is executable, and it gives help, the runs, a ledger command and an error for an unknown command', () => {
  assert.equal(executable(SCRIPT), true, 'bin/task-manager must have the executable bit');
  const help = run(SCRIPT, ['help']);
  assert.equal(help.code, 0);
  assert.match(help.stdout, /task-manager admin \[--port <n>\]/);
  assert.match(help.stdout, /With --force it\nreplaces a file of that name that it did not write/);
  assert.equal(run(SCRIPT, []).stdout, help.stdout);
  const root = path.join(temp('runs'), 'runs');
  assert.deepEqual(JSON.parse(run(SCRIPT, ['runs'], { TASK_MANAGER_RUNS: root }).stdout), { runs: [], broken: [] });
  assert.deepEqual(JSON.parse(run(SCRIPT, ['ledger', 'list', '--state', 'active'], { TASK_MANAGER_RUNS: root }).stdout), { runs: [], broken: [] });
  // An error of the ledger passes through, with its exit code.
  const bad = run(SCRIPT, ['ledger', 'show', '--run', '../x'], { TASK_MANAGER_RUNS: root });
  assert.equal(bad.code, 1);
  assert.match(bad.stderr, /invalid run id/);
  const unknown = run(SCRIPT, ['nope']);
  assert.equal(unknown.code, 1);
  assert.match(unknown.stderr, /unknown command nope/);
  // A relative path to the command works, also with a CDPATH that has a folder of the same name.
  const other = temp('cdpath');
  mkdirSync(path.join(other, 'bin'));
  const relative = run('bin/task-manager', ['help'], { CDPATH: other }, { cwd: PLUGIN });
  assert.equal(relative.code, 0, relative.stderr);
  assert.equal(relative.stdout, help.stdout);
});

test('L2. install writes a launcher that works from a path with a space and a quote; it replaces and removes only its own file', () => {
  const base = temp('install');
  // The plugin can be in any folder: a space and a single quote must not break the launcher.
  const script = copyPlugin(path.join(base, "plug in's"));
  const dir = path.join(base, 'my bin');
  const file = path.join(dir, 'task-manager');
  const out = run(script, ['install', '--dir', dir]);
  assert.equal(out.code, 0, out.stderr);
  assert.equal(out.stdout.split('\n')[0], `installed ${file}`);
  assert.match(out.stdout, /This folder is not on your PATH yet/);
  assert.equal(executable(file), true);
  assert.deepEqual(readFileSync(file, 'utf8').split('\n').slice(3, 5), [`stored='${script.replace(/'/g, "'\\''")}'`, "marketplace=''"]);
  const root = path.join(base, 'runs');
  assert.deepEqual(JSON.parse(run(file, ['runs'], { TASK_MANAGER_RUNS: root }).stdout), { runs: [], broken: [] });
  // No temporary file stays, and on the PATH there is no hint.
  assert.deepEqual(spawnSync('ls', ['-A', dir], { encoding: 'utf8' }).stdout.trim(), 'task-manager');
  assert.doesNotMatch(run(script, ['install', '--dir', dir], { PATH: `${dir}:${process.env.PATH}` }).stdout, /not on your PATH/);
  // A relative folder becomes absolute, so the launcher does not depend on the current folder.
  const rel = run(script, ['install', '--dir', 'rel bin'], {}, { cwd: base });
  assert.equal(rel.stdout.split('\n')[0], `installed ${path.join(base, 'rel bin', 'task-manager')}`);

  // A file that this command did not write stays, unless --force.
  const foreign = path.join(base, 'other');
  mkdirSync(foreign);
  writeFileSync(path.join(foreign, 'task-manager'), '#!/bin/sh\necho mine\n');
  const refused = run(script, ['install', '--dir', foreign]);
  assert.equal(refused.code, 1);
  assert.match(refused.stderr, /exists and this command did not write it/);
  const kept = run(script, ['uninstall', '--dir', foreign]);
  assert.equal(kept.code, 1);
  assert.match(kept.stderr, /is not a launcher that this command wrote; it stays/);
  assert.equal(readFileSync(path.join(foreign, 'task-manager'), 'utf8'), '#!/bin/sh\necho mine\n');
  assert.equal(run(script, ['install', '--dir', foreign, '--force']).code, 0);
  assert.equal(run(script, ['uninstall', '--dir', foreign]).code, 0);
  assert.equal(existsSync(path.join(foreign, 'task-manager')), false);
  assert.match(run(script, ['uninstall', '--dir', foreign]).stdout, /nothing to remove/);
  for (const args of [['install', '--dir'], ['install', '--dir', ''], ['install', '--nope']]) assert.equal(run(script, args).code, 1, args.join(' '));
});

test('L3. [review] install never writes through a link, never replaces a folder, and reports a write that fails', () => {
  const base = temp('safe');
  const script = copyPlugin(path.join(base, 'plugin'));
  // A symbolic link at the place of the launcher: the file that it points to must not change.
  const linked = path.join(base, 'linked');
  mkdirSync(linked);
  const victim = path.join(base, 'victim.txt');
  writeFileSync(victim, 'do not touch\n', { mode: 0o644 });
  symlinkSync(victim, path.join(linked, 'task-manager'));
  assert.equal(run(script, ['install', '--dir', linked]).code, 1);
  assert.equal(lstatSync(path.join(linked, 'task-manager')).isSymbolicLink(), true);
  const forced = run(script, ['install', '--dir', linked, '--force']);
  assert.equal(forced.code, 0, forced.stderr);
  assert.equal(readFileSync(victim, 'utf8'), 'do not touch\n');
  assert.equal(executable(victim), false);
  assert.equal(lstatSync(path.join(linked, 'task-manager')).isSymbolicLink(), false);
  assert.equal(run(path.join(linked, 'task-manager'), ['help']).code, 0);

  // The user's own link to the plugin command, then install --force: the command itself must stay.
  const own = path.join(base, 'own');
  mkdirSync(own);
  symlinkSync(script, path.join(own, 'task-manager'));
  const before = readFileSync(script, 'utf8');
  assert.equal(run(script, ['install', '--dir', own, '--force']).code, 0);
  assert.equal(readFileSync(script, 'utf8'), before);
  assert.equal(run(path.join(own, 'task-manager'), ['help']).code, 0);
  // And never into the folder of the command itself.
  const self = run(script, ['install', '--dir', path.dirname(script), '--force']);
  assert.equal(self.code, 1);
  assert.match(self.stderr, /is the folder of the plugin's own command/);
  assert.equal(readFileSync(script, 'utf8'), before);

  // A folder with the name of the launcher stays, also with --force.
  const withFolder = path.join(base, 'folder');
  mkdirSync(path.join(withFolder, 'task-manager'), { recursive: true });
  const folder = run(script, ['install', '--dir', withFolder, '--force']);
  assert.equal(folder.code, 1);
  assert.match(folder.stderr, /is a folder; it stays/);
  // A place that is a file, and a folder with no write permission: an error, not "installed".
  const notDir = run(script, ['install', '--dir', victim]);
  assert.equal(notDir.code, 1);
  assert.match(notDir.stderr, /is not a folder/);
  const locked = path.join(base, 'locked');
  mkdirSync(locked, { mode: 0o555 });
  const denied = run(script, ['install', '--dir', locked]);
  // The owner of a file system (root in a container) can write there: then the install is real.
  if (denied.code !== 0) {
    assert.match(denied.stderr, /cannot write into/);
    assert.doesNotMatch(denied.stdout, /installed/);
  } else {
    assert.equal(existsSync(path.join(locked, 'task-manager')), true);
  }
});

test('L4. after a plugin update, the launcher runs the version that Claude Code records, of the same marketplace only', () => {
  const base = temp('update');
  const home = path.join(base, 'home');
  const cache = path.join(home, '.claude', 'plugins', 'cache');
  const record = path.join(home, '.claude', 'plugins', 'installed_plugins.json');
  const old = copyPlugin(path.join(cache, 'vavly-skills', 'task-manager', '0.1.0'), 'VERSION-ONE');
  const dir = path.join(base, 'bin');
  const launcher = path.join(dir, 'task-manager');
  const env = { HOME: home };
  const which = () => (/VERSION-[A-Z]+/.exec(run(launcher, ['help'], env).stdout) ?? ['none'])[0];
  assert.equal(run(old, ['install', '--dir', dir], env).code, 0);
  assert.match(readFileSync(launcher, 'utf8'), /^marketplace='vavly-skills'$/m);
  // No record yet: the path of the install.
  assert.equal(which(), 'VERSION-ONE');

  // The update: a new version folder. The old folder still exists for a time.
  const next = path.join(cache, 'vavly-skills', 'task-manager', '0.10.0');
  copyPlugin(next, 'VERSION-TWO');
  // Another marketplace has a plugin of the same name, and its files are the newest: it never runs.
  const foreign = copyPlugin(path.join(cache, 'aaa-other', 'task-manager', '9.9.9'), 'VERSION-OTHER');
  const future = new Date(Date.now() + 3_600_000);
  utimesSync(foreign, future, future);
  const entry = (installPath, lastUpdated) => ({ scope: 'user', installPath, version: path.basename(installPath), lastUpdated });
  writeFileSync(record, JSON.stringify({ version: 2, plugins: { 'task-manager@aaa-other': [entry(path.dirname(path.dirname(foreign)), '2026-12-01T00:00:00Z')], 'task-manager@vavly-skills': [entry(path.dirname(path.dirname(old)), '2026-11-01T00:00:00Z'), entry(next, '2026-11-17T00:00:00Z')] } }));
  assert.equal(which(), 'VERSION-TWO');

  // A record that cannot be read, or that names a folder that is gone: the path of the install.
  writeFileSync(record, '{ not json');
  assert.equal(which(), 'VERSION-ONE');
  writeFileSync(record, JSON.stringify({ plugins: { 'task-manager@vavly-skills': [entry(path.join(cache, 'gone'), '2026-11-17T00:00:00Z')] } }));
  assert.equal(which(), 'VERSION-ONE');
  // The plugin is not installed any more: an error that says what to do, also with the other marketplace there.
  rmSync(path.join(cache, 'vavly-skills'), { recursive: true });
  const none = run(launcher, ['runs'], env);
  assert.equal(none.code, 1);
  assert.match(none.stderr, /the task-manager plugin is not where this launcher expects it/);
});

test('L5. admin starts the dashboard on the given root with no browser, and admin stop stops it', { timeout: 30_000 }, async () => {
  const root = path.join(temp('admin'), 'runs');
  mkdirSync(root);
  // Port 0: the system gives a free port, and the server prints it.
  const child = spawn('/bin/bash', [SCRIPT, 'admin', '--no-open', '--port', '0', '--root', root], { env: process.env });
  let out = '';
  child.stdout.on('data', (chunk) => (out += chunk));
  child.stderr.on('data', (chunk) => (out += chunk));
  const closed = new Promise((done) => child.on('close', done));
  const within = (promise, ms, what) => Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error(`${what} took more than ${ms} ms`)), ms))]);
  try {
    let port = null;
    for (let i = 0; i < 400 && !port; i += 1) {
      port = /127\.0\.0\.1:(\d+)/.exec(out)?.[1] ?? null;
      if (!port) await new Promise((done) => setTimeout(done, 25));
    }
    assert.notEqual(port, null, out);
    const res = await fetch(`http://127.0.0.1:${port}/api/runs`);
    assert.deepEqual(await res.json(), { runs: [], broken: [] });
    const stop = run(SCRIPT, ['admin', 'stop', '--port', port]);
    assert.equal(stop.code, 0, stop.stderr);
    assert.equal(await within(closed, 10_000, 'the stop of the server'), 0);
  } finally {
    child.kill('SIGKILL');
  }
});
