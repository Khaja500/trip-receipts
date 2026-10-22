'use strict';

/* Trip Receipts, on the web.
   Reads transactions.json, which the iPhone app rewrites in a private GitHub
   repo after every change, and shows it. Read-only: the phone is the only
   writer. Everything runs in this browser; the token is sent to
   api.github.com and nowhere else. */

const API = 'https://api.github.com';
const DATA_PATH = 'transactions.json';
const CONNECTION_KEY = 'tripReceipts.connection';
const TAB_KEY = 'tripReceipts.tab';
const POLL_MS = 30_000;
const NEW_FOR_MS = 15 * 60_000;
const REPO_PATTERN = /^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/;

// Mirrors ExpenseCategory: title, and whether it suggests travel on its own.
const CATEGORIES = {
  airfare: ['Airfare', true],
  rail: ['Rail', true],
  cab: ['Cab / Taxi', true],
  localTransport: ['Local transport', true],
  hotel: ['Hotel', true],
  meals: ['Meals', false],
  fuel: ['Fuel', false],
  tollsParking: ['Tolls / Parking', true],
  visaForex: ['Visa / Forex', true],
  other: ['Other', false],
};

// Mirrors TripWindow: a trip claims the day before it starts and two after it ends.
const TRIP_DAYS_BEFORE = 1;
const TRIP_DAYS_AFTER = 2;

const STATUS = {
  pending: { label: 'Waiting', cls: 'waiting' },
  work: { label: 'Work', cls: 'work' },
  personal: { label: 'Personal', cls: '' },
};

// Constant markup only — never built from data.
const ICONS = {
  airfare: '<path d="M10.5 3.5a1.5 1.5 0 0 1 3 0V9l7 4v2l-7-2v4.5l2.5 2V21L12 20l-4 1v-1.5l2.5-2V13l-7 2v-2l7-4z"/>',
  rail: '<rect x="6" y="3" width="12" height="13" rx="3"/><path d="M6 10h12M9 16l-2 4.5M15 16l2 4.5"/><path d="M9.5 13h.01M14.5 13h.01"/>',
  cab: '<path d="M5 17H3.5v-4.5L6 7h12l2.5 5.5V17H19M3.5 12.5h17M9.5 17h5"/><circle cx="7.5" cy="17" r="2"/><circle cx="16.5" cy="17" r="2"/>',
  localTransport: '<rect x="5" y="3" width="14" height="15" rx="2.5"/><path d="M5 11h14M8 18v3M16 18v3M8.5 14.5h.01M15.5 14.5h.01"/>',
  hotel: '<path d="M3 19V6M3 15h18v4M21 15v-3a3 3 0 0 0-3-3h-7v6"/><circle cx="7" cy="11.5" r="1.8"/>',
  meals: '<path d="M7 3v7a2 2 0 0 0 4 0V3M9 12v9M9 3v5M17 21V3c-2 1.2-3 4-3 8h3"/>',
  fuel: '<path d="M5 21V5a1.5 1.5 0 0 1 1.5-1.5h6A1.5 1.5 0 0 1 14 5v16M4 21h11M5 10h9M14 8h2l2 2v7.5a1.5 1.5 0 0 0 3 0V9l-3-3"/>',
  tollsParking: '<rect x="4" y="4" width="16" height="16" rx="3.5"/><path d="M10 16.5v-9h3a2.75 2.75 0 0 1 0 5.5h-3"/>',
  visaForex: '<path d="M6 3h8l4 4v14H6zM14 3v4h4M9 12h6M9 16h4"/>',
  other: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.5"/>',
  refresh: '<path d="M20 11a8 8 0 0 0-14.3-4.9L4 8M4 4v4h4M4 13a8 8 0 0 0 14.3 4.9L20 16M20 20v-4h-4"/>',
  sliders: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
  close: '<path d="M6 6l12 12M18 6 6 18"/>',
  clip: '<path d="m20 11.5-8.2 8.2a5 5 0 0 1-7-7L13 4.5a3.3 3.3 0 0 1 4.7 4.7l-8.2 8.2a1.7 1.7 0 0 1-2.4-2.4l7.6-7.6"/>',
  alert: '<path d="M12 3.5 2.5 20h19zM12 10v4M12 17h.01"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  dashed: '<circle cx="12" cy="12" r="8" stroke-dasharray="3.2 3"/>',
  cross: '<circle cx="12" cy="12" r="9"/><path d="m9 9 6 6M15 9l-6 6"/>',
  shield: '<path d="M12 3 4.5 6v6c0 4.5 3.2 7.8 7.5 9 4.3-1.2 7.5-4.5 7.5-9V6z"/><path d="m8.8 12.2 2.3 2.3 4.3-4.6"/>',
  inbox: '<path d="M3 13h5l1.5 2.5h5L16 13h5M5.5 5h13L21 13v6H3v-6z"/>',
  download: '<path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
  suitcase: '<rect x="3" y="7" width="18" height="13" rx="2.5"/><path d="M9 7V5a1.5 1.5 0 0 1 1.5-1.5h3A1.5 1.5 0 0 1 15 5v2M3 12.5h18"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="m16 16 4 4"/>',
};

const state = {
  mode: null,              // 'live' | 'demo'
  connection: null,        // { repo, token, remember }
  raw: '',
  snapshot: null,
  view: null,
  firstSeen: new Map(),    // uid -> ms first seen here (0 = was there on first load)
  checking: false,
  error: null,
  lastChecked: 0,
  timer: null,
  tab: 'inbox',
  expenseFilter: 'all',
  expenseTrip: '',
  allStatus: 'all',
  search: '',
  openUid: null,
};

const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------- DOM helpers

function h(tag, props, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props || {})) {
    if (value == null || value === false) continue;
    if (key === 'class') el.className = value;
    else if (key === 'style') Object.assign(el.style, value);
    else if (key.startsWith('on')) el.addEventListener(key.slice(2), value);
    else el.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false) continue;
    el.append(child instanceof Node ? child : String(child));
  }
  return el;
}

function icon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('class', 'icon');
  svg.setAttribute('aria-hidden', 'true');
  svg.innerHTML = ICONS[name] || ICONS.other;
  return svg;
}

const tag = (text, cls = '', iconName) => h('span', { class: `tag ${cls}` }, iconName && icon(iconName), text);

function empty(iconName, title, text) {
  return h('div', { class: 'card empty' }, icon(iconName), h('p', null, h('strong', null, title), text));
}

// ---------------------------------------------------------------- Formatting

const formats = new Map();
function money(value, currency = 'INR') {
  const whole = Math.abs(value - Math.round(value)) < 0.005;
  const key = `${currency}:${whole}`;
  try {
    if (!formats.has(key)) {
      formats.set(key, new Intl.NumberFormat(currency === 'INR' ? 'en-IN' : undefined, {
        style: 'currency', currency,
        minimumFractionDigits: whole ? 0 : 2, maximumFractionDigits: whole ? 0 : 2,
      }));
    }
    return formats.get(key).format(value);
  } catch {
    return `${currency} ${value.toFixed(2)}`;
  }
}

function totals(list, pick) {
  const sums = new Map();
  for (const p of list) sums.set(p.currency, (sums.get(p.currency) || 0) + pick(p));
  return sums;
}

/** "₹12,340 + $45" — currencies are never added together. */
function moneyList(sums) {
  const entries = [...sums].filter(([, v]) => Math.abs(v) >= 0.005)
    .sort(([a], [b]) => (a === 'INR' ? -1 : b === 'INR' ? 1 : a.localeCompare(b)));
  return entries.length ? entries.map(([c, v]) => money(v, c)).join(' + ') : money(0);
}

const fmtDay = new Intl.DateTimeFormat('en-IN', { day: 'numeric', month: 'short' });
const fmtDayYear = new Intl.DateTimeFormat('en-IN', { day: 'numeric', month: 'short', year: 'numeric' });
const fmtTime = new Intl.DateTimeFormat('en-IN', { hour: 'numeric', minute: '2-digit' });
const fmtMonth = new Intl.DateTimeFormat('en-IN', { month: 'long', year: 'numeric' });
const fmtFull = new Intl.DateTimeFormat('en-IN', { dateStyle: 'medium', timeStyle: 'short' });

function dayText(date) {
  return (date.getFullYear() === new Date().getFullYear() ? fmtDay : fmtDayYear).format(date);
}

const sameDay = (a, b) => a.toDateString() === b.toDateString();

/** A bank SMS gives the date but not the time; the time it arrived fills in when they agree. */
function paidText(p) {
  const paid = new Date(p.paidAt);
  const received = new Date(p.receivedAt);
  return sameDay(paid, received) ? `${dayText(paid)}, ${fmtTime.format(received)}` : dayText(paid);
}

function ago(iso) {
  const seconds = Math.round((Date.now() - new Date(iso)) / 1000);
  if (seconds < 45) return 'just now';
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.round(hours / 24);
  if (days === 1) return 'yesterday';
  if (days < 7) return `${days} days ago`;
  return `on ${fmtDayYear.format(new Date(iso))}`;
}

const plural = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
const categoryTitle = (key) => (CATEGORIES[key] || CATEGORIES.other)[0];
const isTravel = (key) => (CATEGORIES[key] || CATEGORIES.other)[1];

// ---------------------------------------------------------------- Trips

function tripWindow(trip) {
  const from = new Date(trip.startDate);
  from.setDate(from.getDate() - TRIP_DAYS_BEFORE);
  from.setHours(0, 0, 0, 0);
  const to = new Date(trip.endDate);
  to.setDate(to.getDate() + TRIP_DAYS_AFTER);
  to.setHours(23, 59, 59, 999);
  return [from, to];
}

/** Shortest matching trip wins, as on the phone. */
function tripCovering(date) {
  const span = (t) => new Date(t.endDate) - new Date(t.startDate);
  return state.view.trips
    .filter((t) => { const [from, to] = tripWindow(t); return date >= from && date <= to; })
    .sort((a, b) => span(a) - span(b))[0];
}

function tripDates(trip) {
  const start = new Date(trip.startDate);
  const end = new Date(trip.endDate);
  return sameDay(start, end) ? fmtDayYear.format(start) : `${fmtDay.format(start)} – ${fmtDayYear.format(end)}`;
}

// ---------------------------------------------------------------- Data

class LoadError extends Error {
  constructor(message, status = 0) { super(message); this.status = status; }
}

async function fetchSnapshot(connection) {
  let res;
  try {
    res = await fetch(`${API}/repos/${connection.repo}/contents/${DATA_PATH}`, {
      headers: {
        Authorization: `Bearer ${connection.token}`,
        Accept: 'application/vnd.github.raw+json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
      // Revalidate every time; an unchanged file comes back as a free 304.
      cache: 'no-cache',
    });
  } catch {
    throw new LoadError("Couldn't reach GitHub. Check the connection; this page will keep trying.");
  }
  if (res.ok) return res.text();

  let message = '';
  try { message = (await res.json()).message || ''; } catch { /* not JSON */ }
  if (res.status === 401) {
    throw new LoadError("GitHub didn't accept the token. It may have expired — paste a new one.", 401);
  }
  if ((res.status === 403 || res.status === 429) && /rate limit/i.test(message)) {
    throw new LoadError('GitHub rate limit reached. Trying again shortly.', res.status);
  }
  if (res.status === 403) {
    throw new LoadError('The token can’t read this repo. It needs Contents: Read-only on it.', 403);
  }
  if (res.status === 404) {
    throw new LoadError(`Nothing at ${connection.repo}/${DATA_PATH}. Check the repo name and that the token `
      + 'can see it. If both are right, the phone hasn’t synced yet: Setup → Website → Save and sync now.', 404);
  }
  throw new LoadError(`GitHub answered ${res.status}${message ? `: ${message}` : ''}.`, res.status);
}

function applySnapshot(text) {
  if (text === state.raw) return;
  let data;
  try { data = JSON.parse(text); } catch { throw new LoadError(`${DATA_PATH} isn’t valid JSON.`); }
  if (!data || !Array.isArray(data.payments) || !Array.isArray(data.trips)) {
    throw new LoadError(`${DATA_PATH} doesn’t look like a Trip Receipts sync.`);
  }

  const first = !state.snapshot;
  const now = Date.now();
  for (const p of data.payments) {
    if (!state.firstSeen.has(p.uid)) state.firstSeen.set(p.uid, first ? 0 : now);
  }
  state.raw = text;
  state.snapshot = data;
  state.view = derive(data);
  render();
}

function derive(data) {
  const byPaid = (a, b) => new Date(b.paidAt) - new Date(a.paidAt) || new Date(b.receivedAt) - new Date(a.receivedAt);
  const payments = [...data.payments].sort(byPaid);
  const trips = [...data.trips].sort((a, b) => new Date(b.startDate) - new Date(a.startDate));
  return {
    payments,
    trips,
    tripsById: new Map(trips.map((t) => [t.id, t])),
    pending: payments.filter((p) => p.status === 'pending'),
    work: payments.filter((p) => p.status === 'work'),
    personal: payments.filter((p) => p.status === 'personal'),
  };
}

const isNew = (p) => {
  const seen = state.firstSeen.get(p.uid);
  return seen > 0 && Date.now() - seen < NEW_FOR_MS;
};

// ---------------------------------------------------------------- Connection

function loadConnection() {
  for (const store of [sessionStorage, localStorage]) {
    try {
      const saved = JSON.parse(store.getItem(CONNECTION_KEY) || 'null');
      if (saved?.repo && saved?.token) return saved;
    } catch { /* storage blocked or malformed */ }
  }
  return null;
}

function saveConnection(connection) {
  forgetConnection();
  try {
    (connection.remember ? localStorage : sessionStorage).setItem(CONNECTION_KEY, JSON.stringify(connection));
  } catch { /* lives in memory for this visit only */ }
}

function forgetConnection() {
  try { localStorage.removeItem(CONNECTION_KEY); } catch { /* ignore */ }
  try { sessionStorage.removeItem(CONNECTION_KEY); } catch { /* ignore */ }
}

function showConnect({ repo = '', error = '' } = {}) {
  $('dashboard').hidden = true;
  $('connect').hidden = false;
  $('f-repo').value = repo;
  $('f-token').value = '';

  const connected = state.mode === 'live' && state.connection;
  $('connected-as').hidden = !connected;
  $('connected-as').textContent = connected ? `Connected to ${state.connection.repo}.` : '';
  $('f-token').placeholder = connected ? 'Saved · paste to replace' : 'github_pat_…';
  $('f-remember').checked = connected ? state.connection.remember : true;
  $('disconnect-btn').hidden = !connected;
  $('cancel-btn').hidden = !state.snapshot;
  formError(error);
  renderChrome();
  (repo ? $('f-token') : $('f-repo')).focus();
}

function formError(message) {
  $('form-error').hidden = !message;
  $('form-error').textContent = message || '';
}

async function onConnect(event) {
  event.preventDefault();
  const repo = $('f-repo').value.trim()
    .replace(/^https?:\/\/github\.com\//i, '').replace(/\.git$/, '').replace(/\/+$/, '');
  let token = $('f-token').value.trim();
  if (!token && state.connection?.repo === repo) token = state.connection.token;

  if (!REPO_PATTERN.test(repo)) return formError('Enter the repo as owner/name, like Khaja500/trip-receipts-data.');
  if (!token) return formError('Paste a token that can read that repo.');

  const connection = { repo, token, remember: $('f-remember').checked };
  const button = $('connect-btn');
  button.disabled = true;
  button.textContent = 'Connecting…';
  formError('');
  try {
    const text = await fetchSnapshot(connection);
    saveConnection(connection);
    state.connection = connection;
    state.mode = 'live';
    state.raw = '';
    state.snapshot = null;
    state.firstSeen.clear();
    state.error = null;
    state.lastChecked = Date.now();
    showDashboard();
    applySnapshot(text);
    startPolling();
  } catch (err) {
    formError(err.message);
  } finally {
    button.disabled = false;
    button.textContent = 'Connect';
  }
}

function disconnect() {
  forgetConnection();
  clearInterval(state.timer);
  Object.assign(state, { mode: null, connection: null, raw: '', snapshot: null, view: null, error: null });
  showConnect();
}

async function startLive(connection) {
  state.connection = connection;
  state.mode = 'live';
  showDashboard();
  await refresh();
  if (state.snapshot) startPolling();
}

async function startDemo() {
  clearInterval(state.timer);
  Object.assign(state, { mode: 'demo', raw: '', snapshot: null, error: null });
  state.firstSeen.clear();
  showDashboard();
  const res = await fetch('sample.json', { cache: 'no-cache' });
  applySnapshot(await res.text());
}

function startPolling() {
  clearInterval(state.timer);
  state.timer = setInterval(() => {
    if (document.visibilityState === 'visible') refresh();
    else renderChrome();
  }, POLL_MS);
}

async function refresh() {
  if (state.mode !== 'live' || state.checking) return;
  state.checking = true;
  renderChrome();
  try {
    const text = await fetchSnapshot(state.connection);
    state.error = null;
    state.lastChecked = Date.now();
    applySnapshot(text);
  } catch (err) {
    state.error = err;
    // Nothing loaded yet and the problem is the repo or token: back to the form.
    if (!state.snapshot && err.status) {
      state.mode = null;
      showConnect({ repo: state.connection.repo, error: err.message });
      return;
    }
  } finally {
    state.checking = false;
    renderChrome();
    if (!state.snapshot && state.mode === 'live') renderLoading();
  }
}

function showDashboard() {
  $('connect').hidden = true;
  $('dashboard').hidden = false;
  if (!state.snapshot) renderLoading();
  renderChrome();
}

// ---------------------------------------------------------------- Rendering

function render() {
  if (!state.view) return;
  renderChrome();
  renderTiles();
  renderTabs();
  renderPanel();
  if (state.openUid) renderDetail();
}

function renderLoading() {
  $('tiles').replaceChildren();
  $('panel').replaceChildren(empty('inbox', state.error ? 'Couldn’t load yet' : 'Loading your payments…',
    state.error ? state.error.message : `Reading ${DATA_PATH} from ${state.connection?.repo ?? 'GitHub'}.`));
}

function renderChrome() {
  const pill = $('pill');
  const live = state.mode === 'live';
  pill.hidden = !state.mode;
  $('refresh').hidden = !live;
  $('settings').hidden = !state.mode;
  $('refresh').classList.toggle('is-spinning', state.checking);

  let cls = '';
  let text = '';
  let title = '';
  if (state.mode === 'demo') {
    cls = 'demo';
    text = 'Sample data';
  } else if (live && state.error) {
    cls = 'warn';
    text = state.error.status === 401 ? 'Token rejected' : 'Can’t refresh · retrying';
    title = state.error.message;
  } else if (live && state.snapshot) {
    cls = 'live';
    text = `Live · phone synced ${ago(state.snapshot.generatedAt)}`;
    title = `The phone last synced ${fmtFull.format(new Date(state.snapshot.generatedAt))}. `
      + `Checked ${fmtTime.format(new Date(state.lastChecked))}; checks every ${POLL_MS / 1000} s.`;
  } else if (live) {
    text = 'Connecting…';
  }
  pill.className = `pill ${cls}`;
  pill.title = title;
  pill.replaceChildren(h('span', { class: 'dot', 'aria-hidden': 'true' }), h('span', { class: 'pill-text' }, text));

  const banner = $('banner');
  banner.className = 'banner';
  if (state.mode === 'demo') {
    banner.classList.add('demo');
    banner.replaceChildren(icon('info'), h('span', null,
      'Invented sample data, in exactly the shape the phone syncs. ',
      h('button', { class: 'link-btn', type: 'button', onclick: () => showConnect() }, 'Connect your repo')));
    banner.hidden = false;
  } else if (live && state.error && state.snapshot) {
    banner.replaceChildren(icon('alert'), h('span', null,
      `${state.error.message} Showing what was loaded at ${fmtTime.format(new Date(state.lastChecked))}. `,
      state.error.status === 401 && h('button', {
        class: 'link-btn', type: 'button', onclick: () => showConnect({ repo: state.connection.repo }),
      }, 'Paste a new token')));
    banner.hidden = false;
  } else {
    banner.hidden = true;
  }

  const waiting = state.view?.pending.length || 0;
  document.title = waiting ? `(${waiting}) Trip Receipts` : 'Trip Receipts';
}

function renderTiles() {
  const v = state.view;
  const missing = v.work.filter((p) => !p.receipts.length);
  const tripsWithWork = new Set(v.work.map((p) => p.tripID).filter(Boolean)).size;
  const active = tripCovering(new Date());
  const latest = v.trips[0];

  const tile = (label, value, sub, cls = '') => h('div', { class: `card tile ${cls}` },
    h('div', { class: 'tile-label' }, label),
    h('div', { class: 'tile-value' }, value),
    h('div', { class: 'tile-sub' }, sub));

  $('tiles').replaceChildren(
    tile('To claim', moneyList(totals(v.work, (p) => p.netClaimable)),
      `${plural(v.work.length, 'work expense')}${tripsWithWork ? ` across ${plural(tripsWithWork, 'trip')}` : ''}`, 'hero'),
    tile('Waiting for an answer', String(v.pending.length),
      v.pending.length ? `${moneyList(totals(v.pending, (p) => p.amount))} · answer on the phone` : 'Every payment answered'),
    tile('Missing receipts', String(missing.length),
      missing.length ? h('span', { class: 'warn-text' }, `${moneyList(totals(missing, (p) => p.netClaimable))} unsupported`)
        : (v.work.length ? 'Every expense has one' : 'Nothing to support yet')),
    active
      ? tile('Trip in progress', active.name, tripDates(active), 'is-text')
      : tile('Trips', String(v.trips.length), latest ? `Latest: ${latest.name}` : 'Create one on the phone'),
  );
}

function renderTabs() {
  for (const tab of document.querySelectorAll('[role="tab"]')) {
    const selected = tab.dataset.tab === state.tab;
    tab.setAttribute('aria-selected', String(selected));
    tab.tabIndex = selected ? 0 : -1;
  }
  const inbox = $('tab-inbox');
  const count = state.view.pending.length;
  inbox.replaceChildren('Inbox', count ? h('span', { class: 'count', 'aria-label': `${count} waiting` }, count) : null);
  $('panel').setAttribute('aria-labelledby', `tab-${state.tab}`);
}

function selectTab(name) {
  state.tab = name;
  try { localStorage.setItem(TAB_KEY, name); } catch { /* fine */ }
  renderTabs();
  renderPanel();
}

function renderPanel() {
  // Keep the caret in the search box when a poll redraws underneath it.
  const focused = document.activeElement?.id === 'search' ? document.activeElement : null;
  const caret = focused ? [focused.selectionStart, focused.selectionEnd] : null;

  const panel = $('panel');
  const builders = { inbox: inboxPanel, expenses: expensesPanel, trips: tripsPanel, all: allPanel };
  panel.replaceChildren(...[(builders[state.tab] || inboxPanel)()].flat(Infinity).filter(Boolean));

  if (caret) {
    const search = $('search');
    search?.focus();
    search?.setSelectionRange(...caret);
  }
}

// ---------------------------------------------------------------- Rows

/** Why a waiting payment might be work — the same hints the notification gives. */
function hintFor(p) {
  const trip = tripCovering(new Date(p.paidAt));
  if (trip) return `During ${trip.name}`;
  if (isTravel(p.category)) return `${categoryTitle(p.category)} · usually travel`;
  if (state.view.work.some((w) => w.merchant === p.merchant)) return 'Marked work before';
  return null;
}

function categoryBadge(key) {
  return h('span', { class: `cat${isTravel(key) ? ' travel' : ''}`, title: categoryTitle(key) }, icon(CATEGORIES[key] ? key : 'other'));
}

function amountFor(p, claim) {
  if (!claim || Math.abs(p.netClaimable - p.amount) < 0.005) return h('span', { class: 'amount' }, money(p.amount, p.currency));
  return h('span', { class: 'amount', title: `Paid ${money(p.amount, p.currency)}; claiming ${money(p.netClaimable, p.currency)}` },
    h('s', null, money(p.amount, p.currency)), money(p.netClaimable, p.currency));
}

function paymentRow(p, kind) {
  const meta = [paidText(p), p.instrument || (p.isManual ? 'Entered by hand' : '')];
  if (kind === 'inbox') meta.push(hintFor(p));
  if (kind === 'all' && p.tripID) meta.push(state.view.tripsById.get(p.tripID)?.name);

  const side = [amountFor(p, kind === 'expenses')];
  if (kind === 'expenses') {
    side.push(p.receipts.length
      ? checkTag(paymentCheck(p)) || tag(String(p.receipts.length), 'ok', 'clip')
      : tag('No receipt', 'missing', 'alert'));
  } else if (kind === 'all') {
    const status = STATUS[p.status] || STATUS.pending;
    side.push(tag(status.label, status.cls));
  }

  return h('button', {
    type: 'button',
    class: `row${isNew(p) ? ' is-new' : ''}`,
    onclick: () => openDetail(p.uid),
  },
  categoryBadge(p.category),
  h('span', { class: 'row-main' },
    h('span', { class: 'row-title' }, h('span', null, p.merchant || 'Unknown payee'), isNew(p) && tag('New', 'new')),
    h('span', { class: 'row-meta' }, meta.filter(Boolean).join(' · '))),
  h('span', { class: 'row-side' }, side));
}

const list = (payments, kind) => h('div', { class: 'card list' }, payments.map((p) => paymentRow(p, kind)));

function group(title, meta, total, content) {
  return h('section', { class: 'group' },
    h('div', { class: 'group-head' },
      h('h3', { class: 'group-title' }, title),
      meta && h('span', { class: 'group-meta' }, meta),
      total && h('span', { class: 'group-total' }, total)),
    content);
}

function chips(options, current, onPick) {
  return h('div', { class: 'chips', role: 'group' }, options.map(([value, label]) => h('button', {
    type: 'button', class: 'chip', 'aria-pressed': String(value === current), onclick: () => onPick(value),
  }, label)));
}

// ---------------------------------------------------------------- Panels

function inboxPanel() {
  const { pending } = state.view;
  return [
    h('div', { class: 'panel-head' }, h('p', { class: 'panel-note' },
      'Payments the phone caught that haven’t been answered yet. Answer on the iPhone — from the notification '
      + 'or its Inbox — and they move to Expenses here within half a minute.')),
    pending.length
      ? list(pending, 'inbox')
      : empty('inbox', 'Nothing waiting', 'Every payment the phone caught has been answered.'),
  ];
}

function expensesPanel() {
  const v = state.view;
  let shown = v.work;
  if (state.expenseTrip && !v.tripsById.has(state.expenseTrip)) state.expenseTrip = '';
  if (state.expenseTrip) shown = shown.filter((p) => p.tripID === state.expenseTrip);
  if (state.expenseFilter === 'missing') shown = shown.filter((p) => !p.receipts.length);
  if (state.expenseFilter === 'unfiled') shown = shown.filter((p) => !p.tripID || !v.tripsById.has(p.tripID));
  if (state.expenseFilter === 'warnings') shown = shown.filter((p) => paymentCheck(p)?.status === 'warning');

  const missingCount = v.work.filter((p) => !p.receipts.length).length;
  const warningCount = v.work.filter((p) => paymentCheck(p)?.status === 'warning').length;
  const tripSelect = h('select', {
    class: 'select', 'aria-label': 'Trip',
    onchange: (e) => { state.expenseTrip = e.target.value; renderPanel(); },
  },
  h('option', { value: '' }, 'All trips'),
  v.trips.map((t) => h('option', { value: t.id, selected: t.id === state.expenseTrip }, t.name)));

  const head = h('div', { class: 'panel-head' },
    chips([['all', 'All'], ['missing', `Missing receipt${missingCount ? ` · ${missingCount}` : ''}`],
      ...(warningCount ? [['warnings', `Receipt doesn’t match · ${warningCount}`]] : []), ['unfiled', 'Not in a trip']],
      state.expenseFilter, (value) => { state.expenseFilter = value; renderPanel(); }),
    h('div', { class: 'toolbar' }, v.trips.length > 0 && tripSelect,
      shown.length > 0 && h('button', {
        type: 'button', class: 'btn btn-ghost btn-sm',
        onclick: () => downloadCSV(shown, state.expenseTrip ? `${slug(v.tripsById.get(state.expenseTrip).name)}-claim` : 'work-expenses'),
      }, icon('download'), 'CSV')));

  if (!shown.length) {
    const why = v.work.length
      ? ['Nothing matches', 'Try another filter.']
      : ['No work expenses yet', 'Answer “Yes, work travel” on the phone and they appear here, filed under their trip.'];
    return [head, empty('suitcase', ...why)];
  }

  const groups = new Map();
  for (const p of shown) {
    const key = v.tripsById.has(p.tripID) ? p.tripID : '';
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(p);
  }
  const ordered = [...v.trips.map((t) => t.id).filter((id) => groups.has(id)), ...(groups.has('') ? [''] : [])];
  return [head, ordered.map((id) => {
    const items = groups.get(id);
    const trip = v.tripsById.get(id);
    return group(trip ? trip.name : 'Not in a trip', trip ? tripDates(trip) : 'Work, but outside every trip’s dates',
      moneyList(totals(items, (p) => p.netClaimable)), list(items, 'expenses'));
  })];
}

function tripsPanel() {
  const v = state.view;
  if (!v.trips.length) {
    return empty('suitcase', 'No trips yet',
      'Create one in the Trips tab on the phone; work payments in its dates file themselves under it.');
  }
  const now = new Date();
  return h('div', { class: 'trip-grid' }, v.trips.map((trip) => {
    const items = v.work.filter((p) => p.tripID === trip.id);
    const missing = items.filter((p) => !p.receipts.length).length;
    const [from, to] = tripWindow(trip);
    const active = now >= from && now <= to;

    const byCategory = new Map();
    for (const p of items) byCategory.set(p.category, (byCategory.get(p.category) || 0) + p.netClaimable);
    const rows = [...byCategory].sort((a, b) => b[1] - a[1]);
    const max = rows[0]?.[1] || 1;
    const currency = items[0]?.currency || 'INR';

    const details = [trip.client, trip.purpose, trip.costCentre].filter(Boolean).join(' · ');
    return h('article', { class: 'card trip' },
      h('div', { class: 'trip-top' },
        h('div', null,
          h('h3', { class: 'trip-name' }, trip.name),
          h('div', { class: 'trip-when' }, [tripDates(trip), trip.destination].filter(Boolean).join(' · '))),
        h('div', { class: 'trip-total' },
          h('span', { class: 'amount' }, moneyList(totals(items, (p) => p.netClaimable))),
          h('small', null, 'to claim'))),
      details && h('p', { class: 'note' }, details),
      h('div', { class: 'trip-facts' },
        active && tag('In progress', 'work'),
        tag(plural(items.length, 'expense')),
        items.length > 0 && (missing ? tag(plural(missing, 'missing receipt'), 'missing', 'alert') : tag('All receipts in', 'ok', 'check'))),
      rows.length > 0 && h('figure', { class: 'bars' },
        h('figcaption', { class: 'bars-title' }, 'By category'),
        rows.map(([key, value]) => h('div', { class: 'bar-row', title: `${categoryTitle(key)}: ${money(value, currency)}` },
          h('span', { class: 'bar-label' }, categoryTitle(key)),
          h('span', { class: 'bar-track' },
            h('span', { class: 'bar', style: { width: `${Math.max(1, (value / max) * 78)}%` } }),
            h('span', { class: 'bar-value' }, money(value, currency)))))),
      h('div', { class: 'trip-actions' },
        h('button', {
          type: 'button', class: 'btn btn-ghost btn-sm',
          onclick: () => { state.expenseTrip = trip.id; state.expenseFilter = 'all'; selectTab('expenses'); },
        }, 'Show expenses'),
        items.length > 0 && h('button', {
          type: 'button', class: 'btn btn-ghost btn-sm', onclick: () => downloadCSV(items, `${slug(trip.name)}-claim`),
        }, icon('download'), 'Claim CSV')));
  }));
}

function allPanel() {
  const v = state.view;
  const query = state.search.trim().toLowerCase();
  let shown = state.allStatus === 'all' ? v.payments : v.payments.filter((p) => p.status === state.allStatus);
  if (query) {
    shown = shown.filter((p) => [p.merchant, p.rawMessage, p.reference, p.instrument, p.bank, p.notes,
      categoryTitle(p.category), String(p.amount)].some((field) => field && String(field).toLowerCase().includes(query)));
  }

  const head = h('div', { class: 'panel-head' },
    chips([['all', 'All'], ['pending', 'Waiting'], ['work', 'Work'], ['personal', 'Personal']],
      state.allStatus, (value) => { state.allStatus = value; renderPanel(); }),
    h('div', { class: 'toolbar' },
      h('input', {
        id: 'search', class: 'search', type: 'search', placeholder: 'Search payee, message, amount',
        'aria-label': 'Search payments', value: state.search,
        oninput: (e) => { state.search = e.target.value; renderPanel(); },
      }),
      shown.length > 0 && h('button', {
        type: 'button', class: 'btn btn-ghost btn-sm', onclick: () => downloadCSV(shown, 'payments'),
      }, icon('download'), 'CSV')));

  if (!shown.length) {
    return [head, empty('search', v.payments.length ? 'No payments match' : 'No payments yet',
      v.payments.length ? 'Try a different search or filter.' : 'Payments appear as the phone catches them.')];
  }

  const months = new Map();
  for (const p of shown) {
    const key = fmtMonth.format(new Date(p.paidAt));
    if (!months.has(key)) months.set(key, []);
    months.get(key).push(p);
  }
  return [head,
    [...months].map(([month, items]) => group(month, plural(items.length, 'payment'),
      moneyList(totals(items, (p) => p.amount)), list(items, 'all'))),
    state.allStatus !== 'pending' && v.personal.length > 0 && h('p', { class: 'note' },
      'Personal payments are deleted on the phone 30 days after you mark them, and drop off here then.')];
}

// ---------------------------------------------------------------- Detail

function openDetail(uid) {
  state.openUid = uid;
  renderDetail();
  const dialog = $('detail');
  if (!dialog.open) dialog.showModal();
}

function renderDetail() {
  const dialog = $('detail');
  const p = state.view?.payments.find((x) => x.uid === state.openUid);
  if (!p) {
    if (dialog.open) dialog.close();
    return;
  }
  const status = STATUS[p.status] || STATUS.pending;
  const trip = state.view.tripsById.get(p.tripID);
  const scroll = dialog.scrollTop;

  const claim = [];
  if (p.status === 'work') {
    claim.push(`Claiming ${money(p.netClaimable, p.currency)}`);
    if (p.claimableAmount < p.amount - 0.005) claim.push(`part of the bill (${money(p.claimableAmount, p.currency)})`);
    if (p.refundedAmount > 0) claim.push(`after a ${money(p.refundedAmount, p.currency)} refund`);
  } else if (p.status === 'pending') {
    claim.push('Waiting for an answer on the phone');
  } else {
    claim.push('Marked personal — not claimed');
  }

  const facts = [
    ['Paid', paidText(p)],
    ['Paid by', p.instrument],
    ['Bank', p.bank],
    ['Reference', p.reference],
    ['Category', categoryTitle(p.category)],
    ['Trip', trip && `${trip.name} · ${tripDates(trip)}`],
    ['Notes', p.notes],
    ['Answered', p.reviewedAt && fmtFull.format(new Date(p.reviewedAt))],
    ['Parsing', p.parseConfidence < 0.9 && !p.isManual && 'Partly understood — check the payee on the phone'],
  ].filter(([, value]) => value);

  dialog.replaceChildren(
    h('div', { class: 'd-head' },
      categoryBadge(p.category),
      h('div', null,
        h('h2', { id: 'detail-title' }, p.merchant || 'Unknown payee'),
        h('div', { class: 'd-sub' }, tag(status.label, status.cls), tag(categoryTitle(p.category)), trip && tag(trip.name))),
      h('button', { type: 'button', class: 'icon-btn', 'aria-label': 'Close', onclick: () => dialog.close() }, icon('close'))),
    h('div', { class: 'd-amount' },
      h('div', { class: 'big' }, money(p.amount, p.currency)),
      h('div', { class: 'claim' }, claim.join(', '))),
    h('section', { class: 'd-section' },
      h('h3', null, 'Details'),
      h('dl', { class: 'facts' }, facts.map(([k, value]) => [h('dt', null, k), h('dd', null, value)]))),
    h('section', { class: 'd-section' },
      h('h3', null, 'Receipts'),
      p.receipts.length
        ? h('div', null, p.receipts.map((r) => receiptLine(r, p)))
        : h('p', { class: 'note' }, p.status === 'work'
          ? 'No receipt attached yet. Add it on the phone — scan, photo or PDF.'
          : 'None attached.')),
    h('section', { class: 'd-section' },
      h('h3', null, 'Proof of payment'),
      p.isManual || !p.rawMessage
        ? h('p', { class: 'note' }, 'Entered by hand — there is no bank message for this one.')
        : [
          proofBlock({ text: p.rawMessage, sender: p.sender, receivedAt: p.receivedAt, fingerprint: p.messageHash }, 'Original message'),
          ...(p.additionalMessages || []).map((m) => proofBlock(m, 'Also received')),
        ]),
  );
  dialog.scrollTop = scroll;
}

/**
 * The receipt check that speaks for a payment, as the phone ran it: a
 * matching receipt settles it; otherwise a warning outranks "unverified".
 * The site shows the phone's verdict rather than comparing again.
 */
function paymentCheck(p) {
  const checks = p.receipts.map((r) => r.verification).filter(Boolean);
  return checks.find((c) => c.status === 'matched')
    || checks.find((c) => c.status === 'warning')
    || checks[0] || null;
}

function checkTag(check) {
  if (!check) return null;
  if (check.status === 'matched') return tag('Verified', 'ok', 'check');
  if (check.status === 'warning') return tag(check.overridden ? 'Added anyway' : 'Doesn’t match', 'missing', 'alert');
  return tag('Unverified', '', 'dashed');
}

function receiptLine(r, p) {
  const v = r.verification;
  if (v) {
    const read = [
      typeof v.parsedTotal === 'number' && `total ${money(v.parsedTotal, v.parsedCurrency || p.currency)}`,
      v.parsedDate && `dated ${dayText(new Date(`${v.parsedDate}T${v.parsedTime || '12:00'}`))}`,
      v.parsedMerchant && `from ${v.parsedMerchant}`,
    ].filter(Boolean).join(', ');
    const lines = [
      v.summary,
      read && `${v.source === 'online' ? 'Parser read' : 'Read on the phone'}: ${read}.`,
      v.source !== 'online' && v.fallbackReason,
      v.overridden && (v.note ? `Added to the trip anyway: “${v.note}”` : 'Added to the trip anyway.'),
    ].filter(Boolean);
    return h('div', { class: 'receipt' },
      icon(r.isPDF ? 'visaForex' : 'clip'),
      h('div', { class: 'grow' }, r.filename,
        h('small', null, `Added ${dayText(new Date(r.addedAt))} · kept on the phone`),
        lines.map((line, i) => h('small', { class: i === 0 && v.status === 'warning' ? 'warn-text' : '' }, line))),
      checkTag(v));
  }
  let check = null;
  if (typeof r.ocrTotal === 'number' && p.amount > 0) {
    const matches = Math.abs(r.ocrTotal - p.amount) / p.amount <= 0.01;
    check = matches
      ? tag(`Total ${money(r.ocrTotal, p.currency)} matches`, 'ok', 'check')
      : tag(`Total read ${money(r.ocrTotal, p.currency)}`, 'missing', 'alert');
  }
  return h('div', { class: 'receipt' },
    icon(r.isPDF ? 'visaForex' : 'clip'),
    h('div', { class: 'grow' }, r.filename, h('small', null, `Added ${dayText(new Date(r.addedAt))} · kept on the phone`)),
    check);
}

/** Recomputes the fingerprint the phone took when the SMS arrived. */
function proofBlock(message, label) {
  const verdict = h('span', { class: 'verdict pending' }, 'Checking…');
  const received = new Date(message.receivedAt);
  verifyFingerprint(message).then((ok) => {
    verdict.className = `verdict ${ok ? 'ok' : 'bad'}`;
    verdict.replaceChildren(icon(ok ? 'shield' : 'cross'),
      ok ? 'Matches — unchanged since it arrived' : 'Doesn’t match the text shown');
  });
  return h('div', { class: 'proof' },
    h('div', { class: 'proof-meta' },
      h('b', null, label),
      h('span', null, `From ${message.sender || 'unknown sender'}`),
      h('span', null, `Received ${fmtFull.format(received)}`)),
    h('pre', { class: 'sms' }, message.text),
    h('div', { class: 'fingerprint' },
      h('code', { title: message.fingerprint }, `SHA-256 ${shortHash(message.fingerprint)}`),
      verdict));
}

async function verifyFingerprint({ sender, receivedAt, text, fingerprint }) {
  if (!fingerprint || !crypto?.subtle) return false;
  // ProofHasher: sender, ISO 8601 time to the second, text — joined by newlines.
  const bytes = new TextEncoder().encode(`${sender}\n${receivedAt}\n${text}`);
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  const hex = Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join('');
  return hex === fingerprint;
}

const shortHash = (hash) => (hash && hash.length >= 16 ? `${hash.slice(0, 8)}…${hash.slice(-8)}` : hash || '—');

// ---------------------------------------------------------------- CSV

function slug(name) {
  return String(name).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'trip';
}

function csvField(value) {
  let text = value == null ? '' : String(value);
  // A payee or message starting like a formula must stay text in a spreadsheet.
  if (/^[=+@\t\r]/.test(text) || (/^-/.test(text) && Number.isNaN(Number(text)))) text = `'${text}`;
  return `"${text.replace(/"/g, '""')}"`;
}

function checkColumns(check) {
  if (!check) return ['', '', '', '', ''];
  return [check.status, typeof check.parsedTotal === 'number' ? check.parsedTotal.toFixed(2) : '',
    [check.parsedDate, check.parsedTime].filter(Boolean).join(' '), check.overridden ? 'yes' : 'no', check.note || ''];
}

/** The same columns as the claim pack the phone exports. */
function downloadCSV(payments, name) {
  const isoDay = (iso) => {
    const d = new Date(iso);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  };
  const fixed = (n) => Number(n || 0).toFixed(2);
  const rows = [
    ['Date', 'Payee', 'Category', 'Trip', 'Currency', 'Amount', 'Claimed', 'Refunded', 'Net claimed', 'Paid by',
      'Bank', 'Reference', 'Receipts', 'Notes', 'Original message', 'Proof SHA-256',
      'verification_status', 'parsed_total', 'parsed_date', 'overridden', 'note'],
    ...[...payments].sort((a, b) => new Date(a.paidAt) - new Date(b.paidAt)).map((p) => [
      isoDay(p.paidAt), p.merchant, categoryTitle(p.category), state.view.tripsById.get(p.tripID)?.name || '',
      p.currency, fixed(p.amount), fixed(p.claimableAmount), fixed(p.refundedAmount), fixed(p.netClaimable),
      p.instrument, p.bank || '', p.reference || '', p.receipts.length, p.notes,
      p.isManual ? '(entered manually)' : p.rawMessage, p.messageHash,
      ...checkColumns(paymentCheck(p)),
    ]),
  ];
  const csv = rows.map((row) => row.map(csvField).join(',')).join('\r\n');
  const url = URL.createObjectURL(new Blob(['﻿', csv], { type: 'text/csv;charset=utf-8' }));
  const link = h('a', { href: url, download: `${name}.csv` });
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// ---------------------------------------------------------------- Start

function init() {
  $('refresh').append(icon('refresh'));
  $('settings').append(icon('sliders'));
  try { state.tab = localStorage.getItem(TAB_KEY) || 'inbox'; } catch { /* default */ }

  $('connect-form').addEventListener('submit', onConnect);
  $('demo-btn').addEventListener('click', startDemo);
  $('disconnect-btn').addEventListener('click', disconnect);
  $('cancel-btn').addEventListener('click', () => { showDashboard(); render(); });
  $('refresh').addEventListener('click', refresh);
  $('settings').addEventListener('click', () => showConnect({ repo: state.connection?.repo || '' }));

  const tabs = [...document.querySelectorAll('[role="tab"]')];
  for (const tab of tabs) {
    tab.addEventListener('click', () => selectTab(tab.dataset.tab));
    tab.addEventListener('keydown', (e) => {
      const step = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
      if (!step) return;
      const next = tabs[(tabs.indexOf(tab) + step + tabs.length) % tabs.length];
      next.focus();
      selectTab(next.dataset.tab);
    });
  }

  const dialog = $('detail');
  dialog.addEventListener('close', () => { state.openUid = null; });
  dialog.addEventListener('click', (e) => { if (e.target === dialog) dialog.close(); });

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') refresh();
  });

  // The phone's "Open the website" link carries #repo=owner/name (never a token).
  const params = new URLSearchParams(location.hash.slice(1));
  const linkedRepo = params.get('repo');
  if (location.hash) history.replaceState(null, '', location.pathname + location.search);

  if (params.has('demo')) return startDemo();
  const saved = loadConnection();
  if (saved && (!linkedRepo || linkedRepo === saved.repo)) return startLive(saved);
  return showConnect({ repo: linkedRepo || saved?.repo || '' });
}

init();
