/**
 * Notifications of the task manager: tell the user that a run needs an answer, waits, or is done.
 *
 * The ledger calls `notify` after a write. A notification is never part of the run state, and it
 * never makes a ledger command fail: each sender starts as a detached process, and every error is
 * ignored. `notifyNow` is the same send, done in place, for `notify-test`: it reports what
 * happened.
 *
 * The settings are in `<runs root>/config.json`, which belongs to one user on one machine:
 *   { "notify": { "desktop": true, "command": "<shell command>", "events": ["question", ...] } }
 * With no file, or with no `notify` key, nothing is sent.
 *
 * The command gets the event as JSON on stdin and in TASK_MANAGER_* variables. No text of a run
 * goes into a command line, so a question cannot inject shell code.
 */
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import * as path from 'node:path';
import process from 'node:process';

/** `question`: a question opened. `paused`: the run waits. `finished`: the run is done. */
export const NOTIFY_EVENTS = ['question', 'paused', 'finished'];

export const configPath = (root) => path.join(root, 'config.json');

/** The `notify` settings, or `{ error }` when the file cannot be used, or `null` with no settings. */
export function readNotifyConfig(root) {
  const file = configPath(root);
  if (!existsSync(file)) return null;
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return { error: `${file} is not valid JSON` };
  }
  const given = parsed?.notify;
  if (given === undefined || given === null) return null;
  if (typeof given !== 'object' || Array.isArray(given)) return { error: `"notify" in ${file} must be an object` };
  if (given.command !== undefined && (typeof given.command !== 'string' || given.command.trim() === '')) {
    return { error: `"notify.command" in ${file} must be a command, as text` };
  }
  if (given.events !== undefined && !(Array.isArray(given.events) && given.events.every((e) => NOTIFY_EVENTS.includes(e)))) {
    return { error: `"notify.events" in ${file} must be a list of: ${NOTIFY_EVENTS.join(', ')}` };
  }
  return { desktop: given.desktop === true, command: given.command ?? null, events: given.events ?? NOTIFY_EVENTS };
}

const TITLES = { question: 'Task manager: your answer is necessary', paused: 'Task manager: a run waits', finished: 'Task manager: a run is done' };

/** One short line for a desktop notification. */
export function messageOf(event) {
  const where = event.layer ? `${event.title} (${event.layer})` : event.title;
  return event.text ? `${where}: ${event.text}` : where;
}

/**
 * The desktop command for a platform, as an argument list, or `null` when the platform has none.
 * The text goes in as arguments, never as script source.
 */
export function desktopCommand(event, platform = process.platform) {
  const title = TITLES[event.type];
  const message = messageOf(event).slice(0, 240);
  if (platform === 'darwin') {
    // `--` ends the options: without it, a text that starts with `-e` is one more line of script.
    return ['osascript', '-e', 'on run argv', '-e', 'display notification (item 1 of argv) with title (item 2 of argv)', '-e', 'end run', '--', message, title];
  }
  if (platform === 'linux') return ['notify-send', '--', title, message];
  return null;
}

function commandEnv(event, env) {
  return {
    ...env,
    TASK_MANAGER_EVENT: event.type,
    TASK_MANAGER_RUN: event.run,
    TASK_MANAGER_TITLE: event.title,
    TASK_MANAGER_LAYER: event.layer ?? '',
    TASK_MANAGER_QUESTION_ID: event.questionId ?? '',
    TASK_MANAGER_TEXT: event.text ?? '',
    TASK_MANAGER_SESSION_ONLY: event.sessionOnly ? '1' : '',
  };
}

/** The longest text and title that a sender gets. */
export const MAX_TEXT = 4000;
export const MAX_TITLE = 300;

/**
 * Cut the long values. The event goes to the command through a pipe and through the environment.
 * A pipe holds about 64 KB: a larger event would keep the ledger process alive until the command
 * reads it, and a command that reads nothing would then block the ledger.
 */
function bounded(event) {
  const cut = (value, max) => (typeof value === 'string' && value.length > max ? `${value.slice(0, max - 1)}…` : value);
  return { ...event, title: cut(event.title, MAX_TITLE), text: cut(event.text, MAX_TEXT) };
}

/** The senders that the settings ask for, for this event. */
function sendersOf(config, fullEvent, { platform = process.platform, env = process.env } = {}) {
  if (!config || config.error || !config.events.includes(fullEvent.type)) return [];
  const event = bounded(fullEvent);
  const senders = [];
  if (config.desktop) {
    const argv = desktopCommand(event, platform);
    if (argv) senders.push({ name: 'desktop', file: argv[0], args: argv.slice(1), options: {} });
  }
  if (config.command) {
    senders.push({ name: 'command', file: config.command, args: [], options: { shell: true, env: commandEnv(event, env) }, input: `${JSON.stringify(event)}\n` });
  }
  return senders;
}

/** Send in the background. Never throws, and never waits. */
export function notify(root, event, options = {}) {
  try {
    for (const sender of sendersOf(readNotifyConfig(root), event, options)) {
      const child = spawn(sender.file, sender.args, { ...sender.options, detached: true, stdio: [sender.input ? 'pipe' : 'ignore', 'ignore', 'ignore'] });
      child.on('error', () => {});
      if (sender.input) {
        child.stdin.on('error', () => {});
        child.stdin.end(sender.input);
      }
      child.unref();
    }
  } catch {
    // A notification must never fail a ledger write.
  }
}

/** Send in place and report each sender: for `notify-test`. */
export function notifyNow(root, event, options = {}) {
  const config = readNotifyConfig(root);
  if (!config) return { config: configPath(root), sent: [], note: 'no "notify" settings: nothing is sent' };
  if (config.error) return { config: configPath(root), sent: [], error: config.error };
  const sent = sendersOf(config, event, options).map((sender) => {
    const result = spawnSync(sender.file, sender.args, { ...sender.options, input: sender.input, encoding: 'utf8', timeout: 15_000 });
    const ok = !result.error && result.status === 0;
    return ok ? { sender: sender.name, ok } : { sender: sender.name, ok, reason: result.error ? result.error.message : `exit ${result.status}: ${(result.stderr ?? '').trim().slice(0, 200)}` };
  });
  return { config: configPath(root), desktop: config.desktop, command: Boolean(config.command), events: config.events, sent };
}
