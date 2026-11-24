import { env, json } from './_lib.js';
import { lookup } from './_expiry.js';

// "Check now" button in the app. Only signed-in users can call it.
export async function POST(request) {
  const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token || !(await validUser(token))) return json({ error: 'Please sign in again' }, 401);

  let body;
  try { body = await request.json(); } catch { return json({ error: 'Bad request' }, 400); }
  const { type, host } = body || {};
  if (!['domain', 'ssl'].includes(type) || !host) return json({ error: 'Bad request' }, 400);

  try {
    return json({ date: await lookup(type, host) });
  } catch (err) {
    return json({ error: err.message }, 422);
  }
}

async function validUser(token) {
  const url = env('SUPABASE_URL').replace(/\/$/, '');
  const res = await fetch(`${url}/auth/v1/user`, {
    headers: { apikey: env('SUPABASE_ANON_KEY'), Authorization: `Bearer ${token}` },
  });
  return res.ok;
}
