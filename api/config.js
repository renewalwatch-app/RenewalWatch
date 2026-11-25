import { env, json } from './_lib.js';

// Public settings the browser needs. Never put secret keys here.
export function GET() {
  return json({
    supabaseUrl: env('SUPABASE_URL'),
    supabaseAnonKey: env('SUPABASE_ANON_KEY'),
    paymentLink: env('STRIPE_PAYMENT_LINK'),
    paymentLinkYearly: env('STRIPE_PAYMENT_LINK_YEARLY'),
    portalLink: env('STRIPE_PORTAL_LINK'),
    priceLabel: env('PRICE_LABEL', '$12/month'),
    priceLabelYearly: env('PRICE_LABEL_YEARLY', '$120/year'),
    gaMeasurementId: env('GA_MEASUREMENT_ID'),
  });
}
