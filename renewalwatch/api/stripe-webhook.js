import crypto from 'node:crypto';
import { env, json, supabase, isUuid } from './_lib.js';

// Stripe sends events here. Set the endpoint in Stripe to https://YOUR-DOMAIN/api/stripe-webhook
// Events used: checkout.session.completed, customer.subscription.updated, customer.subscription.deleted
export async function POST(request) {
  const secret = env('STRIPE_WEBHOOK_SECRET');
  if (!secret) return json({ error: 'STRIPE_WEBHOOK_SECRET is not set' }, 500);

  const payload = await request.text();
  const header = request.headers.get('stripe-signature') || '';
  if (!verifySignature(payload, header, secret)) return json({ error: 'Invalid signature' }, 400);

  const event = JSON.parse(payload);
  const obj = event.data?.object || {};

  try {
    if (event.type === 'checkout.session.completed') {
      const ws = obj.client_reference_id;
      if (!isUuid(ws)) return json({ received: true, note: 'No workspace id on session' });
      await supabase(`workspaces?id=eq.${ws}`, {
        method: 'PATCH',
        body: { plan: 'pro', stripe_customer_id: obj.customer || null, stripe_subscription_id: obj.subscription || null },
      });
    } else if (event.type === 'customer.subscription.updated' || event.type === 'customer.subscription.created') {
      const active = ['active', 'trialing', 'past_due'].includes(obj.status);
      await supabase(`workspaces?stripe_customer_id=eq.${encodeURIComponent(obj.customer)}`, {
        method: 'PATCH',
        body: { plan: active ? 'pro' : 'free', stripe_subscription_id: obj.id },
      });
    } else if (event.type === 'customer.subscription.deleted') {
      await supabase(`workspaces?stripe_customer_id=eq.${encodeURIComponent(obj.customer)}`, {
        method: 'PATCH',
        body: { plan: 'free' },
      });
    }
  } catch (err) {
    console.error(err);
    return json({ error: 'Update failed' }, 500); // Stripe will retry
  }
  return json({ received: true });
}

function verifySignature(payload, header, secret, toleranceSec = 300) {
  const parts = header.split(',').map(p => p.split('='));
  const t = parts.find(([k]) => k === 't')?.[1];
  const sigs = parts.filter(([k]) => k === 'v1').map(([, v]) => v);
  if (!t || sigs.length === 0) return false;
  if (Math.abs(Date.now() / 1000 - Number(t)) > toleranceSec) return false;
  const expected = crypto.createHmac('sha256', secret).update(`${t}.${payload}`).digest('hex');
  const a = Buffer.from(expected);
  return sigs.some(s => {
    const b = Buffer.from(s);
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  });
}
