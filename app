import { CATEGORIES, CAT, GROUPS, FREE_ITEM_LIMIT, isFreeCategory, STATUSES, BILLING, EXTRA_REMINDER_DATES } from './categories.js';

const SUPABASE_CDN = 'https://esm.sh/@supabase/supabase-js@2';
const state = {
  cfg: null, sb: null, session: null, recovery: false,
  workspaces: [], ws: null, items: [], members: [], invites: [],
  view: 'dashboard', filters: { q: '', group: '', location: '', status: 'open' },
  people: { q: '', location: '', group: '', sort: 'name', open: new Set() },
};
const root = document.getElementById('app');

// ---------------- utilities ----------------
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pad = n => String(n).padStart(2, '0');
const toISO = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const todayStr = () => toISO(new Date());
const daysBetween = (a, b) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86400000);
const daysLeft = d => daysBetween(todayStr(), d);
function addMonths(dateStr, n) {
  const [y, m, d] = dateStr.split('-').map(Number);
  const target = new Date(Date.UTC(y, m - 1 + n, 1));
  const lastDay = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
  target.setUTCDate(Math.min(d, lastDay));
  return target.toISOString().slice(0, 10);
}
const money = n => (n === null || n === undefined || n === '' || isNaN(n)) ? '' :
  '$' + Number(n).toLocaleString('en-CA', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
const fmtDate = d => d ? new Date(`${d}T12:00:00`).toLocaleDateString('en-CA', { year: 'numeric', month: 'short', day: 'numeric' }) : '';
const isPro = () => state.ws?.plan === 'pro';
const me = () => state.session?.user;
const isOwner = () => state.members.some(m => m.user_id === me()?.id && m.role === 'owner');
const openItems = () => state.items.filter(i => i.status !== 'retired');
const lsGet = k => { try { return localStorage.getItem(k); } catch { return null; } };
const lsSet = (k, v) => { try { localStorage.setItem(k, v); } catch { /* storage unavailable */ } };

function badge(left) {
  if (left === null || left === undefined) return '<span class="badge b-gray">No date</span>';
  if (left < 0) return `<span class="badge b-red">${-left}d overdue</span>`;
  if (left === 0) return '<span class="badge b-red">Today</span>';
  if (left <= 30) return `<span class="badge b-amber">${left}d left</span>`;
  if (left <= 90) return `<span class="badge b-blue">${left}d left</span>`;
  return `<span class="badge b-gray">${left}d left</span>`;
}

let toastTimer;
function toast(msg, isErr = false) {
  document.querySelector('.toast')?.remove();
  const el = document.createElement('div');
  el.className = 'toast' + (isErr ? ' err' : '');
  el.textContent = msg;
  document.body.appendChild(el);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.remove(), 4000);
}

function friendlyError(err) {
  const m = err?.message || String(err);
  if (m.includes('FREE_LIMIT')) return `The free plan holds up to ${FREE_ITEM_LIMIT} items. Upgrade to Pro for unlimited items.`;
  if (m.includes('PRO_CATEGORY')) return 'That category is part of Pro. Upgrade to track servers, software, domains, contracts and more.';
  if (m.includes('PRO_SETTING')) return 'Custom reminder schedules are part of Pro.';
  return m;
}

// Every date on an item that matters: the main key date plus OS end of support.
function keyDates(item) {
  const cat = CAT[item.category] || { label: item.category, dateLabel: 'Key date' };
  const out = [];
  if (item.expiry_date) out.push({ item, label: cat.dateLabel, date: item.expiry_date, left: daysLeft(item.expiry_date) });
  for (const x of EXTRA_REMINDER_DATES) {
    const d = item.details?.[x.k];
    if (d) out.push({ item, label: x.label, date: d, left: daysLeft(d) });
  }
  return out;
}

// ---------------- boot and auth ----------------
async function boot() {
  root.innerHTML = '<div class="auth-wrap"><p class="muted">Loading…</p></div>';
  state.recovery = location.hash.includes('type=recovery');
  try { state.cfg = await (await fetch('/api/config')).json(); } catch { state.cfg = null; }
  if (!state.cfg?.supabaseUrl || !state.cfg?.supabaseAnonKey) return renderSetup();

  let createClient;
  try { ({ createClient } = await import(SUPABASE_CDN)); } catch {
    root.innerHTML = '<div class="auth-wrap"><div class="card">Could not load the sign-in library. Check your connection and refresh.</div></div>';
    return;
  }
  state.sb = createClient(state.cfg.supabaseUrl, state.cfg.supabaseAnonKey);
  state.sb.auth.onAuthStateChange((event, session) => {
    const prevUser = state.session?.user?.id;
    state.session = session;
    if (event === 'PASSWORD_RECOVERY' || (state.recovery && session)) { state.recovery = true; return renderRecovery(); }
    if (event === 'SIGNED_OUT' || !session) { resetData(); return renderAuth(); }
    if (event === 'INITIAL_SESSION' || (event === 'SIGNED_IN' && session.user.id !== prevUser)) {
      setTimeout(loadAll, 0); // don't call Supabase inside this callback
    }
  });
}

function resetData() {
  Object.assign(state, { workspaces: [], ws: null, items: [], members: [], invites: [] });
}

function renderSetup() {
  root.innerHTML = `<div class="auth-wrap"><div class="card" style="max-width:520px">
    <h2>Almost there</h2>
    <p>RenewalWatch is deployed but isn't connected to its database yet.</p>
    <p class="muted small">Add <code>SUPABASE_URL</code> and <code>SUPABASE_ANON_KEY</code> to the Vercel project's environment variables, then redeploy.</p>
  </div></div>`;
}

function renderAuth(tab = 'signin', message = '', isErr = false) {
  root.innerHTML = `<div class="auth-wrap"><div class="card auth-card">
    <a class="logo" href="/" style="color:var(--ink);margin-bottom:14px"><span class="logo-mark" style="color:#fff">R</span>RenewalWatch</a>
    <div class="tabs">
      <button data-action="auth-tab" data-tab="signin" class="${tab === 'signin' ? 'active' : ''}">Sign in</button>
      <button data-action="auth-tab" data-tab="signup" class="${tab === 'signup' ? 'active' : ''}">Create account</button>
    </div>
    ${message ? `<div class="msg ${isErr ? 'err' : 'ok'}">${esc(message)}</div>` : ''}
    <form id="auth-form" data-tab="${tab}">
      <div class="field"><label>Work email</label><input name="email" type="email" required autocomplete="email"></div>
      ${tab !== 'forgot' ? `<div class="field"><label>Password</label><input name="password" type="password" required minlength="8" autocomplete="${tab === 'signup' ? 'new-password' : 'current-password'}"></div>` : ''}
      <button class="btn primary" style="width:100%;justify-content:center">${tab === 'signin' ? 'Sign in' : tab === 'signup' ? 'Create free account' : 'Send reset link'}</button>
    </form>
    <p class="small muted" style="margin-top:14px;text-align:center">
      ${tab === 'forgot' ? '<a href="#" data-action="auth-tab" data-tab="signin">Back to sign in</a>' : '<a href="#" data-action="auth-tab" data-tab="forgot">Forgot password?</a>'}
    </p>
  </div></div>`;
}

async function submitAuth(form) {
  const tab = form.dataset.tab;
  const email = form.email.value.trim();
  const password = form.password?.value;
  const btn = form.querySelector('button');
  btn.disabled = true;
  try {
    if (tab === 'signin') {
      const { error } = await state.sb.auth.signInWithPassword({ email, password });
      if (error) throw error;
    } else if (tab === 'signup') {
      const { data, error } = await state.sb.auth.signUp({ email, password, options: { emailRedirectTo: `${location.origin}/app` } });
      if (error) throw error;
      if (!data.session) renderAuth('signin', 'Check your email for a confirmation link, then sign in.');
    } else {
      const { error } = await state.sb.auth.resetPasswordForEmail(email, { redirectTo: `${location.origin}/app` });
      if (error) throw error;
      renderAuth('signin', 'If that email has an account, a reset link is on its way.');
    }
  } catch (err) {
    renderAuth(tab, err.message || 'Something went wrong', true);
  }
}

function renderRecovery() {
  root.innerHTML = `<div class="auth-wrap"><div class="card auth-card">
    <h2>Set a new password</h2>
    <form id="recovery-form">
      <div class="field"><label>New password</label><input name="password" type="password" minlength="8" required autocomplete="new-password"></div>
      <button class="btn primary" style="width:100%;justify-content:center">Save password</button>
    </form></div></div>`;
}

// ---------------- data loading ----------------
async function loadAll() {
  const sb = state.sb;
  await sb.rpc('accept_invites');
  const { data: wss, error } = await sb.from('workspaces').select('*').order('created_at');
  if (error) return fatal(error.message);
  if (!wss.length) return fatal('No workspace found for this account. Make sure the database setup script was run before you signed up.');
  state.workspaces = wss;
  const saved = lsGet('rw_ws');
  state.ws = wss.find(w => w.id === saved) || wss[0];
  await loadWorkspace();
  state.view = (location.hash.replace('#', '') || 'dashboard');
  render();
  handleUpgradeReturn();
}

async function loadWorkspace() {
  const sb = state.sb, id = state.ws.id;
  const [items, members, invites] = await Promise.all([
    fetchAllItems(id),
    sb.from('members').select('*').eq('workspace_id', id).order('created_at'),
    sb.from('invites').select('*').eq('workspace_id', id).order('created_at'),
  ]);
  state.items = items;
  state.members = members.data || [];
  state.invites = invites.data || [];
}

async function fetchAllItems(wsId) {
  const all = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await state.sb.from('items').select('*').eq('workspace_id', wsId)
      .order('expiry_date', { ascending: true, nullsFirst: false }).order('id').range(from, from + 999);
    if (error) { toast(error.message, true); break; }
    all.push(...data);
    if (data.length < 1000) break;
  }
  return all;
}

async function refreshWorkspaceRow() {
  const { data } = await state.sb.from('workspaces').select('*').eq('id', state.ws.id).single();
  if (data) {
    state.ws = data;
    state.workspaces = state.workspaces.map(w => w.id === data.id ? data : w);
  }
}

async function handleUpgradeReturn() {
  const params = new URLSearchParams(location.search);
  if (!params.has('upgraded')) return;
  history.replaceState(null, '', location.pathname + location.hash);
  toast('Payment received. Activating Pro…');
  for (let i = 0; i < 12 && !isPro(); i++) {
    await new Promise(r => setTimeout(r, 2500));
    await refreshWorkspaceRow();
  }
  render();
  toast(isPro() ? 'Pro is active. Thanks for upgrading!' : 'Pro is still activating. Refresh in a minute.', !isPro());
}

function fatal(msg) {
  root.innerHTML = `<div class="auth-wrap"><div class="card" style="max-width:520px"><h2>Something's not right</h2><p>${esc(msg)}</p>
    <button class="btn" data-action="signout">Sign out</button></div></div>`;
}

// ---------------- layout ----------------
function render() {
  if (!state.ws) return;
  const views = { dashboard: viewDashboard, inventory: viewInventory, people: viewPeople, settings: viewSettings };
  if (!views[state.view]) state.view = 'dashboard';
  const nav = [['dashboard', 'Dashboard'], ['inventory', 'Inventory'], ['people', 'People'], ['settings', 'Settings']];
  root.innerHTML = `
    <header class="topbar"><div class="topbar-inner">
      <a class="logo" href="#dashboard"><span class="logo-mark">R</span>RenewalWatch</a>
      <nav class="nav">${nav.map(([id, label]) =>
        `<a href="#${id}" class="${state.view === id ? 'active' : ''}">${label}${id === 'people' && !isPro() ? ' 🔒' : ''}</a>`).join('')}</nav>
      <div class="ws-pill">${esc(state.ws.name)} <span class="plan ${isPro() ? 'pro' : ''}">${isPro() ? 'Pro' : 'Free'}</span></div>
    </div></header>
    <main>${views[state.view]()}</main>`;
}

window.addEventListener('hashchange', () => {
  if (!state.ws) return;
  state.view = location.hash.replace('#', '') || 'dashboard';
  render();
  window.scrollTo(0, 0);
});

function upsell(title, points) {
  return `<div class="card locked"><h2>🔒 ${esc(title)}</h2>
    <ul>${points.map(p => `<li>${esc(p)}</li>`).join('')}</ul>
    <button class="btn primary" data-action="upgrade">Upgrade to Pro · ${esc(state.cfg.priceLabel)}</button></div>`;
}

// ---------------- dashboard ----------------
function viewDashboard() {
  const open = openItems();
  const dates = open.flatMap(keyDates);
  const overdue = dates.filter(d => d.left < 0);
  const due30 = dates.filter(d => d.left >= 0 && d.left <= 30);
  const due90 = dates.filter(d => d.left > 30 && d.left <= 90);
  const upcoming = dates.filter(d => d.left <= 90).sort((a, b) => a.left - b.left);
  const noDate = open.filter(i => !i.expiry_date).length;

  if (!state.items.length) {
    return `<div class="page-head"><h1>Welcome to RenewalWatch</h1></div>
      <div class="card empty">
        <h2 style="color:var(--ink)">Add your first item</h2>
        <p>Start with something that bites when it expires: a laptop warranty, a firewall subscription, or your domain name.</p>
        <button class="btn primary" data-action="new-item">+ Add item</button>
        ${isPro() ? ' <a class="btn" href="#settings">Import a spreadsheet</a>' : ''}
      </div>`;
  }

  return `
    <div class="page-head"><h1>Dashboard</h1><button class="btn primary" data-action="new-item">+ Add item</button></div>
    <div class="stats">
      <div class="stat red"><div class="num">${overdue.length}</div><div class="lbl">Overdue</div></div>
      <div class="stat amber"><div class="num">${due30.length}</div><div class="lbl">Due in 30 days</div></div>
      <div class="stat blue"><div class="num">${due90.length}</div><div class="lbl">Due in 31–90 days</div></div>
      <div class="stat"><div class="num">${isPro() ? open.length : state.items.length}${isPro() ? '' : `<span class="muted" style="font-size:16px"> / ${FREE_ITEM_LIMIT}</span>`}</div><div class="lbl">Items tracked</div></div>
    </div>
    <div class="card">
      <h2>Coming up in the next 90 days</h2>
      ${upcoming.length ? `<div class="table-wrap"><table>
        <tr><th>Item</th><th>What</th><th>Date</th><th>Status</th><th>Cost</th><th></th></tr>
        ${upcoming.map(d => `<tr>
          <td><a href="#" data-action="edit-item" data-id="${d.item.id}"><strong>${esc(d.item.name)}</strong></a><div class="sub">${esc(CAT[d.item.category]?.label || d.item.category)}${d.item.vendor ? ' · ' + esc(d.item.vendor) : ''}</div></td>
          <td>${esc(d.label)}${d.item.auto_renew ? '<div class="sub">Auto-renews</div>' : ''}</td>
          <td>${fmtDate(d.date)}</td>
          <td>${badge(d.left)}</td>
          <td>${money(d.item.renewal_cost)}</td>
          <td>${d.date === d.item.expiry_date ? `<button class="btn small" data-action="renew" data-id="${d.item.id}">${d.item.category === 'task' || d.item.category === 'backup' ? 'Done' : 'Renewed'}</button>` : ''}</td>
        </tr>`).join('')}
      </table></div>` : '<p class="muted">Nothing due in the next 90 days. 🎉</p>'}
      ${noDate ? `<p class="small muted" style="margin-top:10px">${noDate} item${noDate === 1 ? ' has' : 's have'} no date set, so ${noDate === 1 ? 'it' : 'they'} won't trigger reminders.</p>` : ''}
    </div>
    ${isPro() ? `<div class="cols">${spendCard(open)}${licenseCard(open)}</div>${healthCard(open)}`
      : upsell('Pro insights', [
        'Renewal spend forecast for the next 12 months',
        'License check: unused and over-allocated seats, with wasted dollars',
        'Health checks: unpatched servers, OS end of support, stale firmware, untested backups, aging laptops',
        'Servers, VMs, network gear, software, SaaS, domains, SSL, contracts and recurring IT tasks',
        'Unlimited items, team members, custom reminder schedules, offboarding checklists, CSV import',
      ])}`;
}

function spendCard(open) {
  const start = new Date(); start.setDate(1);
  const months = [];
  for (let i = 0; i < 12; i++) { const d = new Date(start.getFullYear(), start.getMonth() + i, 1); months.push(`${d.getFullYear()}-${pad(d.getMonth() + 1)}`); }
  const buckets = Object.fromEntries(months.map(m => [m, 0]));
  const startStr = `${months[0]}-01`, endStr = addMonths(startStr, 12);
  for (const it of open) {
    const cost = Number(it.renewal_cost);
    if (!it.expiry_date || !cost) continue;
    const step = it.billing_cycle === 'monthly' ? 1 : it.recur_months || (it.billing_cycle === 'annual' ? 12 : null);
    let d = it.expiry_date;
    if (step) {
      let guard = 0;
      while (d < startStr && guard++ < 600) d = addMonths(d, step);
      while (d < endStr && guard++ < 600) { buckets[d.slice(0, 7)] += cost; d = addMonths(d, step); }
    } else if (d >= startStr && d < endStr) buckets[d.slice(0, 7)] += cost;
  }
  const vals = months.map(m => buckets[m]);
  const max = Math.max(...vals, 1), total = vals.reduce((a, b) => a + b, 0);
  return `<div class="card"><h2>Renewal spend, next 12 months</h2>
    <div class="muted small">Total: <strong style="color:var(--ink)">${money(total)}</strong> based on renewal costs you've entered</div>
    <div class="bars">${months.map((m, i) => `<div class="bar" title="${m}: ${money(vals[i])}">
      <div class="bar-val">${vals[i] ? money(Math.round(vals[i])) : ''}</div>
      <div class="bar-fill" style="height:${(vals[i] / max) * 100}%"></div>
      <div class="bar-lbl">${new Date(`${m}-15`).toLocaleDateString('en-CA', { month: 'short' })}</div></div>`).join('')}</div></div>`;
}

function licenseCard(open) {
  const rows = open.filter(i => i.details?.seats_total !== undefined && i.details?.seats_total !== '').map(i => {
    const total = Number(i.details.seats_total) || 0, used = Number(i.details.seats_used) || 0;
    const unused = total - used;
    const waste = unused > 0 && total && i.renewal_cost ? (unused / total) * Number(i.renewal_cost) : 0;
    return { i, total, used, unused, waste };
  }).filter(r => r.unused !== 0).sort((a, b) => a.unused - b.unused);
  return `<div class="card"><h2>License check</h2>
    ${rows.length ? `<ul class="list-plain">${rows.map(r => `<li>
      <span><a href="#" data-action="edit-item" data-id="${r.i.id}">${esc(r.i.name)}</a><div class="sub">${r.used} of ${r.total} seats in use</div></span>
      <span style="text-align:right">${r.unused < 0 ? `<span class="badge b-red">${-r.unused} over</span><div class="sub">Compliance risk</div>`
        : `<span class="badge b-amber">${r.unused} unused</span>${r.waste ? `<div class="sub">≈ ${money(Math.round(r.waste))} per renewal</div>` : ''}`}</span>
    </li>`).join('')}</ul>` : '<p class="muted">Add "Seats purchased" and "Seats in use" to your software, SaaS and security items to spot waste and over-allocation.</p>'}
  </div>`;
}

function healthCard(open) {
  const t = todayStr(), checks = [];
  const age = d => d ? daysBetween(d, t) : null;
  for (const i of open) {
    const d = i.details || {};
    if (['server', 'vm'].includes(i.category)) {
      const a = age(d.last_patched);
      if (a === null) checks.push([i, 'No "last patched" date recorded', 'gray']);
      else if (a > 35) checks.push([i, `Last patched ${a} days ago`, a > 90 ? 'red' : 'amber']);
      if (d.os_eos) { const l = daysLeft(d.os_eos); if (l < 0) checks.push([i, `OS is past end of support (${fmtDate(d.os_eos)})`, 'red']); else if (l <= 365) checks.push([i, `OS end of support in ${l} days`, 'amber']); }
    }
    if (i.category === 'network') {
      const a = age(d.last_firmware);
      if (a === null) checks.push([i, 'No firmware update date recorded', 'gray']);
      else if (a > 180) checks.push([i, `Firmware last updated ${a} days ago`, 'amber']);
    }
    if (i.category === 'backup') {
      const a = age(d.last_restore_test), s = age(d.last_success);
      if (a === null || a > 90) checks.push([i, a === null ? 'Restore has never been tested' : `Last restore test ${a} days ago`, a === null || a > 180 ? 'red' : 'amber']);
      if (s !== null && s > 2) checks.push([i, `Last successful backup ${s} days ago`, 'red']);
    }
    if (i.category === 'ups') {
      const a = age(d.last_self_test);
      if (a !== null && a > 180) checks.push([i, `Last self-test ${a} days ago`, 'amber']);
    }
    if (i.category === 'computer' && i.purchase_date) {
      const years = age(i.purchase_date) / 365;
      if (years >= 5) checks.push([i, `${Math.floor(years)} years old, plan a replacement`, 'amber']);
    }
    if (['domain', 'ssl'].includes(i.category) && i.expiry_date && !i.auto_renew && daysLeft(i.expiry_date) <= 60) {
      checks.push([i, 'Expiring soon and not set to auto-renew', 'red']);
    }
  }
  const order = { red: 0, amber: 1, gray: 2 };
  checks.sort((a, b) => order[a[2]] - order[b[2]]);
  return `<div class="card"><h2>Health checks</h2>
    ${checks.length ? `<ul class="list-plain">${checks.slice(0, 25).map(([i, text, lvl]) => `<li>
      <span><a href="#" data-action="edit-item" data-id="${i.id}">${esc(i.name)}</a><div class="sub">${esc(CAT[i.category]?.label || '')}</div></span>
      <span class="badge b-${lvl}">${esc(text)}</span></li>`).join('')}</ul>
      ${checks.length > 25 ? `<p class="small muted">And ${checks.length - 25} more.</p>` : ''}`
      : '<p class="muted">No issues found. Health checks look at patch dates, OS end of support, firmware, backups, UPS tests, laptop age and domain or SSL auto-renewal.</p>'}
  </div>`;
}

// ---------------- inventory ----------------
function filteredItems() {
  const { q, group, location: loc, status } = state.filters;
  const needle = q.trim().toLowerCase();
  return state.items.filter(i => {
    if (status === 'open' && i.status === 'retired') return false;
    if (status && status !== 'open' && i.status !== status) return false;
    if (group && CAT[i.category]?.group !== group) return false;
    if (loc && nameKey(i.location) !== nameKey(loc)) return false;
    if (needle) {
      const hay = [i.name, i.vendor, i.model, i.serial, i.asset_tag, i.assigned_to, i.location, i.notes, CAT[i.category]?.label,
        ...Object.values(i.details || {})].join(' ').toLowerCase();
      if (!hay.includes(needle)) return false;
    }
    return true;
  });
}

function viewInventory() {
  const locations = [...canonicalNames('location').values()].sort();
  const f = state.filters;
  return `
    <div class="page-head"><h1>Inventory</h1>
      <div class="chip-row"><button class="btn" data-action="export-csv">Export CSV</button><button class="btn primary" data-action="new-item">+ Add item</button></div></div>
    <div class="filters">
      <input id="f-q" placeholder="Search name, serial, person, IP…" value="${esc(f.q)}">
      <select id="f-group"><option value="">All categories</option>${GROUPS.map(g => `<option ${f.group === g ? 'selected' : ''}>${esc(g)}</option>`).join('')}</select>
      <select id="f-location"><option value="">All locations</option>${locations.map(l => `<option ${f.location === l ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select>
      <select id="f-status">
        <option value="open" ${f.status === 'open' ? 'selected' : ''}>All except retired</option>
        <option value="" ${f.status === '' ? 'selected' : ''}>Everything</option>
        ${STATUSES.map(s => `<option value="${s.id}" ${f.status === s.id ? 'selected' : ''}>${esc(s.label)}</option>`).join('')}
      </select>
    </div>
    <div class="card" style="padding:0" id="inv-table">${inventoryTable()}</div>`;
}

function inventoryTable() {
  const rows = filteredItems();
  if (!rows.length) return `<div class="empty">${state.items.length ? 'No items match these filters.' : 'No items yet.'}</div>`;
  return `<div class="table-wrap"><table>
    <tr><th>Name</th><th>Category</th><th>Assigned to</th><th>Location</th><th>Key date</th><th>Status</th></tr>
    ${rows.map(i => {
      const cat = CAT[i.category];
      const ident = [i.serial && `S/N ${i.serial}`, i.asset_tag && `Tag ${i.asset_tag}`, i.details?.hostname, i.details?.ip || i.details?.mgmt_ip].filter(Boolean).join(' · ');
      return `<tr class="clickable" data-action="edit-item" data-id="${i.id}">
        <td><strong>${esc(i.name)}</strong>${ident ? `<div class="sub">${esc(ident)}</div>` : ''}</td>
        <td>${esc(cat?.label || i.category)}</td>
        <td>${esc(i.assigned_to || '')}</td>
        <td>${esc(i.location || '')}</td>
        <td>${i.expiry_date ? `${fmtDate(i.expiry_date)}<div>${badge(daysLeft(i.expiry_date))}</div>` : '<span class="muted">—</span>'}</td>
        <td>${esc(STATUSES.find(s => s.id === i.status)?.label || i.status)}</td>
      </tr>`;
    }).join('')}
  </table></div>`;
}

// ---------------- item form ----------------
function detailFieldsHtml(catId, details) {
  const cat = CAT[catId];
  if (!cat?.fields.length) return '';
  return `<div class="section-title">${esc(cat.label)} details</div><div class="grid2">${cat.fields.map(fd => {
    const v = details?.[fd.k] ?? '';
    const input = fd.type === 'select'
      ? `<select name="d_${fd.k}"><option value=""></option>${fd.options.map(o => `<option ${v === o ? 'selected' : ''}>${esc(o)}</option>`).join('')}</select>`
      : `<input name="d_${fd.k}" type="${fd.type === 'url' ? 'url' : fd.type}" ${fd.type === 'number' ? 'step="any"' : ''} value="${esc(v)}">`;
    return `<div class="field"><label>${esc(fd.label)}</label>${input}</div>`;
  }).join('')}</div>`;
}

function openItemModal(item = null) {
  const it = item || { category: 'computer', status: 'active', details: {} };
  const pro = isPro();
  const people = [...canonicalNames('assigned_to').values()].sort();
  const locations = [...canonicalNames('location').values()].sort();
  const catOptions = GROUPS.map(g => `<optgroup label="${esc(g)}">${CATEGORIES.filter(c => c.group === g).map(c => {
    const locked = !pro && !isFreeCategory(c.id) && c.id !== it.category;
    return `<option value="${c.id}" ${c.id === it.category ? 'selected' : ''} ${locked ? 'disabled' : ''}>${esc(c.label)}${!isFreeCategory(c.id) && !pro ? ' (Pro)' : ''}</option>`;
  }).join('')}</optgroup>`).join('');
  const cat = CAT[it.category] || CAT.other_hw;
  const v = k => esc(it[k] ?? '');

  const wrap = document.createElement('div');
  wrap.className = 'modal-bg';
  wrap.innerHTML = `<div class="modal" role="dialog" aria-modal="true">
    <div class="modal-head"><h2 style="margin:0">${item ? 'Edit item' : 'Add item'}</h2><button class="x" data-action="close-modal" aria-label="Close">×</button></div>
    <form id="item-form">
      <div class="grid2">
        <div class="field"><label>Category</label><select name="category" id="cat-select">${catOptions}</select></div>
        <div class="field"><label>Name *</label><input name="name" required maxlength="200" value="${v('name')}" placeholder="e.g. Reception laptop, FW-01, Microsoft 365 Business"></div>
      </div>
      ${!pro ? '<p class="small muted" style="margin-top:-4px">Servers, network gear, software, SaaS, domains, SSL, contracts and recurring tasks are part of Pro.</p>' : ''}
      <div class="grid3">
        <div class="field"><label>Vendor / manufacturer</label><input name="vendor" value="${v('vendor')}"></div>
        <div class="field"><label>Model / product</label><input name="model" value="${v('model')}"></div>
        <div class="field"><label>Serial number</label><input name="serial" value="${v('serial')}"></div>
        <div class="field"><label>Asset tag</label><input name="asset_tag" value="${v('asset_tag')}"></div>
        <div class="field"><label>Assigned to</label><input name="assigned_to" list="dl-people" value="${v('assigned_to')}"></div>
        <div class="field"><label>Location / branch</label><input name="location" list="dl-loc" value="${v('location')}"></div>
      </div>
      <datalist id="dl-people">${people.map(p => `<option value="${esc(p)}">`).join('')}</datalist>
      <datalist id="dl-loc">${locations.map(p => `<option value="${esc(p)}">`).join('')}</datalist>

      <div class="section-title">Dates and money</div>
      <div class="grid3">
        <div class="field"><label id="date-label">${esc(cat.dateLabel)}</label><input name="expiry_date" type="date" value="${v('expiry_date')}"></div>
        <div class="field"><label>Renewal cost ($)</label><input name="renewal_cost" type="number" step="0.01" min="0" value="${v('renewal_cost')}"></div>
        <div class="field"><label>Billing</label><select name="billing_cycle"><option value=""></option>${BILLING.map(b => `<option value="${b.id}" ${it.billing_cycle === b.id ? 'selected' : ''}>${b.label}</option>`).join('')}</select></div>
        <div class="field"><label>Purchase date</label><input name="purchase_date" type="date" value="${v('purchase_date')}"></div>
        <div class="field"><label>Purchase cost ($)</label><input name="cost" type="number" step="0.01" min="0" value="${v('cost')}"></div>
        <div class="field"><label>Repeats every (months)</label><input name="recur_months" type="number" min="1" max="120" value="${v('recur_months')}" placeholder="Blank = doesn't repeat"></div>
      </div>
      <div class="grid2">
        <div class="field"><label>Status</label><select name="status">${STATUSES.map(s => `<option value="${s.id}" ${it.status === s.id ? 'selected' : ''}>${s.label}</option>`).join('')}</select></div>
        <div class="field" style="padding-top:26px"><label style="display:flex;gap:8px;align-items:center;font-weight:500"><input type="checkbox" name="auto_renew" ${it.auto_renew ? 'checked' : ''}> Auto-renews</label></div>
      </div>
      ${it.last_done ? `<p class="small muted">Last marked done/renewed: ${fmtDate(it.last_done)}</p>` : ''}

      <div id="details-fields">${detailFieldsHtml(it.category, it.details)}</div>

      <div class="field" style="margin-top:12px"><label>Notes</label><textarea name="notes">${v('notes')}</textarea></div>
      <div class="note">Don't store passwords or license keys here. Keep those in a password manager and note where they're kept.</div>
      <div class="modal-foot">
        <div>${item ? '<button type="button" class="btn danger" data-action="delete-item">Delete</button>' : ''}</div>
        <div class="chip-row"><button type="button" class="btn" data-action="close-modal">Cancel</button><button class="btn primary">Save</button></div>
      </div>
    </form></div>`;
  wrap.dataset.id = item?.id || '';
  document.body.appendChild(wrap);

  const form = wrap.querySelector('#item-form');
  form.category.addEventListener('change', () => {
    const current = readDetails(form);
    const newCat = CAT[form.category.value];
    wrap.querySelector('#details-fields').innerHTML = detailFieldsHtml(newCat.id, current);
    wrap.querySelector('#date-label').textContent = newCat.dateLabel;
  });
  form.addEventListener('submit', e => { e.preventDefault(); saveItem(form, item); });
  form.name.focus();
}

function readDetails(form) {
  const out = {};
  for (const el of form.querySelectorAll('[name^="d_"]')) {
    const k = el.name.slice(2), val = el.value.trim();
    if (val !== '') out[k] = el.type === 'number' ? Number(val) : val;
  }
  return out;
}

function closeModal() { document.querySelector('.modal-bg')?.remove(); }

async function saveItem(form, existing) {
  const num = v => v === '' ? null : Number(v);
  const txt = v => v.trim() === '' ? null : v.trim();
  const row = {
    workspace_id: state.ws.id,
    category: form.category.value,
    name: form.name.value.trim(),
    vendor: txt(form.vendor.value), model: txt(form.model.value), serial: txt(form.serial.value), asset_tag: txt(form.asset_tag.value),
    assigned_to: txt(form.assigned_to.value), location: txt(form.location.value),
    expiry_date: form.expiry_date.value || null, renewal_cost: num(form.renewal_cost.value),
    billing_cycle: form.billing_cycle.value || null, purchase_date: form.purchase_date.value || null, cost: num(form.cost.value),
    recur_months: num(form.recur_months.value), status: form.status.value, auto_renew: form.auto_renew.checked,
    notes: txt(form.notes.value), details: readDetails(form),
  };
  snapNames(row, existing?.id);
  const btn = form.querySelector('button.primary');
  btn.disabled = true;
  const q = existing
    ? state.sb.from('items').update(row).eq('id', existing.id).select().single()
    : state.sb.from('items').insert(row).select().single();
  const { data, error } = await q;
  btn.disabled = false;
  if (error) return toast(friendlyError(error), true);
  if (existing) state.items = state.items.map(i => i.id === data.id ? data : i);
  else state.items.push(data);
  closeModal();
  toast(existing ? 'Saved' : 'Item added');
  render();
}

async function deleteItem(id) {
  const it = state.items.find(i => i.id === id);
  if (!confirm(`Delete "${it?.name}"? This can't be undone. To keep history, set its status to Retired instead.`)) return;
  const { error } = await state.sb.from('items').delete().eq('id', id);
  if (error) return toast(friendlyError(error), true);
  state.items = state.items.filter(i => i.id !== id);
  closeModal();
  toast('Deleted');
  render();
}

async function markRenewed(id) {
  const it = state.items.find(i => i.id === id);
  if (!it) return;
  const step = it.recur_months || (it.billing_cycle === 'monthly' ? 1 : it.billing_cycle === 'annual' ? 12 : null);
  let next;
  if (step && it.expiry_date) {
    next = addMonths(it.expiry_date, step);
    let guard = 0;
    while (next <= todayStr() && guard++ < 600) next = addMonths(next, step);
  } else {
    next = prompt(`New date for "${it.name}" (YYYY-MM-DD). Leave blank to clear it.`, it.expiry_date ? addMonths(it.expiry_date, 12) : '');
    if (next === null) return;
    next = next.trim();
    if (next && !/^\d{4}-\d{2}-\d{2}$/.test(next)) return toast('Use the format YYYY-MM-DD', true);
  }
  const patch = { expiry_date: next || null, last_done: todayStr() };
  if (it.category === 'backup') patch.details = { ...it.details, last_restore_test: todayStr() };
  const { data, error } = await state.sb.from('items').update(patch).eq('id', id).select().single();
  if (error) return toast(friendlyError(error), true);
  state.items = state.items.map(i => i.id === id ? data : i);
  toast(next ? `Next date set to ${fmtDate(next)}` : 'Date cleared');
  render();
}

// ---------------- people / offboarding ----------------
// Reuse the existing spelling of a person or location, so "jane smith" saves as "Jane Smith".
function snapNames(row, skipId) {
  for (const field of ['assigned_to', 'location']) {
    const v = cleanName(row[field]);
    if (!v) { row[field] = null; continue; }
    const match = state.items.find(i => i.id !== skipId && nameKey(i[field]) === v.toLowerCase());
    row[field] = match ? cleanName(match[field]) : v;
  }
}
// Names and locations match regardless of capitalization or extra spaces.
const cleanName = v => (v || '').trim().replace(/\s+/g, ' ');
const nameKey = v => cleanName(v).toLowerCase();
const isLicense = i => CAT[i.category]?.group === 'Software & Cloud';

// Most common spelling of a name or location across items, so "jane smith" and "Jane Smith" show as one.
function canonicalNames(field) {
  const counts = new Map();
  for (const i of state.items) {
    const disp = cleanName(i[field]);
    if (!disp) continue;
    const k = disp.toLowerCase();
    if (!counts.has(k)) counts.set(k, {});
    counts.get(k)[disp] = (counts.get(k)[disp] || 0) + 1;
  }
  const out = new Map();
  for (const [k, spellings] of counts) out.set(k, Object.entries(spellings).sort((a, b) => b[1] - a[1])[0][0]);
  return out;
}

function peopleList() {
  const names = canonicalNames('assigned_to'), locs = canonicalNames('location');
  const map = new Map();
  for (const i of openItems()) {
    const k = nameKey(i.assigned_to);
    if (!k) continue;
    if (!map.has(k)) map.set(k, []);
    map.get(k).push(i);
  }
  return [...map.entries()].map(([key, items]) => {
    const dates = items.flatMap(keyDates).sort((a, b) => a.left - b.left);
    return {
      key, name: names.get(key), items,
      locations: [...new Set(items.map(i => locs.get(nameKey(i.location))).filter(Boolean))].sort(),
      groups: new Set(items.map(i => CAT[i.category]?.group)),
      lic: items.filter(isLicense).length, hw: items.filter(i => !isLicense(i)).length,
      next: dates[0] || null,
    };
  });
}

function viewPeople() {
  if (!isPro()) return `<div class="page-head"><h1>People</h1></div>` + upsell('People and offboarding', [
    'See every device, license and subscription assigned to each person',
    'One-click printable offboarding checklist: accounts to disable, licenses to reclaim, hardware to collect',
    'Never pay for a departed employee\'s license again',
  ]);
  const f = state.people;
  const locations = [...new Set(peopleList().flatMap(p => p.locations))].sort();
  return `<div class="page-head"><h1>People</h1></div>
    <div class="filters">
      <input id="p-q" placeholder="Search name, item, serial…" value="${esc(f.q)}">
      <select id="p-location"><option value="">All locations</option>${locations.map(l => `<option ${f.location === l ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select>
      <select id="p-group"><option value="">Has any item</option>${GROUPS.map(g => `<option value="${esc(g)}" ${f.group === g ? 'selected' : ''}>Has ${esc(g.toLowerCase())}</option>`).join('')}</select>
      <select id="p-sort">
        ${[['name', 'Sort: Name A–Z'], ['items', 'Sort: Most items'], ['next', 'Sort: Next date soonest'], ['location', 'Sort: Location']]
          .map(([v, l]) => `<option value="${v}" ${f.sort === v ? 'selected' : ''}>${l}</option>`).join('')}
      </select>
    </div>
    <div class="card" style="padding:0" id="people-table">${peopleTable()}</div>`;
}

function peopleTable() {
  const f = state.people, needle = f.q.trim().toLowerCase();
  let rows = peopleList().filter(p => {
    if (f.location && !p.locations.includes(f.location)) return false;
    if (f.group && !p.groups.has(f.group)) return false;
    if (needle) {
      const hay = [p.name, ...p.locations, ...p.items.flatMap(i => [i.name, i.serial, i.asset_tag, i.model, i.details?.hostname])].join(' ').toLowerCase();
      if (!hay.includes(needle)) return false;
    }
    return true;
  });
  const by = {
    name: (a, b) => a.name.localeCompare(b.name),
    items: (a, b) => b.items.length - a.items.length || a.name.localeCompare(b.name),
    next: (a, b) => (a.next?.left ?? 1e9) - (b.next?.left ?? 1e9),
    location: (a, b) => (a.locations[0] || '~').localeCompare(b.locations[0] || '~') || a.name.localeCompare(b.name),
  };
  rows.sort(by[f.sort] || by.name);
  const locNames = canonicalNames('location');
  if (!state.items.some(i => cleanName(i.assigned_to))) return '<div class="empty">No one has items assigned yet. Fill in "Assigned to" on an item and they\'ll show up here.</div>';
  if (!rows.length) return '<div class="empty">No people match these filters.</div>';
  return `<div class="table-wrap"><table>
    <tr><th>Name</th><th>Location</th><th>Hardware</th><th>Licenses</th><th>Next date</th><th></th></tr>
    ${rows.map(p => {
      const open = f.open.has(p.key);
      return `<tr class="clickable" data-action="toggle-person" data-key="${esc(p.key)}">
        <td><strong>${open ? '▾' : '▸'} ${esc(p.name)}</strong><div class="sub">${p.items.length} item${p.items.length === 1 ? '' : 's'}</div></td>
        <td>${esc(p.locations.join(', '))}</td>
        <td>${p.hw}</td><td>${p.lic}</td>
        <td>${p.next ? `${fmtDate(p.next.date)}<div>${badge(p.next.left)}</div>` : '<span class="muted">—</span>'}</td>
        <td style="text-align:right"><button class="btn small" data-action="offboard" data-key="${esc(p.key)}">Offboarding checklist</button></td>
      </tr>
      ${open ? `<tr><td colspan="6" style="background:#f8fafc;padding:6px 16px 12px">
        <ul class="list-plain">${p.items.map(i => `<li><span><a href="#" data-action="edit-item" data-id="${i.id}">${esc(i.name)}</a>
          <div class="sub">${esc(CAT[i.category]?.label || '')}${i.serial ? ' · S/N ' + esc(i.serial) : ''}${i.location ? ' · ' + esc(locNames.get(nameKey(i.location)) || i.location) : ''}</div></span>
          <span class="nw">${i.expiry_date ? badge(daysLeft(i.expiry_date)) : ''}</span></li>`).join('')}</ul></td></tr>` : ''}`;
    }).join('')}
  </table></div>`;
}

function printOffboarding(key) {
  const list = openItems().filter(i => nameKey(i.assigned_to) === key);
  const person = canonicalNames('assigned_to').get(key) || key;
  const hw = list.filter(i => !isLicense(i)), lic = list.filter(isLicense);
  const box = '☐';
  let area = document.getElementById('print-area');
  if (!area) { area = document.createElement('div'); area.id = 'print-area'; document.body.appendChild(area); }
  area.innerHTML = `<h1>Offboarding checklist: ${esc(person)}</h1>
    <p>${esc(state.ws.name)} · Printed ${fmtDate(todayStr())} · Last day: ____________ · Completed by: ____________</p>
    <h2>Accounts and access</h2><ul style="list-style:none;padding:0">
      ${['Disable sign-in (Active Directory / Entra ID / Google Workspace)', 'Revoke active sessions and remove MFA devices',
        'Convert mailbox to shared or set forwarding, and set an auto-reply', 'Transfer ownership of files, OneDrive / Google Drive, and shared docs',
        'Remove from groups, distribution lists, Teams / Slack channels', 'Revoke VPN, remote access, and building / alarm access',
        'Change any shared passwords they knew (Wi-Fi, admin accounts, vendor portals)', 'Remove from vendor portals and admin consoles']
        .map(s => `<li>${box} ${esc(s)}</li>`).join('')}</ul>
    <h2>Licenses and subscriptions to reclaim (${lic.length})</h2>
    ${lic.length ? `<ul style="list-style:none;padding:0">${lic.map(i => `<li>${box} ${esc(i.name)} (${esc(CAT[i.category]?.label)})</li>`).join('')}</ul>` : '<p>None recorded.</p>'}
    <h2>Equipment to collect (${hw.length})</h2>
    ${hw.length ? `<ul style="list-style:none;padding:0">${hw.map(i => `<li>${box} ${esc(i.name)}${i.serial ? ` · S/N ${esc(i.serial)}` : ''}${i.asset_tag ? ` · Tag ${esc(i.asset_tag)}` : ''}</li>`).join('')}</ul>` : '<p>None recorded.</p>'}
    <h2>Afterwards</h2><ul style="list-style:none;padding:0">
      <li>${box} Wipe and reimage returned devices</li><li>${box} Update "Assigned to" and status in RenewalWatch</li>
      <li>${box} Reduce seat counts at next renewal if not reassigned</li></ul>`;
  document.body.classList.add('printing');
  const done = () => { document.body.classList.remove('printing'); window.removeEventListener('afterprint', done); };
  window.addEventListener('afterprint', done);
  window.print();
}

// ---------------- settings ----------------
function viewSettings() {
  const owner = isOwner(), pro = isPro();
  return `<div class="page-head"><h1>Settings</h1></div>
    ${state.workspaces.length > 1 ? `<div class="card"><h2>Workspace</h2>
      <select id="ws-switch">${state.workspaces.map(w => `<option value="${w.id}" ${w.id === state.ws.id ? 'selected' : ''}>${esc(w.name)}</option>`).join('')}</select></div>` : ''}
    <div class="cols">
      <div class="card"><h2>Company</h2>
        <form id="ws-form"><div class="field"><label>Company name</label><input name="name" value="${esc(state.ws.name)}" ${owner ? '' : 'disabled'} maxlength="100"></div>
        ${owner ? '<button class="btn">Save</button>' : '<p class="small muted">Only the owner can change this.</p>'}</form>
      </div>
      <div class="card"><h2>Plan</h2>
        <p><span class="plan ${pro ? 'pro' : ''}">${pro ? 'Pro' : 'Free'}</span>
        ${pro ? ' Unlimited items, all categories, team access and insights.' : ` ${state.items.length} of ${FREE_ITEM_LIMIT} items used.`}</p>
        ${owner ? (pro ? '<button class="btn" data-action="manage-billing">Manage billing</button>'
          : `<button class="btn primary" data-action="upgrade">Upgrade to Pro · ${esc(state.cfg.priceLabel)}</button>`) : '<p class="small muted">Only the owner can change the plan.</p>'}
      </div>
    </div>
    <div class="card"><h2>Email reminders</h2>
      ${pro ? '' : '<p class="small muted">Free plan: reminders go to you 30 days and 7 days before each date, on the day, and weekly for anything overdue. Pro lets you pick the schedule and send to more people (like a shared IT inbox).</p>'}
      <form id="reminder-form"><div class="grid2">
        <div class="field"><label>Days before to remind (comma separated)</label><input name="days" value="${esc((state.ws.reminder_days || []).join(', '))}" ${pro && owner ? '' : 'disabled'} placeholder="90, 60, 30, 7, 1"></div>
        <div class="field"><label>Send to (comma separated, blank = all team members)</label><input name="emails" value="${esc((state.ws.notify_emails || []).join(', '))}" ${pro && owner ? '' : 'disabled'} placeholder="it@yourcompany.ca"></div>
      </div>${pro && owner ? '<button class="btn">Save reminders</button>' : ''}</form>
    </div>
    <div class="card"><h2>Team</h2>
      <ul class="list-plain">${state.members.map(m => `<li><span>${esc(m.email)} ${m.role === 'owner' ? '<span class="badge b-green">Owner</span>' : ''}</span>
        ${owner && m.role !== 'owner' ? `<button class="btn small danger" data-action="remove-member" data-user="${m.user_id}">Remove</button>` : ''}</li>`).join('')}
        ${state.invites.map(i => `<li><span>${esc(i.email)} <span class="badge b-gray">Invited</span></span>
        ${owner ? `<button class="btn small" data-action="cancel-invite" data-email="${esc(i.email)}">Cancel</button>` : ''}</li>`).join('')}</ul>
      ${pro && owner ? `<form id="invite-form" class="chip-row" style="margin-top:12px"><input name="email" type="email" required placeholder="colleague@company.ca" style="flex:1;min-width:200px"><button class="btn">Invite</button></form>
        <p class="small muted">They'll join this workspace when they create an account or sign in with that email.</p>`
        : !pro ? '<p class="small muted">Adding team members is part of Pro.</p>' : ''}
    </div>
    <div class="card"><h2>Import and export</h2>
      <div class="chip-row"><button class="btn" data-action="export-csv">Export all items (CSV)</button>
        ${pro ? `<button class="btn" data-action="csv-template">Download import template</button>
          <label class="btn" style="margin:0">Import CSV<input type="file" id="csv-file" accept=".csv,text/csv" hidden></label>` : ''}</div>
      ${pro ? '' : '<p class="small muted" style="margin-top:8px">Importing from a spreadsheet is part of Pro.</p>'}
    </div>
    <div class="card"><h2>Account</h2><p>Signed in as <strong>${esc(me()?.email)}</strong></p><button class="btn" data-action="signout">Sign out</button></div>`;
}

async function saveWorkspaceName(form) {
  const name = form.name.value.trim() || 'My Company';
  const { error } = await state.sb.from('workspaces').update({ name }).eq('id', state.ws.id);
  if (error) return toast(friendlyError(error), true);
  await refreshWorkspaceRow(); render(); toast('Saved');
}

async function saveReminders(form) {
  const days = [...new Set(form.days.value.split(',').map(s => parseInt(s, 10)).filter(n => n >= 0 && n <= 365))].sort((a, b) => b - a);
  const emails = [...new Set(form.emails.value.split(',').map(s => s.trim().toLowerCase()).filter(Boolean))];
  const bad = emails.find(e => !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e));
  if (bad) return toast(`"${bad}" doesn't look like an email`, true);
  if (!days.length) return toast('Enter at least one number of days', true);
  const { error } = await state.sb.from('workspaces').update({ reminder_days: days, notify_emails: emails }).eq('id', state.ws.id);
  if (error) return toast(friendlyError(error), true);
  await refreshWorkspaceRow(); render(); toast('Reminder settings saved');
}

async function invite(form) {
  const email = form.email.value.trim().toLowerCase();
  if (state.members.some(m => m.email === email)) return toast('Already on the team', true);
  const { error } = await state.sb.from('invites').insert({ workspace_id: state.ws.id, email });
  if (error) return toast(error.code === '23505' ? 'Already invited' : friendlyError(error), true);
  await loadWorkspace(); render(); toast(`Invited ${email}. Let them know to sign up at ${location.origin}/app`);
}

function upgrade() {
  const link = state.cfg.paymentLink;
  if (!link) return toast('Payments are not set up yet.', true);
  const url = new URL(link);
  url.searchParams.set('client_reference_id', state.ws.id);
  url.searchParams.set('prefilled_email', me()?.email || '');
  location.href = url.toString();
}

function manageBilling() {
  const link = state.cfg.portalLink;
  if (!link) return toast('Billing portal is not set up yet.', true);
  const url = new URL(link);
  url.searchParams.set('prefilled_email', me()?.email || '');
  location.href = url.toString();
}

// ---------------- CSV ----------------
const BASE_COLS = ['name', 'category', 'vendor', 'model', 'serial', 'asset_tag', 'assigned_to', 'location', 'status', 'purchase_date', 'cost',
  'expiry_date', 'renewal_cost', 'billing_cycle', 'auto_renew', 'recur_months', 'notes'];

function csvCell(v) {
  const s = v === null || v === undefined ? '' : String(v);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}
function download(name, text) {
  const blob = new Blob([text], { type: 'text/csv;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = name;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

function exportCsv() {
  const detailKeys = [...new Set(state.items.flatMap(i => Object.keys(i.details || {})))].sort();
  const header = [...BASE_COLS, ...detailKeys.map(k => `details.${k}`)];
  const lines = [header.join(',')];
  for (const i of state.items) lines.push([...BASE_COLS.map(c => i[c]), ...detailKeys.map(k => i.details?.[k])].map(csvCell).join(','));
  download(`renewalwatch-${todayStr()}.csv`, '﻿' + lines.join('\r\n'));
}

function csvTemplate() {
  const header = [...BASE_COLS, 'details.hostname', 'details.ip', 'details.seats_total', 'details.seats_used'];
  const ex = [
    ['Reception laptop', 'computer', 'Dell', 'Latitude 5450', 'ABC1234', 'IT-0042', 'Jane Smith', 'Woodbridge', 'active', '2024-03-01', '1499', '2027-03-01', '', 'one_time', 'false', '', '3-year ProSupport', 'WS-RECEP01', '', '', ''],
    ['Microsoft 365 Business Premium', 'saas', 'Microsoft', '', '', '', '', '', 'active', '', '', '2027-01-15', '9600', 'annual', 'true', '12', '', '', '', '40', '36'],
  ];
  download('renewalwatch-import-template.csv', [header, ...ex].map(r => r.map(csvCell).join(',')).join('\r\n'));
}

export function parseCsv(text) {
  const rows = []; let row = [], cell = '', q = false;
  text = text.replace(/^﻿/, '');
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else q = false; }
      else cell += c;
    } else if (c === '"') q = true;
    else if (c === ',') { row.push(cell); cell = ''; }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++;
      row.push(cell); rows.push(row); row = []; cell = '';
    } else cell += c;
  }
  if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
  return rows.filter(r => r.some(c => c.trim() !== ''));
}

export function csvRowsToItems(rows, wsId) {
  const [header, ...data] = rows;
  const h = header.map(x => x.trim().toLowerCase().replace(/\s+/g, '_'));
  const byLabel = Object.fromEntries(CATEGORIES.map(c => [c.label.toLowerCase(), c.id]));
  const date = v => /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null;
  const num = v => v === '' || isNaN(Number(v.replace(/[$,]/g, ''))) ? null : Number(v.replace(/[$,]/g, ''));
  return data.map(r => {
    const o = {}; const details = {};
    h.forEach((k, idx) => {
      const val = (r[idx] ?? '').trim();
      if (val === '') return;
      if (k.startsWith('details.')) details[k.slice(8)] = isNaN(Number(val)) ? val : Number(val);
      else o[k] = val;
    });
    let cat = (o.category || '').toLowerCase();
    cat = CAT[cat] ? cat : byLabel[cat] || 'other_hw';
    const billing = BILLING.find(b => b.id === o.billing_cycle || b.label.toLowerCase() === (o.billing_cycle || '').toLowerCase())?.id || null;
    const status = STATUSES.find(s => s.id === o.status || s.label.toLowerCase() === (o.status || '').toLowerCase())?.id || 'active';
    const recur = parseInt(o.recur_months, 10);
    return {
      workspace_id: wsId, category: cat, name: (o.name || '').slice(0, 200),
      vendor: o.vendor || null, model: o.model || null, serial: o.serial || null, asset_tag: o.asset_tag || null,
      assigned_to: o.assigned_to || null, location: o.location || null, status,
      purchase_date: date(o.purchase_date || ''), cost: num(o.cost || ''), expiry_date: date(o.expiry_date || ''),
      renewal_cost: num(o.renewal_cost || ''), billing_cycle: billing, auto_renew: /^(true|yes|y|1)$/i.test(o.auto_renew || ''),
      recur_months: recur >= 1 && recur <= 120 ? recur : null, notes: o.notes || null, details,
    };
  }).filter(i => i.name);
}

async function importCsv(file) {
  const text = await file.text();
  const items = csvRowsToItems(parseCsv(text), state.ws.id);
  items.forEach(i => snapNames(i));
  if (!items.length) return toast('No rows with a "name" column found', true);
  if (!confirm(`Import ${items.length} item${items.length === 1 ? '' : 's'}?`)) return;
  let added = 0;
  for (let i = 0; i < items.length; i += 200) {
    const { data, error } = await state.sb.from('items').insert(items.slice(i, i + 200)).select();
    if (error) { toast(`Stopped after ${added} items: ${friendlyError(error)}`, true); break; }
    added += data.length;
  }
  state.items = await fetchAllItems(state.ws.id);
  render();
  if (added === items.length) toast(`Imported ${added} items`);
}

// ---------------- events ----------------
document.addEventListener('click', async e => {
  const el = e.target.closest('[data-action]');
  if (!el) {
    if (e.target.classList?.contains('modal-bg')) closeModal();
    return;
  }
  const a = el.dataset.action;
  if (el.tagName === 'A' || el.tagName === 'BUTTON' && el.type !== 'submit') e.preventDefault();
  switch (a) {
    case 'auth-tab': return renderAuth(el.dataset.tab);
    case 'signout': await state.sb?.auth.signOut(); return;
    case 'new-item':
      if (!isPro() && state.items.length >= FREE_ITEM_LIMIT) return toast(friendlyError({ message: 'FREE_LIMIT' }), true);
      return openItemModal();
    case 'edit-item': return openItemModal(state.items.find(i => i.id === el.dataset.id));
    case 'close-modal': return closeModal();
    case 'delete-item': return deleteItem(document.querySelector('.modal-bg')?.dataset.id);
    case 'renew': return markRenewed(el.dataset.id);
    case 'upgrade': return upgrade();
    case 'manage-billing': return manageBilling();
    case 'export-csv': return exportCsv();
    case 'csv-template': return csvTemplate();
    case 'offboard': e.stopPropagation(); return printOffboarding(el.dataset.key);
    case 'toggle-person': {
      const k = el.dataset.key, set = state.people.open;
      set.has(k) ? set.delete(k) : set.add(k);
      document.getElementById('people-table').innerHTML = peopleTable();
      return;
    }
    case 'remove-member': {
      if (!confirm('Remove this person from the workspace?')) return;
      const { error } = await state.sb.from('members').delete().eq('workspace_id', state.ws.id).eq('user_id', el.dataset.user);
      if (error) return toast(error.message, true);
      await loadWorkspace(); return render();
    }
    case 'cancel-invite': {
      const { error } = await state.sb.from('invites').delete().eq('workspace_id', state.ws.id).eq('email', el.dataset.email);
      if (error) return toast(error.message, true);
      await loadWorkspace(); return render();
    }
  }
});

document.addEventListener('submit', e => {
  const f = e.target;
  const handlers = {
    'auth-form': submitAuth, 'ws-form': saveWorkspaceName, 'reminder-form': saveReminders, 'invite-form': invite,
    'recovery-form': async form => {
      const { error } = await state.sb.auth.updateUser({ password: form.password.value });
      if (error) return toast(error.message, true);
      state.recovery = false;
      history.replaceState(null, '', location.pathname);
      toast('Password updated');
      loadAll();
    },
  };
  if (handlers[f.id]) { e.preventDefault(); handlers[f.id](f); }
});

document.addEventListener('input', e => {
  const id = e.target.id;
  if (id === 'f-q') { state.filters.q = e.target.value; document.getElementById('inv-table').innerHTML = inventoryTable(); }
  if (id === 'p-q') { state.people.q = e.target.value; document.getElementById('people-table').innerHTML = peopleTable(); }
});

document.addEventListener('change', async e => {
  const id = e.target.id;
  if (['f-group', 'f-location', 'f-status'].includes(id)) {
    state.filters[id.slice(2)] = e.target.value;
    document.getElementById('inv-table').innerHTML = inventoryTable();
  }
  if (['p-location', 'p-group', 'p-sort'].includes(id)) {
    state.people[id.slice(2)] = e.target.value;
    document.getElementById('people-table').innerHTML = peopleTable();
  }
  if (id === 'ws-switch') {
    state.ws = state.workspaces.find(w => w.id === e.target.value);
    lsSet('rw_ws', state.ws.id);
    await loadWorkspace(); render();
  }
  if (id === 'csv-file' && e.target.files[0]) importCsv(e.target.files[0]);
});

document.addEventListener('keydown', e => { if (e.key === 'Escape') closeModal(); });

if (root) boot();
