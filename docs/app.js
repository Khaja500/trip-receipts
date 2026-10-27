'use strict';

/* Trip Receipts, on the web.
   Reads transactions.json, which the iPhone app rewrites in a GitHub repo
   after every change, and shows it. The phone is the only writer of that
   file: a payment added here goes into web-inbox/ in the same repo, and the
   phone files it and syncs it back. Reading needs no token; adding needs one
   with write access, which is sent to api.github.com and nowhere else. */

const API = 'https://api.github.com';
const DATA_PATH = 'transactions.json';
const CONNECTION_KEY = 'tripReceipts.connection';
const TAB_KEY = 'tripReceipts.tab';
const POLL_MS = 30_000;
// Without a token GitHub allows 60 calls an hour, unchanged ones included.
const PUBLIC_POLL_MS = 90_000;
// Read with no token, first readable wins: every payment, then the work-only copy.
const PUBLIC_REPOS = ['Khaja500/trip-receipts-data', 'Khaja500/trip-receipts-shared'];
const NEW_FOR_MS = 15 * 60_000;
// Payments added here go to the repo with every payment, where the phone looks.
const WRITE_REPO = PUBLIC_REPOS[0];
const WEB_INBOX = 'web-inbox';
const WRITE_TOKEN_KEY = 'tripReceipts.writeToken';
const SENT_KEY = 'tripReceipts.sent';
const SAMPLE_KEY = 'tripReceipts.sampleAdded';
// Photos are scaled down before upload; the phone reads 2000 px receipts fine.
const MAX_IMAGE_EDGE = 2000;
const MAX_FILE_BYTES = 10 * 1024 * 1024;
const CURRENCIES = ['INR', 'USD', 'EUR', 'GBP', 'AED', 'SGD', 'THB', 'JPY'];
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
  cross: '<circle cx="12" cy="12" r="9"/><path d="m9 9 6 6M15 9l-6 6"/>',
  shield: '<path d="M12 3 4.5 6v6c0 4.5 3.2 7.8 7.5 9 4.3-1.2 7.5-4.5 7.5-9V6z"/><path d="m8.8 12.2 2.3 2.3 4.3-4.6"/>',
  inbox: '<path d="M3 13h5l1.5 2.5h5L16 13h5M5.5 5h13L21 13v6H3v-6z"/>',
  download: '<path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
  suitcase: '<rect x="3" y="7" width="18" height="13" rx="2.5"/><path d="M9 7V5a1.5 1.5 0 0 1 1.5-1.5h3A1.5 1.5 0 0 1 15 5v2M3 12.5h18"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="m16 16 4 4"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  upload: '<path d="M12 20V9M7 13.5l5-5 5 5M5 4h14"/>',
  trash: '<path d="M4 7h16M9 7V4.5h6V7M6.5 7l1 13h9l1-13M10 11v5M14 11v5"/>',
  phone: '<rect x="7" y="2.5" width="10" height="19" rx="2.5"/><path d="M11 18.5h2"/>',
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
  sent: [],                // added here, not yet back from the phone: { entry, previews }
  sampleAdded: [],         // sample payments added in this browser
  writeToken: '',
  pickedFiles: [],         // receipts chosen in the add form: { file, url }
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
function tripCovering(date, trips = state.view.trips) {
  const span = (t) => new Date(t.endDate) - new Date(t.startDate);
  return trips
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
    const headers = { Accept: 'application/vnd.github.raw+json', 'X-GitHub-Api-Version': '2022-11-28' };
    if (connection.token) headers.Authorization = `Bearer ${connection.token}`;
    res = await fetch(`${API}/repos/${connection.repo}/contents/${DATA_PATH}`, {
      headers,
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
  // A payment sent from here is back from the phone: it shows as new, once.
  const arrived = new Set(data.payments.map((p) => p.uid));
  const returned = new Set(state.sent.filter((s) => arrived.has(s.entry.uid)).map((s) => s.entry.uid));
  for (const p of data.payments) {
    if (!state.firstSeen.has(p.uid)) state.firstSeen.set(p.uid, first && !returned.has(p.uid) ? 0 : now);
  }
  if (returned.size) {
    state.sent = state.sent.filter((s) => !returned.has(s.entry.uid));
    saveSent();
  }
  state.raw = text;
  state.snapshot = data;
  state.view = derive(withLocal(data));
  render();
}

/** The synced data plus what was added in this browser and isn't in it yet. */
function withLocal(data) {
  const added = state.mode === 'demo' ? state.sampleAdded : state.sent;
  const known = new Set(data.payments.map((p) => p.uid));
  const extra = added.filter((s) => !known.has(s.entry.uid))
    .map((s) => localRecord(s, data.trips, state.mode === 'demo' ? 'sample' : 'sending'));
  return extra.length ? { ...data, payments: [...data.payments, ...extra] } : data;
}

/** An added payment in the shape the phone syncs, as the phone would file it. */
function localRecord({ entry, previews = [] }, trips, origin) {
  const trip = entry.status === 'work' ? tripCovering(new Date(entry.paidAt), trips) : null;
  return {
    uid: entry.uid, status: entry.status, amount: entry.amount, currency: entry.currency,
    merchant: entry.merchant, instrument: entry.instrument || 'Added on the website',
    reference: null, bank: null, paidAt: entry.paidAt, category: entry.category,
    claimableAmount: entry.amount, refundedAmount: 0, netClaimable: entry.amount,
    notes: entry.notes, isManual: true, parseConfidence: 1,
    reviewedAt: entry.status === 'pending' ? null : entry.addedAt, tripID: trip?.id ?? null,
    receipts: entry.receipts.map((r, i) => ({
      filename: r.filename, isPDF: r.isPDF, addedAt: entry.addedAt, ocrTotal: null, preview: previews[i] || null,
    })),
    rawMessage: '', sender: '', receivedAt: entry.addedAt, messageHash: '', additionalMessages: [],
    origin,
  };
}

function rederive() {
  if (!state.snapshot) return;
  state.view = derive(withLocal(state.snapshot));
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

const pollMs = () => (state.connection?.token ? POLL_MS : PUBLIC_POLL_MS);

const isNew = (p) => {
  const seen = state.firstSeen.get(p.uid);
  return seen > 0 && Date.now() - seen < NEW_FOR_MS;
};

// ---------------------------------------------------------------- Connection

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
  $('f-token').placeholder = connected ? 'Saved · paste to replace' : 'Leave empty for a public repo';
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

/** No token: the first public repo that answers, the linked one first. */
async function startPublic(linkedRepo) {
  const repos = [...new Set([linkedRepo, ...PUBLIC_REPOS])].filter((r) => r && REPO_PATTERN.test(r));
  state.connection = { repo: repos[0], token: '', remember: false };
  state.mode = 'live';
  showDashboard();
  for (const repo of repos) {
    try {
      const text = await fetchSnapshot({ repo, token: '' });
      state.connection = { repo, token: '', remember: false };
      state.error = null;
      state.lastChecked = Date.now();
      describeSource(repo);
      applySnapshot(text);
      break;
    } catch (err) {
      state.error = err;
      if (err.status !== 404) break;
    }
  }
  if (!state.snapshot) { renderChrome(); renderLoading(); }
  startPolling();
}

function describeSource(repo) {
  const all = repo === PUBLIC_REPOS[0];
  const link = h('a', { href: `https://github.com/${repo}`, target: '_blank', rel: 'noopener' }, repo);
  $('access-text').replaceChildren(
    `This page shows ${all ? 'all of Khaja\u2019s payments' : 'Khaja\u2019s work expenses'} live from the public repo `,
    link, '. No token needed.');
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
  }, pollMs());
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
    // With no token there is nothing to fix there, so keep retrying instead.
    if (!state.snapshot && err.status && state.connection.token) {
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
      + `Checked ${fmtTime.format(new Date(state.lastChecked))}; checks every ${pollMs() / 1000} s.`;
  } else if (live) {
    text = 'Connecting…';
  }
  $('add-btn').hidden = !state.snapshot;
  pill.className = `pill ${cls}`;
  pill.title = title;
  pill.replaceChildren(h('span', { class: 'dot', 'aria-hidden': 'true' }), h('span', { class: 'pill-text' }, text));

  const banner = $('banner');
  banner.className = 'banner';
  if (state.mode === 'demo') {
    banner.classList.add('demo');
    banner.replaceChildren(icon('info'), h('span', null,
      'Invented sample data, in exactly the shape the phone syncs. ',
      h('button', { class: 'link-btn', type: 'button', onclick: openAdd }, 'Add a sample payment'),
      ' · ',
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
  inbox.replaceChildren('Inbox', ...(count ? [h('span', { class: 'count', 'aria-label': `${count} waiting` }, count)] : []));
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
      ? tag(String(p.receipts.length), 'ok', 'clip')
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
    h('span', { class: 'row-title' }, h('span', null, p.merchant || 'Unknown payee'), isNew(p) && tag('New', 'new'),
      p.origin === 'sending' && tag('Waiting for phone', 'waiting', 'phone'),
      p.origin === 'sample' && tag('Added here', 'work')),
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

  const missingCount = v.work.filter((p) => !p.receipts.length).length;
  const tripSelect = h('select', {
    class: 'select', 'aria-label': 'Trip',
    onchange: (e) => { state.expenseTrip = e.target.value; renderPanel(); },
  },
  h('option', { value: '' }, 'All trips'),
  v.trips.map((t) => h('option', { value: t.id, selected: t.id === state.expenseTrip }, t.name)));

  const head = h('div', { class: 'panel-head' },
    chips([['all', 'All'], ['missing', `Missing receipt${missingCount ? ` · ${missingCount}` : ''}`], ['unfiled', 'Not in a trip']],
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
    claim.push(p.origin === 'sending' ? 'The phone will ask whether this was work' : 'Waiting for an answer on the phone');
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

  const origin = {
    sending: 'Added on this website. The phone files it the next time Trip Receipts syncs — open the app to fetch it now.',
    sample: 'A sample payment, kept only in this browser.',
  }[p.origin];

  dialog.replaceChildren(
    origin && h('div', { class: 'd-origin' }, icon(p.origin === 'sending' ? 'phone' : 'info'), h('span', null, origin),
      p.origin === 'sample' && h('button', {
        type: 'button', class: 'btn btn-ghost btn-sm', onclick: () => removeSample(p.uid),
      }, icon('trash'), 'Remove')),
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
        ? h('p', { class: 'note' }, p.origin
          ? 'Added on the website — there is no bank message for this one.'
          : 'Entered by hand — there is no bank message for this one.')
        : [
          proofBlock({ text: p.rawMessage, sender: p.sender, receivedAt: p.receivedAt, fingerprint: p.messageHash }, 'Original message'),
          ...(p.additionalMessages || []).map((m) => proofBlock(m, 'Also received')),
        ]),
  );
  dialog.scrollTop = scroll;
}

function receiptLine(r, p) {
  let check = null;
  if (typeof r.ocrTotal === 'number' && p.amount > 0) {
    const matches = Math.abs(r.ocrTotal - p.amount) / p.amount <= 0.01;
    check = matches
      ? tag(`Total ${money(r.ocrTotal, p.currency)} matches`, 'ok', 'check')
      : tag(`Total read ${money(r.ocrTotal, p.currency)}`, 'missing', 'alert');
  }
  const where = { sending: 'uploaded, waiting for the phone', sample: 'in this browser only' }[p.origin] || 'kept on the phone';
  return h('div', { class: 'receipt' },
    r.preview ? h('img', { class: 'thumb', src: r.preview, alt: '' }) : icon(r.isPDF ? 'visaForex' : 'clip'),
    h('div', { class: 'grow' }, r.filename, h('small', null, `Added ${dayText(new Date(r.addedAt))} · ${where}`)),
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

// ---------------------------------------------------------------- Adding payments

function loadLocal() {
  const read = (store, key) => { try { return JSON.parse(store.getItem(key) || 'null'); } catch { return null; } };
  state.writeToken = read(localStorage, WRITE_TOKEN_KEY) || read(sessionStorage, WRITE_TOKEN_KEY) || '';
  state.sampleAdded = read(localStorage, SAMPLE_KEY) || [];
  // Sent entries are kept a week; by then the phone has them or never will.
  const week = Date.now() - 7 * 86_400_000;
  state.sent = (read(localStorage, SENT_KEY) || []).filter((s) => new Date(s.entry.addedAt) > week);
}

function saveSent() {
  // Previews are object URLs, gone after a reload anyway.
  try { localStorage.setItem(SENT_KEY, JSON.stringify(state.sent.map(({ entry }) => ({ entry })))); } catch { /* memory only */ }
}

function saveSamples() {
  try {
    localStorage.setItem(SAMPLE_KEY, JSON.stringify(state.sampleAdded));
  } catch {
    // Out of room: keep the payments, drop their pictures.
    try { localStorage.setItem(SAMPLE_KEY, JSON.stringify(state.sampleAdded.map(({ entry }) => ({ entry, previews: [] })))); } catch { /* memory only */ }
  }
}

function saveWriteToken(token, remember) {
  forgetWriteToken();
  state.writeToken = token;
  try { (remember ? localStorage : sessionStorage).setItem(WRITE_TOKEN_KEY, JSON.stringify(token)); } catch { /* memory only */ }
}

function forgetWriteToken() {
  state.writeToken = '';
  try { localStorage.removeItem(WRITE_TOKEN_KEY); } catch { /* ignore */ }
  try { sessionStorage.removeItem(WRITE_TOKEN_KEY); } catch { /* ignore */ }
}

function removeSample(uid) {
  state.sampleAdded = state.sampleAdded.filter((s) => s.entry.uid !== uid);
  saveSamples();
  $('detail').close();
  rederive();
}

function clearPicked() {
  for (const { url } of state.pickedFiles) URL.revokeObjectURL(url);
  state.pickedFiles = [];
}

const pad = (n) => String(n).padStart(2, '0');
const localInputValue = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
/** Whole seconds, as the phone writes and reads its dates. */
const isoSeconds = (d) => d.toISOString().replace(/\.\d{3}Z$/, 'Z');

function openAdd() {
  const live = state.mode === 'live';
  const dialog = $('add');
  clearPicked();

  const field = (label, control, hint) => h('label', { class: 'field' }, h('span', null, label), control, hint && h('small', null, hint));
  const choice = (value, label, sub, checked) => h('label', { class: 'choice' },
    h('input', { type: 'radio', name: 'status', value, checked }),
    h('span', null, h('b', null, label), h('small', null, sub)));

  const thumbs = h('div', { class: 'thumbs' });
  const fileInput = h('input', {
    id: 'a-files', type: 'file', accept: 'image/*,application/pdf', multiple: true, class: 'visually-hidden',
    onchange: (e) => {
      for (const file of e.target.files) {
        state.pickedFiles.push({ file, url: file.type.startsWith('image/') ? URL.createObjectURL(file) : '' });
      }
      e.target.value = '';
      drawThumbs();
    },
  });
  function drawThumbs() {
    thumbs.replaceChildren(...state.pickedFiles.map((picked, i) => h('div', { class: 'thumb-card' },
      picked.url ? h('img', { src: picked.url, alt: '' }) : h('span', { class: 'thumb-pdf' }, icon('visaForex'), 'PDF'),
      h('span', { class: 'thumb-name' }, picked.file.name),
      h('button', {
        type: 'button', class: 'icon-btn', 'aria-label': `Remove ${picked.file.name}`,
        onclick: () => { URL.revokeObjectURL(picked.url); state.pickedFiles.splice(i, 1); drawThumbs(); },
      }, icon('close')))));
  }

  const tokenBlock = live && (state.writeToken
    ? h('p', { class: 'fine' }, 'Using the GitHub token saved on this browser. ',
      h('button', { type: 'button', class: 'link-btn', onclick: () => { forgetWriteToken(); openAdd(); } }, 'Forget it'))
    : h('div', { class: 'token-box' },
      field('GitHub token', h('input', {
        id: 'a-token', type: 'password', autocomplete: 'off', spellcheck: 'false', required: true,
        placeholder: 'github_pat_…',
      }), h('span', null, 'Needs ', h('em', null, 'Contents: Read and write'), ` on ${WRITE_REPO}. `,
        h('a', { href: 'https://github.com/settings/personal-access-tokens/new', target: '_blank', rel: 'noopener' }, 'Create one ↗'))),
      h('label', { class: 'check' }, h('input', { id: 'a-remember', type: 'checkbox', checked: true }),
        h('span', null, 'Remember on this browser'))));

  const form = h('form', { id: 'add-form', class: 'add-form', novalidate: true, onsubmit: onAdd },
    h('div', { class: 'd-head' },
      h('div', null,
        h('h2', { id: 'add-title' }, live ? 'Add a payment' : 'Add a sample payment'),
        h('p', { class: 'd-note' }, live
          ? 'It goes to your iPhone through the repo. The phone files it, reads the receipts, and syncs it back here.'
          : 'Try the website with your own payment. It stays in this browser and is never uploaded.')),
      h('button', { type: 'button', class: 'icon-btn', 'aria-label': 'Close', onclick: () => $('add').close() }, icon('close'))),
    h('div', { class: 'add-grid' },
      h('div', { class: 'amount-row' },
        field('Amount', h('input', { id: 'a-amount', type: 'number', inputmode: 'decimal', min: '0.01', step: '0.01', required: true, placeholder: '0.00' })),
        field('Currency', h('select', { id: 'a-currency', class: 'input' }, CURRENCIES.map((c) => h('option', { value: c }, c))))),
      field('Paid to', h('input', { id: 'a-merchant', required: true, maxlength: '80', placeholder: 'Uber, IndiGo, Taj Hotels…', autocomplete: 'off' })),
      h('div', { class: 'two' },
        field('Category', h('select', { id: 'a-category', class: 'input' },
          Object.entries(CATEGORIES).map(([key, [title]]) => h('option', { value: key, selected: key === 'cab' }, title)))),
        field('Paid on', h('input', { id: 'a-paid', type: 'datetime-local', required: true, value: localInputValue(new Date()) }))),
      field('Paid by', h('input', { id: 'a-instrument', maxlength: '60', placeholder: 'UPI · HDFC, Card ••4455, Cash', autocomplete: 'off' })),
      field('Notes', h('textarea', { id: 'a-notes', rows: '2', maxlength: '500', placeholder: 'Client, purpose, anything finance will ask' })),
      h('fieldset', { class: 'choices' },
        h('legend', null, 'Is it work travel?'),
        choice('work', 'Work travel', 'Filed to the trip covering its date', true),
        choice('pending', 'Not sure yet', live ? 'The phone asks you' : 'Waits in the Inbox'),
        choice('personal', 'Personal', 'Not claimed')),
      h('div', { class: 'field' },
        h('span', null, 'Receipts'),
        h('label', { class: 'drop', for: 'a-files' }, icon('upload'),
          h('span', null, h('b', null, 'Add photos or PDFs'), h('small', null, 'On a phone you can take a photo'))),
        fileInput,
        thumbs,
        live && h('small', { class: 'warn-text' }, `${WRITE_REPO} is public: receipts are visible there until the phone picks them up, and stay in the repo's history.`)),
      tokenBlock,
      h('p', { class: 'form-error', id: 'add-error', role: 'alert', hidden: true }),
    ),
    h('div', { class: 'add-actions' },
      h('button', { type: 'button', class: 'btn btn-ghost', onclick: () => $('add').close() }, 'Cancel'),
      h('button', { type: 'submit', class: 'btn btn-primary', id: 'add-submit' }, live ? 'Send to phone' : 'Add sample payment')));

  dialog.replaceChildren(form);
  if (!dialog.open) dialog.showModal();
  $('a-amount').focus();
}

function addError(message) {
  const el = $('add-error');
  el.hidden = !message;
  el.textContent = message || '';
  if (message) el.scrollIntoView({ block: 'nearest' });
}

async function onAdd(event) {
  event.preventDefault();
  const amount = Math.round(parseFloat($('a-amount').value) * 100) / 100;
  const merchant = $('a-merchant').value.trim();
  const paid = new Date($('a-paid').value);
  if (!(amount > 0)) return addError('Enter the amount paid.');
  if (!merchant) return addError('Enter who was paid.');
  if (Number.isNaN(paid.getTime())) return addError('Enter when it was paid.');
  if (paid > new Date(Date.now() + 86_400_000)) return addError('That date is in the future.');
  const tooBig = state.pickedFiles.find(({ file }) => !file.type.startsWith('image/') && file.size > MAX_FILE_BYTES);
  if (tooBig) return addError(`${tooBig.file.name} is over 10 MB. Attach a smaller copy.`);

  const live = state.mode === 'live';
  let token = state.writeToken;
  if (live && !token) {
    token = $('a-token').value.trim();
    if (!token) return addError('Paste a GitHub token that can write to the repo.');
  }

  const button = $('add-submit');
  button.disabled = true;
  addError('');
  const entry = {
    schema: 1,
    uid: crypto.randomUUID().toUpperCase(),
    amount,
    currency: $('a-currency').value,
    merchant,
    category: $('a-category').value,
    paidAt: isoSeconds(paid),
    instrument: $('a-instrument').value.trim(),
    notes: $('a-notes').value.trim(),
    status: new FormData($('add-form')).get('status') || 'work',
    addedAt: isoSeconds(new Date()),
    receipts: [],
  };

  try {
    button.textContent = 'Preparing receipts…';
    const files = [];
    for (const [i, { file }] of state.pickedFiles.entries()) files.push(await prepareReceipt(file, i, live));
    entry.receipts = files.map((f) => ({ path: `${WEB_INBOX}/${entry.uid}/${f.filename}`, filename: f.filename, isPDF: f.isPDF }));

    if (live) {
      button.textContent = 'Checking token…';
      await checkWriteAccess(token);
      if (!state.writeToken) saveWriteToken(token, $('a-remember').checked);
      // Receipts first, the payment last: the phone takes a payment file to
      // mean its receipts are already there.
      for (const [i, f] of files.entries()) {
        button.textContent = `Uploading receipt ${i + 1} of ${files.length}…`;
        await putFile(token, entry.receipts[i].path, f.base64, `Receipt from the website: ${merchant}`);
      }
      button.textContent = 'Sending…';
      await putFile(token, `${WEB_INBOX}/${entry.uid}.json`, textToBase64(JSON.stringify(entry, null, 2)),
        `Added on the website: ${money(amount, entry.currency)} to ${merchant}`);
      state.sent.push({ entry, previews: files.map((f) => (f.isPDF ? null : URL.createObjectURL(f.blob))) });
      saveSent();
      state.firstSeen.set(entry.uid, Date.now());
    } else {
      state.sampleAdded.push({ entry, previews: files.map((f) => f.thumb || null) });
      saveSamples();
      state.firstSeen.set(entry.uid, Date.now());
    }
    $('add').close();
    state.tab = { work: 'expenses', pending: 'inbox', personal: 'all' }[entry.status];
    rederive();
    openDetail(entry.uid);
  } catch (err) {
    if (err.status === 401 || err.status === 403) forgetWriteToken();
    addError(err.message);
  } finally {
    button.disabled = false;
    button.textContent = live ? 'Send to phone' : 'Add sample payment';
  }
}

/** Photos are scaled to MAX_IMAGE_EDGE as JPEG; a photo the browser can't
    open (HEIC outside Safari) and PDFs go up as they are. */
async function prepareReceipt(file, index, live) {
  const stem = slug(file.name.replace(/\.[^.]+$/, '')).slice(0, 40) || 'receipt';
  const isPDF = file.type === 'application/pdf' || /\.pdf$/i.test(file.name);
  let blob = file;
  let ext = (file.name.match(/\.([A-Za-z0-9]{1,5})$/)?.[1] || (isPDF ? 'pdf' : 'jpg')).toLowerCase();
  let thumb = null;
  if (!isPDF) {
    try {
      const bitmap = await createImageBitmap(file);
      blob = await drawJPEG(bitmap, MAX_IMAGE_EDGE, 0.85);
      ext = 'jpg';
      if (!live) thumb = await blobToDataURL(await drawJPEG(bitmap, 480, 0.7));
      bitmap.close?.();
    } catch {
      if (file.size > MAX_FILE_BYTES) throw new Error(`${file.name} is over 10 MB and this browser can't shrink it. Attach a JPEG or PNG.`);
    }
  }
  return {
    filename: `${index + 1}-${stem}.${ext}`,
    isPDF,
    blob,
    thumb,
    base64: live ? (await blobToDataURL(blob)).split(',')[1] : '',
  };
}

function drawJPEG(bitmap, maxEdge, quality) {
  const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#fff';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  return new Promise((resolve, reject) => canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Couldn’t read that image.'))), 'image/jpeg', quality));
}

function blobToDataURL(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error('Couldn’t read that file.'));
    reader.readAsDataURL(blob);
  });
}

function textToBase64(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

async function github(token, method, path, body) {
  let res;
  try {
    res = await fetch(`${API}${path}`, {
      method,
      headers: {
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        Authorization: `Bearer ${token}`,
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
      cache: 'no-store',
    });
  } catch {
    throw new LoadError("Couldn't reach GitHub. Check the connection and try again.");
  }
  let json = null;
  try { json = await res.json(); } catch { /* empty body */ }
  if (res.ok) return json;
  if (res.status === 401) throw new LoadError("GitHub didn't accept the token. It may have expired — paste a new one.", 401);
  if (res.status === 403 || res.status === 404) {
    throw new LoadError(`This token can't write to ${WRITE_REPO}. It needs Contents: Read and write on that repo.`, 403);
  }
  throw new LoadError(`GitHub answered ${res.status}${json?.message ? `: ${json.message}` : ''}.`, res.status);
}

async function checkWriteAccess(token) {
  const repo = await github(token, 'GET', `/repos/${WRITE_REPO}`);
  if (!repo?.permissions?.push) {
    throw new LoadError(`This token can read ${WRITE_REPO} but not write to it. It needs Contents: Read and write.`, 403);
  }
}

const putFile = (token, path, base64, message) => github(token, 'PUT',
  `/repos/${WRITE_REPO}/contents/${path.split('/').map(encodeURIComponent).join('/')}`, { message, content: base64 });

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

/** The same columns as the claim pack the phone exports. */
function downloadCSV(payments, name) {
  const isoDay = (iso) => {
    const d = new Date(iso);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  };
  const fixed = (n) => Number(n || 0).toFixed(2);
  const rows = [
    ['Date', 'Payee', 'Category', 'Trip', 'Currency', 'Amount', 'Claimed', 'Refunded', 'Net claimed', 'Paid by',
      'Bank', 'Reference', 'Receipts', 'Notes', 'Original message', 'Proof SHA-256'],
    ...[...payments].sort((a, b) => new Date(a.paidAt) - new Date(b.paidAt)).map((p) => [
      isoDay(p.paidAt), p.merchant, categoryTitle(p.category), state.view.tripsById.get(p.tripID)?.name || '',
      p.currency, fixed(p.amount), fixed(p.claimableAmount), fixed(p.refundedAmount), fixed(p.netClaimable),
      p.instrument, p.bank || '', p.reference || '', p.receipts.length, p.notes,
      p.isManual ? '(entered manually)' : p.rawMessage, p.messageHash,
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
  $('add-btn').prepend(icon('plus'));
  try { state.tab = localStorage.getItem(TAB_KEY) || 'inbox'; } catch { /* default */ }
  loadLocal();

  $('add-btn').addEventListener('click', openAdd);
  const add = $('add');
  add.addEventListener('click', (e) => { if (e.target === add) add.close(); });
  add.addEventListener('close', clearPicked);

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
  // Tokens saved by earlier versions aren't used any more.
  forgetConnection();
  return startPublic(linkedRepo);
}

init();
