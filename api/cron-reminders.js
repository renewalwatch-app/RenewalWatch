import { CAT, EXTRA_REMINDER_DATES } from '../assets/categories.js';
import { env, json, supabase, fetchAll } from './_lib.js';
import { checkTarget, lookup } from './_expiry.js';

// Runs once a day (see vercel.json). Emails each workspace a digest of upcoming renewals.
export async function GET(request) {
  const secret = env('CRON_SECRET');
  if (!secret || request.headers.get('authorization') !== `Bearer ${secret}`) {
    return json({ error: 'Unauthorized' }, 401);
  }

  const today = torontoToday();
  const checks = await refreshAutoChecks(today);
  const horizon = addDays(today, 400);
  const [workspaces, members, items] = await Promise.all([
    fetchAll('workspaces?select=id,name,plan,reminder_days,notify_emails'),
    fetchAll('members?select=workspace_id,email', 'workspace_id,user_id'),
    fetchAll(`items?select=id,workspace_id,name,category,vendor,expiry_date,renewal_cost,auto_renew,details` +
      `&status=neq.retired&or=(expiry_date.lte.${horizon},details->>os_eos.lte.${horizon})`),
  ]);

  const digests = buildDigests({ today, workspaces, members, items });
  const results = [];
  for (const d of digests) {
    try {
      await sendEmail(d);
      results.push({ workspace: d.workspaceId, sent: d.to.length, lines: d.lines.length });
    } catch (err) {
      console.error(err);
      results.push({ workspace: d.workspaceId, error: String(err.message || err) });
    }
  }
  return json({ today, checks, digests: results.length, results });
}

// Pure function so it can be tested without a database.
export function buildDigests({ today, workspaces, members, items }) {
  const isMonday = new Date(`${today}T00:00:00Z`).getUTCDay() === 1;
  const byWs = new Map();
  for (const it of items) {
    if (!byWs.has(it.workspace_id)) byWs.set(it.workspace_id, []);
    byWs.get(it.workspace_id).push(it);
  }
  const out = [];
  for (const ws of workspaces) {
    const wsItems = byWs.get(ws.id) || [];
    if (!wsItems.length) continue;
    const days = new Set(ws.plan === 'pro' && ws.reminder_days?.length ? ws.reminder_days : [30, 7]);
    days.add(0);
    const lines = [];
    for (const it of wsItems) {
      const cat = CAT[it.category] || { label: it.category, dateLabel: 'Key date' };
      const dates = [{ label: cat.dateLabel, date: it.expiry_date }];
      for (const x of EXTRA_REMINDER_DATES) if (it.details?.[x.k]) dates.push({ label: x.label, date: it.details[x.k] });
      for (const { label, date } of dates) {
        if (!date) continue;
        const left = daysBetween(today, date);
        if (days.has(left) || (left < 0 && isMonday)) {
          lines.push({ name: it.name, vendor: it.vendor, category: cat.label, label, date, left,
            cost: it.renewal_cost, autoRenew: it.auto_renew });
        }
      }
    }
    if (!lines.length) continue;
    lines.sort((a, b) => a.left - b.left);
    const emails = ws.plan === 'pro' && ws.notify_emails?.length
      ? ws.notify_emails
      : members.filter(m => m.workspace_id === ws.id).map(m => m.email);
    const to = [...new Set(emails.filter(Boolean))];
    if (to.length) out.push({ workspaceId: ws.id, workspaceName: ws.name, to, lines });
  }
  return out;
}

async function sendEmail({ workspaceName, to, lines }) {
  const key = env('RESEND_API_KEY');
  if (!key) throw new Error('RESEND_API_KEY is not set');
  const appUrl = env('APP_URL', 'https://renewalwatch.ca').replace(/\/$/, '');
  const overdue = lines.filter(l => l.left < 0).length;
  const subject = overdue
    ? `${overdue} overdue and ${lines.length - overdue} upcoming renewals for ${workspaceName}`
    : `${lines.length} upcoming renewal${lines.length === 1 ? '' : 's'} for ${workspaceName}`;
  const rows = lines.map(l => `
    <tr>
      <td style="padding:8px;border-bottom:1px solid #e5e7eb"><strong>${esc(l.name)}</strong><br>
        <span style="color:#6b7280;font-size:13px">${esc(l.category)}${l.vendor ? ' · ' + esc(l.vendor) : ''}</span></td>
      <td style="padding:8px;border-bottom:1px solid #e5e7eb">${esc(l.label)}<br><span style="font-size:13px">${esc(l.date)}</span></td>
      <td style="padding:8px;border-bottom:1px solid #e5e7eb;color:${l.left < 0 ? '#b91c1c' : l.left <= 7 ? '#b45309' : '#111827'};font-weight:600">
        ${l.left < 0 ? `${-l.left} days overdue` : l.left === 0 ? 'Today' : `In ${l.left} days`}</td>
      <td style="padding:8px;border-bottom:1px solid #e5e7eb">${l.cost != null ? '$' + Number(l.cost).toFixed(2) : ''}${l.autoRenew ? '<br><span style="font-size:12px;color:#6b7280">Auto-renews</span>' : ''}</td>
    </tr>`).join('');
  const html = `<div style="font-family:Arial,sans-serif;max-width:640px;margin:auto;color:#111827">
    <h2 style="margin:0 0 4px">RenewalWatch</h2>
    <p style="margin:0 0 16px;color:#6b7280">${esc(workspaceName)}</p>
    <table style="border-collapse:collapse;width:100%;font-size:14px">
      <tr style="text-align:left;background:#f3f4f6"><th style="padding:8px">Item</th><th style="padding:8px">Date</th><th style="padding:8px">When</th><th style="padding:8px">Cost</th></tr>
      ${rows}
    </table>
    <p style="margin-top:20px"><a href="${appUrl}/app" style="background:#0f766e;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">Open RenewalWatch</a></p>
    <p style="font-size:12px;color:#6b7280">You get this because you're on the ${esc(workspaceName)} workspace. Change reminder settings in the app.</p>
  </div>`;

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: env('REMINDER_FROM', 'RenewalWatch <reminders@renewalwatch.ca>'), to, subject, html }),
  });
  if (!res.ok) throw new Error(`Resend failed: ${res.status} ${await res.text()}`);
}

// Look up fresh expiry dates for domains and SSL certificates set to check automatically.
async function refreshAutoChecks(today) {
  const items = await fetchAll('items?select=id,category,name,details,expiry_date&status=neq.retired' +
    '&category=in.(domain,ssl)&details->>auto_check=eq.true');
  let updated = 0, failed = 0;
  const queue = [...items];
  const worker = async () => {
    while (queue.length) {
      const it = queue.shift();
      const target = checkTarget(it);
      if (!target) continue;
      const details = { ...it.details, last_checked: today };
      let patch;
      try {
        const { date, issuer } = await lookup(target.type, target.host);
        delete details.check_error;
        if (issuer && !details.issuer) details.issuer = issuer;   // fill blanks only, never overwrite
        patch = { expiry_date: date, details };
        if (date !== it.expiry_date) updated++;
      } catch (err) {
        details.check_error = String(err.message || err).slice(0, 200);
        patch = { details };
        failed++;
      }
      try { await supabase(`items?id=eq.${it.id}`, { method: 'PATCH', body: patch }); } catch (e) { console.error(e); }
    }
  };
  await Promise.all(Array.from({ length: 5 }, worker));
  return { checked: items.length, updated, failed };
}

export function torontoToday() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(new Date());
}
export function daysBetween(a, b) {
  return Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86400000);
}
function addDays(d, n) {
  return new Date(Date.parse(`${d}T00:00:00Z`) + n * 86400000).toISOString().slice(0, 10);
}
function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
