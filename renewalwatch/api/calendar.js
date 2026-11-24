import { CAT, EXTRA_REMINDER_DATES } from '../assets/categories.js';
import { env, supabase, fetchAll, isUuid } from './_lib.js';

// Calendar subscription feed. Outlook / Google / Apple Calendar fetch this URL a few times a day.
// The token in the URL is a per-workspace secret, reset from Settings.
export async function GET(request) {
  const token = new URL(request.url).searchParams.get('token');
  if (!isUuid(token)) return new Response('Not found', { status: 404 });
  const [ws] = await supabase(`workspaces?select=id,name,plan&calendar_token=eq.${token}`);
  if (!ws) return new Response('Not found', { status: 404 });

  const items = ws.plan === 'pro'
    ? await fetchAll(`items?select=id,name,category,vendor,expiry_date,renewal_cost,auto_renew,details,location,assigned_to&workspace_id=eq.${ws.id}&status=neq.retired`)
    : [];
  return new Response(buildCalendar(ws, items, env('APP_URL', 'https://renewalwatch.ca')), {
    headers: { 'content-type': 'text/calendar; charset=utf-8', 'cache-control': 'no-store' },
  });
}

export function buildCalendar(ws, items, appUrl) {
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//RenewalWatch//Renewals//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    `X-WR-CALNAME:${text(`RenewalWatch – ${ws.name}`)}`, 'REFRESH-INTERVAL;VALUE=DURATION:PT6H', 'X-PUBLISHED-TTL:PT6H'];
  if (ws.plan !== 'pro') {
    lines.push('BEGIN:VEVENT', `UID:upgrade-${ws.id}@renewalwatch.ca`, `DTSTAMP:${stamp}`, `DTSTART;VALUE=DATE:${stamp.slice(0, 8)}`,
      `SUMMARY:${text('RenewalWatch calendar needs the Pro plan')}`, 'END:VEVENT');
  }
  for (const it of items) {
    const cat = CAT[it.category] || { label: it.category, dateLabel: 'Key date' };
    const dates = [{ key: 'main', label: cat.dateLabel, date: it.expiry_date }];
    for (const x of EXTRA_REMINDER_DATES) if (it.details?.[x.k]) dates.push({ key: x.k, label: x.label, date: it.details[x.k] });
    for (const d of dates) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(d.date || '')) continue;
      const start = d.date.replace(/-/g, '');
      const end = new Date(Date.parse(`${d.date}T00:00:00Z`) + 86400000).toISOString().slice(0, 10).replace(/-/g, '');
      const desc = [cat.label, it.vendor && `Vendor: ${it.vendor}`, it.assigned_to && `Assigned to: ${it.assigned_to}`,
        it.location && `Location: ${it.location}`, it.renewal_cost != null && `Renewal cost: $${Number(it.renewal_cost).toFixed(2)}`,
        it.auto_renew && 'Auto-renews', `${appUrl.replace(/\/$/, '')}/app`].filter(Boolean).join('\n');
      lines.push('BEGIN:VEVENT', `UID:${it.id}-${d.key}@renewalwatch.ca`, `DTSTAMP:${stamp}`,
        `DTSTART;VALUE=DATE:${start}`, `DTEND;VALUE=DATE:${end}`, 'TRANSP:TRANSPARENT',
        `SUMMARY:${text(`${d.label}: ${it.name}`)}`, `DESCRIPTION:${text(desc)}`,
        'BEGIN:VALARM', 'ACTION:DISPLAY', `DESCRIPTION:${text(`${d.label}: ${it.name}`)}`, 'TRIGGER:-P7D', 'END:VALARM',
        'END:VEVENT');
    }
  }
  lines.push('END:VCALENDAR');
  return lines.map(fold).join('\r\n') + '\r\n';
}

function text(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
}
// Calendar lines must be at most 75 bytes; longer ones continue on the next line after a space.
function fold(line) {
  const bytes = Buffer.from(line, 'utf8');
  if (bytes.length <= 75) return line;
  const parts = []; let cur = '';
  for (const ch of line) {
    if (Buffer.byteLength(cur + ch) > (parts.length ? 74 : 75)) { parts.push(cur); cur = ''; }
    cur += ch;
  }
  parts.push(cur);
  return parts.join('\r\n ');
}
