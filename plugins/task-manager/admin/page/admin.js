/**
 * The task-manager admin page. Read-only: it polls the JSON API of task-manager-admin.mjs and draws
 * one view. Every derived value (column, blockedBy, waitsFor, next, stale, phase times) comes from
 * the server, which takes it from the core module. This file only lays the data out.
 *
 * Run data is written by agents and can hold any characters, so it goes into the page only as
 * text (`textContent` through `h`), never as HTML.
 */

const POLL_MS = 3000;
const COLUMNS = [
  ['todo', 'To do'],
  ['in_progress', 'In progress'],
  ['needs_input', 'Needs input'],
  ['done', 'Done'],
];
const PHASES = ['queued', 'implementing', 'review', 'fixing', 'final_checks', 'opening_pr', 'pr_open', 'merged', 'delivered'];

const view = document.getElementById('view');
const live = document.getElementById('live');
let timer = null;
let token = 0;
/** The plan text in view, so that a poll does not fetch it again. */
let planCache = { key: null, text: null, error: null };

// ── DOM helpers ──────────────────────────────────────────────────────────────────────────────────

/** Make an element. Strings and numbers become text nodes; null, undefined and false are skipped. */
function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs ?? {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key.startsWith('on') && typeof value === 'function') el.addEventListener(key.slice(2), value);
    else if (key === 'class') el.className = value;
    else el.setAttribute(key, value === true ? '' : String(value));
  }
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

/** A link only for an http(s) URL. Anything else shows as text. */
function extLink(url, label) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol === 'https:' || parsed.protocol === 'http:') {
      return h('a', { href: parsed.href, target: '_blank', rel: 'noopener noreferrer' }, label);
    }
  } catch {
    // not a URL
  }
  return h('span', null, label);
}

const clone = (checkout) => (checkout ?? '').split('/').filter(Boolean).pop() ?? '';
const enc = encodeURIComponent;

function ago(ts) {
  const ms = Date.now() - Date.parse(ts);
  if (Number.isNaN(ms)) return '-';
  if (ms < 60_000) return 'just now';
  return `${duration(ms)} ago`;
}

/** The outcomes that are not a pull request: the badge of a card, and the word in a table. */
const OUTCOME_LABEL = { report: 'Report', issue: 'Issues', comment: 'PR comment' };
const OUTCOME_WORD = { report: 'report', issue: 'issues', comment: 'comment' };

/** A token count, short: 950, 12.4k, 1.8M. */
function tokens(n) {
  if (typeof n !== 'number') return '-';
  if (n < 1000) return String(n);
  // The limits are where the rounded value reaches the next unit: 99.95k shows as 100k, not 100.0k.
  if (n < 99_950) return `${(n / 1000).toFixed(1)}k`;
  if (n < 999_500) return `${Math.round(n / 1000)}k`;
  return `${(n / 1_000_000).toFixed(1)}M`;
}

/** One line for what a layer, a tier or a run used. `u` is a sum from the server, or nothing. */
function usageText(u) {
  if (!u || !u.agents) return 'no usage recorded';
  const parts = [`${tokens(u.tokens)} tokens`, `${u.toolUses} tool uses`, `${duration(u.durationMs)} of agent time`, `${u.agents} agent${u.agents === 1 ? '' : 's'}`];
  if (typeof u.cost === 'number') parts.push(`$${u.cost.toFixed(2)}`);
  return parts.join(' · ');
}

/** The usage of each layer, by role, and the mean for each tier: are the tiers set correctly? */
function usageTable(state) {
  const usage = state.usage;
  const rows = state.layers.filter((l) => usage?.layers?.[l.id]);
  if (!rows.length) return h('p', { class: 'muted' }, 'No usage recorded yet. The orchestrator records it when an agent returns.');
  const roles = ['implementer', 'reviewer', 'restacker', 'verifier'].filter((role) => rows.some((l) => usage.layers[l.id].roles[role]));
  const tiers = Object.keys(usage.tiers ?? {}).sort();
  return h(
    'div',
    null,
    h(
      'table',
      { class: 'phases' },
      h('thead', null, h('tr', null, ['Layer', 'Tier', ...roles.map((r) => `${r} tokens`), 'Total tokens', 'Tool uses', 'Agent time'].map((t) => h('th', null, t)))),
      h(
        'tbody',
        null,
        rows.map((l) => {
          const u = usage.layers[l.id];
          return h('tr', null, h('td', null, h('a', { href: layerHref(state, l) }, l.id), h('span', { class: 'muted small' }, ` ${l.task}`)), h('td', null, l.tier), roles.map((r) => h('td', null, tokens(u.roles[r]?.tokens))), h('td', null, tokens(u.tokens)), h('td', null, String(u.toolUses)), h('td', null, duration(u.durationMs)));
        }),
      ),
    ),
    tiers.length ? h('p', { class: 'muted small' }, 'Mean for a layer of each tier: ', tiers.map((t) => `${t}: ${tokens(usage.tiers[t].tokensPerLayer)} tokens (${usage.tiers[t].layers})`).join(' · ')) : null,
    Object.keys(usage.runLevel ?? {}).map((role) => h('p', { class: 'muted small' }, `For the run, ${role}: ${usageText(usage.runLevel[role])}`)),
  );
}

function duration(ms) {
  const min = Math.round(ms / 60_000);
  if (min < 1) return '< 1 min';
  if (min < 60) return `${min} min`;
  const hours = Math.floor(min / 60);
  if (hours < 48) return `${hours} h ${min % 60} min`;
  return `${Math.floor(hours / 24)} d ${hours % 24} h`;
}

function time(ts) {
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? String(ts ?? '-') : d.toLocaleString();
}

/**
 * Text that changes only with the clock. The view does not redraw for it: `tick()` rewrites these
 * elements in place, so a poll with no new run data leaves the page untouched.
 *   data-ago="<ts>"                      -> "5 min ago"
 *   data-since="<ts>" data-prefix="..."  -> "<prefix>5 min"
 *   data-ms="<n>" data-at="<ms>"         -> duration(n + now - at), a phase that is still open
 */
const agoEl = (tag, attrs, ts, prefix = '') => h(tag, { ...attrs, 'data-ago': ts, 'data-prefix': prefix }, `${prefix}${ago(ts)}`);
const sinceEl = (tag, attrs, ts, prefix) => h(tag, { ...attrs, 'data-since': ts, 'data-prefix': prefix }, `${prefix}${duration(Date.now() - Date.parse(ts))}`);

function tick() {
  for (const el of view.querySelectorAll('[data-ago]')) el.textContent = `${el.dataset.prefix ?? ''}${ago(el.dataset.ago)}`;
  for (const el of view.querySelectorAll('[data-since]')) el.textContent = `${el.dataset.prefix ?? ''}${duration(Date.now() - Date.parse(el.dataset.since))}`;
  for (const el of view.querySelectorAll('[data-ms]')) el.textContent = duration(Number(el.dataset.ms) + Date.now() - Number(el.dataset.at));
}

/** The time the data on screen was fetched. An open phase's time grows from here. */
let fetchedAt = Date.now();

const badge = (text, kind) => h('span', { class: `badge ${kind ?? ''}` }, text);

// ── Data ─────────────────────────────────────────────────────────────────────────────────────────

async function getJson(url) {
  const res = await fetch(url, { cache: 'no-store' });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error ?? `${res.status} ${res.statusText}`);
  return body;
}

async function getPlan(id, name) {
  const key = `${id}/${name}`;
  if (planCache.key === key) return planCache;
  planCache = { key, text: null, error: null };
  try {
    const res = await fetch(`/api/runs/${enc(id)}/plans/${enc(name)}`, { cache: 'no-store' });
    if (res.ok) planCache.text = await res.text();
    else planCache.error = (await res.json().catch(() => ({}))).error ?? `${res.status}`;
  } catch (error) {
    planCache.error = error.message;
  }
  return planCache;
}

// ── Router and polling ───────────────────────────────────────────────────────────────────────────

function parseHash() {
  const parts = location.hash.replace(/^#\/?/, '').split('/').filter(Boolean).map(decodeURIComponent);
  if (parts[0] === 'runs') return { name: 'runs' };
  if (parts[0] === 'tasks') return { name: 'tasks' };
  if (parts[0] === 'task' && parts[1] && parts[2]) return { name: 'task', id: parts[1], layer: parts[2], tab: parts[3] ?? 'overview', plan: parts[4] ?? null };
  if (parts[0] !== 'run' || !parts[1]) return { name: 'board' };
  if (parts[2] === 'layer' && parts[3]) return { name: 'layer', id: parts[1], layer: parts[3] };
  if (parts[2] === 'timeline') return { name: 'timeline', id: parts[1] };
  if (parts[2] === 'followups') return { name: 'followups', id: parts[1] };
  if (parts[2] === 'prs') return { name: 'prs', id: parts[1] };
  if (parts[2] === 'plans') return { name: 'plans', id: parts[1], plan: parts[3] ?? null };
  return { name: 'run-board', id: parts[1] };
}

/** The settings of this user that the page needs: `startSessions` permits the "Start a session" button. */
let settings = { startSessions: false, confirmOnPage: false };

/**
 * True when no process gives an answer to a session: no watcher runs, and the page started no
 * session. An open session can still be there, but it does not see an answer from this page.
 */
function noWatcher(state) {
  return Boolean(state.session) && !state.session.watching && !state.session.started && state.run.state !== 'finished';
}

/** What the user does after an answer that no session watches for. */
function tellSession(state) {
  return `No session watches run ${state.run.id}. If its session is open, type a message there after your answer, for example "I answered on the admin page". If it is closed, run /task-manager resume ${state.run.id}${settings.startSessions ? ', or use "Start a session" on the run page' : ''}.`;
}

/**
 * Who works on a run, and the button that starts a session when nobody does. A session that
 * watches gets an answer by itself. With no session, an answer waits for a resume.
 */
function sessionControl(state) {
  const { run, session } = state;
  if (!session || run.state === 'finished') return null;
  if (session.started) return h('span', { class: 'badge session', title: `process ${session.started.pid}` }, 'session started from this page');
  if (session.watching) return h('span', { class: 'badge session', title: 'A session waits for answers to this run' }, 'a session watches');
  // An active run belongs to the session that works on it. Only a long silence shows that it is gone.
  const idle = run.state === 'paused' || !state.lastEvent || Date.now() - Date.parse(state.lastEvent) >= 60 * 60 * 1000;
  if (!idle) {
    const badgeEl = h('span', { class: 'badge session', title: 'The run is active: a session works on it, or a session ended and left it active' }, 'active');
    // A session can end and leave its run active. Only the user knows if their own session still works.
    return settings.startSessions ? [badgeEl, h('button', { type: 'button', class: 'btn', onclick: () => confirmStartSession(state, true) }, 'Start a session…')] : badgeEl;
  }
  if (!settings.startSessions) return h('span', { class: 'badge', title: 'An answer waits until you run /task-manager resume. To start a session from this page, set "resume.enabled" in config.json of the runs folder.' }, 'no session');
  return h('button', { type: 'button', class: 'btn', onclick: () => confirmStartSession(state) }, 'Start a session');
}

/** Ask before starting a session: it runs with no terminal, in the clone of the run. */
function confirmStartSession(state, active = false) {
  const { run } = state;
  const sure = h('input', { type: 'checkbox' });
  openConfirm({
    getBody: active
      ? () => {
        if (!sure.checked) throw new Error('Confirm that no session of yours works on this run.');
        return { evenIfActive: true };
      }
      : null,
    title: 'Start a session for this run?',
    confirmLabel: 'Start a session',
    confirmClass: 'btn',
    url: `/api/runs/${enc(run.id)}/session`,
    action: 'session',
    content: h(
      'div',
      null,
      active ? h('p', { class: 'warn-text' }, 'This run is active. A session works on it, or a session ended and left it active. Two sessions in one clone damage the work of each other.') : null,
      active ? h('label', { class: 'answer-option' }, sure, ' No session of mine works on this run') : null,
      h('p', null, 'This starts a session with no terminal that runs ', h('code', null, `/task-manager resume ${run.id}`), ' in this folder:'),
      h('p', null, h('code', null, run.checkout)),
      h('ul', null, h('li', null, 'Start it only if you know this folder: the session uses the settings that are in it.'), h('li', null, 'It acts on the answers that wait, and it continues the run.'), h('li', null, 'It changes files in that clone. Do not work in the clone at the same time.'), h('li', null, 'It cannot ask you in a terminal. A session-only question still needs your own session.'), h('li', null, 'Its output goes to ', h('code', null, 'session.log'), ' in the run folder.')),
    ),
  });
}

/** The data and route of the view on screen. A poll with the same signature does not redraw. */
let lastSignature = null;

async function build(route, data) {
  if (route.name === 'board') return renderGeneralBoard(data);
  if (route.name === 'runs') return renderRuns(data);
  if (route.name === 'tasks') return renderTasks(data);
  if (data.broken) return renderBrokenRun(route.id, data.broken);
  if (route.name === 'layer') return renderLayer(data, route.layer);
  if (route.name === 'task') return renderTask(data, route);
  if (route.name === 'plans') return h('div', null, runHeader(data, 'plans'), await renderPlans(data, route.plan));
  return renderRun(data, route.name);
}

/** True while the user has text selected in the view. A redraw would lose the selection. */
function selectionInView() {
  const selection = document.getSelection();
  return Boolean(selection && !selection.isCollapsed && view.contains(selection.anchorNode));
}

/**
 * The state that the user changes and that the data does not hold: open or closed sections and
 * scroll positions. Elements with `data-keep` carry it across a redraw, matched by that key.
 */
function captureState() {
  const kept = new Map();
  for (const el of view.querySelectorAll('[data-keep]')) {
    kept.set(el.dataset.keep, { open: el.open, top: el.scrollTop, left: el.scrollLeft });
  }
  // A text box with an id keeps its focus and its caret: the list redraws while the user types.
  const active = document.activeElement;
  const focus = active && active.id && view.contains(active) ? { id: active.id, start: active.selectionStart ?? null, end: active.selectionEnd ?? null } : null;
  return { kept, x: window.scrollX, y: window.scrollY, focus };
}

function restoreState({ kept, x, y, focus }) {
  if (focus) {
    const el = document.getElementById(focus.id);
    if (el && view.contains(el)) {
      el.focus();
      if (focus.start !== null && el.setSelectionRange) el.setSelectionRange(focus.start, focus.end ?? focus.start);
    }
  }
  for (const el of view.querySelectorAll('[data-keep]')) {
    const saved = kept.get(el.dataset.keep);
    if (!saved) continue;
    if (el.tagName === 'DETAILS') el.open = saved.open;
    el.scrollTop = saved.top;
    el.scrollLeft = saved.left;
  }
  window.scrollTo(x, y);
}

/** The data on screen, so that a filter change redraws without a fetch. */
let lastData = null;

/** Draw the view and keep the user's state. Returns false when a newer refresh started. */
async function draw(route, data, mine) {
  const node = await build(route, data);
  if (mine !== token) return false;
  const saved = captureState();
  view.replaceChildren(node);
  restoreState(saved);
  return true;
}

/** Redraw from the data on screen, after a filter change. */
function redraw() {
  if (lastData) draw(lastData.route, lastData.data, token);
}

/** Mark the menu item of the current view. Project pages belong to "Projects", task pages to "Tasks". */
function markMenu(route) {
  const item = route.name === 'board' ? '#/' : route.name === 'tasks' || route.name === 'task' ? '#/tasks' : '#/runs';
  for (const a of document.querySelectorAll('.menu a')) a.classList.toggle('active', a.getAttribute('href') === item);
}

async function refresh({ force = false } = {}) {
  const mine = ++token;
  const route = parseHash();
  markMenu(route);
  try {
    const url = route.name === 'board' || route.name === 'tasks' ? '/api/board' : route.name === 'runs' ? '/api/runs' : `/api/runs/${enc(route.id)}`;
    const [data, fresh] = await Promise.all([getJson(url), getJson('/api/settings').catch(() => ({ startSessions: false, confirmOnPage: false }))]);
    if (mine !== token) return;
    settings = fresh;
    live.textContent = `Updated ${new Date().toLocaleTimeString()}`;
    live.classList.remove('error');
    // Phase times grow with the clock on an active run. They are not run data that changed, so they
    // stay out of the signature; tick() updates them in place.
    const signature = `${location.hash}|${JSON.stringify(settings)}|${JSON.stringify({ ...data, phaseTimes: undefined })}`;
    if (!force && signature === lastSignature) return;
    // Keep the user's selection. The next poll tries again.
    if (!force && selectionInView()) return;
    fetchedAt = Date.now();
    lastData = { route, data };
    if (!(await draw(route, data, mine))) return;
    lastSignature = signature;
  } catch (error) {
    if (mine !== token) return;
    live.textContent = `Cannot read: ${error.message}`;
    live.classList.add('error');
    if (!view.dataset.ready) view.replaceChildren(h('p', { class: 'error' }, error.message));
  }
  view.dataset.ready = '1';
}

function schedule() {
  clearTimeout(timer);
  timer = null;
  if (document.visibilityState === 'hidden') return;
  timer = setTimeout(async () => {
    await refresh();
    schedule();
  }, POLL_MS);
}

window.addEventListener('hashchange', () => {
  delete view.dataset.ready;
  lastSignature = null;
  refresh({ force: true }).then(() => window.scrollTo(0, 0)).then(schedule);
});
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') refresh().then(schedule);
  else schedule();
});
refresh().then(schedule);
setInterval(tick, 15_000);

// ── Runs view ────────────────────────────────────────────────────────────────────────────────────

/** The filters of the Projects view, kept in this browser: a search text, a clone or null for all, and the archive switch. */
const RUN_FILTER_KEY = 'task-manager-admin:run-filters';

function loadRunFilters() {
  try {
    const saved = JSON.parse(localStorage.getItem(RUN_FILTER_KEY) ?? 'null');
    if (saved && typeof saved === 'object') return { text: typeof saved.text === 'string' ? saved.text : '', clone: typeof saved.clone === 'string' ? saved.clone : null, archived: saved.archived === true };
  } catch {
    // No storage in this browser: the filters last until the page closes.
  }
  return { text: '', clone: null, archived: false };
}

let runFilters = loadRunFilters();

function setRunFilters(change) {
  runFilters = { ...runFilters, ...change };
  try {
    localStorage.setItem(RUN_FILTER_KEY, JSON.stringify(runFilters));
  } catch {
    // See loadRunFilters.
  }
  redraw();
}

/**
 * The handlers of a search box. Each change redraws the view, and a redraw makes a new input. A
 * dead key or an input method composes a character in the input over several events, so a redraw
 * in between cuts it: the change waits for the end of the composition.
 */
function searchHandlers(change) {
  return {
    oninput: (event) => {
      if (!event.isComposing) change(event.target.value);
    },
    oncompositionend: (event) => change(event.target.value),
  };
}

/** True when every word of the search is in the title, the id or the clone of the run. */
function matchesSearch(text, ...fields) {
  const hay = fields.join(' ').toLowerCase();
  return text.toLowerCase().split(/\s+/).filter(Boolean).every((word) => hay.includes(word));
}

/** The search box, the clone chips and the archive switch, for a list of runs with `checkout` and `archived`. */
function runToolbar(items, filtersNow, setter, checkoutOf, archivedOf) {
  const clones = [...new Set(items.map((r) => clone(checkoutOf(r))))].sort();
  const archivedCount = items.filter(archivedOf).length;
  return h(
    'div',
    { class: 'filters' },
    h(
      'div',
      { class: 'filter-row' },
      h('input', { type: 'search', id: 'run-search', class: 'run-search', placeholder: 'Search by title, id or clone', value: filtersNow.text, 'aria-label': 'Search', ...searchHandlers((text) => setter({ text })) }),
      clones.length > 1 ? [h('span', { class: 'filter-label' }, 'Clone'), chip('All', !filtersNow.clone || !clones.includes(filtersNow.clone), () => setter({ clone: null })), clones.map((c) => chip(c, filtersNow.clone === c, () => setter({ clone: c })))] : null,
      archivedCount || filtersNow.archived
        ? h('label', { class: 'switch' }, h('input', { type: 'checkbox', checked: filtersNow.archived, onchange: (event) => setter({ archived: event.target.checked }) }), ` Show archived (${archivedCount})`)
        : null,
    ),
  );
}

function renderRuns({ runs: all, broken }) {
  // Tasks runs have their own view ("Tasks").
  const everyRun = all.filter((r) => r.kind !== 'tasks');
  const clones = new Set(everyRun.map((r) => clone(r.checkout)));
  const cloneFilter = clones.has(runFilters.clone) ? runFilters.clone : null;
  const runs = everyRun.filter((r) => (runFilters.archived || !r.archived) && (!cloneFilter || clone(r.checkout) === cloneFilter) && matchesSearch(runFilters.text, r.title, r.id, r.checkout));
  const hidden = everyRun.length - runs.length;
  const rank = (r) => (r.openQuestions > 0 ? 0 : r.stale ? 1 : r.state === 'active' ? 2 : r.state === 'paused' ? 3 : 4);
  const ordered = [...runs].sort((a, b) => rank(a) - rank(b) || String(b.lastEvent).localeCompare(String(a.lastEvent)));
  // A question waits for the user also when a filter hides its run.
  const waiting = [...everyRun].filter((r) => r.openQuestions > 0);
  const current = ordered.filter((r) => r.state !== 'finished');
  const finished = ordered.filter((r) => r.state === 'finished');

  return h(
    'div',
    null,
    waiting.length
      ? h(
        'section',
        { class: 'attention' },
        h('h2', null, 'Waiting for you'),
        waiting.map((r) =>
          h(
            'a',
            { class: 'attention-item', href: `#/run/${enc(r.id)}` },
            h('strong', null, `${r.openQuestions} question${r.openQuestions === 1 ? '' : 's'}`),
            ` in ${r.title} — clone `,
            h('code', null, clone(r.checkout)),
          ),
        ),
      )
      : null,
    h('h2', null, 'Projects'),
    everyRun.length ? runToolbar(everyRun, runFilters, setRunFilters, (r) => r.checkout, (r) => r.archived) : null,
    hidden ? h('p', { class: 'muted small' }, `${hidden} project${hidden === 1 ? ' is' : 's are'} hidden by the search, the clone filter or the archive.`) : null,
    current.length ? runTable(current) : h('p', { class: 'muted' }, everyRun.length ? 'No active or paused projects here.' : 'No projects in this root yet.'),
    finished.length ? h('details', { class: 'finished', 'data-keep': 'finished-runs' }, h('summary', null, `Finished projects (${finished.length})`), runTable(finished)) : null,
    broken.length
      ? h(
        'section',
        null,
        h('h2', null, `Folders that cannot be read (${broken.length})`),
        h('ul', { class: 'broken-list' }, broken.map((b) => h('li', null, h('code', null, b.id), ': ', b.error))),
      )
      : null,
  );
}

function runTable(runs) {
  return h(
    'table',
    { class: 'runs' },
    h('thead', null, h('tr', null, ['Project', 'State', 'Clone', 'Layers done', 'PRs', 'Questions', 'Last event'].map((t) => h('th', null, t)))),
    h(
      'tbody',
      null,
      runs.map((r) =>
        h(
          'tr',
          { class: r.openQuestions ? 'row-waiting' : r.stale ? 'row-stale' : null },
          h('td', null, h('a', { href: `#/run/${enc(r.id)}` }, r.title), r.archived ? [' ', badge('archived')] : null, h('div', { class: 'muted small' }, r.id)),
          h('td', null, badge(r.state, `state-${r.state}`), ' ', h('span', { class: 'muted small' }, r.stage), r.stale ? [' ', badge('stale', 'stale')] : null),
          h('td', null, h('code', null, clone(r.checkout))),
          h('td', null, `${r.done} / ${r.layers}`),
          h(
            'td',
            { class: 'nowrap' },
            r.prsOpen + r.prsMerged
              ? h(
                'a',
                { href: `#/run/${enc(r.id)}/prs`, title: 'open / merged' },
                r.prsOpen ? badge(`${r.prsOpen} open`, 'next') : h('span', { class: 'muted' }, '0 open'),
                ' ',
                h('span', { class: 'muted' }, `· ${r.prsMerged} merged`),
              )
              : h('span', { class: 'muted' }, '-'),
          ),
          h('td', null, r.openQuestions ? badge(String(r.openQuestions), 'needs') : '0'),
          r.lastEvent ? agoEl('td', { title: time(r.lastEvent) }, r.lastEvent) : h('td', null, '-'),
        ),
      ),
    ),
  );
}

function renderBrokenRun(id, reason) {
  return h(
    'div',
    null,
    h('p', null, h('a', { href: '#/runs' }, '← Projects')),
    h('h1', null, id),
    h('p', { class: 'error' }, `This run folder cannot be read: ${reason}`),
  );
}

// ── Run views: header, board, timeline, follow-ups ───────────────────────────────────────────────

function runHeader(state, tab) {
  const { run } = state;
  const tabs = [
    ['run-board', 'Board', `#/run/${enc(run.id)}`],
    ['timeline', 'Timeline', `#/run/${enc(run.id)}/timeline`],
    ['followups', `Follow-ups (${state.followups.length})`, `#/run/${enc(run.id)}/followups`],
    ['prs', `PRs (${state.layers.filter((l) => l.pr).length})`, `#/run/${enc(run.id)}/prs`],
    ['plans', `Plans (${state.plans.length})`, `#/run/${enc(run.id)}/plans`],
  ];
  return h(
    'div',
    { class: 'run-header' },
    h('p', null, run.kind === 'tasks' ? h('a', { href: '#/tasks' }, '← Tasks') : h('a', { href: '#/runs' }, '← Projects')),
    h(
      'div',
      { class: 'title-row' },
      h('h1', null, run.title),
      sessionControl(state),
      run.state !== 'finished' ? h('button', { type: 'button', class: 'btn', onclick: () => confirmFinish(state) }, 'Mark as finished') : null,
      archiveControl(state),
    ),
    h(
      'div',
      { class: 'meta' },
      badge(run.state, `state-${run.state}`),
      run.archived ? badge('archived') : null,
      badge(`stage: ${run.stage}`),
      state.stale ? sinceEl('span', { class: 'badge stale' }, state.lastEvent, 'stale: no event for ') : null,
      h('span', null, 'clone ', h('code', { title: run.checkout }, clone(run.checkout))),
      h('span', { class: 'muted' }, run.id),
      state.lastEvent ? agoEl('span', { class: 'muted', title: time(state.lastEvent) }, state.lastEvent, 'last event ') : null,
      state.usage?.total?.agents ? h('span', { class: 'muted', title: usageText(state.usage.total) }, `${tokens(state.usage.total.tokens)} tokens`) : null,
    ),
    run.nextStep ? h('p', { class: 'next-step' }, h('strong', null, 'Next step: '), run.nextStep) : null,
    run.ci ? h('p', null, h('strong', null, 'CI: '), `PR #${run.ci.pr} `, badge(run.ci.result, `ci-${run.ci.result}`), run.ci.runUrl ? [' ', extLink(run.ci.runUrl, 'run')] : null) : null,
    h('details', { class: 'request', 'data-keep': `request:${run.id}` }, h('summary', null, 'Request and decisions'), h('pre', null, run.request), run.decisions.length ? h('ul', null, run.decisions.map((d) => h('li', null, d.question, ' → ', h('strong', null, d.answer)))) : null),
    state.errors.length ? h('div', { class: 'warnings' }, h('strong', null, 'Warnings: '), h('ul', null, state.errors.map((e) => h('li', null, e)))) : null,
    h('nav', { class: 'tabs' }, tabs.map(([key, label, href]) => h('a', { href, class: key === tab ? 'active' : null }, label))),
  );
}

const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

/**
 * A confirmation dialog for a change. On "confirm", it POSTs to `url` with the action header, then
 * redraws. The dialog lives outside the view, so a poll cannot close it.
 */
function openConfirm({ title, content, confirmLabel, url, action, getBody = null, confirmClass = 'btn danger' }) {
  let saving = false;
  const error = h('p', { class: 'error', role: 'alert' });
  const cancel = h('button', { type: 'button', class: 'btn', autofocus: true }, 'Cancel');
  const confirm = h('button', { type: 'button', class: confirmClass }, confirmLabel);
  const dialog = h('dialog', { class: 'confirm', 'aria-labelledby': 'confirm-title' }, h('h2', { id: 'confirm-title' }, title), content, error, h('div', { class: 'confirm-buttons' }, cancel, confirm));

  cancel.addEventListener('click', () => dialog.close());
  // Escape closes the dialog, except while the change is saving.
  dialog.addEventListener('cancel', (event) => {
    if (saving) event.preventDefault();
  });
  dialog.addEventListener('close', () => dialog.remove());
  confirm.addEventListener('click', async () => {
    let payload = null;
    if (getBody) {
      // getBody throws when the form is not complete. Nothing is sent then.
      try {
        payload = getBody();
      } catch (failure) {
        error.textContent = failure.message;
        return;
      }
    }
    saving = true;
    confirm.disabled = true;
    cancel.disabled = true;
    confirm.textContent = 'Saving…';
    error.textContent = '';
    try {
      const headers = { 'X-Task-Manager-Admin': action };
      if (payload) headers['Content-Type'] = 'application/json';
      const res = await fetch(url, { method: 'POST', headers, body: payload ? JSON.stringify(payload) : undefined });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(body.error ?? `${res.status} ${res.statusText}`);
      saving = false;
      dialog.close();
      lastSignature = null;
      await refresh({ force: true });
    } catch (failure) {
      saving = false;
      error.textContent = failure.message;
      confirm.disabled = false;
      cancel.disabled = false;
      confirm.textContent = confirmLabel;
    }
  });

  document.body.append(dialog);
  dialog.showModal();
}

/** Archive a finished project, or bring it back. It only hides the project on this page: nothing is deleted. */
function archiveControl(state) {
  const { run } = state;
  if (run.state !== 'finished') return null;
  const next = !run.archived;
  const tasks = run.kind === 'tasks';
  return h(
    'button',
    {
      type: 'button',
      class: 'btn',
      onclick: () =>
        openConfirm({
          title: next ? (tasks ? 'Archive this run, with all its tasks?' : 'Archive this project?') : tasks ? 'Bring this run back?' : 'Bring this project back?',
          confirmLabel: next ? 'Archive' : 'Bring back',
          confirmClass: 'btn',
          url: `/api/runs/${enc(run.id)}/archive`,
          action: 'archive',
          getBody: () => ({ archived: next }),
          content: h('p', null, next ? `The page hides an archived ${tasks ? 'run, with every task of it' : 'project'}. Its run folder stays as it is, and "Show archived" brings it back into the list.` : 'It shows in the lists again.'),
        }),
    },
    next ? (tasks ? 'Archive run' : 'Archive') : 'Bring back',
  );
}

/** Ask before marking a project as finished. */
function confirmFinish(state) {
  const { run } = state;
  const openPrs = state.layers.filter((l) => l.phase === 'pr_open');
  const unfinished = state.layers.filter((l) => l.column === 'todo' || l.column === 'in_progress' || l.column === 'needs_input');
  const recent = run.state === 'active' && !state.stale;
  openConfirm({
    title: 'Mark this project as finished?',
    confirmLabel: 'Mark as finished',
    url: `/api/runs/${enc(run.id)}/finish`,
    action: 'finish',
    content: [
      h('p', null, h('strong', null, run.title), h('br'), h('span', { class: 'muted small' }, `${run.id} · clone ${clone(run.checkout)}`)),
      h(
        'ul',
        { class: 'confirm-facts' },
        h('li', null, `Now: ${run.state}, stage ${run.stage}.`),
        unfinished.length ? h('li', { class: 'warn-text' }, `${plural(unfinished.length, run.kind === 'tasks' ? 'task' : 'layer')} not done: ${unfinished.map((l) => l.id).join(', ')}.`) : null,
        openPrs.length ? h('li', null, `${plural(openPrs.length, 'PR')} still open: ${openPrs.map((l) => `#${l.pr?.number ?? '?'}`).join(', ')}. ${openPrs.length === 1 ? 'It stays' : 'They stay'} open.`) : null,
        state.openQuestions.length ? h('li', { class: 'warn-text' }, `${plural(state.openQuestions.length, 'open question')} will stay unanswered.`) : null,
      ),
      recent
        ? h('p', { class: 'warnings' }, `The last event was ${ago(state.lastEvent)}. A session can still work on this project. Stop that session first, or it can keep writing to the run.`)
        : null,
      h(
        'p',
        { class: 'muted small' },
        'This sets the state to finished through the task-manager helper, run in clone ',
        h('code', null, clone(run.checkout)),
        '. It does not merge, close or delete any PR or branch. To undo it, run the helper with ',
        h('code', null, `run --run ${run.id} --set state=paused`),
        '.',
      ),
    ],
  });
}

function renderRun(state, tab) {
  const body = tab === 'timeline' ? renderTimeline(state) : tab === 'followups' ? renderFollowups(state) : tab === 'prs' ? renderPrs(state) : renderBoard(state);
  return h('div', null, runHeader(state, tab), body);
}

/** The run and clone of a card, on the board across all runs. */
function cardRun(state) {
  const tasks = state.run.kind === 'tasks';
  return h('div', { class: 'card-run', title: state.run.id }, tasks ? badge('Task', 'task') : null, tasks ? ' ' : null, state.run.title, h('span', { class: 'muted' }, ` · ${clone(state.run.checkout)}`));
}

/** The page of one layer: the task page in a tasks run, the layer page in a stack run. */
const layerHref = (state, l) => (state.run.kind === 'tasks' ? `#/task/${enc(state.run.id)}/${enc(l.id)}` : `#/run/${enc(state.run.id)}/layer/${enc(l.id)}`);

/** The CI result of a task, as a badge. Only a tasks run records CI on a layer. */
const ciBadge = (ci) => (ci ? badge(`CI ${ci.result.replace('_', ' ')}`, `ci-${ci.result}`) : null);

/**
 * The answer that the page sends: the option, the comment, or both. The comment is always
 * available, also when the question has options.
 */
function answerText(option, comment) {
  const note = comment.trim();
  if (option && note) return `${option} — ${note}`;
  return option || note;
}

/** Answer an open question from the page. The session reads the answer from the run's ledger. */
function openAnswer(state, q) {
  const name = `answer-${q.id}`;
  // A session-only question is about an action that cannot be undone. It takes an option only,
  // and the user types that option again. With no options, the option is the word "yes".
  const strict = Boolean(q.sessionOnly);
  const options = strict && !(q.options ?? []).length ? ['yes'] : (q.options ?? []);
  const typed = h('input', { type: 'text', class: 'answer-confirm', autocomplete: 'off', spellcheck: 'false' });
  const choice = (value, label) => h('label', { class: 'answer-option' }, h('input', { type: 'radio', name, value }), ' ', label);
  const comment = h('textarea', { class: 'answer-comment', rows: 3, maxlength: 1500, placeholder: options.length ? 'Add a comment (optional with an option)' : 'Write your answer' });
  const form = h(
    'form',
    { class: 'answer-form' },
    h('p', { class: 'q' }, q.question),
    options.length ? h('div', { class: 'answer-options' }, options.map((o) => choice(o, o)), strict ? null : choice('', 'No option: my comment is the answer')) : null,
    strict ? null : h('label', { class: 'answer-option' }, 'Comment', comment),
    strict ? h('p', { class: 'warn-text' }, 'This question is about an action that cannot be undone, or that goes out of this machine. The session does that action when it gets your answer. It takes no comment: to say "not yet" or to add a condition, answer in the session.') : null,
    strict ? h('label', { class: 'answer-option' }, 'To confirm, type the option that you chose, exactly', typed) : null,
    noWatcher(state)
      ? h('p', { class: 'warn-text' }, tellSession(state))
      : h('p', { class: 'muted small' }, 'The session of clone ', h('code', null, clone(state.run.checkout)), ' gets this answer from the run. If the session is closed, it gets the answer when you resume the run.'),
  );
  form.addEventListener('submit', (event) => event.preventDefault());
  openConfirm({
    title: `Answer ${q.id}${q.layer ? ` (${q.layer})` : ''}`,
    content: form,
    confirmLabel: 'Send answer',
    confirmClass: 'btn primary',
    url: `/api/runs/${enc(state.run.id)}/questions/${enc(q.id)}/answer`,
    action: 'answer',
    getBody: () => {
      const chosen = form.querySelector(`input[name="${name}"]:checked`)?.value ?? '';
      if (strict) {
        // The answer is the option and nothing more: a comment could add a condition to the yes.
        if (!chosen) throw new Error('Choose an option.');
        if (typed.value !== chosen) throw new Error(`Type ${JSON.stringify(chosen)} exactly to confirm.`);
        return { answer: chosen, confirm: typed.value };
      }
      const answer = answerText(chosen, comment.value);
      if (!answer) throw new Error('Choose an option or write a comment.');
      return { answer };
    },
  });
}

/** The way to answer an open question: a button, or a note for a question that only the session takes. */
function answerControl(state, q) {
  if (q.answer !== null && q.answer !== undefined) return null;
  if (q.sessionOnly && !settings.confirmOnPage) return h('p', { class: 'muted small' }, 'Answer this question in the session of clone ', h('code', null, clone(state.run.checkout)), '. The page cannot answer it.');
  const button = h('button', { type: 'button', class: 'btn answer' }, q.sessionOnly ? 'Answer with a confirmation' : 'Answer');
  button.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    openAnswer(state, q);
  });
  // An active run with no watcher is the same for an answer as a paused one: no session gets it.
  const alone = noWatcher(state);
  return h('p', { class: 'answer-row' }, button, h('span', { class: alone ? 'warn-text small' : 'muted small' }, alone ? ` ${tellSession(state)}` : ` or answer in the session (run ${state.run.id})`));
}

function questionCard(state, q, showRun = false) {
  return h(
    'div',
    { class: 'card question' },
    showRun ? cardRun(state) : null,
    h('div', { class: 'card-top' }, badge(q.layer ? q.layer : 'run', 'needs'), h('span', { class: 'muted small' }, q.id)),
    h('p', { class: 'q' }, q.question),
    q.options?.length ? h('ul', { class: 'options' }, q.options.map((o) => h('li', null, o))) : null,
    answerControl(state, q),
  );
}

function layerCard(state, l, showRun = false) {
  const parkedQuestion = l.parked ? state.questions.find((q) => q.id === l.parked.question) : null;
  const layerQuestions = state.openQuestions.filter((q) => q.layer === l.id && q.id !== l.parked?.question);
  return h(
    'div',
    { class: `card layer${state.next === l.id ? ' is-next' : ''}` },
    showRun ? cardRun(state) : null,
    h(
      'div',
      { class: 'card-top' },
      state.run.kind === 'tasks' ? (showRun ? null : badge('Task', 'task')) : h('span', { class: 'pos', title: 'position in the stack' }, `#${l.position}`),
      h('strong', null, l.id),
      badge(`tier ${l.tier}`),
      l.outcome !== 'pr' ? badge(OUTCOME_LABEL[l.outcome] ?? l.outcome, 'task') : null,
      l.escalated ? badge('escalated', 'warn') : null,
      state.next === l.id ? badge('next', 'next') : null,
    ),
    // The task link covers the whole card (CSS), so the card stays one click target.
    h('p', { class: 'task' }, h('a', { class: 'card-link', href: layerHref(state, l) }, l.task)),
    h(
      'div',
      { class: 'facts' },
      h('span', null, l.phase.replace('_', ' ')),
      l.round ? h('span', null, `round ${l.round}/3`) : null,
      l.openFindings ? badge(`${l.openFindings} open finding${l.openFindings === 1 ? '' : 's'}`, 'warn') : null,
      l.pr ? h('span', null, `PR #${l.pr.number}`) : null,
      ciBadge(l.ci),
    ),
    l.parked
      ? h(
        'div',
        { class: 'parked' },
        h('strong', null, `Parked at ${l.parked.phase.replace('_', ' ')}, round ${l.parked.round}`),
        parkedQuestion ? h('p', { class: 'q' }, parkedQuestion.question) : null,
        parkedQuestion?.options?.length ? h('ul', { class: 'options' }, parkedQuestion.options.map((o) => h('li', null, o))) : null,
        parkedQuestion?.answer ? h('p', null, 'Answer: ', h('strong', null, parkedQuestion.answer), ' — ready to unpark') : null,
        // An answer from this page that no watcher took, and nothing gives it to a session: the user
        // must do that. An answer that a session has already needs no warning.
        parkedQuestion?.answer && parkedQuestion.via === 'dashboard' && !parkedQuestion.delivered && noWatcher(state) ? h('p', { class: 'warn-text' }, tellSession(state).replace('after your answer', 'now')) : null,
        parkedQuestion ? answerControl(state, parkedQuestion) : null,
        h('p', { class: 'muted small' }, 'Clone ', h('code', null, clone(state.run.checkout))),
      )
      : null,
    layerQuestions.map((q) => h('div', { class: 'parked' }, h('p', { class: 'q' }, q.question), q.options?.length ? h('ul', { class: 'options' }, q.options.map((o) => h('li', null, o))) : null, answerControl(state, q))),
    l.column === 'todo' && l.blockedBy.length ? h('p', { class: 'blocked' }, `Blocked by parked ${l.blockedBy.join(', ')}`) : null,
    l.column === 'todo' && l.waitsFor.length ? h('p', { class: 'waits' }, `Waits for ${l.waitsFor.join(', ')} (no PR yet)`) : null,
  );
}

/**
 * The Done column holds two states: a PR that waits for the user's merge, and a merged layer. The
 * open PRs come first, because they need the user. The merged group starts closed when open PRs
 * exist; the user's choice then holds across redraws (`data-keep`).
 * `items` are `{state, l}`: a layer and the run it belongs to.
 */
function doneGroups(items, keepKey, showRun) {
  // A delivered report is over, like a merged PR: it does not wait for a merge.
  const over = ({ l }) => l.phase === 'merged' || l.phase === 'delivered';
  const open = items.filter((item) => !over(item));
  const merged = items.filter(over);
  const cards = (list) => list.map(({ state, l }) => layerCard(state, l, showRun));
  return [
    open.length ? h('div', { class: 'group' }, h('h4', null, 'PR open, waiting for merge', h('span', { class: 'count' }, String(open.length))), cards(open)) : null,
    merged.length
      ? h(
        'details',
        { class: 'group', open: open.length === 0, 'data-keep': `merged:${keepKey}` },
        h('summary', null, h('h4', null, 'Merged or delivered', h('span', { class: 'count' }, String(merged.length)))),
        cards(merged),
      )
      : null,
  ];
}

/**
 * The columns of a board. `entries` are run states (`run`, `layers`, `questions`, `openQuestions`,
 * `next`); `columns` are the column keys to show.
 */
function boardColumns(entries, columns, keepKey, showRun) {
  const shown = COLUMNS.filter(([key]) => columns.includes(key));
  return h(
    'div',
    { class: `board cols-${shown.length}` },
    shown.map(([key, label]) => {
      const items = entries.flatMap((state) => state.layers.filter((l) => l.column === key).map((l) => ({ state, l })));
      const questions = key === 'needs_input' ? entries.flatMap((state) => state.openQuestions.filter((q) => !q.layer).map((q) => questionCard(state, q, showRun))) : [];
      const count = items.length + questions.length;
      return h(
        'section',
        { class: `column col-${key}` },
        h('h3', null, label, h('span', { class: 'count' }, String(count))),
        !count
          ? h('p', { class: 'muted small empty' }, 'Nothing here.')
          : key === 'done'
            ? doneGroups(items, keepKey, showRun)
            : [...questions, ...items.map(({ state, l }) => layerCard(state, l, showRun))],
      );
    }),
  );
}

function renderBoard(state) {
  return boardColumns([state], COLUMNS.map(([key]) => key), state.run.id, false);
}

// ── Board across all runs, with filters ─────────────────────────────────────────────────────────

const FILTER_KEY = 'task-manager-admin:filters';
const ALL_COLUMNS = COLUMNS.map(([key]) => key);

/**
 * The board filters, kept in this browser. `runs` is null for every run, or a list of run ids.
 * `columns` lists the columns to show. `finished` shows the finished runs too.
 */
function loadFilters() {
  try {
    const saved = JSON.parse(localStorage.getItem(FILTER_KEY) ?? 'null');
    if (saved && typeof saved === 'object') {
      const columns = Array.isArray(saved.columns) ? saved.columns.filter((c) => ALL_COLUMNS.includes(c)) : [];
      return { runs: Array.isArray(saved.runs) ? saved.runs : null, columns: columns.length ? columns : ALL_COLUMNS, finished: saved.finished === true };
    }
  } catch {
    // No storage in this browser: the filters last until the page closes.
  }
  return { runs: null, columns: ALL_COLUMNS, finished: false };
}

let filters = loadFilters();

function setFilters(change) {
  filters = { ...filters, ...change };
  try {
    localStorage.setItem(FILTER_KEY, JSON.stringify(filters));
  } catch {
    // See loadFilters.
  }
  redraw();
}

/** A toggle button for the filter bar. */
function chip(label, pressed, onclick, extra = null, kind = '') {
  return h('button', { type: 'button', class: `chip ${kind}`, 'aria-pressed': pressed ? 'true' : 'false', onclick }, label, extra);
}

/** Click a project: from "all", show only that project; then add or remove projects. None left means all. */
function toggleRun(id, visibleIds) {
  const current = filters.runs ? filters.runs.filter((r) => visibleIds.includes(r)) : null;
  if (!current || current.length === 0) return setFilters({ runs: [id] });
  const next = current.includes(id) ? current.filter((r) => r !== id) : [...current, id];
  setFilters({ runs: next.length ? next : null });
}

function toggleColumn(key) {
  const next = filters.columns.includes(key) ? filters.columns.filter((c) => c !== key) : ALL_COLUMNS.filter((c) => c === key || filters.columns.includes(c));
  // At least one column stays on.
  if (next.length) setFilters({ columns: next });
}

function renderGeneralBoard({ runs, broken }) {
  const rank = { active: 0, paused: 1, finished: 2 };
  const ordered = [...runs].sort((a, b) => (rank[a.run.state] ?? 3) - (rank[b.run.state] ?? 3) || String(b.lastEvent).localeCompare(String(a.lastEvent)));
  // An archived run is out of the board: the Projects view and the Tasks view bring it back.
  const visible = ordered.filter((e) => !e.run.archived && (filters.finished || e.run.state !== 'finished'));
  const visibleIds = visible.map((e) => e.run.id);
  const picked = filters.runs ? filters.runs.filter((id) => visibleIds.includes(id)) : [];
  const selected = picked.length ? visible.filter((e) => picked.includes(e.run.id)) : visible;
  const all = picked.length === 0;
  const shownOnBoard = runs.filter((e) => !e.run.archived);
  const finishedCount = shownOnBoard.filter((e) => e.run.state === 'finished').length;
  const archivedOnBoard = runs.length - shownOnBoard.length;
  const columnCount = (key) => selected.reduce((n, e) => n + e.layers.filter((l) => l.column === key).length + (key === 'needs_input' ? e.openQuestions.filter((q) => !q.layer).length : 0), 0);

  const toolbar = h(
    'div',
    { class: 'filters' },
    h(
      'div',
      { class: 'filter-row' },
      h('span', { class: 'filter-label' }, 'Projects'),
      chip('All', all, () => setFilters({ runs: null })),
      visible.map((e) => {
        const waiting = e.openQuestions.length;
        return chip(
          e.run.kind === 'tasks' ? `Tasks · ${e.run.title}` : e.run.title,
          !all && picked.includes(e.run.id),
          () => toggleRun(e.run.id, visibleIds),
          [h('span', { class: 'chip-sub' }, clone(e.run.checkout)), waiting ? h('span', { class: 'chip-count needs' }, String(waiting)) : null, e.stale ? h('span', { class: 'chip-count stale' }, 'stale') : null],
          `state-${e.run.state}`,
        );
      }),
    ),
    h(
      'div',
      { class: 'filter-row' },
      h('span', { class: 'filter-label' }, 'Columns'),
      COLUMNS.map(([key, label]) => chip(label, filters.columns.includes(key), () => toggleColumn(key), h('span', { class: 'chip-count' }, String(columnCount(key))), `col-chip-${key}`)),
      h(
        'label',
        { class: 'switch' },
        h('input', { type: 'checkbox', checked: filters.finished, onchange: (event) => setFilters({ finished: event.target.checked }) }),
        ` Show finished projects (${finishedCount})`,
      ),
    ),
  );

  const only = selected.length === 1 && !all ? selected[0] : null;
  return h(
    'div',
    null,
    toolbar,
    only
      ? h(
        'p',
        { class: 'project-link' },
        h('a', { href: `#/run/${enc(only.run.id)}` }, `Open ${only.run.title} →`),
        only.run.nextStep ? h('span', { class: 'muted' }, ` Next step: ${only.run.nextStep}`) : null,
      )
      : null,
    !visible.length
      ? h('p', { class: 'muted' }, runs.length ? (finishedCount && !filters.finished ? 'No active or paused projects. Turn on "Show finished projects" to see the others.' : `Nothing to show here.${archivedOnBoard ? ` ${archivedOnBoard} archived project${archivedOnBoard === 1 ? ' is' : 's are'} in the Projects view and the Tasks view, under "Show archived".` : ''}`) : 'No projects in this root yet.')
      : boardColumns(selected, filters.columns, 'board', true),
    broken.length ? h('p', { class: 'muted small' }, `${broken.length} folder${broken.length === 1 ? '' : 's'} cannot be read. See `, h('a', { href: '#/runs' }, 'Projects'), '.') : null,
  );
}

function eventRow(e) {
  return h(
    'tr',
    null,
    h('td', { class: 'nowrap', title: e.ts }, time(e.ts)),
    h('td', null, e.layer ?? 'run'),
    h('td', null, h('code', null, e.type)),
    h('td', null, e.round ?? ''),
    h('td', null, e.summary, e.refs?.url ? [' ', extLink(e.refs.url, 'link')] : null, e.refs?.sha ? [' ', h('code', { class: 'small' }, String(e.refs.sha).slice(0, 10))] : null),
  );
}

function eventTable(events) {
  if (!events.length) return h('p', { class: 'muted' }, 'No events.');
  return h(
    'table',
    { class: 'events' },
    h('thead', null, h('tr', null, ['Time', 'Layer', 'Type', 'Round', 'Summary'].map((t) => h('th', null, t)))),
    h('tbody', null, [...events].reverse().map(eventRow)),
  );
}

function phaseTable(state) {
  const rows = state.layers.filter((l) => state.phaseTimes[l.id]);
  if (!rows.length) return h('p', { class: 'muted' }, 'No phase times yet. They start when a layer leaves "queued".');
  const used = PHASES.filter((p) => rows.some((l) => state.phaseTimes[l.id][p] !== undefined));
  return h(
    'table',
    { class: 'phases' },
    h('thead', null, h('tr', null, h('th', null, 'Layer'), used.map((p) => h('th', null, p.replace('_', ' '))))),
    h(
      'tbody',
      null,
      rows.map((l) =>
        h(
          'tr',
          null,
          h('td', null, h('a', { href: layerHref(state, l) }, l.id), h('span', { class: 'muted small' }, ` ${l.task}`)),
          used.map((p) => {
            const ms = state.phaseTimes[l.id][p];
            if (ms === undefined) return h('td', null, '');
            const open = p === l.phase && p !== 'merged' && p !== 'delivered' && state.run.state === 'active';
            return h('td', { class: p === l.phase ? 'current' : null, 'data-ms': open ? ms : null, 'data-at': open ? fetchedAt : null }, duration(ms));
          }),
        ),
      ),
    ),
  );
}

function renderTimeline(state) {
  return h('div', null, h('h2', null, 'Time in each phase'), phaseTable(state), h('h2', null, 'Usage of the agents'), usageTable(state), h('h2', null, `Events (${state.events.length}, newest first)`), eventTable(state.events));
}

/** The issue URL of a filed follow-up, from the repository of a PR link in the run. */
function issueLink(state, number) {
  const prUrl = state.layers.map((l) => l.pr?.url).find(Boolean);
  const repo = prUrl ? /^(https:\/\/github\.com\/[^/]+\/[^/]+)\//.exec(prUrl)?.[1] : null;
  return repo ? extLink(`${repo}/issues/${number}`, `#${number}`) : h('span', null, `#${number}`);
}

function renderFollowups(state) {
  const ordered = [...state.followups.filter((f) => f.dataLoss), ...state.followups.filter((f) => !f.dataLoss)];
  if (!ordered.length) return h('p', { class: 'muted' }, 'No follow-ups in this run.');
  return h(
    'ul',
    { class: 'followups' },
    ordered.map((f) =>
      h(
        'li',
        { class: f.dataLoss ? 'data-loss' : null },
        h(
          'div',
          { class: 'card-top' },
          f.dataLoss ? badge('data loss', 'danger') : null,
          badge(f.layer ?? 'run'),
          h('strong', null, f.title),
          h('span', { class: 'right' }, f.issue ? ['filed as ', issueLink(state, f.issue)] : badge('not filed', 'warn')),
        ),
        h('p', null, f.body),
      ),
    ),
  );
}

// ── Layer detail ─────────────────────────────────────────────────────────────────────────────────

function renderLayer(state, layerId) {
  const l = state.layers.find((x) => x.id === layerId);
  const back = h('p', null, h('a', { href: `#/run/${enc(state.run.id)}` }, `← ${state.run.title}`));
  if (!l) return h('div', null, back, h('p', { class: 'error' }, `No layer ${layerId} in this run.`));
  return h('div', null, back, h('h1', null, `${l.id}: ${l.task}`), layerDetail(state, l));
}

/** The fields, questions, findings and events of one layer: the layer page, and the task page's Overview. */
function layerDetail(state, l) {
  const findings = state.findings[l.id] ?? [];
  const questions = state.questions.filter((q) => q.layer === l.id);
  const field = (label, value) => h('div', null, h('dt', null, label), h('dd', null, value ?? '-'));
  const sha = (value) => (value ? h('code', { title: value }, value.slice(0, 10)) : '-');

  const tasks = state.run.kind === 'tasks';
  const planHref = (name) => (tasks ? `#/task/${enc(state.run.id)}/${enc(l.id)}/plan/${enc(name)}` : `#/run/${enc(state.run.id)}/plans/${enc(name)}`);
  return h(
    'div',
    null,
    h(
      'div',
      { class: 'meta' },
      badge(l.column.replace('_', ' '), `col-badge-${l.column}`),
      badge(l.phase.replace('_', ' ')),
      l.round ? badge(`round ${l.round}/3`) : null,
      badge(`tier ${l.tier}`),
      l.outcome !== 'pr' ? badge(OUTCOME_LABEL[l.outcome] ?? l.outcome, 'task') : null,
      l.escalated ? badge('escalated', 'warn') : null,
      state.next === l.id ? badge('next', 'next') : null,
      l.pr ? (l.pr.url ? extLink(l.pr.url, `PR #${l.pr.number}`) : h('span', null, `PR #${l.pr.number}`)) : null,
      ciBadge(l.ci),
    ),
    h(
      'dl',
      { class: 'fields' },
      // A task has no stack: no position, no dependencies.
      tasks ? null : field('Position', String(l.position)),
      field('Source', l.source),
      tasks ? null : field('Depends on', l.dependsOn.join(', ') || '-'),
      tasks ? null : field('Blocked by (parked)', l.blockedBy.join(', ') || '-'),
      tasks ? null : field('Waits for (no PR)', l.waitsFor.join(', ') || '-'),
      field('Branch', l.branch ? h('code', null, l.branch) : '-'),
      field('Base', l.base ? [h('code', null, l.base), ' @ ', sha(l.baseTip)] : '-'),
      field('Head', sha(l.head)),
      field('Last reviewed', sha(l.lastReviewed)),
      field('Implementer', l.implementer),
      field('Reviewer', l.reviewer),
      field('Tier reason', l.tierReason),
      // Runs from before the skill's `plan` field have no link from a layer to its plan.
      field('Plan', l.plan ? h('a', { href: planHref(l.plan.replace(/^plans\//, '')) }, l.plan.replace(/^plans\//, '')) : '-'),
      field('Usage', usageText(state.usage?.layers?.[l.id])),
      // Text from a run is never a link: it shows as text.
      l.outcome === 'issue' || l.outcome === 'comment' ? field('Delivery', l.delivery ?? (l.phase === 'delivered' ? '-' : 'nothing went out yet: it needs your yes')) : null,
      field('Outcome', l.outcome !== 'pr' ? (l.report && state.plans.includes(l.report.replace(/^reports\//, '')) ? h('a', { href: planHref(l.report.replace(/^reports\//, '')) }, l.report.replace(/^reports\//, '')) : `${OUTCOME_LABEL[l.outcome] ?? l.outcome}, not delivered yet`) : 'pull request'),
    ),
    l.parked ? h('div', { class: 'parked' }, h('strong', null, `Parked at ${l.parked.phase}, round ${l.parked.round}, on ${l.parked.question}`)) : null,
    questions.length
      ? [h('h2', null, 'Questions'), h('ul', { class: 'questions' }, questions.map((q) => h('li', null, h('span', { class: 'muted small' }, `${q.id} `), q.question, ' → ', q.answer ? [h('strong', null, q.answer), q.via === 'dashboard' ? h('span', { class: 'muted small' }, ' (from this page)') : null] : [badge('no answer yet', 'needs'), answerControl(state, q)])))]
      : null,
    h('h2', null, `Findings (${findings.length})`),
    findings.length
      ? h(
        'table',
        { class: 'findings' },
        h('thead', null, h('tr', null, ['Id', 'Round', 'Severity', 'Where', 'Defect', 'Ruling', 'State'].map((t) => h('th', null, t)))),
        h(
          'tbody',
          null,
          findings.map((f) =>
            h(
              'tr',
              { class: f.state === 'open' || f.state === 'not_fixed' ? 'row-open' : null },
              h('td', null, f.id),
              h('td', null, String(f.round)),
              h('td', null, badge(f.severity, `sev-${f.severity}`)),
              h('td', null, h('code', { class: 'small' }, `${f.file}${f.line ? `:${f.line}` : ''}`)),
              h('td', null, f.defect, f.expectedFix ? h('div', { class: 'muted small' }, 'Expected: ', f.expectedFix) : null),
              h('td', null, f.ruling ?? '-', f.reason ? h('div', { class: 'muted small' }, f.reason) : null),
              h('td', null, badge(f.state, `fs-${f.state}`), f.fixSha ? h('div', null, sha(f.fixSha)) : null),
            ),
          ),
        ),
      )
      : h('p', { class: 'muted' }, 'No findings.'),
    h('h2', null, 'Events'),
    eventTable(state.events.filter((e) => e.layer === l.id)),
  );
}

// ── Plans ────────────────────────────────────────────────────────────────────────────────────────

/**
 * The plan files of the run, and the text of the selected one. The main plans (copies of the
 * user's plan documents) come first, with their source. `hrefFor(name)` links a plan; `plans`
 * limits the list, for the Plan tab of a task.
 */
async function renderPlans(state, selected, { hrefFor = (p) => `#/run/${enc(state.run.id)}/plans/${enc(p)}`, plans = state.plans } = {}) {
  if (!plans.length) return h('p', { class: 'muted' }, 'No plan files here.');
  const name = selected && plans.includes(selected) ? selected : null;
  const plan = name ? await getPlan(state.run.id, name) : null;
  const sourceOf = (p) => state.run.mainPlans?.find((m) => m.path === `plans/${p}`)?.source;
  const item = (p) => {
    const main = p.startsWith('main-');
    const source = main ? sourceOf(p) : null;
    return h(
      'li',
      null,
      h('a', { href: hrefFor(p), class: p === name ? 'active' : null, title: source ?? null }, main ? [badge('Main plan', 'next'), ' '] : p.startsWith('report-') ? [badge('Report', 'task'), ' '] : null, p.replace(/^(plan|main|report)-|\.md$/g, '')),
      source ? h('div', { class: 'muted small' }, source) : null,
    );
  };
  return h(
    'div',
    { class: 'plans' },
    h('ul', { class: 'plan-list' }, plans.map(item)),
    h('div', null, !name ? h('p', { class: 'muted' }, 'Select a plan.') : plan.error ? h('p', { class: 'error' }, plan.error) : h('pre', { class: 'plan', 'data-keep': `plan:${name}` }, plan.text ?? '')),
  );
}

// ── PRs ──────────────────────────────────────────────────────────────────────────────────────────

const GH_TTL_MS = 60_000;
const GH_PARALLEL = 3;
/** GitHub answers by `<run>/<layer>/<pr>`: `{loading}` or `{at, value}`. Kept across redraws. */
const ghCache = new Map();

const ghKey = (runId, l) => `${runId}/${l.id}/${l.pr.number}`;

/** The text and style of a GitHub cell, from the cache. */
function ghView(entry) {
  if (!entry) return ['-', 'muted'];
  if (entry.loading) return ['Checking…', 'muted'];
  const pr = entry.value;
  if (pr.error) return [`Cannot check: ${pr.error}`, 'warn-text'];
  if (pr.state === 'MERGED') {
    const when = pr.mergedAt ? ` ${ago(pr.mergedAt)}` : '';
    if (pr.recorded) return [`merged${when} · recorded`, 'ok-text'];
    if (pr.waitsForSession) return [`merged${when} · the session records it`, 'ok-text'];
    if (pr.recordError) return [`merged${when} · cannot record: ${pr.recordError}`, 'warn-text'];
    return [`merged${when}`, 'ok-text'];
  }
  return [String(pr.state).toLowerCase(), pr.state === 'OPEN' ? '' : 'warn-text'];
}

function ghCell(key) {
  const [text, kind] = ghView(ghCache.get(key));
  return h('td', { 'data-gh': key, class: kind }, text);
}

/** Write a new GitHub answer into its cells, in place. No redraw. */
function paintGh(key) {
  const [text, kind] = ghView(ghCache.get(key));
  for (const cell of view.querySelectorAll('[data-gh]')) {
    if (cell.dataset.gh !== key) continue;
    cell.textContent = text;
    cell.className = kind;
  }
}

/** Ask GitHub about the open PRs of a run whose answer is missing or older than GH_TTL_MS. */
async function loadGithub(state, { force = false } = {}) {
  const queue = state.layers
    .filter((l) => l.pr && l.phase === 'pr_open')
    .map((l) => ({ l, key: ghKey(state.run.id, l) }))
    .filter(({ key }) => {
      const entry = ghCache.get(key);
      return force ? !entry?.loading : !entry || (!entry.loading && Date.now() - entry.at > GH_TTL_MS);
    });
  for (const { key } of queue) {
    ghCache.set(key, { loading: true });
    paintGh(key);
  }
  const worker = async () => {
    for (let item = queue.shift(); item; item = queue.shift()) {
      const { l, key } = item;
      let value;
      try {
        const res = await fetch(`/api/runs/${enc(state.run.id)}/layers/${enc(l.id)}/pr`, { cache: 'no-store' });
        value = await res.json();
      } catch (failure) {
        value = { error: failure.message };
      }
      ghCache.set(key, { at: Date.now(), value });
      paintGh(key);
      if (value.recorded) recorded = true;
    }
  };
  let recorded = false;
  await Promise.all(Array.from({ length: GH_PARALLEL }, worker));
  // The server recorded a merge: redraw, so the row moves to the merged group.
  if (recorded) {
    lastSignature = null;
    await refresh({ force: true });
  }
}

function renderPrs(state) {
  const withPr = state.layers.filter((l) => l.pr);
  const open = withPr.filter((l) => l.phase === 'pr_open');
  const others = withPr.filter((l) => l.phase !== 'pr_open');
  const noPr = state.layers.length - withPr.length;
  // The cells exist once the view shows this table; then ask GitHub for what is missing.
  setTimeout(() => loadGithub(state), 0);
  if (!withPr.length) return h('p', { class: 'muted' }, 'No layer of this project has a PR yet.');

  const row = (l) => {
    const pr = l.pr.url ? extLink(l.pr.url, `#${l.pr.number}`) : h('span', null, `#${l.pr.number}`);
    return h(
      'tr',
      { class: l.phase === 'pr_open' ? null : 'row-merged' },
      h('td', { class: 'muted' }, String(l.position)),
      h('td', null, h('a', { href: layerHref(state, l) }, l.id)),
      h('td', null, l.task),
      h('td', { class: 'nowrap' }, pr),
      h('td', null, badge(l.phase.replace('_', ' '), l.phase === 'merged' ? 'fs-fixed' : null)),
      l.phase === 'pr_open' ? ghCell(ghKey(state.run.id, l)) : h('td', { class: 'muted' }, '-'),
    );
  };

  return h(
    'div',
    null,
    h(
      'div',
      { class: 'prs-bar' },
      h('span', null, `${plural(open.length, 'PR')} open, ${others.length} merged`, noPr ? h('span', { class: 'muted' }, ` · ${plural(noPr, 'layer')} with no PR yet`) : null),
      open.length ? h('button', { type: 'button', class: 'btn small', onclick: () => loadGithub(state, { force: true }) }, 'Check GitHub again') : null,
    ),
    h(
      'table',
      { class: 'prs' },
      h('thead', null, h('tr', null, ['#', 'Layer', 'Task', 'PR', 'Run phase', 'GitHub'].map((t) => h('th', null, t)))),
      h('tbody', null, [...open, ...others].map(row)),
    ),
    h(
      'p',
      { class: 'muted small' },
      'GitHub states come from `gh pr view` in the clone, only for open PRs, and are kept for 1 minute. When GitHub says a PR is merged, the server records the merge through the task-manager helper. It does this for paused, finished and stale projects. In an active project, the session records merges, because a merge also starts its restack of the PRs above. The server also checks every minute, with no page open.',
    ),
  );
}

// ── Tasks: every task of every tasks run ─────────────────────────────────────────────────────────

const TASK_FILTER_KEY = 'task-manager-admin:task-filters';

/** The Tasks filters, kept in this browser: `finished` shows finished runs; `clone` is null for all. */
function loadTaskFilters() {
  try {
    const saved = JSON.parse(localStorage.getItem(TASK_FILTER_KEY) ?? 'null');
    if (saved && typeof saved === 'object') return { finished: saved.finished === true, clone: typeof saved.clone === 'string' ? saved.clone : null, archived: saved.archived === true, text: typeof saved.text === 'string' ? saved.text : '' };
  } catch {
    // No storage in this browser: the filters last until the page closes.
  }
  return { finished: false, clone: null, archived: false, text: '' };
}

let taskFilters = loadTaskFilters();

function setTaskFilters(change) {
  taskFilters = { ...taskFilters, ...change };
  try {
    localStorage.setItem(TASK_FILTER_KEY, JSON.stringify(taskFilters));
  } catch {
    // See loadTaskFilters.
  }
  redraw();
}

/** The order of the Tasks rows: what waits for the user first, then work, then what is done. */
const TASK_RANK = { needs_input: 0, in_progress: 1, todo: 2, done: 3 };
const taskRank = (l) => TASK_RANK[l.column] * 2 + (l.phase === 'merged' || l.phase === 'delivered' ? 1 : 0);

function renderTasks({ runs, broken }) {
  const everyTasksRun = runs.filter((e) => e.run.kind === 'tasks');
  const archivedCount = everyTasksRun.filter((e) => e.run.archived).length;
  const tasksRuns = everyTasksRun.filter((e) => taskFilters.archived || !e.run.archived);
  const shownRuns = tasksRuns.filter((e) => taskFilters.finished || e.run.state !== 'finished');
  const clones = [...new Set(shownRuns.map((e) => clone(e.run.checkout)))].sort();
  const cloneFilter = clones.includes(taskFilters.clone) ? taskFilters.clone : null;
  const selected = shownRuns.filter((e) => !cloneFilter || clone(e.run.checkout) === cloneFilter);
  const rows = selected
    .flatMap((state) => state.layers.map((l) => ({ state, l })))
    .filter(({ state, l }) => matchesSearch(taskFilters.text ?? '', l.task, l.id, state.run.title, state.run.id, state.run.checkout))
    .sort((a, b) => taskRank(a.l) - taskRank(b.l) || String(b.l.lastEvent ?? b.state.lastEvent).localeCompare(String(a.l.lastEvent ?? a.state.lastEvent)));
  // A question waits for the user also when a filter hides its run.
  const runQuestions = everyTasksRun.flatMap((state) => state.openQuestions.filter((q) => !q.layer).map((q) => ({ state, q })));
  const finishedCount = tasksRuns.length - tasksRuns.filter((e) => e.run.state !== 'finished').length;

  const toolbar = h(
    'div',
    { class: 'filters' },
    h(
      'div',
      { class: 'filter-row' },
      h('span', { class: 'filter-label' }, 'Clone'),
      chip('All', !cloneFilter, () => setTaskFilters({ clone: null })),
      clones.map((c) => chip(c, cloneFilter === c, () => setTaskFilters({ clone: c }))),
      h(
        'label',
        { class: 'switch' },
        h('input', { type: 'checkbox', checked: taskFilters.finished, onchange: (event) => setTaskFilters({ finished: event.target.checked }) }),
        ` Show finished runs (${finishedCount})`,
      ),
      archivedCount || taskFilters.archived
        ? h('label', { class: 'switch' }, h('input', { type: 'checkbox', checked: taskFilters.archived, onchange: (event) => setTaskFilters({ archived: event.target.checked }) }), ` Show archived (${archivedCount})`)
        : null,
      h('input', { type: 'search', id: 'task-search', class: 'run-search', placeholder: 'Search by task, run or clone', value: taskFilters.text ?? '', 'aria-label': 'Search', ...searchHandlers((text) => setTaskFilters({ text })) }),
    ),
  );

  const row = ({ state, l }) => {
    const question = l.parked ? state.questions.find((q) => q.id === l.parked.question) : state.openQuestions.find((q) => q.layer === l.id);
    return h(
      'tr',
      { class: l.column === 'needs_input' ? 'row-waiting' : l.phase === 'merged' || l.phase === 'delivered' ? 'row-merged' : null },
      h('td', null, badge(l.column.replace('_', ' '), `col-badge-${l.column}`)),
      h('td', null, h('a', { href: layerHref(state, l) }, l.task), h('div', { class: 'muted small' }, `${l.id} · `, h('a', { href: `#/run/${enc(state.run.id)}`, title: state.run.id }, state.run.title))),
      h('td', null, h('code', { title: state.run.checkout }, clone(state.run.checkout))),
      h('td', null, l.tier, l.escalated ? [' ', badge('escalated', 'warn')] : null),
      h('td', null, l.phase.replace('_', ' '), question ? h('div', { class: 'small warn-text' }, question.question) : null),
      h('td', { class: 'nowrap' }, l.round ? `${l.round}/3` : '-'),
      h('td', { class: 'nowrap', title: l.delivery ?? null }, l.outcome !== 'pr' ? (l.report && state.plans.includes(l.report.replace(/^reports\//, '')) ? h('a', { href: `${layerHref(state, l)}/plan/${enc(l.report.replace(/^reports\//, ''))}` }, OUTCOME_WORD[l.outcome] ?? l.outcome) : (OUTCOME_WORD[l.outcome] ?? l.outcome)) : l.pr ? (l.pr.url ? extLink(l.pr.url, `#${l.pr.number}`) : `#${l.pr.number}`) : '-'),
      h('td', { class: 'nowrap', title: usageText(state.usage?.layers?.[l.id]) }, tokens(state.usage?.layers?.[l.id]?.tokens)),
      h('td', { class: 'nowrap' }, l.ci ? (l.ci.runUrl ? [ciBadge(l.ci), ' ', extLink(l.ci.runUrl, 'run')] : ciBadge(l.ci)) : '-'),
      l.lastEvent ? agoEl('td', { title: time(l.lastEvent), class: 'nowrap' }, l.lastEvent) : h('td', null, '-'),
    );
  };

  return h(
    'div',
    null,
    h('h2', null, 'Tasks'),
    toolbar,
    runQuestions.length
      ? h('section', { class: 'attention' }, h('h2', null, 'Waiting for you'), runQuestions.map(({ state, q }) => questionCard(state, q, true)))
      : null,
    rows.length
      ? h(
        'div',
        { class: 'table-scroll', 'data-keep': 'tasks-table' },
        h(
          'table',
          { class: 'runs tasks' },
          h('thead', null, h('tr', null, ['State', 'Task', 'Clone', 'Tier', 'Phase', 'Round', 'Outcome', 'Tokens', 'CI', 'Updated'].map((t) => h('th', null, t)))),
          h('tbody', null, rows.map(row)),
        ),
      )
      : h('p', { class: 'muted' }, everyTasksRun.length ? 'No task here. Change the search or the clone, or turn on "Show finished runs" or "Show archived".' : 'No tasks runs in this root yet. The task-manager skill makes them.'),
    broken.length ? h('p', { class: 'muted small' }, `${broken.length} folder${broken.length === 1 ? '' : 's'} cannot be read. See `, h('a', { href: '#/runs' }, 'Projects'), '.') : null,
  );
}

// ── Task page: one task of a tasks run ───────────────────────────────────────────────────────────

/** The run state with only one layer, its events and its follow-ups, for the views of one task. */
function scopeToLayer(state, l) {
  return {
    ...state,
    layers: [l],
    events: state.events.filter((e) => e.layer === l.id),
    followups: state.followups.filter((f) => f.layer === l.id),
    phaseTimes: state.phaseTimes[l.id] ? { [l.id]: state.phaseTimes[l.id] } : {},
    // The tier means and the run-level records are about the run, not about this task.
    usage: state.usage ? { ...state.usage, tiers: {}, runLevel: {} } : state.usage,
  };
}

function renderCi(state, l) {
  const events = state.events.filter((e) => e.type === 'ci_started' || e.type === 'ci_result');
  return h(
    'div',
    null,
    l.ci
      ? h('p', null, h('strong', null, 'CI: '), ciBadge(l.ci), l.ci.runUrl ? [' ', extLink(l.ci.runUrl, 'the run on GitHub')] : null)
      : h('p', { class: 'muted' }, l.pr ? 'No CI run is recorded for this PR yet.' : 'CI starts when the PR opens.'),
    h('h2', null, 'CI events'),
    eventTable(events),
  );
}

async function renderTask(state, route) {
  const back = h('p', null, h('a', { href: '#/tasks' }, '← Tasks'));
  const l = state.layers.find((x) => x.id === route.layer);
  if (!l) return h('div', null, back, h('p', { class: 'error' }, `No task ${route.layer} in run ${state.run.id}.`));
  const { run } = state;
  const scoped = scopeToLayer(state, l);
  const base = `#/task/${enc(run.id)}/${enc(l.id)}`;
  const ownPlan = l.plan ? l.plan.replace(/^plans\//, '') : null;
  const ownReport = l.report ? l.report.replace(/^reports\//, '') : null;
  const plans = state.plans.filter((p) => p.startsWith('main-') || p === ownPlan || p === ownReport);
  const tabs = [
    ['overview', 'Overview', base],
    ['timeline', 'Timeline', `${base}/timeline`],
    ['plan', `Plan (${plans.length})`, `${base}/plan`],
    ['pr', 'PR', `${base}/pr`],
    ['ci', 'CI', `${base}/ci`],
  ];
  const tab = tabs.some(([key]) => key === route.tab) ? route.tab : 'overview';
  const header = h(
    'div',
    { class: 'run-header' },
    back,
    h(
      'div',
      { class: 'title-row' },
      h('h1', null, `${l.id}: ${l.task}`),
      sessionControl(state),
      run.state !== 'finished' ? h('button', { type: 'button', class: 'btn', onclick: () => confirmFinish(state), title: 'Marks the whole tasks run as finished' }, 'Mark run as finished') : null,
      archiveControl(state),
    ),
    h(
      'div',
      { class: 'meta' },
      badge('Task', 'task'),
      h('span', null, 'run ', h('a', { href: `#/run/${enc(run.id)}`, title: run.id }, run.title)),
      badge(run.state, `state-${run.state}`),
      h('span', null, 'clone ', h('code', { title: run.checkout }, clone(run.checkout))),
      l.lastEvent ? agoEl('span', { class: 'muted', title: time(l.lastEvent) }, l.lastEvent, 'last event ') : null,
    ),
    run.nextStep ? h('p', { class: 'next-step' }, h('strong', null, 'Next step of the run: '), run.nextStep) : null,
    h('details', { class: 'request', 'data-keep': `request:${run.id}` }, h('summary', null, 'Request and decisions'), h('pre', null, run.request), run.decisions.length ? h('ul', null, run.decisions.map((d) => h('li', null, d.question, ' → ', h('strong', null, d.answer)))) : null),
    state.errors.length ? h('div', { class: 'warnings' }, h('strong', null, 'Warnings: '), h('ul', null, state.errors.map((e) => h('li', null, e)))) : null,
    h('nav', { class: 'tabs' }, tabs.map(([key, label, href]) => h('a', { href, class: key === tab ? 'active' : null }, label))),
  );
  let body;
  if (tab === 'timeline') body = h('div', null, h('h2', null, 'Time in each phase'), phaseTable(scoped), h('h2', null, 'Usage of the agents'), usageTable(scoped),h('h2', null, `Events (${scoped.events.length}, newest first)`), eventTable(scoped.events));
  else if (tab === 'plan') body = await renderPlans(state, route.plan, { hrefFor: (p) => `${base}/plan/${enc(p)}`, plans });
  else if (tab === 'pr') body = renderPrs(scoped);
  else if (tab === 'ci') body = renderCi(scoped, l);
  else body = h('div', null, layerDetail(state, l), h('h2', null, `Follow-ups (${scoped.followups.length})`), renderFollowups(scoped));
  return h('div', null, header, body);
}
